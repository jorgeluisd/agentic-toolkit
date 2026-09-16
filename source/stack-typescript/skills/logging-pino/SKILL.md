---
name: logging-pino
description: "Logging con pino y nestjs-pino: redact por path, niveles por entorno, objeto primero y mensaje {context}.{action}.{outcome}, campo err, traceId propagado a jobs, catálogo de eventos críticos, test anti-fuga de PII y auditoría aparte. Usar cuando se configura el logger o se agrega un log."
---

# Logging con pino

Los logs son código de producción: JSON, filtrables por `traceId`, agrupables por mensaje. Un log que no cumple la forma de §3 no entra; un log con PII es un incidente.

## 1. Configuración (`nestjs-pino`)

```ts
// logger.config.ts — se reutiliza en la API, el worker y el test de §7
export const loggerOptions: Options = {
  level: env.LOG_LEVEL,
  transport: env.NODE_ENV === 'development' ? { target: 'pino-pretty' } : undefined,   // JSON en todo lo demás
  redact: {
    paths: [
      'req.headers.authorization', 'req.headers.cookie', 'req.headers["x-api-key"]', 'req.headers["x-signature"]', 'res.headers["set-cookie"]',
      '*.password', '*.token', '*.secret', '*.authorization', '*.refreshToken', '*.apiKey',
      '*.phone', '*.email', '*.document', '*.address', '*.fullName',
      '*.*.phone', '*.*.email', '*.*.document',          // `*` cubre un solo nivel; el segundo nivel se declara aparte
    ],
    censor: '[REDACTED]',
  },
  serializers: { req: (r) => ({ id: r.id, method: r.method, url: r.url }), res: (r) => ({ statusCode: r.statusCode }), err: pino.stdSerializers.err },
};
LoggerModule.forRoot({
  pinoHttp: {
    ...loggerOptions,
    genReqId: (req) => (req.headers['x-request-id'] as string | undefined) ?? randomUUID(),
    customProps: (req) => ({ traceId: req.id, tenantId: req.tenant?.tenantId, userId: req.user?.id }),
    autoLogging: { ignore: (req) => req.url === '/health' },
  },
});
```

Nuevo campo sensible en el sistema (nuevo VO, nueva columna) = nuevo path en `redact.paths` en el mismo PR. Objetos más profundos que dos niveles no se loguean: se loguean **ids** (§6). **Cómo se verifica:** el test de §7 corre en `pnpm test` con la config real importada, no con una copia.

## 2. Niveles por entorno

| Entorno | `LOG_LEVEL` | Salida | Nota |
|---|---|---|---|
| development | `debug` | `pino-pretty` | `trace` solo local y a mano |
| test | `silent` | — | Los tests de logging inyectan su propio destino |
| staging | `info` | JSON | `debug` temporal por env var |
| production | `info` | JSON | Nunca por debajo de `info`; subir a `debug` por env var sin redeploy, con fecha de vuelta |

| Nivel | Cuándo |
|---|---|
| `debug` | Decisión interna no crítica (cache hit, rama tomada) |
| `info` | Hito de negocio: `orders.order.placed`, `payment.capture.succeeded` |
| `warn` | Inusual y recuperable: reintento, fallback, rate limit, error esperado de negocio (`code`) |
| `error` | Fallo de operación, 5xx, excepción no esperada, evento de seguridad |
| `fatal` | El proceso no puede seguir (env inválido, sin DB al arrancar) → `process.exit(1)` |

## 3. Forma del log

```ts
this.logger.setContext(PlaceOrderHandler.name);
this.logger.info({ orderId, tenantId: ctx.tenantId }, 'orders.order.placed');                 // objeto primero, mensaje corto después
this.logger.warn({ orderId, code: result.error.code }, 'orders.order.place_failed');          // error esperado: warn + code, sin stack
this.logger.error({ err, orderId, provider: 'payments' }, 'payment.capture.failed');          // el campo se llama exactamente `err`
```

- Mensaje = `{context}.{action}.{outcome}` en snake_case (`auth.login.failed`, `webhook.payments.signature_invalid`, `job.notify_placed.retried`). Es un contrato con dashboards y alertas: no se renombra sin cambiar la alerta.
- **Sin interpolación en el mensaje**: `\`Order ${id} placed\`` rompe el agrupado y salta el redact (§7). Los datos van en el objeto.
- Excepciones: campo `err` (el serializer estándar extrae `type`, `message`, `stack`); errores esperados (`Result` con `code`) van en `warn` con `code`, sin stack.
- Un log por outcome, no uno por línea de código. Repos casi silenciosos (solo errores de DB que no son "no encontrado"); nunca un log por `SELECT`.

**Cómo se verifica:** `grep -rnE "logger\.(trace|debug|info|warn|error|fatal)\(\s*['\`\"]" apps/api/src` vacío (mensaje en primer argumento); `grep -rnE "logger\.(trace|debug|info|warn|error|fatal)\([^)]*\\$\{" apps/api/src` vacío (template literal en un log).

## 4. `traceId`: por request y propagado

| Tramo | Cómo viaja |
|---|---|
| HTTP entrante | `genReqId`: `x-request-id` del proxy o UUID nuevo; `customProps` lo pone en cada log del request |
| Handlers | `ctx.traceId` dentro de `TenantContext`; el logger request-scoped ya lo incluye |
| Jobs (pg-boss) | Manual: `traceId` en el payload al encolar; el worker crea `logger.child({ traceId, jobId, tenantId })` |
| Llamadas salientes | Header `x-trace-id: ctx.traceId` en `safeFetch`; la respuesta se loguea con `status` y duración, sin body |
| Eventos de dominio / outbox | `traceId` en los metadatos del evento; el consumidor lo hereda |
| Respuesta HTTP | Header `x-request-id` para que el cliente lo reporte |

```ts
await this.boss.send('orders.notify_placed', { orderId, tenantId: ctx.tenantId, traceId: ctx.traceId }, { retryLimit: 5, retryBackoff: true });
this.boss.work('orders.notify_placed', async ([job]) => {
  const log = this.base.child({ traceId: job.data.traceId, jobId: job.id, tenantId: job.data.tenantId });
  log.info({ orderId: job.data.orderId }, 'job.notify_placed.started');
});
```

**Cómo se verifica:** test del worker: el job encolado con `traceId: 't-1'` produce líneas con `traceId === 't-1'`.

## 5. Catálogo de eventos críticos

| Evento (mensaje) | Nivel | Campos | Alerta |
|---|---|---|---|
| `auth.login.failed` | `warn` | `reason`, `ip`, `userId?` (nunca email) | ≥ N por IP en ventana |
| `auth.token.invalid` | `warn` | `reason` (`expired`, `signature`, `audience`) | Pico sostenido |
| `webhook.<provider>.signature_invalid` | `error` | `provider`, `ip` | Cada ocurrencia |
| `security.cross_tenant_denied` | `error` | `userId`, `requestedTenantId`, `resource` | Cada ocurrencia |
| `security.tenant_in_body` | `warn` | `route`, `userId?` | Cada ocurrencia (cliente roto o ataque) |
| `rate_limit.hit` | `warn` | `route`, `ip`, `userId?` | Umbral por ruta |
| `outbound.host_denied` | `error` | `host` | Cada ocurrencia |
| `pii.exported` | `info` | `actorId`, `tenantId`, `rowCount`, `filterHash` | Siempre a auditoría (§8) |
| `job.<name>.failed` | `error` | `jobId`, `attempt`, `err` | Tras el último reintento |
| `env.invalid` | `fatal` | `fields` (nombres, no valores) | Arranque |

Cada evento del catálogo tiene un test que aserta que se emitió con ese mensaje y nivel (es parte del contrato de seguridad, ver `security-baseline`).

## 6. Qué nunca se loguea

- Contraseñas, tokens, JWT, cookies, firmas, claves de API: ni en `debug`, ni "para ver qué llega".
- Bodies completos de requests o webhooks; respuestas completas de terceros (traen PII del proveedor).
- Entidades completas (`{ order }`, `{ customer }`): solo **ids** y códigos; el detalle se busca en la base con el `traceId`.
- Teléfonos, emails, documentos, nombres, direcciones, coordenadas crudas, contenido clínico o financiero.
- SQL con valores; stack traces de errores esperados.
- Cualquier dato personal **dentro del mensaje** (§7).

## 7. El redact por path no protege strings interpolados

`fast-redact` reemplaza **propiedades por ruta** (`*.phone`). Un dato dentro de un string (`message` de un error, un template literal, un `JSON.stringify` previo) no tiene ruta y sale en claro. Regla: la PII solo existe en el log como propiedad con un nombre del `redact.paths`; nunca dentro de `msg`, ni en `err.message`, ni serializada a mano. Los `message` internos de los errores llevan ids, no datos (`errors-and-result`).

```ts
// logger.redact.spec.ts — corre en pnpm test con la config real
it('redacts PII by path and fails on interpolated PII', () => {
  const lines: string[] = [];
  const logger = pino({ ...loggerOptions, level: 'info' }, { write: (line: string) => lines.push(line) });
  const phone = '+10000000001', email = 'customer-001@example.test';
  logger.info({ customer: { phone, email }, order: { contact: { phone } } }, 'orders.order.placed');
  expect(lines[0]).not.toContain(phone); expect(lines[0]).not.toContain(email); expect(lines[0]).toContain('[REDACTED]');
  logger.info({ orderId: 'o-1' }, `order placed for ${phone}`);      // demostración: esto sale en claro
  expect(lines[1]).toContain(phone);                                   // por eso la regla; el grep de §3 lo bloquea en CI
});
```

Complemento por handler que loguea datos de un aggregate: test que construye el aggregate con `phone`/`email` sintéticos, ejecuta el handler con un destino en memoria y aserta que ninguna línea contiene esos valores.

## 8. Auditoría vs log

| | Log (pino) | Auditoría |
|---|---|---|
| Propósito | Diagnóstico y alertas | Evidencia de quién hizo qué, exigible |
| Almacén | stdout → agregador; retención corta | Tabla append-only por trigger (o outbox → tabla), retención ≥ la del dato |
| Contenido | ids, `code`, duración, `traceId` | `actorId`, `tenantId`, acción, ids del recurso, resultado, `traceId`; nunca contenido del dato |
| Garantía | Best effort (puede perderse) | Misma transacción que la operación |
| Consulta | Por `traceId`, por mensaje | Por actor, recurso, rango de fechas |
| Ejemplos | `orders.order.placed`, `job.x.failed` | acceso a dato de clase alta, export, cambio de rol, break-glass |

Un evento que necesita auditoría se escribe en la tabla **y** se loguea con el mensaje del catálogo; el log no sustituye la auditoría.

## 9. Errores comunes → arreglo

| Síntoma | Causa | Arreglo |
|---|---|---|
| Log sin campos, mensaje con datos | `logger.info('msg', obj)`: pino espera `(obj, 'msg')` | Invertir; el grep de §3 lo caza |
| Un teléfono aparece en el agregador | Interpolado en `msg` o en `err.message`; path no cubierto | Mover a propiedad con path redactado; agregar path; test §7 |
| Stack de `EntityNotFoundError` en `error` | Error esperado logueado como excepción | `warn` + `code` |
| Logs de un job sin `traceId` | No se puso en el payload | `traceId` al encolar + `child()` en el worker |
| No se sabe qué clase logueó | Falta `setContext` | `setContext(ClassName.name)` en el constructor |
| Dashboard roto tras un refactor / logs vacíos en tests | Mensaje del catálogo renombrado / `LOG_LEVEL=silent` | Actualizar la alerta en el mismo PR / destino en memoria como en §7 |

## 10. Checklist antes de agregar un log

- [ ] ¿Objeto primero, mensaje `{context}.{action}.{outcome}` sin interpolación?
- [ ] ¿Nivel correcto (esperado → `warn` + `code`; inesperado → `error` + `err`)?
- [ ] ¿Solo ids y códigos; ningún objeto completo ni dato personal, ni dentro de un string?
- [ ] ¿Campo sensible nuevo → path en `redact.paths` y test de §7 actualizado?
- [ ] ¿`traceId` presente (request, job con `child`, saliente con header)?
- [ ] Si es seguridad: ¿mensaje del catálogo de §5 con test de emisión? Si es auditable: ¿fila en la tabla de auditoría además del log?
