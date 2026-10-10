#!/bin/bash
# DigitalFix - bootstrap EC2 ec2-mq (Amazon Linux 2023, t3.small)
# Levanta con docker compose el cluster RabbitMQ de 2 nodos (digitalfix-infra/mq/compose.yml).
#   rabbit1: AMQP 5672 | Management UI 15672
#   rabbit2: AMQP 5673 | Management UI 15673
# Credenciales y cookie de Erlang desde SSM Parameter Store (nunca en el repo).
exec > >(tee /var/log/setup-mq.log) 2>&1
set -x
echo "=== INICIO $(date) ==="

dnf install -y docker git
systemctl enable --now docker
usermod -aG docker ec2-user

# Plugin docker compose v2 (Amazon Linux no lo trae en sus repos)
mkdir -p /usr/local/lib/docker/cli-plugins
curl -sSL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
docker compose version

REGION=us-east-1
ssm() { aws ssm get-parameter --region "$REGION" --name "$1" $2 --query Parameter.Value --output text; }

INFRA=/opt/digitalfix-infra
rm -rf "$INFRA"
git clone --depth 1 https://github.com/DigitalFix-Grupo12/digitalfix-infra.git "$INFRA"
cd "$INFRA/mq"

set +x
umask 077
cat > .env <<ENV
RABBITMQ_USER=$(ssm /digitalfix/mq/username)
RABBITMQ_PASS=$(ssm /digitalfix/mq/password --with-decryption)
RABBITMQ_ERLANG_COOKIE=$(ssm /digitalfix/mq/erlang-cookie --with-decryption)
ENV
umask 022
set -x
chown -R ec2-user:ec2-user "$INFRA"

docker compose up -d

# Esperar a que ambos nodos esten healthy (max ~4 min)
for i in $(seq 1 48); do
  HEALTHY=$(docker compose ps --format '{{.Health}}' | grep -c healthy || true)
  [ "$HEALTHY" -ge 2 ] && break
  sleep 5
done
docker compose ps
docker exec rabbit1 rabbitmqctl cluster_status
echo "=== FIN $(date) ==="
