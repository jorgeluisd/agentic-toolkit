# agentic-toolkit

Proceso para desarrollar software con **SDD (Spec-Driven Development) + Strict TDD**: una especificación verificable antes del diseño, un diseño explícito antes del código, TDD estricto durante la implementación y dos paradas humanas obligatorias antes de mergear.

No es una colección de prompts. Es un proceso con artefactos en disco, fases con contextos separados, evidencia mecánica de que los tests corrieron y guardrails por hooks que bloquean lo que no debería pasar.

**Corre en [Claude Code](https://claude.com/claude-code), [Codex CLI](https://developers.openai.com/codex), [OpenCode](https://opencode.ai) y [Devin](https://devin.ai).** El proceso se escribe una vez y se compila al empaquetado nativo de cada uno; qué funciona igual y qué se degrada en cada agente está en **[`PORTABILITY.md`](PORTABILITY.md)**.

---

## Los plugins

El toolkit separa **el proceso** (agnóstico de lenguaje) de **las reglas técnicas** (propias de cada stack).

| Plugin | Qué aporta | Cuándo instalarlo |
|---|---|---|
| **`sdd-tdd-core`** | 10 agentes, 2 gates humanos, protocolo de artefactos con gatekeeper de fases, comandos de sesión, skills de proceso (`sdd-pipeline`, `strict-tdd`, `delivery-workflow`) y guardrails por hooks | **Siempre.** Funciona con cualquier lenguaje |
| **`stack-typescript`** | 12 skills técnicas para TypeScript: Onion + Screaming Architecture, dominio puro, CQRS, Result, Drizzle/Postgres, multi-tenancy con RLS, Vitest, seguridad, pino, Next.js, PWA con React + Vite, dependencias con pnpm. Plantillas de `settings.json`, CI y commitlint | En proyectos TypeScript |
| **`stack-go`** | 12 skills técnicas para Go en Lambda: Onion + Screaming Architecture con depguard y archtest, dominio puro, errores tipados, commands y queries, sqlc + pgx sobre Aurora DSQL, multi-tenancy sin RLS, chi + JWT de Cognito, `go test`, seguridad, slog, Go modules, contrato OpenAPI con oapi-codegen. Plantillas validadas de CI, golangci-lint, `settings.json` y paquetes base | En proyectos Go |

El core no sabe nada de tu lenguaje: pregunta por comandos simbólicos (`<test>`, `<lint>`, `<typecheck>`) que resuelve el documento de contexto de tu proyecto (`CLAUDE.md` o `AGENTS.md`) o el plugin de stack. Si trabajás en PHP o Python, instalá solo el core y declará tus comandos — o escribí tu propio plugin de stack ([ver abajo](#extender-tu-propio-plugin-de-stack)).

---

## Requisitos

- Uno de: **Claude Code**, **Codex CLI**, **OpenCode** o **Devin**.
- **`bash`**, **`git`** y **[`jq`](https://jqlang.github.io/jq/)** en el `PATH`. Los hooks son scripts de shell que parsean JSON con `jq`; sin `jq` los guardrails no corren.
- macOS o Linux. En Windows, WSL.

```bash
jq --version   # si no está: brew install jq · apt install jq
```

---

## Instalación

### Claude Code

```bash
claude plugin marketplace add jorgeluisd/agentic-toolkit
claude plugin install sdd-tdd-core@agentic-toolkit
claude plugin install stack-typescript@agentic-toolkit   # solo en proyectos TypeScript
claude plugin install stack-go@agentic-toolkit           # solo en proyectos Go
```

Por defecto la instalación es de usuario (`--scope user`): los plugins quedan disponibles en todos tus repos. Para atarlos a un proyecto, `--scope project`.

Desde dentro de Claude Code, el equivalente interactivo es `/plugin`.

<details>
<summary>Alternativa: declararlo en <code>settings.json</code></summary>

Útil para versionar la configuración de un equipo en `.claude/settings.json`, o para dejarla fija en `~/.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "agentic-toolkit": {
      "source": { "source": "github", "repo": "jorgeluisd/agentic-toolkit" }
    }
  },
  "enabledPlugins": {
    "sdd-tdd-core@agentic-toolkit": true,
    "stack-typescript@agentic-toolkit": true
  }
}
```
</details>

Verificá que quedaron activos:

```bash
claude plugin list
```

### Codex CLI · OpenCode · Devin

Cloná el repositorio y corré el instalador del agente que uses. La salida ya viene
compilada y commiteada: no hace falta build ni Node en tu máquina.

```bash
git clone https://github.com/jorgeluisd/agentic-toolkit
cd agentic-toolkit

bash dist/codex/install.sh    /ruta/a/tu/repo   # Codex CLI
bash dist/opencode/install.sh /ruta/a/tu/repo   # OpenCode
bash dist/devin/install.sh    /ruta/a/tu/repo   # Devin
```

Cada instalador copia el core y **un** plugin de stack. Lo detecta por los archivos
del repositorio (`go.mod` → `stack-go`, `package.json` → `stack-typescript`), o se
elige con `--stack=go`, `--stack=typescript` o `--stack=none`. Si el repositorio
tiene los dos archivos, pide elegir: en estos agentes las skills van a una sola
carpeta y los dos stacks repiten nombres (`domain-modeling`, `testing-conventions`).
En Claude Code no hace falta elegir, porque cada plugin tiene su propio espacio de
nombres.

En los tres casos queda un paso manual: pegar el contenido del `AGENTS.md` generado
(`dist/<agente>/AGENTS.md`) en el `AGENTS.md` de tu repositorio. El instalador de
Devin lo crea si el repositorio no tiene uno.

#### Devin

Devin no tiene plugins: lee `.agents/` y `AGENTS.md` del repositorio, y los
playbooks y el Knowledge se cargan desde su web. Después del instalador:

1. Commiteá `.agents/`, `.agentic/` y `AGENTS.md`.
2. Subí los 8 playbooks de `dist/devin/playbooks/*.devin.md` a Devin (arrastrarlos
   al iniciar una sesión, o crearlos en la web). Son los comandos del toolkit.
3. Opcional: cargá las 3 entradas de `dist/devin/knowledge/` y las 12 del stack
   (`dist/devin/stacks/<stack>/knowledge/`) en el Knowledge de Devin. El *trigger* de cada una es la línea "Cuándo aplica".

Qué se degrada sin hooks ni subagentes está en `dist/devin/README.md` y en
[`PORTABILITY.md`](PORTABILITY.md#devin).

---

## Configuración

El core lee unos pocos valores que no puede adivinar. Se pueden declarar en dos lugares, y **el del proyecto siempre gana**:

1. **`.agentic/sdd-hooks.env` del repo** (recomendado, versionado, igual en los cuatro agentes). Copiá la plantilla:
   ```bash
   mkdir -p .agentic
   cp source/core/templates/sdd-hooks.env .agentic/sdd-hooks.env
   ```
   Los instaladores de Codex y OpenCode ya lo hacen si el archivo no existe. Los repos adoptados antes de 2.0.0 con `.claude/sdd-hooks.env` siguen funcionando sin tocar nada: los hooks buscan `.agentic/` primero y caen a `.claude/`.
2. **`userConfig` del plugin** (fallback, solo en Claude Code). Se configura con `/plugin` o con `claude plugin install ... --config clave=valor`. Sirve cuando un mismo usuario trabaja en varios repos y quiere un default.

| Clave (`sdd-hooks.env`) | `userConfig` | Default | Para qué |
|---|---|---|---|
| `SDD_ARTIFACT_STORE` | `artifact_store` | `repo` | Dónde viven los artefactos del pipeline: `repo` (versionados en `docs/sdd/`, `gates.md` auditable en el PR), `local` (fuera del registro, en `.agentic/sdd/`) o `engram` (memoria persistente) |
| `SDD_ARTIFACTS_DIR` | `artifacts_dir` | según el store | Raíz donde se materializan los archivos. Relativa al proyecto, absoluta o con `~` |
| `SDD_BASE_BRANCH` | `base_branch` | `develop` | Rama contra la que se abren PR. El hook de git pide confirmación ante push directo a ella |
| `SDD_PROD_MARKERS` | `prod_markers` | vacío | Regex extendida que marca un comando como dirigido a producción (refs de base de datos, nombres de app, dominios). Se suma a los patrones genéricos |
| `SDD_TENANT_FIELD` | `tenant_field` | vacío | Campo de tenant en DTOs y esquema. Vacío = proyecto single-tenant y los checks de tenant se apagan |
| `SDD_TEST_CMD_RE` | `test_cmd_re` | multi-stack | Regex que reconoce una corrida de tests para la evidencia TDD. El default ya cubre vitest, jest, pytest, phpunit, pest, go test, cargo test, dotnet test, mvn/gradle y los comandos agregados de gate (`check`, `verify`, `validate`, `run ci`) |
| `SDD_PROGRESS_KEEP_TASKS` | `progress_keep_tasks` | `10` | Tareas que conserva `05-apply-progress.md` antes de rotar el detalle viejo a un archivo aparte |
| `SDD_COMMENT_MAX_BLOCK` / `SDD_COMMENT_MAX_PCT` | `comment_max_block` / `comment_max_pct` | `4` / `15` | Límite de comentarios en código fuente. Tests, migraciones, configs y `scripts/` quedan exentos |
| `SDD_AUTONOMY` | `autonomy` | `strict` | `strict`: push, PR y merge los decide el humano en GATE 2. `auto`: GATE 2 automático cuando la máquina puede decidirlo ([ver abajo](#autonomía-gate-2-automático)) |
| `SDD_HUMAN_PATHS` | `human_paths` | vacío | Regex sobre las rutas del diff que, en modo `auto`, fuerzan el GATE 2 humano (p. ej. `^infra/\|migrations/`) |

### Autonomía: GATE 2 automático

Con `SDD_AUTONOMY=auto` el humano deja de aprobar push, PR y merge de cada feature y se queda solo con las decisiones que una máquina no puede tomar. Después del verifier, el code-reviewer y el security-reviewer, el orquestador corre `hooks/gate2-auto.sh`, que exige:

- `06-verify.md` en PASS **sobre el HEAD actual**, `07-review.md` `APROBADO` y, si corrió, `07-security.md` sin críticos ni altos y con riesgo residual `aceptable`;
- GATE 1 aprobado (nivel `full`);
- ningún ADR `PROPUESTO` en el diff, ninguna ruta de `SDD_HUMAN_PATHS`, y ningún artefacto con `GATE 2: humano` (el `proposer` y el `designer` lo escriben cuando aplica un disparador que el proyecto declara en su documento de contexto).

Si todo pasa registra la línea exacta `GATE 2 · auto · sha: <HEAD>` en `gates.md` (el contrato que leen el hook y los scripts de merge de cada proyecto), y el agente pushea, abre el PR y mergea hacia la rama base. El hook `pre-bash` solo deja pasar `gh pr merge` con ese registro para el HEAD actual, así que un commit posterior lo invalida salvo que solo toque la raíz de artefactos (versionar el propio `gates.md`); `--admin` está prohibido siempre y un merge parado en la rama base (un release `develop → main`) nunca es automático. Si algo falla, el GATE 2 es humano y el agente muestra los motivos.

Las plantillas de `settings.json` traen el modo `strict`. Para `auto`, en el `settings.json` del repo:

- mover `Bash(git push:*)` y `Bash(gh pr create:*)` de `ask` a `allow`;
- quitar `Bash(gh pr merge:*)` de `deny` y ponerlo en `allow` (el hook es el que decide);
- mantener `deny` para `--force`, `--no-verify` y lo demás.

Acompañalo con protección de rama en `develop` y `main` (CI obligatorio, sin force push, aplicada también a administradores): el gate automático decide sobre artefactos locales; la protección es lo que el servidor garantiza.

---

## Adoptar el estándar en un repo existente

El camino corto es un comando que hace la migración completa y se detiene en cuatro checkpoints humanos:

```
/sdd-tdd-core:adopt --base=main --tenant=none
```

Trabaja en una rama `chore/adopt-sdd-toolkit` y recorre nueve pasos: detecta los valores del proyecto, escribe `.agentic/sdd-hooks.env`, genera el documento de contexto a partir de la plantilla, crea la skill local de invariantes, configura lint y CI, corre una feature piloto por el pipeline completo y recién al final limpia el orquestador y los comandos viejos que hubiera en la carpeta del agente. Nada se borra antes del paso 8.

Si preferís hacerlo a mano, lo mínimo es: `.agentic/sdd-hooks.env`, un documento de contexto (plantilla en `source/core/templates/context-doc.md`) y una skill de invariantes del producto (plantilla en `source/core/templates/invariants-skill/`).

---

## Cómo se trabaja

Una vez instalado, **no hace falta invocar ningún comando**. Si pedís un cambio de código en lenguaje natural ("agregá un endpoint", "arreglá el bug de X"), un hook de `UserPromptSubmit` inyecta el recordatorio y la skill `sdd-pipeline` hace que Claude clasifique el nivel antes de tocar archivos.

```
explorer → proposer → spec-writer → designer → task-planner → [GATE 1] →
(implementer ⟲ strict-tdd)* → verifier ∥ code-reviewer ∥ security-reviewer → [GATE 2] → merge → archiver
```

Hay tres niveles, y el pipeline completo no se paga siempre:

| Nivel | Cuándo | Recorrido |
|---|---|---|
| **Completo** | Feature nueva, cambio de esquema, migración, o cualquier cosa que toque auth, pagos, datos personales o integraciones | Pipeline entero |
| **Bugfix** | Defecto acotado con test reproducible, sin cambio de contrato ni de esquema | `explorer` → `implementer` → `verifier` ∥ `code-reviewer` → GATE 2 |
| **Trivial** | Typo, copy, bump de patch sin cambio de API | Commit directo, sin pipeline |

Cada feature deja sus artefactos en `<raíz>/<NNNN>-<slug>/`, uno por agente, ninguno de más de 150 líneas. Los agentes nunca se pasan el historial de chat.

Los agentes no se pasan rutas sino **referencias** (`sdd/<change>/spec`, `sdd/<change>/design`, …); el *store* configurado las resuelve. Con el default `repo` los artefactos se versionan en `docs/sdd/` — son el registro que justifica el código y que `start-session` y `audit-status` releen después — salvo el estado de sesión (`.current` y `tdd-evidence.log`), que va al `.gitignore`.

Si no querés que el repo acumule nada, `SDD_ARTIFACT_STORE=local` los saca del árbol versionado y `engram` los manda a memoria persistente. El precio es el mismo en los dos casos: `gates.md` deja de estar en el PR, así que el gate deja de ser auditable por el equipo.

Al cerrar, el `archiver` **reconcilia** la spec del change contra el spec de la **capacidad** que toca (`<raíz>/specs/<capacidad>/spec.md`, actualizado in place) y **archiva** la carpeta en `<raíz>/_archive/<fecha>-<slug>/`. Cien features no dejan cien specs vigentes: dejan las capacidades que el producto realmente tiene, más historia fuera del camino.

Y un **gatekeeper** mecánico (hook sobre `Task`) impide lanzar una fase a la que le falta un insumo: sin `02-spec.md` no corre el `designer`, y sin GATE 1 aprobado en `gates.md` no corre el `implementer`. Un agente sin su insumo no falla — inventa. El gatekeeper resuelve la feature en **el repositorio del trabajo pedido**, no en el de la sesión: si el prompt del subagente nombra rutas de otro repo, exige los artefactos de ese repo y dice a cuál está anclada la sesión, en vez de mandar a producir artefactos en uno que nadie está tocando.

**Los dos gates son humanos y no se pueden automatizar.** GATE 1 aprueba spec + diseño + plan + amenazas antes de que se escriba una línea de código de producción; el token literal es la palabra `acepto`. GATE 2 decide el merge. Un gate sin registro en `gates.md` no ocurrió.

### Comandos

| Comando | Qué hace |
|---|---|
| `/sdd-tdd-core:sdd <objetivo>` | Ejecuta el pipeline completo (o `--level=bugfix`) |
| `/sdd-tdd-core:adopt` | Adopta el estándar en el repo actual, de punta a punta |
| `/sdd-tdd-core:start-session` | Arranca leyendo el estado local: documento de contexto, ADRs, backlog, último cierre |
| `/sdd-tdd-core:end-session` | Cierra: resumen, commits en verde, clasificación de hallazgos |
| `/sdd-tdd-core:check-arch` | Corre typecheck + lint + tests + audit y reporta sin corregir |
| `/sdd-tdd-core:audit-status` | Auditoría read-only del código real contra el plan documentado |
| `/sdd-tdd-core:new-adr` | Redacta un ADR en estado `PROPUESTO` |
| `/sdd-tdd-core:pr-draft` | Redacta el PR con la única plantilla permitida |

---

## Guardrails

Los hooks del core corren en cada tool call y no dependen de que el agente decida portarse bien.

Miran el **código** del comando, no el dato: el cuerpo de un heredoc se escribe en un archivo o se manda por stdin, así que documentar una acción prohibida (`- git commit --no-verify está prohibido` dentro de un `cat >| doc.md <<'EOF'`) no dispara nada. La excepción es el heredoc que alimenta a un intérprete de shell (`bash <<'EOF'`), donde el cuerpo sí se ejecuta y se mira entero.

Lo que **deniegan** (`deny`, el agente no puede insistir):

- `git push --force`, `--no-verify`, `gh pr merge --admin`, y mensajes de commit con atribución de IA.
- Leer o editar `.env*` (solo `.env.example`).
- Escribir secretos o datos personales no sintéticos en artefactos, docs, fixtures y tests.
- Filtrar la salida de una corrida de tests con `| tail`/`| grep` — rompe la evidencia TDD.
- `npm`/`yarn` en un repo con `pnpm-lock.yaml`.
- Migraciones destructivas, `SET NOT NULL` sin default, tabla con tenant sin `FORCE ROW LEVEL SECURITY`, `SECURITY DEFINER` sin `search_path`, `GRANT` a `anon`/`PUBLIC`.
- Exceso de comentarios en código fuente.

Lo que **pide confirmación humana** (`ask`): comandos que parecen dirigidos a producción, push directo a la rama base, merge/rebase **sobre** una rama base (actualizar la feature con `git rebase origin/develop` pasa), `gh pr merge` sin GATE 2 registrado para el HEAD, `git commit -a`, `rm -rf` amplio, y lectura de dumps o archivos de credenciales.

**Lo que no ven.** Son regex: los secretos se detectan en cinco formas (`sk-`, JWT, `postgres://user:pass@`, `AKIA`, claves privadas PEM) y los datos personales solo como emails no sintéticos y teléfonos en formato internacional. Quedan fuera los tokens de GitHub o Slack, las API keys genéricas, los documentos nacionales y los teléfonos locales. El detalle completo del borde está en la [referencia del core](plugins/sdd-tdd-core/README.md#límites-conocidos-de-los-detectores) — vale leerlo antes de confiarles material sensible.

Y lo que **registra**: cada corrida de tests va al `docs/sdd/<feature>/tdd-evidence.log` **del repositorio que la corrió** —el que el comando declara con `cd`, `--dir`, `-C` o `--prefix`, que no siempre es el de la sesión— con timestamp, exit code, comando y resumen — con secretos redactados y una marca `WARN=no-tests-ran` si el runner salió en verde sin ejecutar un solo test. Las corridas que fallan llegan por `PostToolUseFailure` con su exit code y el resumen del runner, y una llamada que falló por otra parte del comando —una escritura encadenada que choca con `noclobber`— no se registra como test rojo. Si el repositorio que corrió los tests no es el de la sesión, la línea lo dice (`WARN=repo-cruzado`); si ese repositorio no tiene feature activa, la corrida va a su propio `_unassigned/` y nunca al log de otro repo. El `verifier` contrasta la tabla del apply-progress contra ese log, no contra lo que dice el `implementer`.

---

## Estructura del repositorio

El contenido se escribe una vez en `source/` y `bin/atk` lo compila. **Nada de lo que
está bajo `plugins/` o `dist/` se edita a mano**: son salida del build, y el CI falla
si difieren de `source/`.

```
source/                             # fuente única, sin nombres de agente
  core/
    manifest.json                   # metadatos, hooks y configuración del plugin
    ORCHESTRATOR.md                 # el proceso: pipeline, artefactos, gates
    ORCHESTRATOR-solo.md            # el mismo proceso sin subagentes
    agents/                         # 10 fases, una por archivo
    commands/  skills/  gates/  hooks/  templates/  tests/
  stack-typescript/
    manifest.json  skills/  templates/
  stack-go/
    manifest.json  skills/  templates/

adapters/                           # un módulo por agente + la tabla de placeholders
  targets.json  claude.mjs  codex.mjs  opencode.mjs  devin.mjs  lib.mjs
bin/atk                             # el build, en Node sin dependencias

plugins/                            # salida: Claude Code (ruta del marketplace)
dist/codex/  dist/opencode/  dist/devin/
```

```bash
node bin/atk targets           # qué agentes hay y a dónde salen
node bin/atk build             # compila todos
node bin/atk build --check     # falla si la salida commiteada quedó vieja
```

---

## Extender: tu propio plugin de stack

El core es agnóstico a propósito. Para soportar otro stack no hace falta tocarlo: alcanza con un plugin que aporte skills técnicas.

1. Creá `source/stack-<lenguaje>/manifest.json` con `name`, `version`, `description`, `license`, `targets` y `detect` (el archivo que identifica un repo de ese stack, como `go.mod`; lo usan los instaladores de Codex, OpenCode y Devin).
2. Agregá las skills en `skills/<nombre>/SKILL.md`. Cada una necesita frontmatter con `name` y una `description` que **diga cuándo usarla** — es lo que el agente lee para decidir si la carga. Mirá `stack-typescript` o `stack-go` como referencia. Los nombres pueden repetir los de otro stack: cada uno queda aparte.
3. Cubrí al menos: arquitectura y límites entre capas, convenciones de test (con los comandos reales que resuelven `<test>`, `<lint>`, `<typecheck>`), errores, persistencia y seguridad.
4. Agregalo a `PLUGIN_DIRS` en `bin/atk` y corré `node bin/atk build`. El marketplace de Claude y los árboles de los demás agentes se regeneran solos.

La regla de precedencia es: la skill local de invariantes del proyecto manda sobre el plugin de stack, y el plugin de stack manda sobre los defaults del core. `delivery-workflow` es la única fuente de verdad de commits, ramas, PR y CI: ningún plugin de stack la redefine.

---

## Versionado

Versionado semántico por plugin, más una versión del marketplace en `.claude-plugin/marketplace.json`. Cada release lleva su tag `vX.Y.Z`. Los plugins ya instalados se actualizan con:

```bash
claude plugin marketplace update agentic-toolkit
```

---

## Contribuir

```bash
bash source/core/tests/e2e.sh            # 215 aserciones, repo de prueba descartable
node source/core/tests/opencode-shim.mjs # el shim de OpenCode contra los hooks reales
node bin/atk build --check                # la salida commiteada coincide con source/
```

El CI corre esa suite más `bash -n` y `shellcheck` sobre los hooks, y valida los manifiestos (JSON, que cada hook declarado exista y sea ejecutable, y que el marketplace apunte a plugins reales) en cada push y PR.

---

## Licencia

[MIT](LICENSE) © Jorge Diaz
