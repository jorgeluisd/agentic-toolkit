# pr-draft

Redacta el PR con la única plantilla permitida (Qué cambia · Por qué · Verificación) a partir de la spec y del reporte del verifier, y lo abre con gh solo si el humano lo confirma.

**Argumentos:** `[ruta a docs/sdd/<feature>/ | vacío = la de docs/sdd/.current]`

## Procedure


Redacta la descripción del PR para la feature en:
lo que te pidió el usuario
(si está vacío, usa la carpeta indicada en `docs/sdd/.current`).

Insumos: `02-spec.md` (RESUMEN y OBJETIVO), `06-verify.md` (tabla de checks y sha), `05-apply-progress.md` (solo para confirmar el alcance). Carga la skill `delivery-workflow`.

Plantilla EXACTA (no agregues secciones, no quites ninguna). Título en inglés; cuerpo en español neutro y breve: ≤ 8 líneas en total.

```
<type>(<scope>): <imperative summary in English, ≤ 72 characters>

## Qué cambia
<1–3 líneas, en presente, qué hace el cambio>

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


## Specifications

- El pipeline, las fases y los gates están en `.agents/sdd-tdd-core/ORCHESTRATOR-solo.md`. Leelo antes de empezar.
- Los artefactos van a `docs/sdd/<NNNN>-<slug>/` y son la máquina de estados del proceso: si no está escrito, no pasó.
- En cada gate te detenés de verdad y esperás el token del humano. Un gate sin registro en `gates.md` no ocurrió.

## Forbidden Actions

- Leer o editar `.env*`, `*.pem`, `*.key` ni ningún archivo de credenciales.
- Escribir secretos, datos personales reales o identificadores de producción en un artefacto, un test o un commit. Los ejemplos son sintéticos: teléfonos `+10000000001`, dominios `example.com`.
- Correr comandos dirigidos a producción (psql contra una base productiva, deploys, actualización de una lambda) sin confirmación humana explícita.
- Forzar un push, saltear los hooks de git al commitear, o pushear directo a la rama base.
- Agregar trailers o menciones de IA al commit o al PR: `Co-Authored-By`, `Generated with`, nombres de modelos, `anthropic`, `openai`, `devin.ai`.
- Escribir código de producción antes del GATE 1 aprobado.
- Escribir código de producción en una fase que no sea `implementer`.
- Bloques de comentario de más de 4 líneas, o más de 15 % de líneas comentadas en un archivo de código.
