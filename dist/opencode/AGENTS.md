# AGENTS.md — proceso SDD + Strict TDD

> Bloque generado por agentic-toolkit. Pegalo en el `AGENTS.md` de tu repositorio
> junto a lo propio del proyecto (stack, comandos, invariantes).

## Cómo se ejecuta un cambio de código

Toda feature, bugfix o cambio de esquema se ejecuta por el pipeline SDD, pedido por
comando o en lenguaje natural. Solo el nivel trivial (typo, copy, bump de patch)
queda fuera. El pipeline está en `.opencode/sdd-tdd-core/ORCHESTRATOR.md`; leelo antes de
tocar código.

Las 10 fases son subagentes en `.opencode/agents/`: se lanzan con la
herramienta `task`, una por vez y en el orden del orquestador.

## Comandos

| Comando | Qué hace |
|---|---|
| `/adopt` | Adopta el estándar SDD+TDD en el repositorio actual de punta a punta (configuración, AGENTS.md, skill de invariantes, lint, CI, feature piloto y limpieza de lo viejo), detectando los valores del proyecto y deteniéndose en cuatro checkpoints humanos. |
| `/audit-status` | Auditoría read-only del estado del proyecto — contrasta el código real contra el plan/backlog documentado y propone cierres, merges y splits sin escribir código ni aplicar cambios. |
| `/check-arch` | Corre typecheck + lint (boundaries Onion e inter-contexto) + tests + audit del proyecto y reporta el estado de la arquitectura sin corregir nada. |
| `/end-session` | Cierra la sesión — resumen, estado git, clasificación de hallazgos (ADR / plan / AGENTS.md / runbook / código) y updates propuestos al repo con OK explícito antes de aplicar. |
| `/new-adr` | Redacta un Architecture Decision Record con la plantilla canónica, lo deja en estado PROPUESTO en la carpeta de ADRs del proyecto y solo lo pasa a ACEPTADO tras el OK explícito del humano. |
| `/pr-draft` | Redacta el PR con la única plantilla permitida (Qué cambia · Por qué · Verificación) a partir de la spec y del reporte del verifier, y lo abre con gh solo si el humano lo confirma. |
| `/sdd` | Ejecuta el pipeline SDD+TDD completo (o el nivel bugfix) sobre una feature, agente por agente, con artefactos en docs/sdd/<NNNN>-<slug>/ y paradas en los dos gates humanos. |
| `/start-session` | Arranca una sesión leyendo el estado local del proyecto (AGENTS.md, ADRs, plan/backlog, último 08-close.md) y reporta dónde estamos antes de tocar código. |

## Skills

En `.opencode/skills/`. OpenCode las carga sola según la `description` de cada una.

## Guardrails

`.opencode/plugins/sdd-guard.js` corre los mismos hooks bash que el toolkit usa en
Claude Code y Codex: bloquea comandos dirigidos a producción, lectura y escritura de
secretos, datos personales en artefactos y trailers de IA en los commits, y escribe
la evidencia TDD. Una salvedad: OpenCode no tiene un estado intermedio de
confirmación, así que lo que en Claude sería preguntar acá permite y queda en el log.
