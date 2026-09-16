# Checklist de pruebas manuales — DigitalFix

Ejecutar con el Learner Lab activo (EC2 encendida) desde
https://main.dehlzhnwtqj7a.amplifyapp.com, en una ventana de incógnito por usuario.

Marcar cada fila con ✅ / ❌ y anotar observaciones.

## 1. Autenticación (Entra ID + PKCE)

| # | Paso | Resultado esperado | OK |
|---|---|---|:-:|
| 1.1 | Abrir la app sin sesión | Se muestra la pantalla de login; rutas internas redirigen al login | ☐ |
| 1.2 | Iniciar sesión con admin.demo | Redirección a Microsoft y vuelta al panel | ☐ |
| 1.3 | DevTools → Network en el login | La petición `/authorize` lleva `code_challenge` y `code_challenge_method=S256` | ☐ |
| 1.4 | Pantalla **Mi sesión** | Muestra claims `aud`, `iss`, `exp` y `roles` = Admin | ☐ |
| 1.5 | Cerrar sesión | Vuelve al login; al recargar no se recupera la sesión | ☐ |
| 1.6 | **Crear cuenta** con un correo nuevo | Entra ID crea el usuario invitado; sin rol ve "Sin rol asignado" | ☐ |

## 2. API Gateway y BFF

| # | Paso | Resultado esperado | OK |
|---|---|---|:-:|
| 2.1 | `GET /actuator/health` sin token | 200 | ☐ |
| 2.2 | `GET /api/workorders` sin token | 401 (JWT Authorizer) | ☐ |
| 2.3 | `GET /api/workorders` con token alterado | 401 | ☐ |
| 2.4 | Llamada desde un origen no permitido | El navegador bloquea por CORS | ☐ |
| 2.5 | Colección Postman completa (Runner) | Todas las pruebas en verde | ☐ |

## 3. Autorización por rol

| # | Usuario | Paso | Resultado esperado | OK |
|---|---|---|---|:-:|
| 3.1 | admin.demo | Abrir Reportes y Auditoría | Datos visibles (200) | ☐ |
| 3.2 | supervisor.demo | Abrir Catálogo | 7 ítems (4 servicios, 3 repuestos) | ☐ |
| 3.3 | supervisor.demo | Abrir Auditoría | Sin acceso (403) | ☐ |
| 3.4 | cliente.demo | Abrir Órdenes | Solo aparecen sus órdenes | ☐ |
| 3.5 | cliente.demo | Abrir Reportes | Sin acceso (403) | ☐ |
| 3.6 | auditor.demo | Abrir Auditoría y exportar CSV | Se descarga el archivo | ☐ |

## 4. Flujo de una orden de trabajo

| # | Paso | Resultado esperado | OK |
|---|---|---|:-:|
| 4.1 | Supervisor crea una orden | Aparece en la columna **Nuevas** (201) | ☐ |
| 4.2 | Asignar técnico | Pasa a **Asignadas** | ☐ |
| 4.3 | Enviar a terreno → Iniciar trabajo → Cerrar orden | Avanza columna por columna hasta **Terminadas** | ☐ |
| 4.4 | Detalle de la orden | El historial muestra cada cambio con usuario y fecha | ☐ |
| 4.5 | Cancelar una orden nueva | Queda en la lista de canceladas | ☐ |
| 4.6 | Cliente intenta cambiar estado (Postman) | 403 | ☐ |
| 4.7 | Saltar de CREADA a EN_EJECUCION (Postman) | 409 | ☐ |

## 5. Despliegue en la nube

| # | Paso | Resultado esperado | OK |
|---|---|---|:-:|
| 5.1 | Consola AWS → EC2 | Instancia `digitalfix-*` en estado *running* | ☐ |
| 5.2 | Consola AWS → RDS | `digitalfix-db` disponible | ☐ |
| 5.3 | Consola AWS → Amplify | Último despliegue de `main` exitoso | ☐ |
| 5.4 | Consola AWS → API Gateway | Rutas, autorizador JWT y CORS configurados | ☐ |

Fecha de ejecución: ____________ Responsable: ____________
