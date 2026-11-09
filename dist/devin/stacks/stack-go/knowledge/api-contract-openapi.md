# api-contract-openapi

**Cuándo aplica (trigger de la entrada de Knowledge):** Contrato API con OpenAPI 3.0 como fuente de verdad: api/openapi.yaml cerrado (additionalProperties false, maxLength, maxItems), oapi-codegen genera modelos, servidor chi y la interfaz estricta en internal/apigen, openapi-typescript genera los tipos del front, el security de cada operación declara los roles y se hace cumplir por operationId, el validador rechaza lo que el contrato no permite, y el CI falla si el código generado no coincide. Usar cuando se agrega o cambia un endpoint, un esquema, un código de error, un rol de una operación o el cliente del front.

---

# Contrato API: OpenAPI como fuente de verdad

Backend en Go y frontend en TypeScript se unen por **un archivo**, `api/openapi.yaml`. Todo lo demás se genera desde ahí: los modelos y la interfaz del servidor (oapi-codegen), los tipos del front (openapi-typescript) y los roles por operación. Primero se cambia el contrato, después se regenera y recién ahí se escribe el código. Plantillas: `templates/api/` y `templates/cmd/api/router.go`.

## 1. El archivo

| Regla | Cómo se verifica |
|---|---|
| OpenAPI **3.0.3** (la versión que oapi-codegen y kin-openapi soportan completa) | `openapi: 3.0.3` en la primera línea; lint del spec (§4) |
| Todo `object` con `additionalProperties: false` y `required` explícito | Lint del spec con la regla propia (§4) |
| Todo `string` con `maxLength` (y `format: uuid`, `date-time`, `pattern` cuando aplica); todo `integer` con `minimum`/`maximum` cuando tiene rango; todo `array` con `maxItems` | Lint del spec |
| Toda operación con `operationId` en camelCase y **`security` explícito**: `[]` si es pública, `[{ cognito: [rol, …] }]` si pide roles, `[{ cognito: [] }]` si alcanza con estar autenticado | `auth.OperationsFromSpec` falla en el arranque y en `<test>` si falta (§3) |
| Errores como `application/problem+json` con el esquema `Problem`; los `code` posibles documentados por operación | Revisión; el `code` es el mismo `Code` de `*errs.Error` |
| El tenant (`coach_id`) **nunca** aparece en un request | `grep -n coach api/openapi.yaml` solo encuentra respuestas, si acaso |
| Fechas en `date-time` UTC; dinero como `integer` en unidad menor con `currency` | Revisión |
| Cambios compatibles hacia atrás: agregar campos opcionales o endpoints nuevos. Quitar o cambiar un campo es un cambio de versión (`/v2/...`) con ADR | Revisión del diff del spec en el PR |

## 2. Generación

```yaml
# api/oapi-codegen.yaml
package: apigen
output: internal/apigen/apigen.gen.go
generate:
  models: true
  chi-server: true
  strict-server: true
  embedded-spec: true
```

```bash
go tool -modfile=tools/go.mod oapi-codegen -config api/oapi-codegen.yaml api/openapi.yaml
pnpm --dir web exec openapi-typescript ../api/openapi.yaml -o src/api/schema.d.ts
```

- `internal/apigen` es la capa `contract` del archtest: no importa nada del módulo, no se edita a mano y se commitea.
- **Interfaz estricta:** `apigen.StrictServerInterface` tiene un método por operación con request y response tipados. Cada contexto implementa sus métodos en `adapters/http` (un struct por contexto), y `cmd/api` los compone embebiéndolos en un struct `server` que satisface la interfaz completa. Si falta un método, el binario no compila.
- **Front:** `openapi-typescript` (versión exacta en `web/package.json`) genera `schema.d.ts`, y el cliente lo usa con `openapi-fetch` (skill `frontend-react-vite-pwa` de stack-typescript). El front no declara tipos de la API a mano.

## 3. Roles desde el contrato

`templates/cmd/api/router.go` arma el borde a partir del spec embebido (`apigen.GetSpec()`):

1. `auth.OperationsFromSpec(spec, "cognito")` lee el `security` de cada operación y arma `operationId → {Public | Roles}`. Si una operación no declara `security`, devuelve error y la Lambda no arranca.
2. `OapiRequestValidatorWithOptions` (de `github.com/oapi-codegen/nethttp-middleware`) valida path, query y body contra el spec, con `NoopAuthenticationFunc` porque la autenticación va en el paso siguiente. Un campo de más, un tipo equivocado o un valor fuera de rango → 400 `REQUEST_INVALID`; una ruta inexistente → 404 `ROUTE_NOT_FOUND`.
3. Un `StrictMiddlewareFunc` llama a `ops.Check(verifier, operationID, r)`: lo público pasa, lo demás exige un token válido y uno de los roles del contrato (401 o 403), y deja el `Principal` en el `context`.
4. Los errores del handler van a `ResponseErrorHandlerFunc` → `httpx.WriteError`.

**Cómo se verifica:** `TestOperationsFromSpec_FailsWhenAnOperationDoesNotDeclareSecurity` y `TestRouter_EnforcesTheContract` de las plantillas. El segundo cubre rol permitido, rol denegado, sin token, token inválido, campo de más, valor fuera de rango, ID de ruta inválido, ruta pública y ruta inexistente. Cada operación nueva suma su fila de rol permitido y denegado.

## 4. CI: el contrato y el código no se separan

En `templates/ci.yml`, job `contract`:

```bash
go tool -modfile=tools/go.mod oapi-codegen -config api/oapi-codegen.yaml api/openapi.yaml
go tool -modfile=tools/go.mod sqlc generate
pnpm --dir web exec openapi-typescript ../api/openapi.yaml -o src/api/schema.d.ts
git diff --exit-code -- internal/apigen internal/*/adapters/postgres/gen web/src/api/schema.d.ts
```

Si alguien editó el spec y no regeneró, o editó el código generado a mano, el `git diff` falla. El lint del spec también corre ahí: `pnpm dlx @redocly/cli@<versión exacta> lint api/openapi.yaml`, con una regla de `redocly.yaml` que exige `additionalProperties: false` en todo `object` y `maxLength` en todo `string`.

## 5. Flujo para un endpoint nuevo

1. Escribir la operación en `api/openapi.yaml`: `operationId`, `security` con los roles, request cerrado, respuestas y `code`s de error.
2. Regenerar (§2). El build se rompe porque falta el método de la interfaz estricta: ese es el RED de tipos.
3. Test HTTP de la operación (rol permitido y denegado, validación, caso feliz) contra el router con un fake de application.
4. Implementar el método en `adapters/http` del contexto, que traduce request → command y result → response.
5. El front consume los tipos regenerados en el mismo PR o en uno inmediato, nunca con tipos escritos a mano.

## 6. Checklist

- [ ] ¿El cambio empezó por `api/openapi.yaml`?
- [ ] ¿Esquemas cerrados, con `maxLength`, `maxItems` y rangos?
- [ ] ¿`operationId` y `security` explícitos en cada operación?
- [ ] ¿`internal/apigen` y `schema.d.ts` regenerados y commiteados, y el job `contract` en verde?
- [ ] ¿Test de router con rol permitido y denegado para la operación nueva?
- [ ] ¿Cambio compatible hacia atrás, o versión nueva con ADR?
