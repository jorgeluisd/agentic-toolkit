# AGENTS.md — proceso SDD + Strict TDD

> Bloque generado por agentic-toolkit. Pegalo en el `AGENTS.md` de tu repositorio
> junto a lo propio del proyecto (stack, comandos, invariantes).

## Cómo se ejecuta un cambio de código

Toda feature, bugfix o cambio de esquema se ejecuta por el pipeline SDD, pedido por
comando o en lenguaje natural. Solo el nivel trivial (typo, copy, bump de patch)
queda fuera. El pipeline, sus fases y sus gates están en
`.codex/sdd-tdd-core/ORCHESTRATOR.md`; leelo antes de tocar código.

Si esta sesión no puede lanzar subagentes, seguí `.codex/sdd-tdd-core/ORCHESTRATOR-solo.md`:
mismo proceso, mismas fases, ejecutadas en secuencia por una sola sesión.

## Comandos

| Comando | Qué hace |
|---|---|
| `/prompts:adopt` | Adopta el estándar SDD+TDD en el repositorio actual de punta a punta (configuración, AGENTS.md, skill de invariantes, lint, CI, feature piloto y limpieza de lo viejo), detectando los valores del proyecto y deteniéndose en cuatro checkpoints humanos. |
| `/prompts:audit-status` | Auditoría read-only del estado del proyecto — contrasta el código real contra el plan/backlog documentado y propone cierres, merges y splits sin escribir código ni aplicar cambios. |
| `/prompts:check-arch` | Corre typecheck + lint (boundaries Onion e inter-contexto) + tests + audit del proyecto y reporta el estado de la arquitectura sin corregir nada. |
| `/prompts:end-session` | Cierra la sesión — resumen, estado git, clasificación de hallazgos (ADR / plan / AGENTS.md / runbook / código) y updates propuestos al repo con OK explícito antes de aplicar. |
| `/prompts:new-adr` | Redacta un Architecture Decision Record con la plantilla canónica, lo deja en estado PROPUESTO en la carpeta de ADRs del proyecto y solo lo pasa a ACEPTADO tras el OK explícito del humano. |
| `/prompts:pr-draft` | Redacta el PR con la única plantilla permitida (Qué cambia · Por qué · Verificación) a partir de la spec y del reporte del verifier, y lo abre con gh solo si el humano lo confirma. |
| `/prompts:sdd` | Ejecuta el pipeline SDD+TDD completo (o el nivel bugfix) sobre una feature, agente por agente, con artefactos en docs/sdd/<NNNN>-<slug>/ y paradas en los dos gates humanos. |
| `/prompts:start-session` | Arranca una sesión leyendo el estado local del proyecto (AGENTS.md, ADRs, plan/backlog, último 08-close.md) y reporta dónde estamos antes de tocar código. |

## Skills

Las skills están en `.agents/skills/` y Codex las carga sola cuando la `description`
de cada una coincide con lo que estás haciendo. No hace falta invocarlas.

## Guardrails

Los hooks de `.codex/hooks.json` bloquean comandos dirigidos a producción, lectura
y escritura de secretos, datos personales en artefactos y trailers de IA en los
commits, y escriben la evidencia TDD. Corren solos: no los desactives para avanzar
más rápido — si uno te frena, el cambio es lo que está mal.
