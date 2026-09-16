# audit-status

Auditoría read-only del estado del proyecto — contrasta el código real contra el plan/backlog documentado y propone cierres, merges y splits sin escribir código ni aplicar cambios.

**Argumentos:** `[foco opcional: módulo, contexto o capa | vacío = auditoría general]`

## Procedure


Auditoría de estado (read-only; no escribas código ni modifiques plan/backlog sin OK explícito).

Foco:
lo que te pidió el usuario
(vacío = auditoría general)

Lee en paralelo: `AGENTS.md`, plan/backlog (rutas declaradas), ADRs, `<raíz>/specs/*/spec.md` (el comportamiento vigente), los `<raíz>/<NNNN>-<slug>/02-spec.md` de los changes **abiertos** con su ESTADO, `git log --oneline -30` en la rama base, y la estructura real del código (contextos, endpoints, migraciones, pantallas). No leas `<raíz>/_archive/`: es historia, y contrastar el código contra specs ya reconciliadas produce falsos hallazgos.

Regla anti-cruce de numeración: el único identificador válido de un ítem es el que figura en el archivo de backlog. Ignora números dentro de cuerpos de ítems o de commits viejos; no deduzcas estado por el número de un commit.

Entregables, en este orden:
A) STATUS por contexto/módulo: Done / In Progress / Ready / Backlog / Blocked, contrastando documento vs código; marca cada inconsistencia (código que superó al ítem, ítem full-stack a medias, mal scopeado).
B) DÓNDE ESTAMOS por capa o módulo principal: construido de verdad vs faltante para el próximo hito.
C) ESTIMADO realista según la disponibilidad declarada del equipo (si no está declarada, pregúntala; no la asumas).
D) OPTIMIZACIÓN DEL BACKLOG: merges, splits, redundantes, faltantes (deuda técnica y GAPS de los `06-verify.md`).
E) DECISIONES pendientes que bloquean, con recomendación.
F) PRÓXIMO PASO para la siguiente sesión de código.

Al terminar: mapeo "ID real ↔ qué es ↔ status ↔ qué PR/código lo cierra"; propuesta de cambios al plan/backlog **esperando OK** antes de aplicar; si hay memoria persistente conectada, guarda los hallazgos (sin datos personales).


## Specifications

- El pipeline, las fases y los gates están en `.agents/sdd-tdd-core/ORCHESTRATOR-solo.md`. Leelo antes de empezar.
- Los artefactos van a `docs/sdd/<NNNN>-<slug>/` y son la máquina de estados del proceso: si no está escrito, no pasó.
- En cada gate te detenés de verdad y esperás el token del humano. Un gate sin registro en `gates.md` no ocurrió.

## Forbidden Actions

- Leer o editar `.env*`, `*.pem`, `*.key` ni ningún archivo de credenciales.
- Escribir secretos, datos personales reales o identificadores de producción en un artefacto, un test o un commit. Los ejemplos son sintéticos: teléfonos `+10000000001`, dominios `example.com`.
- Correr comandos dirigidos a producción (psql contra una base productiva, deploys, actualización de una lambda) sin confirmación humana explícita.
- Forzar un push, saltear los hooks de git al commitear, o pushear directo a la rama base.
- Agregar trailers o menciones de IA al commit o al PR: `Co-Authored-By`, `Generated with`, nombres de modelos, `anthropic`, `openai`, `devin.ai`.
- Escribir código de producción antes del GATE 1 aprobado.
- Escribir código de producción en una fase que no sea `implementer`.
- Bloques de comentario de más de 4 líneas, o más de 15 % de líneas comentadas en un archivo de código.
