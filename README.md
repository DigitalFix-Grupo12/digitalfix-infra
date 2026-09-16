# DigitalFix — Infraestructura y despliegue (DSY1107 · Grupo 12)

Sistema de gestión de órdenes de mantenimiento eléctrico: frontend Angular con
login OIDC en Microsoft Entra ID (MSAL, Authorization Code + PKCE), AWS API Gateway
como API Manager (JWT Authorizer + CORS), un BFF en Spring Boot y cuatro
microservicios de dominio en EC2 con base de datos Amazon RDS PostgreSQL.

| Recurso | URL / identificador |
|---|---|
| Frontend (AWS Amplify, HTTPS) | https://main.dehlzhnwtqj7a.amplifyapp.com |
| API Manager (API Gateway HTTP API) | https://7s6qn2mb8h.execute-api.us-east-1.amazonaws.com |
| Backend (EC2 t3.micro, IP elástica) | 18.210.44.145 — solo el puerto 8080 del BFF es alcanzable |
| Base de datos (RDS PostgreSQL, privada) | `digitalfix-db` — schemas `workorders`, `catalog`, `audit` |
| IDaaS | Microsoft Entra ID, tenant `ac1c32f1-bc10-4ded-b8c0-102ac9a1fd68` |

## Equipo

Grupo 12 — DSY1107 Desarrollo Cloud Native I, Duoc UC.

| Integrante | Responsabilidades |
|---|---|
| Kevin Pinochet | Arquitectura de la solución, BFF y seguridad JWT, microservicios de órdenes y reportes, frontend Angular con MSAL, configuración de Entra ID, despliegue en AWS (EC2, RDS, API Gateway, Amplify) |
| Boris Marciel | Documentación de usuario, checklist de pruebas manuales, ejemplos de uso de la API, pruebas del catálogo y colección Postman de auditoría |

Documentación complementaria: [Guía de usuario](docs/GUIA-USUARIO.md) ·
[Pruebas manuales](docs/PRUEBAS-MANUALES.md) · [Decisiones técnicas](docs/DECISIONES-TECNICAS.md) · [Guía de presentación EP2](docs/GUIA-PRESENTACION-EP2.md)

## Repositorios

| Repo | Tecnología | Puerto | Responsabilidad |
|---|---|---|---|
| [frontend-digitalfix](https://github.com/DigitalFix-Grupo12/frontend-digitalfix) | Angular + MSAL | 4200 | SPA, login OIDC/PKCE, guards por rol, MsalInterceptor adjunta el JWT |
| [ms-digitalfix-bff](https://github.com/DigitalFix-Grupo12/ms-digitalfix-bff) | Spring Boot 3.4 | 8080 | Valida firma, vigencia, issuer y audience del JWT; autoriza por rol; gateway hacia los MS |
| [ms-digitalfix-workorders](https://github.com/DigitalFix-Grupo12/ms-digitalfix-workorders) | Spring Boot + JPA | 8082 | Órdenes de trabajo y máquina de estados |
| [ms-digitalfix-catalog](https://github.com/DigitalFix-Grupo12/ms-digitalfix-catalog) | Spring Boot + JPA | 8083 | Catálogo de servicios y repuestos |
| [ms-digitalfix-report](https://github.com/DigitalFix-Grupo12/ms-digitalfix-report) | Spring Boot | 8084 | KPIs calculados desde workorders |
| [ms-digitalfix-audit](https://github.com/DigitalFix-Grupo12/ms-digitalfix-audit) | Spring Boot + JPA | 8085 | Timeline de auditoría |
| digitalfix-infra (este) | PowerShell / Bash / AWS CLI | — | Aprovisionamiento, despliegue y evidencias |

## Arquitectura

```
Usuario ──HTTPS──> AWS Amplify (Angular + MSAL)
   │  1. login OIDC Authorization Code + PKCE ───────────> Microsoft Entra ID
   │  2. access token (aud = digitalfix-api, scp = access_as_user, roles)
   ▼
AWS API Gateway (HTTP API)
   • JWT Authorizer: firma (JWKS), exp, issuer v2.0, audience   -> 401 si falla
   • scope requerido: access_as_user                            -> 403 si falta
   • rutas explícitas por endpoint + CORS restringido
   ▼  HTTP_PROXY (path original)
EC2 (IP elástica) — Security Group: solo 8080 público
ms-digitalfix-bff :8080  (Spring Security: re-valida el JWT y autoriza por rol -> 403)
   ├─> ms-digitalfix-workorders :8082 ──> audit (eventos)   ┐
   ├─> ms-digitalfix-catalog    :8083                       ├─> RDS PostgreSQL (privada,
   ├─> ms-digitalfix-report     :8084 ──> workorders        │   5432 solo desde la EC2)
   └─> ms-digitalfix-audit      :8085                       ┘
```

Defensa en profundidad: el token se valida en el API Gateway **y** en el BFF. Los
microservicios de dominio no son alcanzables desde Internet.

### Rutas del API Manager

| Ruta | Autorización en Gateway | Roles (BFF) | Microservicio |
|---|---|---|---|
| `GET /api/workorders` | JWT + `access_as_user` | Admin, Supervisor, Cliente | workorders |
| `POST /api/workorders` | JWT + `access_as_user` | Admin, Supervisor, Cliente | workorders |
| `GET /api/workorders/{id}` | JWT + `access_as_user` | Admin, Supervisor, Cliente | workorders |
| `PUT /api/workorders/{id}/status` | JWT + `access_as_user` | Admin, Supervisor | workorders |
| `GET /api/catalog/services` | JWT + `access_as_user` | Admin, Supervisor | catalog |
| `GET /api/catalog/services/{id}` | JWT + `access_as_user` | Admin, Supervisor | catalog |
| `GET /api/report/kpis` | JWT + `access_as_user` | Admin | report |
| `GET /api/audit` | JWT + `access_as_user` | Admin, Auditor | audit |
| `GET /actuator/health` | pública | — | bff (monitoreo) |

CORS: orígenes `https://main.dehlzhnwtqj7a.amplifyapp.com` y `http://localhost:4200`;
métodos GET, POST, PUT, OPTIONS; headers `authorization`, `content-type`.

## Estructura en disco

Los scripts asumen que todos los repos están clonados en la misma carpeta:

```
digitalfix/
├── digitalfix-infra/          aws/  scripts/  postman/  evidencias/  docs/
├── frontend-digitalfix/
├── ms-digitalfix-bff/
├── ms-digitalfix-workorders/
├── ms-digitalfix-catalog/
├── ms-digitalfix-report/
└── ms-digitalfix-audit/
```

## Scripts

| Script | Qué hace |
|---|---|
| `scripts/Register-EntraApps.ps1` | Registra las apps SPA y API en Entra ID (scope `access_as_user`, 4 App Roles) y asigna roles a usuarios |
| `scripts/Create-Database.ps1` | Crea RDS PostgreSQL privada, su Security Group y guarda las credenciales en SSM Parameter Store (SecureString) |
| `scripts/Deploy-EC2.ps1` | Lanza la EC2 con `aws/ec2-user-data.sh`, le asocia la IP elástica y ejecuta `Configure-ApiGateway.ps1` |
| `scripts/Configure-ApiGateway.ps1` | Integración hacia el BFF, JWT Authorizer, rutas explícitas y CORS (idempotente) |
| `scripts/Deploy-Frontend.ps1` | `ng build` + publicación en AWS Amplify con rewrite SPA |
| `scripts/Test-ApiGateway.ps1` | Prueba cada ruta sin token, con token inválido y con token real; genera `evidencias/api-gateway.md` |
| `postman/DigitalFix-API-Gateway.postman_collection.json` | Misma evidencia en Postman, con tests automáticos por rol |

### Despliegue completo desde cero

```powershell
cd digitalfix-infra
.\scripts\Create-Database.ps1            # 1. RDS (5-15 min)
.\scripts\Deploy-EC2.ps1 -TerminateOld   # 2. backend + API Gateway (~5 min)
.\scripts\Deploy-Frontend.ps1            # 3. frontend en Amplify
.\scripts\Test-ApiGateway.ps1            # 4. evidencia
```

`ec2-user-data.sh`: crea 2 GB de swap, instala Java 17 y Maven, lee las credenciales
de RDS desde SSM (rol `LabInstanceProfile`), clona y compila los 5 servicios y los
registra como units de systemd con el perfil `cloud`. El log de arranque queda
expuesto 15 minutos en `http://<ip>:8081/setup-debug.log` (sin secretos).

### AWS Academy Learner Lab

Al terminar la sesión del lab la EC2 se detiene. Como usa **IP elástica**, al
volver a iniciar el lab la IP no cambia y el API Gateway sigue funcionando; los
servicios arrancan solos (systemd) y reintentan la conexión a RDS hasta que esté
disponible. Espera 2-3 minutos después de iniciar el lab antes de probar.

## Ejecutar en local

```powershell
# microservicios (perfil por defecto = H2 en memoria)
cd ms-digitalfix-audit;      mvn spring-boot:run
cd ms-digitalfix-catalog;    mvn spring-boot:run
cd ms-digitalfix-workorders; mvn spring-boot:run
cd ms-digitalfix-report;     mvn spring-boot:run

# BFF
$env:AZURE_TENANT_ID = "ac1c32f1-bc10-4ded-b8c0-102ac9a1fd68"
$env:AZURE_API_CLIENT_ID = "fb8ea665-ee45-4790-8112-eade3bd230e5"
cd ms-digitalfix-bff; mvn spring-boot:run

# Frontend (apunta al API Gateway; para BFF local cambiar baseUrl en app-config.ts)
cd frontend-digitalfix; npm install; ng serve
```

## Seguridad

- JWT validado dos veces: API Gateway (JWT Authorizer) y BFF (`JwtAudienceValidator` + validadores de issuer/expiración, firma con JWKS).
- Autorización por rol con el claim `roles` (App Roles de Entra ID); sin rol asignado no hay acceso.
- PKCE (S256), `state` y `nonce` generados y verificados por MSAL; tokens en `localStorage` del origen del SPA.
- RDS privada (sin IP pública), cifrada en reposo, accesible solo desde el SG de la EC2; conexión con `sslmode=require`.
- Credenciales de base de datos en SSM Parameter Store (SecureString), nunca en los repos.
- `.pem`, `.env` y secretos excluidos por `.gitignore`.
