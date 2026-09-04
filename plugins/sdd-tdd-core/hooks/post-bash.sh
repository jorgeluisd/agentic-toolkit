#!/usr/bin/env bash
# PostToolUse/Bash — evidencia TDD mecánica + verificación post-commit.
# Registra cada corrida de tests en <raíz de artefactos>/<feature>/tdd-evidence.log:
#   <ISO-8601> | exit=<n> | <comando> | <resumen>
# La raíz la resuelve common.sh (SDD_ARTIFACTS_DIR, default docs/sdd); la carpeta
# activa se lee de <raíz>/.current (la escribe el task-planner).
. "$(dirname "$0")/common.sh"
read_input
cmd="$(jq_get '.tool_input.command')"
[ -z "$cmd" ] && exit 0
lc="$(printf '%s' "$cmd" | tr '[:upper:]' '[:lower:]')"

# 1) Evidencia de tests.
if is_test_run "$cmd"; then
  stdout="$(printf '%s' "$INPUT" | jq -r '(.tool_response.stdout // .tool_response.output // .tool_response // "") | tostring' 2>/dev/null)"
  stderr="$(printf '%s' "$INPUT" | jq -r '(.tool_response.stderr // "") | tostring' 2>/dev/null)"
  all="$stdout"$'\n'"$stderr"
  # Resumen: líneas de vitest/jest con conteos; si no hay, última línea no vacía.
  summary="$(printf '%s' "$all" | grep -E 'Tests?:?[[:space:]]+[0-9]+|Test Files|passed|failed|FAILURES|OK \(|error TS[0-9]+|\[ERROR\]|test result:' | tail -n 3 | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | cut -c1-240)"
  [ -z "$summary" ] && summary="$(printf '%s' "$all" | grep -v '^[[:space:]]*$' | tail -n 1 | cut -c1-240)"
  # Exit: preferir el campo del harness; si no viene, inferir de la salida.
  code="$(printf '%s' "$INPUT" | jq -r '.tool_response.exit_code // .tool_response.exitCode // .tool_response.code // empty' 2>/dev/null)"
  if [ -z "$code" ]; then
    if printf '%s' "$all" | grep -Eq '([1-9][0-9]*[[:space:]]+failed|FAIL(ED|URES)?[[:space:]:]|error TS[0-9]+|Error:|ERR_|\[ERROR\]|Tests failed|test result: FAILED)'; then code=1; else code=0; fi
  fi
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sdd="$ARTIFACTS_ROOT"
  if [ -f "$sdd/.current" ]; then
    dir="$sdd/$(tr -d '[:space:]' < "$sdd/.current")"
  else
    dir="$sdd/_unassigned"
  fi
  mkdir -p "$dir" 2>/dev/null
  # Nunca registrar secretos ni datos personales en el log: se limpian por patrón.
  safe_cmd="$(printf '%s' "$cmd" | tr '\n' ' ' | sed -E "s#$SECRET_RE#[REDACTED]#g" | cut -c1-300)"
  safe_sum="$(printf '%s' "$summary" | sed -E "s#$SECRET_RE#[REDACTED]#g; s#$EMAIL_RE#[email]#g")"
  # Marcas de evidencia sospechosa: salida filtrada por pipe (se pierde el resumen del runner)
  # o corrida donde no se ejecutó ningún test (filtro -t mal escrito, "No test files found").
  warn=""
  printf '%s' "$lc" | grep -Eq '\|[[:space:]]*(tail|head|grep|egrep|rg|cut|sed|awk|wc|less|more)([[:space:]]|$)' && warn="${warn}piped-output;"
  # Verde falso: exit=0 sin evidencia de que se ejecutó al menos un test (todo skipped, filtro -t sin
  # coincidencias, "No test files found"). Cubre vitest/jest, pytest, phpunit/pest, go, cargo, dotnet.
  if [ "$code" = 0 ] && ! printf '%s' "$all" | grep -Eiq '[1-9][0-9]*[[:space:]]+(passed|failed|tests?[[:space:]]*(,|\)|$))|OK[[:space:]]*\([1-9]|^ok[[:space:]]|test result: ok|passed!|Passed:[[:space:]]*[1-9]|tests: [1-9]'; then
    warn="${warn}no-tests-ran;"
  fi
  # Suite completa a mitad de ciclo: `strict-tdd` reserva la suite para el cierre de
  # tarea y el verifier; dentro del ciclo GREEN/TRIANGULATE va el test dirigido.
  # Se detecta por el RED abierto: la corrida anterior apuntó a un archivo o caso y
  # falló, así que el ciclo está en curso y esta suite completa no es el gate de cierre.
  if ! is_targeted_run "$cmd" && [ -s "$dir/tdd-evidence.log" ]; then
    prev="$(tail -n 1 "$dir/tdd-evidence.log")"
    prev_cmd="$(printf '%s' "$prev" | cut -d'|' -f3)"
    prev_exit="$(printf '%s' "$prev" | cut -d'|' -f2 | tr -dc '0-9')"
    if [ "${prev_exit:-0}" != 0 ] && is_targeted_run "$prev_cmd"; then
      warn="${warn}full-suite-mid-cycle;"
    fi
  fi
  [ -n "$warn" ] && safe_sum="$safe_sum | WARN=${warn%;}"
  printf '%s | exit=%s | %s | %s\n' "$ts" "$code" "$safe_cmd" "$safe_sum" >> "$dir/tdd-evidence.log" 2>/dev/null
fi

# 2) Verificación post-commit: identidad y trailers.
if printf '%s' "$lc" | grep -Eq 'git[[:space:]]+commit' && [ -d "$PROJECT_DIR/.git" ]; then
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
