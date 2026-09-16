# Guía de usuario por rol — DigitalFix

Aplicación: https://main.dehlzhnwtqj7a.amplifyapp.com

## Cómo ingresar

1. Abrir la aplicación y presionar **Iniciar sesión con Microsoft**.
2. Escribir el usuario completo (`nombre@tenatkevin.onmicrosoft.com`) y la contraseña.
3. Microsoft devuelve al usuario al panel. El inicio de sesión usa el flujo
   Authorization Code con PKCE; la aplicación nunca ve la contraseña.
4. Los usuarios nuevos pueden registrarse con **Crear cuenta** (flujo de registro
   de Entra ID). Un administrador debe asignarles un rol antes de que vean datos.

> Si el usuario no tiene un rol asignado, la aplicación muestra "Sin rol asignado"
> y el backend responde 403 en todas las rutas protegidas.

## Qué puede hacer cada rol

| Pantalla | Admin | Supervisor | Cliente | Auditor |
|---|:-:|:-:|:-:|:-:|
| Panel (dashboard) | ✅ | ✅ | ✅ (solo sus órdenes) | ✅ |
| Órdenes de trabajo — ver | ✅ | ✅ | ✅ (solo las propias) | — |
| Órdenes de trabajo — crear | ✅ | ✅ | ✅ (a su nombre) | — |
| Órdenes de trabajo — asignar / avanzar / cancelar | ✅ | ✅ | — | — |
| Catálogo de servicios y repuestos | ✅ | ✅ | — | — |
| Reportes (KPIs) | ✅ | — | — | — |
| Auditoría | ✅ | — | — | ✅ |
| Mi sesión (claims del token y prueba de rutas) | ✅ | ✅ | ✅ | ✅ |

### Admin

- Acceso completo. Revisa KPIs en **Reportes** (últimas 24 h o 7 días).
- Consulta la **Auditoría** para ver quién creó o modificó cada orden.

### Supervisor

- Crea órdenes indicando el cliente.
- En el tablero de **Órdenes de trabajo** mueve cada ticket con un solo botón:
  *Asignar técnico → Enviar a terreno → Iniciar trabajo → Cerrar orden*.
- Puede cancelar una orden antes de que empiece el trabajo.
- Consulta el **Catálogo** para ver tarifas y stock de repuestos.

### Cliente

- Crea solicitudes de servicio; quedan registradas a su nombre automáticamente.
- Solo ve sus propias órdenes y su estado. Si intenta abrir una orden ajena,
  el backend responde 404.

### Auditor

- Solo lectura sobre la **Auditoría**: filtra por usuario, acción u orden y
  exporta el resultado a CSV.

## Estados de una orden

`CREADA → ASIGNADA → EN_DESPLAZAMIENTO → EN_EJECUCION → CERRADA` (o `CANCELADA` antes de
`EN_EJECUCION`). Un salto no permitido devuelve 409.

## Problemas frecuentes

| Síntoma | Causa | Solución |
|---|---|---|
| Error 401 al cargar datos | Token vencido | Cerrar sesión y volver a entrar |
| Error 403 | El rol no tiene permiso para esa pantalla | Usar un usuario con el rol adecuado |
| Error 503 / "Backend fuera de línea" | La EC2 está detenida (Learner Lab) | Iniciar el lab y esperar 2-3 minutos |
| El login abre una cuenta personal de Microsoft | Se escribió solo "admin.demo" | Usar el correo completo del tenant |
