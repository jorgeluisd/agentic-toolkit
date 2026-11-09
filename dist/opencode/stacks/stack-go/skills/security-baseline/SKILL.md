---
name: security-baseline
description: "Baseline de seguridad verificable para la API Go en Lambda: validación de entrada contra el OpenAPI y en los value objects, límites de tamaño de body, listas y páginas, secretos solo en SSM Parameter Store leídos en el init, config validada sin repetir valores, IAM mínimo (dsql:DbConnect vs DbConnectAdmin), token IAM para la DB, link público con token aleatorio, headers de respuesta, sin datos personales en logs ni artefactos, gosec y govulncheck. Usar cuando se toca auth, inputs, secretos, configuración, permisos, datos personales o se revisa un PR."
---

# Baseline de seguridad

Cada regla tiene una mitigación mecánica y una forma de verificarla. Ninguna depende de que el revisor se acuerde de mirar. La autenticación y la autorización están en `http-lambda` §2 y §3, `api-contract-openapi` §3 y `application-cqrs` §5, el aislamiento por tenant en `multi-tenancy-app-level`, y los logs en `logging-slog`.

## 1. Validación de entrada

| Regla | Mecánica | Cómo se verifica |
|---|---|---|
| El request se valida contra el contrato antes del handler | Middleware `OapiRequestValidator` (`github.com/oapi-codegen/nethttp-middleware`) con el spec embebido; los errores van a `httpx.WriteError` como `KindMalformed` | Test HTTP: campo de más, tipo equivocado y string demasiado largo → 400 con `code` |
| Esquemas cerrados | Todo `object` del OpenAPI con `additionalProperties: false`; todo `string` con `maxLength` (y `format`/`pattern` cuando aplica); todo `array` con `maxItems` | Lint del spec en el CI (skill `api-contract-openapi` §4) |
| La regla de negocio se valida en el dominio | Los value objects validan en su constructor (`NewMinute`, `ParseMatchID`); el OpenAPI no reemplaza al dominio | Tests de dominio (skill `domain-modeling` §6) |
| IDs de ruta parseados, nunca concatenados | `domain.ParseMatchID(chi.URLParam(r, "id"))` antes de usarlo | sqlc usa parámetros, así que no hay SQL armado a mano: `grep -rn 'fmt.Sprintf("SELECT' internal` vacío |
| Teléfonos normalizados al cargarlos | Formato internacional sin `+` para `wa.me`, validado en un value object | Test del value object con casos de cada país que se soporte |

## 2. Límites de tamaño

| Límite | Valor | Cómo se verifica |
|---|---|---|
| Body | `httpx.LimitBody(64 KiB)` en el router (API Gateway acepta hasta 10 MB y Lambda 6 MB; el límite propio es mucho menor) | `TestLimitBody_RejectsOversizedBodies` de la plantilla |
| Lotes que manda el cliente (cola offline) | `maxItems: 100` en el spec; la API procesa con `db.Chunks` | Test HTTP con 101 eventos → 400 |
| Paginación | `limit` con `maximum: 100` y default 20; cursor opaco, nunca `offset` libre | Test de la query con `limit=1000` → 400 |
| Tiempo | Timeout de la Lambda ≤ 10 s; todo I/O con el `ctx` de la request | `<lint>`: `noctx` y `contextcheck` |

## 3. Secretos y configuración

| Regla | Mecánica | Cómo se verifica |
|---|---|---|
| Secretos solo en **SSM Parameter Store** (`SecureString`, KMS) | Las variables de entorno llevan el **nombre** del parámetro, nunca el valor; `cmd/api` hace un `GetParameters` en lote con `WithDecryption` en el init | `grep -rn -e PASSWORD -e SECRET -e TOKEN <infra>/` solo encuentra nombres de parámetros; revisión de la config de la Lambda |
| La DB no tiene contraseña | Token IAM por conexión (`db.NewDSQLPool`); el rol de la Lambda solo tiene `dsql:DbConnect` sobre su clúster. `dsql:DbConnectAdmin` lo tiene solo el rol de `cmd/migrate` | Revisión de la política IAM en el CDK; un test de CDK (assertions) que falle si el rol de la API tiene `DbConnectAdmin` |
| La config se valida al arrancar y los errores nombran la variable, nunca el valor | `config.Load(os.Getenv)` con `getenv` inyectado; devuelve error ante un valor faltante o malformado | Test de `config.Load` con un `getenv` falso: el error contiene el nombre y no el valor |
| Nada secreto en el repo | `gitleaks` en el CI sobre el diff del PR | Job `supply-chain` de `templates/ci.yml` |
| Cognito sin client secret para la PWA | App client público con PKCE; el secreto no puede vivir en un front estático | Config de CDK |

## 4. El link público del partido

El link en vivo que se comparte por WhatsApp se abre sin login, así que:

- La ruta lleva un **token aleatorio de 128 bits** (`crypto/rand`, base64url), nunca el ID del partido ni el `coach_id`. Se guarda con un hash (SHA-256) y la búsqueda es por el hash.
- Da acceso de **solo lectura** a ese partido, y el profe lo puede revocar o regenerar.
- La respuesta no incluye datos personales de los alumnos más allá de lo que el profe decidió mostrar (nombre de pila o número de camiseta).
- Throttling por ruta en API Gateway (rate y burst) para frenar la enumeración.

**Cómo se verifica:** test del generador (largo y alfabeto), test de la query que busca por hash, y test HTTP: token inválido → 404, token revocado → 404.

## 5. Respuestas

| Regla | Cómo se verifica |
|---|---|
| `Content-Type` explícito; `X-Content-Type-Options: nosniff` y `Cache-Control: no-store` con `httpx.SecureHeaders` en el router | `TestSecureHeaders_SetsNosniffAndNoStore` de la plantilla |
| El body de error es problem+json sin `err.Error()` ni stack | `TestWriteError_MapsEachKindInOnePlace` |
| CORS solo para el origen de la PWA, configurado en API Gateway | Config de CDK; ninguna Lambda escribe `Access-Control-Allow-Origin` |
| Archivos de S3 (comprobantes, fotos autorizadas) solo por URL prefirmada de vida corta (≤ 5 min), generada después de comprobar tenant y permiso | Test del adapter de S3 con el fake del presigner |

## 6. Datos personales

- Minimización: se guarda lo que el producto usa. Las fotos de menores solo se aceptan con la autorización registrada, y la API lo verifica antes de emitir la URL de subida.
- Nunca en logs, en artefactos de SDD, en fixtures ni en commits: los ejemplos son sintéticos (`example.com`, nombres inventados).
- Borrado: cuando se da de baja un alumno se borran sus datos personales, y quedan solo IDs para las estadísticas.

**Cómo se verifica:** test anti-fuga de logs (skill `logging-slog` §5) y revisión del `security-reviewer` sobre el diff.

## 7. Análisis estático y dependencias

- `gosec` corre dentro de `<lint>`. Todo `//nolint:gosec` lleva el código de la regla y el porqué en la misma línea.
- `go tool -modfile=tools/go.mod govulncheck ./...` (`<audit>`) en cada PR. Solo falla con vulnerabilidades **alcanzables** desde el código; si hay una, se sube la dependencia (skill `dependency-upgrade`) o se registra la excepción con fecha de revisión.
- Las Actions del CI van fijadas por SHA, con `permissions` mínimos por job y despliegue por OIDC (sin claves de AWS en secretos de GitHub).

## 8. Checklist

- [ ] ¿El request se valida contra el OpenAPI (esquema cerrado, `maxLength`, `maxItems`) y en los value objects?
- [ ] ¿Body limitado y paginación con máximo?
- [ ] ¿Secretos solo en SSM, leídos en lote en el init, y la config falla nombrando la variable?
- [ ] ¿El rol de la API sin `DbConnectAdmin`?
- [ ] ¿Link público con token aleatorio hasheado, de solo lectura y revocable?
- [ ] ¿`nosniff` y `no-store` en las respuestas autenticadas, y URLs prefirmadas cortas?
- [ ] ¿`<lint>` (gosec) y `<audit>` (govulncheck) en verde?
