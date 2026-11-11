#!/usr/bin/env bash
# GATE 2 automático (SDD_AUTONOMY=auto). No es un hook: lo corre el orquestador desde
# la raíz del worktree cuando el verifier, el code-reviewer y el security-reviewer
# terminaron. Comprueba contra los artefactos y el diff lo que una máquina puede
# comprobar; si todo pasa, registra en gates.md un GATE 2 APROBADO atado al HEAD
# exacto, que es lo que pre-bash exige para dejar pasar `gh pr merge`.
#
#   bash <plugin>/hooks/gate2-auto.sh
#
# Sale 0 y registra si el gate es automático. Sale 1 con la lista de motivos si el
# GATE 2 lo tiene que decidir un humano. Sale 2 si no aplica (modo strict, sin
# feature activa, en la rama base).
. "$(dirname "$0")/common.sh"

if [ "$AUTONOMY" != auto ]; then
  echo "GATE 2 automático desactivado (SDD_AUTONOMY=$AUTONOMY): el GATE 2 es humano."; exit 2
fi
feature="$(active_feature)" || { echo "No hay feature activa en este worktree."; exit 2; }
if on_base_branch; then
  echo "Estás en la rama base ($WORKTREE_BRANCH): un merge o release desde la base nunca es automático."; exit 2
fi

dir="$ARTIFACTS_ROOT/$feature"
wt="${WORKTREE_DIR:-$PROJECT_DIR}"
head="$(git -C "$wt" rev-parse HEAD 2>/dev/null)"
level=full
[ -f "$dir/.level" ] && level="$(tr -d '[:space:]' < "$dir/.level")"
reasons=""
why() { reasons="${reasons}- $1
"; }

# 1) verifier: PASS sobre este mismo sha.
v="$dir/06-verify.md"
if [ ! -f "$v" ]; then why "falta 06-verify.md"
else
  grep -Eq '^RESUMEN:[[:space:]]*PASS' "$v" || why "06-verify.md no está en PASS"
  vsha="$(sed -nE 's/^sha verificado:[[:space:]]*([0-9a-f]{7,40}).*/\1/p' "$v" | head -1)"
  case "$head" in "$vsha"*) [ -n "$vsha" ] || why "06-verify.md no declara el sha verificado" ;;
    *) why "el sha verificado (${vsha:-ninguno}) no es el HEAD actual (${head:0:12}): hay commits sin verificar" ;; esac
fi

# 2) code-reviewer: veredicto APROBADO (sin hallazgos altos).
r="$dir/07-review.md"
if [ ! -f "$r" ]; then why "falta 07-review.md"
else grep -Eiq 'veredicto:[[:space:]]*APROBADO' "$r" || why "07-review.md no está APROBADO"
fi

# 3) security-reviewer, si corrió: sin críticos ni altos y riesgo residual aceptable.
s="$dir/07-security.md"
if [ -f "$s" ]; then
  counts="$(sed -nE 's/^RESUMEN:.*\(([0-9]+)\/([0-9]+)\/[0-9]+\/[0-9]+\).*/\1 \2/p' "$s" | head -1)"
  if [ -z "$counts" ]; then why "07-security.md no declara el conteo (crítico/alto/medio/bajo)"
  else
    set -- $counts
    [ "$1" = 0 ] && [ "$2" = 0 ] || why "07-security.md tiene hallazgos críticos o altos ($1/$2)"
  fi
  grep -Eiq 'riesgo residual:[[:space:]]*aceptable' "$s" || why "el riesgo residual de 07-security.md no es 'aceptable': lo acepta un humano"
fi

# 4) GATE 1 aprobado (nivel full).
if [ "$level" = full ]; then
  grep -Eq '^GATE 1 .*APROBADO' "$dir/gates.md" 2>/dev/null || why "no hay GATE 1 APROBADO en gates.md"
fi

# 5) El proposer o el designer marcaron que el GATE 2 es humano (disparador del proyecto).
for a in 01-proposal.md 03-design.md 00-explore.md; do
  [ -f "$dir/$a" ] && grep -Eiq '^GATE 2:[[:space:]]*humano' "$dir/$a" && why "$a marca 'GATE 2: humano' (disparador del proyecto)"
done

# 6) El diff: ningún ADR PROPUESTO y ninguna ruta que el proyecto reserva al humano.
base="$BASE_BRANCH"
git -C "$wt" rev-parse -q --verify "origin/$BASE_BRANCH" >/dev/null && base="origin/$BASE_BRANCH"
if ! files="$(git -C "$wt" diff --name-only "$base"...HEAD 2>/dev/null)"; then
  why "no pude calcular el diff contra $base"
else
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if printf '%s' "$f" | grep -Eiq '(^|/)adrs?/' && [ -f "$wt/$f" ] && grep -Eq 'PROPUESTO' "$wt/$f"; then
      why "el diff trae un ADR en PROPUESTO: $f (lo firma un humano)"
    fi
    if [ -n "$HUMAN_PATHS" ] && printf '%s' "$f" | grep -Eq "$HUMAN_PATHS"; then
      why "el diff toca una ruta reservada al humano (SDD_HUMAN_PATHS): $f"
    fi
  done <<EOF
$files
EOF
fi

if [ -n "$reasons" ]; then
  printf 'GATE 2 HUMANO. Motivos:\n%s' "$reasons"; exit 1
fi

sec="no corrió"; [ -f "$s" ] && sec="sin críticos/altos, riesgo aceptable"
printf 'GATE 2 · %s · auto · APROBADO · sha: %s · base: %s · verify PASS · review APROBADO · security %s · sin ADR propuesto · sin rutas humanas\n' \
  "$(date +%Y-%m-%d)" "$head" "$BASE_BRANCH" "$sec" >> "$dir/gates.md"
echo "GATE 2 automático registrado para $head en $feature/gates.md."
exit 0
