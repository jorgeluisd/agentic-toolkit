#!/usr/bin/env bash
# Instala el toolkit SDD+TDD para OpenCode en el repositorio actual.
#   bash install.sh [ruta-al-repo]
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${1:-$PWD}" && pwd)"

[ -d "$REPO/.git" ] || { echo "no parece un repositorio git: $REPO"; exit 1; }

mkdir -p "$REPO/.opencode"
cp -R "$HERE/.opencode/." "$REPO/.opencode/"

if [ ! -f "$REPO/.agentic/sdd-hooks.env" ]; then
  mkdir -p "$REPO/.agentic"
  cp "$HERE/.opencode/sdd-tdd-core/templates/sdd-hooks.env" "$REPO/.agentic/sdd-hooks.env"
  echo "creado  .agentic/sdd-hooks.env — editalo antes del primer cambio"
fi

echo "ok      .opencode/ en $REPO"
echo "falta   pegar el contenido de AGENTS.md en el AGENTS.md del repo"
echo "falta   reiniciar OpenCode para que tome agentes, comandos y el plugin"
