#!/usr/bin/env bash
# Madurez de las dependencias nuevas. No es un hook: lo corre el verifier cuando el diff
# toca un lockfile, y su línea de salida va a 06-verify.md, donde gate2-auto.sh la exige.
# Cubre los gestores que no traen la regla de serie (pnpm < 10.16 sin
# minimum-release-age, Go): toda versión que entra al lockfile tiene que llevar
# publicada al menos SDD_RELEASE_MIN_HOURS horas (default 72), directa o transitiva.
#
#   bash <plugin>/hooks/release-age.sh
#
# Imprime una línea `release-age: OK|FAIL|N/A|SIN VERIFICAR …` y, si falla, la lista.
# Sale 0 (OK o N/A), 1 (FAIL) o 3 (no se pudo consultar el registry).
. "$(dirname "$0")/common.sh"

MIN_HOURS="${SDD_RELEASE_MIN_HOURS:-72}"
case "$MIN_HOURS" in ""|*[!0-9]*) MIN_HOURS=72 ;; esac
ALLOW="${SDD_RELEASE_AGE_ALLOW:-}"
wt="${WORKTREE_DIR:-$PROJECT_DIR}"
base="$BASE_BRANCH"
git -C "$wt" rev-parse -q --verify "origin/$BASE_BRANCH" >/dev/null 2>&1 && base="origin/$BASE_BRANCH"

# Fecha de publicación (epoch) de <tipo> <nombre> <versión>. Reemplazable para tests.
publish_time() {
  if [ -n "${SDD_RELEASE_TIME_CMD:-}" ]; then $SDD_RELEASE_TIME_CMD "$@"; return; fi
  case "$1" in
    npm)
      command -v npm >/dev/null && command -v node >/dev/null || return 3
      npm view "$2" time --json 2>/dev/null | node -e '
        let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
          try { const t = JSON.parse(s)[process.argv[1]]; if (t) console.log(Math.floor(Date.parse(t) / 1000)); } catch {}
        });' "$3" ;;
    go)
      command -v go >/dev/null || return 3
      local t; t="$(go list -m -json "$2@$3" 2>/dev/null | sed -nE 's/^[[:space:]]*"Time": "([^"]+)".*/\1/p' | head -1)"
      [ -n "$t" ] || return 0
      date -u -d "$t" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%S' "${t%%Z*}" +%s 2>/dev/null ;;
  esac
}

# Versiones que el diff agrega a cada lockfile: líneas `tipo nombre versión`.
added=""
if git -C "$wt" diff --quiet "$base"...HEAD -- pnpm-lock.yaml 2>/dev/null; then :; else
  added="$added$(git -C "$wt" diff -U0 "$base"...HEAD -- pnpm-lock.yaml 2>/dev/null \
    | sed -nE "s/^\+  ['\"]?(@?[^@'\"[:space:]]+)@([0-9][^@'\"(:[:space:]]*)(\([^:]*\))?['\"]?:[[:space:]]*$/npm \1 \2/p")
"
fi
if git -C "$wt" diff --quiet "$base"...HEAD -- go.sum 2>/dev/null; then :; else
  added="$added$(git -C "$wt" diff -U0 "$base"...HEAD -- go.sum 2>/dev/null \
    | sed -nE 's#^\+([^[:space:]]+) (v[^/[:space:]]+) h1:.*#go \1 \2#p')
"
fi
added="$(printf '%s' "$added" | sed '/^$/d' | sort -u)"
if [ -z "$added" ]; then echo "release-age: N/A (el diff no agrega versiones a pnpm-lock.yaml ni go.sum)"; exit 0; fi

now="$(date -u +%s)"; limit=$((now - MIN_HOURS * 3600))
young=""; unknown=""; n=0
while read -r kind name ver; do
  [ -n "$name" ] || continue
  [ -n "$ALLOW" ] && printf '%s' "$name" | grep -Eq "$ALLOW" && continue
  n=$((n + 1))
  ts="$(publish_time "$kind" "$name" "$ver")"; rc=$?
  if [ "$rc" = 3 ]; then echo "release-age: SIN VERIFICAR (falta npm/node o go para consultar el registry)"; exit 3; fi
  case "$ts" in
    ""|*[!0-9]*) unknown="$unknown
  $name@$ver" ;;
    *) [ "$ts" -le "$limit" ] || young="$young
  $name@$ver ($(( (now - ts) / 3600 )) h)" ;;
  esac
done <<EOF
$added
EOF

if [ -n "$young$unknown" ]; then
  echo "release-age: FAIL ($n versiones nuevas; mínimo $MIN_HOURS h)"
  [ -n "$young" ] && printf 'Publicadas hace menos de %s h:%s\n' "$MIN_HOURS" "$young"
  [ -n "$unknown" ] && printf 'Sin fecha de publicación en el registry:%s\n' "$unknown"
  exit 1
fi
echo "release-age: OK ($n versiones nuevas, todas con ≥ $MIN_HOURS h)"
exit 0
