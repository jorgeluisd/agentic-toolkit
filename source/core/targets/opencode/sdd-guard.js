// Guardrails SDD+TDD para OpenCode. Los hooks son los mismos scripts bash que
// usan Claude Code y Codex CLI; este shim solo traduce nombres de herramienta y
// de argumento al esquema que esperan, y la decisión de vuelta a un throw.

import { spawn } from 'node:child_process';
import { join } from 'node:path';

const HOOKS = '.opencode/sdd-tdd-core/hooks';

const TOOL_NAMES = {
  bash: 'Bash',
  read: 'Read',
  write: 'Write',
  edit: 'Edit',
  patch: 'Edit',
  task: 'Task',
};

const ARG_NAMES = {
  filePath: 'file_path',
  subagentType: 'subagent_type',
};

const BEFORE = [
  { script: 'pre-bash.sh', tools: ['Bash'] },
  { script: 'pre-file.sh', tools: ['Read', 'Edit', 'Write'] },
  { script: 'pre-task.sh', tools: ['Task'] },
];

const AFTER = [
  { script: 'post-bash.sh', tools: ['Bash'] },
  { script: 'post-file.sh', tools: ['Edit', 'Write'] },
];

function toolInput(args) {
  return Object.fromEntries(Object.entries(args ?? {}).map(([k, v]) => [ARG_NAMES[k] ?? k, v]));
}

function runHook(script, payload, cwd) {
  return new Promise((resolve) => {
    const child = spawn('bash', [join(cwd, HOOKS, script)], {
      cwd,
      env: { ...process.env, SDD_PROJECT_DIR: cwd },
      stdio: ['pipe', 'pipe', 'ignore'],
    });
    let stdout = '';
    child.stdout.on('data', (chunk) => (stdout += chunk));
    child.on('error', () => resolve(null));
    child.on('close', (code) => resolve({ code, stdout }));
    child.stdin.end(JSON.stringify(payload));
  });
}

// `ask` no existe en la API de plugins de OpenCode: se degrada a permitir.
function decisionOf(result) {
  if (!result) return { decision: 'allow' };
  if (result.code === 2) return { decision: 'deny', reason: 'guardrail SDD' };
  if (!result.stdout.trim()) return { decision: 'allow' };
  try {
    const parsed = JSON.parse(result.stdout);
    const specific = parsed.hookSpecificOutput ?? {};
    return {
      decision: specific.permissionDecision ?? parsed.decision ?? 'allow',
      reason: specific.permissionDecisionReason ?? parsed.reason ?? 'guardrail SDD',
    };
  } catch {
    return { decision: 'allow' };
  }
}

export const SddGuard = async ({ directory, worktree }) => {
  const cwd = worktree ?? directory ?? process.cwd();

  const dispatch = async (stage, event, input, extra) => {
    const toolName = TOOL_NAMES[input?.tool];
    if (!toolName) return;
    for (const { script, tools } of stage) {
      if (!tools.includes(toolName)) continue;
      const payload = {
        tool_name: toolName,
        cwd,
        hook_event_name: event,
        tool_input: toolInput(extra.args),
        ...(extra.response ? { tool_response: extra.response } : {}),
      };
      const { decision, reason } = decisionOf(await runHook(script, payload, cwd));
      if (decision === 'deny' || decision === 'block') throw new Error(reason);
    }
  };

  return {
    'tool.execute.before': async (input, output) =>
      dispatch(BEFORE, 'PreToolUse', input, { args: output?.args }),
    'tool.execute.after': async (input, output) =>
      dispatch(AFTER, 'PostToolUse', input, {
        args: output?.args,
        response: { stdout: String(output?.output ?? ''), stderr: '', interrupted: false },
      }),
  };
};
