# Evidencia API Gateway - DigitalFix

- Fecha: 2026-09-16 02:01:09 (hora local)
- API: https://7s6qn2mb8h.execute-api.us-east-1.amazonaws.com

## Ruta publica
| Ruta | Status | Respuesta |
|---|---|---|
| GET /actuator/health | 200 | `{"status":"UP"}` |

## Rutas protegidas (JWT Authorizer + autorizacion por rol en el BFF)
| Ruta | Roles | Sin token | Token invalido | Con token | Esperado | Respuesta con token |
|---|---|---|---|---|---|---|
| GET /api/workorders | Admin, Supervisor, Cliente | 401 | 401 | - | 401 / 401 |  |
| GET /api/workorders/1 | Admin, Supervisor, Cliente | 401 | 401 | - | 401 / 401 |  |
| GET /api/catalog/services | Admin, Supervisor | 401 | 401 | - | 401 / 401 |  |
| GET /api/catalog/services/1 | Admin, Supervisor | 401 | 401 | - | 401 / 401 |  |
| GET /api/report/kpis?range=last24h | Admin | 401 | 401 | - | 401 / 401 |  |
| GET /api/audit?limit=5 | Admin, Auditor | 401 | 401 | - | 401 / 401 |  |

## CORS (preflight)
| Origen | Status | Access-Control-Allow-Origin | Allow-Methods |
|---|---|---|---|
| https://main.dehlzhnwtqj7a.amplifyapp.com | 204 | https://main.dehlzhnwtqj7a.amplifyapp.com | GET,OPTIONS,POST,PUT |
| http://localhost:4200 | 204 | http://localhost:4200 | GET,OPTIONS,POST,PUT |
| https://sitio-no-autorizado.example | 204 |  |  |

Resultado: todas las rutas responden lo esperado