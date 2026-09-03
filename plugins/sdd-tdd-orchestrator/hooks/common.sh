#!/usr/bin/env bash
# Funciones comunes de los hooks. Se hace `source` desde cada script.
# Sin `set -e`: un grep que no matchea devuelve 1 y abortaría el hook.

# Configuración: primero variables de entorno exportadas por el harness a partir
# del userConfig del plugin (CLAUDE_PLUGIN_OPTION_<KEY>); después, si existe,
# el archivo del proyecto .claude/sdd-hooks.env (KEY=VALUE, una por línea), que
# funciona aunque el harness no exporte las opciones.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
if [ -f "$PROJECT_DIR/.claude/sdd-hooks.env" ]; then
  # shellcheck disable=SC1091
  set -a; . "$PROJECT_DIR/.claude/sdd-hooks.env"; set +a
fi
PROD_MARKERS="${CLAUDE_PLUGIN_OPTION_PROD_MARKERS:-${SDD_PROD_MARKERS:-}}"
BASE_BRANCH="${CLAUDE_PLUGIN_OPTION_BASE_BRANCH:-${SDD_BASE_BRANCH:-develop}}"
TENANT_FIELD="${CLAUDE_PLUGIN_OPTION_TENANT_FIELD:-${SDD_TENANT_FIELD:-}}"

read_input() { INPUT="$(cat)"; }
jq_get() { printf '%s' "$INPUT" | jq -r "$1 // \"\"" 2>/dev/null; }

# PreToolUse: pedir confirmación humana / denegar.
ask()  { printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":%s}}\n' "$(printf '%s' "$1" | jq -Rs .)"; }
deny() { printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$(printf '%s' "$1" | jq -Rs .)"; }
# PostToolUse: devolver el problema al agente para que lo corrija.
block_post() { printf '{"decision":"block","reason":%s}\n' "$(printf '%s' "$1" | jq -Rs .)"; }

# Patrones compartidos.
AI_TRAILER_RE='co-authored-by|claude-session|generated with|anthropic|noreply@anthropic'
SECRET_RE='(sk-[A-Za-z0-9]{16,}|eyJ[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{10,}|postgres(ql)?://[^[:space:]]+:[^[:space:]@]+@|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----)'
EMAIL_RE='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
PHONE_RE='\+[0-9]{8,15}'
EXAMPLE_EMAIL_RE='@(example\.(com|org|net)|test\.local|localhost)'
