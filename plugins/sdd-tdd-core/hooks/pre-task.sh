#!/usr/bin/env bash
# PreToolUse/Task — gatekeeper de fases: no deja lanzar un agente del pipeline si
# falta un artefacto que ese agente declara como insumo. Convierte la regla
# "no lanzas un agente si falta el artefacto anterior" en un chequeo mecánico.
#
# Solo actúa cuando hay una feature activa (<raíz>/.current). Fuera del pipeline
# no molesta: subagentes ajenos y agentes lanzados sin feature activa pasan.
. "$(dirname "$0")/common.sh"
read_input

agent="$(jq_get '.tool_input.subagent_type')"
[ -z "$agent" ] && exit 0
# El nombre puede venir namespaced por el plugin (sdd-tdd-core:explorer).
agent="${agent##*:}"

case "$agent" in
  explorer|proposer|spec-writer|designer|task-planner|implementer|verifier|code-reviewer|security-reviewer|archiver) ;;
  *) exit 0 ;;
esac

# Feature activa. Sin ella no hay pipeline en curso y no hay nada que exigir.
[ -f "$ARTIFACTS_ROOT/.current" ] || exit 0
feature="$(tr -d '[:space:]' < "$ARTIFACTS_ROOT/.current")"
[ -n "$feature" ] || exit 0
dir="$ARTIFACTS_ROOT/$feature"
[ -d "$dir" ] || exit 0

# Nivel del pipeline: lo escribe el orquestador al crear la carpeta.
# Ausente = full, que es el conjunto de requisitos más estricto.
level=full
[ -f "$dir/.level" ] && level="$(tr -d '[:space:]' < "$dir/.level")"
case "$level" in full|bugfix) ;; *) level=full ;; esac

# Insumos por agente, según la sección "Entrada" de cada uno.
required=""
if [ "$level" = bugfix ]; then
  case "$agent" in
    proposer|spec-writer|designer|task-planner)
      deny "GATEKEEPER: el nivel de esta feature es 'bugfix' y no incluye al agente '$agent' (explorer → implementer → verifier ∥ code-reviewer → GATE 2). Si el cambio creció a contrato o esquema, subí el nivel a 'full' en $feature/.level y relanzá desde el spec-writer."; exit 0 ;;
    implementer)      required="00-explore.md" ;;
    verifier)         required="05-apply-progress.md tdd-evidence.log" ;;
    code-reviewer)    required="05-apply-progress.md" ;;
    archiver)         required="gates.md" ;;
  esac
else
  case "$agent" in
    proposer)          required="00-explore.md" ;;
    spec-writer)       required="00-explore.md 01-proposal.md" ;;
    designer)          required="00-explore.md 01-proposal.md 02-spec.md" ;;
    task-planner)      required="02-spec.md 03-design.md" ;;
    implementer)       required="02-spec.md 03-design.md 04-plan.md gates.md" ;;
    verifier)          required="02-spec.md 03-design.md 04-plan.md 05-apply-progress.md tdd-evidence.log" ;;
    code-reviewer)     required="02-spec.md 03-design.md 04-plan.md 05-apply-progress.md" ;;
    security-reviewer) required="02-spec.md 03-design.md 05-apply-progress.md" ;;
    archiver)          required="gates.md" ;;
  esac
fi
[ -z "$required" ] && exit 0

missing=""
for f in $required; do
  [ -s "$dir/$f" ] || missing="$missing
- $feature/$f"
done

# El implementer además necesita el GATE 1 registrado como aprobado: antes de eso
# no se escribe una línea de código de producción.
if [ "$agent" = implementer ] && [ "$level" = full ] && [ -s "$dir/gates.md" ]; then
  # Línea que nombre al GATE 1 y lo declare APROBADO, descartando las negaciones
  # ("no aprobado", "sin aprobar") y los otros dos veredictos del protocolo.
  if ! grep -iE 'gate[[:space:]]*1' "$dir/gates.md" \
     | grep -ivE 'no[[:space:]]+aprobad|sin[[:space:]]+aprobar|rechazad|cambios' \
     | grep -qiE 'aprobad|acepto'; then
    missing="$missing
- $feature/gates.md no registra el GATE 1 como APROBADO (token 'acepto'). Sin gate no hay implementación."
  fi
fi

# Rotación del apply-progress. El implementer lo relee entero en cada tarea, así que
# sin rotar la tarea N paga el detalle de las N-1 anteriores. Se deniega el lanzamiento
# hasta rotar; rotar reduce el archivo, así que el ciclo termina.
if [ "$agent" = implementer ] && [ -z "$missing" ] && [ -s "$dir/05-apply-progress.md" ]; then
  tasks="$(grep -c '^## T-' "$dir/05-apply-progress.md" 2>/dev/null || echo 0)"
  if [ "$tasks" -gt "$PROGRESS_KEEP_TASKS" ]; then
    deny "GATEKEEPER: $feature/05-apply-progress.md acumula $tasks tareas (máximo $PROGRESS_KEEP_TASKS antes de rotar). El implementer lo relee entero en cada tarea, así que sin rotar el costo crece con el cuadrado de las tareas.

Rotá antes de relanzar: mové el detalle de las tareas más viejas a $feature/05-apply-progress-T<n>-T<m>.md, y dejá en 05-apply-progress.md una tabla RESUMEN ACUMULADO con una fila por tarea archivada (T-n · estado · commit · AC cubiertos) más el detalle completo de las últimas $PROGRESS_KEEP_TASKS. El verifier lee ambos archivos.

Para cambiar el umbral: SDD_PROGRESS_KEEP_TASKS en .claude/sdd-hooks.env."
    exit 0
  fi
fi

if [ -n "$missing" ]; then
  deny "GATEKEEPER: no se puede lanzar '$agent' (nivel $level). Falta:$missing

Cada agente recibe artefactos, no contexto de chat: sin el insumo previo el resultado sería inventado. Corré la fase que lo produce, o corregí <raíz>/.current si la feature activa no es la que creés."
fi
exit 0
