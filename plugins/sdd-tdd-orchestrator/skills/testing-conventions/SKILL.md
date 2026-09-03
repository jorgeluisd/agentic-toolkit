---
name: testing-conventions
description: "Cuatro niveles de test con sufijos y comandos, Vitest único runner también en NestJS, cobertura por capa, fakes de puertos en vez de mocks, aserción de code, tests de tipos, integración contra Postgres real y e2e acotado. Usar cuando se escribe, ubica o revisa un test o se configura Vitest."
---

# Convenciones de testing

Un test es rápido, determinista y del nivel que corresponde a su capa; si es lento o flaky, está en el nivel equivocado. El **ciclo** RED → GREEN → TRIANGULATE → REFACTOR, la evidencia y el safety net viven en `strict-tdd`; esta skill fija niveles, dobles, comandos, cobertura y qué se prueba obligatoriamente.

## 1. Los 4 niveles

| # | Nivel | Qué prueba | Dónde (sufijo, ubicación) | Dobles | Velocidad | Cantidad |
|---|---|---|---|---|---|---|
| 1 | Unit de dominio | VO, aggregates, servicios de dominio: invariantes, `Result`, `pullEvents()` | `*.spec.ts` junto al archivo en `domain/` | Ninguno: `now`, ids y tunables entran como parámetros | < 1 ms | Muchos |
| 2 | Handler / use case | Secuencia del handler, error paths, eventos a outbox | `*.spec.ts` junto al handler en `application/` | Fakes de puertos (§4); sin `TestingModule`, sin DB, sin HTTP | ms | Medios |
| 3 | Integración de repo/adapter | SQL real, mappers, migraciones alineadas, RLS | `*.integration.spec.ts` junto al adapter en `infrastructure/` | Ninguno sobre la DB (Postgres real, rol de app) | 10–500 ms | Pocos |
| 4 | e2e de API | Cableado Nest completo: guards, pipes, filtro de excepciones, serialización, RLS de punta a punta | `*.e2e-spec.ts` en `presentation/http/` del endpoint | Ninguno (app real + supertest + Postgres) | s | Muy pocos: flujos críticos |

Presentation (guards, pipes, controllers) se cubre en nivel 2 con DI manual + `ExecutionContext` falso y bus fake que devuelve `ok`/`err` reales; el e2e valida el cableado, no la lógica. El frontend usa tests de componente (Testing Library sobre Vitest + jsdom), no e2e.

## 2. Sufijos, suites y comandos

| Comando | Config | Corre | Requiere |
|---|---|---|---|
| `pnpm test` (raíz, vía turbo) | `vitest.config.ts` | Niveles 1 + 2 (`src/**/*.spec.ts`) | Nada: sin Docker, sin red |
| `pnpm test:integration` | `vitest.integration.config.ts` | Niveles 3 + 4 (`*.integration.spec.ts`, `*.e2e-spec.ts`) | Postgres (docker o testcontainers) con rol de app |
| `pnpm --filter <pkg> exec vitest run <ruta> -t "<caso>"` | la que corresponda | Un test dirigido (RED/GREEN) | — |
| `pnpm --filter <pkg> exec vitest run --coverage` | unit | Cobertura por capa (§3) | — |

Vitest es el **único runner**, también en NestJS (`@nestjs/testing` corre sobre Vitest; jest no se introduce). Bootstrapear Nest requiere `emitDecoratorMetadata`, que esbuild no emite: sin `unplugin-swc` la inyección de dependencias falla en silencio en los tests de nivel 2 con `TestingModule` y en todos los e2e.

```ts
// apps/api/vitest.config.ts — unit (1 + 2)
import swc from 'unplugin-swc';
import { defineConfig } from 'vitest/config';
export default defineConfig({
  plugins: [swc.vite({ module: { type: 'es6' } })],
  test: {
    environment: 'node', include: ['src/**/*.spec.ts'], exclude: ['**/*.integration.spec.ts', '**/*.e2e-spec.ts'],
    coverage: { provider: 'v8', include: ['src/**'], thresholds: {
      'src/contexts/**/domain/**': { lines: 95, branches: 90 }, 'src/contexts/**/application/**': { lines: 85 },
      'src/contexts/**/presentation/**': { lines: 70 }, 'src/contexts/**/infrastructure/**': { lines: 60 } } },
  },
});
// apps/api/vitest.integration.config.ts — integración + e2e (3 + 4)
export default defineConfig({
  plugins: [swc.vite({ module: { type: 'es6' } })],
  test: { environment: 'node', include: ['src/**/*.integration.spec.ts', 'src/**/*.e2e-spec.ts'],
    fileParallelism: false, globalSetup: ['test/global-setup.ts'], testTimeout: 30_000, hookTimeout: 180_000 },
});
```

`package.json`: `"test": "vitest run"`, `"test:integration": "vitest run -c vitest.integration.config.ts"`. **Cómo se verifica:** `pnpm test` pasa con Docker apagado; `grep -rn "\"jest\"" package.json apps/*/package.json` vacío.

## 3. Cobertura por capa

| Capa | Líneas | Branches | Cómo se alcanza |
|---|---|---|---|
| `domain/` | 95 % | 90 % | Un caso válido y **cada** inválido por invariante; cada método de comando: estado + eventos |
| `application/` | 85 % | — | Happy path + cada error path del handler con fakes |
| `presentation/` | 70 % | — | Guards/pipes/mappers en unit; e2e solo en flujos críticos |
| `infrastructure/` | 60 % | — | Tests de integración del repo (no se cuentan en `pnpm test`) |

Los thresholds viven en la config (§2), no en un documento: `vitest run --coverage` falla el CI si bajan. Un "85 % global" no sirve: esconde un dominio al 40 %.

## 4. Dobles: permitidos y prohibidos

| Permitido | Forma | Prohibido | Por qué |
|---|---|---|---|
| `TimeProvider` fijo | `{ now: () => new Date('2026-01-01T00:00:00Z') }` | `vi.useFakeTimers` para saltar un `sleep` en dominio | El dominio no debe tener reloj propio |
| `IdGenerator` secuencial | `00000000-0000-7000-8000-000000000001`, `…002` | `Math.random`/`randomUUID` sin control | Ids no deterministas → asserts frágiles |
| `EventBus`/`Outbox` espía | `published: DomainEvent[]` inspeccionable | `toHaveBeenCalled()` sin argumentos | No prueba qué se publicó |
| Repositorio fake en memoria | Clase que **implementa el puerto** con un `Map` | `vi.mock('drizzle-orm')`, mock de pino, mock de pg-boss | Prueba el mock, no el adapter; el nivel correcto es 3 |
| Bus fake en presentation | `execute` devuelve `ok(...)`/`err(new XError())` reales | Mockear el sujeto bajo prueba | No prueba nada |
| `vi.fn()` sobre una interfaz de puerto | Solo cuando el fake completo no aporta (un puerto de un método) | `vi.spyOn` sobre internos privados | Acopla el test a la implementación |

```ts
export class InMemoryOrderRepository implements OrderRepository {
  private readonly rows = new Map<string, Order>();
  async findById(id: OrderId): Promise<Order | null> { return this.rows.get(id.value) ?? null; }
  async save(order: Order): Promise<void> { this.rows.set(order.id.value, order); }
}
const handler = new PlaceOrderHandler(new InMemoryOrderRepository(), fixedTime, sequentialIds, spyOutbox, passthroughTenantRunner, { maxLinesPerOrder: 10 });
```

`passthroughTenantRunner.run = (_tenant, fn) => fn(undefined as unknown as Tx)`: el aislamiento real se prueba en nivel 3, no aquí.

## 5. Aserciones: `code`, estado, eventos y tipos

```ts
const result = await handler.execute(new PlaceOrderCommand({ ctx, input: { customerId, lines: [] } }));
expect(isErr(result) && result.error.code).toBe('ORDER_EMPTY');       // el code, no solo isErr
expect(spyOutbox.published.map((e) => e.constructor.eventName)).toEqual(['orders.order.placed']);
```

- Aserta `code` (contrato con el frontend), el estado resultante y los eventos exactos; nunca `instanceof` solo ni `toBeTruthy()` sobre un `Result`.
- Firmas imposibles se prueban en el compilador: `expectTypeOf(Order.create).returns.toEqualTypeOf<Result<Order, DomainError>>()` y `// @ts-expect-error` en un archivo `*.spec.ts` incluido en `tsconfig.spec.json`; RED de tipos = `tsc --noEmit` falla (detalle en `strict-tdd` §3).
- Nombres en inglés que describen la regla: `it('rejects an order without lines')`, no `it('test placeOrder')`.

## 6. Integración contra Postgres real (nivel 3)

- **Dos conexiones**: `TEST_DATABASE_APP_URL` (rol de app, sujeto a RLS: es **lo que se prueba**) y `TEST_DATABASE_ADMIN_URL` (migrador: **solo** sembrar y limpiar; nunca para ejercer aislamiento ni queries del repo).
- `globalSetup` aplica migraciones una vez y crea el rol de app; un spec no migra ni crea roles en su `beforeAll`.
- `fileParallelism: false`: dos archivos contra la misma base se pisan filas y dan rojos falsos. Ante un rojo en DB, repetir con la máquina libre antes de buscar en el código.
- Cada spec siembra sus tenants/fixtures con ids propios y limpia en `afterAll` (borrar el tenant contenedor con `ON DELETE CASCADE` se lleva lo demás). Queries cross-tenant por diseño (funciones de barrido) asertan filtrando por los ids sembrados: en CI conviven filas de otros specs.
- Obligatorio por repo nuevo con tenant: cross-tenant lectura (A escribe, B lee `null`) y escritura (B no inserta como A); SQL de smoke y de arquitectura en `multi-tenancy-rls` §8.

```ts
const tenantA = ids.next(), tenantB = ids.next();
beforeAll(async () => { admin = adminDb(); app = appDb(); await seedTenants(admin, tenantA, tenantB); });
afterAll(async () => { await cleanupTenants(admin, tenantA, tenantB); await admin.end(); await app.end(); });
```

## 7. e2e de API (nivel 4)

Supertest contra la app Nest real (`Test.createTestingModule({ imports: [AppModule] })` + el mismo `createApp()` que usa `main.ts` para pipes, filtros y helmet) sobre Postgres real. Solo flujos críticos: login/refresh, un command principal por contexto, un endpoint público con rate limit, webhook con firma inválida → 401. Para endpoints con tenant: token de A no ve datos de B (404). Nunca e2e para cubrir lógica que un unit cubre; nunca contra staging ni producción.

```ts
it('returns 404 for an order that belongs to another tenant', async () => {
  await request(app.getHttpServer()).get(`/orders/${orderOfTenantA}`).set('Authorization', `Bearer ${tokenOfTenantB}`).expect(404);
});
```

## 8. Datos sintéticos, siempre

Fixtures con builders (`orderFixture(overrides)`) y valores inventados con forma válida: `+10000000001`, `customer-001@example.test`, `Customer 001`, documentos con dígito verificador calculado sobre secuencias. Nunca exportes de producción, planillas reales, nombres o teléfonos de personas, ni "un caso real anonimizado a mano". **Cómo se verifica:** el hook de PII del plugin sobre `**/*.spec.ts`, `**/fixtures/**`, `docs/sdd/**`; `grep -rnE "\+[1-9][0-9]{7,14}|@(gmail|hotmail|outlook)\." apps packages --include='*.spec.ts' --include='*.json'` vacío.

## 9. Tests que nunca se escriben

| Test | Por qué |
|---|---|
| Getters/setters triviales, `toBeDefined()` de un constructor | Cobertura sin comportamiento |
| `expect(mock).toHaveBeenCalled()` sin argumentos | No prueba qué se hizo; usar `toHaveBeenCalledWith(expect.objectContaining(...))` o un espía inspeccionable |
| `await sleep(100)` / `setTimeout` para "esperar" | Flaky; usar `await` del resultado o fake timers en adapters |
| Dependiente del orden o de estado de otro test | Rojo aleatorio con `--shuffle`; cada test siembra lo suyo |
| Mock de lo que se está probando | Verde vacío |
| `vi.mock` de Drizzle, pino, pg-boss, fetch global | Nivel equivocado: va a integración |
| Contra producción o staging (`DATABASE_URL` real) | Prohibido: ver `security-baseline` |
| Snapshot de HTML/JSON grande "para detectar cambios" | Se regenera sin mirar; asertar campos concretos |
| `it.skip`/`it.todo` para llegar a verde | Prohibido en `strict-tdd` |

## 10. Tests obligatorios por PR

- [ ] Aggregate/VO nuevo o modificado: un caso válido y cada inválido con su `code`; cada método de comando: estado + `pullEvents()`; `rehydrate` no emite.
- [ ] Handler nuevo: happy path + cada error path (`code`) con fakes; evento correcto en el outbox espía.
- [ ] Repo/adapter nuevo: `*.integration.spec.ts` guardar/leer con el rol de app; cross-tenant lectura y escritura si hay tenant.
- [ ] Guard/pipe nuevo: unit con DI manual: 401 sin token, 403 sin membresía o rol, 400 con tenant en body, camino feliz.
- [ ] Endpoint crítico nuevo: un e2e supertest (incluido 404 cross-tenant si aplica).
- [ ] Firma que debe ser imposible: test de tipos.
- [ ] Cobertura por capa no baja (`--coverage` en CI).

## 11. Checklist al escribir un test

- [ ] ¿Nivel correcto por capa (§1) y sufijo correcto (`.spec` / `.integration.spec` / `.e2e-spec`)?
- [ ] ¿`pnpm test` sigue sin necesitar Docker?
- [ ] ¿Dobles = fakes de puertos + `TimeProvider`/`IdGenerator` fijos; ningún mock de librería?
- [ ] ¿Aserta `code`, estado y eventos exactos, no `isErr`/`toHaveBeenCalled` a secas?
- [ ] ¿Nombre en inglés que describe la regla de negocio?
- [ ] ¿Integración con rol de app, admin solo para sembrar, limpieza en `afterAll`, aserciones filtradas por ids sembrados?
- [ ] ¿Datos sintéticos; sin secretos, PII ni URLs de entornos reales?
- [ ] ¿Ninguno de los tests de §9?
