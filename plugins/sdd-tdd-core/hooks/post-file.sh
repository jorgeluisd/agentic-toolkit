#!/usr/bin/env bash
# PostToolUse/Edit|Write|MultiEdit — datos personales en artefactos, secretos en
# cualquier archivo, campo de tenant en DTOs, migraciones destructivas.
# Devuelve {"decision":"block"} con la razón para que el agente corrija.
. "$(dirname "$0")/common.sh"
read_input
path="$(jq_get '.tool_input.file_path')"
[ -z "$path" ] || [ ! -f "$path" ] && exit 0
rel="${path#$PROJECT_DIR/}"
problems=""

# 1) Secretos en cualquier archivo escrito (excepto los de ejemplo).
if ! printf '%s' "$rel" | grep -Eq '\.env\.(example|sample|template)$|tdd-evidence\.log$'; then
  hit="$(grep -EnoI "$SECRET_RE" "$path" 2>/dev/null | head -n 3)"
  [ -n "$hit" ] && problems="$problems
- Posible secreto en $rel: $(printf '%s' "$hit" | cut -c1-80 | tr '\n' ';'). Los secretos van en variables de entorno, nunca en archivos versionados."
fi

# 2) Datos personales en artefactos del proceso, docs, fixtures y tests.
if printf '%s' "$rel" | grep -Eq '^docs/|/docs/|fixtures?/|seeds?/|\.(spec|test|integration\.spec|e2e-spec)\.ts$|\.md$'; then
  emails="$(grep -EoI "$EMAIL_RE" "$path" 2>/dev/null | grep -Ev "$EXAMPLE_EMAIL_RE" | sort -u | head -n 3)"
  [ -n "$emails" ] && problems="$problems
- Emails que no parecen sintéticos en $rel: $(printf '%s' "$emails" | tr '\n' ' '). Usa dominios example.com/test.local."
  phones="$(grep -EoI "$PHONE_RE" "$path" 2>/dev/null | sort -u | head -n 3)"
  [ -n "$phones" ] && problems="$problems
- Teléfonos en formato internacional en $rel: $(printf '%s' "$phones" | tr '\n' ' '). Si son reales, reemplázalos por números sintéticos (por ejemplo +10000000001)."
fi

# 3) Campo de tenant en DTOs / contratos de entrada.
if [ -n "$TENANT_FIELD" ] && printf '%s' "$rel" | grep -Eq '(presentation/.*(dto|schema)|contracts/).*\.ts$'; then
  if grep -Eq "\b$TENANT_FIELD\b" "$path" 2>/dev/null; then
    problems="$problems
- $rel declara el campo de tenant '$TENANT_FIELD'. El tenant viene del contexto de auth, nunca del body/DTO."
  fi
fi

# 4) Migraciones destructivas o sin aislamiento.
if printf '%s' "$rel" | grep -Eq '(migrations?|drizzle|database/migrations|alembic/versions)/.*\.(sql|php|py|ts|js)$'; then
  up="$(tr '[:lower:]' '[:upper:]' < "$path")"
  printf '%s' "$up" | grep -Eq 'DROP[[:space:]]+(TABLE|COLUMN)|ALTER[[:space:]]+COLUMN[[:space:]]+[^;]*[[:space:]]TYPE[[:space:]]|TRUNCATE[[:space:]]|DROPCOLUMN\(|DROPIFEXISTS\(|->DROP\(|OP\.DROP_(TABLE|COLUMN)' && problems="$problems
- Migración destructiva en $rel (DROP/ALTER TYPE/TRUNCATE). Requiere plan de migración expand/contract aprobado en GATE 1."
  printf '%s' "$up" | grep -Eq 'SET[[:space:]]+NOT[[:space:]]+NULL' && ! printf '%s' "$up" | grep -Eq 'DEFAULT|NOT[[:space:]]+VALID|VALIDATE[[:space:]]+CONSTRAINT' && problems="$problems
- SET NOT NULL sin DEFAULT ni CHECK NOT VALID en $rel: bloquea la tabla y falla con filas existentes."
  if [ -n "$TENANT_FIELD" ] && printf '%s' "$up" | grep -Eq 'CREATE[[:space:]]+TABLE' && grep -Eiq "\b$TENANT_FIELD\b" "$path" && ! printf '%s' "$up" | grep -Eq 'FORCE[[:space:]]+ROW[[:space:]]+LEVEL[[:space:]]+SECURITY'; then
    problems="$problems
- Tabla nueva con columna de tenant sin FORCE ROW LEVEL SECURITY en la misma migración ($rel)."
  fi
  printf '%s' "$up" | grep -Eq 'SECURITY[[:space:]]+DEFINER' && ! printf '%s' "$up" | grep -Eq 'SET[[:space:]]+SEARCH_PATH' && problems="$problems
- Función SECURITY DEFINER sin SET search_path fijo en $rel."
  printf '%s' "$up" | grep -Eq 'GRANT[[:space:]]+(ALL|SELECT|INSERT|UPDATE|DELETE)[^;]*TO[[:space:]]+(ANON|PUBLIC)' && problems="$problems
- GRANT de tabla a anon/PUBLIC en $rel. Solo EXECUTE sobre funciones explícitas."
fi

if [ -n "$problems" ]; then
  block_post "GUARDRAIL post-escritura:$problems"
fi
exit 0
