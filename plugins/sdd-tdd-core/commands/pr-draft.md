---
description: Redacta el PR con la única plantilla permitida (Qué cambia · Por qué · Verificación) a partir de la spec y del reporte del verifier, y lo abre con gh solo si el humano lo confirma.
argument-hint: "[ruta a docs/sdd/<feature>/ | vacío = la de docs/sdd/.current]"
---

Redacta la descripción del PR para la feature en:
$ARGUMENTS
(si está vacío, usa la carpeta indicada en `docs/sdd/.current`).

Insumos: `02-spec.md` (RESUMEN y OBJETIVO), `06-verify.md` (tabla de checks y sha), `05-apply-progress.md` (solo para confirmar el alcance). Carga la skill `delivery-workflow`.

Plantilla EXACTA (no agregues secciones, no quites ninguna):

```
<type>(<scope>): <imperative summary in English, ≤ 72 characters>

## Qué cambia
<máximo 3 líneas, en presente, qué hace el cambio>

## Por qué
<una línea; omite la sección solo si es evidente por el título>

## Verificación
<comando → resultado literal, uno por línea, tomados de 06-verify.md; incluye el sha verificado>
```

Prohibido en el PR: referencias a otros PR, nombres de personas, ADRs, análisis de riesgo, orden de merge, recomendaciones, alternativas descartadas, avisos sobre lo que pasa al mergear, menciones a IA o al proceso. Todo eso vive en `docs/sdd/<feature>/` y en la conversación.

Pasos:
1. Muestra el título y el cuerpo completos.
2. Pregunta: "¿Abro el PR contra `<rama base>`?" y **espera la respuesta**.
3. Solo con confirmación: `gh pr create --base <rama base> --title "<título>" --body "$(cat <<'EOF' … EOF)"`. Nunca `--web` sin pedirlo, nunca merge.
