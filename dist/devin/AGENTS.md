# AGENTS.md — proceso SDD + Strict TDD

> Bloque generado por agentic-toolkit. Pegalo en el `AGENTS.md` de tu repositorio
> junto a lo propio del proyecto (stack, comandos, invariantes).

## Cómo se ejecuta un cambio de código

Toda feature, bugfix o cambio de esquema se ejecuta por el pipeline SDD. Solo el
nivel trivial (typo, copy, bump de patch) queda fuera.

**Seguí `.agents/sdd-tdd-core/ORCHESTRATOR-solo.md`.** Es el pipeline completo — diez
fases, dos gates humanos — ejecutado en secuencia por una sola sesión, porque acá
no hay subagentes. Cada fase carga su rol de `.agents/sdd-tdd-core/agents/<fase>.md`,
verifica sus insumos y escribe su artefacto antes de pasar a la siguiente.

Los artefactos en `docs/sdd/<NNNN>-<slug>/` son la máquina de estados: el estado
del pipeline no vive en la conversación, vive en disco. Una sesión que se corta se
retoma mirando qué artefactos existen.

## Playbooks

Cargalos desde `playbooks/`. Equivalen a los comandos del toolkit.

| Playbook | Qué hace |
|---|---|
| `adopt` | Adopta el estándar SDD+TDD en el repositorio actual de punta a punta (configuración, AGENTS.md, skill de invariantes, lint, CI, feature piloto y limpieza de lo viejo), detectando los valores del proyecto y deteniéndose en cuatro checkpoints humanos. |
| `audit-status` | Auditoría read-only del estado del proyecto — contrasta el código real contra el plan/backlog documentado y propone cierres, merges y splits sin escribir código ni aplicar cambios. |
| `check-arch` | Corre typecheck + lint (boundaries Onion e inter-contexto) + tests + audit del proyecto y reporta el estado de la arquitectura sin corregir nada. |
| `end-session` | Cierra la sesión — resumen, estado git, clasificación de hallazgos (ADR / plan / AGENTS.md / runbook / código) y updates propuestos al repo con OK explícito antes de aplicar. |
| `new-adr` | Redacta un Architecture Decision Record con la plantilla canónica, lo deja en estado PROPUESTO en la carpeta de ADRs del proyecto y solo lo pasa a ACEPTADO tras el OK explícito del humano. |
| `pr-draft` | Redacta el PR con la única plantilla permitida (Qué cambia · Por qué · Verificación) a partir de la spec y del reporte del verifier, y lo abre con gh solo si el humano lo confirma. |
| `sdd` | Ejecuta el pipeline SDD+TDD completo (o el nivel bugfix) sobre una feature, agente por agente, con artefactos en docs/sdd/<NNNN>-<slug>/ y paradas en los dos gates humanos. |
| `start-session` | Arranca una sesión leyendo el estado local del proyecto (AGENTS.md, ADRs, plan/backlog, último 08-close.md) y reporta dónde estamos antes de tocar código. |

## Reglas que acá nadie hace cumplir por vos

En otros agentes estas reglas son hooks que **bloquean** la llamada. Devin no tiene
hooks: son reglas que leés y cumplís. Nadie te va a frenar.

- Leer o editar `.env*`, `*.pem`, `*.key` ni ningún archivo de credenciales.
- Escribir secretos, datos personales reales o identificadores de producción en un artefacto, un test o un commit. Los ejemplos son sintéticos: teléfonos `+10000000001`, dominios `example.com`.
- Correr comandos dirigidos a producción (psql contra una base productiva, deploys, actualización de una lambda) sin confirmación humana explícita.
- Forzar un push, saltear los hooks de git al commitear, o pushear directo a la rama base.
- Agregar trailers o menciones de IA al commit o al PR: `Co-Authored-By`, `Generated with`, nombres de modelos, `anthropic`, `openai`, `devin.ai`.
- Escribir código de producción antes del GATE 1 aprobado.
- Escribir código de producción en una fase que no sea `implementer`.
- Bloques de comentario de más de 4 líneas, o más de 15 % de líneas comentadas en un archivo de código.

## Evidencia TDD

En las tareas con `TDD: ON`, anotá cada ciclo en
`docs/sdd/<NNNN>-<slug>/tdd-evidence.log`, una línea por fase, con el comando
literal y su resultado. En otros agentes lo escribe un hook; acá lo escribís vos, y
el `verifier` lo contrasta contra el apply-progress. Formato en
`.agents/sdd-tdd-core/ORCHESTRATOR-solo.md` §5.
