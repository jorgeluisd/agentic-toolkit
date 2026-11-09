---
name: testing-conventions
description: "Tests en Go: cuatro niveles (dominio, handler con fakes, integración con Postgres en Docker bajo el tag integration, HTTP con httptest), tablas de casos con t.Run, testify solo require/assert, fakes escritos a mano en <ctx>test, dbtest con schema aislado, cobertura por capa, y los comandos reales de <test>, <test:file>, <test:integration>, <lint>, <typecheck>, <build> y <audit>. Usar cuando se escribe, ubica o revisa un test, se corre un comando del stack o se configura el CI."
---

# Convenciones de testing en Go

Un test es rápido, determinista y del nivel que le corresponde a su capa. El ciclo RED → GREEN → TRIANGULATE → REFACTOR y la evidencia viven en `strict-tdd`; esta skill fija niveles, dobles, comandos y cobertura.

## 1. Los cuatro niveles

| # | Nivel | Qué prueba | Dónde | Dobles | Comando |
|---|---|---|---|---|---|
| 1 | Dominio | Constructores, invariantes, transiciones, `PullEvents()` | `*_test.go` junto al archivo en `domain/` | Ninguno: el instante y los IDs entran por parámetro | `<test>` |
| 2 | Handler | Secuencia del caso de uso, errores, replay, autorización fina | `*_test.go` junto al handler en `application/` | Fakes de `<ctx>test`; reloj fijo con `clock.Func` | `<test>` |
| 3 | Integración | SQL real, traducción de errores, `InTx` con conflicto, cross-tenant, idempotencia | `*_integration_test.go` en `adapters/postgres/`, con `//go:build integration` | Ninguno sobre la DB: Postgres de `compose.yml` vía `dbtest` | `<test:integration>` |
| 4 | HTTP | Router, middlewares, decodificación, mapeo de errores, roles por ruta | `*_test.go` en `adapters/http/` y `internal/platform/httpx` | `httptest` y fakes de application; sin Lambda | `<test>` |

Además, el archtest (`internal/archtest`) corre en `<test>`, y hay un único humo del adaptador de Lambda en `cmd/api/main_test.go` (plantilla `templates/cmd/api/main_test.go`). No hay e2e contra AWS en el CI. La verificación en staging es manual o un smoke post-deploy.

## 2. Comandos simbólicos del stack (los usan `strict-tdd`, `delivery-workflow`, el `verifier` y `/check-arch`)

| Símbolo | Comando en este stack |
|---|---|
| `<install>` | `go mod download` |
| `<lint>` | `go tool -modfile=tools/go.mod golangci-lint run` (incluye depguard y forbidigo; tiene que terminar en `0 issues.`) |
| `<typecheck>` | `go vet ./...` (compila todos los paquetes, también los `_test.go`) |
| `<test>` | `go test -race -count=1 ./...` (niveles 1, 2 y 4, más el archtest; sin Docker) |
| `<test:file>` | `go test -race -count=1 -v -run '^TestX$' ./internal/<ctx>/<capa>/` |
| `<test:integration>` | `docker compose up -d --wait && go test -race -count=1 -tags integration ./...`, con `DATABASE_URL=postgres://postgres@127.0.0.1:5432/postgres?sslmode=disable` en el entorno (Postgres local sin contraseña, solo en 127.0.0.1) |
| `<build>` | `CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -tags lambda.norpc -trimpath -ldflags='-s -w' -o build/bootstrap ./cmd/api` |
| `<audit>` | `go tool -modfile=tools/go.mod govulncheck ./...` |
| dev / db local | `docker compose up -d --wait`, `go run ./cmd/migrate -local`, `go run ./cmd/api` |

- Cada proyecto los copia en su `AGENTS.md` §6; si difieren, gana el `AGENTS.md`. Un símbolo que el proyecto no tiene se declara `no aplica — <porqué>`.
- **Se invocan literales, no por `make`.** Los hooks de evidencia del core reconocen `go test` en el comando, pero no `make test`. Un Makefile puede existir para humanos; el agente corre el comando de la tabla.
- **Sin pipes sobre la salida de los tests** (`| tail`, `| grep`): el hook necesita el resumen completo del runner. Para acotar están `-run` y la ruta del paquete.
- **Go corre por paquete, no por archivo.** `<test:file>` es "el paquete del archivo más `-run` con el nombre del test". Va con `-v`, para que la salida muestre `=== RUN` y `--- FAIL`/`--- PASS` del caso.
- **`ok ... [no tests to run]` no es GREEN ni RED.** Significa que `-run` no matcheó nada. El hook lo cuenta como corrida, así que la evidencia válida de RED exige ver `--- FAIL: TestX` en la salida (o `FAIL ... [build failed]` en el RED de tipos).

## 3. Forma de un test

```go
func TestNewMinute(t *testing.T) {
	cases := []struct {
		name string
		in   int
		want error
	}{
		{"cero es válido", 0, nil},
		{"tope es válido", 130, nil},
		{"negativo", -1, domain.ErrMinuteInvalid},
		{"más allá del tope", 131, domain.ErrMinuteInvalid},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := domain.NewMinute(tc.in)
			if tc.want == nil {
				require.NoError(t, err)
				return
			}
			require.ErrorIs(t, err, tc.want)
		})
	}
}
```

| Regla | Cómo se verifica |
|---|---|
| Nombre `Test<Tipo o Función>_<Comportamiento>`; casos de tabla con nombre legible en español | Revisión |
| testify: `require` para todo lo que, si falla, invalida el resto; `assert` solo para comparaciones independientes en un mismo test. Sin `testify/mock` ni `testify/suite` | `<lint>`: depguard prohíbe `testify/mock` |
| Se asserta el **error exacto** con `require.ErrorIs`/`ErrorAs`, nunca solo `require.Error` | Revisión: `require.Error(` sin otra aserción sobre el error es un hallazgo |
| Paquete externo (`package domain_test`) para probar la API pública; interno solo para helpers no exportados | Revisión |
| `t.Context()` para el contexto; `t.Cleanup` para liberar; `t.Parallel()` en unit y handler | `<lint>` (`contextcheck`) |
| Sin `time.Sleep` para esperar: canales, `sync.WaitGroup` o barreras explícitas | `grep -rn 'time.Sleep' --include=*_test.go internal` vacío |

## 4. Fakes, no mocks

Cada puerto de application tiene su fake en `internal/<ctx>/<ctx>test/`, escrito a mano, con estado en memoria y la aserción de interfaz:

```go
var _ application.Matches = (*Matches)(nil)

type Matches struct {
	mu     sync.Mutex
	byID   map[string]domain.MatchSnapshot
	events map[string]bool
	Fail   error
}
```

- El fake respeta la semántica del puerto: filtra por tenant, devuelve `ErrMatchNotFound` y aplica el replay por `client_event_id`. Un fake más permisivo que el adapter real esconde bugs.
- `Fail` inyecta un error para probar los caminos de falla.
- Solo los `_test.go` importan `<ctx>test`. `TestBinary_DoesNotLinkFakes` lo verifica.

## 5. Integración

- `//go:build integration` en la primera línea; el archivo termina en `_integration_test.go`.
- `dbtest.Pool(t)` o `dbtest.Conn(t)` (plantilla `templates/db/dbtest/`): un schema propio por test, borrado al final, y el test **se niega a correr** si `DATABASE_URL` no apunta a un host local.
- Las migraciones se aplican al schema del test con `migrate.Run(ctx, conn, migrate.Postgres, ms)`, o sea las mismas que van a DSQL.
- Obligatorios por repositorio: lectura y escritura cross-tenant con 404 (skill `multi-tenancy-app-level` §4), replay del mismo `client_event_id`, traducción de `ErrNoRows` y de `23505`.
- Una vez por módulo: `TestInTx_RetriesConcurrentConflicts` (plantilla), que fuerza un `40001` real.

## 6. Cobertura

| Capa | Mínimo | Cómo se mide |
|---|---|---|
| `domain`, `kernel` | 90 % | `go test -coverprofile=cover.out ./internal/<ctx>/domain/... && go tool cover -func=cover.out` |
| `application` | 85 % | Ídem sobre `application/...` |
| `adapters/postgres` | La da la integración; sin número fijo, pero cada método tiene al menos un test | `-tags integration -coverprofile` |
| `adapters/http`, `platform` | 80 % | `<test>` con `-coverprofile` |

La cobertura es un piso, no un objetivo: un test sin aserción sobre el resultado no cuenta, aunque sume líneas.

## 7. Checklist

- [ ] ¿El test está en el nivel de su capa y en la ubicación de §1?
- [ ] ¿Tabla de casos con `t.Run`, `require.ErrorIs` contra el error exacto?
- [ ] ¿Fakes de `<ctx>test` con la misma semántica que el adapter, sin `testify/mock`?
- [ ] ¿Integración con `//go:build integration` y `dbtest`, nunca contra una base que no sea local?
- [ ] ¿Comandos literales de §2, sin `make` ni pipes, y con `--- FAIL` visible en el RED?
