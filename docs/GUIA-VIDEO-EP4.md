# Guion del video — EP4 (5 a 10 minutos)

Video **continuo**, con la terminal visible y logs en vivo. Objetivo: ~8 min. Cada bloque indica qué
indicador de la pauta cubre. Ensayar una vez completo antes de grabar.

## Preparación (antes de grabar, no sale en el video)

1. Iniciar el Learner Lab y esperar 3 min. Verificar:
   `https://7s6qn2mb8h.execute-api.us-east-1.amazonaws.com/actuator/health` → `UP`.
2. Abrir pestañas: consola AWS (EC2, API Gateway), portal Entra ID (tenant), app en Amplify,
   RabbitMQ UI `http://<IP-mq>:15672`, VS Code con `ms-digitalfix-notify`.
3. Terminales (Windows Terminal, 3 paneles, letra grande):
   - **A — ec2-mq:** `ssh -i digitalfix-key.pem ec2-user@<IP-mq>` → `cd /opt/digitalfix-infra/mq`
   - **B — apps, logs:** `ssh -i digitalfix-key.pem ec2-user@18.210.44.145` → `journalctl -fu ms-digitalfix-notify -o cat`
   - **C — apps, demo:** misma EC2 → `./demo-mensajeria.sh` (aún sin ejecutar)
4. Vaciar las DLQ desde la pantalla *Mensajería* para partir de cero.

## Guion

| Min | Bloque | Qué se muestra | Indicador |
|---|---|---|---|
| 0:00 | Intro (Kevin) | Arquitectura: Angular → API Gateway → BFF → microservicios; workorders publica, notify consume, rabbit-admin administra; RabbitMQ en `ec2-mq` | Hilo conductor |
| 0:45 | Nube activa | Consola EC2: instancias apps y `ec2-mq` *running*; Amplify con la URL | Front y back desplegados |
| 1:15 | IDaaS | Entra ID: tenant, App registrations, usuarios demo con App Roles | Tenant + usuarios |
| 1:45 | Login | Iniciar sesión en Amplify (Authorization Code + PKCE); pantalla *Mi sesión*: claims y token | OAuth 2.0 / OIDC |
| 2:15 | API Manager | API Gateway: rutas (incluye `/api/rabbit/*`), JWT Authorizer, CORS. *Mi sesión* → probador: sin token 401, token válido 200 | API Manager + JWT |
| 3:00 | docker compose (terminal A) | `cat compose.yml` (2 servicios) → `docker compose ps` (healthy) → `docker exec rabbit1 rabbitmqctl cluster_status` (2 nodos *Running*) | docker-compose en la nube + 2 nodos en clúster |
| 3:45 | Topología | UI RabbitMQ *Overview* (2 nodos) → *Exchanges* `cmd.direct` (direct), `cmd.topic` (topic), `cmd.dead.dlx` → *Queues*: 3 colas + 3 DLQ con `DLX`/`DLK` | 3 colas + DLQ, direct y topic |
| 4:30 | Código (VS Code, rápido) | `application.yml` (nombres centralizados) → `RabbitTopologyConfig` (beans por caso de uso) → `ManualAckProcessor` (tabla de decisiones) | Justificación técnica |
| 5:15 | Flujo real (terminal C, logs en B) | `./demo-mensajeria.sh`, bloque 1: crear y cerrar una orden. En B: `[ACK]`, `[EMAIL]`, `[TICKET]`, `[PDF]` | Integración y funcionamiento |
| 6:15 | Rutas de error (C + B) | Bloque 2: `TRANSIENT_ONCE` → `[REINTENTO]` → `[ACK]`; `TRANSIENT` → 3 intentos → `[NACK->DLQ]`; email inválido y JSON roto → `[NACK->DLQ]` inmediato | DLQ funcionando, ACK/NACK |
| 7:15 | DLQ en la app (Admin) | Pantalla *Mensajería*: `q.cmd.email.dlq` con mensajes → *Ver* (origen, motivo, reintentos) → *Reprocesar* | Administrador + DLQ |
| 7:45 | Administrador | Crear cola `q.demo.video` con DLQ, binding en `cmd.topic`, publicar → eliminar. Intentar nombre `amq.x` → 400; borrar `q.cmd.email` → 409 | API REST + validación |
| 8:30 | Cierre (Boris) | Resumen de decisiones: por qué RabbitMQ, ACK manual, 2 nodos, mejoras (quorum con 3 nodos, outbox) | Lenguaje técnico |

## Comandos de respaldo (si algo falla en vivo)

```bash
# ec2-mq
docker compose logs --tail 50 rabbit2
docker exec rabbit1 rabbitmqctl list_queues name messages consumers
docker exec rabbit1 rabbitmqctl list_bindings source_name routing_key destination_name

# apps
systemctl status ms-digitalfix-notify ms-digitalfix-workorders ms-digitalfix-rabbit-admin --no-pager
curl -s localhost:8086/api/notify/activity | python3 -m json.tool | head -40
ls -l /var/lib/digitalfix/reports/
```

**Consumidor caído (opcional, recomendado):** en B `Ctrl+C` y `sudo systemctl stop ms-digitalfix-notify` →
en la app crear y asignar una orden (cliente con correo válido) → en A
`docker exec rabbit1 rabbitmqctl list_queues name messages consumers`: `q.cmd.email` y `q.cmd.dispatch` con mensajes
y **0 consumidores** (esperan, no se pierden) → en B `sudo systemctl start ms-digitalfix-notify` y
`journalctl -fu ms-digitalfix-notify -o cat`: al reconectar procesa lo pendiente (`[EMAIL]`, `[TICKET]`, `[ACK]`).

**Recordatorio de terminales:** A = ec2-mq (`ec2-user@100.49.181.187`, prompt `ip-172-31-37-75`, aquí van los comandos
`docker`); B y C = apps (`ec2-user@18.210.44.145`, prompt `ip-172-31-37-120`, aquí van `systemctl`, `journalctl` y
`./demo-mensajeria.sh`). En la app, usar siempre un correo válido como cliente (si no, los emails van a la DLQ por validación).

**Failover (opcional, si sobra tiempo):** en A `docker compose stop rabbit2` → `cluster_status` muestra un nodo
caído → crear y avanzar una orden: se publica y se consume igual → `docker compose start rabbit2` → el nodo se
reintegra. Si preguntan: con 1 de 2 nodos no se pueden crear colas (Khepri/Raft necesita mayoría); por eso con
3 nodos se usarían quorum queues.

## Checklist de la pauta

- [ ] API Manager creado y activo · configuración hacia el backend · front consume vía gateway
- [ ] JWT válido aceptado / inválido rechazado
- [ ] Tenant IDaaS y usuarios · login OIDC con PKCE y JWT válido
- [ ] Front y back desplegados, activos e integrados
- [ ] 2 nodos RabbitMQ en clúster
- [ ] 3 colas con sus DLQ funcionando
- [ ] Exchanges direct y topic
- [ ] docker compose levantando RabbitMQ en la nube
- [ ] Terminal con logs en vivo: flujo, ACK, estado de contenedores y colas
