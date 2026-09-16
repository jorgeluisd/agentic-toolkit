// Adaptador Claude Code → plugins/<nombre>/
//
// Es la misma ruta que apuntaba marketplace.json en 1.x, así que la reestructura
// no invalida los plugins ya instalados ni el cache de versiones.

import { render } from './lib.mjs';

const MARKETPLACE = {
  name: 'agentic-toolkit',
  description:
    'Marketplace de plugins de Claude Code para desarrollo con SDD + Strict TDD: un core de proceso agnostico de lenguaje y un plugin de skills por stack.',
  owner: { name: 'Jorge Diaz', email: 'diazjorgeluis10@gmail.com' },
};

const CATEGORY = 'development';

const renamedFor = (file, vars) =>
  file === 'templates/context-doc.md' ? `templates/${vars.CONTEXT_DOC}` : file;

export function buildTarget({ plugins, out, rootOut, vars }) {
  for (const { src, manifest, files } of plugins) {
    for (const file of files) {
      out.copy(`${src}/${file}`, `${manifest.name}/${renamedFor(file, vars)}`, vars, {
        exec: file.endsWith('.sh'),
      });
    }
    out.json(`${manifest.name}/.claude-plugin/plugin.json`, pluginJson(manifest, vars));
    if (manifest.hooks) out.json(`${manifest.name}/hooks/hooks.json`, hooksJson(manifest.hooks, vars));
  }

  const core = plugins.find((p) => p.manifest.name === 'sdd-tdd-core');
  rootOut.json('.claude-plugin/marketplace.json', {
    ...MARKETPLACE,
    version: core.manifest.version,
    plugins: plugins.map(({ manifest }) => ({
      name: manifest.name,
      description: manifest.description,
      source: `./plugins/${manifest.name}`,
      category: CATEGORY,
    })),
  });
}

function userConfig(config, manifest, vars) {
  return Object.fromEntries(
    Object.entries(config).map(([key, entry]) => [
      key,
      {
        type: 'string',
        title: entry.title,
        description: render(entry.description, vars, `${manifest.name}/manifest.json`),
        default: entry.default,
        required: false,
      },
    ]),
  );
}

function pluginJson(manifest, vars) {
  const json = {
    name: manifest.name,
    displayName: manifest.displayName,
    version: manifest.version,
    description: render(manifest.description, vars, `${manifest.name}/manifest.json`),
    author: manifest.author,
    license: manifest.license,
    keywords: manifest.keywords,
  };
  if (manifest.config) json.userConfig = userConfig(manifest.config, manifest, vars);
  json.homepage = manifest.homepage;
  json.repository = manifest.repository;
  return json;
}

// Un hook con `targets` que no incluya claude no se emite: PostToolUseFailure
// existe solo acá y se declara una vez en el manifiesto, sin ensuciar a los demás.
function hooksJson(hooks, vars) {
  const byEvent = {};
  for (const hook of hooks) {
    if (hook.targets && !hook.targets.includes('claude')) continue;
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
