# agentic-toolkit para Codex CLI

Salida generada por `node bin/atk build --target=codex`. No editar a mano:
el contenido vive en `source/` del repositorio del toolkit.

## Instalación

```bash
bash install.sh /ruta/a/tu/repo
```

Después, pegá el contenido de `AGENTS.md` en el `AGENTS.md` de tu repositorio y
reiniciá Codex.

## Qué se instala

| Ruta | Qué es | Dónde queda |
|---|---|---|
| `.codex/hooks.json` | Registro de los hooks | repo, versionado |
| `.codex/sdd-tdd-core/` | Orquestador, fases, gates, plantillas y scripts de hook | repo, versionado |
| `.agents/skills/` | Las skills, que Codex carga por `description` | repo, versionado |
| `prompts/*.md` | Los 8 comandos como slash commands | `$CODEX_HOME/prompts`, por máquina |

## Diferencias con Claude Code

Los hooks bash son los mismos: Codex usa el mismo esquema de payload y de decisión.
Dos salvedades:

- Codex no declara el evento `PostToolUseFailure`, así que la evidencia TDD de una
  corrida en rojo llega por `PostToolUse`.
- Los prompts son de usuario y no se comparten por repositorio; por eso el
  `install.sh` los copia a `$CODEX_HOME/prompts` y hay que correrlo en cada máquina.

El registro de los hooks usa rutas relativas a la raíz del repositorio. Si tu
instalación de Codex ejecuta los hooks con otro directorio de trabajo, cambiá
`command` en `.codex/hooks.json` por una ruta absoluta.
