# frontend-react-vite-pwa

**Cuándo aplica (trigger de la entrada de Knowledge):** PWA estática con React 19 + Vite, sin SSR, servida desde S3 + CloudFront: rutas con code splitting, service worker con vite-plugin-pwa, cola offline en IndexedDB con client_event_id idempotente y Web Locks, Web Share API con fallback a wa.me, tipos y cliente generados desde OpenAPI (openapi-typescript + openapi-fetch), errores por code, headers y caché en CloudFront, y presupuestos de carga como gate. Usar cuando se toca una SPA de Vite (web/ o apps/web sin Next), su service worker, la cola offline, el compartir o el consumo del API generado.

---

# Frontend: React 19 + Vite como PWA estática

La app es **un build estático**: `vite build` genera `dist/`, que se sube a S3 y se sirve por CloudFront. No hay servidor que despertar, no hay SSR, no hay Server Actions ni secretos en el front. El backend se consume solo por HTTP, con tipos generados del contrato OpenAPI. Para Next.js está la skill `frontend-next-react`; esta es para la SPA.

El dialecto del copy lo define el `AGENTS.md` del producto. Los estilos siguen `frontend-next-react` §5 (Tailwind 4 con `@theme`, `cn()`, shadcn), salvo las fuentes: se sirven desde el propio build (`@fontsource/*` o archivos en `public/`), nunca desde un CDN.

## 1. Estructura

```
web/
  src/
    main.tsx              # monta la app y registra el service worker
    routes/               # una carpeta por ruta; cada una se carga con lazy()
    features/<context>/   # componentes y hooks por contexto del backend
    api/
      schema.d.ts         # generado por openapi-typescript: no se edita
      client.ts           # createClient<paths> + middleware de auth y errores
    offline/outbox.ts     # cola de eventos (§4)
    share/share.ts        # Web Share + wa.me (§5)
    pwa/sw.ts             # service worker (injectManifest)
  vite.config.ts
```

| Regla | Cómo se verifica |
|---|---|
| Sin SSR ni código de servidor: ni `vite-plugin-ssr`, ni `react-dom/server`, ni handlers en el repo del front | `grep -rn 'react-dom/server' web/src` vacío |
| Variables de entorno solo públicas (`VITE_*`) y validadas con zod al arrancar; ningún secreto en el build | `web/src/env.ts` con zod; `grep -rn -e SECRET -e PASSWORD web/src` vacío |
| Una ruta, un chunk: `lazy(() => import('./routes/live'))`. La ruta pública del link en vivo **no** importa nada del panel del profe | Presupuesto por chunk de §7 |
| SPA en CloudFront: un error 403/404 de S3 devuelve `/index.html` con 200 (custom error response), o una CloudFront Function reescribe las rutas sin extensión | Config de CDK; un deep link (`/live/<token>`) abre en una pestaña nueva |

## 2. Contrato con el API

```ts
// web/src/api/client.ts
import createClient, { type Middleware } from 'openapi-fetch';
import type { paths } from './schema';
import { env } from '../env';
import { currentAccessToken } from '../auth/session';

const auth: Middleware = {
  async onRequest({ request }) {
    const token = await currentAccessToken();
    if (token) request.headers.set('Authorization', `Bearer ${token}`);
    return request;
  },
};

export const api = createClient<paths>({ baseUrl: env.VITE_API_URL });
api.use(auth);
```

| Regla | Cómo se verifica |
|---|---|
| Los tipos del API salen **solo** de `schema.d.ts`, que se genera con `openapi-typescript` (versión exacta en `package.json`) desde `api/openapi.yaml` | Job `contract` del CI del backend: regenera y hace `git diff --exit-code` |
| Las llamadas usan `api.GET/POST(...)`, que tipa path, params, body y respuesta. Nada de `fetch` crudo al API | `grep -rn "fetch(" web/src --include=*.ts --include=*.tsx` solo en `offline/` y en `api/` |
| Los errores se deciden por `code` del problem+json (`messageFor(code)`), nunca por el texto | Test de `messageFor` por `code` |
| El tenant nunca viaja en el body ni en un header propio: lo resuelve el API desde el token | El contrato no lo acepta; un body con `coachId` devuelve 400 |
| Dinero entero en unidad menor y formateado con `Intl.NumberFormat` (`frontend-next-react` §4) | Mismo grep de `parseFloat`/`toFixed` |
| El access token vive en memoria (lo maneja el módulo de sesión), nunca en `localStorage` ni en la caché del service worker | `grep -rn 'localStorage' web/src` sin tokens |

## 3. Service worker

`vite-plugin-pwa` con `strategies: 'injectManifest'` (SW propio en `src/pwa/sw.ts`, con Workbox), `registerType: 'prompt'` y el manifest con íconos, `display: 'standalone'` y `start_url`.

| Recurso | Estrategia | Por qué |
|---|---|---|
| App shell y assets con hash | Precache (lista del build) | Abre sin red y al instante desde el segundo uso |
| `index.html` | Network-first con fallback a la versión precacheada | Toma el deploy nuevo cuando hay red |
| GET del API con control de acceso (listas, fichas) | `network-only` | Lo que un usuario puede ver depende de permisos; una caché lo filtraría a otra sesión |
| Marcador en vivo | `network-only` más tiempo real (AppSync Events); al reconectar se vuelve a leer el estado | Un evento perdido durante el corte no se recupera del canal |
| POST/PUT/DELETE | Nunca los intercepta el SW: pasan por la cola de §4 | La idempotencia la da `clientEventId`, no el SW |

- **No se depende de Background Sync**: Safari en iPhone no lo implementa. La cola se vacía al arrancar, en `online`, en `visibilitychange` a visible, justo después de encolar y con un timer con backoff.
- Actualización: el SW nuevo queda esperando y la UI ofrece "Actualizar"; nunca `skipWaiting()` automático con una cola pendiente.
- Logout: borrar las cachés (`caches.keys()` → `caches.delete`), borrar IndexedDB salvo la cola pendiente, que se avisa antes, y `unregister()` del SW.

**Cómo se verifica:** test de logout que espera `caches.keys()` vacío; `grep -n 'NetworkOnly' web/src/pwa/sw.ts` cubre cada ruta con permisos; `grep -rn 'BackgroundSyncPlugin' web/src` vacío.

## 4. Cola offline idempotente

El delegado carga goles sin señal. Cada evento se guarda **primero** en IndexedDB con un `clientEventId` (UUID generado en el teléfono, `crypto.randomUUID()`), la UI lo muestra como pendiente y la cola lo manda cuando hay red. El API registra el `clientEventId` en la misma transacción (stack-go `persistence-sqlc-dsql` §5), así que mandar dos veces el mismo evento no duplica nada.

```ts
// web/src/offline/outbox.ts (núcleo; el archivo completo trae openOutbox y FlushResult)
export async function enqueue(db: Outbox, event: Pick<OutboxEvent, 'clientEventId' | 'path' | 'body'>, now = Date.now()) {
  const existing = await db.get('events', event.clientEventId);
  if (existing) return existing;
  const item: OutboxEvent = { ...event, createdAt: now, attempts: 0, status: 'pending' };
  await db.put('events', item);
  return item;
}

const retryable = (status: number) => status >= 500 || status === 408 || status === 429;

export async function flush(db: Outbox, send: Send): Promise<FlushResult> {
  const queue = (await db.getAllFromIndex('events', 'byCreatedAt')).filter((e) => e.status === 'pending');
  let sent = 0;
  let rejected = 0;
  for (const event of queue) {
    let res: Response;
    try {
      res = await send(event);
    } catch {
      await db.put('events', { ...event, attempts: event.attempts + 1 });
      break;
    }
    if (res.ok) {
      await db.delete('events', event.clientEventId);
      sent++;
    } else if (retryable(res.status)) {
      await db.put('events', { ...event, attempts: event.attempts + 1 });
      break;
    } else {
      await db.put('events', { ...event, status: 'rejected', rejectionCode: await problemCode(res) });
      rejected++;
    }
  }
  const pending = (await db.getAll('events')).filter((e) => e.status === 'pending').length;
  return { sent, rejected, pending };
}

export function withOutboxLock<T>(fn: () => Promise<T>, locks = globalThis.navigator?.locks) {
  if (!locks) return fn();
  return locks.request('outbox-flush', { ifAvailable: true }, (lock) => (lock ? fn() : undefined));
}
```

| Regla | Cómo se verifica |
|---|---|
| El evento se escribe en IndexedDB **antes** de intentar mandarlo; el ID lo genera el cliente y va en el body (`clientEventId` del contrato) | Test: encolar el mismo `clientEventId` dos veces deja una entrada |
| Se manda en orden de creación, de a uno. Ante red caída, 5xx, 408 o 429 se corta y se conserva el orden | Test: 503 y `TypeError` dejan todo pendiente con `attempts` incrementado; después se vacía |
| Un 2xx (también el replay del API) borra el evento | Test de flush con 200 |
| Un 4xx no reintentable queda `rejected` con su `code` y se **muestra**; nunca se descarta en silencio | Test: 409 `MATCH_NOT_LIVE` queda visible y el siguiente evento igual se manda |
| Una sola pestaña vacía la cola a la vez (`navigator.locks`, `ifAvailable`) | Test con un `LockManager` falso: sin lock no corre |
| Backoff exponencial hasta 30 s con jitter (`nextDelayMs`) | Test de `nextDelayMs` |
| `navigator.storage.persist()` al instalar, y la UI muestra cuántos eventos quedan pendientes | Revisión; contador visible en la pantalla de carga |
| Conflictos: el servidor manda (`last-write-wins` por su `updatedAt`); sin CRDT | El estado se vuelve a leer después de vaciar la cola |

Tests con Vitest + `fake-indexeddb/auto` (una base por test). El archivo de referencia completo, con sus tests, tiene 13 casos en verde.

## 5. Compartir por WhatsApp

```ts
// web/src/share/share.ts
export function waLink(text: string, phone?: string): string {
  const digits = phone?.replace(/\D/g, '') ?? '';
  return `https://wa.me/${digits}?text=${encodeURIComponent(text)}`;
}

export async function shareText(text: string, nav: Partial<Pick<Navigator, 'share' | 'canShare'>> = navigator,
  open: (url: string) => void = (url) => window.open(url, '_blank', 'noopener')): Promise<ShareOutcome> {
  const supported = typeof nav.share === 'function' && (!nav.canShare || nav.canShare({ text }));
  if (!supported) {
    open(waLink(text));
    return 'fallback';
  }
  try {
    await nav.share!({ text });
    return 'shared';
  } catch (err) {
    return err instanceof DOMException && err.name === 'AbortError' ? 'cancelled' : 'failed';
  }
}
```

| Regla | Cómo se verifica |
|---|---|
| `shareText` se llama **directo en el `onClick`**, sin `await` antes: el navegador exige la activación del usuario para abrir el menú | Revisión del handler; test de componente que hace click y espera la llamada a `share` |
| Sin Web Share → `https://wa.me/?text=<texto codificado>`. A una familia → `https://wa.me/<dígitos>?text=…`, con el número en formato internacional y sin `+` (normalizado al cargarlo) | Tests de `waLink` |
| Cancelar el menú (`AbortError`) no es un error; otra falla muestra el link `wa.me` como botón | Tests de `shareText` |
| El texto armado puede llevar nombres de alumnos: nunca se loguea ni se manda a analítica | Revisión; skill `logging-slog` del backend para lo que llegue al API |

## 6. Headers y caché (CloudFront)

| Recurso | Cache-Control |
|---|---|
| `index.html`, `sw.js`, `manifest.webmanifest` | `no-cache` |
| `assets/*` (con hash) | `public, max-age=31536000, immutable` |

Response headers policy de CloudFront: `Content-Security-Policy` con `default-src 'self'`, `script-src 'self'` (Vite no necesita inline), `connect-src 'self' <API> <endpoint wss de AppSync>`, `img-src 'self' data: <bucket de fotos>`, `frame-ancestors 'none'`; además HSTS, `X-Content-Type-Options: nosniff`, `Referrer-Policy: strict-origin-when-cross-origin` y `Permissions-Policy` mínima. La vista previa del link (título e imagen del partido en WhatsApp) la arma una CloudFront Function o una Lambda en el borde, no la SPA. **Cómo se verifica:** test de CDK (assertions) sobre la policy; `curl -sI` del deploy de staging en el smoke post-deploy.

## 7. Presupuestos de carga como gate

El objetivo del producto: el link en vivo, abierto desde WhatsApp en 4G por primera vez en el día, muestra el marcador en **2 s o menos**.

| Métrica | Presupuesto | Herramienta |
|---|---|---|
| JS inicial de la ruta `/live/:token` | ≤ 70 KB gzip | `size-limit` sobre `dist/` |
| JS inicial del panel (profe, delegado) | ≤ 150 KB gzip | `size-limit` |
| CSS total | ≤ 30 KB gzip | `size-limit` |
| LCP (móvil, 4G simulado) en `/live/:token` | ≤ 2,0 s | Lighthouse CI contra `vite preview` |
| INP / CLS | ≤ 200 ms / < 0,1 | Lighthouse CI |
| Accesibilidad | ≥ 95 | Lighthouse CI |

`pnpm --dir web exec size-limit` y `pnpm --dir web exec lhci autorun` corren en el CI del front y **fallan el PR** que se pase. Para bajar peso: code splitting por ruta, sin librerías de fechas pesadas (`Intl`), íconos importados uno por uno, e imágenes en AVIF/WebP con `width`/`height`. Accesibilidad mínima igual que `frontend-next-react` §8 (`eslint-plugin-jsx-a11y` en error).

## 8. Comandos

| Símbolo | Comando |
|---|---|
| `<typecheck>` | `pnpm --dir web typecheck` (`tsc --noEmit`) |
| `<lint>` | `pnpm --dir web lint` |
| `<test>` | `pnpm --dir web test` (Vitest + jsdom + `fake-indexeddb`) |
| `<build>` | `pnpm --dir web build` (`vite build`) |
| `<audit>` | `pnpm --dir web audit --audit-level=high` |

## 9. Prohibiciones

| Prohibido | En su lugar |
|---|---|
| SSR, Server Actions, secretos o `VITE_*` con valores privados | API + variables públicas validadas |
| Tipos del API escritos a mano o `fetch` crudo al API | `schema.d.ts` generado + `openapi-fetch` |
| Mandar un evento sin guardarlo antes en la cola, o sin `clientEventId` | `enqueue` y después `flush` |
| Descartar un evento rechazado en silencio | Estado `rejected` visible con su `code` |
| Depender de Background Sync | Vaciar la cola en arranque, `online`, `visibilitychange` y con timer |
| Cachear GETs con control de acceso | `network-only` |
| `await` antes de `navigator.share` en el click | Llamada directa en el handler |
| Fuentes o scripts desde un CDN | Assets del propio build y CSP `'self'` |
| Tokens en `localStorage` o en la caché del SW | Memoria, gestionada por el módulo de sesión |

## 10. Checklist

- [ ] ¿Build estático sin SSR, rutas con `lazy()` y la ruta del link en vivo liviana?
- [ ] ¿Tipos del API generados y llamadas con `openapi-fetch`, errores por `code`?
- [ ] ¿SW con `injectManifest`, `registerType: 'prompt'` y `network-only` para lo que tiene permisos?
- [ ] ¿Cola offline con `clientEventId`, orden, backoff, Web Locks y rechazos visibles, con sus tests?
- [ ] ¿Compartir sin `await` previo, fallback a `wa.me` y teléfono en dígitos?
- [ ] ¿CSP y caché de CloudFront según §6?
- [ ] ¿`size-limit` y Lighthouse CI dentro de los presupuestos de §7?
