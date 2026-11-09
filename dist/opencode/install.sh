#!/usr/bin/env bash
# Instala el toolkit SDD+TDD para OpenCode en el repositorio actual.
#   bash install.sh [ruta-al-repo] [--stack=<stack>|none]
# Sin --stack lo detecta por los archivos del repo.
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

[ -d "$REPO/.git" ] || { echo "no parece un repositorio git: $REPO"; exit 1; }

if [ -z "$STACK" ]; then
  found=""
  [ -f "$REPO/package.json" ] && found="$found typescript"
  [ -f "$REPO/go.mod" ] && found="$found go"
  set -- $found
  case $# in
    0) STACK=none ;;
    1) STACK="$1" ;;
    *) echo "el repo coincide con varios stacks ($found): elegí uno con --stack=<typescript|go|none>"; exit 1 ;;
  esac
fi
case "$STACK" in none|stack-*) ;; *) STACK="stack-$STACK" ;; esac
if [ "$STACK" != none ] && [ ! -d "$HERE/stacks/$STACK" ]; then
  echo "stack desconocido: $STACK (disponibles: typescript go none)"; exit 1
fi

mkdir -p "$REPO/.opencode"
cp -R "$HERE/.opencode/." "$REPO/.opencode/"

if [ "$STACK" = none ]; then
  echo "ok      sin plugin de stack: declará los comandos del proyecto en su documento de contexto"
else
  mkdir -p "$REPO/.opencode/skills" "$REPO/.opencode/$STACK"
  cp -R "$HERE/stacks/$STACK/skills/." "$REPO/.opencode/skills/"
  cp -R "$HERE/stacks/$STACK/." "$REPO/.opencode/$STACK/"
  rm -rf "$REPO/.opencode/$STACK/skills" "$REPO/.opencode/$STACK/knowledge"
  echo "ok      $STACK: skills en .opencode/skills/ y plantillas en .opencode/$STACK/"
fi

if [ ! -f "$REPO/.agentic/sdd-hooks.env" ]; then
  mkdir -p "$REPO/.agentic"
  cp "$HERE/.opencode/sdd-tdd-core/templates/sdd-hooks.env" "$REPO/.agentic/sdd-hooks.env"
  echo "creado  .agentic/sdd-hooks.env — editalo antes del primer cambio"
fi

echo "ok      .opencode/ en $REPO"
echo "falta   pegar el contenido de AGENTS.md en el AGENTS.md del repo"
echo "falta   reiniciar OpenCode para que tome agentes, comandos y el plugin"
