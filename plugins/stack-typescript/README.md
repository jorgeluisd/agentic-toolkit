# stack-typescript

Skills técnicas del stack TypeScript para [`sdd-tdd-core`](../sdd-tdd-core): **NestJS + Next.js + Drizzle/Postgres + RLS + Vitest**, con Onion + Screaming Architecture y enforcement por ESLint boundaries.

Este plugin no define proceso — eso lo hace el core. Define **cómo se escribe el código**: en qué capa va cada archivo, cómo se modela el dominio, cómo se manejan errores, cómo se aísla un tenant, dónde va cada test y qué está prohibido.

---

## Instalación

```bash
claude plugin marketplace add jorgeluisd/agentic-toolkit
claude plugin install sdd-tdd-core@agentic-toolkit      # requerido
claude plugin install stack-typescript@agentic-toolkit
```

Instalarlo solo, sin el core, no tiene sentido: aporta skills que el pipeline carga, pero no el pipeline.

---

## Skills

Claude las carga solo cuando aplican, según la `description` de cada una.

| Skill | Cubre |
|---|---|
| **`onion-screaming-architecture`** | Capas Onion, matriz de imports, carpetas por bounded context, sufijos de archivo, enforcement con `eslint-plugin-boundaries`. Al crear o mover un archivo, decidir capa o contexto, o cuando el lint marca boundaries |
| **`domain-modeling`** | Aggregates, value objects y eventos en TypeScript puro: constructor privado + `create()` con `Result`, `rehydrate()`, `Identifier<Brand>`, `Money` entero, tiempo e ids inyectados, append-only con compensación |
| **`application-cqrs-jobs`** | Commands/Queries con `{ input }` único y tenant en `ctx`, handlers, puertos + `Symbol`, eventos con outbox, jobs `pg-boss` idempotentes por tenant, controllers finos con zod strict y mappers |
| **`errors-and-result`** | Familias `DomainError`/`ApplicationError`/`InfrastructureError` con `code` y `httpStatus`, `publicMessage` sin PII, `Result<T,E>` en domain/application, `unwrapOrThrow` en presentation, caza del `Result` descartado |
| **`persistence-drizzle`** | Schema Drizzle sobre Postgres: naming, tipos, ids de la app, `varchar` + `CHECK` sin `pgEnum`, migraciones aditivas expand/contract con RLS dentro, journal, pooler `prepare:false`, `SET LOCAL`, `SECURITY DEFINER`, repos con `rehydrate` |
| **`multi-tenancy-rls`** | Tenant desde auth y nunca del body, `TenantContext.run` con `SET LOCAL`, RLS `ENABLE`+`FORCE`+`USING`+`WITH CHECK` fail-closed, roles sin `BYPASSRLS`, autorización doble, 404 vs 403, jobs por tenant, tests cross-tenant |
| **`testing-conventions`** | Cuatro niveles de test con sufijos y comandos, Vitest como runner único también en NestJS, cobertura por capa, fakes de puertos en vez de mocks, aserción de `code`, tests de tipos, integración contra Postgres real, e2e acotado |
| **`security-baseline`** | OWASP con mitigación mecánica, JWT de un algoritmo, env con zod, webhooks HMAC, validación strict, allowlist SSRF, headers y rate limit con test, PII fuera de artefactos, cifrado envelope |
| **`logging-pino`** | `pino` y `nestjs-pino`: `redact` por path, niveles por entorno, objeto primero y mensaje `{context}.{action}.{outcome}`, campo `err`, `traceId` propagado a jobs, catálogo de eventos críticos, test anti-fuga de PII |
| **`frontend-next-react`** | Next.js App Router con Server Components por defecto, React 19 sin memo manual, `server-only`, Server Actions con zod y origen, consumo del API por contracts, errores por `code`, dinero en unidad menor, Tailwind 4 `@theme` + `cn()`, PWA idempotente, budgets Lighthouse |
| **`dependency-upgrade`** | Versiones exactas con `save-exact`, madurez de 72 h verificada en el registry, scripts de instalación solo con aprobación explícita, flujo por grupos con checks, ADR para majors del stack, `audit` y lockfile |

---

## Plantillas

| Plantilla | Destino | Qué trae |
|---|---|---|
| `templates/settings.json` | `.claude/settings.json` | Permisos del proyecto: `allow` para typecheck/lint/test/build y git de lectura y commit; `ask` para push, PR, instalación de paquetes, migraciones, `psql`, deploys; `deny` para `npm`/`yarn`, `--force`, `--no-verify`, `gh pr merge` y toda lectura o escritura de `.env*`, `*.pem`, `*.key`. Además fija `includeCoAuthoredBy: false` |
| `templates/ci.yml` | `.github/workflows/ci.yml` | Tres jobs: `checks` (typecheck, lint, tests unit e integración contra un Postgres de servicio), `supply-chain` (audit y lockfile) y `conventions` (commitlint) |
| `templates/commitlint.config.js` | raíz del proyecto | Types cerrados, scopes derivados de los bounded contexts reales más los transversales, subject en minúscula, header ≤ 72 |

Copiar y adaptar; ninguna se instala sola. El comando `/sdd-tdd-core:adopt` las aplica como parte de la migración.

---

## Escribir un plugin para otro stack

Este plugin es la referencia. Para soportar PHP, Python o Go, creá `plugins/stack-<lenguaje>/` con su `.claude-plugin/plugin.json` y sus `skills/<nombre>/SKILL.md`, y registralo en `.claude-plugin/marketplace.json`. Cubrí al menos arquitectura, convenciones de test (con los comandos reales que resuelven `<test>`, `<lint>` y `<typecheck>`), errores, persistencia y seguridad.

La `description` de cada skill es lo que Claude lee para decidir si la carga: tiene que decir **cuándo usarla**, no solo qué contiene.

---

## Licencia

[MIT](../../LICENSE) © Jorge Diaz
