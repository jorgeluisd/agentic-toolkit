#!/usr/bin/env bash
# PreToolUse/Read|Edit|Write|MultiEdit — archivos que el agente no debe abrir ni tocar.
. "$(dirname "$0")/common.sh"
read_input
path="$(jq_get '.tool_input.file_path')"
[ -z "$path" ] && exit 0
base="$(basename "$path")"

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
exit 0
