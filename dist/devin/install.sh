#!/usr/bin/env bash
# Instala el toolkit SDD+TDD para Devin en el repositorio actual.
#   bash install.sh [ruta-al-repo] [--stack=<stack>|none]
# Sin --stack lo detecta por los archivos del repo. Playbooks y Knowledge no
# viven en el repo: se cargan a mano en la web de Devin.
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

mkdir -p "$REPO/.agents"
cp -R "$HERE/.agents/." "$REPO/.agents/"

if [ "$STACK" = none ]; then
  echo "ok      sin plugin de stack: declará los comandos del proyecto en su documento de contexto"
else
  mkdir -p "$REPO/.agents/skills" "$REPO/.agents/$STACK"
  cp -R "$HERE/stacks/$STACK/skills/." "$REPO/.agents/skills/"
  cp -R "$HERE/stacks/$STACK/." "$REPO/.agents/$STACK/"
  rm -rf "$REPO/.agents/$STACK/skills" "$REPO/.agents/$STACK/knowledge"
  echo "ok      $STACK: skills en .agents/skills/ y plantillas en .agents/$STACK/"
fi

if [ ! -f "$REPO/.agentic/sdd-hooks.env" ]; then
  mkdir -p "$REPO/.agentic"
  cp "$HERE/.agents/sdd-tdd-core/templates/sdd-hooks.env" "$REPO/.agentic/sdd-hooks.env"
  echo "creado  .agentic/sdd-hooks.env — editalo antes del primer cambio"
fi

echo "ok      .agents/ en $REPO"
if [ ! -f "$REPO/AGENTS.md" ]; then
  cp "$HERE/AGENTS.md" "$REPO/AGENTS.md"
  echo "creado  AGENTS.md — sumale lo propio del proyecto (stack, comandos, invariantes)"
elif grep -q 'Bloque generado por agentic-toolkit' "$REPO/AGENTS.md"; then
  echo "ok      AGENTS.md ya tiene el bloque del toolkit"
else
  echo "falta   pegar el contenido de $HERE/AGENTS.md en el AGENTS.md del repo"
fi
echo "falta   commitear .agents/, .agentic/ y AGENTS.md: Devin los lee del repo"
echo "falta   subir los 8 playbooks de $HERE/playbooks a Devin"
echo "opcional cargar las 3 entradas de $HERE/knowledge en el Knowledge de Devin"
[ "$STACK" = none ] || echo "opcional y las del stack, en $HERE/stacks/$STACK/knowledge"
