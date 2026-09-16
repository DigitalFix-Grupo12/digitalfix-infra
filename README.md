# DigitalFix — Infraestructura y despliegue (DSY1107 · Grupo 12)

Sistema de gestión de órdenes de mantenimiento eléctrico: frontend Angular con
login en Azure Entra ID (MSAL, Authorization Code + PKCE), un BFF en Spring Boot
protegido por AWS API Gateway y cuatro microservicios de dominio en EC2.

## Repositorios

| Repo | Tecnología | Puerto | Responsabilidad |
|---|---|---|---|
| [frontend-digitalfix](https://github.com/DigitalFix-Grupo12/frontend-digitalfix) | Angular + MSAL | 4200 | SPA, login, guards por rol, adjunta el JWT |
| [ms-digitalfix-bff](https://github.com/DigitalFix-Grupo12/ms-digitalfix-bff) | Spring Boot 3.4 | 8080 | Valida firma, vigencia, issuer y audience del JWT; autoriza por rol; gateway hacia los MS |
| [ms-digitalfix-workorders](https://github.com/DigitalFix-Grupo12/ms-digitalfix-workorders) | Spring Boot + JPA | 8082 | Órdenes de trabajo y máquina de estados |
| [ms-digitalfix-catalog](https://github.com/DigitalFix-Grupo12/ms-digitalfix-catalog) | Spring Boot + JPA | 8083 | Catálogo de servicios y repuestos |
| [ms-digitalfix-report](https://github.com/DigitalFix-Grupo12/ms-digitalfix-report) | Spring Boot | 8084 | KPIs calculados desde workorders |
| [ms-digitalfix-audit](https://github.com/DigitalFix-Grupo12/ms-digitalfix-audit) | Spring Boot + JPA | 8085 | Timeline de auditoría |
| digitalfix-infra (este) | Bash / PowerShell / AWS CLI | — | Bootstrap EC2, despliegue, registro en Entra ID |

## Arquitectura

```
Navegador (Angular + MSAL) ── login PKCE ──> Azure Entra ID
        │  Authorization: Bearer <JWT>
        ▼
AWS API Gateway (HTTP API, CORS)  ANY /{proxy+}
        │
        ▼  EC2 t3.micro — Security Group: solo 8080 público
ms-digitalfix-bff :8080  ── valida JWT + rol ──┐
        ├─> ms-digitalfix-workorders :8082 ────┼─> ms-digitalfix-audit :8085
        ├─> ms-digitalfix-catalog    :8083     │
        ├─> ms-digitalfix-report     :8084 ────┘ (lee workorders)
        └─> ms-digitalfix-audit      :8085
```

- Los microservicios de dominio escuchan solo en la red interna del host; el perímetro de seguridad es el BFF.
- El BFF propaga la identidad del usuario (`preferred_username`) en `X-User-Name` para la auditoría.
- Roles (App Roles de Entra ID): `Admin`, `Supervisor`, `Cliente`, `Auditor`.

| Endpoint (vía BFF) | Roles |
|---|---|
| `GET/POST /api/workorders`, `GET /api/workorders/{id}` | Admin, Supervisor, Cliente |
| `PUT /api/workorders/{id}/status` | Admin, Supervisor |
| `GET /api/catalog/services` | Admin, Supervisor |
| `GET /api/report/kpis` | Admin |
| `GET /api/audit` | Admin, Auditor |

## Estructura esperada en disco

Los scripts asumen que todos los repos se clonan en la misma carpeta:

```
digitalfix/
├── digitalfix-infra/
├── frontend-digitalfix/
├── ms-digitalfix-bff/
├── ms-digitalfix-workorders/
├── ms-digitalfix-catalog/
├── ms-digitalfix-report/
└── ms-digitalfix-audit/
```

## 1. Registrar las apps en Entra ID

```powershell
cd digitalfix-infra\scripts
.\Register-EntraApps.ps1 -TenantId "<tenant>" -ClientId "<app-admin>" -ClientSecret "<secret>"
.\Register-EntraApps.ps1 ... -AssignRoleToUserUPN "usuario@tenant.onmicrosoft.com" -AssignRoleName Admin
```

Crea la app SPA y la app API (scope `access_as_user` y los 4 App Roles), y actualiza
`frontend-digitalfix/src/app/core/config/app-config.ts` y `ms-digitalfix-bff/run-bff.ps1`.
El secreto se pasa por parámetro y **nunca** se guarda en el repo.

## 2. Ejecutar en local

```powershell
# en cada microservicio (audit, catalog, workorders, report)
mvn clean package
java -jar target\<servicio>-0.0.1-SNAPSHOT.jar

# BFF
$env:AZURE_TENANT_ID = "<tenant-id>"
$env:AZURE_API_CLIENT_ID = "<api-client-id>"
java -jar ms-digitalfix-bff\target\ms-digitalfix-bff-0.0.1-SNAPSHOT.jar

# Frontend
cd frontend-digitalfix
npm install
ng serve
```

Health de cada servicio: `GET http://localhost:<puerto>/actuator/health`.

## 3. Desplegar en AWS

```powershell
cd digitalfix-infra
.\scripts\Deploy-EC2.ps1 -Name digitalfix-v4
```

1. Verifica que los 5 repos backend existan en la organización.
2. Lanza una EC2 (Amazon Linux 2023, t3.micro, 12 GB gp3) con `aws/ec2-user-data.sh`.
3. El user-data crea 2 GB de swap, instala Java 17 y Maven, clona y compila los 5 servicios y los registra como units de systemd (JVM con `-Xmx160m` y SerialGC para caber en 1 GB).
4. Espera el fin del bootstrap (log de diagnóstico en `http://<ip>:8081/setup-debug.log`).
5. Si el BFF responde, cambia la integración del API Gateway a la nueva IP y prueba que una llamada sin token devuelva `401`.

## Seguridad

- La llave `.pem` de EC2 y cualquier secreto de Entra ID están excluidos por `.gitignore`.
- Client ID y Tenant ID no son secretos (son públicos en una SPA).
- Validación del JWT en el BFF: firma (JWKS del tenant), expiración, issuer y audience (`JwtAudienceValidator`).
