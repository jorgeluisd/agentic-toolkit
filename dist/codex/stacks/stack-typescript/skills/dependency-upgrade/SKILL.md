---
name: dependency-upgrade
description: "Reglas duras para dependencias con pnpm: versiones exactas con save-exact, madurez de 72 h verificada en el registry, scripts de instalación solo con aprobación explícita, flujo por grupos con checks, ADR para majors del stack, audit y lockfile. Usar cuando se agrega, sube o fija un paquete."
---

# Dependencias: agregar, actualizar, fijar

Gestor único: **pnpm**. `npm install`/`yarn` prohibidos (generan otro lockfile y saltan `onlyBuiltDependencies`); `npm view` se usa solo para consultar el registry. **Cómo se verifica:** `git ls-files | grep -E 'package-lock.json|yarn.lock'` vacío; `packageManager` fijado en `package.json` raíz (`"pnpm@<versión exacta>"`).

## 1. Reglas duras

| Regla | Mecánica | Cómo se verifica |
|---|---|---|
| **Versiones exactas.** Nunca `^`, `~`, `latest`, `*` ni rangos en `dependencies`/`devDependencies` | `.npmrc`: `save-exact=true`; al editar a mano, escribir la versión literal (`"zod": "3.25.7"`) | Grep de rangos de §3 vacío |
| **Madurez ≥ 72 h.** Solo se adopta una versión publicada hace al menos 72 h en npm | `.npmrc`: `minimum-release-age=4320` (minutos; requiere pnpm ≥ 10.16). Con pnpm menor, verificación manual por paquete (§3) | `npm view <pkg>@<v> time --json` → `now - time[v] ≥ 72h` |
| **Scripts de instalación bloqueados.** `preinstall`/`install`/`postinstall`/`prepare` de dependencias no corren sin aprobación explícita del humano, paquete por paquete | Bloqueo por defecto de pnpm; allowlist mínima en `pnpm.onlyBuiltDependencies`; `pnpm approve-builds` solo tras OK | `npm view <pkg>@<v> scripts --json` inspeccionado antes de instalar; diff de `onlyBuiltDependencies` en el PR |
| **Major del stack → ADR antes de tocar nada** (TypeScript, Node, pnpm, NestJS, Next.js, React, Tailwind, Postgres, Drizzle, Vitest, zod, pino, pg-boss) | ADR en `docs/adr/` con plan de migración y rollback; PR aparte del bump | El PR del major referencia el ADR en `docs/sdd/`, no en el cuerpo del PR |
| **Lockfile siempre commiteado** y congelado en CI | `pnpm-lock.yaml` en el mismo commit que `package.json`; CI con `pnpm install --frozen-lockfile` | `git status --porcelain pnpm-lock.yaml` vacío tras `pnpm install` |
| **Sin vulnerabilidades high/critical** | `pnpm audit --audit-level=high` local y en CI | Salida `No known vulnerabilities found` o override justificado en `pnpm.auditConfig.ignoreCves` con fecha de revisión |
| Versión `deprecated` o despublicada no se adopta aunque cumpla las 72 h | `npm view <pkg>@<v> deprecated` vacío | Mismo comando |

## 2. Configuración del repo

```ini
# .npmrc (raíz)
save-exact=true
minimum-release-age=4320
engine-strict=true
```

```jsonc
// package.json raíz
{
  "packageManager": "pnpm@10.17.0",
  "engines": { "node": "22.x", "pnpm": "10.x" },
  "pnpm": {
    "onlyBuiltDependencies": ["esbuild"],   // solo lo aprobado explícitamente, con el motivo en el ADR o el PR
    "overrides": {}                          // parches de seguridad transitivos; cada entrada con comentario de CVE
  }
}
```

**Cómo se verifica:** `pnpm --version` cumple `engines.pnpm`; `grep -c "save-exact=true" .npmrc` = 1.

## 3. Comandos

```bash
# Línea base verde ANTES de tocar nada (la comparación posterior depende de esto)
pnpm install --frozen-lockfile && pnpm typecheck && pnpm lint && pnpm test

# Inventario de todo el monorepo; separar patch/minor de major
pnpm outdated -r

# Fecha de publicación de una versión puntual (madurez ≥ 72 h)
npm view <pkg>@<v> time --json
# Todas las versiones con fecha, para elegir la última madura
npm view <pkg> time --json | node -e 'const t=JSON.parse(require("fs").readFileSync(0,"utf8"));const lim=Date.now()-72*3600e3;console.log(Object.entries(t).filter(([k,d])=>k!=="created"&&k!=="modified"&&Date.parse(d)<=lim).at(-1))'

# Scripts de ciclo de vida del paquete (preinstall/install/postinstall/prepare)
npm view <pkg>@<v> scripts --json
# Estado de deprecación
npm view <pkg>@<v> deprecated

# Instalar/subir con versión exacta (save-exact ya la clava; el @<v> evita "latest")
pnpm add <pkg>@<v> --filter <workspace>
pnpm add -D <pkg>@<v> -w                      # tooling en la raíz

# Build scripts ignorados por pnpm → SOLO con OK explícito del humano, uno por uno
pnpm approve-builds

# Rangos residuales (debe salir vacío)
grep -REn '"\^|"~|"latest"|"\*"' --include=package.json apps packages package.json

# Vulnerabilidades (debe salir limpio)
pnpm audit --audit-level=high
```

## 4. Flujo por grupos

1. **Rama** `chore/deps-<alcance>` desde `develop` (ver skill `delivery-workflow`). Línea base verde guardada (§3, primer comando). Si la base está roja, se reporta y se detiene: no se mezcla un bump con un fix.
2. **Inventario** con `pnpm outdated -r`. Clasificar: patch/minor (grupo normal) vs major (plan de migración; si es del stack, ADR primero).
3. **Elegir versión** por paquete: última que cumpla madurez ≥ 72 h y no esté `deprecated`. Registrar en `docs/sdd/<feature>/` cuando se evitó la última versión por la regla.
4. **Inspeccionar scripts** de cada paquete nuevo o subido (`npm view … scripts --json`). Si hay alguno, detenerse y presentar al humano: paquete, versión, script literal, qué hace. Sin OK explícito no se instala ni se aprueba. Nunca aprobación masiva ni flags que desactiven el bloqueo.
5. **Instalar por grupos**, en este orden, con `pnpm typecheck && pnpm lint && pnpm test` verde **entre cada grupo** (y `pnpm test:integration` si el grupo toca Drizzle, Postgres o pg-boss):

   | Grupo | Contenido | Check adicional |
   |---|---|---|
   | Tooling | TypeScript, ESLint y plugins (incluido boundaries), Prettier, Vitest, commitlint, turbo | Reformat/relint en commit aparte `chore(deps): …` solo de formato |
   | Framework | NestJS, Next.js, React, Tailwind, Drizzle/drizzle-kit, pg-boss, pino | Migration guide oficial; `pnpm build` |
   | Libs | zod, utilidades, SDKs externos | Contratos en `packages/contracts` siguen compilando en web y api |
6. **Breaking changes**: seguir la guía oficial de migración del major; ajustar código y tests en el mismo PR del bump; si una convención del plugin queda obsoleta, actualizar la skill o el ADR correspondiente.
7. **Cierre**: `grep` de rangos vacío, `pnpm audit --audit-level=high` limpio, lockfile commiteado, `pnpm install --frozen-lockfile` reproduce el árbol. PR a `develop` con la plantilla de tres secciones; en Verificación, los comandos de §3 con salida literal.

Un PR por grupo cuando el diff supera ~10 paquetes o incluye un major; nunca un PR "sube todo".

## 5. Prohibiciones

| Prohibido | En su lugar |
|---|---|
| `npm install`, `yarn`, `npx <cli-que-instala>` en el repo | `pnpm add`, `pnpm dlx` (con versión exacta) |
| `pnpm update --latest`, `pnpm add <pkg>` sin `@<v>` | Versión elegida por madurez y escrita explícita |
| `^`/`~`/`latest`/`*` en cualquier `package.json` del workspace | `save-exact=true` + grep de §3 |
| `pnpm approve-builds` sin OK humano por paquete; `strict-dep-builds=false`; `dangerouslyAllowAllBuilds` | Allowlist mínima en `onlyBuiltDependencies` tras aprobación |
| Major de una dependencia del stack sin ADR | ADR con plan y rollback, luego PR aparte |
| Instalar un `overrides` o `patch` sin comentario de CVE/issue | Entrada documentada con fecha de revisión |
| Bump mezclado con cambios funcionales | PR `chore(deps)` aislado |
| Ignorar el aviso "Ignored build scripts" de pnpm | Tratarlo como bloqueo hasta decidir |

## 6. Checklist

- [ ] ¿Línea base verde guardada antes de tocar nada?
- [ ] ¿`pnpm outdated -r` clasificado en patch/minor vs major? ¿Major del stack con ADR previo?
- [ ] ¿Cada versión nueva con ≥ 72 h publicada (`npm view <pkg>@<v> time --json`) y no `deprecated`?
- [ ] ¿`npm view <pkg>@<v> scripts --json` revisado; ningún script aprobado sin OK explícito; `onlyBuiltDependencies` mínimo?
- [ ] ¿Instalación por grupos tooling → framework → libs con typecheck + lint + test verdes entre grupos?
- [ ] ¿`grep -REn '"\^|"~|"latest"|"\*"' --include=package.json …` vacío? ¿`save-exact=true` y `minimum-release-age=4320` en `.npmrc`?
- [ ] ¿`pnpm audit --audit-level=high` limpio? ¿`pnpm-lock.yaml` commiteado y `--frozen-lockfile` reproducible?
- [ ] ¿PR `chore(deps)` aislado, a `develop`, con la plantilla de tres secciones y salidas literales?
