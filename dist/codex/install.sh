#!/usr/bin/env bash
# Instala el toolkit SDD+TDD para Codex CLI en el repositorio actual.
#   bash install.sh [ruta-al-repo] [--stack=<stack>|none]
# Sin --stack lo detecta por los archivos del repo. Los prompts son de usuario
# ($CODEX_HOME/prompts) y hay que reinstalarlos por máquina.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ARG="$PWD"
STACK=""
for arg in "$@"; do
  case "$arg" in
    --stack=*) STACK="${arg#--stack=}" ;;
    *) REPO_ARG="$arg" ;;
  esac
done
REPO="$(cd "$REPO_ARG" && pwd)"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"

[ -d "$REPO/.git" ] || { echo "no parece un repositorio git: $REPO"; exit 1; }

if [ -z "$STACK" ]; then
  found=""
  [ -f "$REPO/package.json" ] && found="$found typescript"
  set -- $found
  case $# in
    0) STACK=none ;;
    1) STACK="$1" ;;
    *) echo "el repo coincide con varios stacks ($found): elegí uno con --stack=<typescript|none>"; exit 1 ;;
  esac
fi
case "$STACK" in none|stack-*) ;; *) STACK="stack-$STACK" ;; esac
if [ "$STACK" != none ] && [ ! -d "$HERE/stacks/$STACK" ]; then
  echo "stack desconocido: $STACK (disponibles: typescript none)"; exit 1
fi

mkdir -p "$REPO/.codex" "$REPO/.agents" "$CODEX_HOME/prompts"
cp -R "$HERE/.codex/." "$REPO/.codex/"
cp -R "$HERE/.agents/." "$REPO/.agents/"
cp "$HERE/prompts/"*.md "$CODEX_HOME/prompts/"

if [ "$STACK" = none ]; then
  echo "ok      sin plugin de stack: declará los comandos del proyecto en su documento de contexto"
else
  mkdir -p "$REPO/.agents/skills" "$REPO/.codex/$STACK"
  cp -R "$HERE/stacks/$STACK/skills/." "$REPO/.agents/skills/"
  cp -R "$HERE/stacks/$STACK/." "$REPO/.codex/$STACK/"
  rm -rf "$REPO/.codex/$STACK/skills" "$REPO/.codex/$STACK/knowledge"
  echo "ok      $STACK: skills en .agents/skills/ y plantillas en .codex/$STACK/"
fi

if [ ! -f "$REPO/.agentic/sdd-hooks.env" ]; then
  mkdir -p "$REPO/.agentic"
  cp "$HERE/.codex/sdd-tdd-core/templates/sdd-hooks.env" "$REPO/.agentic/sdd-hooks.env"
  echo "creado  .agentic/sdd-hooks.env — editalo antes del primer cambio"
fi

echo "ok      .codex/ y .agents/ en $REPO"
echo "ok      prompts en $CODEX_HOME/prompts"
echo "falta   pegar el contenido de AGENTS.md en el AGENTS.md del repo"
echo "falta   reiniciar Codex para que tome los prompts y los hooks"
