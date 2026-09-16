# Portabilidad

Este toolkit define un proceso, no un plugin de un producto. El proceso se escribe una vez en `source/` y `bin/atk` lo compila al empaquetado nativo de cada agente. Este documento es el contrato: **qué funciona igual en todos lados y qué se degrada en cada uno.**

## Matriz de capacidades

| | Claude Code | Codex CLI | OpenCode | Devin |
|---|---|---|---|---|
| **Skills** (14) | ✅ `.claude/skills/` | ✅ `.agents/skills/` | ✅ `.opencode/skills/` | ⚠️ Knowledge, pegadas a mano |
| **Fases como subagentes** (10) | ✅ `agents/` + Task | ⚠️ a verificar | ✅ `mode: subagent` + Task | ❌ modo solo |
| **Comandos** (8) | ✅ `commands/` | ✅ `~/.codex/prompts/` | ✅ `.opencode/commands/` | ⚠️ Playbooks `.devin.md` |
| **Guardrails bloqueantes** | ✅ hooks nativos | ✅ mismos hooks | ✅ shim JS | ❌ solo instructivos |
| **Gatekeeper de fases** | ✅ `PreToolUse`/`Task` | ⚠️ si hay subagentes | ✅ | ❌ |
| **Evidencia TDD automática** | ✅ `post-bash` | ✅ | ✅ | ❌ a mano |
| **Documento de contexto** | `CLAUDE.md` | `AGENTS.md` | `AGENTS.md` | `AGENTS.md` |

✅ nativo · ⚠️ funciona con salvedad · ❌ no existe, hay compensación documentada

## Lo que es igual en todos lados

**El proceso.** Diez fases, dos gates humanos, la tabla de insumos de `ORCHESTRATOR.md` §3.2, el protocolo de artefactos y el ciclo de vida `<NNNN>-<slug>/` → `specs/` → `_archive/`. No hay una versión "reducida" del proceso para agentes con menos capacidades.

**Los artefactos son la máquina de estados.** El estado del pipeline vive en disco, no en el contexto de la conversación. Por eso el mismo change se puede empezar en un agente y terminar en otro: lo que importa es qué artefactos existen en `<raíz>/<NNNN>-<slug>/`.

**La configuración.** `.agentic/sdd-hooks.env` en la raíz del repo, con las mismas claves `SDD_*` en los cuatro. Los repos adoptados antes de 2.0.0 con `.claude/sdd-hooks.env` siguen funcionando: los hooks buscan `.agentic/` primero y caen a `.claude/`.

**Qué repositorio es "el proyecto".** Los hooks no lo sacan de ninguna variable de entorno de un agente: lo resuelven del payload y del propio comando, por precedencia — el `file_path` de una escritura, el directorio que el comando declara (`cd <repo>`, `--dir`, `-C`, `--prefix`), la primera ruta absoluta del comando, el `cwd` de la llamada y, al final, la raíz de la sesión. Por eso una sesión abierta en el repositorio A que corre los tests de B deja la evidencia en B, en los cuatro agentes por igual.

**Los hooks bash.** Los mismos siete scripts corren en Claude Code y en Codex CLI sin modificación, porque el esquema de payload y de decisión es idéntico: JSON por stdin con `tool_name`/`tool_input`, respuesta `hookSpecificOutput.permissionDecision`. En OpenCode los invoca un shim JS que traduce nombres de herramienta.

## Lo que se degrada, por agente

### Codex CLI
Los hooks son los mismos y se registran en `.codex/hooks.json`. Una diferencia real: Codex no declara el evento `PostToolUseFailure`, así que la evidencia TDD de una corrida que termina en rojo llega por `PostToolUse`. El manifiesto declara ese hook con `"targets": ["claude"]` y el adaptador de Codex no lo emite.

Los prompts son **solo de usuario** (`$CODEX_HOME/prompts/`, no se comparten por repo), así que el adaptador emite un `install.sh` que los copia. Los skills y los hooks sí viven en el repo.

### OpenCode
Lee `.claude/skills/` y `.agents/skills/` además de los suyos, así que las skills funcionan incluso sin compilar nada. Los guardrails necesitan el plugin JS: sin él, el árbol sigue siendo útil pero nada bloquea.

Dos degradaciones concretas del plugin:

1. **No hay estado de confirmación.** La API de plugins permite dejar pasar o lanzar un error; no hay un "preguntá al humano". Lo que en Claude Code sería `ask` — un deploy, un push a la rama base — acá permite y deja el aviso en el log.
2. **`permission.edit` no distingue por ruta.** Toda fase que escriba su artefacto necesita `edit: allow`, así que el permiso no puede impedir que el `designer` escriba código de producción. Eso lo sostiene el prompt de la fase, no la herramienta.

Los modelos por fase se emiten con ids de Anthropic, tomados del mapa `models` de `adapters/targets.json`. Con otro proveedor, se cambian en `.opencode/agents/*.md` o se borra la línea para usar el default.

### Devin
No tiene hooks ni subagentes. Dos consecuencias, y ninguna se disimula:

1. **El pipeline corre en modo solo** (`ORCHESTRATOR-solo.md`): una sesión adopta las diez fases en orden. El gatekeeper de fases no existe; la disciplina de insumos la sostiene el bucle de ejecución.
2. **Los guardrails son instructivos, no bloqueantes.** Producción, secretos, PII, comentarios, trailers de IA y evidencia TDD están escritos como reglas en `AGENTS.md`, y Devin puede no cumplirlas. Fue una decisión explícita: no se agrega enforcement por CI ni por pre-commit. Tampoco hay resolución automática del repositorio ni `tdd-evidence.log` escrito por un hook: el bucle deja la evidencia a mano, en el repo que está tocando.

Si necesitás que esas reglas se hagan cumplir de verdad en Devin, el camino es un job de CI en el repo adoptante — fuera del alcance de este toolkit.

## Agregar un agente nuevo

1. Entrada en `adapters/targets.json` con su `label`, su `out` y los valores de los placeholders.
2. `adapters/<nombre>.mjs` que exporta `buildTarget({ plugins, out, rootOut, vars })`.
3. Columna en la matriz de arriba.

Los placeholders que todo target tiene que resolver: `AGENT_NAME`, `CONTEXT_DOC`, `AGENT_DIR`, `SKILLS_DIR`, `SETTINGS_FILE`, `PLUGIN_ROOT`, `CMD_PREFIX`, `CONFIG_FILE`, `LOCAL_STORE`, `ATTRIBUTION_OFF`, `ORCHESTRATOR`. Uno sin valor rompe el build a propósito: es lo que impide que un token de un producto se cuele en el contenido.
