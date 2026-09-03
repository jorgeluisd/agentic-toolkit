#!/usr/bin/env bash
# UserPromptSubmit — si el mensaje del usuario parece un pedido de cambio de código y no es un
# comando, agrega al contexto un recordatorio de que el cambio va por el pipeline SDD.
# Solo inyecta contexto; nunca bloquea.
input="$(cat)"
prompt="$(printf '%s' "$input" | jq -r '.prompt // ""' 2>/dev/null)"
[ -z "$prompt" ] && exit 0
case "$prompt" in /*) exit 0 ;; esac
lc="$(printf '%s' "$prompt" | tr '[:upper:]' '[:lower:]')"
if printf '%s' "$lc" | grep -Eq '\b(implementa|implementar|agrega|agregar|añade|añadir|crea|crear|construye|desarrolla|arregla|arreglar|corrige|corregir|refactoriza|migra|migrar|elimina la (columna|tabla)|feature|funcionalidad|endpoint|bug|fix|migraci[oó]n|integra(r|ci[oó]n)|webhook)\b'; then
  cat << 'CTX'
[sdd-tdd-core] Este pedido parece un cambio de código. Antes de tocar archivos: clasifica el nivel (completo / bugfix / trivial) según la skill `sdd-pipeline`, dilo en una línea y, salvo nivel trivial, ejecuta el pipeline de ORCHESTRATOR.md con artefactos en docs/sdd/<NNNN>-<slug>/ y parada en el GATE 1 antes de escribir código.
CTX
fi
exit 0
