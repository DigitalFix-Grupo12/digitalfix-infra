# Guía de entorno común — EP3 / EP4 (mensajería)

El docente sorteará a un integrante en clase para revisar su entorno: **Kevin y Boris deben tener
exactamente esta configuración**. Esta guía es la referencia; si algo difiere, se corrige aquí primero.

## 1. Software (mismas versiones)

| Herramienta | Versión | Verificar |
|---|---|---|
| JDK | 17 (Temurin o Corretto) | `java -version` |
| Maven | 3.9.x | `mvn -v` |
| Docker Desktop | 4.x con Compose v2 | `docker compose version` |
| Node.js | 22.22+ o 24.x (Angular 22) | `node -v` |
| Angular CLI | 22.x | `ng version` |
| AWS CLI | v2 | `aws --version` |
| Git | 2.4x | `git --version` |

## 2. Carpeta y repos

```
C:\Users\<usuario>\Documents\digitalfix\
├── digitalfix-infra\            mq\compose.yml · scripts\ · docs\
├── frontend-digitalfix\
├── ms-digitalfix-bff\
├── ms-digitalfix-workorders\    productor RabbitMQ
├── ms-digitalfix-notify\        consumidor RabbitMQ (dueño de colas y DLQ)
├── ms-digitalfix-rabbit-admin\  administrador RabbitMQ
├── ms-digitalfix-catalog\
├── ms-digitalfix-report\
└── ms-digitalfix-audit\
```

```powershell
cd $HOME\Documents\digitalfix
foreach ($r in 'digitalfix-infra','frontend-digitalfix','ms-digitalfix-bff','ms-digitalfix-workorders',
               'ms-digitalfix-notify','ms-digitalfix-rabbit-admin','ms-digitalfix-catalog',
               'ms-digitalfix-report','ms-digitalfix-audit') {
  if (Test-Path $r) { git -C $r pull } else { git clone "https://github.com/DigitalFix-Grupo12/$r.git" }
}
```

## 3. Clúster RabbitMQ local (2 nodos)

```powershell
cd digitalfix-infra\mq
Copy-Item .env.example .env        # mismos valores para ambos integrantes
docker compose up -d
docker compose ps                  # rabbit1 y rabbit2 -> (healthy)
docker exec rabbit1 rabbitmqctl cluster_status
```

| Nodo | AMQP | Management UI |
|---|---|---|
| `rabbit@rabbit1` | localhost:5672 | http://localhost:15672 |
| `rabbit@rabbit2` | localhost:5673 | http://localhost:15673 |

Usuario/clave locales: los del `.env` (`digitalfix` / valor de `RABBITMQ_PASS`). El `.env` **no se sube**
(está en `.gitignore`); el `.env.example` sí.

## 4. Configuración de las aplicaciones (igual en ambos PCs)

| Microservicio | Puerto | RabbitMQ | Variables |
|---|---|---|---|
| ms-digitalfix-workorders | 8082 | productor | `RABBITMQ_ADDRESSES`, `RABBITMQ_USERNAME`, `RABBITMQ_PASSWORD` |
| ms-digitalfix-notify | 8086 | consumidor | las mismas + `REPORTS_DIR` (opcional) |
| ms-digitalfix-rabbit-admin | 8087 | administrador | las mismas + `RABBITMQ_MANAGEMENT_URLS` |
| ms-digitalfix-bff | 8080 | — | `AZURE_TENANT_ID`, `AZURE_API_CLIENT_ID` (+ `_2` para el tenant de Boris); `Start-Local.ps1` los toma de `config/tenants.json` |

Valores por defecto (no hace falta definirlos en local): `RABBITMQ_ADDRESSES=localhost:5672,localhost:5673`,
`RABBITMQ_MANAGEMENT_URLS=http://localhost:15672,http://localhost:15673`, usuario `digitalfix`.
Si cambiaron la clave en `.env`, definir `RABBITMQ_PASSWORD` igual.

Arranque completo en un paso:

```powershell
cd digitalfix-infra
.\scripts\Start-Local.ps1          # cluster + compila y abre cada servicio en su ventana
```

## 5. Verificación rápida (lo que puede pedir el docente)

```powershell
# 3 colas + 3 DLQ, consumidores conectados
docker exec rabbit1 rabbitmqctl list_queues name messages consumers arguments
# exchanges direct y topic
docker exec rabbit1 rabbitmqctl list_exchanges name type | Select-String cmd
# bindings
docker exec rabbit1 rabbitmqctl list_bindings source_name routing_key destination_name | Select-String cmd
# admin
Invoke-RestMethod http://localhost:8087/api/rabbit/overview
Invoke-RestMethod http://localhost:8087/api/rabbit/queues | Format-Table name,messagesReady,consumers,node
```

Dónde está cada cosa en el código (para responder preguntas):

| Pregunta típica | Archivo |
|---|---|
| ¿Dónde se definen los nombres? | `application.yml` → `digitalfix.rabbitmq` (notify y workorders) |
| ¿Dónde están los beans Queue/Exchange/Binding? | `ms-digitalfix-notify/.../config/RabbitTopologyConfig.java` |
| ¿Cómo se hace el ACK manual? | `.../config/RabbitListenerConfig.java` (MANUAL) y `.../messaging/ManualAckProcessor.java` |
| ¿Cuándo va un mensaje a la DLQ? | `ManualAckProcessor` (tabla en el Javadoc) |
| ¿Dónde están los consumidores? | `email/`, `dispatch/`, `report/` → `*CommandListener` con `@RabbitListener` |
| ¿Quién publica? | `ms-digitalfix-workorders/.../messaging/WorkOrderCommandTranslator.java` + `RabbitCommandPublisher` |
| ¿Dónde está la lógica del administrador? | `ms-digitalfix-rabbit-admin/.../service/RabbitAdminService.java` |
| ¿Cómo se valida la entrada? | `ms-digitalfix-rabbit-admin/.../dto/*Request.java` + `ApiExceptionHandler` |

## 6. Nube (AWS Academy Learner Lab)

Credenciales del lab en `C:\Users\<usuario>\.aws\credentials` (se renuevan en cada sesión).

```powershell
cd digitalfix-infra
.\scripts\Deploy-MQ.ps1 -TerminateOld       # 1. ec2-mq: cluster RabbitMQ con docker compose
.\scripts\Deploy-EC2.ps1 -TerminateOld      # 2. ec2 apps (t3.medium): 7 servicios + API Gateway
.\scripts\Deploy-Frontend.ps1               # 3. Amplify (pantalla Mensajeria para Admin)
```

## 7. Tenant de Entra ID (cada integrante)

Cada integrante tiene su propio tenant configurado igual (ver `GUIA-TENANT-ENTRA.md`): `Setup-EntraTenant.ps1`,
IDs en `config/tenants.json`, `Apply-Tenants.ps1` + `Deploy-Frontend.ps1`. En el login de la app se elige el tenant.
