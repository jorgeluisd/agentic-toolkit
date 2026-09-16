# check-arch

Corre typecheck + lint (boundaries Onion e inter-contexto) + tests + audit del proyecto y reporta el estado de la arquitectura sin corregir nada.


## Procedure


Verifica que la arquitectura y el código estén sanos. Usa los comandos declarados en la sección "Comandos" del `AGENTS.md` del proyecto (`typecheck`, `lint`, `test`, `test:integration`, `audit`). Si no están declarados, usa los que documente la skill `testing-conventions` del stack instalado; si tampoco existe, detente y pídelos: no adivines.

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


## Specifications

- El pipeline, las fases y los gates están en `.agents/sdd-tdd-core/ORCHESTRATOR-solo.md`. Leelo antes de empezar.
- Los artefactos van a `docs/sdd/<NNNN>-<slug>/` y son la máquina de estados del proceso: si no está escrito, no pasó.
- En cada gate te detenés de verdad y esperás el token del humano. Un gate sin registro en `gates.md` no ocurrió.

## Forbidden Actions

- Leer o editar `.env*`, `*.pem`, `*.key` ni ningún archivo de credenciales.
- Escribir secretos, datos personales reales o identificadores de producción en un artefacto, un test o un commit. Los ejemplos son sintéticos: teléfonos `+10000000001`, dominios `example.com`.
- Correr comandos dirigidos a producción (psql contra una base productiva, deploys, actualización de una lambda) sin confirmación humana explícita.
- Forzar un push, saltear los hooks de git al commitear, o pushear directo a la rama base.
- Agregar trailers o menciones de IA al commit o al PR: `Co-Authored-By`, `Generated with`, nombres de modelos, `anthropic`, `openai`, `devin.ai`.
- Escribir código de producción antes del GATE 1 aprobado.
- Escribir código de producción en una fase que no sea `implementer`.
- Bloques de comentario de más de 4 líneas, o más de 15 % de líneas comentadas en un archivo de código.
