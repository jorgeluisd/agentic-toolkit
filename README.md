# agentic-toolkit

Marketplace de plugins de [Claude Code](https://claude.com/claude-code) para desarrollar software con **SDD (Spec-Driven Development) + Strict TDD**: una especificación verificable antes del diseño, un diseño explícito antes del código, TDD estricto durante la implementación y dos paradas humanas obligatorias antes de mergear.

No es una colección de prompts. Es un proceso con artefactos en disco, agentes con contextos separados, evidencia mecánica de que los tests corrieron y guardrails por hooks que bloquean lo que no debería pasar.

---

## Los dos plugins

El toolkit separa **el proceso** (agnóstico de lenguaje) de **las reglas técnicas** (propias de cada stack).

| Plugin | Qué aporta | Cuándo instalarlo |
|---|---|---|
| **`sdd-tdd-core`** | 10 agentes, 2 gates humanos, protocolo de artefactos con gatekeeper de fases, comandos de sesión, skills de proceso (`sdd-pipeline`, `strict-tdd`, `delivery-workflow`) y guardrails por hooks | **Siempre.** Funciona con cualquier lenguaje |
| **`stack-typescript`** | 11 skills técnicas para TypeScript: Onion + Screaming Architecture, dominio puro, CQRS, Result, Drizzle/Postgres, multi-tenancy con RLS, Vitest, seguridad, pino, Next.js, dependencias con pnpm. Plantillas de `settings.json`, CI y commitlint | En proyectos TypeScript |

El core no sabe nada de tu lenguaje: pregunta por comandos simbólicos (`<test>`, `<lint>`, `<typecheck>`) que resuelve el `CLAUDE.md` de tu proyecto o el plugin de stack. Si trabajás en PHP, Python o Go, instalá solo el core y declará tus comandos — o escribí tu propio plugin de stack ([ver abajo](#extender-tu-propio-plugin-de-stack)).

---

## Requisitos

- **Claude Code** instalado y autenticado.
- **`bash`**, **`git`** y **[`jq`](https://jqlang.github.io/jq/)** en el `PATH`. Los hooks son scripts de shell que parsean JSON con `jq`; sin `jq` los guardrails no corren.
- macOS o Linux. En Windows, WSL.

```bash
jq --version   # si no está: brew install jq · apt install jq
```

---

## Instalación

```bash
claude plugin marketplace add jorgeluisd/agentic-toolkit
claude plugin install sdd-tdd-core@agentic-toolkit
claude plugin install stack-typescript@agentic-toolkit   # solo en proyectos TypeScript
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

---

## Configuración

El core lee unos pocos valores que no puede adivinar. Se pueden declarar en dos lugares, y **el del proyecto siempre gana**:

1. **`.claude/sdd-hooks.env` del repo** (recomendado, versionado). Copiá la plantilla:
   ```bash
   mkdir -p .claude
   CORE=$(claude plugin list --json | jq -r '.[]|select(.id=="sdd-tdd-core@agentic-toolkit").installPath')
   cp "$CORE/templates/sdd-hooks.env" .claude/sdd-hooks.env
   ```
2. **`userConfig` del plugin** (fallback, a nivel usuario). Se configura con `/plugin` o con `claude plugin install ... --config clave=valor`. Sirve cuando un mismo usuario trabaja en varios repos y quiere un default.

| Clave (`sdd-hooks.env`) | `userConfig` | Default | Para qué |
|---|---|---|---|
| `SDD_ARTIFACT_STORE` | `artifact_store` | `repo` | Dónde viven los artefactos del pipeline: `repo` (versionados en `docs/sdd/`, `gates.md` auditable en el PR), `local` (fuera del registro, en `.claude/sdd/`) o `engram` (memoria persistente) |
| `SDD_ARTIFACTS_DIR` | `artifacts_dir` | según el store | Raíz donde se materializan los archivos. Relativa al proyecto, absoluta o con `~` |
| `SDD_BASE_BRANCH` | `base_branch` | `develop` | Rama contra la que se abren PR. El hook de git pide confirmación ante push directo a ella |
| `SDD_PROD_MARKERS` | `prod_markers` | vacío | Regex extendida que marca un comando como dirigido a producción (refs de base de datos, nombres de app, dominios). Se suma a los patrones genéricos |
| `SDD_TENANT_FIELD` | `tenant_field` | vacío | Campo de tenant en DTOs y esquema. Vacío = proyecto single-tenant y los checks de tenant se apagan |
| `SDD_TEST_CMD_RE` | `test_cmd_re` | multi-stack | Regex que reconoce una corrida de tests para la evidencia TDD. El default ya cubre vitest, jest, pytest, phpunit, pest, go test, cargo test, dotnet test, mvn/gradle |
| `SDD_COMMENT_MAX_BLOCK` / `SDD_COMMENT_MAX_PCT` | `comment_max_block` / `comment_max_pct` | `4` / `15` | Límite de comentarios en código fuente. Tests, migraciones, configs y `scripts/` quedan exentos |

---

## Adoptar el estándar en un repo existente

El camino corto es un comando que hace la migración completa y se detiene en cuatro checkpoints humanos:

```
/sdd-tdd-core:adopt --base=main --tenant=none
```

Trabaja en una rama `chore/adopt-sdd-toolkit` y recorre nueve pasos: detecta los valores del proyecto, escribe `.claude/sdd-hooks.env`, genera el `CLAUDE.md` a partir de la plantilla, crea la skill local de invariantes, configura lint y CI, corre una feature piloto por el pipeline completo y recién al final limpia el orquestador y los comandos viejos que hubiera en `.claude/`. Nada se borra antes del paso 8.

Si preferís hacerlo a mano, lo mínimo es: `.claude/sdd-hooks.env`, un `CLAUDE.md` (plantilla en `plugins/sdd-tdd-core/templates/CLAUDE.md`) y una skill de invariantes del producto (plantilla en `templates/invariants-skill/`).

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

Y un **gatekeeper** mecánico (hook sobre `Task`) impide lanzar una fase a la que le falta un insumo: sin `02-spec.md` no corre el `designer`, y sin GATE 1 aprobado en `gates.md` no corre el `implementer`. Un agente sin su insumo no falla — inventa.

**Los dos gates son humanos y no se pueden automatizar.** GATE 1 aprueba spec + diseño + plan + amenazas antes de que se escriba una línea de código de producción; el token literal es la palabra `acepto`. GATE 2 decide el merge. Un gate sin registro en `gates.md` no ocurrió.

### Comandos

| Comando | Qué hace |
|---|---|
| `/sdd-tdd-core:sdd <objetivo>` | Ejecuta el pipeline completo (o `--level=bugfix`) |
| `/sdd-tdd-core:adopt` | Adopta el estándar en el repo actual, de punta a punta |
| `/sdd-tdd-core:start-session` | Arranca leyendo el estado local: `CLAUDE.md`, ADRs, backlog, último cierre |
| `/sdd-tdd-core:end-session` | Cierra: resumen, commits en verde, clasificación de hallazgos |
| `/sdd-tdd-core:check-arch` | Corre typecheck + lint + tests + audit y reporta sin corregir |
| `/sdd-tdd-core:audit-status` | Auditoría read-only del código real contra el plan documentado |
| `/sdd-tdd-core:new-adr` | Redacta un ADR en estado `PROPUESTO` |
| `/sdd-tdd-core:pr-draft` | Redacta el PR con la única plantilla permitida |

---

## Guardrails

Los hooks del core corren en cada tool call y no dependen de que el agente decida portarse bien. Lo que **deniegan** (`deny`, el agente no puede insistir):

- `git push --force`, `--no-verify`, y mensajes de commit con atribución de IA.
- Leer o editar `.env*` (solo `.env.example`).
- Escribir secretos o datos personales no sintéticos en artefactos, docs, fixtures y tests.
- Filtrar la salida de una corrida de tests con `| tail`/`| grep` — rompe la evidencia TDD.
- `npm`/`yarn` en un repo con `pnpm-lock.yaml`.
- Migraciones destructivas, `SET NOT NULL` sin default, tabla con tenant sin `FORCE ROW LEVEL SECURITY`, `SECURITY DEFINER` sin `search_path`, `GRANT` a `anon`/`PUBLIC`.
- Exceso de comentarios en código fuente.

Lo que **pide confirmación humana** (`ask`): comandos que parecen dirigidos a producción, push directo a la rama base, merge/rebase sobre ramas base, `git commit -a`, `rm -rf` amplio, y lectura de dumps o archivos de credenciales.

**Lo que no ven.** Son regex: los secretos se detectan en cinco formas (`sk-`, JWT, `postgres://user:pass@`, `AKIA`, claves privadas PEM) y los datos personales solo como emails no sintéticos y teléfonos en formato internacional. Quedan fuera los tokens de GitHub o Slack, las API keys genéricas, los documentos nacionales y los teléfonos locales. El detalle completo del borde está en la [referencia del core](plugins/sdd-tdd-core/README.md#límites-conocidos-de-los-detectores) — vale leerlo antes de confiarles material sensible.

Y lo que **registra**: cada corrida de tests va a `docs/sdd/<feature>/tdd-evidence.log` con timestamp, exit code, comando y resumen — con secretos redactados y una marca `WARN=no-tests-ran` si el runner salió en verde sin ejecutar un solo test. El `verifier` contrasta la tabla del apply-progress contra ese log, no contra lo que dice el `implementer`.

---

## Estructura del repositorio

```
.claude-plugin/marketplace.json     # catálogo del marketplace
plugins/
  sdd-tdd-core/
    ORCHESTRATOR.md                 # el proceso: pipeline, artefactos, gates, principios
    agents/                         # 10 agentes, uno por archivo
    commands/                       # 8 comandos
    skills/                         # sdd-pipeline · strict-tdd · delivery-workflow
    gates/                          # checklists de GATE 1 y GATE 2
    hooks/                          # guardrails + gatekeeper (bash + jq)
    tests/e2e.sh                    # 53 aserciones sobre un repo git real
    templates/                      # CLAUDE.md, sdd-hooks.env, skill de invariantes, PR
  stack-typescript/
    skills/                         # 11 skills técnicas
    templates/                      # settings.json, ci.yml, commitlint.config.js
```

---

## Extender: tu propio plugin de stack

El core es agnóstico a propósito. Para soportar otro stack no hace falta tocarlo: alcanza con un plugin que aporte skills técnicas.

1. Creá `plugins/stack-<lenguaje>/.claude-plugin/plugin.json` con `name`, `version`, `description` y `license`.
2. Agregá las skills en `skills/<nombre>/SKILL.md`. Cada una necesita frontmatter con `name` y una `description` que **diga cuándo usarla** — es lo que Claude lee para decidir si la carga. Mirá `stack-typescript` como referencia.
3. Cubrí al menos: arquitectura y límites entre capas, convenciones de test (con los comandos reales que resuelven `<test>`, `<lint>`, `<typecheck>`), errores, persistencia y seguridad.
4. Registralo en `.claude-plugin/marketplace.json`.

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
bash plugins/sdd-tdd-core/tests/e2e.sh   # 53 aserciones, repo de prueba descartable
```

El CI corre esa suite más `bash -n` y `shellcheck` sobre los hooks, y valida los manifiestos (JSON, que cada hook declarado exista y sea ejecutable, y que el marketplace apunte a plugins reales) en cada push y PR.

---

## Licencia

[MIT](LICENSE) © Jorge Diaz
