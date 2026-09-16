#!/bin/bash
# DigitalFix - bootstrap EC2 (Amazon Linux 2023, t3.micro)
# Levanta 5 servicios Spring Boot en el mismo host:
#   8080 ms-digitalfix-bff        (UNICO puerto abierto en el SG, lo consume API Gateway)
#   8082 ms-digitalfix-workorders (interno)
#   8083 ms-digitalfix-catalog    (interno)
#   8084 ms-digitalfix-report     (interno)
#   8085 ms-digitalfix-audit      (interno)
exec > >(tee /var/log/setup-debug.log) 2>&1
set -x

# Log de bootstrap visible via http://<ip>:8081/setup-debug.log (solo diagnostico)
mkdir -p /var/www-debug
ln -sf /var/log/setup-debug.log /var/www-debug/setup-debug.log
(cd /var/www-debug && nohup python3 -m http.server 8081 > /var/log/httpserver.log 2>&1 &)

echo "=== INICIO $(date) ==="

# --- Swap de 2 GB: 5 JVMs + Maven no caben en 1 GB de RAM ---
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile swap swap defaults 0 0' >> /etc/fstab
fi

dnf install -y java-17-amazon-corretto-devel git maven

GH=https://github.com/DigitalFix-Grupo12
APP_DIR=/opt/digitalfix
mkdir -p "$APP_DIR"
export HOME=/root
export MAVEN_OPTS="-Xmx384m"

# Orden de arranque: audit primero (workorders le publica eventos),
# luego workorders (report lo consulta), y el BFF al final.
SERVICES="ms-digitalfix-audit ms-digitalfix-catalog ms-digitalfix-workorders ms-digitalfix-report ms-digitalfix-bff"

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

write_unit ms-digitalfix-audit      ""                                  ""
write_unit ms-digitalfix-catalog    ""                                  ""
write_unit ms-digitalfix-workorders "ms-digitalfix-audit.service"       "Environment=AUDIT_URL=http://localhost:8085"
write_unit ms-digitalfix-report     "ms-digitalfix-workorders.service"  "Environment=WORKORDERS_URL=http://localhost:8082"
write_unit ms-digitalfix-bff        "ms-digitalfix-workorders.service" "Environment=AZURE_TENANT_ID=ac1c32f1-bc10-4ded-b8c0-102ac9a1fd68
Environment=AZURE_API_CLIENT_ID=fb8ea665-ee45-4790-8112-eade3bd230e5
Environment=DIGITALFIX_SECURITY_ALLOWED_ORIGINS=http://localhost:4200"

systemctl daemon-reload
# Arranque escalonado para no saturar la CPU (t3.micro = 2 vCPU burstable)
for SVC in $SERVICES; do
  systemctl enable --now "$SVC"
  sleep 20
done

sleep 30
echo "=== HEALTH ==="
for PORT in 8085 8083 8082 8084 8080; do
  echo -n "$PORT -> "; curl -s -m 5 "http://localhost:$PORT/actuator/health" || echo "sin respuesta"
  echo
done
free -m
echo "=== SYSTEMD STATUS ==="
for SVC in $SERVICES; do systemctl --no-pager -l status "$SVC" | head -5; done
echo "=== FIN $(date) ==="
