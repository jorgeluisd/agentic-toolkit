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

if [ -n "$problems" ]; then
  deny "GUARDRAIL antes de escribir (nada tocó el disco):$problems"
fi
exit 0
