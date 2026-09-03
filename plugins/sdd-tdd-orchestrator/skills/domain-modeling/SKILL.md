---
name: domain-modeling
description: "Aggregates, value objects y eventos en TypeScript puro: constructor privado + create() con Result, rehydrate(), Identifier<Brand>, Money entero, tiempo e ids inyectados, append-only con compensación. Usar cuando se escribe o revisa código bajo domain/."
---

# Domain modeling

El dominio es TypeScript puro: no conoce NestJS, Drizzle, HTTP, colas ni el reloj. Toda regla de negocio vive dentro del aggregate o de un value object, nunca en un controller, un repositorio ni una policy SQL.

## 1. Qué puede importar `domain/` (litmus)

Solo `shared-kernel` y su propio contexto. Pregunta: **"si mañana cambiamos NestJS por otro framework o Drizzle por otro ORM, ¿este archivo cambia?"** Si sí, no va en `domain/`.

Prohibido: `@nestjs/*`, `drizzle-orm`, `zod`, `pino`, `pg-boss`, `rxjs`, `node:*`, `neverthrow`/`fp-ts`, `async` en métodos del aggregate, `new Date()`, `Date.now()`, `Math.random()`, `randomUUID()`. **Cómo se verifica:** `pnpm lint` (`boundaries/external` + `no-restricted-syntax`, ver skill `onion-screaming-architecture`).

Lo que el dominio necesita del mundo entra como parámetro: `now: Date` (obtenido por `TimeProvider.now()` en application), ids generados por `IdGenerator` (UUID v7 recomendado; nunca `gen_random_uuid()` en DB como fuente de verdad), tunables desde config (`maxLinesPerOrder`, tasas, umbrales) nunca como constantes hardcodeadas.

```ts
// shared-kernel: interfaces puras; adapters SystemTimeProvider / Uuidv7IdGenerator en platform/ o infrastructure/
export interface TimeProvider { now(): Date }
export interface IdGenerator { next(): string }
export const TIME_PROVIDER = Symbol('TimeProvider'); export const ID_GENERATOR = Symbol('IdGenerator');
// tests: FixedTimeProvider(new Date('2026-01-01T00:00:00Z')), SequentialIdGenerator() → '00000000-0000-7000-8000-000000000001', ...
```

## 2. Value objects

Constructor privado; `create()` devuelve `Result<VO, DomainError>`; **un VO instanciado es siempre válido**; inmutable (`readonly`, las operaciones devuelven un VO nuevo); `rehydrate()` reconstruye desde persistencia sin re-validar reglas de creación; igualdad por valor con `equals()`.

```ts
export class Money {
  private constructor(readonly amount: number, readonly currency: CurrencyCode) {}

  static create(amount: number, currency: string): Result<Money, DomainError> {
    if (!Number.isSafeInteger(amount)) return err(new MoneyNotIntegerError(amount));
    if (amount < 0) return err(new MoneyNegativeError(amount));
    if (!isIso4217(currency)) return err(new CurrencyInvalidError(currency));
    return ok(new Money(amount, currency as CurrencyCode));
  }
  static rehydrate(amount: number, currency: CurrencyCode): Money { return new Money(amount, currency); }

  add(other: Money): Result<Money, DomainError> {
    if (other.currency !== this.currency) return err(new CurrencyMismatchError(this.currency, other.currency));
    return ok(new Money(this.amount + other.amount, this.currency));
  }
  equals(other: Money): boolean { return this.amount === other.amount && this.currency === other.currency; }
}
```

Money: entero en la unidad menor (centavos) + código ISO 4217. Nunca `number` decimal ni float; nunca operar entre monedas sin conversión explícita por tasa versionada (la tasa usada queda registrada); en DB columna `bigint` (`bigint({ mode: 'number' })` mientras el monto quepa en `Number.MAX_SAFE_INTEGER`). Un pago en dos monedas = dos registros.

## 3. Identificadores con brand

```ts
export abstract class Identifier<Brand extends string> {
  declare private readonly __brand: Brand;
  protected constructor(readonly value: string) {}
  equals(other: Identifier<Brand>): boolean { return this.value === other.value; }
}
export class OrderId extends Identifier<'OrderId'> {
  static create(value: string): Result<OrderId, DomainError> {
    return isUuid(value) ? ok(new OrderId(value)) : err(new OrderIdInvalidError(value));
  }
  static rehydrate(value: string): OrderId { return new OrderId(value); }
}
```

El compilador impide pasar un `CustomerId` donde va un `OrderId`. `TenantId` es la raíz de tenencia: todo aggregate con datos de tenant lo lleva como campo `readonly`.

## 4. Aggregates

- Constructor privado. `create()` valida invariantes de creación y **emite evento**; `rehydrate()` **no emite** y asume datos consistentes (es lo que usa `toDomain` del repositorio, nunca `create`).
- Métodos de comando devuelven `Result<void, DomainError>`, reciben `now` y tunables como parámetros, mutan estado privado y agregan eventos. **Sin setters públicos** (anemic domain = antipatrón).
- `pullEvents()` vacía y devuelve la lista; application publica después de `save`.
- Un aggregate = una transacción. Si una regla cruza dos aggregates o dos contextos, se modela con evento + consistencia eventual y la spec declara explícitamente qué es inmediato y qué es eventual.

```ts
export class Order {
  private readonly events: DomainEvent[] = [];
  private constructor(readonly id: OrderId, readonly tenantId: TenantId, private status: OrderStatus,
                      private readonly lines: OrderLine[], readonly placedAt: Date) {}

  static create(p: { id: OrderId; tenantId: TenantId; lines: OrderLine[]; now: Date; maxLines: number }): Result<Order, DomainError> {
    if (p.lines.length === 0) return err(new OrderEmptyError());
    if (p.lines.length > p.maxLines) return err(new OrderTooManyLinesError(p.maxLines));
    const order = new Order(p.id, p.tenantId, 'placed', p.lines, p.now);
    order.events.push(new OrderPlaced({ orderId: p.id.value, tenantId: p.tenantId.value, occurredAt: p.now }));
    return ok(order);
  }
  static rehydrate(s: OrderSnapshot): Order { return new Order(s.id, s.tenantId, s.status, s.lines, s.placedAt); }

  cancel(now: Date): Result<void, DomainError> {
    if (this.status === 'cancelled') return err(new OrderAlreadyCancelledError(this.id.value));
    this.status = 'cancelled';
    this.events.push(new OrderCancelled({ orderId: this.id.value, tenantId: this.tenantId.value, occurredAt: now }));
    return ok(undefined);
  }
  pullEvents(): DomainEvent[] { const out = [...this.events]; this.events.length = 0; return out; }
}
```

## 5. Entities, domain services, errores, eventos

- **Entity**: identidad dentro del aggregate (`OrderLine` con `OrderLineId`); no se persiste ni se carga sola.
- **Domain service**: lógica que no cabe en un aggregate (`PricingService.quote(lines, rates)`); clase con métodos puros, sin decoradores; se registra en el módulo con `useClass`.
- **Domain error**: subclase de `DomainError` con `code` propio en SCREAMING_SNAKE y `httpStatus` explícito; nunca `Error` genérico. `throw` solo para invariantes imposibles (estado corrupto = bug) → `InvariantViolationError`. Ver skill `errors-and-result`.
- **Evento**: clase PascalCase en pasado, inmutable, sin lógica, con `static readonly eventName = '{context}.{aggregate}.{verbo_pasado}'`; el payload lleva solo ids y primitivos (nunca el aggregate, nunca PII).

```ts
export class OrderPlaced implements DomainEvent {
  static readonly eventName = 'orders.order.placed';
  readonly eventName = OrderPlaced.eventName;
  constructor(readonly payload: { orderId: string; tenantId: string; occurredAt: Date }) {}
}
```

## 6. Registros auditables y proyecciones

- Registros financieros, clínicos o de auditoría son **append-only**: la corrección es un registro compensatorio (`Reversal`, `Adjustment`), nunca `UPDATE`/`DELETE` destructivo. Un `Payment` confirmado no se edita.
- Proyecciones deterministas: un saldo, una racha o un contador se recalculan desde los hechos; nunca un contador mutable como fuente de verdad.
- Revocar un permiso o cancelar no borra: cambia estado y emite evento.

## 7. Antipatrones

| Antipatrón | Por qué falla | Arreglo |
|---|---|---|
| Anemic domain (setters públicos, lógica en el handler) | Cualquiera rompe invariantes desde afuera | Métodos de comando con `Result`; estado privado |
| `price: number` decimal / float para dinero | `0.1 + 0.2 !== 0.3`; redondeo binario acumulado | `Money` entero en unidad menor + ISO 4217; DB `bigint` |
| `{ ...money, amount: 0 }` o `Object.assign` sobre un VO | Salta la validación; pierde el prototipo | Nuevo `Money.create(...)` |
| `throw` en flujo de negocio | El llamador no ve el error en el tipo | `err(new XError())`; `throw` solo invariante imposible |
| `new Date()` / `randomUUID()` en el aggregate | No determinista, no testeable | `now` e `id` como parámetros |
| `toDomain` con `create()` | Dispara "creado" en cada carga | `rehydrate()` |
| Aggregate que referencia otro por objeto | Transacción que cruza límites | Referencia por `Identifier`; coordinación por evento |
| Umbral/límite hardcodeado (`if (lines.length > 50)`) | Cambia sin deploy | Parámetro desde config |

## 8. Cómo se verifica

- `pnpm lint`: imports, builtins, reloj, azar e ids en `domain/`.
- `result-enforcement.spec.ts`: falla ante `throw new` en `domain/`/`application/` fuera de la lista blanca (skill `errors-and-result`).
- Tests unitarios puros (`*.spec.ts`, sin `TestingModule`, sin I/O): por cada invariante un caso válido **y cada caso inválido asertando su `code`**; por cada método de comando, el estado resultante y los eventos en `pullEvents()`; `rehydrate` no emite eventos. Comando: `pnpm vitest run apps/api/src/contexts/orders/domain`.

```ts
it('rejects an order without lines with ORDER_EMPTY', () => {
  const r = Order.create({ id, tenantId, lines: [], now: fixedNow, maxLines: 10 });
  expect(isErr(r) && r.error.code).toBe('ORDER_EMPTY');
});
```

## 9. Checklist

- [ ] ¿Cero imports fuera de `shared-kernel` y el propio contexto; cero reloj/azar/ids directos?
- [ ] ¿VO con constructor privado, `create()` → `Result`, `rehydrate()`, inmutable, `equals()`?
- [ ] ¿Ids con `Identifier<Brand>`; `TenantId` en cada aggregate con datos de tenant?
- [ ] ¿Aggregate: `create()` emite, `rehydrate()` no, `pullEvents()`, sin setters, métodos devuelven `Result`?
- [ ] ¿Money entero + ISO 4217; ninguna operación entre monedas distintas sin conversión explícita?
- [ ] ¿Un aggregate por transacción; cruces por evento y declarados como eventuales en la spec?
- [ ] ¿Registros auditables append-only con compensación; proyecciones recalculables?
- [ ] ¿Tunables como parámetros desde config?
- [ ] ¿Test por invariante (válido + cada inválido con `code`) y `pnpm lint` verde?
