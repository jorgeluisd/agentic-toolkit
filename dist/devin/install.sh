#!/usr/bin/env bash
# Instala el toolkit SDD+TDD para Devin en el repositorio actual.
#   bash install.sh [ruta-al-repo]
# Playbooks y Knowledge no viven en el repo: se cargan a mano en la web de Devin.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${1:-$PWD}" && pwd)"

[ -d "$REPO/.git" ] || { echo "no parece un repositorio git: $REPO"; exit 1; }

mkdir -p "$REPO/.agents"
cp -R "$HERE/.agents/." "$REPO/.agents/"

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
echo "opcional cargar las 14 entradas de $HERE/knowledge en el Knowledge de Devin"
