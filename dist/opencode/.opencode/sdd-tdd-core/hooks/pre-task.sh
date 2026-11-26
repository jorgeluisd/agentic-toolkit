#!/usr/bin/env bash
# PreToolUse/Task — gatekeeper de fases: no deja lanzar un agente del pipeline si
# falta un artefacto que ese agente declara como insumo. Convierte la regla
# "no lanzas un agente si falta el artefacto anterior" en un chequeo mecánico.
#
# Solo actúa cuando hay una feature activa en el worktree (`active_feature`). Fuera del pipeline
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

# El trabajo pedido puede ser sobre otro repositorio: una sesión abierta en A y un
# subagente lanzado para B. El payload de Task no trae ni file_path ni command, así
# que el único indicio son las rutas que nombra el prompt del subagente. Si apuntan
# a un repositorio distinto al de la sesión, el gate se resuelve con los artefactos
# de ESE repositorio — exigir los de A para revisar B manda a producir artefactos
# basura en el repo que no se está tocando.
target="$(_sdd_text_repo "$(jq_get '.tool_input.prompt')
$(jq_get '.tool_input.description')")"
if [ -n "$target" ] && [ "$target" != "$PROJECT_DIR" ]; then
  _sdd_configure "$target"
  SDD_RUN_DIR="$target"; _SDD_WT_DONE=0
fi
_sdd_mark_cross

# Feature activa del worktree del trabajo pedido (`active_feature`). Sin ella no
# hay pipeline en curso y no hay nada que exigir: el gate no inventa uno.
feature="$(active_feature)" || exit 0
dir="$ARTIFACTS_ROOT/$feature"
[ -d "$dir" ] || exit 0

# Nivel del pipeline: lo escribe el orquestador al crear la carpeta.
# Ausente = full, que es el conjunto de requisitos más estricto.
level=full
[ -f "$dir/.level" ] && level="$(tr -d '[:space:]' < "$dir/.level")"
case "$level" in full|bugfix) ;; *) level=full ;; esac

layout="$(feature_layout "$dir")"
prompt="$(jq_get '.tool_input.prompt')"

if [ "$layout" = lite ]; then
  doc="$dir/feature.md"
  need=""
  lack(){ need="$need
- $1"; }
  sec(){ has_section "$doc" "$1" || lack "$feature/feature.md sin la sección '## $1'"; }
  # El pedido del humano entra textual en L1 antes de cualquier fase: es la referencia que
  # leen todos los agentes, en vez de una paráfrasis que se degrada de fase en fase.
  if ! has_section "$doc" Log || ! section_body "$doc" Log | grep -Eq '^L1[[:space:]]'; then
    lack "$feature/feature.md sin '## Log' con L1 (el pedido del humano, textual). Lo escribe el orquestador al crear la carpeta, antes del explorer."
  fi
  case "$agent" in
    spec-writer|task-planner)
      deny "GATEKEEPER: la feature $feature usa el layout lite: el designer escribe '## Specs' y '## Tasks' en feature.md, y '$agent' no corre. Si el proyecto necesita el formato por fases, SDD_LAYOUT=classic antes de crear la carpeta."; exit 0 ;;
    proposer|designer)
      [ "$level" = bugfix ] && { deny "GATEKEEPER: en nivel 'bugfix' el explorer escribe '## Specs' y '## Tasks', y '$agent' no corre. Si el cambio creció a contrato o esquema, sube el nivel a 'full' en $feature/.level."; exit 0; }
      sec Exploración ;;
    implementer)
      sec Specs; sec Tasks
      [ "$level" = full ] && sec Diseño
      printf '%s' "$prompt" | grep -Eq '(^|[^A-Za-z0-9])T[0-9]+' \
        || lack "el prompt del implementer no nombra su tarea (T#). Handoff por referencia: 'Spec: <ruta>/feature.md (lee hasta ## Log). Haz T3; S2, S4.'" ;;
    verifier)   sec Specs; sec Tasks
                for f in 05-apply-progress.md tdd-evidence.log; do [ -s "$dir/$f" ] || lack "$feature/$f"; done ;;
    code-reviewer|security-reviewer)
                sec Specs; [ -s "$dir/05-apply-progress.md" ] || lack "$feature/05-apply-progress.md" ;;
    archiver)   [ -s "$dir/gates.md" ] || lack "$feature/gates.md" ;;
  esac
  # Handoff por referencia: un prompt largo es una paráfrasis del pedido o de un artefacto.
  if [ "$agent" != explorer ] && [ "$HANDOFF_MAX_CHARS" -gt 0 ] && [ "${#prompt}" -gt "$HANDOFF_MAX_CHARS" ]; then
    lack "el prompt de '$agent' tiene ${#prompt} caracteres (tope SDD_HANDOFF_MAX_CHARS=$HANDOFF_MAX_CHARS). Pásale la referencia, no el contenido: ruta de feature.md, T# y S#."
  fi
  if [ "$agent" = implementer ] && [ "$level" = full ] && [ -z "$need" ]; then
    if ! grep -iE 'gate[[:space:]]*1' "$dir/gates.md" 2>/dev/null \
       | grep -ivE 'no[[:space:]]+aprobad|sin[[:space:]]+aprobar|rechazad|cambios' \
       | grep -qiE 'aprobad|acepto'; then
      lack "$feature/gates.md no registra el GATE 1 como APROBADO (token 'acepto'). Sin gate no hay implementación."
    fi
  fi
fi

missing="${need:-}"
if [ "$layout" = classic ]; then

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

fi

# Rotación del apply-progress. El implementer lo relee entero en cada tarea, así que
# sin rotar la tarea N paga el detalle de las N-1 anteriores. Se deniega el lanzamiento
# hasta rotar; rotar reduce el archivo, así que el ciclo termina.
if [ "$agent" = implementer ] && [ -z "$missing" ] && [ -s "$dir/05-apply-progress.md" ]; then
  tasks="$(grep -c '^## T-' "$dir/05-apply-progress.md" 2>/dev/null || echo 0)"
  if [ "$tasks" -gt "$PROGRESS_KEEP_TASKS" ]; then
    deny "GATEKEEPER: $feature/05-apply-progress.md acumula $tasks tareas (máximo $PROGRESS_KEEP_TASKS antes de rotar). El implementer lo relee entero en cada tarea, así que sin rotar el costo crece con el cuadrado de las tareas.

Rotá antes de relanzar: mové el detalle de las tareas más viejas a $feature/05-apply-progress-T<n>-T<m>.md, y dejá en 05-apply-progress.md una tabla RESUMEN ACUMULADO con una fila por tarea archivada (T-n · estado · commit · AC cubiertos) más el detalle completo de las últimas $PROGRESS_KEEP_TASKS. El verifier lee ambos archivos.

Para cambiar el umbral: SDD_PROGRESS_KEEP_TASKS en .agentic/sdd-hooks.env."
    exit 0
  fi
fi

if [ -n "$missing" ]; then
  # De qué repositorio son los artefactos que faltan. Sin decirlo, una sesión
  # anclada a otro repo lee la lista como si fuera del trabajo que pidió.
  if [ "${CROSS_REPO:-0}" = 1 ]; then
    where="La sesión está anclada a $SDD_SESSION_PROJECT_DIR; el trabajo pedido es sobre $PROJECT_DIR, y los artefactos de arriba son los de $PROJECT_DIR."
  else
    where="Estos artefactos son los de $PROJECT_DIR, el repositorio de la sesión. Si el trabajo pedido es sobre otro repositorio, no corras acá la fase que falta: abrí la sesión en la raíz de ese repositorio, que es donde viven sus artefactos."
  fi
  deny "GATEKEEPER: no se puede lanzar '$agent' (nivel $level, layout $layout). Falta:$missing

$where
Cada agente recibe artefactos, no contexto de chat: sin el insumo previo el resultado sería inventado. Corré la fase que lo produce, o corregí el puntero (<git dir>/sdd-current; en el checkout principal, también <raíz>/.current) si la feature activa no es la que creés."
fi
exit 0
