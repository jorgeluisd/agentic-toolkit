# sdd

Ejecuta el pipeline SDD+TDD completo (o el nivel bugfix) sobre una feature, agente por agente, con artefactos en docs/sdd/<NNNN>-<slug>/ y paradas en los dos gates humanos.

**Argumentos:** `<objetivo en una línea> [--level=full|bugfix]`

## Procedure


Orquesta el pipeline definido en `.agents/sdd-tdd-core/ORCHESTRATOR-solo.md` para:

lo que te pidió el usuario

Reglas de orquestación:
1. Lee `ORCHESTRATOR-solo.md` del plugin y el `AGENTS.md` del proyecto antes de lanzar nada. Resuelve la **raíz de artefactos** (§0 del `AGENTS.md` o `.agentic/sdd-hooks.env`; default `docs/sdd/`) y úsala en todo el pipeline: donde este comando dice `docs/sdd/`, va la raíz resuelta. Si el store configurado es `engram`, comprobá que tengas herramientas de memoria disponibles en esta sesión: si no las tenés, degradá a `local`, decilo en una línea y seguí (§3 de `ORCHESTRATOR.md`). No abortes por esto.
2. Clasifica el nivel (`full` | `bugfix`), crea `<raíz>/<NNNN>-<slug>/` (NNNN = siguiente correlativo ignorando `_archive/`; slug = el de la rama), escribe el nombre en `<raíz>/.current` y el nivel en `<raíz>/<NNNN>-<slug>/.level`. El `.level` no es decorativo: el gatekeeper lo lee para saber qué insumos exigir, y si falta asume `full`.
2b. Antes del `spec-writer`, listá `<raíz>/specs/` y pasale al agente el spec de la capacidad que la feature toca, si ya existe: la spec nueva declara el delta contra ese comportamiento, no lo redefine desde cero.
3. Lanza cada agente como agente aparte **pasándole solo las referencias de los artefactos previos ya resueltas a ruta, y su tarea** — nunca el historial de esta conversación ni el cuerpo de un artefacto. No lanzas un agente si falta el artefacto anterior: verifica que sea legible antes de lanzar. Si esta sesión no puede lanzar agentes aparte, seguí `.agents/sdd-tdd-core/ORCHESTRATOR-solo.md`: mismas fases y mismos gates, ejecutados en secuencia por vos.
4. Nivel `full` (default): explorer → proposer → spec-writer → designer → task-planner → **GATE 1** → implementer por tarea (strict-tdd si `TDD: ON`) → verifier ∥ code-reviewer ∥ security-reviewer (si hubo riesgos) → `/pr-draft` → **GATE 2** → (merge humano) → archiver.
   Nivel `bugfix`: explorer → implementer (TDD ON, el test que reproduce el bug es el RED) → verifier ∥ code-reviewer → **GATE 2**. Si aparece cambio de contrato o esquema, sube a `full`.
5. En cada gate te detienes, muestras el checklist de `gates/gate-N-*.md`, pides el token (`acepto` en GATE 1) y **registras la decisión en `gates.md`** antes de continuar. Sin registro, no continúas.
6. Un FAIL del verifier o un hallazgo alto del code-reviewer vuelve al implementer como tareas nuevas; nunca llega al GATE 2.
7. Git: tras el GATE 1, si la sesión está en la rama base, creas `feat|fix|chore/<slug>` desde ella (`git switch -c`) sin preguntar. El `implementer` commitea solo, un commit por tarea con verificaciones verdes (skill `delivery-workflow` §4). Push, PR y merge no los haces por iniciativa propia: el push a la rama de feature y la apertura del PR los autoriza el humano en GATE 2; el merge lo hace el humano.
8. Si un insumo falta o una duda bloquea, paras y preguntas; no inventas.


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
