// Utilidades compartidas por los adaptadores. Sin dependencias externas.

import { readFileSync, writeFileSync, readdirSync, statSync, mkdirSync, rmSync, existsSync, chmodSync } from 'node:fs';
import { join, dirname, relative, extname, normalize } from 'node:path';

const TEXT_EXT = new Set(['.md', '.sh', '.json', '.env', '.yml', '.yaml', '.js', '.mjs', '.toml', '.txt']);

export const isText = (p) => TEXT_EXT.has(extname(p)) || p.endsWith('sdd-hooks.env');

// Un placeholder sin valor es un error de build, no un texto que llega al usuario:
// es lo que impide que un token de vendor nuevo se cuele sin pasar por targets.json.
export function render(text, vars, where) {
  return text.replace(/\{\{([A-Z_]+)\}\}/g, (match, key) => {
    if (!(key in vars)) throw new Error(`placeholder sin valor: ${match} en ${where}`);
    return vars[key];
  });
}

// Los targets sin plugins nativos tienen una sola carpeta de skills, y dos stacks
// pueden repetir nombres (domain-modeling). Cada stack queda aparte en
// stacks/<plugin>/ y el install.sh copia solo el que se elige con --stack.
export const isStack = (manifest) => manifest.name !== 'sdd-tdd-core';
export const stackDir = (manifest) => `stacks/${manifest.name}`;
const stackId = (manifest) => manifest.name.replace(/^stack-/, '');

export const INSTALL_ARGS_SH = `REPO_ARG="$PWD"
STACK=""
for arg in "$@"; do
  case "$arg" in
    --stack=*) STACK="\${arg#--stack=}" ;;
    *) REPO_ARG="$arg" ;;
  esac
done
REPO="$(cd "$REPO_ARG" && pwd)"`;

// Se elige antes de copiar nada: un stack ambiguo o desconocido no deja una
// instalación a medias.
export function chooseStackSh(stacks) {
  const ids = stacks.map(stackId);
  const detect = stacks
    .filter((m) => m.detect)
    .map((m) => `  [ -f "$REPO/${m.detect}" ] && found="$found ${stackId(m)}"`)
    .join('\n');
  return `if [ -z "$STACK" ]; then
  found=""
${detect}
  set -- $found
  case $# in
    0) STACK=none ;;
    1) STACK="$1" ;;
    *) echo "el repo coincide con varios stacks ($found): elegí uno con --stack=<${ids.join('|')}|none>"; exit 1 ;;
  esac
fi
case "$STACK" in none|stack-*) ;; *) STACK="stack-$STACK" ;; esac
if [ "$STACK" != none ] && [ ! -d "$HERE/stacks/$STACK" ]; then
  echo "stack desconocido: $STACK (disponibles: ${ids.join(' ')} none)"; exit 1
fi`;
}

export function copyStackSh({ skillsDir, stackParent }) {
  return `if [ "$STACK" = none ]; then
  echo "ok      sin plugin de stack: declará los comandos del proyecto en su documento de contexto"
else
  mkdir -p "$REPO/${skillsDir}" "$REPO/${stackParent}/$STACK"
  cp -R "$HERE/stacks/$STACK/skills/." "$REPO/${skillsDir}/"
  cp -R "$HERE/stacks/$STACK/." "$REPO/${stackParent}/$STACK/"
  rm -rf "$REPO/${stackParent}/$STACK/skills" "$REPO/${stackParent}/$STACK/knowledge"
  echo "ok      $STACK: skills en ${skillsDir}/ y plantillas en ${stackParent}/$STACK/"
fi`;
}

export function readText(path, vars) {
  return render(readFileSync(path, 'utf8'), vars, path);
}

export function walk(dir, base = dir, acc = []) {
  for (const name of readdirSync(dir).sort()) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) walk(path, base, acc);
    else acc.push(relative(base, path));
  }
  return acc;
}

// Las escrituras se acumulan y se vuelcan al final: --check compara el árbol
// entero sin tocar nada, y un build que falla a mitad no deja restos.
export class Output {
  constructor() {
    this.files = new Map();
    this.sources = new Map();
  }

  write(path, content, { exec = false } = {}) {
    this.files.set(normalize(path), { content, exec });
  }

  // Dos fuentes al mismo destino son un error: antes, el último plugin pisaba
  // en silencio al anterior (el README del core terminaba siendo el del stack).
  copy(srcPath, destPath, vars, { exec = false } = {}) {
    const dest = normalize(destPath);
    const prev = this.sources.get(dest);
    if (prev) throw new Error(`dos fuentes al mismo destino ${destPath}: ${prev} y ${srcPath}`);
    this.sources.set(dest, srcPath);
    const raw = readFileSync(srcPath);
    const content = isText(srcPath) ? render(raw.toString('utf8'), vars, srcPath) : raw;
    this.write(destPath, content, { exec });
  }

  json(path, value) {
    this.write(path, JSON.stringify(value, null, 2) + '\n');
  }
}

// prune:false para un árbol que no es exclusivo del build (la raíz del repo),
// donde borrar lo que el adaptador no emitió sería destructivo.
export function flush(out, outDir, { check = false, prune = true } = {}) {
  const diffs = [];
  const expected = new Set(out.files.keys());
  const actual = prune && existsSync(outDir) ? new Set(walk(outDir)) : new Set();

  for (const stale of actual) {
    if (!expected.has(stale)) diffs.push(`sobra   ${stale}`);
  }

  for (const [rel, { content, exec }] of out.files) {
    const abs = join(outDir, rel);
    const buf = Buffer.isBuffer(content) ? content : Buffer.from(content, 'utf8');
    if (!existsSync(abs)) diffs.push(`falta   ${rel}`);
    else if (!readFileSync(abs).equals(buf)) diffs.push(`difiere ${rel}`);
    if (check) continue;
    mkdirSync(dirname(abs), { recursive: true });
    writeFileSync(abs, buf);
    if (exec) chmodSync(abs, 0o755);
  }

  if (!check && prune) {
    for (const stale of actual) {
      if (!expected.has(stale)) rmSync(join(outDir, stale));
    }
  }
  return diffs;
}

// Clasifica un archivo del plugin por su rol, que es lo que decide dónde va en
// cada target: las skills tienen carpeta propia, los comandos se vuelven prompts
// y el resto viaja junto como cuerpo del plugin.
export function classify(file) {
  const skill = file.match(/^skills\/([^/]+)\/SKILL\.md$/);
  if (skill) return { kind: 'skill', name: skill[1] };
  const command = file.match(/^commands\/([^/]+)\.md$/);
  if (command) return { kind: 'command', name: command[1] };
  const agent = file.match(/^agents\/([^/]+)\.md$/);
  if (agent) return { kind: 'agent', name: agent[1] };
  if (file.startsWith('hooks/')) return { kind: 'hook', name: file.slice('hooks/'.length) };
  if (file.startsWith('tests/')) return { kind: 'test', name: file.slice('tests/'.length) };
  return { kind: 'other', name: file };
}

// Separa el frontmatter YAML del cuerpo. No parsea YAML: los adaptadores
// reescriben el frontmatter entero, nunca editan claves sueltas.
export function splitFrontmatter(text) {
  const match = text.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
  if (!match) return { fields: {}, body: text };
  const fields = {};
  for (const line of match[1].split('\n')) {
    const kv = line.match(/^([a-zA-Z-]+):\s*(.*)$/);
    if (kv) fields[kv[1]] = kv[2].replace(/^"(.*)"$/, '$1');
  }
  return { fields, body: match[2] };
}

export function withFrontmatter(fields, body) {
  const lines = Object.entries(fields)
    .filter(([, v]) => v !== undefined && v !== '')
    .map(([k, v]) => `${k}: ${/[:#]/.test(String(v)) ? JSON.stringify(v) : v}`);
  return `---\n${lines.join('\n')}\n---\n${body}`;
}
