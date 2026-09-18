// Adaptador Devin → dist/devin/
// Devin no tiene hooks ni subagentes: el pipeline corre en modo solo y los
// guardrails son reglas en AGENTS.md, no controles que frenen.

import { readText, classify, splitFrontmatter } from './lib.mjs';

const PLUGIN_DIR = '.agents/sdd-tdd-core';

const FORBIDDEN = [
  '- Leer o editar `.env*`, `*.pem`, `*.key` ni ningún archivo de credenciales.',
  '- Escribir secretos, datos personales reales o identificadores de producción en un artefacto, un test o un commit. Los ejemplos son sintéticos: teléfonos `+10000000001`, dominios `example.com`.',
  '- Correr comandos dirigidos a producción (psql contra una base productiva, deploys, actualización de una lambda) sin confirmación humana explícita.',
  '- Forzar un push, saltear los hooks de git al commitear, o pushear directo a la rama base.',
  '- Agregar trailers o menciones de IA al commit o al PR: `Co-Authored-By`, `Generated with`, nombres de modelos, `anthropic`, `openai`, `devin.ai`.',
  '- Escribir código de producción antes del GATE 1 aprobado.',
  '- Escribir código de producción en una fase que no sea `implementer`.',
  '- Bloques de comentario de más de 4 líneas, o más de 15 % de líneas comentadas en un archivo de código.',
].join('\n');

export function buildTarget({ plugins, out, vars }) {
  const commands = [];
  const skills = [];

  for (const { src, files } of plugins) {
    for (const file of files) {
      const { kind, name } = classify(file);
      if (kind === 'test' || kind === 'hook') continue;

      if (kind === 'skill') {
        const { fields, body } = splitFrontmatter(readText(`${src}/${file}`, vars));
        skills.push({ name, description: fields.description });
        out.copy(`${src}/${file}`, `.agents/skills/${name}/SKILL.md`, vars);
        out.write(`knowledge/${name}.md`, knowledgeEntry(name, fields.description, body));
      } else if (kind === 'command') {
        const { fields, body } = splitFrontmatter(readText(`${src}/${file}`, vars));
        commands.push({ name, description: fields.description });
        out.write(`playbooks/${name}.devin.md`, playbook(name, fields, body));
      } else {
        const dest = file === 'templates/context-doc.md' ? `templates/${vars.CONTEXT_DOC}` : file;
        out.copy(`${src}/${file}`, `${PLUGIN_DIR}/${dest}`, vars);
      }
    }
  }

  out.write(vars.CONTEXT_DOC, agentsMd(commands, vars));
  out.write('install.sh', installSh(commands, skills), { exec: true });
  out.write('README.md', readme(commands, skills));
}

function knowledgeEntry(name, description, body) {
  return `# ${name}

**Cuándo aplica (trigger de la entrada de Knowledge):** ${description}

---
${body}`;
}

function playbook(name, fields, body) {
  const hint = fields['argument-hint'] ? `\n**Argumentos:** \`${fields['argument-hint']}\`\n` : '\n';
  return `# ${name}

${fields.description}
${hint}
## Procedure

${body.replace(/\$ARGUMENTS/g, 'lo que te pidió el usuario')}

## Specifications

- El pipeline, las fases y los gates están en \`${PLUGIN_DIR}/ORCHESTRATOR-solo.md\`. Leelo antes de empezar.
- Los artefactos van a \`docs/sdd/<NNNN>-<slug>/\` y son la máquina de estados del proceso: si no está escrito, no pasó.
- En cada gate te detenés de verdad y esperás el token del humano. Un gate sin registro en \`gates.md\` no ocurrió.

## Forbidden Actions

${FORBIDDEN}
`;
}

function agentsMd(commands, vars) {
  const rows = commands.map((c) => `| \`${c.name}\` | ${c.description} |`).join('\n');
  return `# AGENTS.md — proceso SDD + Strict TDD

> Bloque generado por agentic-toolkit. Pegalo en el \`AGENTS.md\` de tu repositorio
> junto a lo propio del proyecto (stack, comandos, invariantes).

## Cómo se ejecuta un cambio de código

Toda feature, bugfix o cambio de esquema se ejecuta por el pipeline SDD. Solo el
nivel trivial (typo, copy, bump de patch) queda fuera.

**Seguí \`${PLUGIN_DIR}/ORCHESTRATOR-solo.md\`.** Es el pipeline completo — diez
fases, dos gates humanos — ejecutado en secuencia por una sola sesión, porque acá
no hay subagentes. Cada fase carga su rol de \`${PLUGIN_DIR}/agents/<fase>.md\`,
verifica sus insumos y escribe su artefacto antes de pasar a la siguiente.

Los artefactos en \`docs/sdd/<NNNN>-<slug>/\` son la máquina de estados: el estado
del pipeline no vive en la conversación, vive en disco. Una sesión que se corta se
retoma mirando qué artefactos existen.

## Playbooks

Cargalos desde \`playbooks/\`. Equivalen a los comandos del toolkit.

| Playbook | Qué hace |
|---|---|
${rows}

## Reglas que acá nadie hace cumplir por vos

En otros agentes estas reglas son hooks que **bloquean** la llamada. Devin no tiene
hooks: son reglas que leés y cumplís. Nadie te va a frenar.

${FORBIDDEN}

## Evidencia TDD

En las tareas con \`TDD: ON\`, anotá cada ciclo en
\`docs/sdd/<NNNN>-<slug>/tdd-evidence.log\`, una línea por fase, con el comando
literal y su resultado. En otros agentes lo escribe un hook; acá lo escribís vos, y
el \`verifier\` lo contrasta contra el apply-progress. Formato en
\`${PLUGIN_DIR}/ORCHESTRATOR-solo.md\` §5.
`;
}

// Devin no instala nada local: el script deja en el repo lo que Devin lee de ahí y
// lista lo que solo se carga desde la web.
function installSh(commands, skills) {
  return `#!/usr/bin/env bash
# Instala el toolkit SDD+TDD para Devin en el repositorio actual.
#   bash install.sh [ruta-al-repo]
# Playbooks y Knowledge no viven en el repo: se cargan a mano en la web de Devin.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "\${1:-$PWD}" && pwd)"

[ -d "$REPO/.git" ] || { echo "no parece un repositorio git: $REPO"; exit 1; }

mkdir -p "$REPO/.agents"
cp -R "$HERE/.agents/." "$REPO/.agents/"

if [ ! -f "$REPO/.agentic/sdd-hooks.env" ]; then
  mkdir -p "$REPO/.agentic"
  cp "$HERE/${PLUGIN_DIR}/templates/sdd-hooks.env" "$REPO/.agentic/sdd-hooks.env"
  echo "creado  .agentic/sdd-hooks.env — editalo antes del primer cambio"
fi

echo "ok      .agents/ en $REPO"
if [ ! -f "$REPO/AGENTS.md" ]; then
  cp "$HERE/AGENTS.md" "$REPO/AGENTS.md"
  echo "creado  AGENTS.md — sumale lo propio del proyecto (stack, comandos, invariantes)"
elif grep -q 'Bloque generado por agentic-toolkit' "$REPO/AGENTS.md"; then
  echo "ok      AGENTS.md ya tiene el bloque del toolkit"
else
  echo "falta   pegar el contenido de $HERE/AGENTS.md en el AGENTS.md del repo"
fi
echo "falta   commitear .agents/, .agentic/ y AGENTS.md: Devin los lee del repo"
echo "falta   subir los ${commands.length} playbooks de $HERE/playbooks a Devin"
echo "opcional cargar las ${skills.length} entradas de $HERE/knowledge en el Knowledge de Devin"
`;
}

function readme(commands, skills) {
  return `# agentic-toolkit para Devin

Salida generada por \`node bin/atk build --target=devin\`. No editar a mano:
el contenido vive en \`source/\` del repositorio del toolkit.

## Instalación

\`\`\`bash
bash install.sh /ruta/a/tu/repo
\`\`\`

El script copia \`.agents/\` al repositorio, crea \`.agentic/sdd-hooks.env\` si no
existe y crea \`AGENTS.md\` si el repositorio no tiene uno. Lo demás es manual:

1. Si tu repositorio ya tenía \`AGENTS.md\`, pegá dentro el contenido de \`AGENTS.md\`.
2. Commiteá \`.agents/\`, \`.agentic/\` y \`AGENTS.md\`. Devin los lee del repo.
3. Subí los ${commands.length} playbooks de \`playbooks/*.devin.md\` a Devin
   (arrastrarlos al iniciar una sesión, o crearlos en la web).
4. Opcional: cargá las ${skills.length} entradas de \`knowledge/\` en el Knowledge de
   Devin. El *trigger* de cada una es la línea "Cuándo aplica".

## Qué NO funciona acá

Devin no tiene hooks ni subagentes. Dos consecuencias, sin disimulo:

- **El pipeline corre en modo solo.** Una sesión adopta las diez fases en orden.
  No hay gatekeeper que deniegue lanzar una fase sin sus insumos: esa disciplina la
  sostiene el bucle de \`ORCHESTRATOR-solo.md\` §2.
- **Los guardrails son instructivos.** Producción, secretos, PII, comentarios,
  trailers de IA y evidencia TDD están escritos como reglas en \`AGENTS.md\`, y Devin
  puede no cumplirlas. Fue una decisión explícita del toolkit: no se agrega
  enforcement por CI ni por pre-commit.

Si necesitás que se hagan cumplir de verdad, el camino es un job de CI en tu
repositorio, fuera del alcance de este toolkit.
`;
}
