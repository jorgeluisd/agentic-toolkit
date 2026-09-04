# sdd-tdd-core

Proceso de desarrollo guiado por especificación con Strict TDD, **agnóstico de lenguaje**. Aporta 10 agentes, 2 gates humanos, un protocolo de artefactos en disco, comandos de sesión, tres skills de proceso y guardrails por hooks.

Este plugin define **cómo se trabaja**. Las reglas técnicas del lenguaje (capas, dominio, persistencia, tests, seguridad) las aporta un plugin de stack instalado junto a este — `stack-typescript` u otro. El contexto de negocio y las invariantes viven en el `CLAUDE.md` y en la skill local de invariantes de cada proyecto.

> El proceso completo está especificado en **[`ORCHESTRATOR.md`](ORCHESTRATOR.md)**. Este README es la referencia de instalación, configuración e inventario.

---

## Instalación

```bash
claude plugin marketplace add jorgeluisd/agentic-toolkit
claude plugin install sdd-tdd-core@agentic-toolkit
```

Requiere `bash`, `git` y [`jq`](https://jqlang.github.io/jq/) en el `PATH`: los hooks son scripts de shell que parsean el JSON del harness con `jq`.

---

## Configuración

Los valores que el plugin no puede adivinar, resueltos en este orden:

```
.claude/sdd-hooks.env del proyecto   →   userConfig del plugin   →   default
        (manda)                              (fallback)
```

El archivo del proyecto se versiona y es la fuente de verdad para ese repo. El `userConfig` existe para instalaciones a nivel de usuario compartidas por varios repos. Plantilla en [`templates/sdd-hooks.env`](templates/sdd-hooks.env).

| Clave | `userConfig` | Default | Efecto |
|---|---|---|---|
| `SDD_ARTIFACT_STORE` | `artifact_store` | `repo` | Política del store de artefactos: `repo`, `local` o `engram`. Ver `ORCHESTRATOR.md` §3 |
| `SDD_ARTIFACTS_DIR` | `artifacts_dir` | `docs/sdd` con `repo`, `.claude/sdd` con el resto | Raíz donde se materializan los archivos. Relativa al proyecto, absoluta o con `~` |
| `SDD_BASE_BRANCH` | `base_branch` | `develop` | Rama base del proyecto. El hook pide confirmación ante push directo a ella, y ante merge/rebase que la involucre |
| `SDD_PROD_MARKERS` | `prod_markers` | vacío | Regex extendida (`grep -E`) que identifica un comando como dirigido a producción. Se suma a los patrones genéricos de deploy y migración |
| `SDD_TENANT_FIELD` | `tenant_field` | vacío | Campo de tenant. Activa los checks de DTOs sin tenant y de RLS en migraciones. Vacío = single-tenant, checks apagados |
| `SDD_TEST_CMD_RE` | `test_cmd_re` | multi-stack | Regex que reconoce una corrida de tests para la evidencia TDD. El default cubre vitest, jest, mocha, tsc, phpunit, pest, artisan test, phpstan, pytest, mypy, go test, cargo test, dotnet test, mvn, gradle, swift test, xcodebuild |
| `SDD_COMMENT_MAX_BLOCK` | `comment_max_block` | `4` | Bloque contiguo máximo de comentario en código fuente |
| `SDD_COMMENT_MAX_PCT` | `comment_max_pct` | `15` | Porcentaje máximo de líneas comentadas por archivo |

---

## Los 10 agentes

Cada agente corre en su propio contexto y recibe **solo** las referencias de los artefactos previos (`sdd/<change>/<artefacto>`) y su tarea, nunca el historial de chat. El store configurado resuelve cada referencia; ver `ORCHESTRATOR.md` §3.

| # | Agente | Responsabilidad | Artefacto |
|---|---|---|---|
| 1 | `explorer` | Mapa read-only del terreno: qué existe, qué falta, riesgos | `00-explore.md` |
| 2 | `proposer` | 1–3 enfoques con reversibilidad; ADR nace `PROPUESTO` | `01-proposal.md` |
| 3 | `spec-writer` | Criterios G/W/T numerados, bordes, contratos, fuera de alcance | `02-spec.md` |
| 4 | `designer` | Diseño por capa con imports declarados, plan de migración, amenazas | `03-design.md` |
| 5 | `task-planner` | Tareas atómicas con tipo, flag TDD, modelo y criterio de terminado | `04-plan.md` |
| 6 | `implementer` | Único que escribe código de producción; una tarea por vez | `05-apply-progress.md` |
| 7 | `verifier` | Checks mecánicos con salida literal; PASS/FAIL. No corrige | `06-verify.md` |
| 8 | `code-reviewer` | Fidelidad al diseño, reglas de skills, calidad de tests, deuda | `07-review.md` |
| 9 | `security-reviewer` | Lectura adversarial del diff; riesgo residual | `07-security.md` |
| 10 | `archiver` | Post-merge: ADRs, backlog, memoria, próximo paso | `08-close.md` |

El que planifica no implementa; el que implementa no se revisa a sí mismo. `verifier`, `code-reviewer` y `security-reviewer` reciben el diff y los artefactos, nunca el razonamiento del `implementer`.

`strict-tdd` **no es un agente**: es la skill que el `implementer` carga en cada tarea con `TDD: ON`. Separarla en otro subagente rompería el ciclo RED→GREEN a través de una frontera de contexto.

---

## Comandos

| Comando | Argumentos | Qué hace |
|---|---|---|
| `/sdd-tdd-core:sdd` | `<objetivo> [--level=full\|bugfix]` | Ejecuta el pipeline agente por agente, con paradas en los gates |
| `/sdd-tdd-core:adopt` | `[--base=] [--store=] [--tenant=] [--prod=] [--skip-pilot]` | Adopta el estándar en el repo actual: 9 pasos, 4 checkpoints humanos |
| `/sdd-tdd-core:start-session` | `[área]` | Lee el estado local (CLAUDE.md, ADRs, backlog, último cierre) antes de tocar código |
| `/sdd-tdd-core:end-session` | — | Resumen, commits de lo que está en verde, clasificación de hallazgos |
| `/sdd-tdd-core:check-arch` | — | Typecheck + lint + tests + audit; reporta sin corregir |
| `/sdd-tdd-core:audit-status` | `[foco]` | Auditoría read-only del código real contra el plan documentado |
| `/sdd-tdd-core:new-adr` | `[contexto]` | ADR con plantilla canónica, en estado `PROPUESTO` |
| `/sdd-tdd-core:pr-draft` | `[ruta docs/sdd/]` | PR con la única plantilla permitida: Qué cambia · Por qué · Verificación |

---

## Skills

| Skill | Cuándo la carga Claude |
|---|---|
| `sdd-pipeline` | Ante cualquier pedido de implementar, agregar, crear, cambiar, arreglar o migrar código — **aunque no se invoque ningún comando** |
| `strict-tdd` | Al implementar una tarea con TDD ON, o al auditar su evidencia. Protocolo RED-GREEN-TRIANGULATE-REFACTOR de 7 fases |
| `delivery-workflow` | Al commitear, abrir un PR o tocar CI. **Única fuente de verdad** de commits, ramas, PR y CI |

---

## Hooks

Seis scripts en `hooks/`, registrados en [`hooks.json`](hooks/hooks.json). Corren en cada tool call y no dependen de que el agente coopere.

| Hook | Evento | Qué hace |
|---|---|---|
| `pre-bash.sh` | `PreToolUse` / `Bash` | Guardrails de producción y git antes de ejecutar |
| `post-bash.sh` | `PostToolUse` / `Bash` | Registra evidencia TDD; verifica identidad y trailers del commit |
| `pre-file.sh` | `PreToolUse` / `Read\|Edit\|Write\|MultiEdit` | Bloquea antes de que nada toque el disco |
| `post-file.sh` | `PostToolUse` / `Edit\|Write\|MultiEdit` | Devuelve el problema al agente para que corrija |
| `pre-task.sh` | `PreToolUse` / `Task` | **Gatekeeper de fases**: deniega el lanzamiento de un agente si le falta un insumo requerido |
| `user-prompt.sh` | `UserPromptSubmit` | Inyecta el recordatorio de clasificar el nivel SDD. Nunca bloquea |

### Denegado (`deny`)

`git push --force` sin `--force-with-lease` · `--no-verify` · commits con atribución de IA · leer o editar `.env*` · secretos o datos personales no sintéticos en artefactos, docs, fixtures y tests · filtrar la salida de tests con `| tail`/`| grep` · `npm`/`yarn` en repos con `pnpm-lock.yaml` · aprobación masiva de scripts de instalación · exceso de comentarios · migraciones destructivas, `SET NOT NULL` sin default, tabla con tenant sin `FORCE ROW LEVEL SECURITY`, `SECURITY DEFINER` sin `search_path`, `GRANT` a `anon`/`PUBLIC`.

### Confirmación humana (`ask`)

Comandos que parecen dirigidos a producción · push directo a la rama base · merge/rebase sobre ramas base · comandos destructivos sobre el árbol o ramas · `git commit -a` · `rm -rf` sobre rutas amplias · lectura de dumps, seeds o archivos de credenciales.

### Evidencia TDD

Cada corrida de tests se registra en `<raíz>/<feature>/tdd-evidence.log`:

```
2026-09-04T01:12:44Z | exit=0 | pnpm test orders | Tests 12 passed (12) Test Files 3 passed
```

Con secretos y emails redactados por patrón, y dos marcas de sospecha: `WARN=piped-output` si la salida se filtró por un pipe, y `WARN=no-tests-ran` si el runner salió en verde sin ejecutar un solo test (filtro `-t` mal escrito, todo skipped, "No test files found"). El `verifier` contrasta la tabla del apply-progress contra este log.

Este log y `docs/sdd/.current` son **estado de sesión: no se versionan** (`/adopt` los agrega al `.gitignore` del repo). El resto de los artefactos sí — ver `ORCHESTRATOR.md` §3.

---

## Ciclo de vida de los artefactos

```
<raíz>/
  <NNNN>-<slug>/              change en vuelo
  specs/<capacidad>/spec.md   registro durable, uno por capacidad, in place
  _archive/<fecha>-<slug>/    changes cerrados
```

Al cerrar, el `archiver` reconcilia el `02-spec.md` del change contra el spec de la **capacidad** que toca y mueve la carpeta a `_archive/<YYYY-MM-DD>-<slug>/`. Cien features no dejan cien specs vigentes: dejan las capacidades que el producto tiene, deduplicadas, más historia fuera del camino. El registro vivo es `specs/`; un `<NNNN>-<slug>/` suelto en la raíz significa change abierto.

## Gatekeeper de fases

El hook `pre-task` intercepta cada lanzamiento de agente y deniega si falta un insumo. La tabla completa está en `ORCHESTRATOR.md` §3.2; en resumen:

| Fase | Requiere |
|---|---|
| `proposer` | `explore` |
| `spec-writer` | `explore`, `proposal` |
| `designer` | `explore`, `proposal`, `spec` |
| `task-planner` | `spec`, `design` |
| `implementer` | `spec`, `design`, `tasks` **y GATE 1 aprobado** |
| `verifier` | + `apply-progress`, `evidence` |
| `code-reviewer` / `security-reviewer` | los artefactos de diseño + `apply-progress` |
| `archiver` | `gates` |

En nivel `bugfix` (declarado en `<feature>/.level`) el conjunto se reduce y las fases de diseño quedan denegadas por no pertenecer al recorrido. Sin feature activa el hook no interviene.

---

## Tests

```bash
bash plugins/sdd-tdd-core/tests/e2e.sh
```

53 aserciones contra un repositorio git descartable que la suite crea y borra sola. Invoca cada hook con el mismo payload JSON que le manda Claude Code, así que ejercita el camino real y no una simulación: resolución de la raíz de artefactos en sus seis formas, la cadena completa de insumos del gatekeeper, los cuatro veredictos del GATE 1, el recorrido reducido de `bugfix`, los guardrails de secretos, PII, shell y git, la evidencia TDD capturada de una corrida de tests real, y el cierre con reconciliación de capacidad y archivado.

Solo necesita `bash`, `git` y `jq`; si además hay `node`, la evidencia sale de una corrida real en vez de un payload equivalente. Sale 0 si todo pasa, 1 si algo falla. Corre en CI en cada push y PR, junto a `bash -n` y `shellcheck` sobre los seis hooks.

---

## Plantillas

| Plantilla | Destino |
|---|---|
| `templates/CLAUDE.md` | `CLAUDE.md` del proyecto: fuentes de verdad, stack, mapa de contextos, invariantes, comandos, git |
| `templates/sdd-hooks.env` | `.claude/sdd-hooks.env` |
| `templates/invariants-skill/SKILL.md` | `.claude/skills/<producto>-invariants/SKILL.md` |
| `templates/pull_request_template.md` | `.github/pull_request_template.md` |

---

## Licencia

[MIT](../../LICENSE) © Jorge Diaz
