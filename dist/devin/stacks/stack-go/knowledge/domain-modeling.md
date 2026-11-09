# domain-modeling

**Cuándo aplica (trigger de la entrada de Knowledge):** Entidades, value objects y eventos en Go puro: campos sin exportar, constructor New que valida y devuelve (T, error), Rehydrate para persistencia, IDs y estados como tipos, dinero en unidad menor, reloj e IDs como puertos del kernel, sin tags de JSON ni de DB. Usar cuando se escribe o revisa código bajo internal/<context>/domain o internal/kernel.

---

# Modelado de dominio en Go

El dominio es Go puro: stdlib, el `kernel` y nada más. No sabe de HTTP, de SQL, de JSON ni de Lambda. Un valor de dominio inválido **no se puede construir**: si existe, cumple sus invariantes.

## 1. Reglas duras

| Regla | Mecánica | Cómo se verifica |
|---|---|---|
| Sin tags de JSON ni de DB | Los structs de `domain/` no llevan `json:`, `db:`, `validate:`. El DTO vive en `adapters/http`; la fila, en `adapters/postgres/gen` | `grep -rn -e 'json:"' -e 'db:"' -e 'validate:"' internal/*/domain internal/kernel` vacío; depguard prohíbe `encoding/json` en esas capas |
| Campos sin exportar | `type Match struct { id MatchID; status Status }` + métodos de lectura. Nadie fuera del paquete asigna un campo | Revisión: ningún campo exportado en entidades con invariantes; los value objects simples pueden ser tipos con nombre (`type Minute int`) |
| Constructor que valida | `NewX(...) (X, error)` o `(*X, error)`; devuelve un `*errs.Error` del dominio (skill `errors`) | Test de tabla por cada invariante: entrada inválida → `errors.Is(err, ErrX)` |
| `Rehydrate` para persistencia | `RehydrateX(snapshot)` reconstruye desde la DB sin volver a emitir eventos ni aplicar reglas de creación | El adapter postgres usa `Rehydrate`, nunca `New`, al leer |
| Sin reloj ni azar | El instante entra como parámetro (`at time.Time`) o por `clock.Clock`; los IDs por `ids.Generator`. Nunca `time.Now()`, `rand`, `uuid.New()` | `<lint>`: forbidigo (`time.Now`) y depguard (`math/rand`, `crypto/rand`, módulos de terceros) |
| Tipos para conceptos | IDs, estados, minutos y montos son tipos con nombre, no `string`/`int` sueltos | Una firma `func(string, string, int)` en domain es un hallazgo de revisión |
| Dinero en unidad menor | `type Money struct { amount int64; currency Currency }`; nunca `float64` | `grep -rn 'float' internal/*/domain` sin montos |
| Sin `panic` | Un error esperable se devuelve; un `panic` en el dominio tira la Lambda entera | `<lint>`: forbidigo `^panic$` |

## 2. Value objects

```go
package domain

import (
	"regexp"

	"github.com/OWNER/REPO/internal/kernel/errs"
)

var (
	ErrMatchIDInvalid = errs.New(errs.KindInvalid, "MATCH_ID_INVALID", "el id de partido no es un UUID")
	ErrMinuteInvalid  = errs.New(errs.KindInvalid, "MINUTE_INVALID", "minuto fuera de 0..130")
)

var uuidPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// MatchID no tiene valor cero válido: MatchID{} es un bug que el adapter detecta.
type MatchID struct{ value string }

func ParseMatchID(s string) (MatchID, error) {
	if !uuidPattern.MatchString(s) {
		return MatchID{}, ErrMatchIDInvalid
	}
	return MatchID{value: s}, nil
}

func (id MatchID) String() string { return id.value }

type Minute int

func NewMinute(m int) (Minute, error) {
	if m < 0 || m > 130 {
		return 0, ErrMinuteInvalid
	}
	return Minute(m), nil
}
```

- Un VO es inmutable: métodos con receptor por valor que devuelven un VO nuevo.
- Comparación con `==` cuando todos los campos son comparables; si no, un método `Equal`.
- Los estados son `type Status string` con constantes; el `switch` sobre ellos es exhaustivo (`<lint>`: `exhaustive`). En la DB, `text` con `CHECK` (DSQL no tiene enums).

## 3. Entidades y aggregates

```go
type Status string

const (
	StatusScheduled Status = "scheduled"
	StatusLive      Status = "live"
	StatusFinished  Status = "finished"
)

var ErrMatchNotLive = errs.New(errs.KindConflict, "MATCH_NOT_LIVE", "el partido no está en juego")

type Match struct {
	id     MatchID
	tenant tenant.ID
	status Status
	goals  []Goal
	events []Event
}

func NewMatch(id MatchID, t tenant.ID) (*Match, error) {
	if t.IsZero() {
		return nil, tenant.ErrInvalid
	}
	return &Match{id: id, tenant: t, status: StatusScheduled}, nil
}

type MatchSnapshot struct {
	ID     MatchID
	Tenant tenant.ID
	Status Status
	Goals  []Goal
}

func RehydrateMatch(s MatchSnapshot) *Match {
	return &Match{id: s.ID, tenant: s.Tenant, status: s.Status, goals: slices.Clone(s.Goals)}
}

func (m *Match) RecordGoal(g Goal, at time.Time) error {
	if m.status != StatusLive {
		return ErrMatchNotLive
	}
	m.goals = append(m.goals, g)
	m.events = append(m.events, GoalRecorded{Match: m.id, Player: g.Player(), Minute: g.Minute(), At: at})
	return nil
}

func (m *Match) Snapshot() MatchSnapshot {
	return MatchSnapshot{ID: m.id, Tenant: m.tenant, Status: m.status, Goals: slices.Clone(m.goals)}
}

func (m *Match) PullEvents() []Event {
	ev := m.events
	m.events = nil
	return ev
}
```

- El aggregate guarda su `tenant.ID`. El repositorio lo exige igual en la firma (skill `multi-tenancy-app-level`): son dos defensas, no una.
- Un aggregate referencia a otro **solo por ID**. Nada de `*Player` dentro de `Match`.
- `Snapshot()` es la única salida hacia el adapter; los getters sueltos son para lectura en application. Los slices se clonan al entrar y al salir.
- Las transiciones de estado son métodos con nombre de negocio (`Start`, `RecordGoal`, `Finish`), nunca `SetStatus`.

## 4. Eventos de dominio

`type Event interface{ EventName() string }` en `domain/`, y un struct por evento en pasado (`GoalRecorded`). Llevan IDs y valores, nunca datos personales (nombre del alumno, teléfono). El handler de application los saca con `PullEvents()` **después** del commit y los publica por un puerto (AppSync Events, por ejemplo). Si la publicación falla, el estado ya está guardado: el canal en vivo es *best effort* y el cliente reconcilia leyendo. **Cómo se verifica:** test del aggregate que asserta `PullEvents()` tras cada transición, y que una transición rechazada no emite nada.

## 5. Kernel: puertos de reloj e IDs

```go
package clock // internal/kernel/clock

type Clock interface{ Now() time.Time }

type Func func() time.Time

func (f Func) Now() time.Time { return f() }
```

```go
package ids // internal/kernel/ids

type Generator interface{ NewID() string }
```

La implementación real vive fuera del kernel: `clock.Func(time.Now)` y un generador UUIDv7 (`uuid.NewV7`) se arman en `cmd/api`. En tests, `clock.Func(func() time.Time { return fixed })` y un generador secuencial. **Cómo se verifica:** forbidigo marca `time.Now` en `kernel`, `domain` y `application`; depguard rechaza `github.com/google/uuid` en `kernel`/`domain`.

## 6. Tests del dominio

Unit puros, sin fakes: todo entra por parámetro. Tabla de casos por invariante con `t.Run`, `require.ErrorIs(t, err, domain.ErrX)` contra el error exacto (no solo "hubo error") y un caso feliz por constructor. Ver skill `testing-conventions` §1.

## 7. Checklist

- [ ] ¿Ningún tag `json:`/`db:` en `domain/` ni en `kernel/`?
- [ ] ¿Toda entidad con invariantes tiene campos sin exportar, `New...` que valida y `Rehydrate...`?
- [ ] ¿IDs, estados, minutos y montos son tipos, y el dinero es `int64` en unidad menor?
- [ ] ¿El instante entra por parámetro o por `clock.Clock`, y los IDs por `ids.Generator`?
- [ ] ¿Los eventos están en pasado, sin datos personales, y se sacan con `PullEvents()` después del commit?
- [ ] ¿Cada invariante tiene un caso en la tabla del test con `require.ErrorIs`?
