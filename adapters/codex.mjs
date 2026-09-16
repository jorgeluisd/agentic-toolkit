// Adaptador Codex CLI → dist/codex/
//
// Los hooks bash son los mismos que en Claude Code: Codex usa el mismo esquema de
// payload y de decisión. Lo único que cambia es dónde se registran.

import { readText, classify, splitFrontmatter, withFrontmatter } from './lib.mjs';

const PLUGIN_DIR = '.codex/sdd-tdd-core';
const SKILLS_DIR = '.agents/skills';
const PROMPTS_DIR = 'prompts';

export function buildTarget({ plugins, out, vars }) {
  const commands = [];

  for (const { src, manifest, files } of plugins) {
    for (const file of files) {
      const { kind, name } = classify(file);
      if (kind === 'test') continue;

      if (kind === 'skill') {
        out.copy(`${src}/${file}`, `${SKILLS_DIR}/${name}/SKILL.md`, vars);
      } else if (kind === 'command') {
        commands.push({ name, ...promptFor(`${src}/${file}`, vars) });
      } else if (kind === 'hook') {
        out.copy(`${src}/${file}`, `${PLUGIN_DIR}/hooks/${name}`, vars, { exec: name.endsWith('.sh') });
      } else {
        const dest = file === 'templates/context-doc.md' ? `templates/${vars.CONTEXT_DOC}` : file;
        out.copy(`${src}/${file}`, `${PLUGIN_DIR}/${dest}`, vars);
      }
    }
    if (manifest.hooks) out.json('.codex/hooks.json', hooksJson(manifest.hooks, vars));
  }

  for (const cmd of commands) out.write(`${PROMPTS_DIR}/${cmd.name}.md`, cmd.text);

  out.write(vars.CONTEXT_DOC, agentsMd(commands, vars));
  out.write('install.sh', installSh(), { exec: true });
  out.write('README.md', readme(commands));
}

function promptFor(path, vars) {
  const { fields, body } = splitFrontmatter(readText(path, vars));
  return {
    description: fields.description,
    text: withFrontmatter(
      { description: fields.description, 'argument-hint': fields['argument-hint'] },
      body,
    ),
  };
}

// Codex no declara PostToolUseFailure: un hook con targets que no lo incluya se omite.
function hooksJson(hooks, vars) {
  const byEvent = {};
  for (const hook of hooks) {
    if (hook.targets && !hook.targets.includes('codex')) continue;
    const entry = {
      type: 'command',
      command: `bash "${vars.PLUGIN_ROOT}/hooks/${hook.script}"`,
      timeout: hook.timeout,
      statusMessage: hook.statusMessage,
    };
    const group = (byEvent[hook.event] ||= []);
    const existing = hook.matcher
      ? group.find((g) => g.matcher === hook.matcher)
      : group.find((g) => !('matcher' in g));
    if (existing) existing.hooks.push(entry);
    else group.push(hook.matcher ? { matcher: hook.matcher, hooks: [entry] } : { hooks: [entry] });
  }
  return { hooks: byEvent };
}

function agentsMd(commands, vars) {
  const rows = commands.map((c) => `| \`${vars.CMD_PREFIX}${c.name}\` | ${c.description} |`).join('\n');
  return `# AGENTS.md — proceso SDD + Strict TDD

> Bloque generado por agentic-toolkit. Pegalo en el \`AGENTS.md\` de tu repositorio
> junto a lo propio del proyecto (stack, comandos, invariantes).

## Cómo se ejecuta un cambio de código

Toda feature, bugfix o cambio de esquema se ejecuta por el pipeline SDD, pedido por
comando o en lenguaje natural. Solo el nivel trivial (typo, copy, bump de patch)
queda fuera. El pipeline, sus fases y sus gates están en
\`${PLUGIN_DIR}/ORCHESTRATOR.md\`; leelo antes de tocar código.

Si esta sesión no puede lanzar subagentes, seguí \`${PLUGIN_DIR}/ORCHESTRATOR-solo.md\`:
mismo proceso, mismas fases, ejecutadas en secuencia por una sola sesión.

## Comandos

| Comando | Qué hace |
|---|---|
${rows}

## Skills

Las skills están en \`${SKILLS_DIR}/\` y Codex las carga sola cuando la \`description\`
de cada una coincide con lo que estás haciendo. No hace falta invocarlas.

## Guardrails

Los hooks de \`.codex/hooks.json\` bloquean comandos dirigidos a producción, lectura
y escritura de secretos, datos personales en artefactos y trailers de IA en los
commits, y escriben la evidencia TDD. Corren solos: no los desactives para avanzar
más rápido — si uno te frena, el cambio es lo que está mal.
`;
}

function installSh() {
  return `#!/usr/bin/env bash
# Instala el toolkit SDD+TDD para Codex CLI en el repositorio actual.
#   bash install.sh [ruta-al-repo]
# Los prompts son de usuario ($CODEX_HOME/prompts) y hay que reinstalarlos por máquina.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "\${1:-$PWD}" && pwd)"
CODEX_HOME="\${CODEX_HOME:-$HOME/.codex}"

[ -d "$REPO/.git" ] || { echo "no parece un repositorio git: $REPO"; exit 1; }

mkdir -p "$REPO/.codex" "$REPO/.agents" "$CODEX_HOME/prompts"
cp -R "$HERE/.codex/." "$REPO/.codex/"
cp -R "$HERE/.agents/." "$REPO/.agents/"
cp "$HERE/prompts/"*.md "$CODEX_HOME/prompts/"

if [ ! -f "$REPO/.agentic/sdd-hooks.env" ]; then
  mkdir -p "$REPO/.agentic"
  cp "$HERE/.codex/sdd-tdd-core/templates/sdd-hooks.env" "$REPO/.agentic/sdd-hooks.env"
  echo "creado  .agentic/sdd-hooks.env — editalo antes del primer cambio"
fi

echo "ok      .codex/ y .agents/ en $REPO"
echo "ok      prompts en $CODEX_HOME/prompts"
echo "falta   pegar el contenido de AGENTS.md en el AGENTS.md del repo"
echo "falta   reiniciar Codex para que tome los prompts y los hooks"
`;
}

function readme(commands) {
  return `# agentic-toolkit para Codex CLI

Salida generada por \`node bin/atk build --target=codex\`. No editar a mano:
el contenido vive en \`source/\` del repositorio del toolkit.

## Instalación

\`\`\`bash
bash install.sh /ruta/a/tu/repo
\`\`\`

Después, pegá el contenido de \`AGENTS.md\` en el \`AGENTS.md\` de tu repositorio y
reiniciá Codex.

## Qué se instala

| Ruta | Qué es | Dónde queda |
|---|---|---|
| \`.codex/hooks.json\` | Registro de los hooks | repo, versionado |
| \`.codex/sdd-tdd-core/\` | Orquestador, fases, gates, plantillas y scripts de hook | repo, versionado |
| \`.agents/skills/\` | Las skills, que Codex carga por \`description\` | repo, versionado |
| \`prompts/*.md\` | Los ${commands.length} comandos como slash commands | \`$CODEX_HOME/prompts\`, por máquina |

## Diferencias con Claude Code

Los hooks bash son los mismos: Codex usa el mismo esquema de payload y de decisión.
Dos salvedades:

- Codex no declara el evento \`PostToolUseFailure\`, así que la evidencia TDD de una
  corrida en rojo llega por \`PostToolUse\`.
- Los prompts son de usuario y no se comparten por repositorio; por eso el
  \`install.sh\` los copia a \`$CODEX_HOME/prompts\` y hay que correrlo en cada máquina.

El registro de los hooks usa rutas relativas a la raíz del repositorio. Si tu
instalación de Codex ejecuta los hooks con otro directorio de trabajo, cambiá
\`command\` en \`.codex/hooks.json\` por una ruta absoluta.
`;
}
