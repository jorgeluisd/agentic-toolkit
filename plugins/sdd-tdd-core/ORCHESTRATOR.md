# ORCHESTRATOR — SDD + Strict TDD

Pipeline de 10 agentes para construir software con especificación verificable, diseño explícito, TDD estricto y dos paradas humanas. Agnóstico de producto y de lenguaje: el contexto de negocio y las invariantes viven en el `CLAUDE.md` y en la skill local de invariantes de cada proyecto; las reglas técnicas (capas, dominio, persistencia, tests, seguridad) las aporta el plugin de stack instalado junto a este core (`stack-typescript`, `stack-go` u otro). Este documento define solo el proceso.

## 1. Pipeline

```
explorer → (proposer) → designer → [GATE 1] →
(implementer ⟲ strict-tdd)* → verifier ∥ code-reviewer(s) ∥ security-reviewer → [GATE 2] → merge → archiver
```

Desde 2.7.0 el layout por defecto es **lite** (`SDD_LAYOUT=lite`): la intención, el avance y la evidencia de una feature viven en **un solo documento**, `feature.md`, en vez de un archivo por fase. Cada agente escribe su sección del mismo documento; ninguno re-redacta lo que escribió el anterior.

| # | Agente | Responsabilidad (una línea) | Escribe |
|---|---|---|---|
| — | orquestador | Crea la carpeta, `.level` y `feature.md` con el encabezado y `## Log` → `L1` = pedido del humano **textual** | `feature.md` (esqueleto) |
| 1 | `explorer` | Mapa read-only del terreno: qué existe, qué falta, riesgos, insumos faltantes. En `bugfix` también la spec del defecto y la tarea | `## Exploración` (+ `## Specs`, `## Tasks` en bugfix) |
| 2 | `proposer` | **Opcional**: solo si la exploración deja una decisión real con alternativas o un ADR. 1–3 enfoques con reversibilidad | `## Propuesta` (+ ADR propuesto) |
| 3 | `designer` | Specs verificables `S#` con las cadenas del humano textuales, diseño por capa, amenazas con test, tareas `T#` | `## Specs`, `## Diseño`, `## Tasks` |
| — | **GATE 1** | Humano aprueba specs + diseño + tareas + amenazas con la palabra `acepto` | `gates.md` |
| 4 | `implementer` | Único que escribe código de producción; una tarea por vez; carga `strict-tdd`; cierra `T#` con su commit | `05-apply-progress.md` + checkbox en `## Tasks` + `tdd-evidence.log` (hook) |
| 5 | `verifier` | Checks mecánicos con salida literal; **veredicto por `S#`**; madurez de dependencias si cambió un lockfile | `06-verify.md` |
| 6 | `code-reviewer` | Revisión independiente; en riesgo alto, dos instancias a ciegas | `07-review.md` (+ `07-review-2.md`) |
| 7 | `security-reviewer` | Lectura adversarial; obligatorio en riesgo alto | `07-security.md` |
| — | **GATE 2** | Humano (o `gate2-auto.sh`) decide merge | `gates.md` |
| 8 | `archiver` | Post-merge: reconcilia `## Specs` con `specs/<capacidad>/`, ADRs, backlog, memoria | `08-close.md` |

`05`–`08` y `gates.md` conservan nombre y formato: son el contrato que leen `gate2-auto.sh` y los scripts de merge de los proyectos.

**Layout classic** (`SDD_LAYOUT=classic`, y toda feature que ya tenga `00-explore.md`…`04-plan.md`): el pipeline de 10 agentes con un archivo por fase — `explorer → proposer → spec-writer → designer → task-planner → GATE 1 → …` — tal como funcionaba hasta 2.6. El gatekeeper detecta el layout por carpeta, así que una feature en vuelo nunca cambia de formato a mitad de camino.

### `feature.md` — orden fijo

```
# <NNNN>-<slug> — <título>
Nivel: full|bugfix · Rama: <rama> · Runner: <comando de tests>
GATE 2: auto | humano — <disparador>   ← en su propia línea: es la que lee gate2-auto.sh (la fija el designer)

## Exploración      (explorer)   terreno, riesgos, insumos faltantes, DECISIÓN: sí|no
## Propuesta        (proposer)   solo si DECISIÓN: sí
## Specs            (designer; explorer en bugfix)
S1. <criterio verificable; las cadenas, mensajes de error y ejemplos del humano, textuales, nunca resumidos>
## Diseño           (designer)   piezas por capa con imports, datos/migración, AMENAZAS (activo · vector · mitigación · test)
## Tasks            (designer; explorer en bugfix)
- [ ] T1 (S1, S2) · TDD ON · <modelo> · <archivos previstos>
- [x] T1 (S1, S2) · TDD ON · … · 1a2b3c4      ← lo marca el implementer, con el commit
## Log              (último, append-only)
L1 <fecha> humano (textual): > <pedido original>
L2 <fecha> humano (textual): > <corrección>   · decisiones, evidencia, cambios de alcance
```

Reglas del documento:
- `## Log` va siempre al final y `L1` existe antes del explorer: el gatekeeper deniega cualquier fase si falta.
- Un cambio de requisito reescribe **solo** la `S#` afectada y reabre **solo** sus `T#` (con el motivo en el Log). No se rehace el documento.
- Una `T#` se marca `[x]` únicamente con el commit que la contiene; `gate2-auto.sh` rechaza tareas abiertas o cerradas sin commit.
- Tope orientativo de 250 líneas. Si no alcanza, la feature es demasiado grande: se parte en dos features.

`strict-tdd` **no es un agente**: es la skill/protocolo que el `implementer` carga en cada tarea con `TDD: ON`. Separarlo en otro subagente rompería el ciclo RED→GREEN a través de una frontera de contexto.

## 2. Niveles de uso

| Nivel | Cuándo | Recorrido |
|---|---|---|
| Completo | Feature nueva, cambio de esquema o de contrato público, migración, auth, pagos, datos personales, integraciones — **o** cualquier cambio que no pasa el test de reanudación | Pipeline entero |
| Bugfix | Defecto acotado y reproducible que **pasa el test de reanudación**, sin cambio de contrato ni de esquema | `explorer` (escribe `S1` = la reproducción y `T1`) → `implementer` (el test que reproduce el bug es el RED) → `verifier` ∥ `code-reviewer` → GATE 2 |
| Trivial | Typo, comentario, copy, bump de patch sin cambio de API | Sin pipeline; commit directo bajo la skill `delivery-workflow` |

**Test de reanudación.** La pregunta que decide entre bugfix y completo es: *si la sesión se corta ahora, ¿otra sesión podría terminar el trabajo con solo el pedido y el `git diff`?* Si sí, el cambio está entendido y su riesgo contenido: bugfix. Si no —porque hay una decisión que no queda en el diff, un trade-off, un contrato, un orden de pasos que importa—, es completo, y esa información tiene que vivir en `feature.md`. La cantidad de archivos, tests o comandos **no** decide el nivel: un cambio mecánico en diez archivos puede ser bugfix, y uno de cinco líneas en un guard de auth es completo por la lista de arriba. Ante la duda, el nivel más alto.

Si durante un bugfix aparece un cambio de contrato o de esquema, se detiene y se sube al nivel completo.

El pipeline se dispara igual si el pedido llega por `/sdd-tdd-core:sdd` o en lenguaje natural ("agrega un endpoint…"): la skill `sdd-pipeline` y el hook `UserPromptSubmit` del plugin recuerdan clasificar el nivel antes de tocar archivos, y el `CLAUDE.md` de cada proyecto lo fija como regla.

## 3. Protocolo de artefactos

Los agentes no se pasan rutas: se pasan **referencias de artefacto**. Una referencia es un nombre lógico, `sdd/<change>/<artefacto>`, y el *store* configurado es el que la resuelve a una ubicación concreta. El pipeline se define sobre las referencias; dónde terminan los bytes es decisión del repo, no del proceso.

| Referencia | Artefacto | Lo escribe |
|---|---|---|
| `sdd/<change>/feature` | `feature.md` (lite) | orquestador (esqueleto + `L1`), `explorer`, `proposer`, `designer`, `implementer` (checkbox de `T#`) — cada uno su sección |
| `sdd/<change>/explore` · `proposal` · `spec` · `design` · `tasks` | `00-explore.md` … `04-plan.md` (solo classic) | `explorer`, `proposer`, `spec-writer`, `designer`, `task-planner` |
| `sdd/<change>/apply-progress` | `05-apply-progress.md` | `implementer` |
| `sdd/<change>/verify-report` | `06-verify.md` | `verifier` |
| `sdd/<change>/review` | `07-review.md` (+ `07-review-2.md` en riesgo alto) | `code-reviewer` (dos instancias a ciegas en riesgo alto) |
| `sdd/<change>/security` | `07-security.md` | `security-reviewer` |
| `sdd/<change>/gates` | `gates.md` | el humano, en cada gate |
| `sdd/<change>/close` | `08-close.md` | `archiver` |
| `sdd/<change>/evidence` | `tdd-evidence.log` | hook `post-bash` |
| `sdd/<change>/state` | `<git dir>/sdd-current` (fuera de git, `<raíz>/.current`) | el orquestador al abrir; lo borra el `archiver` |
| `sdd/<change>/level` | `.level` | el orquestador al abrir (`full` \| `bugfix`); lo lee el gatekeeper |

### Stores

`SDD_ARTIFACT_STORE` elige la política; `SDD_ARTIFACTS_DIR` elige dónde se materializan los archivos. Ambos se declaran en `.agentic/sdd-hooks.env` del repo (o el `userConfig` del plugin como fallback).

| Store | Raíz por defecto | Para qué |
|---|---|---|
| `repo` (default) | `docs/sdd/` | Registro versionado y compartido con el equipo. `gates.md` es auditable en el PR |
| `local` | `.agentic/sdd/` | Fuera del registro: el repo queda intacto. Se pierde el compartir con el equipo y la auditoría del gate |
| `engram` | `.agentic/sdd/` | Los artefactos narrativos van a memoria persistente bajo la misma clave `sdd/<change>/<artefacto>`; en disco queda solo lo que los hooks necesitan. Sin memoria conectada degrada a `local` |

**Degradación del store.** `engram` describe una intención, no una garantía: nada en los hooks puede comprobar que un servidor de memoria esté conectado. Antes de la primera fase, el orquestador verifica que las herramientas de memoria estén realmente disponibles. Si no lo están, **cae a `local`, lo dice en una línea y sigue** — nunca aborta el pipeline ni manda artefactos a un destino que no existe. Los hooks son indiferentes a esto: la evidencia y el estado de sesión van al mismo sitio en los tres stores.

**Regla de resolución.** Donde este documento, los agentes, los comandos y las skills dicen `docs/sdd/`, se entiende **la raíz de artefactos configurada**. `docs/sdd/` es su valor por defecto y se usa como nombre en la prosa por legibilidad. Si el `CLAUDE.md` del proyecto declara otra raíz en §0, esa manda; los hooks ya la resuelven solos.

## 3.1. Ciclo de vida

```
<raíz>/
  <NNNN>-<slug>/              change en vuelo (los 9 artefactos + gates.md)
  specs/<capacidad>/spec.md   registro durable, uno por capacidad, se actualiza in place
  _archive/<fecha>-<slug>/    changes cerrados, fuera del camino
  .current                    puntero de compatibilidad (solo checkout principal o fuera de git)
```

El puntero a la carpeta activa es **por worktree** y vive fuera del árbol: `$(git rev-parse --absolute-git-dir)/sdd-current`, un archivo con el nombre `<NNNN>-<slug>`. Cada worktree tiene su propio git dir, así que dos sesiones en paralelo —una por worktree— tienen cada una su feature aunque compartan la raíz de artefactos. `<raíz>/.current` se sigue leyendo como compatibilidad, solo en el checkout principal y solo si no hay puntero; fuera de un repositorio git es el único puntero.

Un change vive en `<NNNN>-<slug>/` (número correlativo; el slug es el mismo de la rama) mientras está en vuelo. Al cerrar, el `archiver` hace dos cosas: **reconcilia** sus specs (`## Specs` de `feature.md`, o `02-spec.md` en classic) contra el spec de la capacidad que toca y **archiva** la carpeta a `_archive/<YYYY-MM-DD>-<slug>/`.

Esto es lo que evita que el registro crezca sin techo. Cien features no dejan cien specs vigentes: dejan las capacidades que el producto realmente tiene, deduplicadas y actualizadas in place, más cien carpetas de historia que nadie necesita leer para entender el sistema hoy. **El registro vivo es `specs/`; `_archive/` es historia.** Un `<NNNN>-<slug>/` suelto en la raíz significa change abierto.

Archivar es mover, nunca borrar: el proceso no poda. La política de retención de `_archive/` la fija cada proyecto; el README del plugin lista las tres opciones razonables y cuál conviene por defecto.

Reglas:
- Cada agente recibe **solo** las referencias de los artefactos previos (resueltas a ruta por el orquestador) y su tarea; nunca el historial de chat ni el cuerpo de un artefacto.
- Cada artefacto empieza con `RESUMEN` (≤ 10 líneas) para el agente siguiente y termina con `DUDAS ABIERTAS`. En lite, cada sección de `feature.md` cierra con sus dudas abiertas en la propia sección, y las que bloquean van al `## Log`.
- Ningún artefacto supera 150 líneas (`feature.md`, 250) salvo `05-apply-progress.md`, que en cambio **rota**: pasadas `SDD_PROGRESS_KEEP_TASKS` tareas (default 10), el detalle viejo se mueve a `05-apply-progress-T<n>-T<m>.md` y el archivo vivo conserva un `RESUMEN ACUMULADO` más las últimas tareas. El `implementer` lo relee en cada tarea; sin rotar el costo crece con el cuadrado de las tareas, y el gatekeeper lo deniega.
- Ningún artefacto contiene datos personales reales, secretos ni identificadores de producción. Los ejemplos son sintéticos. (Hook `guard-pii-artifacts` lo verifica.)
- **Registro durable vs. estado de sesión.** Los artefactos son registro durable y se versionan: justifican el código y los releen `start-session` y `audit-status` meses después. Dos archivos son estado de sesión y **no se versionan**: el puntero a la carpeta activa (`<git dir>/sdd-current`, fuera del árbol por construcción; el `docs/sdd/.current` de compatibilidad sí hay que ignorarlo: commitearlo produce conflicto entre features en paralelo sobre un dato que después no significa nada) y `docs/sdd/**/tdd-evidence.log` (append-only, lo genera un hook, nadie lo lee después del GATE 2 y conflictúa ante cualquier escritura concurrente). Ambos tienen que existir en el working tree durante el pipeline — el `verifier` contrasta contra el log — pero no en el historial. Con store `repo`, el repo adoptante ignora esos dos archivos en su `.gitignore`; con `local` o `engram` ignora la raíz entera y la distinción deja de importar.
- El orquestador no arranca un agente si falta el artefacto previo.
- Cada agente escribe su propio artefacto a disco con `Write` (todos lo tienen en su frontmatter). Si un agente devuelve el contenido en su mensaje final en vez de escribirlo, el orquestador no lo persiste por él: lo relanza indicándole la ruta. El contenido de los artefactos no pasa por el contexto del orquestador.
- `07-review.md` y `07-security.md` son independientes entre sí y del `06-verify.md`; los tres entran juntos al GATE 2.
- `gates.md` registra cada gate: fecha, quién, veredicto (`APROBADO` / `CAMBIOS` / `RECHAZADO`), token explícito y observaciones. Un gate sin registro no ocurrió.

## 3.2. Insumos por fase y gatekeeper

Cada agente declara qué artefactos necesita. La tabla es el contrato: el orquestador no lanza una fase si falta un insumo **requerido**, porque un agente sin su insumo no falla — inventa.

| Fase | Lee (requerido) | Escribe |
|---|---|---|
| `explorer` | — | `explore` |
| `proposer` | `explore` | `proposal` |
| `spec-writer` | `explore`, `proposal` | `spec` |
| `designer` | `explore`, `proposal`, `spec` | `design` |
| `task-planner` | `spec`, `design` | `tasks` |
| `implementer` | `spec`, `design`, `tasks`, `gates` con GATE 1 aprobado | `apply-progress` |
| `verifier` | `spec`, `design`, `tasks`, `apply-progress`, `evidence` | `verify-report` |
| `code-reviewer` | `spec`, `design`, `tasks`, `apply-progress` + diff | `review` |
| `security-reviewer` | `spec`, `design`, `apply-progress` + diff | `security` |
| `archiver` | `gates` + todos los artefactos | `close` |

La tabla de arriba es la de classic. En **lite** el insumo es una sección de `feature.md`, y el gatekeeper lo comprueba por sección:

| Fase (lite) | Requiere en `feature.md` | Además |
|---|---|---|
| todas | `## Log` con `L1` | prompt ≤ `SDD_HANDOFF_MAX_CHARS` (default 2000) salvo el explorer |
| `proposer`, `designer` | `## Exploración` | no corren en `bugfix` |
| `spec-writer`, `task-planner` | — | no corren en lite |
| `implementer` | `## Specs`, `## Tasks` (+ `## Diseño` y GATE 1 en `full`) | el prompt nombra su `T#` |
| `verifier` | `## Specs`, `## Tasks` | `05-apply-progress.md`, `tdd-evidence.log` |
| `code-reviewer`, `security-reviewer` | `## Specs` | `05-apply-progress.md` |
| `archiver` | — | `gates.md` |

En nivel `bugfix` el conjunto se reduce: `implementer` lee `explore`; `verifier` lee `apply-progress` + `evidence`; `code-reviewer` lee `apply-progress`. Las fases de diseño no corren.

**El gatekeeper lo hace cumplir.** El hook `pre-task` (`PreToolUse` / `Task`) intercepta el lanzamiento de cada agente del pipeline, resuelve la feature activa y su nivel, y **deniega** si falta un insumo requerido o si el `implementer` va a correr sin GATE 1 aprobado. Fuera del pipeline no interviene: sin feature activa en el worktree, o con un subagente ajeno, no hace nada.

El nivel se declara en `<raíz>/<feature>/.level` (`full` | `bugfix`); lo escribe el orquestador al crear la carpeta. Ausente equivale a `full`, que es el conjunto más estricto.

## 4. Gates

**GATE 1 — después del `designer` (lite) o del `task-planner` (classic).** El humano aprueba specs, diseño, tareas y tabla de amenazas juntos, porque el plan es lo que se va a ejecutar y el diseño es lo que se va a pagar. Antes del gate solo se escribe documentación; ningún archivo de código. Token: la palabra `acepto`. Sin token no hay implementación. Checklist en `gates/gate-1-design.md`.

**GATE 2 — después de `verifier` PASS, `code-reviewer` sin hallazgos altos (+ `security-reviewer` si corrió).** Contiene solo lo que la máquina no puede decidir: ¿es lo correcto para el producto?, ¿el diff coincide con lo aprobado en GATE 1?, ¿se acepta el riesgo residual?, ¿go/no-go de la migración?, ¿los ADRs quedaron firmados? Un FAIL del `verifier` nunca llega al gate. Checklist en `gates/gate-2-impl.md`.

**GATE 2 automático (`SDD_AUTONOMY=auto`).** El orquestador corre `bash ${CLAUDE_PLUGIN_ROOT}/hooks/gate2-auto.sh` desde el worktree. El script comprueba lo mecánico —verify PASS sobre el HEAD exacto, review `APROBADO`, security sin críticos ni altos con riesgo residual `aceptable` (si corrió), GATE 1 aprobado en nivel `full`, ningún ADR `PROPUESTO` en el diff, ninguna ruta de `SDD_HUMAN_PATHS`, ningún artefacto con `GATE 2: humano`; en lite además: cada `S#` con veredicto PASS en `06-verify.md` y cada `T#` cerrada con su commit; en riesgo alto, `07-review-2.md` APROBADO y `07-security.md`; si el diff cambia `pnpm-lock.yaml` o `go.sum`, la línea `release-age: OK` en `06-verify.md`— y, si todo pasa, registra `GATE 2 · auto · sha: <HEAD>` en `gates.md` (línea exacta: es el contrato que leen el hook y los scripts de merge del proyecto; el detalle va en la línea siguiente). Con ese registro el agente pushea, abre el PR y mergea hacia la rama base sin preguntar; el hook `pre-bash` solo deja pasar `gh pr merge` si el registro corresponde al HEAD actual, así que un commit posterior que toque algo fuera de la raíz de artefactos lo invalida (versionar el propio `gates.md` no). Si el script sale 1, el GATE 2 es humano como en `strict` y se muestran sus motivos. Los disparadores semánticos del proyecto (cutover, cambios de modo, secretos, datos reales…) se declaran en el `CLAUDE.md`; el `proposer` y el `designer` los evalúan y escriben `GATE 2: humano — <motivo>` en su artefacto cuando aplican. Un release desde la rama base nunca es automático. Un PR cuyo diff solo toca documentación de `SDD_DOCS_AUTO_PATHS` (sin ADR ni rutas de `SDD_DOCS_HUMAN_PATHS`) se mergea sin GATE 2 ni SDD; el hook lo comprueba sobre el diff contra la base.

## 5. Modelo por agente (valor por defecto; el proyecto puede subirlo, nunca bajarlo en agentes marcados ⬆)

| Agente | Modelo | Razón |
|---|---|---|
| explorer, spec-writer, task-planner, verifier, archiver | económico | Trabajo estructurado sobre insumos claros |
| proposer, designer ⬆ | capaz | Decisiones con trade-offs y reversibilidad |
| implementer | capaz para tareas de `domain`/`application`; económico para adapters/UI marcados así en el plan | El plan lo fija por tarea |
| code-reviewer ⬆, security-reviewer ⬆ | capaz | Lectura crítica y adversarial de código ajeno; el costo de un falso negativo es alto |

### 5.1. Gasto proporcional al riesgo del diff

Antes de lanzar los revisores, el orquestador corre `bash ${CLAUDE_PLUGIN_ROOT}/hooks/review-plan.sh` desde el worktree. El riesgo sale del diff contra la base, no de la opinión de nadie, y `gate2-auto.sh` lo recalcula igual para exigir lo que corresponde:

| Riesgo | Cuándo | Revisión |
|---|---|---|
| bajo | el diff solo trae tests, documentación (`docs/`, README, CHANGELOG) o artefactos del pipeline | `code-reviewer` con modelo económico (el orquestador pasa `model: sonnet` al lanzarlo); sin `security-reviewer` |
| medio | el resto | `code-reviewer` con su modelo; `security-reviewer` si `## Diseño` tiene amenazas con activo real |
| alto | alguna ruta de `SDD_HIGH_RISK_PATHS` (default auth, security, payments, billing, webhooks, migrations) o de `SDD_HUMAN_PATHS` | **review doble a ciegas**: dos `code-reviewer` en paralelo, cada uno sin ver el resultado del otro, escriben `07-review.md` y `07-review-2.md`; `security-reviewer` obligatorio. Un hallazgo alto vuelve al implementer y se re-juzga; como máximo dos rondas, a la tercera decide el humano |

Bajar el modelo en riesgo bajo es la única excepción a la regla ⬆ de arriba, y la decide el script, no el orquestador.

El modelo de planificación no implementa; el que implementa no se revisa ni se aprueba a sí mismo: `verifier`, `code-reviewer` y `security-reviewer` corren en contextos separados y solo reciben el diff y los artefactos, nunca el razonamiento del `implementer`.

### 5.2. Handoff por referencia

Un subagente recibe **una referencia, nunca una paráfrasis**: la ruta de `feature.md`, su tarea y las specs que cubre.

```
Spec: docs/sdd/0042-alta-pedido/feature.md (lee hasta ## Log). Haz T3; S2, S4.
```

Sin documento (nivel trivial que escaló, o una consulta), el pedido del humano va textual. El agente lee el documento hasta `## Log` inclusive y responde qué `S#` cubrió. El gatekeeper deniega un prompt de más de `SDD_HANDOFF_MAX_CHARS` caracteres (default 2000) en lite —un prompt largo es contenido copiado, que se degrada de fase en fase— y un `implementer` cuyo prompt no nombra su `T#`. Si el humano reporta una falla, el verifier la reproduce antes de que nadie decida que ya funciona.

## 6. Principios

1. **Skills primero.** Antes de escribir, el agente carga las skills de proceso de este core (`strict-tdd`, `delivery-workflow`), las del plugin de stack que apliquen y la skill local de invariantes del proyecto, si existe. La skill local prima sobre el default de los plugins.
2. **Nada se ratifica solo.** Un ADR nace `PROPUESTO` y solo un humano lo pasa a `ACEPTADO`. El `archiver` registra lo firmado; no firma.
3. **No romper lo verde.** Cada tarea deja typecheck, lint y tests en verde. Ese gate corre **al cerrar la tarea**, no dentro del ciclo: en RED/GREEN/TRIANGULATE va el test dirigido al archivo o al caso. Una suite completa con un RED abierto queda marcada con `WARN=full-suite-mid-cycle` y no cuenta como evidencia. Si el safety net falla antes de tocar nada, se reporta como falla preexistente y se para.
4. **Evidencia mecánica.** La evidencia TDD la captura un hook en `tdd-evidence.log`; la tabla del apply-progress la referencia. El `verifier` contrasta la tabla contra el log, no contra la palabra del `implementer`.
5. **Alcance cerrado.** El diff del PR debe corresponder a los archivos previstos en `## Tasks` (lite) o `04-plan.md` (classic) o justificar la diferencia. Scope creep es un FAIL.
6. **Datos personales y secretos fuera del proceso.** Ni en specs, ni en evidencia, ni en memoria, ni en commits, ni en ramas. El `explorer` nunca abre `.env*`, dumps ni seeds con datos reales; reporta que existen, no su contenido.
7. **Producción es de humanos.** Ninguna acción sobre producción sin OK humano explícito que nombre "producción". El hook `guard-prod` fuerza la confirmación.
8. **El PR dice qué, por qué y cómo se verificó.** Nada más (skill `delivery-workflow`). El resto vive en `docs/sdd/`.
