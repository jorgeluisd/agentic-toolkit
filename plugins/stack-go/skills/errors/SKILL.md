---
name: errors
description: "Errores en Go: *errs.Error del kernel con Kind y Code estable, centinelas por contexto, errors.Is/As y %w, traducción de errores del driver en el adapter, mapeo Kind → status HTTP en un solo lugar (problem+json), 404 entre tenants, sin panic en el flujo normal y sin loguear y devolver. Usar cuando se crea un error, se elige un status HTTP, se envuelve o compara un error, o se traduce un error de pgx o del SDK de AWS."
---

# Errores

En Go el error de negocio ya es un valor de retorno; la disciplina está en **tiparlo una vez** (dominio o adapter), **envolverlo con contexto** al subir, y **traducirlo a HTTP en un solo lugar**. Plantillas: `templates/kernel/errs/errs.go` (tipo) y `templates/httpx/httpx.go` (`WriteError`).

## 1. El tipo

```go
type Kind uint8 // KindInvalid, KindMalformed, KindNotFound, KindConflict, KindForbidden, KindUnauthenticated, KindUnavailable

type Error struct {
	Kind Kind   // qué tipo de falla es; el borde lo traduce a status
	Code string // SCREAMING_SNAKE, estable, uno por error: contrato con el front
	Msg  string // interno, para el log; nunca datos personales
}

func (e *Error) Is(target error) bool { t, ok := target.(*Error); return ok && t.Code == e.Code }
```

| Campo | Regla | Cómo se verifica |
|---|---|---|
| `Code` | Único por error en todo el módulo. Va en `Problem.code` y en el OpenAPI como enum documentado | Paso `Error codes únicos` de `templates/ci.yml` (comando abajo) |
| `Kind` | Lo elige quien crea el error, según la naturaleza de la falla; nunca se deduce del mensaje | Revisión: ningún `strings.Contains(err.Error(), ...)` |
| `Msg` | Interno. Puede llevar IDs; nunca nombres, teléfonos, emails ni datos de menores | Skill `logging-slog` §5: test anti-fuga |

Códigos repetidos (tiene que salir vacío):

```bash
grep -rhoE --include='*.go' --exclude='*_test.go' 'errs\.New\(errs\.Kind[A-Za-z]+, "[A-Z_]+"' internal | grep -oE '"[A-Z_]+"' | sort | uniq -d
```

## 2. Dónde nace cada error

| Capa | Qué hace | Ejemplo |
|---|---|---|
| `domain` | Centinelas `var ErrX = errs.New(...)` por invariante; los devuelve tal cual | `ErrMatchNotLive` (`KindConflict`) |
| `application` | Centinelas de orquestación: no encontrado, rol de recurso, conflicto de idempotencia | `ErrMatchNotFound` (`KindNotFound`), `ErrNotDelegateOfCategory` (`KindForbidden`) |
| `adapters/postgres` | **Traduce** el error del driver a uno de application; el resto lo envuelve con `%w` y sube como 500 | `pgx.ErrNoRows` → `application.ErrMatchNotFound`; SQLSTATE `23505` → el conflicto del caso de uso |
| `adapters/http` | Errores de forma del request: body ilegible, campo desconocido, tipo inválido | `ErrBodyInvalid` (`KindMalformed`) |
| `platform/auth` | Token ausente o inválido, rol insuficiente | `ErrUnauthenticated`, `ErrRoleRequired` |

Nada fuera de `adapters/postgres` conoce `pgx`, `pgconn` ni un SQLSTATE: depguard lo impide en `application` y en `adapters/http`.

## 3. Envolver y comparar

- Al subir, `fmt.Errorf("record goal match %s: %w", id, err)`: contexto con IDs, nunca datos personales, y siempre `%w` (nunca `%v` sobre un error, que corta la cadena).
- Identidad con `errors.Is(err, domain.ErrMatchNotLive)`. Datos del error con `errors.As(err, &target)`. **Nunca** `err == ErrX` ni `err.Error() == "..."`.
- `errors.Join` para validar varios campos y devolverlos juntos.
- Un error se **loguea una sola vez**, en el borde (`WriteError` o el log de acceso). Quien lo devuelve no lo loguea.

**Cómo se verifica:** `<lint>` con `errorlint` (comparaciones y `%w`), `nilerr` (devolver `nil` con un `err` en mano) y el `errcheck` del preset estándar.

## 4. Mapeo a HTTP: un solo lugar

`httpx.WriteError` es el **único** lugar donde un error se vuelve status:

| Kind | Status |
|---|---|
| `KindInvalid` | 422: el request se entendió pero rompe una regla |
| `KindMalformed` | 400: el request no se pudo leer (JSON roto, campo desconocido, tipo equivocado) |
| `KindNotFound` | 404 |
| `KindConflict` | 409 |
| `KindForbidden` | 403 |
| `KindUnauthenticated` | 401 |
| `KindUnavailable` | 503 |
| cualquier otro error (no es `*errs.Error`) | 500 `INTERNAL`, y al log solo el tipo (`%T`), nunca el mensaje |

El body es `application/problem+json` con `type`, `title`, `status`, `code` y `requestId`; nunca `err.Error()`. **Cómo se verifica:** `TestWriteError_MapsEachKindInOnePlace` de la plantilla (un caso por `Kind`, un error del driver que devuelve 500 sin filtrar su texto). `grep -rn 'WriteHeader(http.Status' internal/*/adapters/http` solo encuentra respuestas exitosas.

## 5. Casos que se equivocan siempre

| Caso | Regla |
|---|---|
| Recurso de otro tenant | **404**, igual que si no existiera; nunca 403 (confirmaría que existe). El repo ya filtra por tenant, así que "no está" y "no es tuyo" son el mismo `ErrNotFound` |
| Rol suficiente pero no sobre este recurso (delegado de otra categoría) | 403 con `Code` propio, solo si el recurso es del mismo tenant |
| Conflicto OCC de DSQL tras agotar reintentos | El adapter devuelve `KindUnavailable` con `Code` `BUSY` → 503; el front reintenta con el mismo `client_event_id` |
| Evento offline repetido (mismo `client_event_id`) | **No es un error**: 200 con el resultado original (skill `persistence-sqlc-dsql` §5) |
| Body más grande que el límite | `*http.MaxBytesError` → el adapter devuelve `ErrBodyTooLarge` (`KindMalformed`, `Code` `BODY_TOO_LARGE`) → 400 |
| Cancelación del cliente (`context.Canceled`) | No es un error del servidor: el handler retorna sin loguearlo como error; el cliente ya no escucha la respuesta |

## 6. Panic

- En el flujo normal no hay `panic`: forbidigo lo prohíbe fuera de tests.
- `regexp.MustCompile` y similares solo en variables de paquete con literales (fallan al arrancar, nunca en una request).
- En `cmd/`, un error del init es `log.Fatalf("api: <qué>: %v", err)`; la Lambda no arranca y el error queda en CloudWatch.
- `httpx.Recover` convierte un panic inesperado en 500 sin loguear el valor (puede traer datos) y re-lanza `http.ErrAbortHandler`.

## 7. Checklist

- [ ] ¿El error nuevo es un `*errs.Error` con `Kind` correcto y un `Code` único?
- [ ] ¿El adapter traduce los errores del driver a errores de application, y nada más conoce `pgx`?
- [ ] ¿Se envuelve con `%w` y se compara con `errors.Is`/`errors.As`?
- [ ] ¿Ningún handler escribe un status de error a mano: todo pasa por `httpx.WriteError`?
- [ ] ¿Recurso de otro tenant → 404? ¿El evento repetido devuelve el resultado original?
- [ ] ¿Se loguea una sola vez y sin `err.Error()` de terceros?
