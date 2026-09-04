# ORCHESTRATOR — SDD + Strict TDD

Pipeline de 10 agentes para construir software con especificación verificable, diseño explícito, TDD estricto y dos paradas humanas. Agnóstico de producto y de lenguaje: el contexto de negocio y las invariantes viven en el `CLAUDE.md` y en la skill local de invariantes de cada proyecto; las reglas técnicas (capas, dominio, persistencia, tests, seguridad) las aporta el plugin de stack instalado junto a este core (`stack-typescript` u otro). Este documento define solo el proceso.

## 1. Pipeline

```
explorer → proposer → spec-writer → designer → task-planner → [GATE 1] →
(implementer ⟲ strict-tdd)* → verifier ∥ code-reviewer ∥ security-reviewer → [GATE 2] → merge → archiver
```

| # | Agente | Responsabilidad (una línea) | Artefacto que produce |
|---|---|---|---|
| 1 | `explorer` | Mapa read-only del terreno: qué existe, qué falta, riesgos, insumos faltantes | `00-explore.md` |
| 2 | `proposer` | 1–3 enfoques con reversibilidad y condiciones bloqueantes; ADR nace PROPUESTO | `01-proposal.md` (+ ADR propuesto) |
| 3 | `spec-writer` | Especificación verificable: criterios G/W/T numerados, bordes, contratos, fuera de alcance | `02-spec.md` |
| 4 | `designer` | Diseño por capa con imports declarados, plan de migración, amenazas con test asignado | `03-design.md` |
| 5 | `task-planner` | Tareas atómicas ordenadas con tipo, flag TDD, modelo, criterio de terminado, archivos previstos | `04-plan.md` |
| — | **GATE 1** | Humano aprueba spec + diseño + plan + amenazas con la palabra `acepto` | `gates.md` |
| 6 | `implementer` | Único que escribe código de producción; una tarea por vez; carga el protocolo `strict-tdd` | `05-apply-progress.md` + `tdd-evidence.log` (hook) |
| 7 | `verifier` | Checks mecánicos con salida literal; PASS/FAIL con recomendación por FAIL; no corrige | `06-verify.md` |
| 8 | `code-reviewer` | Revisión de código independiente: fidelidad al diseño, reglas de las skills, calidad de tests, duplicación, deuda; hallazgos por severidad | `07-review.md` |
| 9 | `security-reviewer` | Lectura adversarial del diff (y del diseño si toca auth/pagos/datos personales); riesgo residual | `07-security.md` |
| — | **GATE 2** | Humano decide merge: alcance, producto, riesgo residual, migración | `gates.md` |
| 10 | `archiver` | Post-merge: ADRs ratificados/enmendados, backlog, memoria sin datos personales, próximo paso | `08-close.md` |

`strict-tdd` **no es un agente**: es la skill/protocolo que el `implementer` carga en cada tarea con `TDD: ON`. Separarlo en otro subagente rompería el ciclo RED→GREEN a través de una frontera de contexto.

## 2. Niveles de uso

| Nivel | Cuándo | Recorrido |
|---|---|---|
| Completo | Feature nueva, cambio de esquema, migración, cualquier cosa que toque auth, pagos, datos personales o integraciones | Pipeline entero |
| Bugfix | Defecto acotado con test reproducible, sin cambio de contrato ni de esquema | `explorer` → `implementer` (TDD ON: el test que reproduce el bug es el RED) → `verifier` ∥ `code-reviewer` → GATE 2 |
| Trivial | Typo, comentario, copy, bump de patch sin cambio de API | Sin pipeline; commit directo bajo la skill `delivery-workflow` |

Si durante un bugfix aparece un cambio de contrato o de esquema, se detiene y se sube al nivel completo.

El pipeline se dispara igual si el pedido llega por `/sdd-tdd-core:sdd` o en lenguaje natural ("agrega un endpoint…"): la skill `sdd-pipeline` y el hook `UserPromptSubmit` del plugin recuerdan clasificar el nivel antes de tocar archivos, y el `CLAUDE.md` de cada proyecto lo fija como regla.

## 3. Protocolo de artefactos

Los agentes no se pasan rutas: se pasan **referencias de artefacto**. Una referencia es un nombre lógico, `sdd/<change>/<artefacto>`, y el *store* configurado es el que la resuelve a una ubicación concreta. El pipeline se define sobre las referencias; dónde terminan los bytes es decisión del repo, no del proceso.

| Referencia | Artefacto | Lo escribe |
|---|---|---|
| `sdd/<change>/explore` | `00-explore.md` | `explorer` |
| `sdd/<change>/proposal` | `01-proposal.md` | `proposer` |
| `sdd/<change>/spec` | `02-spec.md` | `spec-writer` |
| `sdd/<change>/design` | `03-design.md` | `designer` |
| `sdd/<change>/tasks` | `04-plan.md` | `task-planner` |
| `sdd/<change>/apply-progress` | `05-apply-progress.md` | `implementer` |
| `sdd/<change>/verify-report` | `06-verify.md` | `verifier` |
| `sdd/<change>/review` | `07-review.md` | `code-reviewer` |
| `sdd/<change>/security` | `07-security.md` | `security-reviewer` |
| `sdd/<change>/gates` | `gates.md` | el humano, en cada gate |
| `sdd/<change>/close` | `08-close.md` | `archiver` |
| `sdd/<change>/evidence` | `tdd-evidence.log` | hook `post-bash` |
| `sdd/<change>/state` | `.current` | el orquestador al abrir; lo borra el `archiver` |
| `sdd/<change>/level` | `.level` | el orquestador al abrir (`full` \| `bugfix`); lo lee el gatekeeper |

### Stores

`SDD_ARTIFACT_STORE` elige la política; `SDD_ARTIFACTS_DIR` elige dónde se materializan los archivos. Ambos se declaran en `.claude/sdd-hooks.env` del repo (o el `userConfig` del plugin como fallback).

| Store | Raíz por defecto | Para qué |
|---|---|---|
| `repo` (default) | `docs/sdd/` | Registro versionado y compartido con el equipo. `gates.md` es auditable en el PR |
| `local` | `.claude/sdd/` | Fuera del registro: el repo queda intacto. Se pierde el compartir con el equipo y la auditoría del gate |
| `engram` | `.claude/sdd/` | Los artefactos narrativos van a memoria persistente bajo la misma clave `sdd/<change>/<artefacto>`; en disco queda solo lo que los hooks necesitan. Sin memoria conectada degrada a `local` |

**Degradación del store.** `engram` describe una intención, no una garantía: nada en los hooks puede comprobar que un servidor de memoria esté conectado. Antes de la primera fase, el orquestador verifica que las herramientas de memoria estén realmente disponibles. Si no lo están, **cae a `local`, lo dice en una línea y sigue** — nunca aborta el pipeline ni manda artefactos a un destino que no existe. Los hooks son indiferentes a esto: la evidencia y el estado de sesión van al mismo sitio en los tres stores.

**Regla de resolución.** Donde este documento, los agentes, los comandos y las skills dicen `docs/sdd/`, se entiende **la raíz de artefactos configurada**. `docs/sdd/` es su valor por defecto y se usa como nombre en la prosa por legibilidad. Si el `CLAUDE.md` del proyecto declara otra raíz en §0, esa manda; los hooks ya la resuelven solos.

## 3.1. Ciclo de vida

```
<raíz>/
  <NNNN>-<slug>/              change en vuelo (los 9 artefactos + gates.md)
  specs/<capacidad>/spec.md   registro durable, uno por capacidad, se actualiza in place
  _archive/<fecha>-<slug>/    changes cerrados, fuera del camino
  .current                    puntero a la carpeta activa (estado de sesión)
```

Un change vive en `<NNNN>-<slug>/` (número correlativo; el slug es el mismo de la rama) mientras está en vuelo. Al cerrar, el `archiver` hace dos cosas: **reconcilia** su `02-spec.md` contra el spec de la capacidad que toca y **archiva** la carpeta a `_archive/<YYYY-MM-DD>-<slug>/`.

Esto es lo que evita que el registro crezca sin techo. Cien features no dejan cien specs vigentes: dejan las capacidades que el producto realmente tiene, deduplicadas y actualizadas in place, más cien carpetas de historia que nadie necesita leer para entender el sistema hoy. **El registro vivo es `specs/`; `_archive/` es historia.** Un `<NNNN>-<slug>/` suelto en la raíz significa change abierto.

Archivar es mover, nunca borrar: la poda de `_archive/` es decisión del proyecto, no del proceso.

Reglas:
- Cada agente recibe **solo** las referencias de los artefactos previos (resueltas a ruta por el orquestador) y su tarea; nunca el historial de chat ni el cuerpo de un artefacto.
- Cada artefacto empieza con `RESUMEN` (≤ 10 líneas) para el agente siguiente y termina con `DUDAS ABIERTAS`.
- Ningún artefacto supera 150 líneas salvo `05-apply-progress.md`.
- Ningún artefacto contiene datos personales reales, secretos ni identificadores de producción. Los ejemplos son sintéticos. (Hook `guard-pii-artifacts` lo verifica.)
- **Registro durable vs. estado de sesión.** Los artefactos son registro durable y se versionan: justifican el código y los releen `start-session` y `audit-status` meses después. Dos archivos son estado de sesión y **no se versionan**: `docs/sdd/.current` (puntero a la carpeta activa, lo crea el `task-planner` y lo borra el `archiver`; commitearlo produce conflicto entre features en paralelo sobre un dato que después no significa nada) y `docs/sdd/**/tdd-evidence.log` (append-only, lo genera un hook, nadie lo lee después del GATE 2 y conflictúa ante cualquier escritura concurrente). Ambos tienen que existir en el working tree durante el pipeline — el `verifier` contrasta contra el log — pero no en el historial. Con store `repo`, el repo adoptante ignora esos dos archivos en su `.gitignore`; con `local` o `engram` ignora la raíz entera y la distinción deja de importar.
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

En nivel `bugfix` el conjunto se reduce: `implementer` lee `explore`; `verifier` lee `apply-progress` + `evidence`; `code-reviewer` lee `apply-progress`. Las fases de diseño no corren.

**El gatekeeper lo hace cumplir.** El hook `pre-task` (`PreToolUse` / `Task`) intercepta el lanzamiento de cada agente del pipeline, resuelve la feature activa y su nivel, y **deniega** si falta un insumo requerido o si el `implementer` va a correr sin GATE 1 aprobado. Fuera del pipeline no interviene: sin `.current` activo, o con un subagente ajeno, no hace nada.

El nivel se declara en `<raíz>/<feature>/.level` (`full` | `bugfix`); lo escribe el orquestador al crear la carpeta. Ausente equivale a `full`, que es el conjunto más estricto.

## 4. Gates

**GATE 1 — después del `task-planner`.** El humano aprueba la spec, el diseño, el plan y la tabla de amenazas juntos, porque el plan es lo que se va a ejecutar y el diseño es lo que se va a pagar. Antes del gate solo se escribe documentación; ningún archivo de código. Token: la palabra `acepto`. Sin token no hay implementación. Checklist en `gates/gate-1-design.md`.

**GATE 2 — después de `verifier` PASS, `code-reviewer` sin hallazgos altos (+ `security-reviewer` si corrió).** Contiene solo lo que la máquina no puede decidir: ¿es lo correcto para el producto?, ¿el diff coincide con lo aprobado en GATE 1?, ¿se acepta el riesgo residual?, ¿go/no-go de la migración?, ¿los ADRs quedaron firmados? Un FAIL del `verifier` nunca llega al gate. Checklist en `gates/gate-2-impl.md`.

## 5. Modelo por agente (valor por defecto; el proyecto puede subirlo, nunca bajarlo en agentes marcados ⬆)

| Agente | Modelo | Razón |
|---|---|---|
| explorer, spec-writer, task-planner, verifier, archiver | económico | Trabajo estructurado sobre insumos claros |
| proposer, designer ⬆ | capaz | Decisiones con trade-offs y reversibilidad |
| implementer | capaz para tareas de `domain`/`application`; económico para adapters/UI marcados así en el plan | El plan lo fija por tarea |
| code-reviewer ⬆, security-reviewer ⬆ | capaz | Lectura crítica y adversarial de código ajeno; el costo de un falso negativo es alto |

El modelo de planificación no implementa; el que implementa no se revisa ni se aprueba a sí mismo: `verifier`, `code-reviewer` y `security-reviewer` corren en contextos separados y solo reciben el diff y los artefactos, nunca el razonamiento del `implementer`.

## 6. Principios

1. **Skills primero.** Antes de escribir, el agente carga las skills de proceso de este core (`strict-tdd`, `delivery-workflow`), las del plugin de stack que apliquen y la skill local de invariantes del proyecto, si existe. La skill local prima sobre el default de los plugins.
2. **Nada se ratifica solo.** Un ADR nace `PROPUESTO` y solo un humano lo pasa a `ACEPTADO`. El `archiver` registra lo firmado; no firma.
3. **No romper lo verde.** Cada tarea deja typecheck, lint y tests en verde. Si el safety net falla antes de tocar nada, se reporta como falla preexistente y se para.
4. **Evidencia mecánica.** La evidencia TDD la captura un hook en `tdd-evidence.log`; la tabla del apply-progress la referencia. El `verifier` contrasta la tabla contra el log, no contra la palabra del `implementer`.
5. **Alcance cerrado.** El diff del PR debe corresponder a los archivos previstos en `04-plan.md` o justificar la diferencia. Scope creep es un FAIL.
6. **Datos personales y secretos fuera del proceso.** Ni en specs, ni en evidencia, ni en memoria, ni en commits, ni en ramas. El `explorer` nunca abre `.env*`, dumps ni seeds con datos reales; reporta que existen, no su contenido.
7. **Producción es de humanos.** Ninguna acción sobre producción sin OK humano explícito que nombre "producción". El hook `guard-prod` fuerza la confirmación.
8. **El PR dice qué, por qué y cómo se verificó.** Nada más (skill `delivery-workflow`). El resto vive en `docs/sdd/`.
