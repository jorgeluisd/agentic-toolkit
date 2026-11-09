---
name: onion-screaming-architecture
description: "Capas Onion, matriz de imports, carpetas por bounded context, sufijos de archivo y enforcement con eslint-plugin-boundaries. Usar cuando se crea o mueve un archivo, se decide capa o contexto, se crea un bounded context o el lint marca boundaries."
---

# Onion + Screaming Architecture

Dependencias siempre hacia adentro; la estructura de carpetas grita el negocio (`orders/`, `billing/`), no la tecnología (`controllers/`, `services/`). Enforcement con `eslint-plugin-boundaries` en `pnpm lint`; nunca "honor system".

## 0. Caché de tareas y enforcement

Si `pnpm lint` corre por turbo, `turbo.json` debe declarar en `inputs` de la tarea `lint` los archivos que cambian el resultado sin tocar `src/`: `eslint.config.mjs` de la raíz, `.dependency-cruiser.cjs` si existe, `tsconfig*.json`. Sin eso, aflojar o romper una regla de arquitectura deja `pnpm lint` en verde desde caché (local y en CI si restaura la caché). **Cómo se verifica:** cambiar una regla del `eslint.config.mjs` y correr `pnpm lint`: la salida no debe decir `cached`. `pnpm lint -- --force` no sirve (el flag llega a eslint); es `pnpm exec turbo run lint --force`.

## 1. Layout canónico

```
apps/api/src/
  shared-kernel/               # puro: Result, DomainError base, Money, Identifier<Brand>, TimeProvider, IdGenerator, DomainEvent base
  contexts/<context>/          # un bounded context por carpeta; el nombre grita el negocio
    domain/                    # aggregates/ entities/ value-objects/ events/ repositories/ (interfaces = puertos) services/ errors/
    application/               # commands/ queries/ handlers/ ports/ read-models/ mappers/ (application→domain)
    presentation/              # http/ (controllers, dtos class-validator, guards, pipes, mappers presentation→application)
    infrastructure/            # persistence/ (drizzle schema, repos), messaging/, external/, mappers/ (infra→domain)
    <context>.module.ts        # composition root del contexto (tipo context-root)
  platform/                    # opcional: auth, config, provider de DB, health; transversal, sin dominio, no importa contextos
  app.module.ts, main.ts       # app-root
packages/contracts/            # opcional: tipos de request/response compartidos web↔api; NO importa domain
apps/web/                      # solo importa packages/contracts; nunca domain/application
```

Prohibido: un `packages/domain` global con todos los contextos adentro; carpetas por capa en la raíz; un contexto `shared/` de dominio (si es puro va a `shared-kernel`; si no, los límites están mal trazados). Tests (`*.spec.ts`, `*.integration.spec.ts`, `*.e2e-spec.ts`) exentos del enforcement: cablean adapters a propósito.

## 2. Matriz de imports (fila importa columna)

| desde \ hacia | shared-kernel | domain | application | presentation | infrastructure | platform | contracts | context-root |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| shared-kernel | mismo | no | no | no | no | no | no | no |
| domain | sí | mismo contexto | no | no | no | no | no | no |
| application | sí | mismo contexto | mismo contexto | no | no | no | no | no |
| presentation | sí | no | mismo contexto | mismo contexto | no | sí | sí | no |
| infrastructure | sí | mismo contexto | mismo contexto | no | mismo contexto | sí | no | no |
| context-root | sí | mismo contexto | mismo contexto | mismo contexto | mismo contexto | sí | no | no |
| platform | sí | no | no | no | no | sí | no | no |
| app-root | sí | no | no | no | no | sí | no | sí |
| contracts | no | no | no | no | no | no | mismo | no |

- `shared-kernel`: solo stdlib de TS/JS sin I/O. Prohibido `node:*`, frameworks, `new Date()`, `Math.random()`, `crypto.randomUUID()`.
- `presentation` no importa `domain`: lo que necesita del dominio lo recibe como read model o `{ id }` desde `application`.

## 3. Taxonomía de elementos para el lint

| Tipo | Patrón | Nota |
|---|---|---|
| `shared-kernel` | `apps/api/src/shared-kernel/**` (o `packages/shared-kernel/src/**`) | sin `capture` |
| `domain` / `application` / `presentation` / `infrastructure` | `apps/api/src/contexts/*/<capa>/**` | `capture: ['context']` |
| `context-root` | `apps/api/src/contexts/*/*.module.ts` | `mode: 'file'`, `capture: ['context']`; único que ve las 4 capas de su contexto |
| `platform` | `apps/api/src/platform/**` | transversal: guards de auth, config, provider de DB; jamás importa un contexto |
| `app-root` | `apps/api/src/{app.module,main}.ts` | `mode: 'file'`; único que importa `context-root` |
| `contracts` | `packages/contracts/src/**` | no importa nada del api. Tests `**/*.{spec,integration.spec,e2e-spec}.ts`: excluidos vía `ignores` |

## 4. Regla inter-contexto

Nada en compile-time entre contextos. Un contexto habla con otro solo por: (a) evento de dominio (clase + `eventName`), (b) contrato de `packages/contracts`, (c) `CommandBus`/`QueryBus` con plain data. Un contexto que necesita una entidad de otro guarda solo su `Identifier` y consulta por Query. Si un contexto vive en `packages/<context>`, expone entrypoints explícitos en `package.json#exports` (`"./application"`, `"./events"`) para que importar internals ni siquiera resuelva; el lint es la segunda defensa, no la única.

## 5. Sufijos de archivo

| Pieza | Sufijo | Carpeta |
|---|---|---|
| Aggregate / Entity / Value object | `.aggregate.ts` / `.entity.ts` / `.vo.ts` | `domain/{aggregates,entities,value-objects}` |
| Evento / Error / Domain service | `.event.ts` / `.error.ts` / `.service.ts` | `domain/{events,errors,services}` |
| Puerto de repositorio / adapter | `.repository.ts` / `.repository.drizzle.ts` | `domain/repositories` / `infrastructure/persistence` |
| Command / Query / Handler / Use case | `.command.ts` / `.query.ts` / `.handler.ts` / `.use-case.ts` | `application/{commands,queries,handlers}` |
| Puerto / Read model / Mapper | `.port.ts` / `.read-model.ts` / `.mapper.ts` | `application/{ports,read-models,mappers}` |
| Controller / Schema / Guard / Pipe | `.controller.ts` / `.schema.ts` (o `.dto.ts`) / `.guard.ts` / `.pipe.ts` | `presentation/http` |
| Módulo | `.module.ts` | raíz del contexto |

Archivos kebab-case; clases PascalCase; interfaces sin prefijo `I` (`OrderRepository`, no `IOrderRepository`); identificadores en inglés. Evento: clase `OrderPlaced`, archivo `order-placed.event.ts`. En paquetes ESM puros (`"type": "module"`), los imports internos llevan extensión `.js`.

## 6. Contexto nuevo: decisión y scaffold

Test de decisión, un punto por cada afirmación cierta: lenguaje propio · ciclo de vida propio · dueño distinto · consistencia transaccional independiente · cambia por razones distintas · podría ser un servicio aparte. **4+** → contexto nuevo. **2–3** → sub-carpeta o aggregate dentro de uno existente. **0–1** → no lo crees. En contra: las consultas naturales lo cruzan con otro contexto todo el tiempo, o tiene menos de dos entidades.
```bash
ctx=apps/api/src/contexts/orders
mkdir -p $ctx/domain/{aggregates,entities,value-objects,events,repositories,services,errors} $ctx/application/{commands,queries,handlers,ports,read-models,mappers} \
         $ctx/presentation/http/{controllers,schemas,mappers} $ctx/infrastructure/{persistence,messaging,external,mappers}
find $ctx -type d -empty -exec touch {}/.gitkeep \;
```

```ts
// apps/api/src/contexts/orders/orders.module.ts  (luego: app.module.ts → imports: [..., OrdersModule])
@Module({ imports: [CqrsModule], controllers: [OrdersController],
  providers: [PlaceOrderHandler, GetOrderDetailHandler, { provide: ORDER_REPOSITORY, useClass: OrderDrizzleRepository }] })
export class OrdersModule {}
```
Mínimo funcional antes de mergear: un aggregate con `create`/`rehydrate`, un puerto de repositorio con `Symbol`, un adapter + mapper, la migración con RLS si hay tabla de tenant, un test del aggregate y uno del repositorio.

## 7. Enforcement: `eslint.config.mjs`

```js
import tseslint from 'typescript-eslint'; import boundaries from 'eslint-plugin-boundaries'; import importPlugin from 'eslint-plugin-import';

const ctx = (type, glob) => ({ type, pattern: `apps/api/src/contexts/*/${glob}`, capture: ['context'] });
const own = (type) => [type, { context: '${from.context}' }];
const TESTS = ['**/*.{spec,integration.spec,e2e-spec}.ts'];

export default tseslint.config(
  {
    files: ['apps/api/src/**/*.ts', 'packages/contracts/src/**/*.ts'],
    ignores: TESTS,
    plugins: { boundaries, import: importPlugin },
    settings: { 'boundaries/include': ['apps/api/src/**/*.ts', 'packages/contracts/src/**/*.ts'],
      'boundaries/elements': [
        { type: 'shared-kernel', pattern: 'apps/api/src/shared-kernel/**' },
        { type: 'contracts', pattern: 'packages/contracts/src/**' },
        ctx('domain', 'domain/**'), ctx('application', 'application/**'), ctx('presentation', 'presentation/**'), ctx('infrastructure', 'infrastructure/**'),
        { ...ctx('context-root', '*.module.ts'), mode: 'file' },
        { type: 'platform', pattern: 'apps/api/src/platform/**' },
        { type: 'app-root', pattern: 'apps/api/src/{app.module,main}.ts', mode: 'file' },
      ] },
    rules: {
      'boundaries/element-types': ['error', { default: 'disallow', rules: [
        { from: 'shared-kernel', allow: ['shared-kernel'] },
        { from: 'domain', allow: ['shared-kernel', own('domain')] },
        { from: 'application', allow: ['shared-kernel', own('domain'), own('application')] },
        { from: 'presentation', allow: ['shared-kernel', 'contracts', 'platform', own('application'), own('presentation')] },
        { from: 'infrastructure', allow: ['shared-kernel', 'platform', own('domain'), own('application'), own('infrastructure')] },
        { from: 'context-root', allow: ['shared-kernel', 'platform', own('domain'), own('application'), own('presentation'), own('infrastructure')] },
        { from: 'platform', allow: ['shared-kernel', 'platform'] },
        { from: 'app-root', allow: ['shared-kernel', 'platform', 'app-root', 'context-root'] },
        { from: 'contracts', allow: ['contracts'] },
      ] }],
      'boundaries/no-unknown-files': 'error',
      'boundaries/external': ['error', { default: 'allow', rules: [{ from: ['domain', 'shared-kernel'],
        disallow: ['@nestjs/*', 'drizzle-orm', 'drizzle-orm/*', 'postgres', 'express', 'rxjs', 'pino', 'pino-http', 'nestjs-pino', 'pg-boss', 'zod',
                   'class-validator', 'class-transformer', 'neverthrow', 'fp-ts', 'fp-ts/*'],
        message: "'${dependency.source}' no entra en domain/shared-kernel: puerto en application, adapter en infrastructure." }] }],
      'import/no-cycle': 'error',   // el `no-circular` de dependency-cruiser, en ESLint
    },
  },
  {
    files: ['apps/api/src/contexts/*/domain/**/*.ts', 'apps/api/src/shared-kernel/**/*.ts'],
    ignores: TESTS,
    rules: {
      'no-restricted-imports': ['error', { patterns: [{ group: ['node:*', 'crypto', 'fs', 'fs/*', 'path', 'os', 'child_process'], message: 'domain no importa builtins de Node: inyecta un puerto.' }] }],
      'no-restricted-syntax': ['error',
        { selector: 'NewExpression[callee.name="Date"][arguments.length=0]', message: 'new Date(): usa TimeProvider.now() o recibe now como parámetro.' },
        { selector: 'MemberExpression[object.name="Date"][property.name="now"]', message: 'Date.now(): usa TimeProvider.' },
        { selector: 'MemberExpression[object.name="Math"][property.name="random"]', message: 'Math.random(): inyecta el azar desde application.' },
        { selector: 'CallExpression[callee.name="randomUUID"]', message: 'randomUUID(): usa IdGenerator.' }],
    },
  },
);
```

`new Date(valor)` con argumento sí se permite (instante a partir de un input; es puro). Si `pnpm lint` corre desde `apps/api` (turbo), duplica los patrones con prefijo `src/...`: el plugin resuelve rutas relativas al CWD. **Cómo se verifica:** `pnpm lint` (incluye boundaries; primer gate del CI, antes de typecheck). Prueba que muerde: agrega un import `domain → infrastructure` temporal y corre `pnpm lint`; si no falla, el patrón de `files` no matchea el CWD. Si el lint se queja de un import, el diseño está mal, no el lint.

## 8. Errores comunes → arreglo

| Síntoma | Arreglo |
|---|---|
| `@Injectable()` en `domain/` | Quitar el decorador; registrar con `useClass`/`useFactory` en el módulo |
| Controller importa `Order` (aggregate); domain service hace `fetch`/consulta DB | Controller despacha Command/Query y responde read model o `{ id }`; puerto en `application/ports` + adapter en `infrastructure` |
| Handler de `billing` importa `Order` de `orders` | Evento `OrderPlaced` que `billing` escucha, o Query a `orders` por bus |
| `boundaries/no-unknown-files` en un archivo nuevo | Está fuera de la taxonomía: moverlo a su capa o a `platform/` |
| `import/no-cycle` entre dos aggregates | Uno referencia al otro solo por `Identifier`; la coordinación va por evento |
| DTO de `presentation` embebe un tipo de `domain`; módulo de un contexto importa el de otro | Shape en `contracts`/read model; solo `app-root` importa `context-root` |

## 9. Checklist

- [ ] ¿Contexto decidido con el test de §6 (o ya existe)? ¿Capa elegida por la pregunta litmus "si cambio framework/ORM, ¿esto cambia?" → no es domain?
- [ ] ¿Nombre de archivo con sufijo de §5, kebab-case; clase PascalCase en inglés?
- [ ] ¿Ningún import cruza la matriz de §2 ni entra en otro contexto?
- [ ] ¿Provider/controller registrado en `<context>.module.ts`; módulo registrado en `app.module.ts`?
- [ ] ¿`pnpm lint` verde, incluidas `boundaries/*`, `no-restricted-syntax` e `import/no-cycle`?
