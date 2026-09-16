# ORCHESTRATOR SOLO — SDD + Strict TDD en una sola sesión

Variante de `ORCHESTRATOR.md` para agentes que **no pueden lanzar subagentes**. El proceso es el mismo — mismas fases, mismos artefactos, mismos dos gates humanos. Lo que cambia es quién ejecuta cada fase: en vez de diez agentes con contexto propio, **una sola sesión que adopta diez roles en orden**.

Usá este documento cuando el agente no tenga una herramienta de subagentes (Devin, y Codex CLI mientras no se confirme el suyo). Si tenés subagentes, usá `ORCHESTRATOR.md`: es estrictamente mejor.

## 1. Qué se pierde y cómo se compensa

Un subagente aporta dos cosas que una sesión única no tiene gratis: **contexto limpio** (el `verifier` no vio al `implementer` escribir el código, así que no hereda su sesgo) y **aislamiento de herramientas** (el `explorer` no puede escribir aunque quiera). Sin subagentes:

| Se pierde | Compensación obligatoria |
|---|---|
| Contexto limpio entre fases | Cada fase se abre releyendo **solo** los artefactos que la tabla de insumos le asigna, y se cierra escribiendo el suyo. Lo que recuerdes de una fase anterior no cuenta como insumo: si no está en el artefacto, no existe |
| Independencia de la revisión | El `verifier` y el `code-reviewer` juzgan **contra el artefacto**, nunca contra la intención. Si no podés justificar un PASS citando la línea del `02-spec.md` o del `03-design.md`, es FAIL |
| Aislamiento de herramientas | Las fases de lectura (`explorer`, `proposer`, `spec-writer`, `designer`, `task-planner`, `verifier`, `code-reviewer`, `security-reviewer`) **no escriben código de producción**. Solo el `implementer` toca `src/`. Esto no lo fuerza ninguna herramienta acá: es una regla que cumplís vos |

**Los artefactos en disco son la máquina de estados.** Eso es lo que hace portable al proceso: el estado del pipeline no vive en el contexto de la conversación, vive en `<raíz>/<NNNN>-<slug>/`. Una sesión que se corta se retoma leyendo qué artefactos existen.

## 2. Bucle de ejecución

Para cada fase, en el orden de `ORCHESTRATOR.md` §1:

1. **Declará la fase.** Una línea: `── FASE 3/10 · spec-writer ──`. Sin esto las fases se funden y el proceso deja de ser auditable.
2. **Cargá el rol.** Leé `agents/<fase>.md`: es tu instrucción completa para esta fase, incluidos su alcance y sus prohibiciones. Reemplaza cualquier criterio propio.
3. **Verificá los insumos.** Tabla de `ORCHESTRATOR.md` §3.2. Si falta uno requerido, **detenete**: no lo inventes ni lo reconstruyas de memoria.
4. **Ejecutá y escribí el artefacto** a su ruta, con `RESUMEN` (≤ 10 líneas) al inicio y `DUDAS ABIERTAS` al final. Máximo 150 líneas salvo `05-apply-progress.md`.
5. **Cerrá la fase.** Confirmá en una línea qué artefacto quedó escrito y pasá a la siguiente.

En los gates te detenés de verdad: mostrás el checklist de `gates/gate-N-*.md`, esperás el token del humano (`acepto` en GATE 1) y **registrás la decisión en `gates.md`** antes de seguir. Un gate sin registro no ocurrió.

## 3. Nivel de uso

Igual que en el pipeline con subagentes:

| Nivel | Recorrido |
|---|---|
| Completo | Las 10 fases, con los dos gates |
| Bugfix | `explorer` → `implementer` (TDD ON: el test que reproduce el bug es el RED) → `verifier` + `code-reviewer` → GATE 2 |
| Trivial | Sin pipeline; commit directo bajo la skill `delivery-workflow` |

El nivel se escribe en `<raíz>/<NNNN>-<slug>/.level` al abrir el change, igual que siempre.

## 4. Dónde no hay gatekeeper

En el pipeline con subagentes, el hook `pre-task` intercepta el lanzamiento de cada fase y **deniega** si falta un insumo o si el `implementer` va a correr sin GATE 1. Acá no hay lanzamiento que interceptar: no existe una llamada `Task` que el hook pueda ver.

Consecuencia directa, sin rodeos: **en modo solo, el paso 3 del bucle es la única barrera entre el proceso y la improvisación.** Los otros guardrails (producción, secretos, PII, evidencia TDD, trailers de IA) siguen corriendo donde el agente soporte hooks; el gatekeeper de fases, no.

Si tu agente no ejecuta hooks en absoluto, los guardrails son reglas que leés y cumplís, no controles que te frenen. Está documentado en `PORTABILITY.md`.

## 5. Evidencia TDD sin hook

`tdd-evidence.log` lo escribe el hook `post-bash` a partir de cada corrida de tests. Sin hooks no se escribe solo: durante las tareas con `TDD: ON`, **anotás vos** cada ciclo en `<raíz>/<NNNN>-<slug>/tdd-evidence.log`, una línea por fase, con el comando literal y su resultado:

```
2026-09-15T14:02:11Z  T3  RED     pnpm vitest run src/orders/cancel.spec.ts   exit=1  1 failed
2026-09-15T14:06:40Z  T3  GREEN   pnpm vitest run src/orders/cancel.spec.ts   exit=0  3 passed
```

El `verifier` contrasta el log contra el `05-apply-progress.md`: una tarea con `TDD: ON` sin RED previo al GREEN es FAIL. Escrito a mano o por hook, el contrato es el mismo.
