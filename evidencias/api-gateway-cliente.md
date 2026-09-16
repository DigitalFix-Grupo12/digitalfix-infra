# Evidencia API Gateway - DigitalFix

- Fecha: 2026-09-16 04:03:46 (hora local)
- API: https://7s6qn2mb8h.execute-api.us-east-1.amazonaws.com
- Usuario: cliente.demo@tenatkevin.onmicrosoft.com | roles: Cliente | scp: access_as_user
- iss: https://login.microsoftonline.com/ac1c32f1-bc10-4ded-b8c0-102ac9a1fd68/v2.0 | aud: fb8ea665-ee45-4790-8112-eade3bd230e5 | exp: 09/16/2026 05:23:50

## Ruta publica
| Ruta | Status | Respuesta |
|---|---|---|
| GET /actuator/health | 200 | `{"status":"UP"}` |

## Rutas protegidas (JWT Authorizer + autorizacion por rol en el BFF)
| Ruta | Roles | Sin token | Token invalido | Con token | Esperado | Respuesta con token |
|---|---|---|---|---|---|---|
| GET /api/workorders | Admin, Supervisor, Cliente | 401 | 401 | 200 | 401 / 401 / 200 | `[{"id":4,"descripcion":"Evidencia: falla de alumbrado publico","clienteId":"cliente-eviden...` |
| GET /api/workorders/1 | Admin, Supervisor, Cliente | 401 | 401 | 200 | 401 / 401 / 200 | `{"id":1,"descripcion":"Corte de energía en sector norte","clienteId":"cliente-001","tecnic...` |
| GET /api/catalog/services | Admin, Supervisor | 401 | 401 | 403 | 401 / 401 / 403 | `` |
| GET /api/catalog/services/1 | Admin, Supervisor | 401 | 401 | 403 | 401 / 401 / 403 | `` |
| GET /api/report/kpis?range=last24h | Admin | 401 | 401 | 403 | 401 / 401 / 403 | `` |
| GET /api/audit?limit=5 | Admin, Auditor | 401 | 401 | 403 | 401 / 401 / 403 | `` |

## CORS (preflight)
| Origen | Status | Access-Control-Allow-Origin | Allow-Methods |
|---|---|---|---|
| https://main.dehlzhnwtqj7a.amplifyapp.com | 204 | https://main.dehlzhnwtqj7a.amplifyapp.com | GET,OPTIONS,POST,PUT |
| http://localhost:4200 | 204 | http://localhost:4200 | GET,OPTIONS,POST,PUT |
| https://sitio-no-autorizado.example | 204 |  |  |

Resultado: todas las rutas responden lo esperado