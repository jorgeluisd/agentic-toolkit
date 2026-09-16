#!/usr/bin/env bash
# Funciones comunes de los hooks. Se hace `source` desde cada script.
# Sin `set -e`: un grep que no matchea devuelve 1 y abortaría el hook.

# Configuración: el archivo del proyecto .claude/sdd-hooks.env (KEY=VALUE, una
# por línea) manda; el userConfig del plugin (CLAUDE_PLUGIN_OPTION_<KEY>) es el
# fallback, pensado para instalaciones a nivel de usuario compartidas por varios
# repos, donde cada repo declara sus propios valores.
#
# CLAUDE_PROJECT_DIR es la raíz de la SESIÓN, que no tiene por qué ser un
# repositorio: abierta en una carpeta que contiene varios repos apunta a la
# contenedora, ahí no está .claude/sdd-hooks.env y la configuración del repo se
# ignora en silencio (guardrail de producción inerte, evidencia en un _unassigned
# fuera de todo repositorio). El ancla buena es lo que la herramienta está
# tocando: `read_input` la saca del payload y vuelve a resolver la raíz.

# Claves que el archivo del proyecto puede definir. Se guarda lo que traía el
# entorno para que una re-resolución recargue desde cero: si no, el repositorio B
# hereda las claves que el archivo de A definió y B no.
SDD_KEYS="SDD_PROD_MARKERS SDD_BASE_BRANCH SDD_TENANT_FIELD SDD_ARTIFACT_STORE SDD_ARTIFACTS_DIR SDD_PROGRESS_KEEP_TASKS SDD_COMMENT_MAX_BLOCK SDD_COMMENT_MAX_PCT SDD_TEST_CMD_RE"
for _k in $SDD_KEYS; do eval "_sdd_env_$_k=\${$_k:-}"; done

# _sdd_climb <ruta absoluta>: sube hasta el primer directorio que parezca la raíz
# de un repositorio. `.git` puede ser un archivo y no un directorio (worktrees,
# submódulos): por eso -e. Devuelve 1 si no encuentra ninguno.
_sdd_climb() {
  local d="$1"
  case "$d" in /*) ;; *) return 1 ;; esac
  [ -d "$d" ] || d="${d%/*}"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    [ -f "$d/.claude/sdd-hooks.env" ] && { printf '%s' "$d"; return 0; }
    [ -e "$d/.git" ] && { printf '%s' "$d"; return 0; }
    d="${d%/*}"
  done
  return 1
}

# _sdd_in_session_tree <ruta>: la ruta está en la misma rama del árbol que la raíz
# de la sesión (arriba o abajo de ella). Acota la heurística del comando, que
# puede traer la ruta de un binario o de un repositorio ajeno: /opt/homebrew y
# muchos $HOME son repositorios git, y ahí no va ni la evidencia ni nada.
_sdd_in_session_tree() {
  case "$_sdd_base" in "$1"|"$1"/*) return 0 ;; esac
  case "$1" in "$_sdd_base"/*) return 0 ;; esac
  return 1
}

# _sdd_configure <raíz>: fija PROJECT_DIR y todo lo que se deriva de él.
_sdd_configure() {
  local k _opt _pkg _end
  PROJECT_DIR="$1"
  for k in $SDD_KEYS; do eval "$k=\$_sdd_env_$k"; done
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
  # Tareas cuyo detalle se conserva en 05-apply-progress.md antes de rotar. El
  # implementer relee ese archivo en cada tarea: sin rotar, el costo crece
  # cuadráticamente (la tarea N relee el detalle de las N-1 anteriores).
  PROGRESS_KEEP_TASKS="${SDD_PROGRESS_KEEP_TASKS:-${CLAUDE_PLUGIN_OPTION_PROGRESS_KEEP_TASKS:-10}}"
  case "$PROGRESS_KEEP_TASKS" in ""|*[!0-9]*) PROGRESS_KEEP_TASKS=10 ;; esac
  # Comentarios en código: bloque contiguo máximo y porcentaje máximo de líneas comentadas por archivo.
  COMMENT_MAX_BLOCK="${SDD_COMMENT_MAX_BLOCK:-${CLAUDE_PLUGIN_OPTION_COMMENT_MAX_BLOCK:-4}}"
  COMMENT_MAX_PCT="${SDD_COMMENT_MAX_PCT:-${CLAUDE_PLUGIN_OPTION_COMMENT_MAX_PCT:-15}}"
  # Regex que reconoce una corrida de tests (evidencia TDD). Default multi-stack.
  TEST_CMD_RE="${SDD_TEST_CMD_RE:-${CLAUDE_PLUGIN_OPTION_TEST_CMD_RE:-}}"
  # El gestor admite opciones globales entre el binario y el script, y un agente con el
  # cwd en la carpeta padre las usa: `pnpm --dir <ruta> test`, `pnpm -C <ruta> test`,
  # `npm --prefix <ruta> test`, `pnpm --filter <paquete> test`, `pnpm -r test`,
  # `yarn workspace <paquete> test`. El valor de la opción es opcional a propósito: si
  # fuera obligatorio, `-r test` se comería `test` como valor y la corrida no se
  # registraría. Incluye los comandos *agregados* de gate (check, verify, validate,
  # run ci): en la mayoría de los repos son los que de verdad corren la suite. `npm ci`
  # queda fuera — instala dependencias, no corre tests — por eso `ci` exige `run` delante.
  _opt='([[:space:]]+-{1,2}[a-z][a-z0-9-]*(=[^[:space:]]+)?([[:space:]]+[^-[:space:]][^[:space:]]*)?)*'
  _pkg="(pnpm|npm|yarn|bun|turbo)${_opt}([[:space:]]+workspace[[:space:]]+[^-[:space:]][^[:space:]]*)?${_opt}"
  _end='([[:space:]:]|$)'
  [ -z "$TEST_CMD_RE" ] && TEST_CMD_RE="(vitest|jest|mocha\
|${_pkg}[[:space:]]+(run[[:space:]]+)?test${_end}\
|${_pkg}[[:space:]]+(run[[:space:]]+)?(check|verify|validate)${_end}\
|${_pkg}[[:space:]]+run[[:space:]]+ci${_end}\
|tsc[[:space:]].*--noemit|phpunit|[[:space:]/]pest([[:space:]]|\$)|artisan[[:space:]]+test\
|composer[[:space:]]+test|phpstan|pytest|python[[:space:]]+-m[[:space:]]+(pytest|unittest)\
|mypy|go[[:space:]]+test|cargo[[:space:]]+test|dotnet[[:space:]]+test\
|mvn[[:space:]]+(test|verify)|gradle[[:space:]]+test|swift[[:space:]]+test|xcodebuild[[:space:]]+test)"
  # Gestor de paquetes JS del proyecto (guardrail npm/yarn): solo si hay pnpm-lock.yaml.
  PNPM_PROJECT=0; [ -f "$PROJECT_DIR/pnpm-lock.yaml" ] && PNPM_PROJECT=1
  return 0
}

# Punto de partida, antes de ver ningún payload: la raíz de la sesión, trepada si
# resuelve. Sin repositorio ni configuración por ningún lado, queda como estaba.
_sdd_base="${CLAUDE_PROJECT_DIR:-$(pwd)}"
_sdd_configure "$(_sdd_climb "$_sdd_base" || printf '%s' "$_sdd_base")"

_sdd_field() { printf '%s' "$1" | jq -r "$2 // \"\"" 2>/dev/null; }

# La ruta del comando es una heurística sobre la primera ruta absoluta que aparece.
_sdd_cmd_path() {
  local c
  c="$(_sdd_field "$1" '.tool_input.command')"
  [ -n "$c" ] || return 1
  c="$(printf '%s' "$c" | grep -oE '(^|[[:space:]=])/[^[:space:];|&)]+' | head -n 1 | sed -E 's/^[[:space:]=]//; s/["'"'"']+$//')"
  [ -n "$c" ] && _sdd_in_session_tree "$c" && printf '%s' "$c"
}

# sdd_reanchor <payload>: vuelve a resolver la raíz con lo que el payload dice que
# la herramienta está tocando. Orden de confianza: el archivo (Write/Edit/Read),
# la primera ruta absoluta del comando (Bash, heurística), el cwd del payload, y
# recién al final la raíz de la sesión, que es la que puede estar equivocada.
# Cada ancla se paga solo si hace falta: el hook corre en cada herramienta que usa
# el agente, y un Write se resuelve con una sola llamada a jq.
sdd_reanchor() {
  local p d
  p="$1"; [ -n "$p" ] || return 0
  d="$(_sdd_climb "$(_sdd_field "$p" '.tool_input.file_path')")" ||
    d="$(_sdd_climb "$(_sdd_cmd_path "$p")")" ||
    d="$(_sdd_climb "$(_sdd_field "$p" '.cwd')")" ||
    return 0
  [ "$d" = "$PROJECT_DIR" ] || _sdd_configure "$d"
}

# is_test_run <comando>: 0 si alguno de los segmentos del comando ejecuta tests.
# Quita cadenas entre comillas y descarta segmentos cuyo primer verbo es de
# impresión/lectura (echo, printf, cat, grep, git, sed...) para que "echo pnpm test"
# o git commit -m "run vitest" no cuenten como evidencia.
#
# El cuerpo de un heredoc es dato, no comando: sin quitarlo, escribir "corre
# vitest" dentro de un heredoc se registra como corrida de tests. Se conserva la
# línea que lo abre (ahí sí hay un comando) y se descarta hasta el delimitador.
strip_heredocs() {
  awk '
    inhd { l=$0; sub(/^[ \t]+/,"",l); if (l==delim) inhd=0; next }
    match($0, /<<-?[ \t]*["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?[ \t]*$/) {
      delim=substr($0,RSTART,RLENGTH)
      sub(/^<<-?[ \t]*/,"",delim); gsub(/["\047]/,"",delim); sub(/[ \t]+$/,"",delim)
      inhd=1
    }
    { print }'
}
# heredoc_bodies <comando>: el inverso de strip_heredocs, solo los cuerpos. Con
# `git commit -F - <<'EOF'` el cuerpo *es* el mensaje del commit.
heredoc_bodies() {
  awk '
    inhd { l=$0; sub(/^[ \t]+/,"",l); if (l==delim) { inhd=0; next } print; next }
    match($0, /<<-?[ \t]*["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?[ \t]*$/) {
      delim=substr($0,RSTART,RLENGTH)
      sub(/^<<-?[ \t]*/,"",delim); gsub(/["\047]/,"",delim); sub(/[ \t]+$/,"",delim)
      inhd=1
    }'
}

# commit_message <comando>: lo que va a quedar escrito en el mensaje —valores de
# -m/--message/--trailer y cuerpos de heredoc—, no el comando entero. La distinción
# importa: `delivery-workflow` §3 manda verificar cada commit con un grep que nombra
# los patrones de atribución, y mirar el comando completo denegaba esa verificación
# cuando iba encadenada al commit. Un mensaje por archivo (`-F notas.txt`) no se lee
# acá; a ese lo agarra la verificación post-commit de post-bash.sh sobre el commit real.
commit_message() {
  printf '%s' "$1" | grep -oE "(^|[[:space:]])(-m|--message|--trailer)(=|[[:space:]]+)('[^']*'|\"[^\"]*\"|[^[:space:]]+)"
  printf '%s' "$1" | heredoc_bodies
}
is_test_run() {
  local c stripped seg first
  c="$(printf '%s' "$1" | strip_heredocs | tr '[:upper:]' '[:lower:]' | tr '\n' ';')"
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
# is_targeted_run <comando>: 0 si la corrida apunta a un archivo de test concreto
# o filtra un caso por nombre. Lo contrario es una suite completa (de proyecto o de
# paquete), que en el ciclo RED→GREEN es el antipatrón que `strict-tdd` prohíbe.
# Agnóstico de stack: un test dirigido nombra un archivo o pasa un filtro de caso
# (-t, -k, --testNamePattern, -run, --filter-name), venga del runner que venga.
is_targeted_run() {
  local c
  c="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr '\n' ' ')"
  # Un archivo de test nombrado explícitamente.
  printf '%s' "$c" | grep -Eq '[^[:space:]]+\.(spec|test|e2e-spec|integration\.spec)\.[a-z]+([[:space:]]|$)' && return 0
  printf '%s' "$c" | grep -Eq 'test_[a-z0-9_]+\.py|[a-z0-9_]+_test\.(py|go|rb|exs?)' && return 0
  # Un filtro de caso por nombre.
  printf '%s' "$c" | grep -Eq '(^|[[:space:]])(-t|-k|-run|--testnamepattern|--filter-name|--grep)([[:space:]]|=)' && return 0
  return 1
}

# evidence_dir: carpeta activa de artefactos donde se materializa la evidencia.
evidence_dir() {
  if [ -f "$ARTIFACTS_ROOT/.current" ]; then
    printf '%s/%s' "$ARTIFACTS_ROOT" "$(tr -d '[:space:]' < "$ARTIFACTS_ROOT/.current")"
  else
    printf '%s/_unassigned' "$ARTIFACTS_ROOT"
  fi
}

# hook_diag <mensaje>: un hook que no puede hacer su trabajo lo deja escrito. Sin
# esto un payload ilegible sale con exit 0 y es indistinguible de "no había nada
# que registrar", que es justo la ambigüedad que la evidencia mecánica evita.
hook_diag() {
  mkdir -p "$ARTIFACTS_ROOT" 2>/dev/null || return 0
  printf '%s | %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$ARTIFACTS_ROOT/.hook-errors.log" 2>/dev/null
}

# Corrida de tests pendiente de resultado.
#
# post-bash.sh recibe el resultado de cada llamada Bash por PostToolUse (terminó en
# 0) o por PostToolUseFailure (falló) y limpia la marca de esa llamada. La marca es
# para cuando no llega ningún evento: PreToolUse la deja antes de lanzar la corrida,
# un archivo por tool_use_id en <feature>/.tdd-pending/, y la que nadie limpia se
# registra como exit=!0 sin salida. La concilian:
# - pre-bash.sh, solo las vencidas: una llamada en paralelo puede seguir corriendo, y
#   conciliarla antes de su evento registraría un rojo que no ocurrió. Vencida es más
#   vieja que el timeout máximo de Bash (10 min), con margen.
# - user-prompt.sh, todas: con el turno terminado ya no hay evento en camino.
PENDING_STALE_MIN=15
pending_dir() { printf '%s/.tdd-pending' "$(evidence_dir)"; }
_pending_id() { local id; id="$(printf '%s' "$1" | tr -cd 'A-Za-z0-9_-' | cut -c1-100)"; printf '%s' "${id:-sin-id}"; }

mark_pending_test() {
  local d; d="$(pending_dir)"
  [ -f "$d" ] && _flush_pending_entry "$d"
  mkdir -p "$d" 2>/dev/null || return 0
  printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$(printf '%s' "$1" | tr '\n' ' ' | sed -E "s#$SECRET_RE#[REDACTED]#g" | cut -c1-300)" \
    >| "$d/$(_pending_id "$2")" 2>/dev/null
}

clear_pending_test() {
  local d; d="$(pending_dir)"
  [ -d "$d" ] || return 0
  rm -f "$d/$(_pending_id "$1")" 2>/dev/null
  rmdir "$d" 2>/dev/null
  return 0
}

_flush_pending_entry() {
  local f="$1" ts cmd
  [ -s "$f" ] || { rm -f "$f" 2>/dev/null; return 0; }
  ts="$(cut -f1 < "$f")"; cmd="$(cut -f2- < "$f")"
  rm -f "$f" 2>/dev/null
  printf '%s | exit=!0 | %s | sin salida capturada | WARN=resultado-inferido-por-ausencia-de-PostToolUse\n' \
    "$ts" "$cmd" >> "$(evidence_dir)/tdd-evidence.log" 2>/dev/null
}

# flush_pending_test [all]: sin argumento concilia solo las marcas vencidas.
flush_pending_test() {
  local d f; d="$(pending_dir)"
  # La marca de 1.4.x es un archivo sin tool_use_id: se concilia como entonces.
  if [ -f "$d" ]; then _flush_pending_entry "$d"; return 0; fi
  [ -d "$d" ] || return 0
  if [ "${1:-}" = all ]; then
    find "$d" -type f 2>/dev/null
  else
    find "$d" -type f -mmin "+$PENDING_STALE_MIN" 2>/dev/null
  fi | while IFS= read -r f; do _flush_pending_entry "$f"; done
  rmdir "$d" 2>/dev/null
  return 0
}

read_input() { INPUT="$(cat)"; sdd_reanchor "$INPUT"; }
jq_get() { _sdd_field "$INPUT" "$1"; }

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
