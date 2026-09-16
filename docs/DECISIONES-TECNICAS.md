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

- **Decisión:** tenant propio (`tenatkevin.onmicrosoft.com`) con dos registros de aplicación:
  `digitalfix-frontend` (SPA) y `digitalfix-api` (API protegida con el scope `access_as_user`).
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
| Backend | EC2 t3.micro + IP elástica | Requisito del curso; la IP no cambia al reiniciar el lab |
| Servicios | systemd | Arranque automático y reinicio ante fallos |
| Memoria | `-Xmx` acotado + swap de 2 GB | Cinco JVM en una instancia de 1 GB |

Todo el aprovisionamiento está en scripts idempotentes (`scripts/`) para poder recrear el entorno cuando el lab expira.

## 9. Calidad

- Tests automáticos en cada microservicio (seguridad del BFF, máquina de estados, propiedad de órdenes,
  catálogo, auditoría y KPIs), ejecutados en cada push con **GitHub Actions**.
- Colección Postman con pruebas de 401/403/200/409 y el checklist de [pruebas manuales](PRUEBAS-MANUALES.md).
