---
description: Ejecuta el pipeline SDD+TDD completo (o el nivel bugfix) sobre una feature, agente por agente, con artefactos en docs/sdd/<NNNN>-<slug>/ y paradas en los dos gates humanos.
argument-hint: "<objetivo en una línea> [--level=full|bugfix]"
---

Orquesta el pipeline definido en `${CLAUDE_PLUGIN_ROOT}/ORCHESTRATOR.md` para:

$ARGUMENTS

Reglas de orquestación:
1. Lee `ORCHESTRATOR.md` del plugin y el `CLAUDE.md` del proyecto antes de lanzar nada.
2. Crea `docs/sdd/<NNNN>-<slug>/` (NNNN = siguiente correlativo; slug = el de la rama) y escribe el nombre en `docs/sdd/.current`.
3. Lanza cada agente como subagente **pasándole solo las rutas de los artefactos previos y su tarea**, nunca el historial de esta conversación. No lanzas un agente si falta el artefacto anterior.
4. Nivel `full` (default): explorer → proposer → spec-writer → designer → task-planner → **GATE 1** → implementer por tarea (strict-tdd si `TDD: ON`) → verifier ∥ code-reviewer ∥ security-reviewer (si hubo riesgos) → `/pr-draft` → **GATE 2** → (merge humano) → archiver.
   Nivel `bugfix`: explorer → implementer (TDD ON, el test que reproduce el bug es el RED) → verifier ∥ code-reviewer → **GATE 2**. Si aparece cambio de contrato o esquema, sube a `full`.
5. En cada gate te detienes, muestras el checklist de `gates/gate-N-*.md`, pides el token (`acepto` en GATE 1) y **registras la decisión en `gates.md`** antes de continuar. Sin registro, no continúas.
6. Un FAIL del verifier o un hallazgo alto del code-reviewer vuelve al implementer como tareas nuevas; nunca llega al GATE 2.
7. No commiteas, no mergeas, no pusheas: lo hace el humano o lo autoriza explícitamente (skill `delivery-workflow`).
8. Si un insumo falta o una duda bloquea, paras y preguntas; no inventas.
