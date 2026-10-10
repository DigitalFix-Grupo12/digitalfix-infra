#!/bin/bash
# DigitalFix - bootstrap EC2 de aplicaciones (Amazon Linux 2023, t3.medium)
# Levanta 7 servicios Spring Boot en el mismo host:
#   8080 ms-digitalfix-bff          (UNICO puerto abierto en el SG, lo consume API Gateway)
#   8082 ms-digitalfix-workorders   (interno; productor RabbitMQ)
#   8083 ms-digitalfix-catalog      (interno)
#   8084 ms-digitalfix-report       (interno)
#   8085 ms-digitalfix-audit        (interno)
#   8086 ms-digitalfix-notify       (interno; consumidor RabbitMQ)
#   8087 ms-digitalfix-rabbit-admin (interno; administrador RabbitMQ)
# RabbitMQ corre en otra EC2 (ec2-mq, ver Deploy-MQ.ps1); su IP privada esta en SSM.
exec > >(tee /var/log/setup-debug.log) 2>&1
set -x

# Log de bootstrap visible via http://<ip>:8081/setup-debug.log (solo diagnostico)
mkdir -p /var/www-debug
ln -sf /var/log/setup-debug.log /var/www-debug/setup-debug.log
(cd /var/www-debug && nohup python3 -m http.server 8081 > /var/log/httpserver.log 2>&1 &)

echo "=== INICIO $(date) ==="

# --- Swap de 2 GB: margen para compilar con Maven mientras arrancan las JVM ---
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile swap swap defaults 0 0' >> /etc/fstab
fi

dnf install -y java-17-amazon-corretto-devel git maven

# --- Credenciales de la base de datos cloud (RDS) desde SSM Parameter Store ---
# La instancia usa el rol LabInstanceProfile; el password es SecureString.
# Si SSM no responde, los servicios arrancan con H2 (perfil por defecto).
REGION=us-east-1
mkdir -p /etc/digitalfix
ssm() { aws ssm get-parameter --region "$REGION" --name "$1" $2 --query Parameter.Value --output text; }
set +x
if DB_HOST=$(ssm /digitalfix/db/host) && DB_USERNAME=$(ssm /digitalfix/db/username) \
   && DB_PASSWORD=$(ssm /digitalfix/db/password --with-decryption) && DB_NAME=$(ssm /digitalfix/db/name); then
  umask 077
  cat > /etc/digitalfix/db.env <<EOF
SPRING_PROFILES_ACTIVE=cloud
DB_HOST=$DB_HOST
DB_NAME=$DB_NAME
DB_USERNAME=$DB_USERNAME
DB_PASSWORD=$DB_PASSWORD
EOF
  umask 022
  echo "db.env generado para host $DB_HOST"
else
  echo "WARN: no se pudieron leer los parametros SSM; se usara H2"
fi
unset DB_PASSWORD

# --- Conexion al cluster RabbitMQ (ec2-mq) desde SSM ---
if MQ_HOST=$(ssm /digitalfix/mq/host) && MQ_USER=$(ssm /digitalfix/mq/username) \
   && MQ_PASS=$(ssm /digitalfix/mq/password --with-decryption); then
  umask 077
  cat > /etc/digitalfix/mq.env <<EOF
RABBITMQ_ADDRESSES=$MQ_HOST:5672,$MQ_HOST:5673
RABBITMQ_USERNAME=$MQ_USER
RABBITMQ_PASSWORD=$MQ_PASS
RABBITMQ_MANAGEMENT_URLS=http://$MQ_HOST:15672,http://$MQ_HOST:15673
EOF
  umask 022
  echo "mq.env generado para el cluster en $MQ_HOST"
else
  echo "WARN: sin parametros /digitalfix/mq/*; ejecutar Deploy-MQ.ps1 antes que Deploy-EC2.ps1"
fi
unset MQ_PASS
set -x

GH=https://github.com/DigitalFix-Grupo12
APP_DIR=/opt/digitalfix
mkdir -p "$APP_DIR"
export HOME=/root
export MAVEN_OPTS="-Xmx384m"

# Orden de arranque: audit primero (workorders le publica eventos), notify
# antes que workorders (declara colas y DLQ), report despues de workorders
# (lo consulta), y el BFF al final.
SERVICES="ms-digitalfix-audit ms-digitalfix-catalog ms-digitalfix-notify ms-digitalfix-workorders ms-digitalfix-report ms-digitalfix-rabbit-admin ms-digitalfix-bff"

for SVC in $SERVICES; do
  cd /home/ec2-user
  rm -rf "$SVC"
  timeout 120 git clone --depth 1 "$GH/$SVC.git" || { echo "ERROR clonando $SVC"; continue; }
  cd "$SVC"
  timeout 900 mvn -B -q package -DskipTests || { echo "ERROR compilando $SVC"; continue; }
  JAR=$(ls target/*.jar | grep -v original | head -1)
  cp "$JAR" "$APP_DIR/$SVC.jar"
  ls -la "$APP_DIR/$SVC.jar"
done
chown -R ec2-user:ec2-user "$APP_DIR"

# JVM chica: heap acotado + SerialGC + C1 para arrancar rapido con poca RAM
JAVA_OPTS="-Xms64m -Xmx160m -XX:MaxMetaspaceSize=128m -Xss512k -XX:+UseSerialGC -XX:TieredStopAtLevel=1"

write_unit() {
  local SVC=$1 AFTER=$2 EXTRA_ENV=$3
  cat > /etc/systemd/system/$SVC.service <<EOF
[Unit]
Description=DigitalFix $SVC
After=network-online.target $AFTER
Wants=network-online.target

[Service]
User=ec2-user
WorkingDirectory=$APP_DIR
$EXTRA_ENV
ExecStart=/usr/bin/java $JAVA_OPTS -jar $APP_DIR/$SVC.jar
Restart=always
RestartSec=10
SuccessExitStatus=143

[Install]
WantedBy=multi-user.target
EOF
}

DBENV="EnvironmentFile=-/etc/digitalfix/db.env"
MQENV="EnvironmentFile=-/etc/digitalfix/mq.env"
mkdir -p /var/lib/digitalfix/reports && chown ec2-user:ec2-user /var/lib/digitalfix/reports
write_unit ms-digitalfix-audit      ""                                  "$DBENV"
write_unit ms-digitalfix-catalog    ""                                  "$DBENV"
write_unit ms-digitalfix-notify     ""                                  "$MQENV
Environment=REPORTS_DIR=/var/lib/digitalfix/reports"
write_unit ms-digitalfix-workorders "ms-digitalfix-audit.service ms-digitalfix-notify.service" "$DBENV
$MQENV
Environment=AUDIT_URL=http://localhost:8085"
write_unit ms-digitalfix-rabbit-admin ""                                "$MQENV"
write_unit ms-digitalfix-report     "ms-digitalfix-workorders.service"  "Environment=WORKORDERS_URL=http://localhost:8082"
write_unit ms-digitalfix-bff        "ms-digitalfix-workorders.service" "Environment=AZURE_TENANT_ID=ac1c32f1-bc10-4ded-b8c0-102ac9a1fd68
Environment=AZURE_API_CLIENT_ID=fb8ea665-ee45-4790-8112-eade3bd230e5
Environment=DIGITALFIX_SECURITY_ALLOWED_ORIGINS=http://localhost:4200,https://main.dehlzhnwtqj7a.amplifyapp.com"

systemctl daemon-reload
# Arranque escalonado para no saturar la CPU (2 vCPU burstable)
for SVC in $SERVICES; do
  systemctl enable --now "$SVC"
  sleep 20
done

# Script de demostracion de mensajeria (EP4) para ejecutar por SSH
curl -sSL https://raw.githubusercontent.com/DigitalFix-Grupo12/digitalfix-infra/main/scripts/demo-mensajeria.sh \
  -o /home/ec2-user/demo-mensajeria.sh && chmod +x /home/ec2-user/demo-mensajeria.sh \
  && chown ec2-user:ec2-user /home/ec2-user/demo-mensajeria.sh || true

sleep 30
echo "=== HEALTH ==="
for PORT in 8085 8083 8086 8082 8084 8087 8080; do
  echo -n "$PORT -> "; curl -s -m 5 "http://localhost:$PORT/actuator/health" || echo "sin respuesta"
  echo
done
free -m
echo "=== SYSTEMD STATUS ==="
for SVC in $SERVICES; do systemctl --no-pager -l status "$SVC" | head -5; done
grep -h "profiles are active" /var/log/messages 2>/dev/null | tail -5 || true
journalctl --no-pager -u ms-digitalfix-workorders | grep -E "profile|HikariPool|PostgreSQL" | tail -5 || true
echo "=== FIN $(date) ==="

# El log de diagnostico se deja de exponer 15 minutos despues del bootstrap
nohup bash -c 'sleep 900; pkill -f "http.server 8081"' >/dev/null 2>&1 &
