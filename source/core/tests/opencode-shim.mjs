// Test del shim de OpenCode: que traduzca nombres, corra los hooks bash reales y
// convierta una denegacion en throw.
//
//   node source/core/tests/opencode-shim.mjs
//
// Monta un repositorio descartable con los hooks del target opencode ya compilado.

import { mkdtempSync, mkdirSync, writeFileSync, cpSync, rmSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '../../..');
const DIST = join(ROOT, 'dist/opencode/.opencode');
if (!existsSync(DIST)) throw new Error('falta dist/opencode: corré `node bin/atk build --target=opencode`');

const repo = mkdtempSync(join(tmpdir(), 'sdd-shim-'));
mkdirSync(join(repo, '.opencode'), { recursive: true });
mkdirSync(join(repo, '.agentic'), { recursive: true });
mkdirSync(join(repo, 'docs/sdd/0001-alta'), { recursive: true });
cpSync(DIST, join(repo, '.opencode'), { recursive: true });
execFileSync('git', ['init', '-q'], { cwd: repo });
writeFileSync(join(repo, '.agentic/sdd-hooks.env'), 'SDD_PROD_MARKERS=prod-cluster\nSDD_BASE_BRANCH=develop\n');
writeFileSync(join(repo, 'docs/sdd/.current'), '0001-alta');
writeFileSync(join(repo, 'docs/sdd/0001-alta/.level'), 'full');
writeFileSync(join(repo, '.env'), 'SECRET=x\n');

const { SddGuard } = await import(join(repo, '.opencode/plugins/sdd-guard.js'));
const hooks = await SddGuard({ directory: repo, worktree: repo });

let pass = 0;
let fail = 0;
async function t(name, fn, expected) {
  let got = 'allow';
  try {
    await fn();
  } catch (error) {
    got = `deny: ${error.message.slice(0, 40)}`;
  }
  const ok = expected === 'allow' ? got === 'allow' : got.startsWith('deny');
  if (ok) pass++;
  else fail++;
  console.log(`  ${ok ? '✓' : '✗'} ${name.padEnd(46)} ${got}`);
}

const before = hooks['tool.execute.before'];
const after = hooks['tool.execute.after'];

console.log('\nShim de OpenCode · traducción y decisión');
await t('bash inocuo pasa', () => before({ tool: 'bash' }, { args: { command: 'pnpm vitest run' } }), 'allow');
await t('lectura de .env denegada', () => before({ tool: 'read' }, { args: { filePath: join(repo, '.env') } }), 'deny');
await t('task sin insumos denegado', () => before({ tool: 'task' }, { args: { subagent_type: 'implementer' } }), 'deny');
await t('herramienta sin mapeo se ignora', () => before({ tool: 'todowrite' }, { args: {} }), 'allow');

await after({ tool: 'bash' }, { args: { command: 'pnpm vitest run src/x.spec.ts' }, output: '1 failed' });
const evidence = join(repo, 'docs/sdd/0001-alta/tdd-evidence.log');
const wrote = existsSync(evidence);
console.log(`  ${wrote ? '✓' : '✗'} ${'evidencia TDD escrita por el after'.padEnd(46)} ${wrote ? 'si' : 'no'}`);
wrote ? pass++ : fail++;

rmSync(repo, { recursive: true, force: true });
console.log(`\n${pass} pasaron · ${fail} fallaron\n`);
process.exit(fail === 0 ? 0 : 1);
