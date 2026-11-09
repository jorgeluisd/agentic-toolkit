---
name: persistence-drizzle
description: "Schema Drizzle sobre Postgres: naming, tipos, ids de la app, varchar+CHECK sin pgEnum, migraciones aditivas expand/contract con RLS dentro, journal, pooler prepare:false, SET LOCAL, SECURITY DEFINER, repos con rehydrate. Usar cuando se crea o cambia una tabla, migración, función SQL o repositorio."
---

# Persistencia: Drizzle + Postgres

`infrastructure/persistence/` de cada contexto: schema Drizzle (`*.schema.ts`), adapters (`*.repository.drizzle.ts`), mappers infra→domain. Las migraciones SQL las genera `drizzle-kit` y se versionan en el repo; el dashboard de la base nunca es fuente de verdad. Si el proyecto declara tenant, ver `multi-tenancy-rls` para policies y contexto.

## 1. Naming

| Elemento | Regla | Ejemplo |
|---|---|---|
| Tabla | plural, snake_case, sin prefijos ni nombre del contexto salvo colisión | `orders`, `order_lines` |
| Columna | snake_case en DB, camelCase en TS; FK `<entidad>_id`; booleanos `is_*`; fechas `<verbo>_at` | `tenant_id` ↔ `tenantId`, `placed_at` |
| Índice | `<tabla>_<cols>_idx`; en toda FK filtrada; compuestos que empiezan por `tenant_id` cuando la query es por tenant | `orders_tenant_status_created_idx` |
| CHECK / UNIQUE / policy | `<tabla>_<col>_check`, `<tabla>_<cols>_key`, `tenant_isolation` | `orders_status_check` |
| Esquema Postgres (opcional) | uno por contexto cuando el proyecto lo decide: `pgSchema('orders')`; nunca objetos de negocio en esquemas de terceros | `orders.orders` |

## 2. Tipos de columna

| Necesidad | Drizzle | Postgres | Nota |
|---|---|---|---|
| ID / FK | `uuid('id').primaryKey()` sin default | `uuid` | Generado por la app (`IdGenerator`, UUID v7). Nunca `gen_random_uuid()` como fuente de verdad |
| Texto corto / largo | `varchar('x', { length })` / `text()` | `varchar(n)` / `text` | Longitud = la del VO |
| Enum | `varchar({ length: 20 })` + `check()` | `varchar` + `CHECK` | **No `pgEnum`**: `ALTER TYPE … ADD VALUE` no es transaccional y el rename es destructivo |
| Dinero | `bigint('amount', { mode: 'number' })` + `varchar('currency', { length: 3 })` | `bigint` + `varchar(3)` | Unidad menor + ISO 4217; `mode: 'bigint'` si supera `MAX_SAFE_INTEGER`. Nunca `numeric`/`float` |
| Fecha-hora | `timestamp('x', { withTimezone: true, mode: 'date' })` | `timestamptz` | Nunca `timestamp` sin zona |
| Datos semiestructurados | `jsonb('x').$type<Shape>()` | `jsonb` | Solo para payloads sin invariantes propias |
| Usuario de auth | `uuid('auth_user_id')` | `uuid` | Opaco: **sin FK a `auth.users`** ni a ningún esquema del proveedor (reemplazable, y el `pg_dump` restaura en cualquier Postgres) |

```ts
// orders.schema.ts
export const orders = pgTable('orders', {
  id: uuid('id').primaryKey(),
  tenantId: uuid('tenant_id').notNull(),
  customerId: uuid('customer_id').notNull().references(() => customers.id, { onDelete: 'restrict' }),
  status: varchar('status', { length: 20 }).notNull(),
  totalAmount: bigint('total_amount', { mode: 'number' }).notNull(),
  currency: varchar('currency', { length: 3 }).notNull(),
  placedAt: timestamp('placed_at', { withTimezone: true, mode: 'date' }),
  createdAt: timestamp('created_at', { withTimezone: true, mode: 'date' }).notNull().defaultNow(),
  updatedAt: timestamp('updated_at', { withTimezone: true, mode: 'date' }).notNull().defaultNow(),
}, (t) => [
  index('orders_tenant_status_created_idx').on(t.tenantId, t.status, t.createdAt),
  check('orders_status_check', sql`${t.status} in ('draft', 'placed', 'cancelled')`),
]);
```

Registros auditables/financieros: sin `UPDATE`/`DELETE` (trigger que lanza excepción); la corrección es una fila compensatoria.

## 3. Migraciones

`pnpm drizzle-kit generate` produce `migrations/NNNN_<slug>.sql` + entrada en `meta/_journal.json`; `pnpm drizzle-kit migrate` aplica. Reglas:

- **Aditivas y forward-only**: no hay `down`; corregir = nueva migración. Una migración aplicada en `develop`/`main` es inmutable.
- **Compatibles con el código anterior** (deploy sin ventana: orden migraciones → api → web): un cambio incompatible se hace en dos PR con **expand/contract**.
- **RLS, triggers, funciones y grants van dentro del `.sql`** (append a mano después de generar): `drizzle-kit` no los produce y el dashboard no se versiona.
- Atómica: tabla + índices + CHECK + RLS + trigger `set_updated_at` en la misma migración.

```sql
-- 0007_orders_placed_at_expand.sql  (PR 1: el código escribe placed_at y tolera NULL al leer)
ALTER TABLE orders ADD COLUMN placed_at timestamptz;
UPDATE orders SET placed_at = created_at WHERE placed_at IS NULL;   -- backfill; en tablas grandes: job por lotes
ALTER TABLE orders ADD CONSTRAINT orders_placed_at_not_null CHECK (placed_at IS NOT NULL) NOT VALID;

-- 0008_orders_placed_at_contract.sql  (PR 2, tras confirmar que ninguna versión desplegada inserta NULL)
ALTER TABLE orders VALIDATE CONSTRAINT orders_placed_at_not_null;
ALTER TABLE orders ALTER COLUMN placed_at SET NOT NULL;
ALTER TABLE orders DROP CONSTRAINT orders_placed_at_not_null;
```

| Prohibido en un PR normal | Requiere plan de migración (documento en `docs/sdd/<feature>/` con expand, backfill, contract y rollback por compensación) |
|---|---|
| `DROP TABLE`, `DROP COLUMN` | Renombrar en código, dejar de leer, esperar un ciclo de deploy, contract en PR posterior |
| `ALTER COLUMN … TYPE` | Columna nueva + backfill + doble escritura + swap |
| `NOT NULL` sin `DEFAULT` sobre tabla con datos | Expand con CHECK `NOT VALID` → backfill → `VALIDATE` → `SET NOT NULL` |
| `RENAME COLUMN/TABLE` | Es un drop disfrazado para el código desplegado: mismo tratamiento |
| Cambio de policy RLS que amplía filas visibles | Revisión de seguridad + test cross-tenant actualizado |

**Cómo se verifica:** `git diff --name-only origin/develop... -- '**/migrations/*.sql' | xargs grep -nE 'DROP (TABLE|COLUMN)|ALTER COLUMN .* TYPE|RENAME|SET NOT NULL'` debe salir vacío o venir con el plan enlazado en el PR.

### Journal: manda `when`, no `idx`

`drizzle-kit migrate` ordena y filtra por `when` (ms). Una migración con `when` menor que la última aplicada **se salta en silencio**: imprime `Migrations complete` y la columna no existe. Incidente típico: reordenar migraciones a mano tras un rebase, o inventar un `when` "de hoy" cuando los existentes van por delante del reloj.

```json
{ "idx": 8, "version": "7", "when": 1787460000001, "tag": "0008_orders_placed_at_contract", "breakpoints": true }
```

Regla: `when` nuevo = `when` de la última entrada + 1 como mínimo; una migración ya aplicada no se edita ni se reordena. **Cómo se verifica:** `pnpm drizzle-kit check` sin conflictos; `jq '[.entries[].when] | . == sort' meta/_journal.json` → `true`; tras migrar, `psql -c '\d orders'` muestra la columna.

## 4. Conexión y contexto por transacción

```ts
// postgres.js detrás de un pooler en modo transacción (pgbouncer/Supavisor): sin prepared statements
export const sql = postgres(env.DATABASE_URL, { prepare: false, max: env.DB_POOL_MAX });
export const db = drizzle(sql, { schema });
```

- `prepare: false` es obligatorio con pooler en modo transacción (el statement preparado vive en una conexión que la siguiente transacción no tiene).
- Todo estado de sesión se fija con **`SET LOCAL`** (o `set_config(..., true)`) **dentro** de `db.transaction`; nunca `SET` de sesión: la conexión vuelve al pool con el valor puesto y lo hereda otro tenant.
- Rol de conexión de la app: `LOGIN`, `NOBYPASSRLS`, sin `SUPERUSER`, sin ownership de tablas. Las migraciones corren con un rol migrador aparte (owner de los objetos) desde CI/release, nunca desde la app.

**Cómo se verifica:** `psql "$DATABASE_URL" -c "select rolname, rolsuper, rolbypassrls from pg_roles where rolname = current_user"` → `f | f`. `grep -rn "prepare: true\|\bSET app\." apps/api/src` vacío.

## 5. Funciones `SECURITY DEFINER` y grants

```sql
CREATE OR REPLACE FUNCTION orders.count_open_orders(p_tenant uuid) RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = orders, pg_temp          -- obligatorio: sin esto, un search_path malicioso secuestra la función
AS $$ SELECT count(*)::int FROM orders.orders WHERE tenant_id = p_tenant AND status = 'placed' $$;
REVOKE ALL ON FUNCTION orders.count_open_orders(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION orders.count_open_orders(uuid) TO app_role;
```

- `SECURITY DEFINER` solo cuando la app no puede hacer la operación con su rol (bootstrap, barridos cross-tenant desde el worker). Cada una fija `search_path` y revoca `PUBLIC`.
- Roles anónimos (`anon` o equivalente): **ningún grant sobre tablas ni esquemas**; solo `EXECUTE` sobre RPC explícitos que devuelven un contrato mediado. Antes de un `GRANT`, la pregunta es "¿esto abre datos al público?".

**Cómo se verifica:** `SELECT proname FROM pg_proc WHERE prosecdef AND NOT EXISTS (SELECT 1 FROM unnest(coalesce(proconfig, '{}')) c WHERE c LIKE 'search_path=%')` → 0 filas. `SELECT table_schema, table_name, privilege_type FROM information_schema.role_table_grants WHERE grantee = 'anon'` → 0 filas.

## 6. Repositorio (adapter)

```ts
// order.repository.drizzle.ts — implementa el puerto OrderRepository de domain/repositories
export class DrizzleOrderRepository implements OrderRepository {
  async findById(id: OrderId, tx: Tx): Promise<Order | null> {
    const row = await tx.query.orders.findFirst({ where: eq(orders.id, id.value), with: { lines: true } });
    return row ? OrderMapper.toDomain(row) : null;
  }
  async save(order: Order, tx: Tx): Promise<void> {
    const row = OrderMapper.toPersistence(order);
    await tx.insert(orders).values(row).onConflictDoUpdate({ target: orders.id, set: { ...row, updatedAt: sql`now()` } });
  }
}
// order.mapper.ts (infra→domain): rehydrate, nunca create (create validaría y emitiría eventos al cargar)
static toDomain(r: OrderRow): Order {
  return Order.rehydrate({ id: OrderId.rehydrate(r.id), tenantId: r.tenantId, status: r.status as OrderStatus,
    total: Money.rehydrate(r.totalAmount, r.currency as CurrencyCode), lines: r.lines.map(OrderLineMapper.toDomain), placedAt: r.placedAt });
}
```

Sin lógica de negocio: ni `if (order.status === ...)`, ni cálculos, ni decisiones de tenant. El `tx` viene del contexto de tenant abierto por el handler; el repo no abre conexiones propias. Un valor inválido leído de la base es corrupción de datos: `rehydrate` lo acepta y un check de integridad lo detecta, no una regla de dominio.

## 7. Backup restaurable

Sin FK ni funciones a esquemas del proveedor, `pg_dump --no-owner --no-privileges` restaura en cualquier Postgres. **Cómo se verifica** (mensual o antes de una migración con plan): `pg_dump --schema-only ... | psql <db-vacía>` y luego `pnpm drizzle-kit migrate` contra esa base debe decir "no migrations to apply"; el restore completo se prueba corriendo `pnpm test:integration` contra la copia.

## 8. Errores comunes → arreglo

| Síntoma | Causa | Arreglo |
|---|---|---|
| `prepared statement "s1" already exists` / `does not exist` | Pooler en modo transacción con `prepare: true` | `postgres(url, { prepare: false })` |
| Query devuelve 0 filas con datos presentes | GUC de tenant no seteado o `SET` fuera de la transacción | `SET LOCAL` dentro de `TenantContext.run` |
| Tenant "ve" filas de otro tras un request | `SET` de sesión heredado por la conexión del pool | Reemplazar por `SET LOCAL` |
| `Migrations complete` pero la columna no existe | `when` del journal menor que el anterior | Corregir `when`, `drizzle-kit check` |
| `cannot ALTER TYPE ... in a transaction block` | `pgEnum` | `varchar` + `CHECK` (redefinir CHECK en migración nueva) |
| Evento "creado" emitido al cargar / restore falla por `auth.users` | `toDomain` usa `create()` / FK a esquema del proveedor | `rehydrate()` / columna `uuid` opaca |

## 9. Checklist

- [ ] ¿snake_case en DB, camelCase en TS, `timestamptz`, dinero `bigint` + moneda, enum `varchar` + `CHECK`, sin `pgEnum`?
- [ ] ¿`id` sin default (lo genera la app) y `auth_user_id` como `uuid` opaco sin FK?
- [ ] ¿Migración generada por `drizzle-kit`, aditiva, con RLS/trigger/grants dentro del `.sql`, `when` mayor que el anterior?
- [ ] ¿Ningún `DROP`/`ALTER TYPE`/`NOT NULL sin DEFAULT`/`RENAME`, o hay plan expand/contract enlazado?
- [ ] ¿`prepare: false`, `SET LOCAL` dentro de la transacción, rol de app sin `BYPASSRLS` ni ownership?
- [ ] ¿`SECURITY DEFINER` con `search_path` fijo y `REVOKE … FROM PUBLIC`; cero grants de tablas a roles anónimos?
- [ ] ¿Repo implementa el puerto, `toDomain` con `rehydrate`, sin lógica de negocio, recibe `tx`?
- [ ] ¿Test de integración del repo contra Postgres real con el rol de app (`testing-conventions`), cross-tenant si hay tenant; migración corrida local y `\d <tabla>` muestra lo esperado?
