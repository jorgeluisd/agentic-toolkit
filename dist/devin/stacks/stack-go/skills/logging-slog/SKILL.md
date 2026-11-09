---
name: logging-slog
description: "Logging con log/slog en JSON: logger único con lista cerrada de claves (todo lo demás se descarta), mensaje estático {contexto}.{acción}.{resultado}, solo slog.Attr con claves camelCase (sloglint), requestId y campos estándar, una línea por request, errores por tipo y código sin err.Error() de terceros, niveles por entorno, y nunca datos personales ni de menores, con test anti-fuga. Usar cuando se configura el logger, se agrega un log o se revisa qué sale a CloudWatch."
---

# Logging con slog

Un solo logger, JSON a stdout (CloudWatch lo toma tal cual), armado en `cmd/api` y pasado por parámetro. La regla de fondo es **fail-closed**: lo que no está en la lista de claves permitidas no se escribe, aunque alguien lo pase por error. Plantilla: `templates/applog/` → `internal/platform/applog/`.

## 1. El logger

```go
logger := applog.New(os.Stdout, "api", applog.Level(cfg.Env), "matchId", "categoryId")
```

| Regla | Cómo se verifica |
|---|---|
| `slog.NewJSONHandler` con `ReplaceAttr` que descarta toda clave fuera de la lista y todo atributo dentro de un grupo | `TestNew_DropsEveryKeyOutsideTheAllowlist` de la plantilla |
| Lista base: `time`, `level`, `msg`, `service`, `requestId`, `method`, `route`, `status`, `durationMs`, `code`, `errorType`, `op`, `attempt`, `coachId`. Cada contexto agrega sus IDs (`matchId`) en `New` | Agregar una clave es un cambio de una línea en `cmd/api`, visible en el diff |
| Ningún logger global: ni `slog.SetDefault` ni `slog.Info` del paquete. El logger entra por parámetro o por el struct del handler | `<lint>`: `sloglint`; `grep -rn -e 'slog\.Info(' -e 'slog\.Warn(' -e 'slog\.Error(' -e 'slog\.Debug(' -e 'slog\.SetDefault(' internal` vacío |
| Sin otras librerías de logging | `<lint>`: depguard prohíbe `logrus` y `zap` |
| Nivel `Info` en staging y prod, `Debug` solo con `ENV=dev` | `applog.Level`; test de la plantilla |

## 2. Forma de cada log

```go
log.LogAttrs(ctx, slog.LevelInfo, "matches.goal.recorded",
	slog.String("requestId", httpx.RequestID(ctx)),
	slog.String("coachId", cmd.Tenant.String()),
	slog.String("matchId", cmd.Match.String()),
)
```

- **Mensaje estático** `{contexto}.{acción}.{resultado}` en minúscula (`matches.goal.recorded`, `billing.fee.failed`). Nunca `fmt.Sprintf` en el mensaje: el valor va como atributo, y el atributo pasa por la lista.
- **Solo `slog.Attr`** (`slog.String`, `slog.Int`), nunca pares sueltos `"k", v`. Claves en camelCase.
- `requestId` siempre que haya request; el log de acceso (`httpx.AccessLog`) lo pone en su única línea por request, junto con `method`, `route` (el patrón de chi, nunca la URL cruda), `status` y `durationMs`.
- `LogAttrs` con `ctx` en vez de `Info(...)`: evita el costo de `any` y mantiene el contexto.

**Cómo se verifica:** `<lint>` con `sloglint` (`attr-only`, `static-msg`, `key-naming-case: camel`).

## 3. Errores

- Un error se loguea **una vez**, en el borde (`httpx.WriteError` para los 500, o el worker que lo descarta). Quien lo devuelve no lo loguea.
- Del error va `code` (si es `*errs.Error`) o `errorType` (`%T`), y `op` si el adapter la conoce. **Nunca** `err.Error()` de pgx, del SDK de AWS o de un tercero, porque esos mensajes repiten valores de filas o de requests.
- Un panic se loguea sin su valor (`httpx.Recover`).
- Un conflicto OCC reintentado es `Debug` con `attempt`. Solo el agotamiento de reintentos es `Warn`.

## 4. Eventos que siempre se loguean

| Evento | Nivel | Claves |
|---|---|---|
| Request terminada | Info | `requestId`, `method`, `route`, `status`, `durationMs` |
| 5xx | Error | lo anterior más `code` o `errorType` |
| Autenticación rechazada | Info | `requestId`, `route`, `code` (nunca el token) |
| Autorización fina denegada | Info | `requestId`, `coachId`, `code`, ID del recurso |
| Reintentos OCC agotados | Warn | `requestId`, `op`, `attempt` |
| Migración aplicada (cmd/migrate) | Info | `op`, versión |

## 5. Datos personales y de menores

Los alumnos son menores. **Nunca** salen a un log: nombre, apellido, fecha de nacimiento, documento, foto, teléfono o email del alumno o de su familia, ni el texto de un mensaje de WhatsApp armado. Lo mismo para el profe y los delegados, salvo su `sub` de Cognito (que no es dato personal). Solo se loguean IDs opacos (UUID).

**Cómo se verifica:**

- La lista cerrada hace que `slog.Any("player", p)` no escriba nada. Lo prueba `TestNew_DropsEveryKeyOutsideTheAllowlist`, con datos sintéticos.
- `static-msg` impide interpolar un nombre en el mensaje.
- Un test por contexto que ejercita el caso de uso con datos sintéticos reconocibles (un nombre y un teléfono inventados), captura el log en un `bytes.Buffer` y asserta que esos valores no aparecen. Es obligatorio en todo contexto que maneje alumnos o familias.

## 6. Checklist

- [ ] ¿El log usa el logger inyectado, `LogAttrs` con `ctx` y mensaje estático?
- [ ] ¿Toda clave nueva está agregada a la lista en `cmd/api`, y ninguna lleva un dato personal?
- [ ] ¿El error sale como `code`/`errorType`, sin `err.Error()` de terceros, y una sola vez?
- [ ] ¿El contexto con datos de alumnos tiene su test anti-fuga con datos sintéticos?
- [ ] ¿`<lint>` en verde con `sloglint`?
