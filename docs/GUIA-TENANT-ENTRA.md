# Guía: tenant de Entra ID y nube de cada integrante (Kevin y Boris)

**Opción A — una URL, dos nubes.** Cada integrante tiene su **tenant de Entra ID** y su **cuenta de AWS
Academy** con el mismo despliegue (EC2 de apps, `ec2-mq` con 2 nodos RabbitMQ, API Gateway). La app es una sola:
https://main.dehlzhnwtqj7a.amplifyapp.com (Amplify en la cuenta de Kevin). En el login se elige el tenant y la app
llama al API Gateway de la cuenta de ese integrante (ver `DECISIONES-TECNICAS.md` §16).

## 1. Crear el tenant (portal, cada integrante)

> **Con la cuenta @duocuc.cl** la sección Entra ID del portal da "Sin acceso" (401), pero el
> formulario de creación sí funciona: abrir directamente
> https://portal.azure.com/#create/Microsoft.AzureActiveDirectory , completar nombre, dominio
> inicial y país (Chile) y presionar **Crear** (pide captcha). La cuenta DuocUC queda como
> Administrador global del tenant nuevo (usuario `#EXT#`) y debe registrar MFA con Microsoft
> Authenticator al primer ingreso. Luego, en el tenant nuevo: **Propiedades → Administrar valores
> predeterminados de seguridad → Deshabilitado**, para que los usuarios demo no pidan MFA en el video.

Alternativa por el portal (si la sección Entra ID está disponible):

1. https://entra.microsoft.com → **Entra ID → Información general → Administrar inquilinos → + Crear**.
2. Tipo: **Microsoft Entra ID** (workforce).
3. Nombre de la organización: `DigitalFix <Nombre>` · Dominio inicial: p. ej. `digitalfixboris`
   · País: **Chile** (no se puede cambiar después).
4. **Revisar y crear** → captcha → esperar ~2 min.
5. Cambiar al tenant nuevo (engranaje → Directorios) y copiar el **Id. de inquilino**.

> Si el portal no deja crear el tenant: activar Azure for Students con el correo DuocUC.

## 2. Configurarlo con el script (cada integrante, en su PC)

Requisitos: Windows PowerShell 5.1+, el repo `digitalfix-infra` clonado.

```powershell
cd C:\Users\<usuario>\Documents\digitalfix\digitalfix-infra\scripts
powershell -ExecutionPolicy Bypass -File .\Setup-EntraTenant.ps1 -TenantId "<Id. de inquilino>"
```

- Se abre el navegador: iniciar sesión con la cuenta que creó el tenant y aceptar
  **Consentir en nombre de la organización** (Microsoft Graph Command Line Tools).
- El script crea: `digitalfix-api` (scope `access_as_user`, App Roles Admin/Supervisor/Cliente/Auditor,
  tokens v2), `digitalfix-frontend` (SPA, redirect `http://localhost:4200` y Amplify, admin consent),
  los usuarios `admin|supervisor|cliente|auditor.demo@<dominio>` con su rol, y el rol Admin para
  la cuenta que lo ejecuta.
- Resultado en `C:\Users\<usuario>\Documents\digitalfix\entra-tenant.json` (fuera de los repos:
  contiene la clave de los usuarios demo; **no subirlo a GitHub**).
- Es idempotente: si falla a mitad de camino, se vuelve a ejecutar.

## 3. Registrar el tenant en el repo

Completar el bloque del integrante en `config/tenants.json` con los valores de `entra-tenant.json`:
`tenantId`, `domain`, `spaClientId` (= spaAppId) y `apiClientId` (= apiAppId). Son públicos.

## 4. Desplegar la nube del integrante (con SUS credenciales del Learner Lab)

Pegar las credenciales de su Learner Lab en `C:\Users\<usuario>\.aws\credentials` y verificar con
`aws sts get-caller-identity`. Luego, desde `digitalfix-infra` (Boris usa `-Owner boris`):

```powershell
.\scripts\Apply-Tenants.ps1 -Owner boris -SkipEc2Restart   # SSM con su tenant (registra su cuenta AWS)
.\scripts\Deploy-MQ.ps1                                     # ec2-mq: cluster RabbitMQ de 2 nodos (~10 min)
.\scripts\Deploy-EC2.ps1 -Owner boris -Name digitalfix-v1   # EC2 de apps + su API Gateway (~15 min)
```

- En una cuenta nueva los scripts crean el par de claves `digitalfix-key` (se guarda como
  `digitalfix-key-<cuenta>.pem` junto a los repos, **no se sube**) y el Security Group `digitalfix-apps-sg`.
- `Apply-Tenants.ps1` se detiene si las credenciales no son de la cuenta registrada para ese integrante.
- Al terminar, `config/tenants.json` queda con su `apiGatewayId` y `awsAccountId`.

## 5. Publicar el selector (Kevin, con SUS credenciales)

Hacer commit de `config/tenants.json`, volver a las credenciales de Kevin y ejecutar:

```powershell
.\scripts\Apply-Tenants.ps1 -SkipEc2Restart   # regenera tenants.ts con los dos perfiles
.\scripts\Deploy-Frontend.ps1                 # Amplify: aparece "Tenant Kevin / Tenant Boris"
```

Commit de `frontend-digitalfix/src/app/core/config/tenants.ts`.

## 6. Verificar

| Prueba | Esperado |
|---|---|
| Login *Tenant Kevin* + `admin.demo@digitalfixkevin.onmicrosoft.com` | Panel completo (backend de Kevin) |
| Login *Tenant Boris* + `admin.demo@<dominio Boris>` | Panel completo (backend de Boris) |
| Pantalla *Sesión* | Tenant, authority, client ID y gateway del tenant elegido |
| `GET <gateway>/api/workorders` sin token | 401 |
| Token de un tenant contra el gateway del otro | 401 (issuer no coincide) |

## Qué mostrar en el video (cada integrante, su tenant y su cuenta)

Entra ID → **Usuarios** (los 4 demo) → **Registros de aplicaciones** (`digitalfix-frontend`: plataforma
SPA y redirect URIs; `digitalfix-api`: *Exponer una API* y *Roles de aplicación*) → **Aplicaciones
empresariales → digitalfix-api → Usuarios y grupos** → login en vivo con PKCE eligiendo su tenant →
en SU consola de AWS: EC2 (apps + ec2-mq), API Gateway (authorizer y CORS), RabbitMQ y logs por SSH.
El frontend es el Amplify común de la cuenta de Kevin: mostrarlo con su URL.
