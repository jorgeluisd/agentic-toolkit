---
description: Corre typecheck + lint (boundaries Onion e inter-contexto) + tests + audit del proyecto y reporta el estado de la arquitectura sin corregir nada.
allowed-tools: Bash(pnpm typecheck:*), Bash(pnpm lint:*), Bash(pnpm test:*), Bash(pnpm audit:*), Bash(pnpm -r:*), Bash(pnpm turbo:*), Bash(git status:*), Bash(git diff:*)
---

Verifica que la arquitectura y el código estén sanos. Usa los comandos declarados en la sección "Comandos" del `CLAUDE.md` del proyecto; si no están declarados, usa los del estándar: `pnpm typecheck`, `pnpm lint`, `pnpm test`, `pnpm test:integration` (solo si hay Postgres disponible), `pnpm audit --audit-level=high`.

Corre **todos** aunque alguno falle (se necesita el panorama completo) y reporta:

| Check | Comando | Resultado | Última línea de salida |
|---|---|---|---|
| Typecheck | … | ✔/✘ | … |
| Lint + boundaries | … | ✔/✘ | … |
| Tests | … | ✔/✘ | … |
| Integración | … | ✔/✘/omitido (motivo) | … |
| Audit | … | ✔/✘ | … |

Si algo falla: archivo, capa, regla rota y el error textual. Si todo pasa: "arquitectura verde" con una línea por check.

Si el proyecto no tiene enforcement de boundaries en el lint (ningún `boundaries/*` configurado), repórtalo como **GAP** con la referencia a la skill `onion-screaming-architecture` §Enforcement.

No arregles nada en este comando: solo diagnostica.
