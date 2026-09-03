---
name: application-cqrs-jobs
description: "Commands/Queries con { input } único y tenant en ctx, handlers, puertos + Symbol, eventos con outbox, jobs pg-boss idempotentes por tenant, controllers finos con zod strict y mappers. Usar cuando se escribe un handler, use case, evento, job, controller o mapper."
---

# Application: CQRS, use cases, eventos y jobs

`application/` orquesta: no conoce HTTP ni SQL. Importa `domain` y `shared-kernel`; define puertos que `infrastructure` implementa.

## 1. Las 3 reglas inviolables

1. **Command** modifica estado y devuelve `Result<void | { id: string }, DomainError>`. Nunca un read model ni un aggregate.
2. **Query** lee y devuelve un **read model** (interface plana, transport-agnostic), o `Result<ReadModel, EntityNotFoundError>` solo si la lectura puede fallar (un detalle sí; un listado que como mucho viene vacío, no). Nunca muta ni carga aggregates.
3. **Inter-contexto = eventos** (o Command/Query por bus con plain data), nunca imports directos.

Command y Query se construyen con **un único objeto** tipado, nunca argumentos posicionales (cuatro `string` seguidos se invierten sin que el compilador lo note). El tenant llega en `ctx: TenantContext` (poblado por presentation desde auth); `input` **nunca** lleva campo de tenant.

```ts
export interface PlaceOrderInput { customerId: string; lines: { productId: string; quantity: number }[] }
export class PlaceOrderCommand implements ICommand {
  constructor(readonly props: { ctx: TenantContext; input: PlaceOrderInput }) {}
}
export interface OrderDetailReadModel { id: string; status: string; totalAmount: number; currency: string; lines: { productId: string; quantity: number }[] }
export class GetOrderDetailQuery implements IQuery {
  constructor(readonly props: { ctx: TenantContext; input: { orderId: string } }) {}
}
```

**Excepción acotada al retorno** (las dos condiciones a la vez, documentadas en el handler): el dato se produce durante la escritura **y** no puede recuperarse después con una Query (secreto de un solo uso, o dato atómicamente necesario para el paso siguiente del mismo flujo). Si se puede leer con una Query, va por Query.

## 2. Handler: secuencia canónica

1. Autorización de rol (`ctx.roles`) → 2. abrir contexto de tenant → 3. cargar aggregates → 4. construir todos los VO (cortar en el primer `err`) → 5. invariantes (`create`/método de comando) → 6. `save` → 7. eventos a outbox en la misma transacción → 8. `{ id }`.

```ts
@CommandHandler(PlaceOrderCommand)
export class PlaceOrderHandler implements ICommandHandler<PlaceOrderCommand, Result<{ id: string }, DomainError>> {
  constructor(
    @Inject(ORDER_REPOSITORY) private readonly orders: OrderRepository,
    @Inject(TIME_PROVIDER) private readonly time: TimeProvider,
    @Inject(ID_GENERATOR) private readonly ids: IdGenerator,
    @Inject(OUTBOX) private readonly outbox: Outbox,
    private readonly tenant: TenantContextRunner, private readonly config: OrdersConfig,
  ) {}
  async execute({ props: { ctx, input } }: PlaceOrderCommand): Promise<Result<{ id: string }, DomainError>> {
    return this.tenant.run(ctx.tenantId, async (tx) => {
      const lines = all(input.lines.map((l) => OrderLine.create(l.productId, l.quantity)));
      if (isErr(lines)) return lines;
      const id = OrderId.rehydrate(this.ids.next());   // generado por la app; no re-validar
      const created = Order.create({ id, tenantId: ctx.tenantId, lines: lines.value, now: this.time.now(), maxLines: this.config.maxLinesPerOrder });
      if (isErr(created)) return created;
      await this.orders.save(created.value, tx);
      await this.outbox.append(created.value.pullEvents(), { tx, traceId: ctx.traceId });
      return ok({ id: id.value });
    });
  }
}
```

Un handler **no**: devuelve el aggregate ni un read model completo; hace `findById` tras `save`; llama servicios externos de forma síncrona (va por evento + job); cruza tenants sin `TenantContextRunner`. La Query lee con JOIN dentro del contexto de tenant y arma el read model; no carga aggregates ni muta (`last_viewed_at` es un Command).

## 3. Puertos, registro en el módulo y use case sin bus

```ts
// application/ports/notification.port.ts
export interface NotificationPort { send(msg: { tenantId: string; to: string; template: string; traceId: string }): Promise<void> }
export const NOTIFICATION_PORT = Symbol('NotificationPort');
// orders.module.ts — @nestjs/cqrs descubre handlers por decorador; los puertos se ligan por Symbol
@Module({ imports: [CqrsModule], controllers: [OrdersController],
  providers: [PlaceOrderHandler, GetOrderDetailHandler, EnqueueOrderConfirmation,
    { provide: ORDER_REPOSITORY, useClass: OrderDrizzleRepository }, { provide: NOTIFICATION_PORT, useClass: EmailNotificationAdapter }] })
export class OrdersModule {}
```

`@nestjs/cqrs` es el binding recomendado, no obligatorio. Sin bus, la forma canónica es una clase por caso de uso registrada como provider: `execute(ctx: TenantContext, input: PlaceOrderInput): Promise<Result<...>>`, tenant siempre en el **primer** parámetro, misma secuencia de §2. Las reglas de §1, §4 y §5 aplican igual.

## 4. Eventos: naming, outbox, bus

Clase PascalCase en pasado con `static readonly eventName = 'orders.order.placed'` (`{context}.{aggregate}.{verbo_pasado}`). Prohibido: `OrderCreatedEvent` sin contexto en `eventName`, `order_create` (presente), `PlaceOrderEvent` (parece command).

| Mecanismo | Cuándo | Garantía |
|---|---|---|
| **Outbox** (tabla del contexto emisor, misma transacción del aggregate; relay en el worker; dedupe por `eventId`) | El consumidor está fuera del proceso, o la reacción no puede perderse (facturar, notificar, proyectar) | at-least-once; consumidores idempotentes |
| **Bus in-memory** (`EventBus` de `@nestjs/cqrs`) | Reacción en el mismo proceso sin garantía requerida (invalidar cache, métrica) | ninguna: se pierde si el proceso cae |

Publicar fuera de la transacción del aggregate = evento perdido. Un event handler importa **solo el evento** (plain data) del otro contexto.

## 5. Event handlers que encolan jobs (pg-boss)

```ts
@EventsHandler(OrderPlaced)
export class EnqueueOrderConfirmation implements IEventHandler<OrderPlaced> {
  constructor(@Inject(JOB_QUEUE) private readonly jobs: JobQueue) {}
  async handle(e: OrderPlaced): Promise<void> {
    await this.jobs.send('orders.send-confirmation',
      { orderId: e.payload.orderId, tenantId: e.payload.tenantId, traceId: e.payload.traceId },
      { singletonKey: `orders.send-confirmation:${e.payload.orderId}`, retryLimit: 5, retryDelay: 5, retryBackoff: true });
  }
}
```

- El handler **encola**, no hace la llamada HTTP: el caso de uso no depende del uptime de terceros. Jobs idempotentes (`singletonKey` o dedupe por `eventId` en tabla); `tenantId` y `traceId` en el payload; reintentos con backoff exponencial.
- Worker aparte (`worker.ts` levanta solo módulos de jobs, sin HTTP); nunca cron in-process en la API (se duplica al escalar). Los schedules viven en la DB (`pgboss`), no en memoria.
- Barridos **por tenant**: el cron itera tenants y encola un job por tenant; nunca un job global que cruce tenants. **Sagas** (`@Saga()` + `ofType`) con moderación: son síncronas e in-memory; preferir event handler + job con reintentos.

## 6. Controllers finos

Regla de validación de borde: **en NestJS, class-validator + class-transformer** con `ValidationPipe` global `{ whitelist: true, forbidNonWhitelisted: true, transform: true, enableImplicitConversion: false }`. Fuera de NestJS (Server Actions de Next.js, Edge Functions, scripts) la validación es **zod `.strict()`** (ver `frontend-next-react`). No mezclar los dos en la misma capa.

```ts
class OrderLineDto {
  @IsUUID() productId!: string;
  @IsInt() @IsPositive() quantity!: number;
}
export class PlaceOrderDto {
  @IsUUID() customerId!: string;
  @ValidateNested({ each: true }) @Type(() => OrderLineDto) @ArrayMinSize(1) lines!: OrderLineDto[];
  // sin campo de tenant: forbidNonWhitelisted rechaza con 400 cualquier clave no declarada, tenantId incluido
}

@Post()
async place(@Body() dto: PlaceOrderDto, @CurrentTenant() ctx: TenantContext) {
  const result = await this.commandBus.execute<PlaceOrderCommand, Result<{ id: string }, DomainError>>(OrderRequestMapper.toPlaceCommand(dto, ctx));
  return unwrapOrThrow(result);
}
```

Validar → mapear → ejecutar → `unwrapOrThrow` → responder (201 con `{ id }`; GET 404 vía `EntityNotFoundError`). Sin lógica de negocio, sin `new Order(...)`, sin `try/catch` que traduzca errores (eso es del `DomainExceptionFilter`). El pipe global rechaza DTOs con campo de tenant.

## 7. Mappers: exactamente 3 fronteras

| # | Frontera | Ubicación | Métodos | Cuándo existe |
|---|---|---|---|---|
| 1 | presentation ↔ application | `presentation/http/mappers/order-request.mapper.ts` | `toPlaceCommand(dto, ctx)`, `toResponse(rm)` | Siempre para DTO→Command; `toResponse` solo si hay que aplanar/ocultar |
| 2 | application ↔ domain | inline en el handler; `application/mappers/` solo si el payload es complejo | `toDomain(input)` | No crear un archivo para envolver un `.create(string)` |
| 3 | infrastructure ↔ domain | `infrastructure/mappers/order.mapper.ts` | `toPersistence(aggregate)`, `toDomain(row, lineRows)` | Siempre; `toDomain` usa **`rehydrate`**, nunca `create` |

Clases con métodos estáticos puros, sin estado ni reglas de negocio. No existen mappers application↔application, domain↔domain, DTO→aggregate ni read-model→domain.

```ts
static toPlaceCommand(dto: PlaceOrderDto, ctx: TenantContext): PlaceOrderCommand {
  return new PlaceOrderCommand({ ctx, input: { customerId: dto.customerId, lines: dto.lines.map((l) => ({ productId: l.productId, quantity: l.quantity })) } });
}
```
Nunca `new PlaceOrderCommand({ tenantId, ...dto })`: el spread acopla el DTO al command y, si va después del tenant, un `tenantId` del body lo pisa. Lista los campos aunque sean veinte.

## 8. `packages/contracts`

- Tipos e interfaces de request/response compartidos web↔api (derivados de los DTOs de la API, sin decoradores ni dependencias de NestJS); única frontera web↔api. **No importa `domain`** ni `domain` importa `contracts`; `presentation` mapea entre ambos. Los schemas zod del web (formularios, Server Actions) se escriben contra estos tipos con `satisfies`.
- Valida forma y formato, no reglas de negocio ("no puede pedir si está bloqueado" vive en el aggregate).
- Catálogos duplicados a propósito (`OrderStatus` en contracts y en domain) con un **test de consistencia** que los compara.
- Cambiar la forma de un DTO es un cambio de frontera: expand (campo nuevo opcional) → migrar consumidores → contract (retirar el viejo).

## 9. Errores comunes → arreglo

| Síntoma | Arreglo |
|---|---|
| `constructor(tenantId: string, orderId: string)` posicional; `input.tenantId` | Un objeto `{ ctx, input }`; el tenant sale de `ctx` y el pipe global lo rechaza en el body |
| Handler devuelve el aggregate "fresco" | `{ id }`; el cliente hace GET |
| Query con `UPDATE` | Command separado |
| Handler de `billing` importa `Order` | Escucha `OrderPlaced` o consulta por `QueryBus` |
| `eventBus.publish` después de commit para algo que no puede perderse | Outbox en la misma transacción |
| Event handler hace `fetch` a un tercero | Encola job idempotente con backoff |
| `setInterval`/`@Cron` en la API | Schedule en pg-boss dentro del worker, un job por tenant |
| `bus.execute<Cmd, void>` con handler que devuelve `Result` | Tipar el retorno real y consumir el `Result` |

## 10. Checklist

- [ ] ¿Command devuelve `void`/`{ id }` (o excepción acotada documentada)? ¿Query devuelve read model plano?
- [ ] ¿Construcción con `{ ctx, input }`; `input` sin tenant?
- [ ] ¿Handler sigue la secuencia de §2, corta en el primer `err`, publica eventos en la misma transacción?
- [ ] ¿Puerto = interface + `Symbol`, cableado en `<context>.module.ts`?
- [ ] ¿`eventName` con `{context}.{aggregate}.{verbo_pasado}`; reacciones cross-context por evento?
- [ ] ¿Jobs idempotentes, con `tenantId` + `traceId`, backoff, en el worker, por tenant?
- [ ] ¿Controller: DTO class-validator (whitelist + forbidNonWhitelisted) → mapper → bus → `unwrapOrThrow`?
- [ ] ¿Mappers solo en las 3 fronteras; `toDomain` con `rehydrate`; sin spread tras el tenant?
- [ ] ¿Test del handler con fakes de puertos (repo en memoria, `TimeProvider` fijo, `IdGenerator` secuencial, outbox espía) que asertan `ok` y el `code` del error?
