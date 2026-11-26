#!/usr/bin/env bash
# Plan de revisión proporcional al riesgo del diff. No es un hook: lo corre el orquestador
# desde el worktree antes de lanzar los revisores, y gate2-auto.sh recalcula el mismo
# riesgo para exigir lo que corresponde. El gasto sigue al riesgo, no a la costumbre.
#
#   bash <plugin>/hooks/review-plan.sh
#
# Imprime `RIESGO: bajo|medio|alto` y el plan. Sale 0 siempre que pudo calcular el diff.
. "$(dirname "$0")/common.sh"

files="$(branch_diff_files)" || { echo "No pude calcular el diff contra $BASE_BRANCH."; exit 2; }
tier="$(printf '%s\n' "$files" | risk_tier)"

echo "RIESGO: $tier"
case "$tier" in
  bajo)
    echo "- code-reviewer con modelo económico (sonnet); el diff solo trae tests, documentación o artefactos."
    echo "- security-reviewer no corre." ;;
  medio)
    echo "- code-reviewer con su modelo por defecto."
    echo "- security-reviewer solo si '## Diseño' de feature.md tiene amenazas con activo real (datos, entradas externas)." ;;
  alto)
    echo "- review doble a ciegas: dos code-reviewer en paralelo, sin ver el resultado del otro; escriben 07-review.md y 07-review-2.md."
    echo "- security-reviewer obligatorio (07-security.md)."
    echo "- Un hallazgo alto vuelve al implementer; se re-juzga como máximo dos rondas. A la tercera, decide el humano."
    echo "- Rutas que lo suben a alto:"
    printf '%s\n' "$files" | while IFS= read -r f; do
      [ -n "$f" ] || continue
      if { [ -n "$HIGH_RISK_PATHS" ] && printf '%s' "$f" | grep -Eq "$HIGH_RISK_PATHS"; } \
         || { [ -n "$HUMAN_PATHS" ] && printf '%s' "$f" | grep -Eq "$HUMAN_PATHS"; }; then
        echo "    $f"
      fi
    done ;;
esac
exit 0
