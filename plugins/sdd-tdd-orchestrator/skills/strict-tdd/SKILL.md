---
name: strict-tdd
description: "Protocolo RED-GREEN-TRIANGULATE-REFACTOR de 7 fases con comando por fase, RED válido y de tipos, estricto en domain/application y pragmático en adapters/UI, evidencia atada a tdd-evidence.log. Usar cuando se implementa una tarea con Strict TDD ON o se audita su evidencia."
---

# Strict TDD

El test define el comportamiento y el contrato; el código de producción viene después. Es el modo que el `implementer` activa dentro del apply de una tarea; no es un agente aparte.

| Tipo de tarea | Strict TDD |
|---|---|
| feature, endpoint, componente, pantalla, refactor | **ON** por defecto |
| documentación, spike/exploración, cambio de configuración | **OFF** por defecto |
| Override manual del humano (ON/OFF para una tarea) | Se respeta y se registra en el apply-progress; ante la duda, preguntar antes de asumir |

Runner único: Vitest. Comando base `pnpm --filter <pkg> exec vitest run <ruta> -t "<caso>"` (en un solo paquete: `pnpm vitest run ...`). Integración/e2e: `pnpm test:integration -- <archivo.integration.spec.ts>` (requiere Postgres; ver §3).

## 1. Protocolo: 7 fases con comando

| # | Fase | Qué se hace | Comando | Resultado esperado |
|---|---|---|---|---|
| 1 | **Safety net** | Solo si la tarea toca archivos existentes: correr los specs de esos archivos antes de editar nada | `pnpm --filter <pkg> exec vitest run <specs de los archivos a tocar>` | PASS. FAIL → §7. Solo archivos nuevos → `N/A` |
| 2 | **Understand** | Leer tarea, spec, escenarios de aceptación (Given/When/Then), diseño y skills de la capa. Nada se escribe todavía | — | Comportamiento esperado y capa identificados |
| 3 | **RED** | Un solo test que describe el comportamiento ausente. Cero código de producción antes | `pnpm --filter <pkg> exec vitest run <archivo.spec.ts> -t "<caso>"` | **FAIL por la razón correcta** (§2) |
| 4 | **GREEN** | El mínimo código que hace pasar ese test. Sin generalizar, sin adornos | mismo comando de RED | PASS |
| 5 | **TRIANGULATE** | Casos extra que fuerzan la generalización (§4); cada uno pasa por su propio RED→GREEN | mismo comando, un `-t` por caso | FAIL → PASS por caso |
| 6 | **REFACTOR** | Nombres, duplicación, capa correcta. Sin cambiar comportamiento | `pnpm --filter <pkg> exec vitest run <archivo.spec.ts>` | PASS (toda la suite del archivo) |
| 7 | **Evidence** | Completar la tabla del apply-progress con los timestamps del log (§6) | `grep "<timestamp>" docs/sdd/<feature>/tdd-evidence.log` | Cada fila referencia una línea real del log |

Un ciclo por comportamiento; una tarea suele tener varios ciclos. GREEN y TRIANGULATE corren **solo el test dirigido**: la suite completa es del `verifier`, no del ciclo interno.

## 2. RED válido vs. inválido

| RED válido (cuenta) | RED inválido (no cuenta; arreglar y repetir) |
|---|---|
| Falla por comportamiento ausente: `expected 'ORDER_EMPTY', received undefined` | Falla por typo, import roto, `ReferenceError`, sintaxis |
| Falla porque el método aún no existe (`order.cancel is not a function`) y el test lo llama con la firma diseñada | Falla porque la DB no está levantada, el puerto no responde o falta un fixture |
| Aserta el `code` del error o el estado/evento resultante | Aserta `toHaveBeenCalled()` sin argumentos o un getter trivial |
| RED de tipos: `tsc` falla por `Unused '@ts-expect-error' directive` o `expectTypeOf` no compila (§3) | El test "falla" porque está skippeado, comentado o con `expect(true).toBe(false)` |
| Salida del FAIL pegada literal en la evidencia | "Falló, lo vi" sin línea de salida |

Si un RED da PASS de entrada, el test no prueba nada nuevo: reescribirlo o descartar el caso, nunca dejarlo como evidencia.

## 3. RED de tipos y RED por capa

Una firma que debe ser imposible se prueba en el compilador, no en runtime:

```ts
// order.repository.spec.ts — RED: hoy findById acepta cualquier string, la directiva queda "unused" y tsc falla
it('rejects a CustomerId where an OrderId is expected', () => {
  // @ts-expect-error CustomerId no es asignable a OrderId
  void repo.findById(CustomerId.rehydrate('11111111-1111-7111-8111-111111111111'));
  expectTypeOf(Order.create).returns.toEqualTypeOf<Result<Order, DomainError>>();
});
```

Comando: `pnpm --filter <pkg> exec tsc --noEmit -p tsconfig.spec.json` (o `vitest run --typecheck`). RED = `tsc` falla; GREEN = compila. Vale también para "un DTO no puede declarar campo de tenant" y "un `Draft` no entra en `emit(Signed)`".

| Capa | Modo | Primer test que falla | Dobles |
|---|---|---|---|
| domain (value objects, aggregates, services) | **Estricto**: ciclo puro, sin framework, milisegundos | Unit `*.spec.ts` sin `TestingModule` | Ninguno: `now`, ids y tunables como parámetros |
| application (handlers, use cases) | **Estricto** | Unit `*.spec.ts` del handler | Fakes de puertos: repo en memoria, `TimeProvider` fijo, `IdGenerator` secuencial, outbox/bus espía. Nunca mocks de Drizzle/pino/pg-boss |
| infrastructure (repos, adapters) | **Pragmático**: el test que falla primero es de integración contra Postgres real | `*.integration.spec.ts` (rol de app, no superusuario; cross-tenant obligatorio si hay tabla de tenant) | Ninguno sobre la DB |
| presentation (controllers, guards) | Pragmático | Unit con DI manual + `ExecutionContext` falso; e2e supertest solo en flujo crítico | Bus falso que devuelve `ok`/`err` reales |
| UI (Next.js) | Pragmático | Test de componente (Testing Library) por criterio de aceptación | Fetch/acciones fake |

En modo pragmático el orden RED→GREEN se mantiene; cambia el tipo de test y el comando (`pnpm test:integration -- <archivo>`). Un FAIL por DB caída no es RED: levanta la DB y repite.

## 4. Triangulación mínima

Después del primer GREEN, antes de REFACTOR, como mínimo:

| Caso | Ejemplo con `Order` | Qué evita |
|---|---|---|
| Error path con `code` | `cancel()` sobre un pedido cancelado → `ORDER_ALREADY_CANCELLED` | Código que solo conoce el camino feliz |
| Borde | `maxLines` exacto pasa; `maxLines + 1` falla; lista vacía; moneda distinta en `Money.add` | `if` hardcodeado al primer valor del test |
| Cross-tenant (si toca datos de tenant) | Tenant A escribe, tenant B lee `null`; DTO con `tenantId` en body → 400 | Fuga de aislamiento |
| Evento / efecto | `pullEvents()` contiene `OrderCancelled` una vez; `rehydrate()` no emite | Doble emisión, evento perdido |
| Determinismo | Con `TimeProvider` fijo el resultado es idéntico en dos corridas | Dependencia oculta del reloj |

Regla de tres: si dos casos pasan con una constante, el tercero debe romperla.

## 5. Antipatrones prohibidos

- Escribir producción antes del test en RED; "verde" sin un RED demostrado con línea de salida.
- Skippear (`it.skip`, `it.todo`, `xit`), comentar o mockear el sujeto bajo prueba para que el RED pase.
- Correr la suite completa en cada GREEN (lento, enmascara qué test cambió de estado).
- Refactor que deja rojo "para arreglar después"; seguir editando con el safety net en rojo.
- Falso verde: test que pasa contra una constante sin triangular; `toHaveBeenCalled()` sin argumentos; `sleep`; tests dependientes del orden.
- Evidencia con RED después del GREEN, sin timestamp del log, o con timestamps que no existen en el log.
- Datos reales de personas en fixtures; secretos o PII en la evidencia.

## 6. Evidencia mecánica

El hook `PostToolUse` del plugin registra cada corrida de test en `docs/sdd/<feature>/tdd-evidence.log`, una línea por corrida: `<ISO-8601> | exit=<n> | <comando> | <última línea del resumen de Vitest>`. La tabla del apply-progress **referencia esos timestamps**, no hashes de commit: la evidencia sobrevive a squash y rebase.

```
### Apply-progress — <tarea>
- Strict TDD: ON (tipo: <feature|endpoint|componente|pantalla|refactor>) · override: <ninguno|forzado ON/OFF por el humano>
- Safety net: <PASS | N/A (solo archivos nuevos) | falla preexistente reportada: <spec>>

| Tarea | Fase | Test | Comando | Resultado | Timestamp-log |
|-------|------|------|---------|-----------|---------------|
| T2-cancel-order | RED | rejects cancelling an already cancelled order | pnpm --filter api exec vitest run order.aggregate.spec.ts -t "already cancelled" | FAIL — expected 'ORDER_ALREADY_CANCELLED', received undefined | 2026-09-03T14:02:11Z |
| T2-cancel-order | GREEN | rejects cancelling an already cancelled order | (mismo) | PASS — 1 passed | 2026-09-03T14:05:40Z |
| T2-cancel-order | RED | emits OrderCancelled exactly once | (mismo, -t "exactly once") | FAIL — expected length 1, received 0 | 2026-09-03T14:07:02Z |
| T2-cancel-order | GREEN | emits OrderCancelled exactly once | (mismo) | PASS — 2 passed | 2026-09-03T14:08:15Z |
| T2-cancel-order | REFACTOR | order.aggregate.spec.ts | pnpm --filter api exec vitest run order.aggregate.spec.ts | PASS — 2 passed | 2026-09-03T14:12:30Z |
```

Validez (la revisa el `verifier`): cada fila tiene un timestamp presente en el log con el mismo comando y exit code coherente (RED ≠ 0, GREEN/REFACTOR = 0); el RED de un test precede a su GREEN; TRIANGULATE agrega pares RED→GREEN; ninguna fila sin línea de salida. Evidencia inválida → la tarea vuelve al `implementer`. **Cómo se verifica:** `grep -c "| exit=1 |" docs/sdd/<feature>/tdd-evidence.log` ≥ número de filas RED, y `grep "<timestamp>" ...` devuelve una línea por cada fila de la tabla.

## 7. Cuando el safety net falla

1. No tocar código de producción ni "arreglar de paso" el test rojo.
2. Registrar en el apply-progress: spec que falla, comando, línea de salida, timestamp del log.
3. Reportar al orquestador como **falla preexistente** y detener la tarea; el humano decide si abre una tarea de fix previa o acepta el rojo como conocido (queda escrito).
4. Nunca continuar con el test skippeado ni con `--reporter` que oculte el fallo.

## 8. Qué NO hace este modo

- No corre la suite completa ni `pnpm test:integration` global: eso es del `verifier` en el gate.
- No skippea, comenta ni debilita tests para llegar a verde.
- No commitea ni hace push: el commit lo hace el `implementer` solo cuando el humano lo pide o el proyecto lo permite; la evidencia no depende de hashes.
- No decide el nivel de test por comodidad: lo fija la capa (§3).
- No mockea Drizzle, pino ni pg-boss; no prueba contra producción.

## 9. Checklist de cierre de tarea

- [ ] ¿Estado Strict TDD (ON/OFF, tipo, override) registrado en el apply-progress?
- [ ] ¿Safety net PASS o `N/A`, o falla preexistente reportada y la tarea detenida?
- [ ] ¿Cada comportamiento tiene un RED con FAIL por la razón correcta, anterior a su GREEN?
- [ ] ¿Triangulación mínima de §4 (error path con `code`, borde, cross-tenant si aplica, evento)?
- [ ] ¿REFACTOR final en verde sobre el archivo completo?
- [ ] ¿Tabla de evidencia con timestamps que existen en `docs/sdd/<feature>/tdd-evidence.log`?
- [ ] ¿Ningún `it.skip`/`it.todo`/`xit` nuevo; ningún mock de Drizzle/pino/pg-boss; sin PII en fixtures ni evidencia?
- [ ] ¿Suite completa, lint y typecheck quedan para el `verifier` (no corridos aquí como sustituto de la evidencia)?
