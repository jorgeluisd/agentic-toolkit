# stack-go

Skills técnicas del stack Go para [`sdd-tdd-core`](../sdd-tdd-core): **una Lambda en Go (arm64, `provided.al2023`) con chi, Aurora DSQL con sqlc + pgx, Cognito y OpenAPI con oapi-codegen**, con Onion + Screaming Architecture y enforcement por depguard y archtest.

Este plugin no define proceso — eso lo hace el core. Define **cómo se escribe el código**: en qué capa va cada paquete, cómo se modela el dominio, cómo se manejan los errores, cómo se aísla un tenant sin RLS, dónde va cada test y qué está prohibido.

---

## Instalación

```bash
claude plugin marketplace add jorgeluisd/agentic-toolkit
claude plugin install sdd-tdd-core@agentic-toolkit      # requerido
claude plugin install stack-go@agentic-toolkit
```

Instalarlo sin el core no tiene sentido: aporta skills que el pipeline carga, pero no el pipeline.

---

## Skills

El agente las carga solo cuando aplican, según la `description` de cada una.

| Skill | Cubre |
|---|---|
| **`onion-screaming-architecture`** | `cmd/` + `internal/<context>/{domain,application,adapters}` + `kernel` + `platform`, matriz de imports, módulos externos por capa con depguard y forbidigo, archtest sobre `go list`, nombres de paquetes |
| **`domain-modeling`** | Entidades y value objects en Go puro: campos sin exportar, `New…` que valida, `Rehydrate…`, IDs y estados como tipos, dinero en unidad menor, reloj e IDs como puertos, sin tags |
| **`errors`** | `*errs.Error` con `Kind` y `Code`, centinelas, `errors.Is`/`As` y `%w`, traducción de errores del driver, mapeo a HTTP en un solo lugar, 404 entre tenants, sin `panic` |
| **`application-cqrs`** | Commands y queries como structs con `Handler`, puertos chicos, tenant explícito, `Update(fn)` que relee en cada reintento OCC, idempotencia por `client_event_id`, autorización fina |
| **`persistence-sqlc-dsql`** | sqlc + pgx v5, runner de migraciones compatible con DSQL, `db/schema.sql` para sqlc, restricciones de DSQL, `InTx` con reintento ante `40001`, token IAM, Postgres local que imita a DSQL |
| **`multi-tenancy-app-level`** | Tenant desde el JWT, explícito desde el adapter, filtro `coach_id` en cada query, tests por AST y de integración cross-tenant |
| **`http-lambda`** | chi + `httpadapter.NewV2`, router desde el contrato, orden de middlewares, JWT de Cognito con jwx, init liviano, build `bootstrap` arm64 |
| **`testing-conventions`** | Cuatro niveles, tablas con `t.Run`, testify `require`/`assert`, fakes a mano, `dbtest` con schema aislado, y los comandos reales de `<test>`, `<test:file>`, `<test:integration>`, `<lint>`, `<typecheck>` |
| **`security-baseline`** | Validación contra el contrato, límites de tamaño, secretos en SSM, IAM mínimo, link público con token aleatorio, headers, gosec y govulncheck |
| **`logging-slog`** | `slog` JSON con lista cerrada de claves, mensaje estático, `sloglint`, `requestId`, errores sin texto de terceros, nunca datos de menores |
| **`dependency-upgrade`** | `go get mod@vX.Y.Z`, madurez de 72 h por el campo `Time` del proxy, herramientas en `tools/go.mod`, `go mod tidy -diff`, govulncheck |
| **`api-contract-openapi`** | OpenAPI 3.0 cerrado como fuente de verdad, oapi-codegen (interfaz estricta), openapi-typescript, roles por `security`, CI que falla si lo generado no coincide |

---

## Plantillas

Todas están validadas: compilan, pasan `golangci-lint` con la configuración de abajo y sus tests corren en verde, incluidos los de integración contra el Postgres de `compose.yml`. Cada `.go` se copia a la ruta indicada y se reemplaza `github.com/OWNER/REPO` por la ruta de `go.mod`.

| Plantilla | Destino |
|---|---|
| `templates/ci.yml` | `.github/workflows/ci.yml` (checks, integración, contrato, audit, supply-chain, convenciones) |
| `templates/golangci.yml` | `.golangci.yml` (depguard por capa, forbidigo, sloglint, gosec) |
| `templates/settings.json` | `.claude/settings.json` (solo Claude Code; `includeCoAuthoredBy: false`) |
| `templates/compose.yml` | `compose.yml` (Postgres 17 en Repeatable Read, UTC, collation C) |
| `templates/archtest/` | `internal/archtest/` (matriz de imports y tenant por AST) |
| `templates/kernel/` | `internal/kernel/{errs,tenant}/` |
| `templates/httpx/`, `templates/auth/`, `templates/applog/`, `templates/db/`, `templates/migrate/` | `internal/platform/<nombre>/` |
| `templates/cmd/api/`, `templates/cmd/migrate/` | `cmd/api/` (router desde el contrato y humo del adaptador v2), `cmd/migrate/` |
| `templates/api/` | `api/openapi.yaml` de ejemplo, `api/oapi-codegen.yaml` e `internal/apigen/contract_test.go` |

Las herramientas (golangci-lint, sqlc, oapi-codegen, govulncheck) van en un `tools/go.mod` aparte, con la directiva `tool`, y se corren con `go tool -modfile=tools/go.mod <herramienta>` (skill `dependency-upgrade` §2).
