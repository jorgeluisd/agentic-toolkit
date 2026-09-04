---
description: Arranca una sesión leyendo el estado local del proyecto (CLAUDE.md, ADRs, plan/backlog, último 08-close.md) y reporta dónde estamos antes de tocar código.
argument-hint: "[área o ítem a tocar | vacío para sesión exploratoria]"
---

Arranca la sesión de trabajo. Regla de oro (local-first): las decisiones y el estado viven en el repositorio; no asumas fuentes externas salvo que el `CLAUDE.md` las declare.

Lee, en este orden y solo lo necesario:
1. `CLAUDE.md` del proyecto (contexto, stack, invariantes, comandos, rutas de plan/backlog/ADRs).
2. Skill local de invariantes del proyecto, si existe.
3. `<raíz>/specs/` — los specs de capacidad son el registro vigente de qué hace el sistema. Leé los de la capacidad que vas a tocar; no los de `_archive/`, que es historia.
4. El último `08-close.md` (próximo paso sugerido) y `<raíz>/.current` si hay una feature abierta.
5. ADRs afines al área a tocar (busca por tema; no leas todos).
6. Plan/backlog: qué está hecho, qué está en curso, orden de cierre.
7. Memoria persistente conectada, si existe; si no, omite.

Área/ítem de esta sesión:
$ARGUMENTS
(vacío = sesión exploratoria)

Confirma: rama actual, commit de la rama base (`git rev-parse --short <base>`), árbol limpio, identidad git local (`git config --local user.email`; si falta, dilo: la convención exige fijarla antes del primer commit).

Responde con:
1. Estado del plan: fase activa, hecho/pendiente, feature SDD abierta si la hay.
2. ADRs que aplican al área.
3. Blockers o insumos faltantes que afecten esta sesión.
4. Rama, commit base e identidad git.
5. "Listo. ¿Qué hacemos?"

No modifiques nada en este comando.
