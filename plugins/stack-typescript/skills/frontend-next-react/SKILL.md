---
name: frontend-next-react
description: "Next.js App Router con Server Components por defecto, React 19 sin memo manual, server-only, Server Actions con zod y origen, consumo del API por contracts, errores por code, dinero en unidad menor, Tailwind 4 @theme + cn(), PWA idempotente y budgets Lighthouse. Usar cuando se toca apps/web."
---

# Frontend: Next.js App Router + React 19 + Tailwind 4

`apps/web` es un cliente del API. Importa **solo** `packages/contracts` (schemas zod + tipos); nunca `domain/`, `application/` ni `infrastructure/` de ningún contexto. Toda regla de negocio vive en el backend; el web valida UX, presenta y encola. **Cómo se verifica:** `pnpm lint` (`eslint-plugin-boundaries`: `apps/web` solo puede importar `contracts`; ver skill `onion-screaming-architecture`) y `grep -rnE "from '(@[a-z-]+/)?(api|domain|application|infrastructure)" apps/web/src` vacío.

El dialecto del copy de usuario (neutro, regional, tuteo/ustedeo) lo define el `CLAUDE.md` de cada producto; esta skill no lo fija. Identificadores de código siempre en inglés.

## 1. Server vs Client Components

Server Component por defecto (sin directiva). `'use client'` solo en la hoja interactiva, nunca en `layout.tsx`, `page.tsx` ni en contenedores que solo pasan props.

| Qué | Dónde | Por qué |
|---|---|---|
| Fetch de datos, lectura de cookies/headers, acceso a secretos, composición de casos de uso | Server Component / Server Action | No viaja al bundle; sin waterfall cliente |
| `useState`, `useEffect`, `onClick`, `useActionState`, APIs del navegador (IndexedDB, `navigator`) | Client Component hoja (`'use client'`) | Necesita runtime del navegador |
| Layouts, páginas, tablas de solo lectura, formateo de dinero/fechas | Server Component | Cero JS de hidratación |
| Un botón interactivo dentro de una tarjeta estática | Tarjeta = server; botón = client (hoja) | Empujar la directiva hacia abajo |
| Fetch en `useEffect` para datos iniciales | Prohibido | Va al Server Component o a la acción |

**Cómo se verifica:** `grep -rln "'use client'" apps/web/src/app --include=layout.tsx --include=page.tsx` vacío.

## 2. React 19

- Sin `useMemo`/`useCallback`/`memo` manuales: el React Compiler memoiza. Se agregan solo ante una medición (Profiler) documentada en el PR.
- Sin `JSX.Element` como tipo de retorno (no existe el namespace global); dejar inferir o `import type { ReactNode } from 'react'` para props.
- Props con `interface`/`type` explícitos; `any` prohibido (`@typescript-eslint/no-explicit-any` error).
- `ref` es prop normal: sin `forwardRef` en componentes nuevos.
- Formularios con `useActionState` + `<form action={serverAction}>`; estado de envío con `useFormStatus`.

**Cómo se verifica:** `grep -rnE "useMemo|useCallback|React\.memo\(|forwardRef" apps/web/src` vacío o cada match con comentario `// measured:` que apunte a la medición.

## 3. Composition root y Server Actions

```ts
// apps/web/src/lib/api.ts — composition root del web: único lugar que conoce URL base y auth
import 'server-only';
import { cookies } from 'next/headers';
import { env } from '@/lib/env'; // zod, falla rápido al arrancar

export async function apiFetch<T>(path: string, init: RequestInit = {}): Promise<T> {
  const token = (await cookies()).get('session')?.value;
  const res = await fetch(`${env.API_URL}${path}`, {
    ...init,
    headers: { 'content-type': 'application/json', authorization: `Bearer ${token}`, ...init.headers },
    signal: AbortSignal.timeout(env.API_TIMEOUT_MS),
  });
  return parseApiResponse<T>(res); // §4
}
```

```ts
// apps/web/src/app/orders/actions.ts
'use server';
import { headers } from 'next/headers';
import { PlaceOrderInput } from '@acme/contracts/orders';
import { apiFetch } from '@/lib/api';

export async function placeOrder(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const h = await headers();
  if (new URL(h.get('origin') ?? 'null://').host !== h.get('host')) return { ok: false, code: 'FORBIDDEN_ORIGIN' };
  const parsed = PlaceOrderInput.strict().safeParse(Object.fromEntries(formData));
  if (!parsed.success) return { ok: false, code: 'VALIDATION_FAILED', fields: parsed.error.flatten().fieldErrors };
  const { id } = await apiFetch<{ id: string }>('/orders', { method: 'POST', body: JSON.stringify(parsed.data) });
  return { ok: true, id };
}
```

Reglas: `import 'server-only'` en todo módulo que lea secretos o cookies; el tenant lo resuelve el API desde el JWT, el web **nunca** lo manda en el body; los commands devuelven `{ id }` y la lectura posterior es un GET aparte (CQRS); `next.config.ts` fija `experimental.serverActions.allowedOrigins` con la allowlist del producto. **Cómo se verifica:** `grep -rL "server-only" apps/web/src/lib/api.ts apps/web/src/lib/env.ts` vacío; test de componente que envía `tenantId` en el `FormData` y espera `VALIDATION_FAILED` (el schema es `.strict()`).

## 4. Contrato de errores y dinero

El API responde `{ code, publicMessage, publicDetails?, traceId }`. La UI decide por `code` (estable, SCREAMING_SNAKE); `publicMessage` es fallback, nunca el `message` interno. Ver skill `errors-and-result`.

```ts
// apps/web/src/lib/errors.ts
import type { ErrorCode } from '@acme/contracts/errors';
import { copy } from '@/copy'; // dialecto según CLAUDE.md del producto

const byCode: Partial<Record<ErrorCode, () => string>> = {
  ORDER_ALREADY_CANCELLED: () => copy.orders.alreadyCancelled,
  ORDER_NOT_FOUND: () => copy.common.notFound,
  VALIDATION_FAILED: () => copy.common.checkFields,
};
export function messageFor(error: { code: ErrorCode; publicMessage: string }): string {
  return byCode[error.code]?.() ?? error.publicMessage;
}
```

Dinero: llega `{ amount: number; currency: string }` con `amount` entero en unidad menor. Se formatea en UI, nunca se opera: `new Intl.NumberFormat(locale, { style: 'currency', currency }).format(amount / 10 ** fractionDigits(currency))`; `fractionDigits` viene de `contracts` (ISO 4217; no asumir 2). Prohibido `parseFloat` sobre montos, sumar en el cliente o mandar decimales al API. **Cómo se verifica:** `grep -rnE "parseFloat\(|toFixed\(" apps/web/src` vacío fuera de `lib/money.ts`; test de `messageFor` que aserta por `code`.

## 5. Estilos: Tailwind 4 + shadcn

- `apps/web/src/app/globals.css`: `@import "tailwindcss";` + tokens en `@theme` (`--color-primary`, `--radius-md`, `--font-sans`). Sin `tailwind.config.js|ts`; PostCSS con `@tailwindcss/postcss`.
- Utilidades desde tokens (`bg-primary`, `text-muted-foreground`); prohibido `var(--x)` crudo en `className` y hex sueltos.
- `cn()` en `src/lib/utils.ts` = `twMerge(clsx(...))`; `className` del consumidor va al final para permitir override. Nunca concatenar strings de clases a mano.
- Componentes base shadcn en `src/components/ui/` (`cva` + `VariantProps`); se reutilizan, no se reescriben. Sin otra librería de UI sin decisión escrita en `docs/sdd/`.
- Fuentes con `next/font` (self-host) en `layout.tsx`, expuestas por variable CSS y referenciadas en `@theme`; nunca `<link>` a CDN de fuentes.
- Modo claro y oscuro con tokens; contraste WCAG AA.

**Cómo se verifica:** `ls apps/web/tailwind.config.*` falla; `grep -rnE "var\(--|#[0-9a-fA-F]{3,8}\b" apps/web/src --include=*.tsx` vacío; `grep -rn "fonts.googleapis" apps/web` vacío.

## 6. Formularios

Schema de `contracts` reutilizado en cliente para validación de UX (requerido, formato, longitud) y en la Server Action con `.strict()`. El API es la fuente de verdad: no duplicar reglas de negocio en el web. Errores de campo desde `fields` de la acción; error global desde `messageFor`. Inputs con `font-size ≥ 16px` en móvil (evita zoom), `label` asociado, `aria-invalid` y `aria-describedby` al mensaje.

## 7. PWA

| Regla | Mecánica |
|---|---|
| Escrituras offline | Outbox en IndexedDB; cada operación lleva `idempotencyKey` (UUID generado al encolar) enviado como header `Idempotency-Key`; el API deduplica. Reintento sin key = duplicados |
| Conflictos | Last-write-wins por `updatedAt` del servidor; sin CRDT. Rechazos del API se muestran, nunca se descartan en silencio |
| Listas con control de acceso (lo que un usuario puede ver depende de permisos/bloqueos) | Estrategia `network-only`; nunca precache ni stale-while-revalidate |
| App shell y assets estáticos | Precache con hash de build; `registerType: 'prompt'` para actualizar |
| Logout | `caches.keys().then(ks => Promise.all(ks.map(k => caches.delete(k))))` + limpiar IndexedDB + `unregister()` del SW |
| Indicador de conectividad | Señal real (`navigator.onLine` + ping al API), no asumido |

**Cómo se verifica:** test de componente que encola dos veces la misma operación y aserta una sola entrada por `idempotencyKey`; `grep -n "network-only" apps/web/src/pwa/sw.ts` cubre cada ruta de lista con permisos; test de logout que espera `caches.keys()` vacío.

## 8. Rendimiento y accesibilidad como gate

Lighthouse CI (`lighthouserc.cjs`, `pnpm exec lhci autorun`) corre en CI cuando cambia `apps/web/**` o `packages/contracts/**` y **falla el PR** que exceda: LCP ≤ 2,5 s · INP ≤ 200 ms · CLS < 0,1 · JS inicial ≤ 200 KB gzip · CSS ≤ 50 KB · fuentes ≤ 100 KB · accesibilidad ≥ 95. Code splitting por ruta; imágenes con `next/image`.

Accesibilidad mínima: foco visible, navegación por teclado completa, `alt` en imágenes informativas, roles y nombres accesibles en controles custom, contraste AA, targets táctiles ≥ 44 px, `prefers-reduced-motion` respetado. **Cómo se verifica:** `eslint-plugin-jsx-a11y` en `pnpm lint` (nivel error) y la auditoría de accesibilidad de Lighthouse en el gate.

## 9. Prohibiciones

| Prohibido | En su lugar |
|---|---|
| Importar `domain/`, `application/` o un paquete de contexto desde `apps/web` | `packages/contracts` + HTTP |
| Tenant en body/FormData | Lo resuelve el API desde auth |
| `'use client'` en layouts, páginas o contenedores | Hoja interactiva |
| `useMemo`/`useCallback`/`memo` sin medición | React Compiler |
| Mostrar `message` interno o `details` de un error | `messageFor(code)` |
| Float, `parseFloat`, aritmética de dinero en cliente | Entero en unidad menor + `Intl.NumberFormat` |
| `tailwind.config.*`, `var(--x)` en `className`, hex sueltos | `@theme` + utilidades + `cn()` |
| Fuentes por CDN, `<link>` a `fonts.googleapis` | `next/font` self-host |
| `dangerouslySetInnerHTML` con contenido de usuario | Render de texto; sanitizado server-side si es HTML propio |
| Reintento offline sin `Idempotency-Key`; cache de listas con permisos | Outbox idempotente; `network-only` |
| Hosts hardcodeados, secretos en `NEXT_PUBLIC_*` | `env.ts` con zod; solo lo público lleva prefijo |
| Tunables de producto (límites, tasas) en el front | Config del backend expuesta por el API |

## 10. Checklist

- [ ] ¿`apps/web` importa solo `packages/contracts`? ¿`pnpm lint` con boundaries verde?
- [ ] ¿Server Component salvo hoja interactiva? ¿Ningún `'use client'` en layouts/páginas?
- [ ] ¿Sin `useMemo`/`useCallback`/`memo`/`forwardRef` nuevos sin medición?
- [ ] ¿Server Actions con schema `.strict()` de `contracts` y verificación de origen? ¿`server-only` en módulos con secretos/cookies?
- [ ] ¿Errores mapeados por `code` con copy del producto (dialecto según su `CLAUDE.md`)?
- [ ] ¿Dinero recibido entero en unidad menor y formateado con `Intl.NumberFormat`?
- [ ] ¿Tokens `@theme` + `cn()` + shadcn; sin `tailwind.config.*`; fuentes por `next/font`?
- [ ] ¿PWA: outbox con `idempotencyKey`, listas con permisos `network-only`, logout limpia caches y SW?
- [ ] ¿Lighthouse CI dentro de budgets? ¿`jsx-a11y` verde; foco, teclado y contraste revisados?
- [ ] ¿`pnpm --filter web typecheck && pnpm --filter web lint && pnpm --filter web test` verdes?
