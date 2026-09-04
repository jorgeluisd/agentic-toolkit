---
description: Auditoría read-only del estado del proyecto — contrasta el código real contra el plan/backlog documentado y propone cierres, merges y splits sin escribir código ni aplicar cambios.
argument-hint: "[foco opcional: módulo, contexto o capa | vacío = auditoría general]"
---

Auditoría de estado (read-only; no escribas código ni modifiques plan/backlog sin OK explícito).

Foco:
$ARGUMENTS
(vacío = auditoría general)

Lee en paralelo: `CLAUDE.md`, plan/backlog (rutas declaradas), ADRs, `<raíz>/specs/*/spec.md` (el comportamiento vigente), los `<raíz>/<NNNN>-<slug>/02-spec.md` de los changes **abiertos** con su ESTADO, `git log --oneline -30` en la rama base, y la estructura real del código (contextos, endpoints, migraciones, pantallas). No leas `<raíz>/_archive/`: es historia, y contrastar el código contra specs ya reconciliadas produce falsos hallazgos.

Regla anti-cruce de numeración: el único identificador válido de un ítem es el que figura en el archivo de backlog. Ignora números dentro de cuerpos de ítems o de commits viejos; no deduzcas estado por el número de un commit.

Entregables, en este orden:
A) STATUS por contexto/módulo: Done / In Progress / Ready / Backlog / Blocked, contrastando documento vs código; marca cada inconsistencia (código que superó al ítem, ítem full-stack a medias, mal scopeado).
B) DÓNDE ESTAMOS por capa o módulo principal: construido de verdad vs faltante para el próximo hito.
C) ESTIMADO realista según la disponibilidad declarada del equipo (si no está declarada, pregúntala; no la asumas).
D) OPTIMIZACIÓN DEL BACKLOG: merges, splits, redundantes, faltantes (deuda técnica y GAPS de los `06-verify.md`).
E) DECISIONES pendientes que bloquean, con recomendación.
F) PRÓXIMO PASO para la siguiente sesión de código.

Al terminar: mapeo "ID real ↔ qué es ↔ status ↔ qué PR/código lo cierra"; propuesta de cambios al plan/backlog **esperando OK** antes de aplicar; si hay memoria persistente conectada, guarda los hallazgos (sin datos personales).
