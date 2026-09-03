---
name: security-baseline
description: "Baseline de seguridad verificable: OWASP con mitigación mecánica, JWT de un algoritmo, env con zod, webhooks HMAC, zod strict, SSRF allowlist, headers y rate limit con test, PII fuera de todo artefacto y cifrado envelope. Usar cuando se toca auth, inputs, secretos, webhooks o PII, o se revisa un PR."
---

# Seguridad: baseline

Cada regla trae su verificación (`cómo se verifica`). Si una regla no puede verificarse con comando, config o test, se convierte en hook del plugin o no cuenta como cumplida.

## 1. Los 5 puntos rojos (bloquean merge)

1. **Tenant/autorización**: tenant desde auth, guard + RLS, recurso ajeno → 404 (`multi-tenancy-rls`).
2. **Secretos**: solo en env validado al arrancar; jamás en código, tests, logs, commits, artefactos SDD ni memoria de sesión.
3. **Webhooks**: firma HMAC sobre raw body con `timingSafeEqual` antes de tocar el payload; luego encolar.
4. **PII/PHI**: nunca en logs, errores públicos, URLs, telemetría ni artefactos de proceso (§8).
5. **Inputs**: validación de borde que rechace claves desconocidas (NestJS: class-validator con `whitelist` + `forbidNonWhitelisted`; fuera de NestJS: zod `.strict()`), queries parametrizadas, uploads por magic bytes, límites y timeouts.

## 2. OWASP → mitigación mecánica

| OWASP 2021 | Mitigación | Cómo se verifica |
|---|---|---|
| A01 Broken Access Control | Guard de rol + RLS `FORCE` + `TenantContext.run` | `pnpm test:integration` incluye cross-tenant y el SQL de `pg_class` (`multi-tenancy-rls` §8) |
| A02 Cryptographic Failures | Secretos en env (`EnvSchema`), TLS, hash de contraseñas `argon2id`, clase alta con envelope (§9) | `gitleaks detect --no-git -v` limpio; `grep -rnE "md5\(|sha1\(|createHash\('(md5|sha1)'" apps packages` vacío |
| A03 Injection | Drizzle parametriza (`sql\`\`` es binding); class-validator `forbidNonWhitelisted` / zod `.strict()`; React escapa; sin `dangerouslySetInnerHTML` con datos de usuario | `grep -rn "sql.raw(" apps/api/src` vacío o cada uso revisado; `grep -rn dangerouslySetInnerHTML apps/web/src` vacío |
| A04 Insecure Design | Invariantes en `domain/`; la spec SDD incluye escenarios de abuso (doble envío, replay, enumeración) | Sección "Abuso" en `docs/sdd/<feature>/spec.md` con un test por escenario |
| A05 Security Misconfiguration | helmet + CSP + HSTS + `Referrer-Policy`; CORS allowlist; `FORCE ROW LEVEL SECURITY`; `.strict()` | e2e de headers (§7); `grep -rn "origin: '\*'\|origin: true" apps/api/src` vacío |
| A06 Vulnerable Components | `pnpm audit --audit-level=high`, `save-exact`, `minimum-release-age`, scripts bloqueados | CI falla en `audit`; `grep -REn '"\^|"~' --include=package.json .` vacío |
| A07 Auth Failures | JWT verificado por request, un algoritmo, `iss`/`aud` fijos; rate limit en `/auth/*`; roles re-validados en servidor | Unit del guard (401/403); test de throttle (§7) |
| A08 Data Integrity | HMAC en webhooks; lockfile commiteado; `pnpm install --frozen-lockfile` en CI; builds con `approve-builds` | e2e "firma inválida → 401"; CI con `--frozen-lockfile` |
| A09 Logging Failures / A10 SSRF | pino `redact` + catálogo + test de redact; `safeFetch` con allowlist, sin redirects, timeout | `logging-pino` §7 test `[REDACTED]`; unit host fuera de allowlist → `OUTBOUND_HOST_NOT_ALLOWED`; `grep -rnE "\bfetch\(" apps/api/src` solo dentro de `safeFetch` |

## 3. Auth y JWT

```ts
const jwks = createRemoteJWKSet(new URL(env.JWT_JWKS_URL));   // o una clave simétrica si el emisor es propio: nunca ambas
const { payload } = await jwtVerify(token, jwks, { issuer: env.JWT_ISSUER, audience: env.JWT_AUDIENCE, algorithms: [env.JWT_ALG] });
```

- `algorithms` con **un solo valor** configurado por env; sin lista ni "JWKS y si falla HS256" (alg confusion: el atacante firma con la clave pública como secreto HMAC).
- Verificación en **cada request** (guard global; rutas públicas con `@Public()` explícito y listadas en un test que las enumera).
- Roles y membresías se leen de la fuente del servidor (tabla de membresías o claims firmados por el servidor de auth), nunca de un campo del cliente.
- Contraseñas propias: `argon2id`; tokens de un solo uso (invitación, reset): aleatorios ≥ 256 bits, guardados hasheados, con expiración. Cambio de rol → invalidación de cache por evento.

## 4. Secretos

```ts
// config/env.ts — se importa antes que cualquier módulo; falla rápido
const EnvSchema = z.object({           // sin .strict(): process.env trae variables del SO
  NODE_ENV: z.enum(['development', 'test', 'staging', 'production']),
  DATABASE_URL: z.string().url(),
  JWT_JWKS_URL: z.string().url(), JWT_ISSUER: z.string().url(), JWT_AUDIENCE: z.string().min(1), JWT_ALG: z.enum(['RS256', 'ES256', 'HS256']),
  WEBHOOK_SECRET_PAYMENTS: z.string().min(32),
  CORS_ORIGINS: z.string().transform((s) => s.split(',').map((o) => o.trim())),
  OUTBOUND_ALLOWED_HOSTS: z.string().transform((s) => s.split(',')),
});
const parsed = EnvSchema.safeParse(process.env);
if (!parsed.success) { console.error('Invalid environment', parsed.error.flatten().fieldErrors); process.exit(1); }   // sin valores: solo nombres de campo
export const env = parsed.data;
```

- `.env*` en `.gitignore`; solo `.env.example` con placeholders y todas las claves. Staging y producción nunca comparten secretos; los secretos no entran a cachés de build (`turbo.json` `env` explícito, no `passThroughEnv` global). Un secreto nuevo: `EnvSchema` + `.env.example` + secret manager del entorno, en el mismo PR.
- **Cómo se verifica:** `gitleaks protect --staged` en pre-commit y `gitleaks detect` en CI; `git ls-files | grep -E '^\.env($|\.)' | grep -v example` vacío; el proceso con `DATABASE_URL` vacío termina con exit 1 antes de escuchar.

## 5. Webhooks

```ts
// main.ts: NestFactory.create(AppModule, { rawBody: true })
@Post('webhooks/payments') @HttpCode(200)
async receive(@Req() req: RawBodyRequest<Request>, @Headers('x-signature') received = '') {
  const raw = req.rawBody; if (!raw) throw new UnauthorizedException();
  const expected = createHmac('sha256', env.WEBHOOK_SECRET_PAYMENTS).update(raw).digest();
  const given = Buffer.from(received, 'hex');
  if (given.length !== expected.length || !timingSafeEqual(given, expected)) {    // timingSafeEqual lanza si difieren en longitud
    this.logger.warn({ provider: 'payments', ip: req.ip }, 'webhook.payments.signature_invalid');
    throw new UnauthorizedException();
  }
  const event = WebhookEnvelopeSchema.parse(JSON.parse(raw.toString('utf8')));
  await this.inbox.enqueue({ provider: 'payments', eventId: event.id, payload: event, traceId: req.id });   // UNIQUE (provider, event_id): replay → no-op
  return { received: true };
}
```

La firma se calcula sobre el **body crudo**, nunca sobre el JSON re-serializado. Procesar = job del worker que lee la tabla de inbox; el endpoint responde en milisegundos. Endpoint público sin firma (formularios): rate limit + `.strict()` + honeypot + tamaño máximo. **Cómo se verifica:** e2e con firma alterada → 401 y ninguna fila en inbox; mismo `eventId` dos veces → una fila.

## 6. Inputs, uploads, SSRF

| Regla | Config / código | Cómo se verifica |
|---|---|---|
| Rechazo de claves desconocidas en todo borde | NestJS: `ValidationPipe({ whitelist: true, forbidNonWhitelisted: true, transform: true })` global + DTOs con decoradores. Fuera de NestJS: zod `.strict()` (el default de zod **descarta** claves desconocidas en silencio) | `grep -n "forbidNonWhitelisted: true" apps/api/src/main.ts`; `grep -rLE "\.strict\(\)" apps/web/**/*.schema.ts` vacío |
| Body size limit y uploads | `app.use(json({ limit: '1mb' }))` (y `urlencoded`); `multer` con `limits.fileSize`; `fileTypeFromBuffer` (magic bytes, no `mimetype` del cliente); allowlist de tipos; nombre = UUID; bucket privado; URL firmada con expiración | e2e: body de 2 MB → 413; unit: `.exe` renombrado `.png` → `UPLOAD_TYPE_NOT_ALLOWED` |
| Timeouts salientes | `AbortSignal.timeout(ms)` en todo fetch; reintentos solo en jobs | Sin `fetch(` fuera de `safeFetch` |
| Queries / hojas de cálculo | Drizzle query builder o `sql\`\`` (binding); `sql.raw` solo con literales del código. Importaciones: límite de filas/celdas, sin evaluar fórmulas, en un job | grep de A03; fixture con 100k filas → `IMPORT_TOO_LARGE` |

```ts
export async function safeFetch(url: string, init: RequestInit = {}) {
  const u = new URL(url);
  if (u.protocol !== 'https:' || !env.OUTBOUND_ALLOWED_HOSTS.includes(u.hostname)) throw new OutboundHostNotAllowedError(u.hostname);
  return fetch(u, { ...init, redirect: 'manual', signal: AbortSignal.timeout(5_000) });   // sin redirects: un 302 a 169.254.169.254 no se sigue
}
```

Toda URL provista por un usuario (avatar por URL, callback, importación) pasa por `safeFetch`; IPs literales, `localhost` y hosts internos nunca están en la allowlist.

## 7. Headers, CORS y rate limiting

```ts
app.use(helmet({ contentSecurityPolicy: { directives: { defaultSrc: ["'self'"], frameAncestors: ["'none'"] } },
  strictTransportSecurity: { maxAge: 31536000, includeSubDomains: true }, referrerPolicy: { policy: 'strict-origin-when-cross-origin' } }));
app.enableCors({ origin: env.CORS_ORIGINS, credentials: true, allowedHeaders: ['authorization', 'content-type', 'x-tenant-id'] });
// ThrottlerModule.forRoot([{ ttl: 900_000, limit: 5 }]) en /auth/*; público 30/h por IP; el resto según config, nunca hardcodeado
```

```ts
it('throttles login after the configured attempts', async () => {
  for (let i = 0; i < 5; i++) await request(server).post('/auth/login').send(wrongCredentials).expect(401);
  await request(server).post('/auth/login').send(wrongCredentials).expect(429);
});
it('sends security headers', async () => {
  const res = await request(server).get('/health');
  expect(res.headers['strict-transport-security']).toMatch(/max-age=/);
  expect(res.headers['content-security-policy']).toContain("default-src 'self'");
  expect(res.headers['x-powered-by']).toBeUndefined();
});
```

Next.js: los mismos headers en `next.config` `headers()`; Server Actions con zod `.strict()` y verificación de `Origin` contra la allowlist.

## 8. PII/PHI: dónde nunca

| Lugar | Regla | Cómo se verifica |
|---|---|---|
| Logs | `redact` por path + **nunca interpolar** en el mensaje (`logging-pino`) | Test `[REDACTED]` |
| Errores públicos | `publicMessage`/`publicDetails` sin PII ni ids internos (`errors-and-result`) | Revisión del verifier + grep de E.164/email en `*.error.ts` |
| URLs | Nada de PII en path ni query (queda en logs de proxies e historial); usar ids opacos y POST | `grep -rnE "\?(email|phone|document)=" apps` vacío |
| Telemetría / APM / analytics | Solo ids y métricas; sin nombres, teléfonos, direcciones | Revisión del schema de eventos |
| `docs/sdd/**` (spec, design, apply-progress, `tdd-evidence.log`), memoria de sesión | Escenarios con datos sintéticos; nunca pegar salidas con datos reales | Hook `PostToolUse` de PII sobre `docs/**`, `**/*.md` |
| Commits, nombres de rama, PR, capturas | Sin nombres de clientes ni datos personales | `git log --format=%B origin/develop.. \| grep -E '\+[0-9]{8,15}\|@'` vacío |
| Fixtures, seeds, entornos no productivos | Sintéticos (`testing-conventions` §8); nunca copia de producción con datos reales | Hook de PII sobre `**/*.spec.ts`, `fixtures/**`; staging sin job de "copiar prod" |

Exports con PII: rol explícito, auditados (`actor`, `tenantId`, filtro, `rowCount`, timestamp) con evento `pii.exported`, entregados por URL firmada con expiración corta. Búsquedas sobre datos sensibles registran el **hash** del término, no el texto.

## 9. Datos de clase alta (PHI, identificadores nacionales, financieros)

| Mecanismo | Implementación | Qué resuelve |
|---|---|---|
| Cifrado envelope | KEK en KMS; DEK por tenant; AEAD (`aes-256-gcm`) sobre columnas `*_ciphertext bytea` + `dek_id` | Un dump de la base no expone el dato; rotación por tenant |
| Blind index | `*_bidx = HMAC-SHA256(key_tenant, normalize(valor))` para búsqueda por igualdad y dedupe | Buscar sin exponer ni indexar el texto |
| Audit log append-only con hash-chain | Trigger que inserta `prev_hash`, `hash = sha256(prev_hash || fila)`; sin `UPDATE`/`DELETE`; el evento referencia ids, jamás copia el contenido | Detectar reescritura; retención ≥ la del dato |
| Crypto-shredding | Destruir la DEK del tenant = borrado efectivo (offboarding, derecho al olvido) | Borrado verificable con backups aún existentes |
| MFA + una sesión = un contexto; respuestas uniformes | TOTP/passkey para roles con acceso a clase alta; cambiar de tenant = refresh; mismo status (404) y tiempo para "no existe" y "ajeno" | Robo de credencial no basta; sin mezcla de tenants; anti-enumeración |

## 10. Dependencias

`pnpm audit --audit-level=high` en CI (high/critical bloquean); `.npmrc`: `save-exact=true`, `minimum-release-age=4320` (72 h, pnpm ≥ 10.16); scripts de instalación bloqueados por defecto, `pnpm approve-builds` solo con OK explícito y tras `npm view <pkg> scripts --json`; lockfile commiteado y `--frozen-lockfile` en CI; gitleaks en pre-commit y CI. **Cómo se verifica:** `grep -REn '"\^|"~' --include=package.json .` vacío; `npm view <pkg>@<v> time --json` muestra ≥ 72 h.

## 11. Producción

- Ninguna acción sobre producción (migración, script, `UPDATE`, deploy, cambio de secreto) sin OK humano explícito que **nombre "producción"** en la conversación; el hook `guard-prod` del plugin bloquea comandos con marcadores de prod sin ese OK.
- **Nunca** tests, harness "con ROLLBACK" ni scripts de verificación contra la base de producción: el esquema real se prueba en staging o en una restauración del backup. `vitest`/`node scripts/*` con `DATABASE_URL` de producción → rechazado. Una lectura (conteo) también se avisa antes; salida sin PII.

## 12. Checklist de PR review

- [ ] ¿Tenant desde auth; guard + RLS; cross-tenant testeado; recurso ajeno → 404?
- [ ] ¿Ningún secreto en diff, tests, docs ni evidencia; env nuevo en `EnvSchema` + `.env.example`; gitleaks limpio?
- [ ] ¿JWT con un algoritmo, `iss`/`aud`; rutas públicas con `@Public()` enumeradas en test?
- [ ] ¿Webhook: HMAC sobre raw body, `timingSafeEqual` con check de longitud, inbox idempotente, e2e firma inválida → 401?
- [ ] ¿DTOs con `forbidNonWhitelisted` (NestJS) o schemas `.strict()` (fuera); body limit; uploads por magic bytes; `safeFetch`; sin `sql.raw` con datos de usuario; helmet/CSP/HSTS/Referrer-Policy, CORS allowlist y throttle con tests?
- [ ] ¿PII fuera de logs, errores, URLs, telemetría, `docs/sdd/**`, commits, ramas, fixtures? ¿Exports auditados?
- [ ] ¿Dato de clase alta con envelope + blind index + audit hash-chain?
- [ ] ¿`pnpm audit` sin high/critical; versiones exactas; lockfile; sin scripts aprobados sin OK; nada tocó producción ni apunta a ella?
