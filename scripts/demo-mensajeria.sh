#!/bin/bash
# DigitalFix - demostracion del flujo de mensajeria (EP3/EP4).
# Ejecutar EN LA EC2 de aplicaciones (los microservicios escuchan en localhost):
#   ssh -i digitalfix-key.pem ec2-user@<IP-apps>
#   ./demo-mensajeria.sh     (lo descarga el bootstrap en /home/ec2-user)
# En otra terminal, ver los consumidores en vivo:
#   journalctl -fu ms-digitalfix-notify -o cat
#
# 1) Flujo real: crea una orden y la lleva hasta CERRADA -> email, ticket y PDF.
# 2) Rutas de error: falla transitoria recuperada, reintentos agotados -> DLQ,
#    payload invalido -> DLQ inmediata, JSON roto -> DLQ inmediata.
# 3) Estado de colas y DLQ desde ms-digitalfix-rabbit-admin.
set -euo pipefail
WO=${WO:-http://localhost:8082}
ADMIN=${ADMIN:-http://localhost:8087}
# Dominio del tenant principal de Entra ID (lo escribe Apply-Tenants.ps1 en entra.env)
DOMINIO=${DOMINIO:-$(sed -n 's/^DIGITALFIX_DEMO_DOMAIN=//p' /etc/digitalfix/entra.env 2>/dev/null || true)}
DOMINIO=${DOMINIO:-digitalfix.local}
H=(-H "Content-Type: application/json" -H "X-User-Name: supervisor.demo@$DOMINIO" -H "X-User-Roles: Supervisor")
CLIENTE=cliente.demo@$DOMINIO
pausa() { echo; read -r -p ">> Enter para continuar ($1)" _; echo; }
jqget() { python3 -c "import sys,json; print(json.load(sys.stdin)$1)"; }

echo "=== 1. Flujo de una orden de trabajo ==="
ID=$(curl -s "${H[@]}" -X POST "$WO/api/workorders" \
  -d "{\"descripcion\":\"Demo EP4: falla en tablero electrico\",\"clienteId\":\"$CLIENTE\"}" | jqget "['id']")
echo "Orden #$ID creada (email.created -> q.cmd.email)"
pausa "asignar tecnico"
for ST in ASIGNADA EN_DESPLAZAMIENTO EN_EJECUCION CERRADA; do
  BODY="{\"status\":\"$ST\"$( [ "$ST" = ASIGNADA ] && echo ',"tecnicoId":"tecnico.demo"' || true)}"
  curl -s -o /dev/null -w "PUT status=$ST -> HTTP %{http_code}\n" "${H[@]}" -X PUT "$WO/api/workorders/$ID/status" -d "$BODY"
  sleep 1
done
echo "Esperado en notify: [EMAIL] x4, [TICKET] emitido + 3 avances, [PDF] certificado-orden-$ID.pdf"
pausa "rutas de error"

publish() { # $1=exchange $2=routingKey $3=body
  python3 - "$1" "$2" "$3" <<'PY' | curl -s -H "Content-Type: application/json" -X POST "$ADMIN/api/rabbit/messages" -d @- ; echo
import json,sys; print(json.dumps({"exchange":sys.argv[1],"routingKey":sys.argv[2],"body":sys.argv[3]}))
PY
}
envelope() { # $1=simulateFailure (opcional) $2=to
  python3 - "$1" "${2:-$CLIENTE}" <<'PY'
import json,sys,uuid,datetime
e={"type":"EMAIL","eventId":str(uuid.uuid4()),"timestamp":datetime.datetime.utcnow().isoformat()+"Z",
   "traceId":str(uuid.uuid4()),"correlationId":"demo-errores","source":"demo-mensajeria.sh",
   "payload":{"orderId":1,"to":sys.argv[2],"template":"ENROUTE","tecnicoId":"tecnico.demo","descripcion":"Prueba"}}
if sys.argv[1]: e["simulateFailure"]=sys.argv[1]
print(json.dumps(e))
PY
}

echo "=== 2a. Falla transitoria que se recupera (reintento -> ACK) ==="
publish cmd.topic email.enroute "$(envelope TRANSIENT_ONCE)"
sleep 4
echo "=== 2b. Falla transitoria persistente (3 intentos -> NACK -> q.cmd.email.dlq) ==="
publish cmd.topic email.enroute "$(envelope TRANSIENT)"
echo "=== 2c. Payload invalido (destinatario no es email -> NACK inmediato -> DLQ) ==="
publish cmd.direct email.send "$(envelope '' no-es-un-email)"
echo "=== 2d. JSON mal formado (NACK inmediato -> DLQ) ==="
publish cmd.direct email.send '{"type":"EMAIL", esto no es json'
echo "Esperando reintentos (2 s + 4 s)..."
sleep 8
pausa "estado de colas"

echo "=== 3. Colas y DLQ ==="
curl -s "$ADMIN/api/rabbit/queues" | python3 -c '
import sys,json
fmt="{:24} {:>7} {:>8} {:>7}  {}"
print(fmt.format("cola","listos","sin ack","consum","nodo"))
for q in json.load(sys.stdin):
    print(fmt.format(q["name"], q["messagesReady"], q["messagesUnacked"], q["consumers"], q["node"]))'
echo
echo "Mensajes en q.cmd.email.dlq (motivo y origen):"
curl -s "$ADMIN/api/rabbit/queues/q.cmd.email.dlq/messages?count=5" | python3 -c '
import sys,json
for m in json.load(sys.stdin):
    print("- origen={} motivo={} reintentos={} error={}".format(m["originalQueue"], m["deathReason"], m["retryCount"], m["lastError"]))'
