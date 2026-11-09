# application-cqrs

**Cuándo aplica (trigger de la entrada de Knowledge):** Capa application en Go: commands y queries como structs, un Handler por caso de uso con Handle(ctx, cmd), puertos como interface chicas en application, tenant y actor dentro del command puestos solo por el adapter, escritura con Update(fn) que relee en cada reintento OCC, idempotencia por client_event_id, autorización fina con datos, eventos después del commit y tests con fakes. Usar cuando se escribe un command, query, handler, puerto o el wiring de un caso de uso.

---

# Application: commands, queries y puertos

`application` orquesta: recibe un command o una query, consulta y muta el dominio a través de **puertos**, y devuelve un resultado. No sabe de HTTP, de SQL ni de Lambda (depguard lo impide). No hay bus ni reflexión: cada caso de uso es un struct con un método `Handle`.

## 1. Forma de un caso de uso

```go
package application

type RecordGoal struct {
	Tenant        tenant.ID // lo pone el adapter desde el Principal; nunca viene del body
	Actor         Actor
	Match         domain.MatchID
	Player        domain.PlayerID
	Minute        domain.Minute
	ClientEventID domain.EventID // ID que genera el teléfono para la cola offline
}

type RecordGoalResult struct {
	Match   domain.MatchID
	Goals   int
	Replay  bool
}

type RecordGoalHandler struct {
	Matches     Matches
	Memberships Memberships
	Events      Publisher
	Clock       clock.Clock
}

func (h RecordGoalHandler) Handle(ctx context.Context, cmd RecordGoal) (RecordGoalResult, error) {
	ok, err := h.Memberships.IsDelegateOfMatch(ctx, cmd.Tenant, cmd.Actor.Subject, cmd.Match)
	if err != nil {
		return RecordGoalResult{}, fmt.Errorf("record goal: membership: %w", err)
	}
	if !ok && !cmd.Actor.Has(RoleCoach) {
		return RecordGoalResult{}, ErrNotDelegateOfMatch
	}
	goal, err := domain.NewGoal(cmd.Player, cmd.Minute)
	if err != nil {
		return RecordGoalResult{}, err
	}
	at := h.Clock.Now()
	m, replay, err := h.Matches.Update(ctx, cmd.Tenant, cmd.Match, cmd.ClientEventID, func(m *domain.Match) error {
		return m.RecordGoal(goal, at)
	})
	if err != nil {
		return RecordGoalResult{}, fmt.Errorf("record goal %s: %w", cmd.Match, err)
	}
	if !replay {
		_ = h.Events.Publish(ctx, cmd.Tenant, m.PullEvents()) // best effort: el estado ya está guardado
	}
	return RecordGoalResult{Match: m.ID(), Goals: m.GoalCount(), Replay: replay}, nil
}
```

| Regla | Cómo se verifica |
|---|---|
| Un archivo por caso de uso (`record_goal.go`) con el command, el resultado y el handler; el test al lado | Revisión de estructura (skill `onion-screaming-architecture` §6) |
| `Handle(ctx, cmd) (Result, error)`: un único argumento de entrada además del `ctx` | Revisión: ninguna firma `Handle(ctx, a, b, c)` |
| El handler es un struct con sus puertos como campos exportados; el wiring los llena en `cmd/api` | `go vet` + el test arma el handler con fakes sin constructor mágico |
| Los campos del command son tipos de dominio ya validados (`domain.Minute`, no `int`) | El adapter HTTP parsea y valida antes de construir el command; un `int` suelto en un command es un hallazgo |
| Sin `time.Now()` ni `uuid.New()`: el handler usa `Clock` e `ids.Generator` | `<lint>`: forbidigo |

## 2. Tenant y actor

`Tenant` y `Actor` viajan **dentro del command**, y solo los llena el adapter HTTP a partir de `auth.FromContext(ctx)`. El `context` lleva el `Principal` hasta el adapter; desde ahí en adelante el tenant es un argumento explícito que el compilador obliga a pasar. `application` no lee el `context` para sacar el tenant.

```go
type Actor struct {
	Subject string
	Roles   []Role
}
```

**Cómo se verifica:** el esquema del request en `api/openapi.yaml` no tiene `coach_id` ni `tenant` (skill `api-contract-openapi`), y el test de handler HTTP de skill `multi-tenancy-app-level` §4 manda un body con un tenant ajeno y comprueba que se ignora.

## 3. Puertos

Interfaces **chicas**, declaradas en `application/ports.go` por quien las usa, con `tenant.ID` en toda firma que toque datos de un tenant:

```go
type Matches interface {
	Get(ctx context.Context, t tenant.ID, id domain.MatchID) (*domain.Match, error)
	// Update relee, aplica fn y guarda en una transacción; si hay conflicto OCC
	// reintenta todo, así que fn tiene que ser pura (solo muta el aggregate).
	Update(ctx context.Context, t tenant.ID, id domain.MatchID, event domain.EventID, fn func(*domain.Match) error) (*domain.Match, bool, error)
}

type Memberships interface {
	IsDelegateOfMatch(ctx context.Context, t tenant.ID, subject string, id domain.MatchID) (bool, error)
}

type Publisher interface {
	Publish(ctx context.Context, t tenant.ID, events []domain.Event) error
}
```

- **No hay `Load` + `Save` separados para escribir.** Con la concurrencia optimista de DSQL, un reintento que no vuelve a leer pisa el cambio del otro. La lectura, la mutación y la escritura van juntas dentro de `Update`, y el adapter las corre en `db.InTx` (skill `persistence-sqlc-dsql` §4).
- `fn` no hace I/O, no publica y no lee el reloj: puede correr hasta 5 veces. El instante se calcula **antes** (`at := h.Clock.Now()`).
- Un puerto por necesidad, no un `Repository` con 15 métodos. Si una query nueva no encaja, es otro puerto.
- **Cómo se verifica:** cada puerto tiene su fake en `<ctx>test` con `var _ application.Matches = (*Matches)(nil)`, y `go vet ./...` falla si el fake no lo implementa.

## 4. Idempotencia de los eventos offline

El teléfono del delegado manda cada evento con un `client_event_id` (UUID generado en el cliente). `Update` lo registra en la misma transacción que el cambio. Si ya estaba, no aplica `fn` y devuelve `replay = true` con el estado actual, y el handler responde el mismo resultado sin publicar de nuevo. **Cómo se verifica:** test de handler que manda dos veces el mismo command y comprueba que el gol se cuenta una vez, que el segundo resultado tiene `Replay: true` y que el fake de `Publisher` recibió una sola publicación.

## 5. Autorización

Dos niveles, y los dos son obligatorios:

1. **Gruesa, en el borde:** los roles de cada operación en el `security` del contrato, que `auth.Operations.Check` hace cumplir por `operationId` (skills `api-contract-openapi` §3 y `http-lambda` §2), con los grupos de Cognito (profe, ayudante, delegado, padre).
2. **Fina, en application, con datos:** "es delegado *de esta categoría*" o "es padre *de este alumno*" se pregunta a un puerto (`Memberships`) dentro del mismo tenant. Si no corresponde → `ErrNotDelegateOfMatch` (`KindForbidden`, 403). Si el recurso no existe en el tenant → `ErrNotFound` (404), nunca 403.

**Cómo se verifica:** por cada handler con autorización fina, un caso de test por rol permitido y uno por rol denegado.

## 6. Queries

Una query devuelve un **read model** de application (struct plano, sin métodos de negocio), no un aggregate. El adapter lo arma directo desde la fila de sqlc, sin pasar por `Rehydrate`.

```go
type MatchBoard struct {
	Match     domain.MatchID
	HomeGoals int
	AwayGoals int
	Status    domain.Status
}

type MatchBoards interface {
	Board(ctx context.Context, t tenant.ID, id domain.MatchID) (MatchBoard, error)
}
```

Una query no escribe, no publica y no abre transacción de escritura.

## 7. Tests de handler

Nivel 2 de skill `testing-conventions`: fakes de `<ctx>test`, sin DB ni HTTP, reloj fijo con `clock.Func`. Hay que cubrir el caso feliz, cada error que el handler puede devolver (`require.ErrorIs`), el replay y la autorización.

## 8. Checklist

- [ ] ¿Command y resultado como structs, con un `Handler` struct y `Handle(ctx, cmd)`?
- [ ] ¿`Tenant` y `Actor` dentro del command, puestos solo por el adapter desde el `Principal`?
- [ ] ¿Puertos chicos en `application`, con `tenant.ID` en la firma y un fake con aserción de interfaz?
- [ ] ¿La escritura usa `Update(fn)` con `fn` pura, y el instante se calcula antes?
- [ ] ¿`client_event_id` registrado en la misma transacción, con replay probado?
- [ ] ¿Autorización gruesa en la ruta y fina en el handler, con casos permitido y denegado?
- [ ] ¿Eventos publicados después del commit y nunca en un replay?
