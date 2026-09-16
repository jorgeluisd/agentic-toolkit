# end-session

Cierra la sesión — resumen, estado git, clasificación de hallazgos (ADR / plan / AGENTS.md / runbook / código) y updates propuestos al repo con OK explícito antes de aplicar.


## Procedure


Cierra la sesión en este orden estricto.

1. **Resumen** (idioma del proyecto): objetivo declarado, completado, abierto y por qué, decisiones tomadas (formales o tácticas), descubrimientos y blockers, archivos nuevos o muy modificados.

2. **Git**: `git status` y `git log --oneline -5`. Si hay cambios sin commitear que están en verde, commitéalos siguiendo `delivery-workflow` (un commit por cambio coherente, `type(scope)` en inglés, sin trailers de IA, identidad personal); lo que esté a medias o en rojo se deja sin commitear y se anota como pendiente. No pushees: pregunta si el humano quiere push y PR, o qué queda pendiente.

3. **Clasifica cada hallazgo**:
   a) Decisión sustantiva (arquitectura, stack, modelo, reglas de producto) → ADR con `/new-adr`; no lo escribas aquí, lístalo con el número que le tocaría.
   b) Cambio de estado del plan (ítem cerrado, bloqueado, nuevo) → update del plan/backlog.
   c) Cambio en cómo se trabaja → update del `AGENTS.md` del proyecto o de su skill local de invariantes.
   d) Runbook, blocker externo, nota de deploy → docs operativas del proyecto.
   e) Detalle de implementación → comentario en PR o código, no en docs.

4. **Updates al repo**: para (b), (c), (d) muestra el diff propuesto y **espera el OK explícito** antes de aplicar. Nada va directo a la rama base.

5. **Memoria persistente** (si existe): guarda el cierre y lo no obvio; nunca datos personales, secretos ni identificadores de producción. Si no existe, omite.

6. **Próxima sesión**: objetivo concreto, qué leer antes, prerequisitos, y el prompt de continuación con el commit actual de la rama base.

Reglas: no tocar ADRs sin firma humana en esta sesión; si algo no está claro, pregunta antes de escribir.


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
