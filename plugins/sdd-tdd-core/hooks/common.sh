#!/usr/bin/env bash
# Funciones comunes de los hooks. Se hace `source` desde cada script.
# Sin `set -e`: un grep que no matchea devuelve 1 y abortaría el hook.

# Configuración: el archivo del proyecto .claude/sdd-hooks.env (KEY=VALUE, una
# por línea) manda; el userConfig del plugin (CLAUDE_PLUGIN_OPTION_<KEY>) es el
# fallback, pensado para instalaciones a nivel de usuario compartidas por varios
# repos, donde cada repo declara sus propios valores.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
if [ -f "$PROJECT_DIR/.claude/sdd-hooks.env" ]; then
  # shellcheck disable=SC1091
  set -a; . "$PROJECT_DIR/.claude/sdd-hooks.env"; set +a
fi
PROD_MARKERS="${SDD_PROD_MARKERS:-${CLAUDE_PLUGIN_OPTION_PROD_MARKERS:-}}"
BASE_BRANCH="${SDD_BASE_BRANCH:-${CLAUDE_PLUGIN_OPTION_BASE_BRANCH:-develop}}"
TENANT_FIELD="${SDD_TENANT_FIELD:-${CLAUDE_PLUGIN_OPTION_TENANT_FIELD:-}}"
# Store de artefactos: política que siguen los agentes (repo | local | engram).
# ARTIFACTS_DIR es dónde se materializan los archivos; siempre existe, porque los
# hooks escriben en disco aunque los artefactos narrativos vivan en memoria.
# Acepta ruta relativa al proyecto (docs/sdd), absoluta (/tmp/sdd) o con ~.
ARTIFACT_STORE="${SDD_ARTIFACT_STORE:-${CLAUDE_PLUGIN_OPTION_ARTIFACT_STORE:-repo}}"
ARTIFACTS_DIR="${SDD_ARTIFACTS_DIR:-${CLAUDE_PLUGIN_OPTION_ARTIFACTS_DIR:-}}"
[ -z "$ARTIFACTS_DIR" ] && { [ "$ARTIFACT_STORE" = repo ] && ARTIFACTS_DIR="docs/sdd" || ARTIFACTS_DIR=".claude/sdd"; }
case "$ARTIFACTS_DIR" in
  "~/"*) ARTIFACTS_ROOT="$HOME/${ARTIFACTS_DIR#\~/}" ;;
  /*)    ARTIFACTS_ROOT="$ARTIFACTS_DIR" ;;
  *)     ARTIFACTS_ROOT="$PROJECT_DIR/$ARTIFACTS_DIR" ;;
esac
ARTIFACTS_ROOT="${ARTIFACTS_ROOT%/}"
# Comentarios en código: bloque contiguo máximo y porcentaje máximo de líneas comentadas por archivo.
COMMENT_MAX_BLOCK="${SDD_COMMENT_MAX_BLOCK:-${CLAUDE_PLUGIN_OPTION_COMMENT_MAX_BLOCK:-4}}"
COMMENT_MAX_PCT="${SDD_COMMENT_MAX_PCT:-${CLAUDE_PLUGIN_OPTION_COMMENT_MAX_PCT:-15}}"
# Regex que reconoce una corrida de tests (evidencia TDD). Default multi-stack.
TEST_CMD_RE="${SDD_TEST_CMD_RE:-${CLAUDE_PLUGIN_OPTION_TEST_CMD_RE:-}}"
[ -z "$TEST_CMD_RE" ] && TEST_CMD_RE='(vitest|jest|mocha|(pnpm|npm|yarn|bun)[[:space:]]+(run[[:space:]]+)?test|turbo[[:space:]]+(run[[:space:]]+)?test|tsc[[:space:]].*--noemit|phpunit|[[:space:]/]pest([[:space:]]|$)|artisan[[:space:]]+test|composer[[:space:]]+test|phpstan|pytest|python[[:space:]]+-m[[:space:]]+(pytest|unittest)|mypy|go[[:space:]]+test|cargo[[:space:]]+test|dotnet[[:space:]]+test|mvn[[:space:]]+(test|verify)|gradle[[:space:]]+test|swift[[:space:]]+test|xcodebuild[[:space:]]+test)'
# is_test_run <comando>: 0 si alguno de los segmentos del comando ejecuta tests.
# Quita cadenas entre comillas y descarta segmentos cuyo primer verbo es de
# impresión/lectura (echo, printf, cat, grep, git, sed...) para que "echo pnpm test"
# o git commit -m "run vitest" no cuenten como evidencia.
is_test_run() {
  local c stripped seg first
  c="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr '\n' ' ')"
  stripped="$(printf '%s' "$c" | sed -E "s/'[^']*'//g; s/\"[^\"]*\"//g")"
  printf '%s\n' "$stripped" | sed -E 's/\|\||&&|;|\|/\n/g' | while IFS= read -r seg; do
    seg="$(printf '%s' "$seg" | sed -E 's/^[[:space:]]+//; s/^(cd [^ ]+ *)//; s/^([a-z_]+=[^ ]+ +)*//')"
    first="$(printf '%s' "$seg" | awk '{print $1}')"
    case "$first" in
      echo|printf|cat|grep|egrep|rg|tail|head|less|more|sed|awk|cut|wc|git|gh|ls|find|open|code|vim|nano|man|which|type|"") continue ;;
    esac
    printf '%s' "$seg" | grep -Eq "$TEST_CMD_RE" && { echo yes; break; }
  done | grep -q yes
}
# Gestor de paquetes JS del proyecto (para el guardrail npm/yarn): solo aplica si hay pnpm-lock.yaml.
PNPM_PROJECT=0; [ -f "$PROJECT_DIR/pnpm-lock.yaml" ] && PNPM_PROJECT=1

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
