# Decisiones técnicas — DigitalFix

Registro breve de las decisiones de arquitectura: qué se eligió, por qué y qué se descartó.
Sirve como apoyo para justificar la solución en la presentación (EP2).

## 1. Login con Authorization Code + PKCE (MSAL)

- **Decisión:** el SPA Angular usa `@azure/msal-angular` con el flujo Authorization Code + PKCE (S256).
- **Por qué:** una SPA no puede guardar un *client secret*. PKCE reemplaza el secreto por un
  `code_verifier` aleatorio que solo conoce el navegador que inició el login, así un código
  interceptado no sirve. Es el flujo recomendado por OAuth 2.1 para aplicaciones públicas.
- **Descartado:** flujo implícito (entrega el token en la URL y ya no se recomienda).

## 2. Microsoft Entra ID como IDaaS

- **Decisión:** un tenant propio por integrante (Kevin y Boris), configurados de forma idéntica con
  `scripts/Setup-EntraTenant.ps1`. Cada tenant tiene dos registros de aplicación:
  `digitalfix-frontend` (SPA) y `digitalfix-api` (API protegida con el scope `access_as_user`). Ver §16.
- **Por qué:** usuarios, contraseñas, MFA y registro de cuentas quedan fuera de nuestro código.
  Los permisos se modelan como **App Roles** (Admin, Supervisor, Cliente, Auditor) que viajan en el claim `roles`.
- **Sin rol no hay acceso:** un usuario autorregistrado ve "Sin rol asignado" hasta que un administrador le asigna uno.

## 3. AWS API Gateway (HTTP API) como API Manager

- **Decisión:** HTTP API con **JWT Authorizer** (issuer y audiencia de Entra ID), rutas explícitas y CORS
  limitado al origen local y al de Amplify.
- **Por qué:** rechaza tokens ausentes o inválidos (401) antes de llegar a la EC2, centraliza CORS y
  es más simple y barato que una REST API para un proxy HTTP.
- **Descartado:** REST API con Lambda authorizer (más código y más costo sin beneficio para este caso).

## 4. BFF que vuelve a validar el token

- **Decisión:** `ms-digitalfix-bff` valida firma (JWKS), vigencia, emisor y **audiencia** del JWT y autoriza por rol.
- **Por qué:** defensa en profundidad. Si alguien llegara al puerto 8080 sin pasar por el gateway, el token
  igual se valida. Spring no valida `aud` por defecto, por eso existe `JwtAudienceValidator`:
  sin él, un token de otra aplicación del mismo tenant sería aceptado.
- El BFF es el único servicio expuesto; los microservicios de dominio escuchan solo en la red interna del host.

## 5. Autorización a nivel de dato

- **Decisión:** el BFF propaga `X-User-Name` y `X-User-Roles`; `ms-digitalfix-workorders` limita al rol Cliente
  a sus propias órdenes.
- **Por qué:** el rol decide *qué rutas* se pueden usar, pero no *qué registros*. Una orden ajena responde **404**
  (no **403**) para no revelar que existe.

## 6. Microservicios por dominio

| Servicio | Responsabilidad | Motivo de separarlo |
|---|---|---|
| workorders | Órdenes y máquina de estados | Núcleo del negocio, reglas de transición (409 si el salto no es válido) |
| catalog | Servicios y repuestos | Datos de referencia con otro ritmo de cambio |
| report | KPIs | Solo lectura; calcula desde workorders sin duplicar datos |
| audit | Registro append-only | Trazabilidad independiente; si falla, no bloquea la operación (*best effort*) |

## 7. Base de datos: RDS PostgreSQL con un schema por servicio

- **Decisión:** una instancia RDS privada y un schema por microservicio (`workorders`, `catalog`, `audit`).
- **Por qué:** cada servicio es dueño de sus tablas sin pagar varias instancias en el Learner Lab.
  Perfil `cloud` en la EC2 y H2 en memoria para desarrollo y tests.
- **Seguridad:** sin IP pública, acceso solo desde el Security Group de la EC2, `sslmode=require`,
  cifrado en reposo y credenciales en SSM Parameter Store (nunca en el repositorio).

## 8. Despliegue

| Componente | Servicio | Motivo |
|---|---|---|
| Frontend | AWS Amplify | HTTPS incluido y despliegue por zip; CloudFront está bloqueado en el Learner Lab |
| Backend | EC2 t3.medium + IP elástica | Requisito del curso; la IP no cambia al reiniciar el lab (t3.micro en la EP2; 7 JVM desde la EP3) |
| Mensajería | EC2 `ec2-mq` t3.small + docker compose | Clúster RabbitMQ de 2 nodos separado de las apps (caso, sección 7) |
| Servicios | systemd | Arranque automático y reinicio ante fallos |
| Memoria | `-Xmx` acotado + swap de 2 GB | Siete JVM con heap acotado (160 MB c/u) |

Todo el aprovisionamiento está en scripts idempotentes (`scripts/`) para poder recrear el entorno cuando el lab expira.

## 9. Calidad

- Tests automáticos en cada microservicio (seguridad del BFF, máquina de estados, propiedad de órdenes,
  catálogo, auditoría y KPIs), ejecutados en cada push con **GitHub Actions**.
- Colección Postman con pruebas de 401/403/200/409 y el checklist de [pruebas manuales](PRUEBAS-MANUALES.md).

---

# Capa de mensajería (EP3 / EP4)

## 10. RabbitMQ para tareas asíncronas

- **Decisión:** las notificaciones al cliente, el ticket de despacho y el PDF del certificado se envían como
  **comandos asíncronos** por RabbitMQ en vez de llamadas HTTP.
- **Por qué:** cambiar el estado de una orden no debe esperar ni fallar porque el correo o el PDF tardan.
  `ms-digitalfix-workorders` publica y responde; `ms-digitalfix-notify` procesa a su ritmo y, si está caído,
  los mensajes esperan en la cola (desacople temporal).
- **Kafka** queda para la evaluación de streaming (auditoría y KPIs), como indica el caso.

## 11. Topología (caso, sección 8)

| Elemento | Nombre | Tipo / uso |
|---|---|---|
| Exchange | `cmd.direct` | direct: comandos con clave exacta (`email.send`, `dispatch.ticket`, `report.gen`) |
| Exchange | `cmd.topic` | topic: eventos por patrón (`email.*`, `dispatch.#`, `report.*`) |
| Exchange | `cmd.dead.dlx` | direct: dead-letter exchange, enruta cada rechazo a su DLQ |
| Colas | `q.cmd.email`, `q.cmd.dispatch`, `q.cmd.report` | durables, con `x-dead-letter-exchange` y `x-dead-letter-routing-key` |
| DLQ | `q.cmd.email.dlq`, `q.cmd.dispatch.dlq`, `q.cmd.report.dlq` | mensajes que no se pudieron procesar |

- Los nombres viven **solo** en `application.yml` (`digitalfix.rabbitmq`), enlazados a records
  `@ConfigurationProperties` validados al arrancar (si falta una ruta el servicio no levanta).
- `ms-digitalfix-notify` (consumidor) es el **dueño** de colas, DLQ y bindings; `workorders` (productor) solo
  declara los exchanges. Declarar es idempotente, así el orden de arranque no importa.
- Se usan **los dos tipos de exchange**: emails y avances van por `cmd.topic` (una familia de eventos con un
  patrón); ticket y PDF van por `cmd.direct` (comandos puntuales).

## 12. Confirmación manual (ACK) y manejo de errores

- **Decisión:** `AcknowledgeMode.MANUAL` y una única política (`ManualAckProcessor`) para todos los consumidores.
- **Rutas diferenciadas:**
  - OK → `basicAck`.
  - Error **no recuperable** (JSON roto, payload inválido, tipo desconocido) → `basicNack(requeue=false)` →
    el broker lo mueve a la DLQ. Reintentar no lo arreglaría.
  - Error **recuperable** (timeout, IO) → reintento con espera creciente (2 s, 4 s) republicando una copia con
    `x-retry-count`; al tercer intento → `basicNack(requeue=false)` → DLQ con `x-last-error`.
- **Descartado:** `basicNack(requeue=true)`: reencola al instante sin contar intentos y genera un bucle infinito
  con un mensaje "veneno".
- **Idempotencia:** RabbitMQ entrega *al menos una vez*; el consumidor recuerda los `eventId` procesados y
  confirma los duplicados sin repetir el envío.
- **DLQ observable:** el rechazo queda en el log (`[NACK->DLQ]` con motivo), `DeadLetterMonitor` informa la
  profundidad de cada DLQ y el administrador permite leerlas y **reprocesarlas** a su cola de origen.

## 13. Productor confiable

- Publicación **después del commit** (`@TransactionalEventListener(AFTER_COMMIT)`): nunca se notifica una orden
  que no quedó guardada. El servicio de negocio solo emite un evento de dominio de Spring.
- Mensajes persistentes, JSON con envelope común (`type`, `eventId`, `timestamp`, `traceId`, `correlationId`),
  `messageId = eventId`, *publisher confirms* y *returns* (mensaje sin cola destino) registrados en el log.
- Si RabbitMQ no responde, la orden se guarda igual y queda `[NO-PUBLICADO]` en el log.
  Mejora futura: patrón *outbox* para reenviar automáticamente.

## 14. Clúster de 2 nodos con docker compose

- `rabbit1` y `rabbit2` (`rabbitmq:4.2-management`) con el mismo cookie de Erlang y descubrimiento
  `classic_config`: al arrancar, `rabbit2` se une a `rabbit1`.
- Las apps se conectan a **ambos nodos** (`spring.rabbitmq.addresses`); si uno cae, reconectan al otro.
- RabbitMQ 4.2 guarda los metadatos (colas, exchanges, bindings, usuarios) en **Khepri**, replicado con
  Raft. Con 2 nodos, si uno cae **la mensajería sigue funcionando** (probado: con `rabbit2` detenido se creó y
  asignó una orden, y notify consumió y confirmó todo), pero los **cambios de topología** (crear/borrar colas)
  quedan bloqueados hasta que vuelva el otro nodo: Raft necesita mayoría (2 de 2). El administrador responde
  502 en ese caso. Al volver el nodo, se reintegra solo.
- Colas **clásicas durables**: las *quorum queues* también usan Raft y con 2 nodos no toleran la caída de uno;
  con 3 nodos se migrarían a quorum queues y Khepri toleraría la caída de un nodo.
- EC2 propia `ec2-mq` (t3.small) como pide el caso; AMQP solo accesible desde el Security Group de las apps,
  credenciales y cookie en SSM Parameter Store.

## 15. Microservicio administrador

- `ms-digitalfix-rabbit-admin`: API REST (`/api/rabbit/queues|exchanges|bindings|messages`) con toda la lógica en
  `RabbitAdminService`; los controladores no conocen RabbitMQ.
- Crear/eliminar por AMQP (`AmqpAdmin`); consultas, lectura sin consumir y publicación con `routed` por la
  Management API (URL de ambos nodos con failover).
- Validación con DTO + Bean Validation y errores RFC 7807; recursos del sistema (`cmd.*`, `q.cmd.*`) protegidos.
- Expuesto solo al rol **Admin** (JWT en API Gateway + rol en el BFF) y con pantalla *Mensajería* en Angular.

## 16. Dos tenants de Entra ID sobre la misma nube

- **Decisión:** el sistema acepta usuarios de los dos tenants (Kevin y Boris). El login de Angular ofrece
  un selector de tenant; MSAL se configura con el `clientId`/`tenantId` del tenant elegido.
- **API Manager:** un HTTP API por tenant (`digitalfix-gw` y `digitalfix-gw-boris`) porque el JWT authorizer de
  API Gateway admite **un solo issuer**. Ambos tienen las mismas rutas, scope `access_as_user` y CORS, y
  apuntan al mismo BFF. El frontend usa el gateway del tenant activo.
- **BFF:** `JwtIssuerAuthenticationManagerResolver` con lista cerrada de issuers (`MultiTenantJwtResolver`).
  Lee el `iss` del token, rechaza (401) cualquier tenant no configurado y valida con el decoder de ese tenant:
  firma con sus claves JWKS, expiración, issuer exacto y `aud` = client ID de su `digitalfix-api`.
  Los IDs llegan por `AZURE_TENANT_ID[_2]` / `AZURE_API_CLIENT_ID[_2]` desde SSM (`/digitalfix/entra/bff-env`).
- **Descartado:** app multi-tenant con authority `organizations` (aceptaría cualquier tenant de Microsoft y
  los App Roles de cada tenant no se compartirían) y Lambda authorizer (más código y latencia para
  algo que dos authorizers nativos resuelven).
- **Fuente única:** `config/tenants.json`; `scripts/Apply-Tenants.ps1` propaga los IDs a SSM, gateways,
  BFF en EC2 y `frontend-digitalfix/src/app/core/config/tenants.ts`.
