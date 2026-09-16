# sdd-tdd-core

Proceso de desarrollo guiado por especificación con Strict TDD, **agnóstico de lenguaje**. Aporta 10 agentes, 2 gates humanos, un protocolo de artefactos en disco, comandos de sesión, tres skills de proceso y guardrails por hooks.

Este plugin define **cómo se trabaja**. Las reglas técnicas del lenguaje (capas, dominio, persistencia, tests, seguridad) las aporta un plugin de stack instalado junto a este — `stack-typescript` u otro. El contexto de negocio y las invariantes viven en el `{{CONTEXT_DOC}}` y en la skill local de invariantes de cada proyecto.

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
{{CONFIG_FILE}} del proyecto   →   userConfig del plugin   →   default
        (manda)                              (fallback)
```

El archivo del proyecto se versiona y es la fuente de verdad para ese repo. El `userConfig` existe para instalaciones a nivel de usuario compartidas por varios repos. Plantilla en [`templates/sdd-hooks.env`](templates/sdd-hooks.env).

**Qué repositorio es "el proyecto".** No la raíz de la sesión: la sesión puede abrirse en una carpeta que contiene varios repositorios, y ahí no hay configuración que cargar. Cada hook se ancla en lo que la herramienta está tocando y sube hasta el primer directorio con `{{CONFIG_FILE}}` y, si no hay ninguno, con `.git` (worktrees y submódulos resuelven a su propia raíz). Las anclas, por orden: el `file_path` del Write/Edit, la primera ruta absoluta del comando en un Bash —heurística, solo se acepta dentro del árbol de la sesión—, el `cwd` del payload y, al final, la raíz de la sesión. Así la configuración que se carga y la evidencia que se escribe son siempre las del repositorio del cambio.

| Clave | `userConfig` | Default | Efecto |
|---|---|---|---|
| `SDD_ARTIFACT_STORE` | `artifact_store` | `repo` | Política del store de artefactos: `repo`, `local` o `engram`. Ver `ORCHESTRATOR.md` §3 |
| `SDD_ARTIFACTS_DIR` | `artifacts_dir` | `docs/sdd` con `repo`, `{{LOCAL_STORE}}` con el resto | Raíz donde se materializan los archivos. Relativa al proyecto, absoluta o con `~` |
| `SDD_BASE_BRANCH` | `base_branch` | `develop` | Rama base del proyecto. El hook pide confirmación ante push directo a ella, y ante merge/rebase que la involucre |
| `SDD_PROD_MARKERS` | `prod_markers` | vacío | Regex extendida (`grep -E`) que identifica un comando como dirigido a producción. Se suma a los patrones genéricos de deploy y migración |
| `SDD_TENANT_FIELD` | `tenant_field` | vacío | Campo de tenant. Activa los checks de DTOs sin tenant y de RLS en migraciones. Vacío = single-tenant, checks apagados |
| `SDD_TEST_CMD_RE` | `test_cmd_re` | multi-stack | Regex que reconoce una corrida de tests para la evidencia TDD. El default cubre vitest, jest, mocha, tsc, phpunit, pest, artisan test, phpstan, pytest, mypy, go test, cargo test, dotnet test, mvn, gradle, swift test, xcodebuild |
| `SDD_PROGRESS_KEEP_TASKS` | `progress_keep_tasks` | `10` | Tareas cuyo detalle conserva `05-apply-progress.md` antes de rotar. El `implementer` lo relee en cada tarea; pasado el umbral el gatekeeper deniega hasta rotar |
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
| `{{CMD_PREFIX}}sdd` | `<objetivo> [--level=full\|bugfix]` | Ejecuta el pipeline agente por agente, con paradas en los gates |
| `{{CMD_PREFIX}}adopt` | `[--base=] [--store=] [--tenant=] [--prod=] [--skip-pilot]` | Adopta el estándar en el repo actual: 9 pasos, 4 checkpoints humanos |
| `{{CMD_PREFIX}}start-session` | `[área]` | Lee el estado local ({{CONTEXT_DOC}}, ADRs, backlog, último cierre) antes de tocar código |
| `{{CMD_PREFIX}}end-session` | — | Resumen, commits de lo que está en verde, clasificación de hallazgos |
| `{{CMD_PREFIX}}check-arch` | — | Typecheck + lint + tests + audit; reporta sin corregir |
| `{{CMD_PREFIX}}audit-status` | `[foco]` | Auditoría read-only del código real contra el plan documentado |
| `{{CMD_PREFIX}}new-adr` | `[contexto]` | ADR con plantilla canónica, en estado `PROPUESTO` |
| `{{CMD_PREFIX}}pr-draft` | `[ruta docs/sdd/]` | PR con la única plantilla permitida: Qué cambia · Por qué · Verificación |

---

## Skills

| Skill | Cuándo la carga el agente |
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
| `post-bash.sh` | `PostToolUse` + `PostToolUseFailure` / `Bash` | Registra evidencia TDD; verifica identidad y trailers del commit |
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
2026-09-04T01:14:02Z | exit=1 | pnpm vitest run order.spec.ts | Tests 1 failed (1) Test Files 1 failed (1)
2026-09-04T01:16:30Z | exit=0 | pnpm vitest run order.spec.ts && cat > notas.md <<'EOF' … | Tests 1 passed (1) | WARN=call-failed-outside-tests
```

El hook está registrado en `PostToolUse` y en `PostToolUseFailure`: el harness entrega el primero cuando la llamada Bash termina en 0 y el segundo cuando falla, con el exit code y la salida (stdout y stderr mezclados, recortada a unos 10 000 caracteres desde el principio). Así el RED del ciclo —la segunda línea— queda con su código y su resumen reales.

Ninguno de los dos trae el exit code del runner: el payload exitoso no trae ninguno, y el de la llamada fallida es el del comando entero. El hook decide en este orden: el resumen del runner (`N failed` ⇒ rojo; `N passed` sin fallos ⇒ verde), después el evento, y solo si el payload no dice de qué evento viene, una inferencia por palabras. Esa inferencia ya no mira `Error:` ni `ERR_` —los imprime cualquier suite verde que pruebe caminos de error—, y las líneas JSON de log quedan fuera tanto del resumen como de la decisión. El resumen manda sobre el evento porque `<test>; echo $?` sale 0 con los tests en rojo.

Ese exit code es el de la llamada entera, no el de los tests. La tercera línea es una corrida verde encadenada con una escritura que falló por `noclobber`: si el runner reporta tests ejecutados y ninguno rojo, la llamada fallida se registra `exit=0` con `WARN=call-failed-outside-tests`; si no hay rastro del runner, `WARN=no-tests-ran`; si la salida se recortó antes del resumen, `WARN=output-truncated`. Por eso una corrida de tests va sola en su llamada, y toda escritura por heredoc usa `>|` (`cat >| archivo <<'EOF'`), que ignora `noclobber`.

Si no llega ningún evento, queda la marca que `PreToolUse` deja antes de lanzar cada corrida en `<raíz>/<feature>/.tdd-pending/<tool_use_id>`, y se registra como `exit=!0 | … | sin salida capturada | WARN=resultado-inferido-por-ausencia-de-PostToolUse`. `pre-bash` concilia solo las marcas más viejas que el timeout máximo de Bash —una llamada en paralelo puede seguir corriendo— y el `UserPromptSubmit` del turno, todas.

Con secretos y emails redactados por patrón, y estas marcas de sospecha: `WARN=piped-output` si la salida se filtró por un pipe, `WARN=output-truncated` si el harness recortó la salida de una llamada fallida antes del resumen del runner, `WARN=interrupted` si la corrida se cortó, `WARN=no-tests-ran` si el runner salió en verde sin ejecutar un solo test (filtro `-t` mal escrito, todo skipped, "No test files found"), `WARN=backgrounded` si la llamada pasó a background —el evento llega al pasar, no al terminar, y el resultado real no llega nunca: la línea queda `exit=?` y no es ni RED ni GREEN—, `WARN=compile-error` si el rojo es de compilación y ningún caso llegó a ejecutarse (`strict-tdd` §3), y `WARN=full-suite-mid-cycle` si se corrió la suite completa con un RED abierto — la suite es del cierre de tarea y del `verifier`, no del ciclo interno, y cuesta unas 3× más por corrida. El `verifier` contrasta la tabla del apply-progress contra este log.

Este log, `docs/sdd/.current`, `<feature>/.tdd-pending` y `docs/sdd/.hook-errors.log` (donde los hooks anotan un payload que no pudieron leer, en vez de salir en silencio) son **estado de sesión: no se versionan** (`/adopt` los agrega al `.gitignore` del repo). El resto de los artefactos sí — ver `ORCHESTRATOR.md` §3.

### Límites conocidos de los detectores

Los guardrails son regex sobre el contenido que el agente va a escribir. Cubren bien lo que reconocen y **no ven nada fuera de eso**. Conviene saber exactamente dónde está el borde antes de confiarles material sensible.

**Secretos** — se aplica a todo archivo salvo `.env.example|sample|template` y el log de evidencia. Reconoce cinco formas:

| Detecta | No detecta |
|---|---|
| `sk-…` (16+ chars) · JWT `eyJ….…` · `postgres://user:pass@…` · `AKIA…` · `-----BEGIN … PRIVATE KEY-----` | Tokens de GitHub (`ghp_`, `gho_`), de Slack (`xox…`), API keys hexadecimales genéricas, bearer sin prefijo `eyJ`, connection strings de MySQL, Mongo o Redis, credenciales en query string |

**Datos personales** — se aplica solo a rutas `docs/`, `fixtures/`, `seeds/`, archivos de test y todo `.md`:

| Detecta | No detecta |
|---|---|
| Emails que no sean `@example.com/org/net`, `@test.local` o `@localhost` · Teléfonos en formato internacional (`+` y 8–15 dígitos) | Nombres y apellidos, direcciones, documentos nacionales (RUT, DNI, CUIT, CPF, NIF), tarjetas, fechas de nacimiento, IPs, **teléfonos en formato local** (`11 5555-5555` no matchea) |

**Corridas de tests** — `SDD_TEST_CMD_RE` reconoce los runners de cada stack y los comandos agregados de gate (`pnpm|npm|yarn|bun|turbo` + `test`, `check`, `verify`, `validate`, `run ci`). `npm ci` queda fuera a propósito: instala dependencias. Un alias propio (`pnpm gate`, `make qa`) no se reconoce sin declarar `SDD_TEST_CMD_RE` en `{{CONFIG_FILE}}`. El cuerpo de un heredoc no se evalúa: escribir prosa que menciona `vitest` dentro de un `<<EOF` no cuenta como corrida.

Hoy ampliarlos requiere editar `hooks/common.sh` (`SECRET_RE`, `PHONE_RE`) en una copia del plugin: no hay clave de configuración para patrones propios. Si tu proyecto maneja documentos nacionales o teléfonos locales, es el primer lugar donde mirar.

Y hay una categoría que los detectores **no intentan** cubrir, por diseño: `00-explore.md` y `03-design.md` describen tu esquema real, tus endpoints y tus reglas de negocio. Eso no es PII, es propiedad intelectual del producto, y es exactamente para lo que esos artefactos existen. En un repo privado está bien; tenelo presente antes de hacer público un repo que los versiona, porque git es append-only y borrarlos después no los saca del historial.

---

## Ciclo de vida de los artefactos

```
<raíz>/
  <NNNN>-<slug>/              change en vuelo
  specs/<capacidad>/spec.md   registro durable, uno por capacidad, in place
  _archive/<fecha>-<slug>/    changes cerrados
```

Al cerrar, el `archiver` reconcilia el `02-spec.md` del change contra el spec de la **capacidad** que toca y mueve la carpeta a `_archive/<YYYY-MM-DD>-<slug>/`. Cien features no dejan cien specs vigentes: dejan las capacidades que el producto tiene, deduplicadas, más historia fuera del camino. El registro vivo es `specs/`; un `<NNNN>-<slug>/` suelto en la raíz significa change abierto.

**Retención de `_archive/`.** Archivar es mover, nunca borrar: el plugin no poda. La política la fija cada proyecto, y las opciones razonables son tres — dejarlo crecer (son archivos de texto, cuestan poco y git ya los comprime), podar por antigüedad conservando `gates.md` y `06-verify.md` de cada change (el registro de auditoría y la evidencia de verificación), o borrar la carpeta entera confiando en que el spec de capacidad y el historial de git ya guardan lo que importa. La primera es el default sensato hasta que el repo demuestre lo contrario.

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
| `implementer` | + `05-apply-progress.md` con ≤ `SDD_PROGRESS_KEEP_TASKS` tareas sin rotar |
| `archiver` | `gates` |

En nivel `bugfix` (declarado en `<feature>/.level`) el conjunto se reduce y las fases de diseño quedan denegadas por no pertenecer al recorrido. Sin feature activa el hook no interviene.

---

## Tests

```bash
bash plugins/sdd-tdd-core/tests/e2e.sh
```

68 aserciones contra un repositorio git descartable que la suite crea y borra sola. Invoca cada hook con el mismo payload JSON que le manda {{AGENT_NAME}}, así que ejercita el camino real y no una simulación: resolución de la raíz de artefactos en sus seis formas, la cadena completa de insumos del gatekeeper, los cuatro veredictos del GATE 1, el recorrido reducido de `bugfix`, los guardrails de secretos, PII, shell y git, la evidencia TDD capturada de una corrida de tests real, y el cierre con reconciliación de capacidad y archivado.

Solo necesita `bash`, `git` y `jq`; si además hay `node`, la evidencia sale de una corrida real en vez de un payload equivalente. Sale 0 si todo pasa, 1 si algo falla. Corre en CI en cada push y PR, junto a `bash -n` y `shellcheck` sobre los seis hooks.

---

## Plantillas

| Plantilla | Destino |
|---|---|
| `templates/{{CONTEXT_DOC}}` | `{{CONTEXT_DOC}}` del proyecto: fuentes de verdad, stack, mapa de contextos, invariantes, comandos, git |
| `templates/sdd-hooks.env` | `{{CONFIG_FILE}}` |
| `templates/invariants-skill/SKILL.md` | `{{SKILLS_DIR}}/<producto>-invariants/SKILL.md` |
| `templates/pull_request_template.md` | `.github/pull_request_template.md` |

---

## Licencia

[MIT](../../LICENSE) © Jorge Diaz
