# agentic-toolkit para OpenCode

Salida generada por `node bin/atk build --target=opencode`. No editar a mano:
el contenido vive en `source/` del repositorio del toolkit.

## Instalación

```bash
bash install.sh /ruta/a/tu/repo
```

## Qué se instala

| Ruta | Qué es |
|---|---|
| `.opencode/agents/` | Las 10 fases del pipeline, como subagentes |
| `.opencode/commands/` | Los 8 comandos |
| `.opencode/skills/` | Las skills, que OpenCode carga por `description` |
| `.opencode/plugins/sdd-guard.js` | Shim que corre los hooks bash del toolkit |
| `.opencode/sdd-tdd-core/` | Orquestador, gates, plantillas y scripts de hook |

## Modelos

Los agentes traen el modelo sugerido por fase, con ids de Anthropic. Si usás otro
proveedor, cambiá `model:` en `.opencode/agents/*.md` o borrá la línea para que
OpenCode use su default. La tabla de por qué cada fase merece su modelo está en
`.opencode/sdd-tdd-core/ORCHESTRATOR.md` §5.

## Salvedades

- OpenCode ya lee `.claude/skills/` y `.agents/skills/`, así que las skills
  funcionan aunque no instales nada más.
- El plugin no tiene un estado de confirmación: los guardrails que en Claude Code
  preguntan, acá permiten y dejan el aviso en el log. Los que deniegan, deniegan.
