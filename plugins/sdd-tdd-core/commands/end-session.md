---
description: Cierra la sesión — resumen, estado git, clasificación de hallazgos (ADR / plan / CLAUDE.md / runbook / código) y updates propuestos al repo con OK explícito antes de aplicar.
---

Cierra la sesión en este orden estricto.

1. **Resumen** (idioma del proyecto): objetivo declarado, completado, abierto y por qué, decisiones tomadas (formales o tácticas), descubrimientos y blockers, archivos nuevos o muy modificados.

2. **Git**: `git status` y `git log --oneline -5`. Si hay cambios sin commitear que están en verde, commitéalos siguiendo `delivery-workflow` (un commit por cambio coherente, `type(scope)` en inglés, sin trailers de IA, identidad personal); lo que esté a medias o en rojo se deja sin commitear y se anota como pendiente. No pushees: pregunta si el humano quiere push y PR, o qué queda pendiente.

3. **Clasifica cada hallazgo**:
   a) Decisión sustantiva (arquitectura, stack, modelo, reglas de producto) → ADR con `/new-adr`; no lo escribas aquí, lístalo con el número que le tocaría.
   b) Cambio de estado del plan (ítem cerrado, bloqueado, nuevo) → update del plan/backlog.
   c) Cambio en cómo se trabaja → update del `CLAUDE.md` del proyecto o de su skill local de invariantes.
   d) Runbook, blocker externo, nota de deploy → docs operativas del proyecto.
   e) Detalle de implementación → comentario en PR o código, no en docs.

4. **Updates al repo**: para (b), (c), (d) muestra el diff propuesto y **espera el OK explícito** antes de aplicar. Nada va directo a la rama base.

5. **Memoria persistente** (si existe): guarda el cierre y lo no obvio; nunca datos personales, secretos ni identificadores de producción. Si no existe, omite.

6. **Próxima sesión**: objetivo concreto, qué leer antes, prerequisitos, y el prompt de continuación con el commit actual de la rama base.

Reglas: no tocar ADRs sin firma humana en esta sesión; si algo no está claro, pregunta antes de escribir.
