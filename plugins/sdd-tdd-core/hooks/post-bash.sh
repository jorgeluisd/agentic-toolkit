#!/usr/bin/env bash
# PostToolUse y PostToolUseFailure / Bash — evidencia TDD mecánica + verificación post-commit.
# Registra cada corrida de tests en <raíz de artefactos>/<feature>/tdd-evidence.log:
#   <ISO-8601> | exit=<n> | <comando> | <resumen>[ | WARN=<marca>;...]
# PostToolUse llega cuando la llamada Bash termina en 0 y trae tool_response
# (stdout/stderr, sin exit code). PostToolUseFailure llega cuando falla y no trae
# tool_response: el código y la salida, con stdout y stderr mezclados, vienen en
# .error como "Exit code <n>\n<salida>", recortada a ~10 000 caracteres desde el
# principio (Claude Code 2.1.272). Ese código es el de la llamada entera, no el del
# runner: `pnpm test && cat > existente` sale 1 por la escritura con noclobber.
# Si no llega ningún evento, `flush_pending_test` concilia la corrida (common.sh).
# La raíz la resuelve common.sh (SDD_ARTIFACTS_DIR, default docs/sdd); la carpeta
# activa se lee de <raíz>/.current (la escribe el task-planner).
. "$(dirname "$0")/common.sh"
read_input
# Un payload que no se puede leer no puede salir en silencio: sin esta traza el
# hook devuelve 0 sin escribir nada y es indistinguible de "no había tests".
if [ -n "$INPUT" ] && ! printf '%s' "$INPUT" | jq -e . >/dev/null 2>&1; then
  hook_diag "post-bash: payload ilegible para jq; no se registró evidencia de esta llamada"
  exit 0
fi
cmd="$(jq_get '.tool_input.command')"
if [ -z "$cmd" ]; then
  [ -n "$INPUT" ] && hook_diag "post-bash: payload sin .tool_input.command; no se registró evidencia de esta llamada"
  exit 0
fi
lc="$(printf '%s' "$cmd" | tr '[:upper:]' '[:lower:]')"
failed="$(printf '%s' "$INPUT" | jq -r 'if .hook_event_name == "PostToolUseFailure" or (.tool_response == null and (.error | type) == "string") then 1 else 0 end' 2>/dev/null)"

# Llegó el resultado de esta llamada: la marca que dejó PreToolUse ya no hace falta.
clear_pending_test "$(jq_get '.tool_use_id')"

# Conteos del runner: vitest/jest, node --test, pytest, phpunit/pest, go, cargo, dotnet.
# RAN_RE: se ejecutó al menos un test (sin distinguir mayúsculas). FAILED_RE: al menos
# uno terminó en rojo o el código no compiló (distingue mayúsculas: FAIL de jest/go).
RAN_RE='[1-9][0-9]*[[:space:]]+(passed|failed|tests?[[:space:]]*(,|\)|$))|OK[[:space:]]*\([1-9]|^ok[[:space:]]|^#[[:space:]]+(pass|fail)[[:space:]]+[1-9]|test result: ok|passed!|Passed:[[:space:]]*[1-9]|tests: [1-9]'
FAILED_RE='[1-9][0-9]*[[:space:]]+(failed|failing|errors?)([^[:alnum:]]|$)|^#[[:space:]]+fail[[:space:]]+[1-9]|^not ok[[:space:]]|(Failures|Errors|Failed):[[:space:]]*[1-9]|FAILURES!|test result: FAILED|^--- FAIL|^FAIL[[:space:]]|error TS[0-9]+'
# A partir de este largo, .error pudo haber perdido el final de la salida.
TRUNCATED_AT=10000

# 1) Evidencia de tests.
if is_test_run "$cmd"; then
  harness_code=""; err_len=0
  if [ "$failed" = 1 ]; then
    all="$(printf '%s' "$INPUT" | jq -r '(.error // "") | tostring' 2>/dev/null)"
    err_len="$(printf '%s' "$INPUT" | jq -r '(.error // "") | tostring | length' 2>/dev/null)"
    harness_code="$(printf '%s' "$all" | head -n 1 | sed -nE 's/^Exit code ([0-9]+)[[:space:]]*$/\1/p')"
    [ -n "$harness_code" ] && all="$(printf '%s' "$all" | tail -n +2)"
  else
    stdout="$(printf '%s' "$INPUT" | jq -r '(.tool_response.stdout // .tool_response.output // .tool_response // "") | tostring' 2>/dev/null)"
    stderr="$(printf '%s' "$INPUT" | jq -r '(.tool_response.stderr // "") | tostring' 2>/dev/null)"
    all="$stdout"$'\n'"$stderr"
  fi
  # Resumen: líneas de conteo del runner; si no hay, última línea no vacía.
  summary="$(printf '%s' "$all" | grep -E 'Tests?:?[[:space:]]+[0-9]+|Test Files|passed|failed|FAILURES|OK \(|error TS[0-9]+|\[ERROR\]|test result:|^#[[:space:]]+(tests|pass|fail)[[:space:]]+[0-9]+' | tail -n 3 | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | cut -c1-240)"
  [ -z "$summary" ] && summary="$(printf '%s' "$all" | grep -v '^[[:space:]]*$' | tail -n 1 | cut -c1-240)"
  # Exit: el campo del harness; si no viene, "Exit code <n>" de PostToolUseFailure; si
  # tampoco, inferir de la salida.
  code="$(printf '%s' "$INPUT" | jq -r '.tool_response.exit_code // .tool_response.exitCode // .tool_response.code // empty' 2>/dev/null)"
  [ -z "$code" ] && code="$harness_code"
  if [ -z "$code" ]; then
    if printf '%s' "$all" | grep -Eq '([1-9][0-9]*[[:space:]]+failed|FAIL(ED|URES)?[[:space:]:]|error TS[0-9]+|Error:|ERR_|\[ERROR\]|Tests failed|test result: FAILED)'; then code=1; else code=0; fi
    # Un evento de fallo sin código legible (interrupción) no terminó en 0.
    [ "$failed" = 1 ] && [ "$code" = 0 ] && code='!0'
  fi
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  dir="$(evidence_dir)"
  mkdir -p "$dir" 2>/dev/null
  # Nunca registrar secretos ni datos personales en el log: se limpian por patrón.
  safe_cmd="$(printf '%s' "$cmd" | tr '\n' ' ' | sed -E "s#$SECRET_RE#[REDACTED]#g" | cut -c1-300)"
  safe_sum="$(printf '%s' "$summary" | sed -E "s#$SECRET_RE#[REDACTED]#g; s#$EMAIL_RE#[email]#g")"
  warn=""
  [ "$(printf '%s' "$INPUT" | jq -r '.is_interrupt == true or .tool_response.interrupted == true' 2>/dev/null)" = true ] && warn="${warn}interrupted;"
  # Salida filtrada por pipe: se pierde el resumen del runner.
  printf '%s' "$lc" | grep -Eq '\|[[:space:]]*(tail|head|grep|egrep|rg|cut|sed|awk|wc|less|more)([[:space:]]|$)' && warn="${warn}piped-output;"
  ran=0; printf '%s' "$all" | grep -Eiq "$RAN_RE" && ran=1
  red=0; printf '%s' "$all" | grep -Eq "$FAILED_RE" && red=1
  if [ "$code" = 0 ]; then
    # Verde falso: exit=0 sin evidencia de que se ejecutó al menos un test (todo skipped,
    # filtro -t sin coincidencias, "No test files found").
    [ "$ran" = 1 ] || warn="${warn}no-tests-ran;"
  elif [ "$failed" = 1 ] && [ "$red" = 0 ]; then
    # La llamada falló y el runner no reporta ningún rojo: lo que falló fue otra parte
    # del comando. Con la salida recortada no se sabe qué quedó afuera.
    if [ "${err_len:-0}" -ge "$TRUNCATED_AT" ]; then
      warn="${warn}output-truncated;"
    elif [ "$ran" = 1 ]; then
      code=0; warn="${warn}call-failed-outside-tests;"
    else
      warn="${warn}no-tests-ran;"
    fi
  fi
  # Suite completa a mitad de ciclo: `strict-tdd` reserva la suite para el cierre de
  # tarea y el verifier; dentro del ciclo GREEN/TRIANGULATE va el test dirigido.
  # Se detecta por el RED abierto: la corrida anterior apuntó a un archivo o caso y
  # falló, así que el ciclo está en curso y esta suite completa no es el gate de cierre.
  if ! is_targeted_run "$cmd" && [ -s "$dir/tdd-evidence.log" ]; then
    prev="$(tail -n 1 "$dir/tdd-evidence.log")"
    prev_cmd="$(printf '%s' "$prev" | cut -d'|' -f3)"
    prev_exit="$(printf '%s' "$prev" | cut -d'|' -f2 | tr -d '[:space:]')"
    prev_exit="${prev_exit#exit=}"
    if [ "${prev_exit:-0}" != 0 ] && is_targeted_run "$prev_cmd"; then
      warn="${warn}full-suite-mid-cycle;"
    fi
  fi
  [ -n "$warn" ] && safe_sum="$safe_sum | WARN=${warn%;}"
  printf '%s | exit=%s | %s | %s\n' "$ts" "$code" "$safe_cmd" "$safe_sum" >> "$dir/tdd-evidence.log" 2>/dev/null
fi

# 2) Verificación post-commit: identidad y trailers. Solo si el commit pudo ocurrir:
# sobre una llamada fallida, el último commit es el anterior y no es de esta llamada.
if [ "$failed" = 0 ] && printf '%s' "$lc" | grep -Eq 'git[[:space:]]+commit' && [ -d "$PROJECT_DIR/.git" ]; then
  last="$(git -C "$PROJECT_DIR" log -1 --format='%ae%n%B' 2>/dev/null)"
  if printf '%s' "$last" | grep -Eiq "$AI_TRAILER_RE"; then
    block_post "El último commit contiene atribución de IA. Corrige con: git commit --amend (mensaje sin trailers ni menciones de IA)."; exit 0
  fi
  email="$(printf '%s' "$last" | head -n 1)"
  expected="$(git -C "$PROJECT_DIR" config --local user.email 2>/dev/null)"
  if [ -z "$expected" ]; then
    block_post "El repositorio no tiene identidad local configurada (git config --local user.email). La convención exige identidad personal fijada por repo antes del primer commit."; exit 0
  fi
  if [ "$email" != "$expected" ]; then
    block_post "El commit salió con $email y la identidad local del repo es $expected. Corrige con git commit --amend --reset-author."; exit 0
  fi
fi
exit 0
