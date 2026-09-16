# Guía de presentación EP2 — DigitalFix (5 a 10 minutos)

Checklist previo (15 min antes):

1. Iniciar el **Learner Lab** y esperar 3 minutos (la EC2 arranca sola con su IP elástica).
2. Verificar: `.\scripts\Test-ApiGateway.ps1` → "todas las rutas responden lo esperado".
3. Abrir pestañas: frontend (Amplify), consola AWS (API Gateway `7s6qn2mb8h`, EC2, RDS), Entra ID (App registrations), Postman con la colección importada.
4. Tener un usuario por rol listo (Admin y al menos uno sin permiso de Reportería, p. ej. Cliente o Auditor) para mostrar 200 vs 403.

## Guion sugerido

| Min | Qué mostrar | Dónde | Indicador de la pauta |
|---|---|---|---|
| 0:00 | Arquitectura (diagrama del README) y por qué: API Manager + BFF (defensa en profundidad), microservicios con schema propio, IP elástica | README de `digitalfix-infra` | Hilo conductor |
| 1:00 | **Tenant** y **usuarios**: tenant de Entra ID, usuarios con App Roles asignados (Admin, Supervisor, Cliente, Auditor) | Entra ID → Enterprise applications → digitalfix-api → Users and groups | Tenant 10 % |
| 2:00 | **App registrations**: SPA con client ID y redirect URIs (Amplify + localhost, tipo *Single-page application*); API con *Expose an API* (`access_as_user`) y *App roles* | Entra ID → App registrations | Aplicación 10 % |
| 3:00 | **Login OIDC + PKCE**: abrir el frontend, F12 → Network → filtrar `authorize`: mostrar `response_type=code`, `code_challenge`, `code_challenge_method=S256`, `state`, `nonce`. Luego la llamada `token` con `code_verifier` | Frontend en Amplify | PKCE 15 %, flujo de usuario 10 % |
| 4:00 | **Mi sesión**: claims del ID token (`nonce`) y del access token (`iss`, `aud`, `scp`, `roles`, `exp`) | Frontend → Mi sesión | Flujo de usuario (claims) |
| 5:00 | **API Manager**: API activa, rutas explícitas, integración HTTP hacia el BFF, **CORS** con dos orígenes y métodos mínimos | Consola API Gateway → Routes / Authorization / CORS | Rutas 13 %, CORS 7 % |
| 6:00 | **JWT Authorizer**: issuer `https://login.microsoftonline.com/<tenant>/v2.0`, audience `fb8ea665-...`, scope `access_as_user` en cada ruta | API Gateway → Authorization | Validación JWT 20 % |
| 6:30 | **Pruebas 200 / 401 / 403**: botón "Probar rutas del API Gateway" en Mi sesión (con y sin token). Repetir en Postman: carpeta 1 (401) y carpeta 2 (200/403 según rol) | Frontend / Postman | Validación JWT 20 %, Evidencias 15 % |
| 8:00 | **Integración en la nube**: crear una orden, asignar técnico, avanzar estados (mostrar el 409 al intentar ejecutar sin asignar), ver Auditoría con el usuario y Reportería con KPIs | Frontend | Integración final, Evidencias |
| 9:00 | **Despliegue**: EC2 (5 servicios systemd), RDS privada, Amplify | Consola AWS | Integración final |

## Preguntas probables y respuesta corta

- **¿Por qué validar el JWT en el Gateway y también en el BFF?** El Gateway corta tráfico no autenticado antes de llegar a la EC2 (issuer, audience, firma, expiración y scope). El BFF vuelve a validar (zero trust) y además decide por **rol**, que el authorizer JWT de HTTP API no evalúa.
- **¿Qué diferencia hay entre 401 y 403?** 401: el token no existe o es inválido/expirado (Gateway o BFF). 403: el token es válido pero el rol no autoriza el endpoint (BFF), o falta el scope (Gateway).
- **¿Por qué PKCE en una SPA?** Una SPA no puede guardar un client secret. PKCE liga el `code` al `code_verifier` que solo tiene el navegador que inició el login, evitando el robo del código de autorización. El flujo Implicit está deprecado.
- **¿Para qué sirven `state` y `nonce`?** `state` protege contra CSRF en el redirect; `nonce` evita el replay del ID token. MSAL los genera y los verifica.
- **¿Por qué `aud` es un GUID y no `api://...`?** Los access tokens v2.0 de Entra ID ponen el Application ID en `aud`. El authorizer acepta ambos formatos.
- **¿Cómo se comunican los microservicios?** El BFF llama por HTTP a `localhost` (red interna del host); workorders publica eventos a audit y report consulta a workorders. Si un servicio cae, el BFF responde 503.
- **¿Dónde están las credenciales de la base?** En SSM Parameter Store (SecureString); la EC2 las lee con su rol IAM al arrancar. No están en el código.
- **¿Qué pasa si se reinicia el lab?** La IP elástica mantiene la integración del Gateway; systemd levanta los servicios y reintentan la conexión a RDS.
