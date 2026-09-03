---
description: Corre typecheck + lint (boundaries Onion e inter-contexto) + tests + audit del proyecto y reporta el estado de la arquitectura sin corregir nada.
allowed-tools: Bash(pnpm typecheck:*), Bash(pnpm lint:*), Bash(pnpm test:*), Bash(pnpm audit:*), Bash(composer:*), Bash(php artisan test:*), Bash(vendor/bin/pest:*), Bash(vendor/bin/phpstan:*), Bash(pytest:*), Bash(git status:*), Bash(git diff:*)
---

Verifica que la arquitectura y el código estén sanos. Usa los comandos declarados en la sección "Comandos" del `CLAUDE.md` del proyecto (`typecheck`, `lint`, `test`, `test:integration`, `audit`). Si no están declarados, usa los que documente la skill `testing-conventions` del stack instalado; si tampoco existe, detente y pídelos: no adivines.

Corre **todos** aunque alguno falle (se necesita el panorama completo). Si un check corre a través de una caché de tareas (turbo, nx), un resultado `cached`/`FULL TURBO` **no cuenta**: repítelo forzando la ejecución (`pnpm exec turbo run <tarea> --force`) y anota como GAP si la configuración de esa tarea (lint, typecheck) no declara sus archivos de configuración en `inputs`. Reporta:

| Check | Comando | Resultado | Última línea de salida |
|---|---|---|---|
| Typecheck | … | ✔/✘ | … |
| Lint + boundaries | … | ✔/✘ | … |
| Tests | … | ✔/✘ | … |
| Integración | … | ✔/✘/omitido (motivo) | … |
| Audit | … | ✔/✘ | … |

Si algo falla: archivo, capa, regla rota y el error textual. Si todo pasa: "arquitectura verde" con una línea por check.

Si el proyecto no tiene enforcement de boundaries en el lint (ningún `boundaries/*` configurado), repórtalo como **GAP** con la referencia a la sección de enforcement de la skill de arquitectura del stack instalado.

No arregles nada en este comando: solo diagnostica.
