// Adaptador OpenCode → dist/opencode/
// Los guardrails van por un plugin JS: el shim de source/core/targets/opencode
// traduce las llamadas a los mismos hooks bash de Claude Code y Codex.

import { readText, classify, splitFrontmatter, withFrontmatter } from './lib.mjs';

const PLUGIN_DIR = '.opencode/sdd-tdd-core';
const SHIM = 'targets/opencode/sdd-guard.js';

export function buildTarget({ plugins, out, vars, spec }) {
  const commands = [];
  const agents = [];

  for (const { src, files } of plugins) {
    for (const file of files) {
      const { kind, name } = classify(file);
      if (kind === 'test') continue;

      if (kind === 'skill') {
        out.copy(`${src}/${file}`, `.opencode/skills/${name}/SKILL.md`, vars);
      } else if (kind === 'command') {
        commands.push({ name, ...commandFor(`${src}/${file}`, vars) });
      } else if (kind === 'agent') {
        agents.push({ name, ...agentFor(`${src}/${file}`, vars, spec.models) });
      } else if (kind === 'hook') {
        out.copy(`${src}/${file}`, `${PLUGIN_DIR}/hooks/${name}`, vars, { exec: name.endsWith('.sh') });
      } else if (file === SHIM) {
        out.copy(`${src}/${file}`, '.opencode/plugins/sdd-guard.js', vars);
      } else {
        const dest = file === 'templates/context-doc.md' ? `templates/${vars.CONTEXT_DOC}` : file;
        out.copy(`${src}/${file}`, `${PLUGIN_DIR}/${dest}`, vars);
      }
    }
  }

  for (const cmd of commands) out.write(`.opencode/commands/${cmd.name}.md`, cmd.text);
  for (const agent of agents) out.write(`.opencode/agents/${agent.name}.md`, agent.text);

  out.write(vars.CONTEXT_DOC, agentsMd(commands, agents, vars));
  out.write('install.sh', installSh(), { exec: true });
  out.write('README.md', readme(commands, agents));
}

function commandFor(path, vars) {
  const { fields, body } = splitFrontmatter(readText(path, vars));
  return { description: fields.description, text: withFrontmatter({ description: fields.description }, body) };
}

// OpenCode declara permisos, no herramientas por nombre. Sin `tools` en origen el
// agente las tiene todas (es el caso del implementer). `edit` cubre write y edit,
// asi que toda fase que escriba su artefacto lo necesita: el permiso no distingue
// artefacto de codigo de produccion, y esa restriccion la sostiene el prompt.
function permissionFrom(tools) {
  if (!tools) return { edit: 'allow', bash: 'allow' };
  const list = tools.split(',').map((t) => t.trim());
  const writes = ['Write', 'Edit', 'MultiEdit'].some((t) => list.includes(t));
  return {
    edit: writes ? 'allow' : 'deny',
    bash: list.includes('Bash') ? 'allow' : 'deny',
  };
}

function agentFor(path, vars, models) {
  const { fields, body } = splitFrontmatter(readText(path, vars));
  const permission = permissionFrom(fields.tools);
  const text = [
    '---',
    `description: ${JSON.stringify(fields.description)}`,
    'mode: subagent',
    ...(models?.[fields.model] ? [`model: ${models[fields.model]}`] : []),
    'permission:',
    `  edit: ${permission.edit}`,
    `  bash: ${permission.bash}`,
    '---',
    body,
  ].join('\n');
  return { description: fields.description, text };
}

function agentsMd(commands, agents, vars) {
  const cmdRows = commands.map((c) => `| \`${vars.CMD_PREFIX}${c.name}\` | ${c.description} |`).join('\n');
  return `# AGENTS.md — proceso SDD + Strict TDD

> Bloque generado por agentic-toolkit. Pegalo en el \`AGENTS.md\` de tu repositorio
> junto a lo propio del proyecto (stack, comandos, invariantes).

## Cómo se ejecuta un cambio de código

Toda feature, bugfix o cambio de esquema se ejecuta por el pipeline SDD, pedido por
comando o en lenguaje natural. Solo el nivel trivial (typo, copy, bump de patch)
queda fuera. El pipeline está en \`${PLUGIN_DIR}/ORCHESTRATOR.md\`; leelo antes de
tocar código.

Las ${agents.length} fases son subagentes en \`.opencode/agents/\`: se lanzan con la
herramienta \`task\`, una por vez y en el orden del orquestador.

## Comandos

| Comando | Qué hace |
|---|---|
${cmdRows}

## Skills

En \`.opencode/skills/\`. OpenCode las carga sola según la \`description\` de cada una.

## Guardrails

\`.opencode/plugins/sdd-guard.js\` corre los mismos hooks bash que el toolkit usa en
Claude Code y Codex: bloquea comandos dirigidos a producción, lectura y escritura de
secretos, datos personales en artefactos y trailers de IA en los commits, y escribe
la evidencia TDD. Una salvedad: OpenCode no tiene un estado intermedio de
confirmación, así que lo que en Claude sería preguntar acá permite y queda en el log.
`;
}

function installSh() {
  return `#!/usr/bin/env bash
# Instala el toolkit SDD+TDD para OpenCode en el repositorio actual.
#   bash install.sh [ruta-al-repo]
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "\${1:-$PWD}" && pwd)"

[ -d "$REPO/.git" ] || { echo "no parece un repositorio git: $REPO"; exit 1; }

mkdir -p "$REPO/.opencode"
cp -R "$HERE/.opencode/." "$REPO/.opencode/"

if [ ! -f "$REPO/.agentic/sdd-hooks.env" ]; then
  mkdir -p "$REPO/.agentic"
  cp "$HERE/.opencode/sdd-tdd-core/templates/sdd-hooks.env" "$REPO/.agentic/sdd-hooks.env"
  echo "creado  .agentic/sdd-hooks.env — editalo antes del primer cambio"
fi

echo "ok      .opencode/ en $REPO"
echo "falta   pegar el contenido de AGENTS.md en el AGENTS.md del repo"
echo "falta   reiniciar OpenCode para que tome agentes, comandos y el plugin"
`;
}

function readme(commands, agents) {
  return `# agentic-toolkit para OpenCode

Salida generada por \`node bin/atk build --target=opencode\`. No editar a mano:
el contenido vive en \`source/\` del repositorio del toolkit.

## Instalación

\`\`\`bash
bash install.sh /ruta/a/tu/repo
\`\`\`

## Qué se instala

| Ruta | Qué es |
|---|---|
| \`.opencode/agents/\` | Las ${agents.length} fases del pipeline, como subagentes |
| \`.opencode/commands/\` | Los ${commands.length} comandos |
| \`.opencode/skills/\` | Las skills, que OpenCode carga por \`description\` |
| \`.opencode/plugins/sdd-guard.js\` | Shim que corre los hooks bash del toolkit |
| \`.opencode/sdd-tdd-core/\` | Orquestador, gates, plantillas y scripts de hook |

## Modelos

Los agentes traen el modelo sugerido por fase, con ids de Anthropic. Si usás otro
proveedor, cambiá \`model:\` en \`.opencode/agents/*.md\` o borrá la línea para que
OpenCode use su default. La tabla de por qué cada fase merece su modelo está en
\`${PLUGIN_DIR}/ORCHESTRATOR.md\` §5.

## Salvedades

- OpenCode ya lee \`.claude/skills/\` y \`.agents/skills/\`, así que las skills
  funcionan aunque no instales nada más.
- El plugin no tiene un estado de confirmación: los guardrails que en Claude Code
  preguntan, acá permiten y dejan el aviso en el log. Los que deniegan, deniegan.
`;
}
