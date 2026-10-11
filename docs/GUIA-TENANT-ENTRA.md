# Guía: tenant de Microsoft Entra ID (Kevin y Boris)

DigitalFix acepta usuarios de **dos tenants** de Entra ID, uno por integrante, configurados
exactamente igual. Ambos inician sesión en la misma app (Amplify) eligiendo su tenant; cada
tenant tiene su propio API Gateway (JWT authorizer) y el BFF confía en los dos issuers
(ver `DECISIONES-TECNICAS.md` §16).

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

## 3. Enviar los IDs a Kevin (solo Boris)

Enviar estos 4 valores de `entra-tenant.json` (son públicos, no la clave):
`tenantId`, `domain`, `spaAppId`, `apiAppId`.

## 4. Aplicar los tenants (Kevin, con credenciales del Learner Lab)

1. Completar `config/tenants.json` (`tenantId`, `domain`, `spaClientId` = spaAppId,
   `apiClientId` = apiAppId) en el bloque de cada integrante.
2. Ejecutar:

```powershell
cd C:\Users\katty\Documents\digitalfix\digitalfix-infra
.\scripts\Apply-Tenants.ps1      # SSM + un API Gateway por tenant + reinicio del BFF + tenants.ts
.\scripts\Deploy-Frontend.ps1    # publica el selector de tenant en Amplify
```

## 5. Verificar

| Prueba | Esperado |
|---|---|
| Login con *Tenant Kevin* y `admin.demo@<dominio Kevin>` | Panel con todas las secciones |
| Login con *Tenant Boris* y `admin.demo@<dominio Boris>` | Panel con todas las secciones |
| `GET <gateway>/api/workorders` sin token | 401 (API Gateway) |
| Token de un tenant contra el gateway del otro | 401 (issuer no coincide) |
| Pantalla *Sesión* | Muestra el tenant, authority, client ID y gateway activos |

## Qué mostrar en el video (cada integrante, su tenant)

Entra ID → **Usuarios** (los 4 demo) → **Registros de aplicaciones** (`digitalfix-frontend`: plataforma
SPA y redirect URIs; `digitalfix-api`: *Exponer una API* y *Roles de aplicación*) → **Aplicaciones
empresariales → digitalfix-api → Usuarios y grupos** (rol de cada usuario) → login en vivo con PKCE.
