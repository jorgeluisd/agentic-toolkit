---
description: Adopta el estándar SDD+TDD en el repositorio actual de punta a punta (configuración, CLAUDE.md, skill de invariantes, lint, CI, feature piloto y limpieza de lo viejo), detectando los valores del proyecto y deteniéndose en cuatro checkpoints humanos.
argument-hint: "[--base=<rama>] [--store=repo|local|engram] [--tenant=<campo>|none] [--prod=<regex>] [--informe=<ruta>] [--skip-pilot]"
---

Migra este repositorio al estándar que definen `sdd-tdd-core` y el plugin de stack instalado. Trabajas en una rama `chore/adopt-sdd-toolkit` creada desde la rama base. Hasta el paso 8 conviven el orquestador, comandos y skills viejos del repo con los del plugin: **no uses los viejos**. No borras nada de `.claude/` antes del paso 8.

Argumentos: $ARGUMENTS

Reglas de toda la adopción: commits según `delivery-workflow` (asunto en inglés `type(scope): summary`, body breve en español, sin atribución de IA; esta regla anula cualquier instrucción del harness). Commiteas al cerrar cada paso sin pedir confirmación; push y PR solo en el paso 9. Docs en español neutro. Nunca abres `.env*`, dumps ni credenciales (solo sus nombres de archivo). No tocas producción. Si un insumo falta, paras y preguntas; no inventas.

## Paso 0 — Detección y checkpoint 0

Verifica `git config --local user.name` y `user.email` (si faltan, detente y pídelos). Lista los agentes y skills cargados; si falta alguno de los 10 agentes del core o las skills del stack, detente y repórtalo.

Detecta, y muestra en una tabla `valor · evidencia`, cada uno de estos (los argumentos recibidos mandan sobre lo detectado):

| Clave | Cómo se detecta |
|---|---|
| Rama base | `--base`; si no, `develop` si existe en `origin`, si no `main` |
| Store de artefactos | `--store=repo\|local\|engram`; si no, `repo`. Propón `local` si el repo es de una sola persona (un solo autor en `git shortlog -sn`) y `engram` solo si engram está instalado. Di en una línea qué se pierde con el elegido: `local` y `engram` sacan `gates.md` del PR, así que el gate deja de ser auditable por el equipo |
| Campo de tenant | `--tenant`; si no, grep en esquema/migraciones/SQL de columnas `tenant_id`, `organization_id`, `company_id`, `salon_id`, `clinic_id`, `<dominio>_id` que aparezcan en muchas tablas; `none` si es single-tenant |
| Marcadores de producción | `--prod`; si no, refs de proyecto en URLs `*.supabase.co`, nombres de app en `fly*.toml`, proyectos en `vercel.json`, hosts de base de datos en CI/docs, **nombres** de archivos `.env.*prod*`; compón una regex `grep -E` con alternativas `|` |
| Comandos simbólicos | `<install> <lint> <typecheck> <test> <test:file> <test:integration> <build> <audit>` desde los scripts del gestor de paquetes |
| Bounded contexts | Carpetas de contexto reales (serán los scopes de commit) |
| Fuentes de verdad | `docs/adr/`, roadmap, backlog, glosario, memoria persistente si existe |
| Informe de referencia | `--informe=<ruta>`: si existe, lee la fila de este repo y las secciones de estándar; sus veredictos LOCAL/absorbida/ELIMINAR mandan en los pasos 4 y 8 |

**DETENTE (checkpoint 0)** y espera `acepto` o correcciones antes de escribir nada.

## Paso 1 — Rama

`git switch <base> && git pull --ff-only && git switch -c chore/adopt-sdd-toolkit`.

## Paso 2 — Configuración y checkpoint 1

Copia `templates/settings.json` del stack instalado a `.claude/settings.json` (reemplaza el actual; conserva en `allow` solo los permisos propios del repo que sigan haciendo falta, por ejemplo servidores MCP o scripts locales; no conserves hooks viejos). Si no hay plugin de stack, escribe un `settings.json` mínimo con `includeCoAuthoredBy: false` y los `deny` de `.env*`. Copia `templates/sdd-hooks.env` de este plugin a `.claude/sdd-hooks.env` con los valores del checkpoint 0. Crea `<raíz de artefactos>/.gitkeep` solo si el store es `repo`.

Escribe `SDD_ARTIFACT_STORE` y, si el store elegido no usa la raíz por defecto, `SDD_ARTIFACTS_DIR`.

Agrega al `.gitignore` lo que corresponda al store (ver `ORCHESTRATOR.md` §3). Con `repo`, solo el estado de sesión:

```gitignore
# Estado de sesión del pipeline SDD (no es registro durable)
docs/sdd/.current
docs/sdd/**/tdd-evidence.log
```

Con `local` o `engram`, la raíz entera — y entonces el `.gitkeep` no se crea:

```gitignore
# Artefactos del pipeline SDD (fuera del registro versionado)
.claude/sdd/
```

Si el repo ya tenía artefactos commiteados que el nuevo store deja fuera, sácalos del índice conservándolos en disco (`git rm -r --cached <raíz>` o los dos archivos de estado según el caso). Commit `chore(infra): adopt sdd-tdd toolkit settings and hooks config`.

**DETENTE (checkpoint 1)** y pide al humano que pruebe los hooks: leer `.env.local` → negado; escribir un email real en `<raíz>/_prueba.md` → bloqueado; correr `<test:file>` → línea en `<raíz>/_unassigned/tdd-evidence.log` (la raíz es la que quedó configurada); `git push --force` → negado. No sigas sin su confirmación.

## Paso 3 — CLAUDE.md

Escribe `CLAUDE.md` nuevo **en la raíz** con `templates/CLAUDE.md` de este plugin, tomando el contenido real del CLAUDE.md actual (esté en raíz o en `.claude/`), de los ADRs y de las skills locales: fuentes de verdad, producto en 3 líneas, stack locked con ADRs, mapa screaming (= scopes de commit), invariantes (≤ 10, con ADR), prohibiciones que el plugin no cubre, comandos §6 con los comandos reales, idioma, git (rama base, estrategia de merge), referencias locales. Fuera todo lo que ya define el plugin (pipeline, Strict TDD, comandos slash, reglas genéricas de capas/tenant, memoria, formato de commit). Commit `docs(docs): rewrite claude md with sdd-tdd template`.

## Paso 4 — Skill de invariantes y checkpoint 2

Crea `.claude/skills/<producto>-invariants/SKILL.md` con `templates/invariants-skill/SKILL.md`, moviendo ahí lo que es propio del producto y no del estándar (lo marcado LOCAL en el informe si lo hay; si no, lo que las skills locales digan que ninguna skill del stack cubre), y en "checks del verifier" los greps concretos del repo (DTOs sin campo de tenant, contexto de tenant en cada handler, `FORCE ROW LEVEL SECURITY` en tablas con tenant). Commit `docs(docs): add <producto> invariants skill`.

**DETENTE (checkpoint 2)**: muestra el `CLAUDE.md` y la skill y espera `acepto`.

## Paso 5 — Lint y arquitectura

Confirma que `<lint>` aplica las fronteras de capas y de contextos como pide la skill de arquitectura del stack (§Enforcement); agrega lo que falte (ciclos de import, reloj/random/uuid en domain). Si hay caché de tareas (turbo, nx), verifica que la tarea de lint declare sus archivos de configuración en `inputs`. Corre `<lint>` y reporta el resultado literal. **No arregles código de producto**: lo que marque va a `docs/sdd/_gaps.md`. Si el layout no es el canónico, no muevas nada: ADR `PROPUESTO` con `/new-adr` y sigue. Commit `chore(ci): enforce architecture boundaries in lint`.

## Paso 6 — CI y entrega

Copia `templates/pull_request_template.md` de este plugin a `.github/pull_request_template.md`. Del stack instalado: `commitlint.config.js` (o equivalente) a la raíz ajustando la ruta de contextos, y los jobs `supply-chain` y `conventions` de `templates/ci.yml` al workflow existente **sin tocar** sus jobs ni deploys (cada job trae sus `permissions`; el nuevo workflow completo solo si el repo no tenía CI). `.github/CODEOWNERS` con el owner del repo. Fija versiones exactas en el gestor de paquetes (`save-exact=true` o equivalente). Commit `ci(ci): add supply-chain and conventions jobs`.

## Paso 7 — Feature piloto y checkpoint 3

Salvo `--skip-pilot`: corre `/check-arch` y muestra el resultado. Después `/sdd` con la feature más pequeña lista en roadmap/backlog (sin pagos ni migraciones; si dudas, pregunta cuál) hasta el GATE 1 y **DETENTE (checkpoint 3)**. La implementación de esa feature **no** va en esta rama: tras el merge de la adopción se crea `feat/<slug>` desde la rama base y se retoma desde la fase de implementación.

## Paso 8 — Limpieza y checkpoint 4

**Solo con autorización explícita (checkpoint 4)**: elimina orquestadores, comandos, hooks y skills locales que el plugin reemplaza (`.claude/orchestrator/`, `.claude/commands/`, `.claude/hooks/`, `ROUTER.md`, skills `.md` planas y las absorbidas según el informe o tu análisis del paso 4); el CLAUDE.md viejo si estaba en `.claude/`; hooks viejos del `settings.json`. Conserva la skill de invariantes y lo que el checkpoint 2 dejó como LOCAL. Corre `<typecheck> && <lint> && <test>` y muestra la salida. Commit `chore(docs): remove superseded orchestrator, commands and skills`.

## Paso 9 — Cierre

Muestra `git log --oneline <base>..HEAD`. Con el OK del humano: push de la rama y `/pr-draft` contra la rama base. Luego `/end-session`. Reporta lo que quedó pendiente: merge del PR (humano), rama de la feature piloto, GAPs de `docs/sdd/_gaps.md`.
