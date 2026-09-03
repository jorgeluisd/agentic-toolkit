#!/usr/bin/env bash
# PreToolUse/Read|Edit|Write|MultiEdit — archivos que el agente no debe abrir ni
# tocar, y contenido que no debe llegar al disco (se evalúa ANTES de escribir).
. "$(dirname "$0")/common.sh"
read_input
path="$(jq_get '.tool_input.file_path')"
[ -z "$path" ] && exit 0
base="$(basename "$path")"
tool="$(jq_get '.tool_name')"

# ---- 1) Rutas prohibidas o sensibles (cualquier herramienta) ----
# .env* excepto .env.example / .env.sample / .env.template
if printf '%s' "$base" | grep -Eq '^\.env(\..+)?$' && ! printf '%s' "$base" | grep -Eq '^\.env\.(example|sample|template)$'; then
  deny "Prohibido leer o editar $base. Los secretos no entran al contexto del agente; usa .env.example para documentar variables."; exit 0
fi
# Claves y credenciales.
if printf '%s' "$base" | grep -Eq '\.(pem|key|p12|pfx|jks|keystore)$|^id_(rsa|ed25519|ecdsa)(\.pub)?$|service-account.*\.json$|credentials\.json$|\.npmrc$|\.pypirc$|\.netrc$|auth\.json$|\.env\.php$'; then
  ask "Archivo de credenciales o configuración con posibles secretos ($base). Confirma si realmente hace falta."; exit 0
fi
# Dumps y exportaciones con datos reales.
if printf '%s' "$base" | grep -Eq '\.(dump|sql\.gz|bak|backup)$|dump.*\.sql$|export.*\.(csv|xlsx|json)$'; then
  ask "Posible dump o exportación con datos reales ($base). El agente no debe cargar datos personales en su contexto. Confirma."; exit 0
fi

# ---- 2) Contenido que se va a escribir (Write: content; Edit: new_string; MultiEdit: edits[].new_string) ----
case "$tool" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac
content="$(printf '%s' "$INPUT" | jq -r '[.tool_input.content // empty, .tool_input.new_string // empty, ((.tool_input.edits // [])[]? | .new_string // empty)] | join("\n")' 2>/dev/null)"
[ -z "$content" ] && exit 0
rel="${path#$PROJECT_DIR/}"
problems=""

# Secretos en cualquier archivo (excepto los de ejemplo y el log de evidencia, que ya redacta).
if ! printf '%s' "$rel" | grep -Eq '\.env\.(example|sample|template)$|tdd-evidence\.log$'; then
  hit="$(printf '%s' "$content" | grep -EoI "$SECRET_RE" | head -n 3)"
  [ -n "$hit" ] && problems="$problems
- Posible secreto en el contenido destinado a $rel. Los secretos van en variables de entorno, nunca en archivos versionados."
fi

# Datos personales en artefactos del proceso, docs, fixtures y tests.
if printf '%s' "$rel" | grep -Eq '^docs/|/docs/|fixtures?/|seeds?/|\.(spec|test|integration\.spec|e2e-spec)\.[a-z]+$|\.md$'; then
  emails="$(printf '%s' "$content" | grep -EoI "$EMAIL_RE" | grep -Ev "$EXAMPLE_EMAIL_RE" | sort -u | head -n 3)"
  [ -n "$emails" ] && problems="$problems
- Emails que no parecen sintéticos destinados a $rel: $(printf '%s' "$emails" | tr '\n' ' '). Usa dominios example.com/test.local."
  phones="$(printf '%s' "$content" | grep -EoI "$PHONE_RE" | sort -u | head -n 3)"
  [ -n "$phones" ] && problems="$problems
- Teléfonos en formato internacional destinados a $rel: $(printf '%s' "$phones" | tr '\n' ' '). Si son reales, reemplázalos por sintéticos (+10000000001)."
fi

# Campo de tenant en DTOs / contratos de entrada.
if [ -n "$TENANT_FIELD" ] && printf '%s' "$rel" | grep -Eq '(presentation/.*(dto|schema)|contracts/).*\.(ts|php|py)$' && printf '%s' "$content" | grep -Eq "\b$TENANT_FIELD\b"; then
  problems="$problems
- El contenido destinado a $rel declara el campo de tenant '$TENANT_FIELD'. El tenant viene del contexto de auth, nunca del body/DTO."
fi

# Comentarios en código fuente: el código debe explicarse solo. Se mide sobre el archivo tal como
# quedaría (contenido completo en Write; para Edit/MultiEdit, el archivo actual con el reemplazo aplicado
# no está disponible aquí, así que se mide solo el fragmento nuevo).
if printf '%s' "$rel" | grep -Eq '\.(ts|tsx|js|jsx|mjs|php|py|go|rs|kt|java|swift|cs)$' \
   && ! printf '%s' "$rel" | grep -Eq '(\.d\.ts$|\.config\.[a-z]+$|(^|/)(migrations?|drizzle|database/migrations|alembic)/|\.(spec|test|integration\.spec|e2e-spec)\.[a-z]+$|(^|/)(tests?|__tests__|spec|e2e|fixtures?|testing)/|(^|/)scripts?/|(^|/)\.claude/)'; then
  stats="$(printf '%s\n' "$content" | awk -v maxblock="$COMMENT_MAX_BLOCK" '
    function is_comment(l) { return (l ~ /^[[:space:]]*(\/\/|#|\*|\/\*|<!--|--[[:space:]])/ && l !~ /^[[:space:]]*#!/ && l !~ /^[[:space:]]*#\[/) }
    { total++; if (is_comment($0)) { c++; run++; if (run > longest) longest = run } else if ($0 !~ /^[[:space:]]*$/) { run = 0 } }
    END { pct = (total > 0) ? int(100 * c / total) : 0; printf "%d %d %d", longest, pct, total }')"
  longest="${stats%% *}"; rest="${stats#* }"; pct="${rest%% *}"; total="${rest#* }"
  if [ "$total" -ge 12 ] && { [ "$longest" -gt "$COMMENT_MAX_BLOCK" ] || [ "$pct" -gt "$COMMENT_MAX_PCT" ]; }; then
    problems="$problems
- Demasiado comentario en $rel: bloque más largo de $longest líneas (máx. $COMMENT_MAX_BLOCK), $pct % de líneas comentadas (máx. $COMMENT_MAX_PCT %). El código debe explicarse con nombres, tipos y tests; un comentario solo justifica un porqué que el código no puede expresar (decisión con ADR/issue, workaround con condición de retiro). Si un bloque necesita explicación, extrae una función con ese nombre. Sin código comentado ni banners de sección."
  fi
fi

if [ -n "$problems" ]; then
  deny "GUARDRAIL antes de escribir (nada tocó el disco):$problems"
fi
exit 0
