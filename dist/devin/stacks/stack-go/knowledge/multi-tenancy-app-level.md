# multi-tenancy-app-level

**Cuándo aplica (trigger de la entrada de Knowledge):** Aislamiento por tenant sin RLS (Aurora DSQL): el tenant sale siempre del JWT por middleware, viaja en el context hasta el adapter y desde ahí como tenant.ID explícito en commands, puertos y queries; cada query de sqlc filtra por coach_id; 404 entre tenants; tests mecánicos por AST y test de integración cross-tenant. Usar cuando se toca una tabla, una query, un repositorio, un puerto, un endpoint o el middleware de auth.

---

# Multi-tenancy en la aplicación

Aurora DSQL no tiene RLS (o no está documentado, así que se asume que no). El aislamiento por tenant (`coach_id`) depende entonces **solo** del código. Por eso se aplica en capas que se verifican solas, y no por cuidado de quien escribe.

## 1. Flujo del tenant

```
Authorization: Bearer <access token>
  → auth.Operations.Check  valida el token, lee el claim de tenant, arma el Principal
  → context                auth.WithPrincipal(ctx, p)
  → adapters/http          p := auth.FromContext(ctx); cmd.Tenant = p.Tenant
  → application            Handle(ctx, cmd)  — cmd.Tenant es un tenant.ID
  → puerto                 Matches.Update(ctx, cmd.Tenant, ...)
  → adapters/postgres      WHERE coach_id = @coach_id
```

| Regla | Cómo se verifica |
|---|---|
| El tenant sale **solo** del token validado. Nunca del body, de la query string, de un header propio (`X-Coach-Id`) ni de la ruta | El OpenAPI no declara `coach_id` en ningún request; test de handler HTTP de §4 |
| `tenant.ID` no tiene valor cero válido: `tenant.Parse` exige UUID y `ID{}` es un bug | Test de `tenant.Parse`; el adapter rechaza `t.IsZero()` antes de consultar |
| Desde el adapter HTTP hacia adentro, el tenant es un **argumento explícito**. `application` y los repos no lo leen del `context` | `TestPorts_TakeTenantAfterContext` (§3) |
| Toda query de sqlc filtra por `coach_id`, también en `UPDATE` y `DELETE` | `TestQueries_FilterByTenant` (§3) |
| Recurso de otro tenant → **404**, indistinguible de uno que no existe | Test de integración de §4 |
| Toda tabla con datos de un tenant tiene `coach_id uuid NOT NULL` y lo lleva en la PK o en un índice único que empieza por él | Revisión de la migración; skill `persistence-sqlc-dsql` §2 |

## 2. El claim de tenant

El access token de Cognito no trae atributos propios. El claim (`coach_id`) se agrega con el trigger **pre token generation V2** (`claimsAndScopeOverrideDetails.accessTokenGeneration.claimsToAddOrOverride`), que lo lee de la tabla de membresías o de un atributo del usuario. `auth.Config.TenantClaim` dice qué claim leer. Si un mismo usuario pertenece a más de un tenant (un padre con hijos en dos profes), el token lleva **un** tenant activo, elegido al iniciar sesión. Cambiar de tenant es volver a pedir el token, nunca mandar otro tenant en el request. Ese diseño se registra en un ADR del producto. **Cómo se verifica:** `TestVerify_RejectsEachInvalidToken` de la plantilla `templates/auth/` cubre token sin tenant y tenant que no es UUID.

## 3. Enforcement mecánico (archtest)

Plantilla `templates/archtest/tenant_test.go` → `internal/archtest/tenant_test.go`:

- **`TestPorts_TakeTenantAfterContext`** parsea cada `internal/*/application/*.go` y falla si un método de interface recibe `context.Context` pero no `tenant.ID` como segundo argumento. Los puertos sin tenant (reloj, IDs) van en `tenantlessPorts` con su porqué, y esa lista se revisa en el PR que la toca.
- **`TestQueries_FilterByTenant`** recorre `internal/*/adapters/postgres/queries/*.sql` y falla si un bloque `-- name:` no tiene `coach_id = @coach_id`. La excepción se declara debajo del nombre: `-- tenant: global — <porqué>`.
- **`TestTenantChecks_Bite`** prueba que los dos chequeos muerden con fuentes de ejemplo.

Si el nombre de la columna no es `coach_id`, se cambia en `tenantFilter` y en esta skill, en el mismo PR.

## 4. Tests obligatorios

**Integración cross-tenant**, uno por repositorio, contra Postgres local (skill `testing-conventions` §4):

```go
func TestMatches_IsolatesTenants(t *testing.T) {
	repo, a, b := newRepo(t), newTenant(t), newTenant(t)
	id := seedMatch(t, repo, a)

	_, err := repo.Get(t.Context(), b, id)
	require.ErrorIs(t, err, application.ErrMatchNotFound)

	_, _, err = repo.Update(t.Context(), b, id, newEventID(t), func(m *domain.Match) error { return m.Start() })
	require.ErrorIs(t, err, application.ErrMatchNotFound)

	m, err := repo.Get(t.Context(), a, id)
	require.NoError(t, err)
	require.Equal(t, domain.StatusScheduled, m.Status())
}
```

**Handler HTTP:** un request con token del tenant A y un body que intenta colar `"coach_id": "<B>"` (o un header `X-Coach-Id`) tiene que terminar con el command armado para A. Si el DTO generado rechaza campos desconocidos, la respuesta es 400. En cualquiera de los dos casos, nunca se toca B. Se verifica con un fake de handler que captura el command.

## 5. Otros caminos por donde se filtra un tenant

| Camino | Regla |
|---|---|
| Canal de AppSync Events | Nombre del canal con el tenant y el recurso (`/coach/<coach_id>/match/<id>`). La autorización del canal es pública solo para lectura del link en vivo, y el link lleva un token propio del partido, nunca el `coach_id` adivinable |
| Archivos en S3 | Prefijo `coach/<coach_id>/...`; URL prefirmada de vida corta, generada después de comprobar el tenant |
| Logs | El `coach_id` puede ir (no es dato personal); nombres, teléfonos y datos de menores no (skill `logging-slog`) |
| Caché en memoria de la Lambda | La clave incluye siempre el tenant; nada de cachés globales por ID de recurso |
| Tareas programadas (EventBridge Scheduler) | Una ejecución por tenant, con el tenant en el payload firmado por la infraestructura, nunca "todos los tenants en una transacción" (límite de 3.000 filas de DSQL) |

## 6. Checklist

- [ ] ¿El tenant sale solo del token validado, y el OpenAPI no lo acepta en ningún request?
- [ ] ¿Commands, puertos y repos reciben `tenant.ID` explícito? (`TestPorts_TakeTenantAfterContext`)
- [ ] ¿Toda query nueva filtra por `coach_id`, o lleva `-- tenant: global — <porqué>`? (`TestQueries_FilterByTenant`)
- [ ] ¿Test de integración cross-tenant del repo (lectura y escritura) con 404?
- [ ] ¿Canales, prefijos de S3, cachés y tareas programadas llevan el tenant en la clave?
