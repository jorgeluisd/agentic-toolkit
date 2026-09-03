# CLAUDE.md — <Producto>

> Solo lo estable e inviolable del producto, más punteros. El estado vive en el plan/backlog.
> El proceso (pipeline, gates, TDD, commits, PR, memoria) lo define el plugin `sdd-tdd-core`; las reglas técnicas, el plugin de stack instalado.
> Ante conflicto de proceso gana el plugin; ante conflicto de invariante de producto gana este archivo.

## 0. Fuentes de verdad
| Qué | Dónde |
|---|---|
| Decisiones (ADR) | `docs/adr/` (formato `ADR-NNNN-<slug>.md`, estados PROPUESTO/ACEPTADO/REEMPLAZADO) |
| Plan / backlog | `docs/ROADMAP.md` · `docs/BACKLOG.md` (IDs `<PREFIJO>-NNN`) |
| Features SDD | `docs/sdd/<NNNN>-<slug>/` |
| Invariantes de producto | `.claude/skills/<producto>-invariants/SKILL.md` |

## 1. Producto en 3 líneas
<qué es, para quién, en qué fase está. Una línea por gate vigente si los hay.>

## 2. Stack locked
| Capa | Tecnología | ADR |
|---|---|---|
| Backend | <framework · runtime · gestor de paquetes> | ADR-… |
| Datos | <motor · ORM · aislamiento (RLS u otro)> | ADR-… |
| Auth | … | ADR-… |
| Frontend | <framework> | ADR-… |
| Jobs | <cola> | ADR-… |
| Infra | … | ADR-… |
Un major de cualquiera de estas exige ADR.

## 3. Mapa screaming (bounded contexts)
| Contexto | Ruta | Estado |
|---|---|---|
| `<context-a>` | `apps/api/src/contexts/<context-a>/` | MVP |
| `<context-b>` | … | diferido |
Estos nombres son los `scope` válidos de los commits (más `kernel`, `web`, `infra`, `docs`, `ci`, `deps`).

## 4. Invariantes del producto (≤ 10, numeradas, con ADR)
1. Tenant: campo `<tenant_field>`, helper `<TenantContext>`; viene del contexto de auth, nunca del body. (ADR-…)
2. <datos sensibles / dinero / firma / auditoría…>
3. …
Detalle y checks en la skill local de invariantes.

## 5. Prohibiciones específicas (solo las que NO cubre el plugin)
- …

## 6. Comandos
| Check | Comando |
|---|---|
| typecheck | `<comando>` |
| lint (incluye boundaries) | `<comando>` |
| test (unit + handler) | `<comando>` |
| test:file (un archivo o caso) | `<comando> <archivo> -t <caso>` |
| test:integration | `<comando>` |
| build | `<comando>` |
| audit | `<comando>` |
| dev / db local | `<comando>` |
Estos son los símbolos que usan `strict-tdd`, `delivery-workflow`, el `verifier` y `/check-arch`. Plugin de stack instalado: `<stack-typescript | …>`.
Configuración de hooks del core: `.claude/sdd-hooks.env` (`SDD_PROD_MARKERS`, `SDD_BASE_BRANCH`, `SDD_TENANT_FIELD`, `SDD_TEST_CMD_RE`, `SDD_COMMENT_MAX_BLOCK`, `SDD_COMMENT_MAX_PCT`).

## 7. Idioma
Código, identificadores y mensajes de commit en inglés; docs, ADRs, specs y comentarios en español neutro. Copy de usuario final: `<dialecto del producto>`.

## 8. Git y entrega
Rama base `develop` (release a `main` con merge commit). Ramas `feat/<slug>`, `fix/<slug>`, `chore/<slug>`. Merge lo hace el humano en GATE 2. Deploy: staging automático; producción por promoción manual.

## 9. Referencias locales
- Skill de invariantes: `.claude/skills/<producto>-invariants/`
- Memoria persistente: `<sistema y tags>` (o "ninguna")
- Assets no versionados: …
