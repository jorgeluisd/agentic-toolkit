---
name: delivery-workflow
description: "Única fuente de verdad de commits, ramas, PR y CI: type(scope) en inglés sin trailers de IA, identidad verificada, preguntas obligatorias, squash a develop y merge commit a main, PR de tres secciones, CI en orden con comandos simbólicos. Usar cuando se commitea, se abre un PR o se toca CI."
---

# Entrega: commits, ramas, PR y CI

Esta skill es la **única fuente de verdad** de cómo se entrega código. Ninguna otra skill, agente ni comando del plugin redefine formato de commit, ramas, PR o CI; si un `CLAUDE.md` de producto necesita variar algo (rama base, scopes extra), lo declara ahí y esta skill manda en todo lo demás.

## 0. Comandos simbólicos

Esta skill es agnóstica de lenguaje: los comandos aparecen como símbolos y el comando real lo define cada proyecto en `CLAUDE.md` §6 y la skill `testing-conventions` del stack instalado. Símbolos: `<install>` (instala dependencias con lockfile congelado), `<lint>` (linter, incluidas reglas de límites entre capas y contextos), `<typecheck>` (chequeo estático: compilador o analizador estático del stack), `<test>` (unit + handler, sin infraestructura externa), `<test:integration>` (contra base de datos real y e2e), `<build>` (todos los artefactos desplegables), `<audit>` (vulnerabilidades de dependencias, umbral high). En la sección Verificación del PR y en los pasos de CI va el comando real ya resuelto, nunca el símbolo.

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
| `build` | Sistema de build, bundling, configuración del compilador o del monorepo |
| `perf` | Mejora medible de rendimiento sin cambio funcional |
| `revert` | Revierte un commit; body con el hash revertido |

`scope` = carpeta del bounded context (`orders`, `billing`, `identity`) o uno transversal: `kernel` (shared-kernel), `web` (frontend), `infra`, `docs`, `ci`, `deps`. Un commit toca un scope; si toca dos contextos, son dos commits. Ejemplos: `feat(orders): allow cancelling an order before dispatch` · `chore(deps): pin http client to 2.4.1`. Idioma del mensaje de commit: **inglés** (imperativo, minúscula inicial); docs, ADRs y specs siguen en español neutro. **Cómo se verifica:** validador de convención de commits (§9) con lista cerrada de types, scope obligatorio, header ≤ 72, sin punto final.

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

**Cómo se verifica:** protección de rama en `develop`/`main` (PR obligatorio, checks requeridos, sin force-push); hooks de pre-commit (escaneo de secretos, validación de commits) nunca se saltan.

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

No va en el PR (vive en `docs/sdd/<feature>/` y en la conversación): referencias a otros PR, personas, ADRs, análisis de riesgo, orden de merge, alternativas descartadas, avisos, checklists, capturas, emojis, firmas. La plantilla de PR del repo contiene solo esas tres cabeceras.

```bash
gh pr create --base develop --title "feat(orders): allow cancelling an order before dispatch" --body "$(cat <<'EOF'
## Qué cambia
Agrega `Order.cancel()` con invariante de estado y `POST /orders/:id/cancel`; emite `orders.order.cancelled` una sola vez.
## Por qué
El flujo de devolución requiere cancelar antes del despacho.
## Verificación
<typecheck> → 0 errores
<lint> → 0 errores (boundaries incluido)
<test> → 214 passed
<test:integration> → 38 passed (cross-tenant incluido)
<audit> → sin vulnerabilidades high/critical
EOF
)"
```

En el PR real, cada `<símbolo>` se reemplaza por el comando resuelto. **Cómo se verifica:** el paso 10 de §8 falla si el título o el body del PR mencionan atribución de IA; el paso 11 rechaza cualquier cabecera `## ` distinta de las tres.

## 8. CI mínimo (orden fijo)

| # | Paso | Comando | Qué corta |
|---|---|---|---|
| 1 | Install | `<install>` | Lockfile desactualizado |
| 2 | Lint (incluye boundaries) | `<lint>` | Import ilegal entre capas/contextos, reloj/random en domain |
| 3 | Typecheck | `<typecheck>` | Error de tipos o de análisis estático en cualquier paquete |
| 4 | Test | `<test>` | Unit + handler (sin infraestructura) |
| 5 | Test integración | `<test:integration>` | Repo contra base de datos real con **rol de app sin bypass de aislamiento** (un superusuario ignora las políticas de fila y esconde fugas cross-tenant) + e2e |
| 6 | Build | `<build>` | Build roto de cualquier artefacto |
| 7 | Audit | `<audit>` | Vulnerabilidad high/critical |
| 8 | Escaneo de secretos | escáner de secretos sobre el historial del PR | Secreto en el historial del PR |
| 9 | Convención de commits | validador sobre los commits del PR y el título | Formato de §1 |
| 10 | Trailers de IA | grep de §9 sobre commits, título y body | Atribución de IA en commits o PR |
| 11 | Plantilla de PR | validación de cabeceras del body | Cabecera `## ` distinta de las tres de §7 |

Suite completa en cada PR; el filtrado por paquetes afectados solo sirve para acelerar `<build>`, nunca para saltar tests. Secretos de CI en environments del proveedor; nunca en archivos de configuración del monorepo, en cache remoto ni en logs. El stack instalado provee la plantilla concreta (`templates/ci.yml`).

## 9. Validación de commits y trailers

Independiente del stack: el validador de convención de commits corre sobre el rango `base..head` del PR y sobre el título; el chequeo de trailers es un `grep` sobre el mismo rango más título y body:

```bash
git log --format='%an <%ae>%n%B' "$BASE_SHA".."$HEAD_SHA" | grep -iE 'co-authored-by|claude-session|generated with|anthropic|claude\.ai' && exit 1
printf '%s\n%s' "$PR_TITLE" "$PR_BODY" | grep -iE 'co-authored-by|claude-session|generated with|anthropic|claude\.ai' && exit 1
```

Reglas del validador: lista cerrada con los diez types de §1, scope obligatorio, header ≤ 72, sin punto final. Pre-commit local: validación del mensaje + escaneo de secretos sobre lo staged. La herramienta concreta la fija el stack instalado.

## 10. Deploy

- Staging: automático en cada push a `develop` (o `main` en trunk-based) tras CI verde. Producción: **solo promoción manual** (disparo manual con confirmación literal o tag `v*`) sobre un environment `production` protegido con required reviewer; nada llega a producción sin pasar por staging.
- Orden fijo: **migraciones → api → web**. Las migraciones deben ser compatibles con el código anterior (expand/contract; ver la skill de persistencia del stack).
- Rollback: redeploy de la versión anterior de api/web; migraciones **forward-only** (se corrige con una migración nueva, nunca `down`).
- Secretos por entorno (`staging` y `production` nunca comparten uno), en el environment del proveedor; jamás en configuración versionada, en `env` de tareas cacheadas ni en logs.
- Ninguna acción sobre producción sin OK humano explícito que nombre "producción". **Cómo se verifica:** el workflow de producción declara `environment: production` en cada job y no se dispara por push a ramas; `grep -rn "secrets\." <config del monorepo>` vacío.

## 11. Checklist

- [ ] ¿Símbolos de §0 resueltos desde `CLAUDE.md` §6 / `testing-conventions`, y `git config --local user.name/user.email` verificados antes del primer commit?
- [ ] ¿Cada commit `type(scope): summary` en inglés, ≤ 72, scope único?
- [ ] ¿`git log -1 --format='%an <%ae>%n%B' | grep -iE 'co-authored-by|claude-session|generated with|anthropic'` vacío tras cada commit?
- [ ] ¿Se preguntó "¿misma rama o nueva?" y "¿abro el PR?" y se esperó respuesta?
- [ ] ¿Rama `feat|fix|chore/<slug>` desde `develop`; sin push a `develop`/`main`, sin `--force`, sin `--no-verify`? ¿Release `develop` → `main` con merge commit (nunca squash)?
- [ ] ¿PR con exactamente las tres secciones y resultados literales en Verificación?
- [ ] ¿CI en el orden de §8 con base de datos bajo rol de app sin bypass; commits, trailers y plantilla de PR como pasos con nombre?
- [ ] ¿Deploy migraciones → api → web; producción solo por promoción manual en environment protegido?
