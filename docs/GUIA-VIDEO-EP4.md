# Guion del video — EP4 (≈ 9:50 minutos, sin audio)

El video se graba **sin audio** y se presenta en vivo hablando encima. Por eso cada bloque tiene:
**Pantalla** (qué debe verse), **Acciones** (clics exactos, lentos), **Decir** (lo que se explica en vivo,
2–4 frases) e **Indicador** de la pauta que cubre.

Reglas de grabación: zoom del navegador 110–125 %, mouse lento, **pausa de 3 s** en cada pantalla clave
(es el momento en que se habla), ventanas maximizadas, notificaciones de Windows desactivadas.

## Preparación (no sale en el video)

1. Learner Lab iniciado hace ≥ 3 min. `Verificar-Nube.ps1` y `Verificar-EC2.ps1` en verde.
2. Chrome, en este orden de pestañas (todas con sesión iniciada):
   1. App: https://main.dehlzhnwtqj7a.amplifyapp.com (ventana **incógnito** aparte, sin sesión)
   2. Consola AWS → EC2 → Instancias (región us-east-1)
   3. Consola AWS → API Gateway → `digitalfix-gw` (7s6qn2mb8h)
   4. Portal Azure → Microsoft Entra ID → **DigitalFix Kevin** → Información general
   5. RabbitMQ Management: http://100.49.181.187:15672 (usuario `digitalfix`; clave:
      `aws ssm get-parameter --name /digitalfix/mq/password --with-decryption --query Parameter.Value --output text`)
3. Windows Terminal, letra 16, 3 pestañas:
   - **A · ec2-mq**: `ssh -i digitalfix-key.pem ec2-user@100.49.181.187` → `cd /opt/digitalfix-infra/mq`
   - **B · logs**: `ssh -i digitalfix-key.pem ec2-user@18.210.44.145` → `sudo journalctl -fu ms-digitalfix-notify -o cat`
   - **C · apps**: `ssh -i digitalfix-key.pem ec2-user@18.210.44.145`
4. En la app (Admin) → Mensajería → vaciar `q.cmd.email.dlq` (X) para que el contador parta en 0.
5. VS Code abierto en la carpeta `digitalfix` (todos los repos) con 5 pestañas, en este orden:
   `ms-digitalfix-notify/.../application.yml`, `workorders/.../messaging/RabbitCommandPublisher.java`,
   `notify/.../RabbitTopologyConfig.java`, `notify/.../ManualAckProcessor.java`,
   `rabbit-admin/.../service/RabbitAdminService.java`. Tema oscuro, zoom `Ctrl +` dos veces.
6. Segunda ventana incógnito (sin sesión) para el bloque de roles, con la app abierta.

## Guion

### 1 · Presentación y arquitectura — 0:00 a 0:40
- **Pantalla:** app en incógnito, pantalla de login.
- **Acciones:** ninguna (pausa 5 s).
- **Decir:** "DigitalFix gestiona órdenes de mantención eléctrica. El frontend Angular está en AWS Amplify y
  autentica con Microsoft Entra ID. Cada llamada pasa por AWS API Gateway, que valida el JWT, hacia un BFF en
  Spring Boot y luego a los microservicios en EC2. En esta entrega agregamos RabbitMQ: el microservicio de órdenes
  publica comandos y el de notificaciones los consume de forma asíncrona."
- **Indicador:** hilo conductor / lenguaje técnico.

### 2 · Nube activa — 0:40 a 1:10
- **Pantalla:** consola EC2 → Instancias.
- **Acciones:** mostrar `digitalfix-v8` (t3.medium) y `digitalfix-mq-…` (t3.small) en *Running*; pasar el mouse
  sobre las IP elásticas.
- **Decir:** "Tenemos dos EC2: la de aplicaciones con los 7 microservicios como servicios systemd, y `ec2-mq`
  dedicada a RabbitMQ. Las apps se comunican con RabbitMQ por la IP privada de la VPC; AMQP no está expuesto a
  Internet, solo al Security Group de las apps."
- **Indicador:** frontend y backend desplegados y activos.

### 3 · IDaaS: tenant y usuarios — 1:10 a 1:50
- **Pantalla:** Entra ID → DigitalFix Kevin.
- **Acciones:** Información general (Id. de inquilino) → **Usuarios** (los 4 demo) → **Registros de aplicaciones**
  → `digitalfix-api` → *Exponer una API* (scope `access_as_user`) → *Roles de aplicación* (4 roles) →
  `digitalfix-frontend` → *Autenticación* (plataforma **SPA** con las 2 redirect URI).
- **Decir:** "Este es nuestro tenant de Entra ID con cuatro usuarios, uno por rol. Registramos dos aplicaciones:
  la SPA, que es un cliente público sin secreto, y la API, que expone el scope `access_as_user` y define los
  App Roles. Los roles viajan en el claim `roles` del access token y el backend autoriza con ellos."
- **Indicador:** tenant IDaaS con usuarios registrados.

### 4 · Login con Authorization Code + PKCE — 1:50 a 2:30
- **Pantalla:** app en incógnito.
- **Acciones:** clic **Continuar con Microsoft** → (pausa en la URL de login: se ve `code_challenge` y
  `code_challenge_method=S256`) → `admin.demo@digitalfixkevin.onmicrosoft.com` → Dashboard →
  menú **Mi sesión y token**.
- **Decir:** "MSAL genera un code_verifier aleatorio y envía solo su hash SHA-256; Entra devuelve un código que
  solo sirve junto al verifier, así un código interceptado no sirve. En *Mi sesión* se ve el token: issuer de
  nuestro tenant, audience de la API, scope y el rol Admin."
- **Indicador:** login OIDC con PKCE y JWT válido.

### 5 · API Manager y validación del JWT — 2:30 a 3:10
- **Pantalla:** API Gateway `digitalfix-gw` → *Routes* → *Authorization* → *CORS*; luego la app.
- **Acciones:** mostrar rutas (incluye `/api/rabbit/*`), el authorizer `entra-id-jwt` (issuer y audience), CORS
  (solo Amplify y localhost). En la app → *Mi sesión* → **Probar rutas del Gateway**.
- **Decir:** "El API Gateway es nuestro API Manager: cada ruta exige un JWT emitido por nuestro tenant, para
  nuestra API y con el scope correcto. Sin token responde 401 sin tocar el backend; el BFF vuelve a validar firma,
  vigencia y audience, y aplica el rol: defensa en profundidad."
- **Indicador:** API Manager activo, CORS, JWT válido aceptado / inválido rechazado.

### 6 · Roles (RBAC) — 3:10 a 3:40
- **Pantalla:** segunda ventana incógnito.
- **Acciones:** login con `supervisor.demo@digitalfixkevin.onmicrosoft.com` → mostrar que el menú no tiene
  *Mensajería* → escribir `/messaging` en la URL → aparece el aviso **"Tu rol no tiene acceso"** y vuelve al
  Dashboard → *Mi sesión*: claim `roles` = Supervisor. Cerrar la ventana.
- **Decir:** "Cada usuario recibe su rol desde Entra ID. El supervisor no ve la administración de mensajería; y
  aunque escriba la URL, el guard del frontend lo bloquea. Lo importante es que el backend también lo rechaza:
  el BFF responde 403 a `/api/rabbit` para cualquier rol distinto de Admin."
- **Indicador:** roles del IDaaS aplicados en frontend y backend.

### 7 · docker compose y clúster de 2 nodos — 3:40 a 4:20
- **Pantalla:** terminal A.
- **Acciones:** `cat compose.yml` → `docker compose ps` → `docker exec rabbit1 rabbitmqctl cluster_status`
  (bajar hasta *Running Nodes*) → RabbitMQ Management → *Overview* → sección **Nodes** (rabbit1 y rabbit2 en verde).
- **Decir:** "En `ec2-mq` RabbitMQ se levanta con docker compose: dos nodos con la misma cookie de Erlang que
  forman un clúster. `cluster_status` muestra rabbit1 y rabbit2 en ejecución. La topología se replica con Khepri,
  así que ambos nodos conocen todas las colas."
- **Indicador:** docker compose en la nube · 2 nodos en clúster.

### 8 · Topología: exchanges, colas y DLQ — 4:20 a 5:00
- **Pantalla:** app → **Mensajería** (topología en vivo); luego RabbitMQ Management → *Exchanges* y *Queues*.
- **Acciones:** pausa sobre la topología → pestañas *Exchanges* y *Bindings* → en RabbitMQ UI abrir `q.cmd.email`
  (args `x-dead-letter-exchange`).
- **Decir:** "Tres colas de trabajo — email, despacho y reporte — cada una con su DLQ. Usamos un exchange
  **direct** para comandos con clave exacta y uno **topic** para patrones como `email.*`. Si un mensaje se
  rechaza, la cola lo envía al exchange `cmd.dead.dlx` y termina en su DLQ."
- **Indicador:** 3 colas con DLQ · exchanges direct y topic.

### 9 · Flujo real de una orden — 5:00 a 6:00
- **Pantalla:** app (izquierda) + terminal B con logs (derecha).
- **Acciones:** *Órdenes de trabajo* → crear "Falla en tablero eléctrico" con cliente
  `cliente.demo@digitalfixkevin.onmicrosoft.com` → **Asignar técnico** (`tecnico.demo`) → **Enviar a terreno** →
  **Iniciar trabajo** → **Cerrar orden**. Mirar el log en cada paso.
- **Decir:** "Al guardar el cambio de estado, workorders publica el comando después del commit de la transacción.
  En los logs vemos al consumidor: email al cliente, ticket de despacho y, al cerrar, el certificado PDF. Cada
  mensaje termina con su ACK."
- **Indicador:** integración y funcionamiento · logs en vivo.

### 10 · Reintentos y DLQ — 6:00 a 7:00
- **Pantalla:** app → Mensajería + terminal B.
- **Acciones:** **Publicar prueba** → escenario *Falla 1 vez y se recupera* → Publicar (log: REINTENTO → ACK) →
  *Falla transitoria persistente* → Publicar (3 intentos → NACK→DLQ; contador **En DLQ** sube a 1) →
  clic en `q.cmd.email.dlq` (motivo, reintentos, error) → **Reprocesar**.
- **Decir:** "Un error transitorio se reintenta y se recupera. Si persiste, después de tres intentos el mensaje
  no se pierde: queda en la DLQ con el motivo y el último error. Desde el panel lo podemos revisar sin
  consumirlo y reprocesarlo cuando el problema esté corregido."
- **Indicador:** DLQ funcionando · ACK/NACK.

### 11 · Consumidor caído (desacoplamiento) — 7:00 a 7:40
- **Pantalla:** terminal C + app Mensajería.
- **Acciones:** `sudo systemctl stop ms-digitalfix-notify` → en la app crear una orden → topología: consumidores en
  rojo y *Pendientes* sube → `sudo systemctl start ms-digitalfix-notify` → pendientes vuelven a 0 (log en B).
- **Decir:** "Si el servicio de notificaciones se cae, las órdenes se siguen creando: los mensajes esperan en la
  cola. Cuando vuelve, los procesa. Ese es el beneficio del desacoplamiento asíncrono."
- **Indicador:** robustez / mensajería asíncrona.

### 12 · Microservicio administrador — 7:40 a 8:20
- **Pantalla:** app → Mensajería.
- **Acciones:** **Nueva cola** `q.demo.video` con DLQ → pestaña Bindings → **Nuevo binding** `cmd.topic` →
  `demo.#` → Publicar prueba a `cmd.topic` / `demo.alerta` (Enrutado) → eliminar la cola (diálogo de confirmación)
  → intentar crear otra vez `q.cmd.email` (el servicio responde **409**: ya existe) → mostrar que el tacho de
  `q.cmd.email` está deshabilitado (protegida).
- **Decir:** "ms-digitalfix-rabbit-admin centraliza la administración: crea y elimina colas, exchanges y bindings
  validando los datos, y protege los recursos del sistema. Solo el rol Admin accede, validado en el Gateway y en
  el BFF."
- **Indicador:** microservicio administrador.

### 13 · Código — 8:20 a 9:20
- **Pantalla:** VS Code (pestañas en el orden de la preparación).
- **Acciones:** 10–12 s por pestaña, señalando con el mouse la línea clave:
  `application.yml` (nombres de colas/exchanges) → `RabbitCommandPublisher` (publica tras el commit) →
  `RabbitTopologyConfig` (`x-dead-letter-exchange` de cada cola) → `ManualAckProcessor` (bucle de reintentos,
  `basicAck` / `basicNack(requeue=false)`) → `RabbitAdminService` (validación de nombres, recursos protegidos → 409).
- **Decir:** "Los nombres viven en configuración, no en el código. El publicador envía el comando solo cuando la
  transacción se confirmó, para no notificar algo que no se guardó. Cada cola declara su DLX. El consumidor usa
  ACK manual: éxito → ACK; error recuperable → reintento con espera creciente hasta 3 veces; error permanente o
  intentos agotados → NACK sin reencolar y va a la DLQ. Es idempotente por `eventId`. El administrador valida y
  protege los recursos del sistema."
- **Indicador:** justificación técnica.

### 14 · Cierre — 9:20 a 9:50
- **Pantalla:** app → Dashboard (o topología).
- **Decir:** "En resumen: identidad con Entra ID y PKCE, API Gateway validando JWT, microservicios en EC2 y
  mensajería con RabbitMQ en clúster, con reintentos y DLQ. Como mejora usaríamos tres nodos con quorum queues
  para tolerar la caída de un nodo, y el patrón outbox para garantizar la publicación."

## Si algo falla en vivo

```bash
# ec2-mq (A)
docker compose ps
docker exec rabbit1 rabbitmqctl list_queues name messages consumers
# apps (C)
systemctl status ms-digitalfix-notify ms-digitalfix-workorders ms-digitalfix-rabbit-admin --no-pager
./demo-mensajeria.sh        # demo completa por terminal (Enter para avanzar)
```

## Checklist de la pauta

- [ ] API Manager activo · CORS · front consume vía gateway (bloques 5 y 9)
- [ ] JWT válido aceptado / inválido rechazado (bloque 5)
- [ ] Tenant IDaaS con usuarios · login OIDC con PKCE (bloques 3 y 4)
- [ ] Front y back desplegados e integrados (bloques 2 y 9)
- [ ] 2 nodos RabbitMQ en clúster con docker compose (bloque 7)
- [ ] 3 colas con DLQ · exchanges direct y topic (bloque 8)
- [ ] Logs en vivo: flujo, ACK/NACK, DLQ (bloques 9 y 10)
- [ ] Roles del IDaaS en frontend y backend (bloque 6)
- [ ] Microservicio administrador y código justificado (bloques 12 y 13)
