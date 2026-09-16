#!/usr/bin/env bash
# Instala el toolkit SDD+TDD para Codex CLI en el repositorio actual.
#   bash install.sh [ruta-al-repo]
# Los prompts son de usuario ($CODEX_HOME/prompts) y hay que reinstalarlos por máquina.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${1:-$PWD}" && pwd)"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"

[ -d "$REPO/.git" ] || { echo "no parece un repositorio git: $REPO"; exit 1; }

mkdir -p "$REPO/.codex" "$REPO/.agents" "$CODEX_HOME/prompts"
cp -R "$HERE/.codex/." "$REPO/.codex/"
cp -R "$HERE/.agents/." "$REPO/.agents/"
cp "$HERE/prompts/"*.md "$CODEX_HOME/prompts/"

if [ ! -f "$REPO/.agentic/sdd-hooks.env" ]; then
  mkdir -p "$REPO/.agentic"
  cp "$HERE/.codex/sdd-tdd-core/templates/sdd-hooks.env" "$REPO/.agentic/sdd-hooks.env"
  echo "creado  .agentic/sdd-hooks.env — editalo antes del primer cambio"
fi

echo "ok      .codex/ y .agents/ en $REPO"
echo "ok      prompts en $CODEX_HOME/prompts"
echo "falta   pegar el contenido de AGENTS.md en el AGENTS.md del repo"
echo "falta   reiniciar Codex para que tome los prompts y los hooks"
