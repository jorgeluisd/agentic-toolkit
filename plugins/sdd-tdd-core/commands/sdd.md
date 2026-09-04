---
description: Ejecuta el pipeline SDD+TDD completo (o el nivel bugfix) sobre una feature, agente por agente, con artefactos en docs/sdd/<NNNN>-<slug>/ y paradas en los dos gates humanos.
argument-hint: "<objetivo en una línea> [--level=full|bugfix]"
---

Orquesta el pipeline definido en `${CLAUDE_PLUGIN_ROOT}/ORCHESTRATOR.md` para:

$ARGUMENTS

Reglas de orquestación:
1. Lee `ORCHESTRATOR.md` del plugin y el `CLAUDE.md` del proyecto antes de lanzar nada. Resuelve la **raíz de artefactos** (§0 del `CLAUDE.md` o `.claude/sdd-hooks.env`; default `docs/sdd/`) y úsala en todo el pipeline: donde este comando dice `docs/sdd/`, va la raíz resuelta.
2. Crea `<raíz>/<NNNN>-<slug>/` (NNNN = siguiente correlativo; slug = el de la rama) y escribe el nombre en `<raíz>/.current`.
3. Lanza cada agente como subagente **pasándole solo las referencias de los artefactos previos ya resueltas a ruta, y su tarea** — nunca el historial de esta conversación ni el cuerpo de un artefacto. No lanzas un agente si falta el artefacto anterior: verifica que sea legible antes de lanzar.
4. Nivel `full` (default): explorer → proposer → spec-writer → designer → task-planner → **GATE 1** → implementer por tarea (strict-tdd si `TDD: ON`) → verifier ∥ code-reviewer ∥ security-reviewer (si hubo riesgos) → `/pr-draft` → **GATE 2** → (merge humano) → archiver.
   Nivel `bugfix`: explorer → implementer (TDD ON, el test que reproduce el bug es el RED) → verifier ∥ code-reviewer → **GATE 2**. Si aparece cambio de contrato o esquema, sube a `full`.
5. En cada gate te detienes, muestras el checklist de `gates/gate-N-*.md`, pides el token (`acepto` en GATE 1) y **registras la decisión en `gates.md`** antes de continuar. Sin registro, no continúas.
6. Un FAIL del verifier o un hallazgo alto del code-reviewer vuelve al implementer como tareas nuevas; nunca llega al GATE 2.
7. Git: tras el GATE 1, si la sesión está en la rama base, creas `feat|fix|chore/<slug>` desde ella (`git switch -c`) sin preguntar. El `implementer` commitea solo, un commit por tarea con verificaciones verdes (skill `delivery-workflow` §4). Push, PR y merge no los haces por iniciativa propia: el push a la rama de feature y la apertura del PR los autoriza el humano en GATE 2; el merge lo hace el humano.
8. Si un insumo falta o una duda bloquea, paras y preguntas; no inventas.
