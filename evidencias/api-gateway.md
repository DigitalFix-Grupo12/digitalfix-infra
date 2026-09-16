# Evidencia API Gateway - DigitalFix

- Fecha: 2026-09-16 03:56:07 (hora local)
- API: https://7s6qn2mb8h.execute-api.us-east-1.amazonaws.com
- Usuario: admin.demo@tenatkevin.onmicrosoft.com | roles: Admin | scp: access_as_user
- iss: https://login.microsoftonline.com/ac1c32f1-bc10-4ded-b8c0-102ac9a1fd68/v2.0 | aud: fb8ea665-ee45-4790-8112-eade3bd230e5 | exp: 09/16/2026 05:18:08

## Ruta publica
| Ruta | Status | Respuesta |
|---|---|---|
| GET /actuator/health | 200 | `{"status":"UP"}` |

## Rutas protegidas (JWT Authorizer + autorizacion por rol en el BFF)
| Ruta | Roles | Sin token | Token invalido | Con token | Esperado | Respuesta con token |
|---|---|---|---|---|---|---|
| GET /api/workorders | Admin, Supervisor, Cliente | 401 | 401 | 200 | 401 / 401 / 200 | `[{"id":3,"descripcion":"Cambio de medidor domiciliario","clienteId":"cliente-003","tecnico...` |
| GET /api/workorders/1 | Admin, Supervisor, Cliente | 401 | 401 | 200 | 401 / 401 / 200 | `{"id":1,"descripcion":"Corte de energía en sector norte","clienteId":"cliente-001","tecnic...` |
| GET /api/catalog/services | Admin, Supervisor | 401 | 401 | 200 | 401 / 401 / 200 | `[{"id":1,"nombre":"Cambio de tablero eléctrico","tipo":"SERVICIO","stock":12,"tarifa":4500...` |
| GET /api/catalog/services/1 | Admin, Supervisor | 401 | 401 | 200 | 401 / 401 / 200 | `{"id":1,"nombre":"Cambio de tablero eléctrico","tipo":"SERVICIO","stock":12,"tarifa":45000...` |
| GET /api/report/kpis?range=last24h | Admin | 401 | 401 | 200 | 401 / 401 / 200 | `{"range":"last24h","generadoEn":"2026-09-16T06:56:13.504192836Z","totalOrdenes":3,"ordenes...` |
| GET /api/audit?limit=5 | Admin, Auditor | 401 | 401 | 200 | 401 / 401 / 200 | `[]` |

## Flujo de escritura
- POST /api/workorders -> **201** `{"id":4,"descripcion":"Evidencia: falla de alumbrado publico","clienteId":"cliente-evidencia","tecnicoId":null,"status":...`
- PUT status CREADA -> EN_EJECUCION (regla de negocio) -> **409** ``
- PUT status -> ASIGNADA -> **200**
- PUT status -> EN_DESPLAZAMIENTO -> **200**
- PUT status -> EN_EJECUCION -> **200**
- PUT status -> CERRADA -> **200**
- GET /api/audit -> **200** `[{"id":5,"usuario":"admin.demo@tenatkevin.onmicrosoft.com","accion":"CAMBIO orden #4: EN_EJECUCION -> CERRADA","servicio":"ms-digitalfix-workorders","referencia...`

## CORS (preflight)
| Origen | Status | Access-Control-Allow-Origin | Allow-Methods |
|---|---|---|---|
| https://main.dehlzhnwtqj7a.amplifyapp.com | 204 | https://main.dehlzhnwtqj7a.amplifyapp.com | GET,OPTIONS,POST,PUT |
| http://localhost:4200 | 204 | http://localhost:4200 | GET,OPTIONS,POST,PUT |
| https://sitio-no-autorizado.example | 204 |  |  |

Resultado: todas las rutas responden lo esperado