#!/usr/bin/env bash
# E2E de los hooks de sdd-tdd-core sobre un repositorio git real y descartable.
#
# Invoca cada hook con el mismo payload JSON que le manda Claude Code y con
# CLAUDE_PROJECT_DIR apuntando al repo de prueba, así que ejercita el camino real:
# resolución de la raíz de artefactos, gatekeeper de fases, guardrails de
# producción, git, secretos y PII, evidencia TDD y ciclo de vida del change.
#
#   bash plugins/sdd-tdd-core/tests/e2e.sh
#
# Sale 0 si todo pasa. Requiere bash, git y jq. Si hay node, la evidencia TDD se
# captura de una corrida de tests real; si no, del payload equivalente.
set -u

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
for bin in git jq; do
  command -v "$bin" >/dev/null || { echo "falta $bin en el PATH"; exit 2; }
done

R="$(mktemp -d "${TMPDIR:-/tmp}/sdd-e2e.XXXXXX")"
trap 'rm -rf "$R"' EXIT

PASS=0; FAIL=0
if [ -t 1 ]; then G=$'\033[32m'; B=$'\033[31m'; W=$'\033[1m'; N=$'\033[0m'; else G=; B=; W=; N=; fi

hook(){ printf '%s' "$2" | env CLAUDE_PROJECT_DIR="$R" bash "$HOOKS/$1" 2>/dev/null; }
dec(){ local o; o="$(hook "$1" "$2")"
  if [ -z "$o" ]; then echo allow
  else printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecision // .decision // "allow"'; fi; }
task(){ dec pre-task.sh "$(jq -nc --arg a "$1" '{tool_name:"Task",tool_input:{subagent_type:$a}}')"; }
cmd(){ dec pre-bash.sh "$(jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}')"; }
wr(){ dec pre-file.sh "$(jq -nc --arg p "$1" --arg c "$2" '{tool_name:"Write",tool_input:{file_path:$p,content:$c}}')"; }
rd(){ dec pre-file.sh "$(jq -nc --arg p "$1" '{tool_name:"Read",tool_input:{file_path:$p}}')"; }
yn(){ [ -e "$1" ] && echo si || echo no; }

t(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf "  ${G}✓${N} %-54s %s\n" "$1" "$2"
     else FAIL=$((FAIL+1)); printf "  ${B}✗${N} %-54s %s (esperaba %s)\n" "$1" "$2" "$3"; fi; }
sec(){ printf "\n${W}%s${N}\n" "$1"; }

# ---------------------------------------------------------------- repo de prueba
mkdir -p "$R/src" "$R/test" "$R/.claude"
git -C "$R" init -q .
git -C "$R" config --local user.name "Dev Prueba"
git -C "$R" config --local user.email "dev@example.com"
cat >| "$R/package.json" <<'EOF'
{ "name": "sdd-e2e-fixture", "version": "1.0.0", "scripts": { "test": "node --test" } }
EOF
cat >| "$R/test/order.test.js" <<'EOF'
const { test } = require('node:test');
const assert = require('node:assert');
test('crea un pedido', () => { assert.strictEqual(1 + 1, 2); });
test('rechaza cantidad negativa', () => { assert.ok(true); });
EOF
cat >| "$R/.gitignore" <<'EOF'
node_modules/
docs/sdd/.current
docs/sdd/.hook-errors.log
docs/sdd/**/tdd-evidence.log
docs/sdd/**/.tdd-pending
EOF
printf 'SDD_BASE_BRANCH=develop\n' > "$R/.claude/sdd-hooks.env"
printf 'SECRET=x\n' > "$R/.env"
git -C "$R" add -A >/dev/null && git -C "$R" commit -qm "chore: initial commit"

SDD="$R/docs/sdd"; F="$SDD/0001-alta-pedido"

# ---------------------------------------------------------------------- fases
sec "Resolución de la raíz de artefactos"
root(){ env -u SDD_ARTIFACTS_DIR -u SDD_ARTIFACT_STORE CLAUDE_PROJECT_DIR=/proj "$@" \
        bash -c ". $HOOKS/common.sh; printf '%s' \"\$ARTIFACTS_ROOT\""; }
t "default (store repo)"                   "$(root)"                                 /proj/docs/sdd
t "store local"                            "$(root SDD_ARTIFACT_STORE=local)"        /proj/.claude/sdd
t "ruta relativa custom"                   "$(root SDD_ARTIFACTS_DIR=.sdd)"          /proj/.sdd
t "ruta absoluta"                          "$(root SDD_ARTIFACTS_DIR=/tmp/sdd)"      /tmp/sdd
t "barra final normalizada"                "$(root SDD_ARTIFACTS_DIR=docs/sdd/)"     /proj/docs/sdd
t "proyecto gana sobre userConfig"         "$(root SDD_ARTIFACTS_DIR=gana CLAUDE_PLUGIN_OPTION_ARTIFACTS_DIR=pierde)" /proj/gana

# --------------------------------------- raíz del proyecto por ancla (multi-repo)
# La sesión abierta en una carpeta que contiene varios repositorios: CLAUDE_PROJECT_DIR
# apunta a la contenedora, que no es un repositorio y no tiene la configuración. El
# hook tiene que anclarse en lo que la herramienta está tocando, no en la raíz de la sesión.
sec "Raíz del proyecto · ancla dentro del repositorio"
C="$(mktemp -d "${TMPDIR:-/tmp}/sdd-e2e-multi.XXXXXX")"
trap 'rm -rf "$R" "$C"' EXIT
mkdir -p "$C/repo-a/src" "$C/repo-a/.claude" "$C/repo-a/docs/sdd" "$C/repo-b/src" "$C/suelto"
printf 'SDD_PROD_MARKERS=marcador-del-equipo\nSDD_BASE_BRANCH=trunk\n' > "$C/repo-a/.claude/sdd-hooks.env"
printf '0007-alta\n' > "$C/repo-a/docs/sdd/.current"
for r in repo-a repo-b; do
  git -C "$C/$r" init -q .
  git -C "$C/$r" config --local user.name "Dev Prueba"
  git -C "$C/$r" config --local user.email "dev@example.com"
  printf 'x\n' > "$C/$r/src/x.ts"
  git -C "$C/$r" add -A >/dev/null && git -C "$C/$r" commit -qm "chore: initial commit"
done
git -C "$C/repo-a" worktree add -q "$C/wt-a" -b wt >/dev/null 2>&1

res(){ printf '%s' "$1" | env -u SDD_ARTIFACTS_DIR -u SDD_ARTIFACT_STORE -u SDD_BASE_BRANCH \
       CLAUDE_PROJECT_DIR="$2" bash -c ". $HOOKS/common.sh; read_input; printf '%s' \"\${${3:-PROJECT_DIR}}\""; }
pw(){ jq -nc --arg p "$1" '{tool_name:"Write",tool_input:{file_path:$p}}'; }
pc(){ jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }
pd(){ jq -nc --arg d "$1" '{tool_name:"Task",cwd:$d,tool_input:{subagent_type:"implementer"}}'; }

t "ancla file_path resuelve el repositorio" "$(res "$(pw "$C/repo-a/src/x.ts")" "$C")"                    "$C/repo-a"
t "carga los marcadores de ese repo"        "$(res "$(pw "$C/repo-a/src/x.ts")" "$C" PROD_MARKERS)"       marcador-del-equipo
t "y su rama base"                          "$(res "$(pw "$C/repo-a/src/x.ts")" "$C" BASE_BRANCH)"        trunk
t "artefactos dentro del repo"              "$(res "$(pw "$C/repo-a/src/x.ts")" "$C" ARTIFACTS_ROOT)"     "$C/repo-a/docs/sdd"
t "ancla de comando (ruta absoluta)"        "$(res "$(pc "cd $C/repo-a && pnpm test")" "$C")"             "$C/repo-a"
t "ancla cwd del payload"                   "$(res "$(pd "$C/repo-a")" "$C")"                             "$C/repo-a"
t "worktree resuelve a su propia raíz"      "$(res "$(pw "$C/wt-a/src/x.ts")" "$C")"                      "$C/wt-a"
t "repo sin config no hereda la del otro"   "$(res "$(pw "$C/repo-b/src/x.ts")" "$C/repo-a" BASE_BRANCH)" develop
t "sesión en la raíz del repo no cambia"    "$(res "$(pw "$C/repo-a/src/x.ts")" "$C/repo-a")"             "$C/repo-a"
t "fuera de todo repo, cae a hoy"           "$(res "$(pw "$C/suelto/x.txt")" "$C")"                       "$C"
t "ruta de comando fuera del árbol se ignora" "$(res "$(pc "ls $C/repo-a/src && pnpm test")" "$R")"          "$R"
t "el archivo sí manda fuera del árbol"       "$(res "$(pw "$C/repo-a/src/x.ts")" "$R")"                     "$C/repo-a"
t "el entorno sobrevive a la re-resolución" "$(printf '%s' "$(pw "$C/repo-a/src/x.ts")" | env SDD_ARTIFACTS_DIR=.sdd CLAUDE_PROJECT_DIR="$C" bash -c ". $HOOKS/common.sh; read_input; printf '%s' \"\$ARTIFACTS_ROOT\"")" "$C/repo-a/.sdd"

# La evidencia tiene que caer en el repo tocado, y la contenedora quedar intacta.
printf '%s' "$(jq -nc --arg c "cd $C/repo-a && pnpm test" --arg o "10 passed" \
  '{tool_name:"Bash",tool_input:{command:$c},tool_response:{stdout:$o,exit_code:0}}')" \
  | env CLAUDE_PROJECT_DIR="$C" bash "$HOOKS/post-bash.sh" >/dev/null 2>&1
t "evidencia en el repo, no en la contenedora" "$(yn "$C/repo-a/docs/sdd/0007-alta/tdd-evidence.log")"    si
t "ningún _unassigned fuera del repo"          "$(yn "$C/docs")"                                          no
# UserPromptSubmit no trae comando ni archivo: ancla en el cwd del payload.
printf '%s\t%s\n' '2026-01-01T00:00:00Z' 'pnpm vitest run src/order.spec.ts' > "$C/repo-a/docs/sdd/0007-alta/.tdd-pending"
printf '%s' "$(jq -nc --arg d "$C/repo-a" '{hook_event_name:"UserPromptSubmit",cwd:$d,prompt:"seguimos"}')" \
  | env CLAUDE_PROJECT_DIR="$C" bash "$HOOKS/user-prompt.sh" >/dev/null 2>&1
t "user-prompt concilia dentro del repo"       "$(grep -c 'exit=!0' "$C/repo-a/docs/sdd/0007-alta/tdd-evidence.log")" 1
# La consecuencia de no cargar la config: el guardrail de producción queda inerte.
decc(){ local o; o="$(printf '%s' "$2" | env CLAUDE_PROJECT_DIR="$3" bash "$HOOKS/$1" 2>/dev/null)"
  if [ -z "$o" ]; then echo allow
  else printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecision // .decision // "allow"'; fi; }
DEPLOY="cd $C/repo-a && aws lambda update-function-code --function-name marcador-del-equipo"
t "marcador del repo frena el deploy"          "$(decc pre-bash.sh "$(pc "$DEPLOY")" "$C")"                ask
t "sin marcador, el mismo comando pasa"        "$(decc pre-bash.sh "$(pc "cd $C/repo-b && aws lambda update-function-code --function-name x")" "$C")" allow


sec "Gatekeeper · sin feature activa no interviene"
t "explorer sin .current"                  "$(task explorer)"          allow
t "implementer sin .current"               "$(task implementer)"       allow
t "subagente ajeno al pipeline"            "$(task Explore)"           allow

sec "Gatekeeper · cadena de insumos (nivel full)"
mkdir -p "$F"; printf '0001-alta-pedido\n' > "$SDD/.current"; printf 'full\n' > "$F/.level"
t "proposer sin explore"                   "$(task proposer)"          deny
printf 'RESUMEN\n' > "$F/00-explore.md"
t "proposer con explore"                   "$(task proposer)"          allow
t "spec-writer sin proposal"               "$(task spec-writer)"       deny
printf 'RESUMEN\n' > "$F/01-proposal.md"
t "spec-writer con explore+proposal"       "$(task spec-writer)"       allow
t "designer sin spec"                      "$(task designer)"          deny
printf 'RESUMEN\nAC-1\n' > "$F/02-spec.md"
t "designer con spec"                      "$(task designer)"          allow
t "task-planner sin design"                "$(task task-planner)"      deny
printf 'RESUMEN\n' > "$F/03-design.md"
t "task-planner con design"                "$(task task-planner)"      allow
t "nombre namespaced se reconoce"          "$(task sdd-tdd-core:implementer)" deny

sec "Gatekeeper · GATE 1 condiciona la implementación"
printf 'RESUMEN\nT-1\n' > "$F/04-plan.md"
t "sin gates.md"                           "$(task implementer)"       deny
printf 'GATE 1 — RECHAZADO\n'              > "$F/gates.md"; t "GATE 1 rechazado"        "$(task implementer)" deny
printf 'GATE 1 — CAMBIOS. No aprobado.\n'  > "$F/gates.md"; t "GATE 1 con negación"     "$(task implementer)" deny
printf 'GATE 2 — APROBADO\n'               > "$F/gates.md"; t "solo GATE 2 aprobado"    "$(task implementer)" deny
printf 'GATE 1 — CAMBIOS\nGATE 1 — APROBADO (acepto)\n' > "$F/gates.md"
t "GATE 1 aprobado tras una ronda"         "$(task implementer)"       allow

sec "Gatekeeper · nivel bugfix acorta el recorrido"
BF="$SDD/0002-fix"; mkdir -p "$BF"; printf '0002-fix\n' > "$SDD/.current"; printf 'bugfix\n' > "$BF/.level"
printf 'RESUMEN\n' > "$BF/00-explore.md"
t "implementer solo con explore"           "$(task implementer)"       allow
t "spec-writer no pertenece al recorrido"  "$(task spec-writer)"       deny
t "designer no pertenece al recorrido"     "$(task designer)"          deny
printf '0001-alta-pedido\n' > "$SDD/.current"

sec "Guardrails de escritura"
t "secreto en código"                      "$(wr "$R/src/cfg.ts" 'const k = "sk-abcdefghijklmnopqrstuvwx";')" deny
t "email real en artefacto"                "$(wr "$F/02-spec.md" 'contacto: juan.perez@empresa-real.com')"    deny
t "email sintético en artefacto"           "$(wr "$F/02-spec.md" 'contacto: user@example.com')"               allow
t "código limpio"                          "$(wr "$R/src/order.ts" 'export const create = () => 1;')"         allow
t "lectura de .env"                        "$(rd "$R/.env")"                                                  deny

sec "Guardrails de shell y git"
t "commit con atribución de IA"            "$(cmd 'git commit -m "x" -m "Co-Authored-By: a <b@c.d>"')"  deny
t "commit limpio"                          "$(cmd 'git commit -m "feat(orders): add creation"')"        allow
t "push --force"                           "$(cmd 'git push --force origin main')"                      deny
t "push --no-verify"                       "$(cmd 'git push --no-verify origin x')"                     deny
t "push a la rama base"                    "$(cmd 'git push origin develop')"                           ask
t "push a rama de feature"                 "$(cmd 'git push origin feat/alta-pedido')"                   allow
t "salida de tests filtrada por pipe"      "$(cmd 'npm test | tail -5')"                                deny
t "comando inocuo"                         "$(cmd 'ls -la')"                                            allow

sec "Evidencia TDD"
if command -v node >/dev/null && command -v npm >/dev/null; then
  OUT="$(cd "$R" && npm test 2>&1)"; CODE=$?; SRC="corrida real"
else
  OUT="# tests 2"$'\n'"# pass 2"$'\n'"# fail 0"; CODE=0; SRC="payload equivalente (sin node)"
fi
hook post-bash.sh "$(jq -nc --arg c "npm test" --arg o "$OUT" --argjson e "$CODE" \
  '{tool_name:"Bash",tool_input:{command:$c},tool_response:{stdout:$o,exit_code:$e}}')" >/dev/null
t "log escrito en la carpeta activa ($SRC)" "$(yn "$F/tdd-evidence.log")"                 si
t "registra exit=0"                         "$(grep -c 'exit=0' "$F/tdd-evidence.log")"   1
# El payload real de PostToolUse no trae exit_code (solo stdout/stderr/interrupted):
# el código se infiere de la salida. Se ejercita esa forma, no solo la enriquecida.
: > "$F/tdd-evidence.log"
hook post-bash.sh "$(jq -nc --arg c "npm test" --arg o "1 failed" \
  '{tool_name:"Bash",tool_input:{command:$c},tool_response:{stdout:$o,stderr:"",interrupted:false}}')" >/dev/null
t "sin exit_code, infiere el fallo"         "$(grep -c 'exit=1' "$F/tdd-evidence.log")"   1
# Se restituye la corrida verde: el gatekeeper del verifier exige evidencia real.
: > "$F/tdd-evidence.log"
hook post-bash.sh "$(jq -nc --arg c "npm test" --arg o "$OUT" --argjson e "$CODE" \
  '{tool_name:"Bash",tool_input:{command:$c},tool_response:{stdout:$o,exit_code:$e}}')" >/dev/null
t "verifier sin apply-progress"             "$(task verifier)"                            deny
printf 'RESUMEN\n' > "$F/05-apply-progress.md"
t "verifier con evidencia y progreso"       "$(task verifier)"                            allow
t "code-reviewer con los artefactos"        "$(task code-reviewer)"                       allow

sec "Corrida sin ningún evento · conciliación de la marca"
# post-bash limpia la marca de su llamada (tool_use_id) con PostToolUse o con
# PostToolUseFailure. La marca solo se concilia como exit=!0 cuando no llegó ningún
# evento: pre-bash concilia las vencidas —una llamada en paralelo puede seguir
# corriendo— y user-prompt, con el turno terminado, todas.
pending_count(){ find "$F/.tdd-pending" -type f 2>/dev/null | wc -l | tr -d ' '; }
pre(){ dec pre-bash.sh "$(jq -nc --arg c "$1" --arg id "$2" '{tool_name:"Bash",tool_input:{command:$c},tool_use_id:$id}')"; }
prompt(){ hook user-prompt.sh '{"hook_event_name":"UserPromptSubmit","prompt":"seguimos"}' >/dev/null; }
: > "$F/tdd-evidence.log"; rm -rf "$F/.tdd-pending"
pre 'pnpm vitest run src/order.spec.ts' toolu_a >/dev/null
t "pre-bash marca la corrida"              "$(pending_count)"                                       1
t "todavía no hay línea en el log"         "$(grep -c . "$F/tdd-evidence.log")"                     0
pre 'pnpm vitest run src/other.spec.ts' toolu_b >/dev/null
t "una llamada en paralelo no la concilia" "$(grep -c 'exit=!0' "$F/tdd-evidence.log")"             0
t "cada llamada tiene su marca"            "$(pending_count)"                                       2
touch -t 202601010000 "$F/.tdd-pending/toolu_a"
cmd 'ls -la' >/dev/null
t "pre-bash concilia la marca vencida"     "$(grep -c 'exit=!0' "$F/tdd-evidence.log")"             1
t "conserva el comando conciliado"         "$(grep -c 'order.spec.ts' "$F/tdd-evidence.log")"       1
t "la reciente sigue pendiente"            "$(pending_count)"                                       1
prompt
t "user-prompt concilia el resto"          "$(grep -c 'exit=!0' "$F/tdd-evidence.log")"             2
t "la marca se consume"                    "$(yn "$F/.tdd-pending")"                                no
prompt
t "no se duplica en el turno siguiente"    "$(grep -c 'exit=!0' "$F/tdd-evidence.log")"             2

: > "$F/tdd-evidence.log"; rm -rf "$F/.tdd-pending"
pre 'pnpm vitest run src/order.spec.ts' toolu_ok >/dev/null
hook post-bash.sh "$(jq -nc --arg c 'pnpm vitest run src/order.spec.ts' \
  '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:$c},tool_use_id:"toolu_ok",tool_response:{stdout:"Tests  3 passed (3)",stderr:""}}')" >/dev/null
t "con resultado real, la marca se limpia" "$(yn "$F/.tdd-pending")"                                no
t "y no queda corrida sin resultado"       "$(grep -c 'exit=!0' "$F/tdd-evidence.log")"             0
t "queda la línea con el resultado"        "$(grep -c 'exit=0' "$F/tdd-evidence.log")"              1

# Una marca de 1.4.x es un archivo sin tool_use_id: se concilia en vez de romper la nueva.
: > "$F/tdd-evidence.log"; rm -rf "$F/.tdd-pending"
printf '%s\t%s\n' '2026-01-01T00:00:00Z' 'pnpm vitest run src/legacy.spec.ts' >| "$F/.tdd-pending"
pre 'pnpm vitest run src/order.spec.ts' toolu_new >/dev/null
t "marca heredada de 1.4.x se concilia"    "$(grep -c 'legacy.spec.ts' "$F/tdd-evidence.log")"      1
t "y la nueva queda en su lugar"           "$(pending_count)"                                       1
rm -rf "$F/.tdd-pending"

: > "$F/tdd-evidence.log"
cmd 'git push origin develop' >/dev/null
t "un ask no marca corrida"                "$(yn "$F/.tdd-pending")"                                no

sec "Un payload ilegible deja diagnóstico, no silencio"
rm -f "$SDD/.hook-errors.log"
hook post-bash.sh 'esto no es json' >/dev/null
t "registra el payload ilegible"           "$(grep -c 'ilegible' "$SDD/.hook-errors.log")"          1
t "no inventa evidencia"                   "$(grep -c . "$F/tdd-evidence.log")"                     0
rm -f "$SDD/.hook-errors.log"

sec "Alcance del test · dirigido vs suite completa"
# shellcheck source=/dev/null
. "$HOOKS/common.sh"
tgt(){ if is_targeted_run "$1"; then echo dirigido; else echo suite; fi; }
t "pnpm test"                              "$(tgt 'pnpm test')"                                    suite
t "turbo run test --force"                 "$(tgt 'pnpm exec turbo run test --force')"             suite
t "--filter de paquete no es filtro de caso" "$(tgt 'pnpm --filter @app/api exec vitest run')"      suite
t "archivo .spec.ts nombrado"              "$(tgt 'vitest run src/x.spec.ts')"                     dirigido
t "filtro -t de caso"                      "$(tgt 'vitest run x.spec.ts -t \"crea\"')"             dirigido
t "pytest con archivo"                     "$(tgt 'pytest tests/test_orders.py')"                  dirigido
t "go test ./..."                          "$(tgt 'go test ./...')"                                suite

sec "Detección de la corrida · comandos agregados de gate"
det(){ if is_test_run "$1"; then echo test; else echo no; fi; }
t "pnpm check"                             "$(det 'pnpm check')"                    test
t "pnpm run check"                         "$(det 'pnpm run check')"                test
t "pnpm verify"                            "$(det 'pnpm verify')"                   test
t "pnpm validate"                          "$(det 'pnpm validate')"                 test
t "pnpm run ci"                            "$(det 'pnpm run ci')"                   test
t "npm ci instala, no corre tests"         "$(det 'npm ci')"                        no
t "pnpm checkout no es un gate"            "$(det 'pnpm exec checkly deploy')"      no
t "echo pnpm check no es evidencia"        "$(det 'echo "pnpm check"')"             no
# El cuerpo de un heredoc es dato, no comando: prosa que menciona un runner no es una corrida.
HD="$(printf 'cat >| doc.md <<%sEOF%s\nal correr vitest el ciclo queda en rojo\nEOF\n' "'" "'")"
HP="$(printf 'python3 - <<%sPY%s\nel ciclo corre vitest sobre el caso nuevo\nPY\n' "'" "'")"
t "prosa dentro de un heredoc no es evidencia" "$(det "$HP")"                    no
t "heredoc con verbo no filtrado tampoco"      "$(det "$HD")"                    no
t "comando real después del heredoc sí"        "$(det "$HD"$'\npnpm test')"      test

sec "WARN de suite completa a mitad de ciclo"
ev(){ hook post-bash.sh "$(jq -nc --arg c "$1" --arg o "$2" --argjson e "$3" \
       '{tool_name:"Bash",tool_input:{command:$c},tool_response:{stdout:$o,exit_code:$e}}')" >/dev/null; }
lastwarn(){ tail -n 1 "$F/tdd-evidence.log" | grep -oE 'full-suite-mid-cycle' || echo "-"; }
: > "$F/tdd-evidence.log"
ev 'vitest run x.spec.ts -t "caso"' '1 failed' 1
t "RED dirigido no marca"                  "$(lastwarn)"  -
ev 'pnpm test' '10 passed' 0
t "suite tras un RED abierto marca"        "$(lastwarn)"  full-suite-mid-cycle
: > "$F/tdd-evidence.log"
ev 'vitest run x.spec.ts -t "caso"' '1 passed' 0
ev 'pnpm test' '10 passed' 0
t "suite tras GREEN (cierre) no marca"     "$(lastwarn)"  -
: > "$F/tdd-evidence.log"
ev 'pnpm test' '2 failed' 1
ev 'pnpm test' '10 passed' 0
t "suite tras suite no marca"              "$(lastwarn)"  -

sec "PostToolUseFailure · la llamada fallida llega con su salida"
# PostToolUse solo llega cuando la llamada Bash termina en 0. Cuando falla llega
# PostToolUseFailure, sin tool_response: el código y la salida (stdout y stderr
# mezclados) vienen en .error como "Exit code <n>\n<salida>", recortada a unos
# 10 000 caracteres desde el principio. Forma capturada del harness real (2.1.272).
t "hooks.json registra PostToolUseFailure/Bash" \
  "$(jq -r '.hooks.PostToolUseFailure[]? | select(.matcher=="Bash") | .hooks[].command' "$HOOKS/hooks.json" | grep -c 'post-bash.sh')" 1
fail_ev(){ hook post-bash.sh "$(jq -nc --arg c "$1" --arg o "$2" --arg id "$3" \
  '{hook_event_name:"PostToolUseFailure",tool_name:"Bash",tool_input:{command:$c},tool_use_id:$id,error:$o,is_interrupt:false}')" >/dev/null; }
last(){ tail -n 1 "$F/tdd-evidence.log"; }
# Lo que el verifier cuenta como RED: exit distinto de 0 sin una marca que invalide la línea.
reds(){ grep -E '\| exit=([1-9]|!0)' "$F/tdd-evidence.log" | grep -vcE 'WARN=.*(no-tests-ran|piped-output|output-truncated|interrupted)'; }
HAS_NODE=0; command -v node >/dev/null && command -v npm >/dev/null && HAS_NODE=1

mkdir -p "$R/red"
cat >| "$R/red/order.red.test.js" <<'EOF'
const { test } = require('node:test');
const assert = require('node:assert');
test('rechaza un pedido vacío', () => { assert.strictEqual(undefined, 'ORDER_EMPTY'); });
EOF
RED_CMD='npm test -- red/order.red.test.js'
if [ "$HAS_NODE" = 1 ]; then
  RED_OUT="$(cd "$R" && npm test -- red/order.red.test.js 2>&1)"; RED_CODE=$?; RSRC="corrida real"
else
  RED_OUT="not ok 1 - rechaza un pedido vacío"$'\n'"# tests 1"$'\n'"# pass 0"$'\n'"# fail 1"; RED_CODE=1; RSRC="payload equivalente"
fi
rm -rf "$R/red"
: > "$F/tdd-evidence.log"; rm -rf "$F/.tdd-pending"
pre "$RED_CMD" toolu_red >/dev/null
fail_ev "$RED_CMD" "Exit code $RED_CODE"$'\n'"$RED_OUT" toolu_red
t "RED real deja exit=1 ($RSRC)"           "$(last | grep -oE '\| exit=[^ ]+')"                     "| exit=1"
t "con el resumen del runner"              "$(last | grep -c 'fail 1')"                             1
t "sin marca de sospecha"                  "$(last | grep -c 'WARN=')"                              0
t "cuenta como RED"                        "$(reds)"                                                1
t "la marca de esa llamada se limpia"      "$(pending_count)"                                       0
prompt
t "y no se concilia otra vez como exit=!0" "$(grep -c 'exit=!0' "$F/tdd-evidence.log")"             0

# El caso real: tests verdes encadenados con una escritura que choca con noclobber.
printf 'previo\n' >| "$R/artefacto.md"
NC_CMD="npm test && cat > artefacto.md <<'EOF'"$'\n'"# notas"$'\n'"EOF"
if [ "$HAS_NODE" = 1 ]; then
  NC_OUT="$(cd "$R" && bash -c "set -o noclobber; $NC_CMD" 2>&1)"; NC_CODE=$?
else
  NC_OUT="ok 1 - crea un pedido"$'\n'"# tests 2"$'\n'"# pass 2"$'\n'"# fail 0"$'\n'"bash: artefacto.md: cannot overwrite existing file"; NC_CODE=1
fi
t "tests verdes && cat > existente sale 1" "$NC_CODE"                                               1
: > "$F/tdd-evidence.log"
pre "$NC_CMD" toolu_nc >/dev/null
fail_ev "$NC_CMD" "Exit code $NC_CODE"$'\n'"$NC_OUT" toolu_nc
t "la escritura fallida no es un test rojo" "$(reds)"                                               0
t "queda como GREEN con la llamada marcada" "$(last | grep -c '| exit=0 |.*WARN=call-failed-outside-tests')" 1
t "sin corrida pendiente"                  "$(pending_count)"                                       0
prompt
t "ni conciliada después como exit=!0"     "$(grep -c 'exit=!0' "$F/tdd-evidence.log")"             0

: > "$F/tdd-evidence.log"
W_CMD="cat > artefacto.md <<'EOF'"$'\n'"# notas"$'\n'"EOF"$'\n'"npm test"
fail_ev "$W_CMD" "Exit code 1"$'\n'"bash: line 1: artefacto.md: cannot overwrite existing file" toolu_w
t "escritura fallida antes de los tests: no es RED" "$(reds)"                                       0
t "marca no-tests-ran"                     "$(last | grep -c 'WARN=no-tests-ran')"                  1

: > "$F/tdd-evidence.log"
LONG="$(for i in $(seq 1 400); do printf 'ok %d - caso %d de relleno para superar el recorte\n' "$i" "$i"; done)"
fail_ev 'pnpm test' "Exit code 1"$'\n'"${LONG:0:10000}" toolu_long
t "salida recortada: conserva el exit real" "$(last | grep -oE '\| exit=[^ ]+')"                    "| exit=1"
t "marca output-truncated"                 "$(last | grep -c 'WARN=output-truncated')"              1
t "y no cuenta como RED ni como GREEN"     "$(reds)"                                                0

# Forma no capturada del harness real: interrupción sin "Exit code".
: > "$F/tdd-evidence.log"
hook post-bash.sh "$(jq -nc '{hook_event_name:"PostToolUseFailure",tool_name:"Bash",tool_input:{command:"pnpm test"},tool_use_id:"toolu_int",error:"Interrupted by user",is_interrupt:true}')" >/dev/null
t "interrupción: exit=!0 con marca"        "$(last | grep -c '| exit=!0 |.*WARN=.*interrupted')"    1
t "y no cuenta como RED"                   "$(reds)"                                                0

sec "Sin tests ejecutados · no-tests-ran"
: > "$F/tdd-evidence.log"
hook post-bash.sh "$(jq -nc --arg c 'pnpm vitest run src/order.spec.ts -t "no existe"' \
  '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:$c},tool_use_id:"toolu_nt",tool_response:{stdout:"No test files found, exiting with code 0",stderr:"",interrupted:false}}')" >/dev/null
t "exit=0 sin tests sigue marcando no-tests-ran" "$(last | grep -c '| exit=0 |.*WARN=no-tests-ran')" 1

sec "Escritura por heredoc con noclobber"
printf 'previo\n' >| "$R/artefacto.md"
t "bash: cat > sobre existente falla"      "$(cd "$R" && bash -c "set -o noclobber; cat > artefacto.md <<'EOF'"$'\n'"nuevo"$'\n'"EOF" 2>/dev/null; echo $?)" 1
t "bash: cat >| sobre existente funciona"  "$(cd "$R" && bash -c "set -o noclobber; cat >| artefacto.md <<'EOF'"$'\n'"nuevo"$'\n'"EOF" && cat artefacto.md)" nuevo
if command -v zsh >/dev/null; then
  t "zsh: cat > sobre existente falla"     "$(cd "$R" && zsh -fc "setopt noclobber; cat > artefacto.md <<'EOF'"$'\n'"zsh"$'\n'"EOF" 2>/dev/null; echo $?)" 1
  t "zsh: cat >| sobre existente funciona" "$(cd "$R" && zsh -fc "setopt noclobber; cat >| artefacto.md <<'EOF'"$'\n'"zsh"$'\n'"EOF" && cat artefacto.md)" zsh
fi
rm -f "$R/artefacto.md"

sec "Verificación post-commit · solo sobre un commit que ocurrió"
IA="$C/repo-ia"; mkdir -p "$IA"
git -C "$IA" init -q .
git -C "$IA" config --local user.name "Dev Prueba"
git -C "$IA" config --local user.email "dev@example.com"
printf 'x\n' >| "$IA/x"; git -C "$IA" add -A >/dev/null
git -C "$IA" commit -qm "feat(x): add x" -m "Co-Authored-By: bot <bot@example.com>"
commit_dec(){ local o
  o="$(jq -nc --arg e "$1" '{hook_event_name:$e,tool_name:"Bash",tool_input:{command:"git commit -m \"feat(x): change\""},tool_use_id:"toolu_c"}
       + (if $e == "PostToolUse" then {tool_response:{stdout:"",stderr:""}} else {error:"Exit code 1\nnothing to commit, working tree clean",is_interrupt:false} end)' \
       | env CLAUDE_PROJECT_DIR="$IA" bash "$HOOKS/post-bash.sh" 2>/dev/null)"
  if [ -z "$o" ]; then echo none; else printf '%s' "$o" | jq -r '.decision // "none"'; fi; }
t "commit que ocurrió con trailer de IA"   "$(commit_dec PostToolUse)"                              block
t "commit fallido no juzga el anterior"    "$(commit_dec PostToolUseFailure)"                       none

sec "Rotación del apply-progress"
mkprog(){ : > "$F/05-apply-progress.md"; for i in $(seq 1 "$1"); do printf '## T-%d — x\n d\n' "$i" >> "$F/05-apply-progress.md"; done; }
KEEP="$(env CLAUDE_PROJECT_DIR="$R" bash -c ". $HOOKS/common.sh; printf '%s' \"\$PROGRESS_KEEP_TASKS\"")"
t "umbral por defecto"                     "$KEEP"                    10
mkprog 10; t "en el umbral, implementer pasa"  "$(task implementer)"  allow
mkprog 11; t "pasado el umbral, deniega"       "$(task implementer)"  deny
mkprog 3;  t "tras rotar, vuelve a pasar"      "$(task implementer)"  allow

sec "Cierre · reconciliación de capacidad y archivado"
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -qm "feat(orders): artifacts" >/dev/null 2>&1
mkdir -p "$SDD/specs/pedidos" "$SDD/_archive"
printf '# Capacidad: pedidos\n<!-- 0001-alta-pedido -->\nEl sistema MUST permitir crear un pedido.\n' \
  > "$SDD/specs/pedidos/spec.md"
A="$SDD/_archive/2026-09-04-alta-pedido"
git -C "$R" mv "docs/sdd/0001-alta-pedido" "docs/sdd/_archive/2026-09-04-alta-pedido" >/dev/null 2>&1
mv "$F/tdd-evidence.log" "$A/" 2>/dev/null
rmdir "$F" 2>/dev/null; rm -f "$SDD/.current"
t "change movido a _archive"               "$(yn "$A")"                     si
t "carpeta original eliminada"             "$(yn "$F")"                     no
t "spec de capacidad presente"             "$(yn "$SDD/specs/pedidos/spec.md")" si
t "evidencia acompañó al archivo"          "$(yn "$A/tdd-evidence.log")"    si
t ".current borrado"                       "$(yn "$SDD/.current")"          no
t "gatekeeper vuelve a no intervenir"      "$(task implementer)"            allow

sec "Qué versiona git"
git -C "$R" add -A >/dev/null 2>&1
TRK="$(git -C "$R" ls-files docs/sdd)"
t "tdd-evidence.log ignorado"              "$(printf '%s' "$TRK" | grep -c 'tdd-evidence' || true)"   0
t ".tdd-pending ignorado"                  "$(printf '%s' "$TRK" | grep -c 'tdd-pending' || true)"   0
t ".hook-errors.log ignorado"              "$(printf '%s' "$TRK" | grep -c 'hook-errors' || true)"   0
t "spec de capacidad versionado"           "$(printf '%s' "$TRK" | grep -c 'specs/pedidos' || true)"  1
t "gates.md archivado versionado"          "$(printf '%s' "$TRK" | grep -c '_archive/.*gates' || true)" 1

printf "\n${W}%d pasaron · %d fallaron${N}\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
