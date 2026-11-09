---
name: onion-screaming-architecture
description: "Capas Onion en Go: cmd/ + internal/<context>/{domain,application,adapters} + internal/kernel + internal/platform, matriz de imports, nombres de paquetes, y enforcement mecánico con depguard + forbidigo en golangci-lint y un archtest sobre go list. Usar cuando se crea o mueve un paquete, se decide capa o contexto, se crea un bounded context o el lint o el archtest marcan un import."
---

# Onion + Screaming Architecture en Go

Dependencias siempre hacia adentro. `internal/` grita el negocio (`matches/`, `billing/`), no la tecnología (`handlers/`, `services/`, `utils/`). El enforcement es mecánico y está en dos piezas que corren en cada PR: **depguard + forbidigo** (`<lint>`) para módulos externos por capa, y **archtest** (`<test>`) para imports entre paquetes del propio módulo. Nunca por confianza.

## 1. Layout canónico

```
cmd/
  api/main.go                 # composition root de la Lambda: config, clientes, wiring, lambda.Start
  migrate/main.go             # aplica db/migrations (CI o deploy; nunca en el init de la Lambda)
internal/
  kernel/                     # shared kernel puro: errs, tenant, clock, ids. Solo stdlib
  <context>/                  # un bounded context por carpeta; el nombre grita el negocio
    domain/                   # entidades, value objects, errores, eventos. Go puro
    application/              # commands, queries, handlers, puertos (interface)
    adapters/
      http/                   # handlers chi, DTOs, mapeo DTO ↔ command
      postgres/               # repos sobre sqlc; queries/*.sql y gen/ (salida de sqlc)
      appsync/ ses/ s3/ ...   # un paquete por sistema externo
    <context>test/            # fakes de los puertos; solo los importan _test.go
  platform/                   # transversal, sin negocio: config, auth, db, httpx, log, migrate
  apigen/                     # código generado del OpenAPI (oapi-codegen); no se edita
  archtest/                   # el test de la matriz (§5)
api/openapi.yaml              # contrato (skill api-contract-openapi)
db/migrations/                # NNNN_slug.sql, una sentencia por archivo (skill persistence-sqlc-dsql)
```

Prohibido: `pkg/`, `utils/`, `common/`, `helpers/`, `models/` en cualquier nivel; un `internal/shared/` de dominio (si es puro va a `kernel`; si no, los contextos están mal cortados); carpetas por capa en la raíz (`internal/domain/`, `internal/handlers/`). **Cómo se verifica:** `TestClassify_FlagsUnknownPackages` y `TestModule_RespectsImportMatrix` del archtest reportan todo paquete fuera de la taxonomía.

## 2. Matriz de imports (fila importa columna; solo paquetes del módulo)

| desde \ hacia | kernel | domain | application | adapters | platform | apigen | `<ctx>test` | cmd |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| kernel | sí | no | no | no | no | no | no | no |
| domain | sí | mismo ctx | no | no | no | no | no | no |
| application | sí | mismo ctx | mismo ctx | no | no | no | no | no |
| adapters | sí | mismo ctx | **cualquier ctx** | mismo ctx | sí | sí | no | no |
| platform | sí | no | no | no | sí | no | no | no |
| apigen | no | no | no | no | no | sí | no | no |
| `<ctx>test` | sí | mismo ctx | mismo ctx | no | no | no | mismo ctx | no |
| cmd | sí | sí | sí | sí | sí | sí | no | no |

- Un `_test.go` puede importar fakes y adapters a propósito: `go list` no cuenta sus imports en `Imports`.
- `application` no importa `platform`: el logger, el reloj y la transacción entran como puertos o parámetros.
- Un adapter puede llamar a la `application` de otro contexto (§4), nunca a su `domain`.

## 3. Módulos externos por capa (depguard)

| Capa | Permitido | Prohibido (ejemplos) |
|---|---|---|
| `kernel`, `domain` | Solo stdlib (`list-mode: strict`) | `net/http`, `database/sql`, `encoding/json`, `os`, `log`, `log/slog`, `math/rand`, `crypto/rand`, cualquier módulo de terceros |
| `application` | stdlib, `log/slog`, el propio módulo | `net/http`, `database/sql`, `os`, `pgx`, `chi`, `aws-sdk-go-v2`, `jwx` |
| `adapters/http` | chi, `apigen`, stdlib | `pgx`, `database/sql` |
| `adapters/*`, `platform` | lo que el adapter necesita | `aws-lambda-go`, `aws-lambda-go-api-proxy` (solo `cmd/`) |
| todo el módulo | — | `github.com/pkg/errors`, `testify/mock`, `logrus`, `zap` |

forbidigo agrega lo que no es un import: `time.Now` fuera de `platform`/`adapters`/`cmd` (en `kernel`, `domain` y `application` el reloj es un puerto), `panic` fuera de tests, y `fmt.Print*`/`print`/`println` fuera de `cmd/`. **Cómo se verifica:** plantilla `templates/golangci.yml` de este plugin, copiada a `.golangci.yml` con la ruta del módulo; `<lint>` termina en `0 issues.`

## 4. Regla inter-contexto

Nada de `domain` a `domain` entre contextos. Un contexto que necesita algo de otro (a) guarda solo su ID como value object propio, (b) declara un puerto en su `application` (`type RosterReader interface { PlayersOf(ctx, tenant.ID, CategoryID) ([]PlayerRef, error) }`) y (c) lo implementa un adapter `adapters/rosterclient/` que llama a un handler de `roster/application`. Así el acoplamiento queda en un archivo que se ve en el diff. Para efectos asíncronos (recalcular la tabla tras un gol) se usa un evento de dominio despachado después del commit. **Cómo se verifica:** `TestAllowed_EachRuleBites` incluye `rosterclient → roster/application` (permitido) y `rosterclient → roster/domain` (prohibido).

## 5. Enforcement: archtest

Plantilla `templates/archtest/arch_test.go` de este plugin → `internal/archtest/arch_test.go`. Usa `go list -f '{{.ImportPath}} {{.Imports}}' <módulo>/...`, que respeta build tags y excluye los imports de los tests. Tiene cuatro tests:

| Test | Qué garantiza |
|---|---|
| `TestModule_RespectsImportMatrix` | Ningún paquete real rompe §2; falla si `go list` encontró menos de 2 paquetes (un test que pasa vacío no prueba nada) |
| `TestBinary_DoesNotLinkFakes` | `go list -deps -tags lambda.norpc ./cmd/...` no contiene ningún `<ctx>test` |
| `TestAllowed_EachRuleBites` | Tabla de casos permitidos y prohibidos: si alguien afloja `allowed()`, este test cae aunque el módulo esté limpio |
| `TestClassify_FlagsUnknownPackages` | `utils`, `services`, `pkg/...` y `adapters` sin subpaquete son "fuera de taxonomía" |

**Prueba que muerde** (obligatoria al adoptar la plantilla): agregar un import temporal `domain → platform/db` y correr `<test>`. Tiene que fallar `TestModule_RespectsImportMatrix` con `internal/<ctx>/domain → internal/platform/db`. Agregar `encoding/json` y `time.Now()` en el dominio y correr `<lint>`: tienen que salir `depguard` y `forbidigo`. Si no muerden, el patrón de `files` o la ruta del módulo están mal.

## 6. Nombres

| Pieza | Regla | Ejemplo |
|---|---|---|
| Paquete | Una palabra, minúscula, sin `_`; el nombre de la carpeta | `domain`, `postgres`, `matchestest` |
| Archivo | `snake_case.go`, uno por concepto; test al lado | `match.go`, `match_test.go`, `record_goal.go` |
| Tipo exportado | Sin tartamudeo: el paquete ya califica | `domain.Match`, no `domain.MatchEntity` |
| Interfaz | Por lo que hace, del lado de quien la usa; sin `I` ni `Interface` | `Matches`, `Clock`, `Publisher` |
| Command / query | `<Verbo><Sustantivo>` + `Handler` | `RecordGoal`, `RecordGoalHandler` |
| Fake | Mismo nombre que el puerto en `<ctx>test` | `matchestest.Matches` |
| Build tags | `integration` para tests con DB; `lambda.norpc` para el binario | `//go:build integration` |

Identificadores en inglés; comentarios y mensajes internos en español neutro.

## 7. Contexto nuevo: decisión y scaffold

Test de decisión, un punto por cada afirmación cierta: lenguaje propio · ciclo de vida propio · dueño distinto · consistencia transaccional independiente · cambia por razones distintas · podría ser un servicio aparte. **4+** → contexto nuevo. **2–3** → subpaquete o entidad dentro de uno existente. **0–1** → no lo crees.

```bash
ctx=internal/matches
mkdir -p $ctx/domain $ctx/application $ctx/adapters/http $ctx/adapters/postgres/queries $ctx/matchestest
```

Mínimo antes de mergear: una entidad con constructor que valida (skill `domain-modeling`), un puerto de repositorio en `application`, su adapter `postgres` con test de integración y su fake en `<ctx>test`, un handler con test, y la migración si hay tabla. El wiring va en `cmd/api` (o en un `wire.go` del mismo paquete `main` si crece).

## 8. Errores comunes → arreglo

| Síntoma | Arreglo |
|---|---|
| `domain` importa `encoding/json` para tags | DTO en `adapters/http` y mapeo explícito; el dominio no tiene tags |
| `application` recibe `*pgxpool.Pool` o `pgx.Tx` | Puerto `UnitOfWork`/repositorio en `application`; la transacción la abre el adapter |
| Handler HTTP arma SQL o llama a sqlc | Llama a un handler de `application`; el SQL vive en `adapters/postgres` |
| Paquete `internal/matches/services/` | Es `application` (orquesta) o `domain` (regla pura): elegir y mover |
| Un fake vive en `adapters/` y lo enlaza el binario | Moverlo a `<ctx>test`; `TestBinary_DoesNotLinkFakes` lo confirma |
| Ciclo de imports entre dos contextos | Uno de los dos declara un puerto y el otro lo implementa con un adapter (§4) |

## 9. Checklist

- [ ] ¿Paquete en su capa según §1 y contexto decidido con §7?
- [ ] ¿Ningún import rompe la matriz de §2? (`<test>` corre el archtest)
- [ ] ¿`domain` y `kernel` sin módulos de terceros, sin JSON, sin reloj ni azar? (`<lint>`: depguard + forbidigo)
- [ ] ¿Nombres de paquete, archivo y tipo según §6?
- [ ] ¿La prueba que muerde de §5 se corrió al adoptar o tocar la plantilla?
