# start-session

Arranca una sesión leyendo el estado local del proyecto (AGENTS.md, ADRs, plan/backlog, último 08-close.md) y reporta dónde estamos antes de tocar código.

**Argumentos:** `[área o ítem a tocar | vacío para sesión exploratoria]`

## Procedure


Arranca la sesión de trabajo. Regla de oro (local-first): las decisiones y el estado viven en el repositorio; no asumas fuentes externas salvo que el `AGENTS.md` las declare.

Lee, en este orden y solo lo necesario:
1. `AGENTS.md` del proyecto (contexto, stack, invariantes, comandos, rutas de plan/backlog/ADRs).
2. Skill local de invariantes del proyecto, si existe.
3. `<raíz>/specs/` — los specs de capacidad son el registro vigente de qué hace el sistema. Leé los de la capacidad que vas a tocar; no los de `_archive/`, que es historia.
4. El último `08-close.md` (próximo paso sugerido) y `<raíz>/.current` si hay una feature abierta.
5. ADRs afines al área a tocar (busca por tema; no leas todos).
6. Plan/backlog: qué está hecho, qué está en curso, orden de cierre.
7. Memoria persistente conectada, si existe; si no, omite.

Área/ítem de esta sesión:
lo que te pidió el usuario
(vacío = sesión exploratoria)

Confirma: rama actual, commit de la rama base (`git rev-parse --short <base>`), árbol limpio, identidad git local (`git config --local user.email`; si falta, dilo: la convención exige fijarla antes del primer commit).

Responde con:
1. Estado del plan: fase activa, hecho/pendiente, feature SDD abierta si la hay.
2. ADRs que aplican al área.
3. Blockers o insumos faltantes que afecten esta sesión.
4. Rama, commit base e identidad git.
5. "Listo. ¿Qué hacemos?"

No modifiques nada en este comando.


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
