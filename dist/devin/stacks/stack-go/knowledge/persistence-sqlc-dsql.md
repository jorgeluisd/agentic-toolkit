# persistence-sqlc-dsql

**Cuándo aplica (trigger de la entrada de Knowledge):** Persistencia sobre Aurora DSQL: sqlc + pgx v5, migraciones con el runner propio (una sentencia por archivo, CREATE INDEX ASYNC, sin advisory locks), db/schema.sql para sqlc, restricciones de DSQL (sin triggers, PL/pgSQL, CREATE TYPE, TRUNCATE ni temporales; 3.000 filas y 10 MiB por transacción, 5 minutos; Repeatable Read; OCC con reintento), token IAM por conexión, transacciones idempotentes por client_event_id y Postgres local en Docker que imita a DSQL. Usar cuando se crea o cambia una tabla, migración, query de sqlc, repositorio o la conexión.

---

# Persistencia: sqlc + pgx sobre Aurora DSQL

El SQL se escribe a mano y queda visible en el repo. sqlc lo tipa, pgx v5 lo ejecuta y el runner de migraciones lo aplica. Todo tiene que correr igual en DSQL y en el Postgres local. Plantillas de este plugin: `templates/migrate/`, `templates/db/` (pool, `InTx`, `Chunks`, `dbtest`) y `templates/compose.yml`.

## 1. Qué no soporta DSQL (y qué hacer)

| DSQL no tiene | En su lugar | Cómo se verifica |
|---|---|---|
| Triggers, PL/pgSQL, `DO $$` | Lógica en Go, en `application` | `migrate.Check` rechaza la migración |
| `CREATE TYPE` / enums | `text NOT NULL CHECK (status IN (...))` y `type Status string` en el dominio | `migrate.Check` |
| `TRUNCATE` | `DELETE` por lotes de ≤ 3.000 filas | `migrate.Check` |
| Tablas temporales | CTE (`WITH ...`) o subconsultas | `migrate.Check` |
| Extensiones, varias bases | Funciones de Go; un clúster por producto, schemas para separar | `migrate.Check` |
| RLS (no documentado) | Filtro de tenant en cada query (skill `multi-tenancy-app-level`) | `TestQueries_FilterByTenant` |
| Varias DDL por transacción; DDL junto con DML | **Una sentencia por archivo de migración** | `migrate.Check` (más de un `;`) |
| `CREATE INDEX` bloqueante o `CONCURRENTLY` | `CREATE INDEX ASYNC`: devuelve un `job_id` que el runner espera con `sys.wait_for_job` | `migrate.Check` |
| Índices sobre `json`/`jsonb` | Columnas tipadas para lo que se filtra; `jsonb` solo para guardar | Revisión de la migración |
| Más de 3.000 filas o 10 MiB por transacción, más de 5 minutos | `db.Chunks(items, n)` y una transacción por lote; tareas por tenant, nunca "todos" | `TestChunks_NeverExceedsTheDSQLRowLimit` y test del caso de uso con > 3.000 filas |
| Otros aislamientos | Repeatable Read fijo; el Postgres local corre igual (§7) | `SHOW default_transaction_isolation` = `repeatable read` |
| Bloqueos pesimistas | Concurrencia optimista: el conflicto sale al commit con SQLSTATE `40001` (`OC000` datos, `OC001` esquema) → `db.InTx` reintenta | `TestInTx_RetriesConcurrentConflicts` |

Sí soporta claves foráneas, vistas, `json`/`jsonb` sin índices, y (desde febrero de 2026) secuencias e identity. Igual, los IDs son **UUID generados por la app** (v7 por orden temporal), porque así se reparte la escritura entre particiones y el cliente offline puede crear IDs sin red. Ante la duda, la documentación de DSQL manda sobre esta tabla.

## 2. Esquema

- Tablas en plural `snake_case`; columnas `snake_case`; PK compuesta `(coach_id, id)` en toda tabla con datos de un tenant.
- `coach_id uuid NOT NULL` como primera columna de la PK y de todo índice: cada query filtra por tenant y el índice la cubre.
- Tiempos en `timestamptz` (DSQL corre en UTC); dinero en `bigint` de unidad menor más `currency text`.
- `CHECK` para estados y rangos; `NOT NULL` por defecto; `DEFAULT` solo con valores constantes.
- Claves foráneas sí, incluyendo `coach_id` en la referencia (`FOREIGN KEY (coach_id, match_id) REFERENCES matches (coach_id, id)`), para que la DB tampoco permita cruzar tenants.

## 3. Migraciones

- Archivos `db/migrations/NNNN_slug.sql`, **una sentencia cada uno**, aditivas (expand/contract): agregar columna nullable → backfill por lotes → `NOT NULL` en una migración posterior. Nunca se edita una migración ya mergeada.
- Idempotentes: `CREATE TABLE IF NOT EXISTS`, `ADD COLUMN IF NOT EXISTS`. El runner registra cada versión en una transacción aparte de su DDL (regla de DSQL), así que, si algo se corta en el medio, al reintentar tolera "ya existe" (SQLSTATE `42P07`, `42701`, `42710`).
- Las corre `cmd/migrate` (paso del deploy o del CI con el rol de migración), **nunca** el init de la Lambda: el arranque en frío no paga DDL y el rol de la API no tiene permisos de DDL.
- `go run ./cmd/migrate -schema >| db/schema.sql` regenera el esquema para sqlc. El parser de sqlc no entiende `ASYNC`, así que lee `db/schema.sql`, que es el mismo esquema en dialecto Postgres. Se commitea, y el CI falla si no coincide.

**Cómo se verifica:** `TestCheck_RejectsWhatDSQLCannotRun` y `TestSchema_StripsAsyncForSqlc` (unit), `TestRun_AppliesOnceAgainstPostgres` (integración). En el CI: `go run ./cmd/migrate -schema | diff - db/schema.sql`.

## 4. Conexión y transacciones

```go
pool, err := db.NewDSQLPool(ctx, db.DSQLConfig{
	Endpoint: cfg.DSQLEndpoint, Region: awsCfg.Region, User: "app", Credentials: awsCfg.Credentials,
})
```

- `NewDSQLPool` no abre conexiones: la primera consulta conecta. `BeforeConnect` firma un **token IAM** nuevo por conexión (`auth.GenerateDbConnectAuthToken`; `admin` solo para `cmd/migrate`). No hay contraseña en ningún lado.
- `MaxConns = 2` (una Lambda atiende una request a la vez), `MaxConnLifetime = 50m` (DSQL corta a los 60), `sslmode=verify-full`.
- Toda escritura va en `db.InTx(ctx, pool, fn)`. Reintenta hasta 5 veces ante `40001` con backoff y jitter, así que `fn` **relee, muta y escribe** adentro, y no tiene efectos afuera: nada de publicar, mandar emails ni leer el reloj ahí (skill `application-cqrs` §3).
- Después de agotar los reintentos, el adapter devuelve `KindUnavailable` (`BUSY`, 503) y el cliente reintenta con el mismo `client_event_id`.

## 5. Transacciones idempotentes

Tabla por contexto, en la misma transacción que el cambio:

```sql
CREATE TABLE IF NOT EXISTS applied_events (
  coach_id uuid NOT NULL,
  client_event_id uuid NOT NULL,
  applied_at timestamptz NOT NULL,
  PRIMARY KEY (coach_id, client_event_id)
)
```

Dentro de `InTx`: `INSERT INTO applied_events ... ON CONFLICT DO NOTHING`. Si no insertó ninguna fila, el evento ya se aplicó: no se ejecuta `fn` y se devuelve `replay = true` con el estado actual. Dos teléfonos que mandan el mismo evento a la vez chocan en la PK, uno de los dos reintenta y en el reintento ve el replay. **Cómo se verifica:** test de integración que aplica el mismo `client_event_id` dos veces (secuencial y concurrente) y cuenta una sola fila de efecto.

## 6. sqlc

```yaml
# sqlc.yaml
version: "2"
sql:
  - engine: postgresql
    schema: db/schema.sql
    queries: internal/matches/adapters/postgres/queries
    gen:
      go:
        package: gen
        out: internal/matches/adapters/postgres/gen
        sql_package: pgx/v5
        emit_empty_slices: true
```

- Un bloque `sql:` por contexto; `queries/*.sql` con `-- name: X :one|:many|:exec|:execrows`, y en cada una `coach_id = @coach_id`.
- `gen/` es salida: no se edita a mano, se commitea, y el CI regenera y falla si hay diff (`go tool -modfile=tools/go.mod sqlc generate && git diff --exit-code`). `go tool -modfile=tools/go.mod sqlc vet` en CI.
- El repositorio (`adapters/postgres/<entidad>.go`) envuelve `gen.Queries`: traduce las filas a `domain` con `Rehydrate` o a read models, y traduce los errores (`pgx.ErrNoRows` → `ErrNotFound`, `23505` → conflicto del caso de uso). `gen` nunca sale del adapter.
- Lotes con `db.Chunks` y una `InTx` por lote. Para insertar muchas filas, un `INSERT ... SELECT unnest(@ids::uuid[]), ...` por lote. `:copyfrom` (protocolo COPY) no se usa sin antes confirmar en la documentación de DSQL que está soportado.

## 7. Postgres local que imita a DSQL

`templates/compose.yml`: `postgres:17-alpine` con `default_transaction_isolation=repeatable read`, `timezone=UTC` y `--locale=C` (DSQL usa collation C). Con eso, un conflicto concurrente devuelve `40001` igual que DSQL, y el reintento se prueba en local. Lo que Postgres sí permitiría y DSQL no (triggers, `TRUNCATE`, varias DDL) lo frena `migrate.Check` **antes** de tocar la base, y los límites por transacción, `db.Chunks`. Los tests de integración usan `dbtest.Pool(t)`/`dbtest.Conn(t)`: un schema propio por test y negativa a correr si `DATABASE_URL` no es local.

## 8. Checklist

- [ ] ¿Migración nueva con una sola sentencia, idempotente, aditiva y sin construcciones que DSQL no soporte? (`migrate.Check`)
- [ ] ¿Índices con `CREATE INDEX ASYNC` y `coach_id` primero?
- [ ] ¿`db/schema.sql` regenerado y `gen/` de sqlc regenerado y commiteado?
- [ ] ¿Toda escritura en `db.InTx` con lectura dentro y sin efectos externos?
- [ ] ¿Eventos del cliente con `client_event_id` registrado en la misma transacción?
- [ ] ¿Ningún lote supera 3.000 filas por transacción?
- [ ] ¿Tests de integración con `dbtest` contra el Postgres de `compose.yml`, incluido el cross-tenant?
