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
cat > "$R/package.json" <<'EOF'
{ "name": "sdd-e2e-fixture", "version": "1.0.0", "scripts": { "test": "node --test" } }
EOF
cat > "$R/test/order.test.js" <<'EOF'
const { test } = require('node:test');
const assert = require('node:assert');
test('crea un pedido', () => { assert.strictEqual(1 + 1, 2); });
test('rechaza cantidad negativa', () => { assert.ok(true); });
EOF
cat > "$R/.gitignore" <<'EOF'
node_modules/
docs/sdd/.current
docs/sdd/**/tdd-evidence.log
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
t "verifier sin apply-progress"             "$(task verifier)"                            deny
printf 'RESUMEN\n' > "$F/05-apply-progress.md"
t "verifier con evidencia y progreso"       "$(task verifier)"                            allow
t "code-reviewer con los artefactos"        "$(task code-reviewer)"                       allow

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
t "spec de capacidad versionado"           "$(printf '%s' "$TRK" | grep -c 'specs/pedidos' || true)"  1
t "gates.md archivado versionado"          "$(printf '%s' "$TRK" | grep -c '_archive/.*gates' || true)" 1

printf "\n${W}%d pasaron · %d fallaron${N}\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
