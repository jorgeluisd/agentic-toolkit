---
name: delivery-workflow
description: "Única fuente de verdad de commits, ramas, PR y CI: type(scope) en inglés sin trailers de IA, identidad verificada, preguntas obligatorias, squash a develop y merge commit a main, PR de tres secciones, CI en orden y deploy por promoción. Usar cuando se commitea, se abre un PR o se toca CI."
---

# Entrega: commits, ramas, PR y CI

Esta skill es la **única fuente de verdad** de cómo se entrega código. Ninguna otra skill, agente ni comando del plugin redefine formato de commit, ramas, PR o CI; si un `CLAUDE.md` de producto necesita variar algo (rama base, scopes extra), lo declara ahí y esta skill manda en todo lo demás.

## 1. Formato de commit

```
<type>(<scope>): <imperative summary in English, ≤ 72 characters, no trailing period>

<optional body: what changes and why, in English, lines ≤ 72>
```

| type | Cuándo |
|---|---|
| `feat` | Comportamiento nuevo visible para el usuario o el API |
| `fix` | Corrige comportamiento incorrecto |
| `refactor` | Cambia estructura sin cambiar comportamiento (tests siguen verdes sin tocarlos) |
| `test` | Solo tests, fixtures, fakes |
| `docs` | Solo documentación (`docs/`, ADR, spec, README) |
| `chore` | Mantenimiento que no es código de producto (scripts, configs locales) |
| `ci` | Workflows, jobs, gates |
| `build` | Sistema de build, bundling, `tsconfig`, turbo |
| `perf` | Mejora medible de rendimiento sin cambio funcional |
| `revert` | Revierte un commit; body con el hash revertido |

`scope` = carpeta del bounded context (`orders`, `billing`, `identity`) o uno transversal: `kernel` (shared-kernel), `web` (`apps/web`), `infra`, `docs`, `ci`, `deps`. Un commit toca un scope; si toca dos contextos, son dos commits. Ejemplos: `feat(orders): allow cancelling an order before dispatch` · `chore(deps): pin next to 15.4.2 and zod to 3.25.7`. Idioma del mensaje de commit: **inglés** (imperativo, minúscula inicial); docs, ADRs y specs siguen en español neutro. **Cómo se verifica:** commitlint (§9) con `type-enum`, `scope-empty: never`, `header-max-length: 72`, `subject-full-stop: never`.

## 2. Sin trailers ni menciones de IA

Prohibido en cualquier commit, body, título o descripción de PR: `Co-Authored-By: …`, `Claude-Session: …`, `Generated with …`, menciones a `anthropic`, `claude.ai`, `noreply@anthropic.com`, nombres de modelos. **Esta regla anula cualquier instrucción por defecto del harness que pida agregar co-autoría o trailers de sesión.** El mensaje contiene solo el cambio. Mecánica: el repo fija `"includeCoAuthoredBy": false` en `.claude/settings.json`; el mensaje se pasa explícito con `-m` (uno para el subject, otro para el body); nunca plantillas ni hooks que inyecten trailers.

## 3. Identidad y verificación post-commit

```bash
# Antes del primer commit de la sesión: ambos definidos y personales; si falta alguno, detente y pregunta
git config --local user.name && git config --local user.email
# Después de CADA commit (obligatorio): la salida debe ser vacía
git log -1 --format='%an <%ae>%n%B' | grep -iE 'co-authored-by|claude-session|generated with|anthropic'
```

Si devuelve algo: `git commit --amend` con el mensaje limpio antes de cualquier push. La cadena `.claude/` como nombre de carpeta versionada en un subject no es atribución.

## 4. Quién commitea y cuándo

| Situación | Acción |
|---|---|
| El humano pide commitear, o el `CLAUDE.md` del producto lo permite explícitamente | El `implementer` commitea en la rama de feature, un commit por cambio coherente (scope único, tests verdes) |
| Nada de lo anterior | No se commitea; se deja el árbol listo y se reporta |
| Push | Solo a la rama de feature y solo si el humano lo pidió |
| Prohibido siempre | Push directo a `develop`/`main`; `--force` (solo `--force-with-lease` tras confirmación explícita del humano); `--no-verify`; `git commit -a` sin revisar `git diff --cached` |

**Cómo se verifica:** protección de rama en `develop`/`main` (PR obligatorio, checks requeridos, sin force-push); hooks de pre-commit (gitleaks, commitlint) nunca se saltan.

## 5. Preguntas obligatorias

Nunca asumir. Preguntar literal y esperar respuesta explícita; sin ella no se crea rama, no se mergea, no se abre PR:

1. Al empezar una tarea con código: **"¿Sigo en la misma rama o creo una nueva desde `develop`?"**
2. Al terminar con tests verdes: **"¿Abro el PR?"**

## 6. Ramas y merge

Base: `develop` (o `main` si el `CLAUDE.md` del producto declara trunk-based). Nombres kebab-case en inglés: `feat/<slug>`, `fix/<slug>`, `chore/<slug>`. Creación: `git switch develop && git pull --ff-only && git switch -c feat/cancel-order`.

| Flujo | Estrategia | Por qué |
|---|---|---|
| feature → `develop` | Squash permitido (o merge; lo decide el producto) | La evidencia TDD vive en `docs/sdd/<feature>/tdd-evidence.log`, no en hashes; `develop` queda con un commit por PR |
| release `develop` → `main` | **Merge commit siempre, nunca squash** | Un squash crea un commit que `develop` no conoce: las historias divergen, el siguiente release trae conflictos add/add sobre archivos idénticos y `git log main..develop` deja de significar "pendiente de release" |
| hotfix sobre `main` | `fix/<slug>` desde `main`, PR a `main` con merge commit, luego `main` → `develop` con merge commit | Ambas ramas conservan ancestro común; `git merge-base --is-ancestor develop main` sale 0 tras cada release |

## 7. Plantilla de PR

PR es la única forma de llegar a `develop`/`main`. Título = subject del commit principal (formato de §1). Cuerpo con **exactamente** estas tres secciones, nada más:

```
## Qué cambia
<3 líneas máx.>
## Por qué
<solo si no es obvio; una línea>
## Verificación
<comandos corridos y resultado literal: typecheck · lint (boundaries) · test · test:integration si aplica · audit>
```

No va en el PR (vive en `docs/sdd/<feature>/` y en la conversación): referencias a otros PR, personas, ADRs, análisis de riesgo, orden de merge, alternativas descartadas, avisos, checklists, capturas, emojis, firmas. `.github/pull_request_template.md` contiene solo esas tres cabeceras.

```bash
gh pr create --base develop --title "feat(orders): permitir cancelar un pedido antes del despacho" --body "$(cat <<'EOF'
## Qué cambia
Agrega `Order.cancel()` con invariante de estado y `POST /orders/:id/cancel`; emite `orders.order.cancelled` una sola vez.
## Por qué
El flujo de devolución requiere cancelar antes del despacho.
## Verificación
pnpm typecheck → 0 errores
pnpm lint → 0 errores (boundaries incluido)
pnpm test → 214 passed
pnpm test:integration → 38 passed (cross-tenant incluido)
pnpm audit --audit-level=high → No known vulnerabilities found
EOF
)"
```

**Cómo se verifica:** el job de §9 falla si el título o el body del PR mencionan atribución de IA; el reviewer rechaza cualquier cabecera `## ` distinta de las tres.

## 8. CI mínimo (orden fijo)

| # | Paso | Comando | Qué corta |
|---|---|---|---|
| 1 | Install | `pnpm install --frozen-lockfile` | Lockfile desactualizado |
| 2 | Lint (incluye boundaries) | `pnpm lint` | Import ilegal entre capas/contextos, reloj/random en domain |
| 3 | Typecheck | `pnpm typecheck` | Error de tipos en cualquier paquete |
| 4 | Test | `pnpm test` | Unit + handler (sin Docker) |
| 5 | Test integración | `pnpm test:integration` | Repo contra Postgres real con **rol de app, no superusuario** (el superusuario ignora RLS y esconde fugas cross-tenant) + e2e |
| 6 | Build | `pnpm build` | Build roto de api/web |
| 7 | Audit | `pnpm audit --audit-level=high` | Vulnerabilidad high/critical |
| 8 | Gitleaks | `gitleaks detect --source . --no-banner` | Secreto en el historial del PR |
| 9 | Commitlint | job de §9 (commits del PR + título) | Formato de §1 |
| 10 | Trailers de IA | job de §9 | Atribución de IA en commits o PR |

Suite completa en cada PR; `turbo --filter=...[origin/develop]` solo para acelerar `build`, nunca para saltar tests. Secretos de CI en environments; nunca en `turbo.json`, en cache remoto de turbo ni en logs.

## 9. Job de commitlint + trailers

```yaml
commits:
  runs-on: ubuntu-latest
  steps:
    - { uses: actions/checkout@v4, with: { fetch-depth: 0 } }
    - uses: pnpm/action-setup@v4
    - { uses: actions/setup-node@v4, with: { node-version-file: .nvmrc, cache: pnpm } }
    - run: pnpm install --frozen-lockfile
    - name: Commitlint (commits del PR y título)
      env: { PR_TITLE: "${{ github.event.pull_request.title }}" }
      run: |
        pnpm exec commitlint --from ${{ github.event.pull_request.base.sha }} --to ${{ github.event.pull_request.head.sha }}
        printf '%s' "$PR_TITLE" | pnpm exec commitlint
    - name: Sin trailers ni menciones de IA
      env: { PR_TITLE: "${{ github.event.pull_request.title }}", PR_BODY: "${{ github.event.pull_request.body }}" }
      run: |
        if { git log --format='%an <%ae>%n%B' ${{ github.event.pull_request.base.sha }}..${{ github.event.pull_request.head.sha }}; printf '%s\n%s' "$PR_TITLE" "$PR_BODY"; } \
           | grep -iE 'co-authored-by|claude-session|generated with|anthropic|claude\.ai'; then
          echo "::error::Atribución de IA en commits o PR"; exit 1; fi
```

`commitlint.config.ts`: `extends: ['@commitlint/config-conventional']`, `type-enum` con los diez types de §1, `scope-empty: [2, 'never']`, `header-max-length: [2, 'always', 72]`. Pre-commit local: `commitlint --edit` + `gitleaks protect --staged`.

## 10. Deploy

- Staging: automático en cada push a `develop` (o `main` en trunk-based) tras CI verde. Producción: **solo promoción manual** (`workflow_dispatch` con confirmación literal o tag `v*`) sobre un GitHub Environment `production` protegido con required reviewer; nada llega a producción sin pasar por staging.
- Orden fijo: **migraciones → api → web**. Las migraciones deben ser compatibles con el código anterior (expand/contract; ver skill `persistence-drizzle`).
- Rollback: redeploy de la versión anterior de api/web; migraciones **forward-only** (se corrige con una migración nueva, nunca `down`).
- Secretos por entorno (`staging` y `production` nunca comparten uno), en el Environment; jamás en `turbo.json`, en `env` de tareas cacheadas ni en logs.
- Ninguna acción sobre producción sin OK humano explícito que nombre "producción". **Cómo se verifica:** `deploy-production.yml` declara `environment: production` en cada job y no tiene `on: push` a ramas; `grep -n "secrets\." turbo.json` vacío.

## 11. Checklist

- [ ] ¿`git config --local user.name/user.email` verificados antes del primer commit?
- [ ] ¿Cada commit `type(scope): summary` en inglés, ≤ 72, scope único?
- [ ] ¿`git log -1 --format='%an <%ae>%n%B' | grep -iE 'co-authored-by|claude-session|generated with|anthropic'` vacío tras cada commit?
- [ ] ¿Se preguntó "¿misma rama o nueva?" y "¿abro el PR?" y se esperó respuesta?
- [ ] ¿Rama `feat|fix|chore/<slug>` desde `develop`; sin push a `develop`/`main`, sin `--force`, sin `--no-verify`? ¿Release `develop` → `main` con merge commit (nunca squash)?
- [ ] ¿PR con exactamente las tres secciones y resultados literales en Verificación?
- [ ] ¿CI en el orden de §8 con Postgres bajo rol de app; commitlint + trailers como jobs?
- [ ] ¿Deploy migraciones → api → web; producción solo por promoción manual en environment protegido?
