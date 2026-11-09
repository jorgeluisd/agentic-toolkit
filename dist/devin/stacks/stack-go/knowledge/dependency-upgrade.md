# dependency-upgrade

**Cuándo aplica (trigger de la entrada de Knowledge):** Dependencias en Go modules: versión explícita con go get mod@vX.Y.Z, madurez de 72 horas desde la publicación verificada en el proxy (campo Time), herramientas aisladas en tools/go.mod con la directiva tool, go mod tidy sin diff, govulncheck alcanzable, flujo por grupos con checks, ADR para majors del stack, y go.sum siempre commiteado. Usar cuando se agrega, sube, fija o quita un módulo o una herramienta.

---

# Dependencias: Go modules

En Go la versión ya queda exacta en `go.mod`, y MVS elige la mínima que satisface a todos. El riesgo no son los rangos, sino **adoptar una versión recién publicada**, subir de más por arrastre y mezclar las herramientas con la app.

## 1. Reglas duras

| Regla | Mecánica | Cómo se verifica |
|---|---|---|
| **Versión explícita.** Nunca `go get mod@latest`, `go get -u ./...` ni `-u=patch` en bloque | `go get <mod>@v<X.Y.Z>` con la versión elegida por §3 | El diff de `go.mod` en el PR muestra solo los módulos del grupo |
| **Madurez ≥ 72 h.** Solo se adopta una versión publicada hace al menos 72 horas, directa o transitiva | Consulta del campo `Time` al proxy (§3) | El PR lista módulo, versión y fecha de publicación en la verificación |
| **Herramientas aisladas.** golangci-lint, sqlc, oapi-codegen y govulncheck van en `tools/go.mod` con la directiva `tool`, nunca en el `go.mod` de la app | Se agregan y ordenan **dentro** de `tools/` (`cd tools && go get -tool <mod>/cmd/<x>@v<X.Y.Z> && go mod tidy`) y se corren desde la raíz con `go tool -modfile=tools/go.mod <x>`. `go mod tidy -modfile=…` desde la raíz no sirve: toma el árbol de la app como parte del módulo de herramientas | `grep -c '^tool' go.mod` = 0; `tools/go.mod` tiene una línea `tool` por herramienta |
| **`go mod tidy` sin diff** | `go mod tidy` después de cada cambio; en CI, `go mod tidy -diff` en la raíz y en `tools/` | Paso `Módulos ordenados` de `templates/ci.yml` |
| **`go.sum` commiteado** con `go.mod`, en el mismo commit | `GOFLAGS=-mod=readonly` en CI: si falta una entrada, falla | El build del CI no modifica `go.mod` ni `go.sum` |
| **Sin vulnerabilidades alcanzables** | `go tool -modfile=tools/go.mod govulncheck ./...` (`<audit>`) | Sale `No vulnerabilities found.`, o la excepción queda documentada con fecha de revisión |
| **Major del stack → ADR antes de tocar nada** (Go, pgx, chi, aws-lambda-go, aws-sdk-go-v2, jwx, sqlc, oapi-codegen, golangci-lint) | ADR con plan de migración y rollback; PR aparte. En Go, un major es otra ruta de import (`/v6`) | El PR del major referencia el ADR en `docs/sdd/` |
| **Toolchain fijada** | `go 1.N.0` y `toolchain go1.N.P` en `go.mod`; CI con `go-version-file: go.mod` | `go version` en el CI coincide con la línea `toolchain` |
| Sin `replace` hacia rutas locales ni forks sin ADR | `grep -n '^replace' go.mod` vacío, o cada `replace` con su comentario de issue y fecha de retiro | Revisión |
| Módulo retirado (`retract`) o deprecado no se adopta | `go list -m -json <mod>@<v>` sin `Retracted` ni `Deprecated` | Mismo comando |

## 2. Configuración del repo

```
go.mod            # module, go, toolchain, require de la app
go.sum
tools/go.mod      # module <ruta>/tools + una línea `tool` por herramienta
tools/go.sum
```

`tools/` no tiene código: es solo un módulo para fijar versiones de herramientas sin que su árbol de dependencias suba versiones de la app por MVS.

## 3. Comandos

```bash
# Línea base verde ANTES de tocar nada
go vet ./... && go tool -modfile=tools/go.mod golangci-lint run && go test -race -count=1 ./...

# Inventario: qué tiene versión nueva (no instala nada)
go list -m -u -json all | jq -r 'select(.Update and (.Indirect|not)) | "\(.Path) \(.Version) -> \(.Update.Version)"'

# Versiones publicadas de un módulo
go list -m -versions github.com/jackc/pgx/v5

# Fecha de publicación de una versión puntual (madurez ≥ 72 h)
go list -m -json github.com/jackc/pgx/v5@v5.9.2 | jq -r '.Time'

# Última versión con ≥ 72 h (macOS: date -v-72H; Linux: date -d '72 hours ago')
limit=$(date -u -d '72 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-72H +%Y-%m-%dT%H:%M:%SZ)
for v in $(go list -m -versions github.com/jackc/pgx/v5 | cut -d' ' -f2-); do
  t=$(go list -m -json "github.com/jackc/pgx/v5@$v" | jq -r .Time); [[ "$t" < "$limit" ]] && echo "$v $t"
done | tail -1

# Retractada o deprecada
go list -m -json github.com/jackc/pgx/v5@v5.9.2 | jq '{Retracted, Deprecated}'

# Subir con versión explícita
go get github.com/jackc/pgx/v5@v5.9.2 && go mod tidy

# Herramienta nueva o subida (dentro de tools/)
(cd tools && go get -tool github.com/sqlc-dev/sqlc/cmd/sqlc@v1.31.1 && go mod tidy)

# Cierre
go mod tidy -diff && (cd tools && go mod tidy -diff) && go tool -modfile=tools/go.mod govulncheck ./...
```

El campo `Time` lo devuelve el proxy (`GOPROXY`, por defecto `proxy.golang.org`). Con `GOPROXY=direct` no siempre viene: la verificación se hace contra el proxy.

## 4. Flujo por grupos

1. **Rama** `chore/deps-<alcance>` desde la base (skill `delivery-workflow`). Línea base verde (§3). Si la base está roja, se reporta y se frena: no se mezcla un bump con un fix.
2. **Inventario** con `go list -m -u -json all`. Además, `go list -m all` contra el campo `Time` del proxy: ninguna versión del árbol, directa o transitiva, con menos de 72 h. Clasificar en patch/minor (grupo normal) o major (ruta nueva: plan de migración, y ADR si es del stack).
3. **Elegir versión** por módulo: la última con ≥ 72 h, sin `Retracted` ni `Deprecated`. Si `govulncheck` exige una versión con menos de 72 h para cerrar una vulnerabilidad **alcanzable**, se adopta igual y se registra la excepción en `docs/sdd/<feature>/` con el ID `GO-AAAA-NNNN`.
4. **Instalar por grupos**, con `<typecheck>`, `<lint>` y `<test>` en verde entre grupo y grupo, más `<test:integration>` si el grupo toca pgx o el SDK de AWS:

   | Grupo | Contenido | Check adicional |
   |---|---|---|
   | Toolchain | `go` y `toolchain` de `go.mod` | `<build>` para arm64 |
   | Herramientas | `tools/go.mod` | Regenerar sqlc y oapi-codegen: el diff tiene que ser vacío o explicado |
   | Plataforma | pgx, aws-sdk-go-v2, aws-lambda-go, api-proxy, chi, jwx | `<test:integration>` y el humo del adaptador v2 |
   | Libs | uuid, testify y utilidades | — |

5. **Cierre**: `go mod tidy -diff` limpio en los dos módulos, `govulncheck` limpio, `go.sum` commiteado. PR `chore(deps)` con la plantilla de tres secciones; en Verificación, los comandos de §3 con su salida literal y la fecha de publicación de cada versión.

Un PR por grupo cuando el diff toca más de ~10 módulos directos o incluye un major. Nunca un PR "sube todo".

## 5. Prohibiciones

| Prohibido | En su lugar |
|---|---|
| `go get -u ./...`, `@latest`, `@master`, pseudo-versiones de una rama | Versión etiquetada elegida por §3 |
| Herramientas en el `go.mod` de la app, o instaladas con `go install …@latest` en el CI | `tools/go.mod` + `go tool -modfile=tools/go.mod` |
| `GOFLAGS=-mod=mod` en el CI | `-mod=readonly` (el default fuera de `go get`) |
| `GONOSUMDB`, `GOSUMDB=off` o `GOINSECURE` para saltear la verificación de `go.sum` | Arreglar el origen del módulo |
| Bump mezclado con cambios funcionales | PR `chore(deps)` aislado |

## 6. Checklist

- [ ] ¿Línea base verde guardada antes de tocar nada?
- [ ] ¿Cada versión nueva con ≥ 72 h (`go list -m -json …@v | jq .Time`), sin `Retracted` ni `Deprecated`?
- [ ] ¿Herramientas solo en `tools/go.mod` y corridas con `go tool -modfile=tools/go.mod`?
- [ ] ¿Instalación por grupos con checks verdes entre grupo y grupo?
- [ ] ¿`go mod tidy -diff` limpio en los dos módulos y `govulncheck` limpio?
- [ ] ¿Major del stack con ADR previo y PR aparte?
