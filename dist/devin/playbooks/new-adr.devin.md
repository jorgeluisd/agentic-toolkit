# new-adr

Redacta un Architecture Decision Record con la plantilla canónica, lo deja en estado PROPUESTO en la carpeta de ADRs del proyecto y solo lo pasa a ACEPTADO tras el OK explícito del humano.

**Argumentos:** `[contexto del problema en 3-5 líneas]`

## Procedure


Crea un ADR para:
lo que te pidió el usuario
(si está vacío, pide el contexto en 3–5 líneas antes de continuar).

1. **Numeración**: lista la carpeta de ADRs del proyecto (ruta en `AGENTS.md`, por defecto `docs/adr/`) y toma el siguiente número con el mismo ancho de dígitos que los existentes. Confirma el número. Nunca lo inventes.
2. **Afines**: ADRs relacionados o impactados (grep por tema). Si reemplaza uno, dilo y propón cómo enlazarlos. Si la decisión ya existe, actualiza ese ADR en vez de crear otro.
3. **Opciones**: 2–3 serias (si solo hay 2 reales, son 2), cada una con descripción, pros y contras **para este proyecto**, costo de adopción y de salida.
4. **Recomendación** con 3–5 razones concretas, considerando stack declarado, tamaño del equipo, etapa del proyecto, restricciones operativas y reversibilidad.
5. **Borrador** con esta plantilla exacta:

```
# ADR-NNNN — <título corto y concreto>
Fecha: YYYY-MM-DD
Estado: PROPUESTO

## Contexto
<problema concreto, no la solución; ADRs afines por número>

## Opciones consideradas
### Opción A — <nombre>
Descripción · Pros para el proyecto · Contras para el proyecto · Costo de adopción / salida
### Opción B — …

## Decisión
Elegimos <opción>. Razones: …

## Consecuencias
Se gana · Se pierde o compromete · Trabajo derivado obligatorio (ítems concretos) · Reversibilidad: baja|media|alta — qué costaría revertir

## ADRs relacionados
```

6. **Confirmación**: muestra el borrador completo y espera el OK explícito ("acepto", "acepto con cambios: …", "rechazo").
7. **Escritura**: crea `ADR-NNNN-<slug-kebab>.md`. **El estado pasa a `ACEPTADO` únicamente tras el OK del paso 6; el agente nunca lo ratifica por su cuenta.** Si reemplaza otro, marca el anterior como `REEMPLAZADO por ADR-NNNN`. Se integra por PR a la rama base.
8. **Trabajo derivado**: lista lo que el ADR obliga (actualizar skill local, ítem de plan, runbook) y pregunta si se agenda ahora o después.

Reglas: idioma del proyecto; identificadores en inglés; no crear el ADR mientras se sigue debatiendo.


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
