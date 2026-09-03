---
name: multi-tenancy-rls
description: "Aislamiento por tenant: tenant desde auth y nunca del body, TenantContext.run con SET LOCAL, RLS ENABLE+FORCE+USING+WITH CHECK fail-closed, roles sin BYPASSRLS, autorización doble, 404 vs 403, jobs por tenant y tests cross-tenant. Usar cuando se toca una tabla, repo, guard o endpoint con tenant."
---

# Multi-tenancy con RLS

**Aplica solo si el proyecto declara un campo de tenant** (por ejemplo `tenant_id`). Sin tenant declarado, esta skill no impone nada; el resto de las reglas de persistencia siguen en `persistence-drizzle`.

## 1. Regla de oro

**El tenant sale del contexto de autenticación. Nunca del body, query, params ni de ningún payload del cliente.** Un endpoint que acepta `tenantId` del cliente es un bug de aislamiento aunque RLS lo cubra: RLS filtra por el GUC que la app fija, y la app lo fijaría con el valor que el atacante mandó. La defensa es en profundidad y en este orden: (1) el tenant se deriva de un claim o membresía verificada por el servidor, (2) el pipe rechaza cualquier DTO que lo traiga, (3) el handler abre `TenantContext.run`, (4) RLS re-verifica en Postgres, (5) tests que prueban cada capa.

## 2. Origen del tenant

| Fuente | Cuándo | Validación obligatoria |
|---|---|---|
| Claim del JWT (`tenant_id` acuñado por el servidor de auth en login/refresh) | Un usuario pertenece a un tenant activo a la vez | Firma, `iss`, `aud`, `exp`; el claim se acuña solo si la membresía está activa; cambiar de tenant = refresh |
| Header `x-tenant-id` + `sub` del JWT | Un usuario con varios tenants | El guard comprueba membresía activa `(auth_user_id, tenant_id)` en cada request (cache corto, §7); sin membresía → 403 |
| Slug/id público en la URL | Endpoint público sin auth (formulario público, webhook) | Resolver el tenant en el servidor (slug → id, número de teléfono → id), entrar al contexto, rate limit |

En los tres casos el resultado es un `TenantContext` request-scoped (`tenantId`, `authUserId`, `roles`, `traceId`) inyectado con `@CurrentTenant()`; los commands y queries lo reciben en `ctx`, y `input` **nunca** tiene campo de tenant (ver `application-cqrs-jobs`).

## 3. `TenantContext.run`: contexto por transacción

```ts
@Injectable()
export class TenantContextRunner {
  constructor(@Inject(DB) private readonly db: Db) {}
  run<T>(tenantId: string, fn: (tx: Tx) => Promise<T>): Promise<T> {
    return this.db.transaction(async (tx) => {
      // set_config(..., true) == SET LOCAL: muere al terminar la transacción. SET no admite parámetros; SET de sesión contamina el pool.
      await tx.execute(sql`select set_config('app.tenant_id', ${tenantId}, true)`);
      return fn(tx);
    });
  }
}
```

Todo acceso a tablas con tenant pasa por aquí; los repos reciben `tx` y no abren conexiones propias. Pooler en modo transacción con `prepare: false` (ver `persistence-drizzle` §4). **Cómo se verifica:** `grep -rnE "set_config\('app\.tenant_id'" apps/api/src` devuelve una sola ubicación (el runner); `grep -rnE "\bSET app\.tenant_id" apps/api/src` vacío.

## 4. El pipe rechaza tenant en el DTO

```ts
// main.ts — ValidationPipe global de NestJS (class-validator)
app.useGlobalPipes(new ValidationPipe({ whitelist: true, forbidNonWhitelisted: true, transform: true, transformOptions: { enableImplicitConversion: false } }));

// Pipe adicional: rechaza el campo de tenant aunque algún DTO lo declare por error
const TENANT_KEYS = ['tenantId', 'tenant_id'];   // los nombres declarados en el proyecto
@Injectable()
export class RejectTenantInBodyPipe implements PipeTransform {
  transform(value: unknown) {
    if (value && typeof value === 'object' && TENANT_KEYS.some((k) => k in (value as object))) throw new BadRequestException({ code: 'TENANT_IN_BODY' });
    return value;
  }
}
```

`forbidNonWhitelisted` ya rechaza `tenantId` si el DTO no lo declara; el pipe explícito cubre el caso en que alguien lo declare. El test de arquitectura (§9) garantiza que ningún DTO lo declare. Fuera de NestJS (Server Actions, Edge Functions) el equivalente es zod `.strict()`.

## 5. Policy RLS

```sql
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders FORCE ROW LEVEL SECURITY;            -- aplica también al owner de la tabla
CREATE POLICY tenant_isolation ON orders
  FOR ALL TO app_role
  USING      (tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid)   -- SELECT/UPDATE/DELETE
  WITH CHECK (tenant_id = nullif(current_setting('app.tenant_id', true), '')::uuid);  -- INSERT/UPDATE
```

- `current_setting(name, true)`: `missing_ok`; sin contexto devuelve NULL o `''` según el estado de la conexión; `nullif` convierte ambos en NULL y `tenant_id = NULL` no matchea ninguna fila. **Fail-closed**: sin contexto → 0 filas, nunca "todas".
- Sin `WITH CHECK` los `INSERT` fallan con `new row violates row-level security policy`; sin `FORCE` el owner y los roles admin ven todo.
- Una policy por tabla con tenant, dentro de la misma migración que crea la tabla. Tablas globales (catálogos, la tabla maestra de tenants) se documentan como excepción en el schema.
- Sin RLS de la aplicación **no** se acepta la alternativa "sin policies porque el único cliente es la API con rol privilegiado": eso es cero aislamiento en la base.

## 6. Roles

```sql
CREATE ROLE app_role LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE INHERIT;
GRANT USAGE ON SCHEMA orders TO app_role;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA orders TO app_role;    -- sin DELETE en tablas append-only
ALTER DEFAULT PRIVILEGES FOR ROLE migrator IN SCHEMA orders GRANT SELECT, INSERT, UPDATE ON TABLES TO app_role;
```

| Rol | Quién lo usa | RLS |
|---|---|---|
| `app_role` | La API y el worker en el path de negocio | Sujeto a RLS; sin `BYPASSRLS`, sin ownership |
| `migrator` | Solo `drizzle-kit migrate` y backfills desde CI/release; owner de los objetos | `BYPASSRLS` explícito (con `FORCE`, ser owner no basta para un backfill). Su credencial nunca llega a la app |
| Barridos cross-tenant (reportes, billing) | Worker identificado, función `SECURITY DEFINER` acotada o rol admin dedicado, nunca desde un controller | Explícito y auditado |
| `service_role` / superusuario del proveedor | Nunca en la app. Solo consola de emergencia con OK humano | Bypasea todo |

**Cómo se verifica:** `SELECT rolname, rolbypassrls, rolsuper FROM pg_roles WHERE rolname = current_user` con `DATABASE_URL` de la app → `f | f`; `grep -rn "SERVICE_ROLE\|service_role" apps/api/src` vacío fuera de scripts de migración.

## 7. Autorización dos veces, 404 vs 403, jobs y cache

La matriz de permisos se implementa **dos veces**: guard/policy en aplicación (`RolesGuard` + `ctx.roles`) y RLS. Ninguna de las dos es suficiente sola: el guard no sabe de filas; RLS no sabe de acciones de negocio.

| Situación | Status | Por qué |
|---|---|---|
| Sin token, token inválido o expirado | 401 | No hay identidad |
| Usuario autenticado sin membresía en el tenant pedido (header/claim) | 403 | Autorización de tenant; no revela ningún recurso |
| Rol insuficiente dentro de su tenant | 403 | Identidad y tenant válidos, acción no permitida |
| Recurso de otro tenant por id | **404** | RLS devuelve `null`; un 403 confirmaría que el id existe |
| `tenantId` en body/query/params | 400 `TENANT_IN_BODY` | Contrato roto |

- Batch/cron: **siempre por tenant**. El scheduler itera tenants y encola un job por tenant con `tenantId` + `traceId`; el job abre `TenantContext.run`. Nunca un barrido global con rol privilegiado "porque es interno".
- Cache de membresías/permisos: TTL corto **y** invalidación por evento (`MembershipRevoked`, `RoleChanged`). Un cache sin invalidación mantiene acceso tras la revocación.

## 8. Tests obligatorios por tabla/repo nuevo

Corren en `pnpm test:integration` contra Postgres real conectado como `app_role`; el cliente admin (migrador) solo siembra y limpia (ver `testing-conventions`).

```ts
// order.repository.integration.spec.ts — cross-tenant
it('does not expose an order of tenant A to tenant B', async () => {
  await runner.run(tenantA, (tx) => repo.save(orderOf(tenantA), tx));
  const seen = await runner.run(tenantB, (tx) => repo.findById(orderId, tx));
  expect(seen).toBeNull();                                       // → 404 en el borde, nunca 403
});
it('rejects inserting a row for another tenant', async () => {
  await expect(runner.run(tenantB, (tx) => repo.save(orderOf(tenantA), tx))).rejects.toThrow(/row-level security/);
});
```

```sql
-- smoke RLS: SELECT sin WHERE devuelve solo el tenant del SET LOCAL; sin contexto, 0 filas
BEGIN; SELECT set_config('app.tenant_id', :'tenant_a', true); SELECT count(*) FROM orders; COMMIT;   -- = filas de A
BEGIN; SELECT count(*) FROM orders; COMMIT;                                                             -- = 0
```

```sql
-- test de arquitectura: toda tabla con columna tenant tiene RLS habilitado, forzado y con policy
SELECT n.nspname, c.relname FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id' AND NOT a.attisdropped
WHERE c.relkind = 'r' AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND NOT (c.relrowsecurity AND c.relforcerowsecurity AND EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid = c.oid));
-- esperado: 0 filas. El spec falla si devuelve alguna.
```

Test de arquitectura de DTOs (unit, sin DB): `grep -rlE "tenantId|tenant_id" apps/api/src/contexts/*/presentation packages/contracts/src` debe estar vacío; en Vitest, un spec que recorre los archivos `*.schema.ts`/`*.dto.ts` con `fast-glob` y aserta `not.toMatch(/tenant_?id/i)`. Complemento de tipos: `// @ts-expect-error` al construir un `PlaceOrderInput` con `tenantId`.

## 9. Errores comunes → arreglo

| Síntoma | Causa | Arreglo |
|---|---|---|
| `new row violates row-level security policy` | Policy sin `WITH CHECK`, o contexto de otro tenant | Agregar `WITH CHECK`; revisar quién fijó el GUC |
| 0 filas con datos presentes | `TenantContext.run` no abierto; GUC vacío | Envolver el acceso; fail-closed funcionando |
| Tenant ve filas de otro | `SET` de sesión + pool; rol con `BYPASSRLS`; falta `FORCE` | `SET LOCAL`; recrear rol; `FORCE ROW LEVEL SECURITY` |
| `invalid input syntax for type uuid: ""` | `current_setting` devuelve `''` tras una tx anterior | `nullif(current_setting(...), '')::uuid` |
| Admin "no ve nada" en reportes | Correcto: RLS aplica | Job por tenant o función `SECURITY DEFINER` acotada, no desactivar RLS |
| Acceso persiste tras revocar membresía | Cache sin invalidación | Evento `MembershipRevoked` → invalidar; TTL corto |
| 403 en recurso ajeno | Guard responde antes que RLS con el id | Devolver 404 desde `EntityNotFoundError` |

## 10. Checklist

- [ ] ¿Tenant derivado de claim/membresía verificada; ningún DTO, query ni param lo acepta; `input` sin tenant?
- [ ] ¿Handler/job abre `TenantContext.run`; repos reciben `tx`; `set_config(..., true)` en un solo lugar?
- [ ] ¿Tabla nueva con `tenant_id uuid not null`, `ENABLE` + `FORCE`, policy `USING` + `WITH CHECK` con `nullif(current_setting(..., true), '')::uuid`, en la misma migración?
- [ ] ¿Rol de app sin `BYPASSRLS`/`SUPERUSER`/ownership; migrador aparte; sin `service_role` en el path de negocio?
- [ ] ¿Permiso en guard **y** en RLS; recurso ajeno → 404; sin membresía → 403; tenant en body → 400?
- [ ] ¿Jobs por tenant con `tenantId` + `traceId`; cache de permisos con invalidación por evento?
- [ ] ¿Tests: cross-tenant lectura y escritura, smoke RLS, arquitectura (`pg_class` + DTOs), en `pnpm test:integration` con `app_role`?
