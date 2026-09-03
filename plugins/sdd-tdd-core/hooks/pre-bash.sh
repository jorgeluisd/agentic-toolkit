#!/usr/bin/env bash
# PreToolUse/Bash — guardrails de producción y de git.
# Devuelve "ask" para acciones que requieren un humano, "deny" para las prohibidas,
# y nada (permite) en el resto.
. "$(dirname "$0")/common.sh"
read_input
cmd="$(jq_get '.tool_input.command')"
[ -z "$cmd" ] && exit 0
lc="$(printf '%s' "$cmd" | tr '[:upper:]' '[:lower:]')"

# 1) Producción: marcadores del proyecto (userConfig) + patrones genéricos.
prod=0
if [ -n "$PROD_MARKERS" ] && printf '%s' "$cmd" | grep -Eq "$PROD_MARKERS"; then prod=1; fi
if printf '%s' "$lc" | grep -Eq '(^|[[:space:];&|])(fly(ctl)?|vercel|railway|gcloud|eb|heroku)[[:space:]]+deploy|vercel[[:space:]].*--prod|supabase[[:space:]]+(db[[:space:]]+(push|reset)|link)|drizzle-kit[[:space:]]+(push|migrate)|db:(push|migrate|reset)|prisma[[:space:]]+(db[[:space:]]+push|migrate[[:space:]]+deploy)|artisan[[:space:]]+migrate(:fresh|:refresh|:reset|:rollback)?|alembic[[:space:]]+(upgrade|downgrade)|manage\.py[[:space:]]+migrate|dotnet[[:space:]]+ef[[:space:]]+database[[:space:]]+update|kubectl[[:space:]]+(apply|delete|rollout)|terraform[[:space:]]+(apply|destroy)|flyctl?[[:space:]]+secrets|fly[[:space:]]+ssh'; then
  printf '%s' "$lc" | grep -Eq 'staging|preview|local|127\.0\.0\.1|localhost|docker' || prod=1
fi
if printf '%s' "$lc" | grep -Eq '(database_url|supabase_url|pg(host|user|password))=[^[:space:]]*(supabase\.co|amazonaws|neon\.tech|render\.com|railway\.app|fly\.dev|\.prod)'; then prod=1; fi
if [ "$prod" = 1 ]; then
  ask "GUARDRAIL PRODUCCIÓN: este comando parece actuar sobre un entorno de producción (marcador del proyecto o deploy/migración sin mención de staging/local). Solo un humano, nombrando explícitamente 'producción', autoriza esta acción. Aprueba únicamente si es intencional."
  exit 0
fi

# 2) Git: prohibiciones duras.
if printf '%s' "$lc" | grep -Eq 'git[[:space:]]+push.*(--force([[:space:]]|$)|-f([[:space:]]|$))' && ! printf '%s' "$lc" | grep -q -- '--force-with-lease'; then
  deny "Prohibido git push --force. Usa --force-with-lease solo con confirmación humana explícita."; exit 0
fi
if printf '%s' "$lc" | grep -Eq 'git[[:space:]]+(commit|push).*--no-verify'; then
  deny "Prohibido --no-verify: los hooks de git son parte de los guardrails."; exit 0
fi
if printf '%s' "$lc" | grep -Eq "git[[:space:]]+push[[:space:]].*[[:space:]](origin[[:space:]]+)?(main|master|$BASE_BRANCH)([[:space:]]|:|$)"; then
  ask "GUARDRAIL GIT: push directo a una rama base (main/master/$BASE_BRANCH). El flujo es rama de feature → PR → merge humano. Aprueba solo si es un release autorizado."; exit 0
fi
if printf '%s' "$lc" | grep -Eq 'git[[:space:]]+(merge|rebase)[[:space:]]' && printf '%s' "$lc" | grep -Eq "(main|master|$BASE_BRANCH)"; then
  ask "GUARDRAIL GIT: merge/rebase que involucra una rama base. Confirma que es lo que quieres."; exit 0
fi
if printf '%s' "$lc" | grep -Eq 'git[[:space:]]+(reset[[:space:]]+--hard|clean[[:space:]]+-[a-z]*f|branch[[:space:]]+-D|checkout[[:space:]]+--[[:space:]]+\.|restore[[:space:]]+\.)'; then
  ask "GUARDRAIL GIT: comando destructivo sobre el árbol de trabajo o ramas. Confirma."; exit 0
fi
if printf '%s' "$lc" | grep -Eq 'git[[:space:]]+commit' && printf '%s' "$lc" | grep -Eiq "$AI_TRAILER_RE"; then
  deny "El mensaje de commit contiene atribución de IA (co-author/session/generated). Convención: sin trailers ni menciones de IA. Reescribe el mensaje."; exit 0
fi
if printf '%s' "$lc" | grep -Eq 'git[[:space:]]+commit' && printf '%s' "$lc" | grep -Eq '(-a[[:space:]]|--all|-am[[:space:]])' ; then
  ask "git commit -a incluye todo lo modificado sin revisar el stage (riesgo de versionar .env o artefactos). Confirma o usa git add explícito."; exit 0
fi

# 3) Instalación y sistema.
if [ "$PNPM_PROJECT" = 1 ] && printf '%s' "$lc" | grep -Eq '(^|[[:space:];&|])(npm|yarn)[[:space:]]+(install|add|i|ci|run|exec)'; then
  deny "Este proyecto usa pnpm (hay pnpm-lock.yaml). Usa pnpm."; exit 0
fi
if printf '%s' "$lc" | grep -Eq '(--unsafe-perm|dangerouslyallowallbuilds|strict-dep-builds=false|--ignore-platform-reqs|--no-verify-signatures)'; then
  deny "Aprobación masiva o relajación de verificaciones de instalación prohibida. Aprueba paquete por paquete con OK humano."; exit 0
fi
if printf '%s' "$lc" | grep -Eq '(^|[[:space:];&|])rm[[:space:]]+-[a-z]*r[a-z]*f?[[:space:]]+(/|~|\$home|\.\.|\*)'; then
  ask "rm -rf sobre una ruta amplia. Confirma."; exit 0
fi
if printf '%s' "$lc" | grep -Eq '(^|[[:space:];&|])(cat|less|more|head|tail|bat|code|vim|nano|open)[[:space:]].*\.env($|\.[a-z.]+)' && ! printf '%s' "$lc" | grep -q '\.env\.example'; then
  deny "Prohibido leer archivos .env* (solo .env.example). Los secretos no entran al contexto del agente."; exit 0
fi
exit 0
