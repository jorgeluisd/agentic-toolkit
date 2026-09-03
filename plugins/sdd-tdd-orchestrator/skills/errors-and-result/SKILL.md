---
name: errors-and-result
description: "Familias DomainError/ApplicationError/InfrastructureError con code y httpStatus, publicMessage sin PII, Result<T,E> en domain/application, unwrapOrThrow en presentation y caza del Result descartado. Usar cuando se crea un error, se elige un status HTTP o se desempaca un Result."
---

# Errores y Result

El error de negocio es un **valor de retorno**, no una excepción. `domain` y `application` devuelven `Result<T, E>`; `infrastructure` lanza tipado; `presentation` desempaca en el borde.

## 1. Las tres familias

`BaseError` (abstracta) → `DomainError` (una regla de negocio se violó) · `ApplicationError` (la orquestación no puede continuar: autorización, no encontrado, conflicto) · `InfrastructureError` (un sistema de afuera falló: DB, cola, API externa; `httpStatus` 500 por defecto). La familia dice la naturaleza del fallo, no el status.

| Campo | Tipo | Regla |
|---|---|---|
| `code` | `string` | SCREAMING_SNAKE, estable, **uno por clase**; es el contrato con el frontend. Ocho clases compartiendo `ENTITY_NOT_FOUND` son indistinguibles |
| `httpStatus` | `number` | Explícito por clase; nunca derivado de `instanceof` ni de una tabla mágica (mover un error de familia no debe cambiar su status) |
| `message` | `string` | Interno, va al log: ids, estados, respuesta cruda de un tercero. **Nunca PII interpolada** (el `redact` de pino filtra por path, no dentro de un string) |
| `publicMessage` | `string` | Va al body de la respuesta: sin PII, sin ids internos, sin jerga técnica, en el idioma del producto (dialecto según el CLAUDE.md del proyecto). Default genérico por familia: olvidar el copy da un mensaje pobre, nunca una fuga |
| `details` | `object?` | Contexto interno; **nunca se serializa** |
| `publicDetails` | `object?` | Opt-in explícito de lo que la UI necesita (intentos restantes, opciones disponibles) |

```ts
export abstract class BaseError extends Error {
  abstract readonly code: string;
  abstract readonly httpStatus: number;
  readonly publicMessage: string;
  readonly details?: Readonly<Record<string, unknown>>;
  readonly publicDetails?: Readonly<Record<string, string | number | boolean | string[]>>;
  constructor(message: string, opts: { details?: Record<string, unknown>; publicMessage?: string; publicDetails?: BaseError['publicDetails'] } = {}) {
    super(message); this.publicMessage = opts.publicMessage ?? 'La operación no pudo completarse.'; this.details = opts.details; this.publicDetails = opts.publicDetails;
  }
}
export abstract class DomainError extends BaseError {}
export abstract class ApplicationError extends BaseError {}
export abstract class InfrastructureError extends BaseError { readonly httpStatus: number = 500; }
export abstract class ConflictError extends ApplicationError { readonly httpStatus: number = 409; }

// Copy fijo: redeclarar el campo en la subclase (gana sobre el default de la base).
export class OrderAlreadyCancelledError extends DomainError {
  readonly code = 'ORDER_ALREADY_CANCELLED';
  readonly httpStatus = 422;
  readonly publicMessage = 'El pedido ya estaba cancelado.';
  constructor(orderId: string) { super(`Order ${orderId} is already cancelled`, { details: { orderId } }); }
}
```

Bases concretas en `shared-kernel` con `httpStatus` fijo: `InvalidValueError` (400), `AuthorizationError` (403), `EntityNotFoundError` (404), `ConflictError` (409), `InvariantViolationError` (422). Cada contexto deriva clases con su `code`.

## 2. `Result<T, E>`

Unión discriminada en `shared-kernel`, funciones libres, objetos planos (serializan, se comparan con `toEqual`). Nada de `neverthrow`/`fp-ts` (bloqueados por `boundaries/external`).

```ts
export type Ok<T> = { readonly ok: true; readonly value: T };
export type Err<E> = { readonly ok: false; readonly error: E };
export type Result<T, E> = Ok<T> | Err<E>;
export const ok = <T>(value: T): Ok<T> => ({ ok: true, value });
export const err = <E>(error: E): Err<E> => ({ ok: false, error });
export const isOk = <T, E>(r: Result<T, E>): r is Ok<T> => r.ok;
export const isErr = <T, E>(r: Result<T, E>): r is Err<E> => !r.ok;
export const map = <T, U, E>(r: Result<T, E>, f: (v: T) => U): Result<U, E> => (r.ok ? ok(f(r.value)) : r);
export const flatMap = <T, U, E>(r: Result<T, E>, f: (v: T) => Result<U, E>): Result<U, E> => (r.ok ? f(r.value) : r);
export const mapErr = <T, E, F>(r: Result<T, E>, f: (e: E) => F): Result<T, F> => (r.ok ? r : err(f(r.error)));
export const unwrapOr = <T, E>(r: Result<T, E>, fallback: T): T => (r.ok ? r.value : fallback);
export function all<T, E>(results: readonly Result<T, E>[]): Result<T[], E> {
  const values: T[] = [];
  for (const r of results) { if (!r.ok) return r; values.push(r.value); }
  return ok(values);
}
```

Propagar es una línea y conserva el tipo: `const cancelled = order.cancel(now); if (isErr(cancelled)) return cancelled;`. Aserta `code` en tests, no solo `isErr`.

## 3. Dónde Result y dónde throw

| Capa | Mecanismo |
|---|---|
| domain | `Result`. `throw new InvariantViolationError(...)` solo para estado imposible (bug), marcado `// invariant: impossible` |
| application | `Result`; compone con `isErr`/`flatMap`/`all`. Nunca `unwrapOrThrow` |
| infrastructure | `throw` tipado (`InfrastructureError` y subclases); el filtro lo convierte en 500 |
| presentation | `unwrapOrThrow(result)` y nada más |

Una Query que no puede fallar no se envuelve: `ListOrdersQuery` devuelve el read model pelado; `GetOrderDetailQuery` devuelve `Result` porque puede dar 404.

## 4. El borde HTTP

```ts
// presentation/http/unwrap-result.ts
export function unwrapOrThrow<T, E extends BaseError>(r: Result<T, E>): T {
  if (r.ok) return r.value;
  throw r.error;   // tal cual: sin envolver ni traducir; el filtro ya sabe leerlo
}

@Catch()
export class DomainExceptionFilter implements ExceptionFilter {
  constructor(@InjectPinoLogger() private readonly logger: PinoLogger) {}
  catch(exception: unknown, host: ArgumentsHost) {
    const res = host.switchToHttp().getResponse();
    if (exception instanceof BaseError) {
      this.logger.warn({ err: exception, code: exception.code }, 'http.request.rejected');   // message interno al log
      return res.status(exception.httpStatus).json({ code: exception.code, message: exception.publicMessage, details: exception.publicDetails });
    }
    if (exception instanceof HttpException) return res.status(exception.getStatus()).json(exception.getResponse());
    this.logger.error({ err: exception }, 'http.request.failed');
    return res.status(500).json({ code: 'INTERNAL_ERROR', message: 'Ocurrió un error inesperado.' });
  }
}
```

Se loguea `message`; se serializa `publicMessage` + `publicDetails`. Envolver el error en el controller duplica el mapeo por endpoint y suele terminar en 500 genérico.

## 5. Mapeo a HTTP

| Situación | Status | Nota |
|---|---|---|
| Body inválido (class-validator / zod `.strict()`) | 400 | `VALIDATION_FAILED` + `publicDetails.issues` sin valores del body |
| Sin sesión / token inválido | 401 | |
| Tenant sin membresía | 403 | Único uso de 403 |
| Recurso de otro tenant o inexistente | 404 | Nunca 403: confirma existencia |
| Estado conflictivo (duplicado, versión) | 409 | |
| Regla de negocio violada | 422 | Nunca 500 |
| Infraestructura | 500 | `publicMessage` genérico |

## 6. El `Result` descartado

TypeScript no obliga a usar un valor de retorno: `order.cancel(now);` compila y tira el error. Consecuencias típicas: un PATCH responde 204 con el aggregate intacto; un gate de verificación se salta; un `try/catch` deja de dispararse. Dónde se esconde y cómo se caza:

1. **`bus.execute<Cmd, void>`**: el tipo del bus se escribe a mano. `grep -rn 'execute<' apps/api/src --include=*.ts` y revisar el segundo parámetro contra el retorno real del handler.
2. **Métodos del aggregate** que pasaron de `void` a `Result`: `grep -rn '\.\(cancel\|confirm\|apply\)(' ` sobre los nombres del método y confirmar que cada llamada lee `ok`.
3. **`@Get` sin `unwrapOrThrow`**: responde `{ ok: true, value: {...} }` en vez del read model.
4. Lint (`pnpm lint`): `@typescript-eslint/no-floating-promises` (handlers async) + `@typescript-eslint/no-unused-expressions` (llamada síncrona cuyo valor se descarta). Lo que el lint no ve lo revisa el verifier con los greps de arriba.
5. Mocks: un spec con el bus mockeado devolviendo `undefined` sigue verde con el llamador roto. Los dobles hablan el contrato real (`ok(...)`/`err(...)`); en el camino feliz se aserta `isOk`, no solo el efecto lateral.

## 7. Copy público sin PII

- Sin teléfono, correo, documento, nombre, token ni id interno; sin inglés técnico; sin sustantivo de país: el frontend sobreescribe por `code` con su locale, el backend no localiza.
- Uniforme ante enumeración: "credenciales inválidas" tanto para usuario inexistente como para clave incorrecta; recurso ajeno responde igual que inexistente.

## 8. Test de enforcement

```ts
// apps/api/src/architecture/result-enforcement.spec.ts
import { readFileSync } from 'node:fs'; import fg from 'fast-glob';
const ALLOWLIST = ['src/shared-kernel/errors/invariant-violation.error.ts'];
const MARKER = '// invariant: impossible';
describe('domain/application return Result instead of throwing', () => {
  const files = fg.sync('src/contexts/*/{domain,application}/**/*.ts', { ignore: ['**/*.spec.ts', ...ALLOWLIST] });
  it.each(files)('%s has no throw new', (file) => {
    const offenders = readFileSync(file, 'utf8').split('\n').map((line, i) => ({ line, n: i + 1 }))
      .filter(({ line }) => /\bthrow new\b/.test(line) && !line.includes(MARKER));
    expect(offenders, offenders.map((o) => `${file}:${o.n}`).join('\n')).toEqual([]);
  });
});
```

**Cómo se verifica:** `pnpm vitest run apps/api/src/architecture/result-enforcement.spec.ts` (parte de `pnpm test`; gate de CI).

## 9. Checklist al crear un error

- [ ] ¿Familia correcta (regla de negocio / orquestación / sistema externo)?
- [ ] ¿`code` propio en SCREAMING_SNAKE y `httpStatus` explícito y semánticamente correcto (§5)?
- [ ] ¿`message` con lo necesario para diagnosticar y sin PII; `publicMessage` sin PII ni ids?
- [ ] ¿Lo que la UI necesita está en `publicDetails`, no en `details`?
- [ ] ¿Devuelto con `err(...)` en domain/application; `throw` solo con `// invariant: impossible`?
- [ ] ¿Cada llamador consume el `Result` (bus, métodos del aggregate, `@Get` con `unwrapOrThrow`)?
- [ ] ¿Los tests asertan el `code`, no solo `isErr`; los dobles devuelven `ok`/`err` reales?
- [ ] ¿`result-enforcement.spec.ts` y `pnpm lint` verdes?
