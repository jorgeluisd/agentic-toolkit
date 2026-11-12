# GATE 2 — Implementación (parada humana antes del merge)

**Posición:** después de `06-verify.md` en PASS, `07-review.md` sin hallazgos altos y `07-security.md` (si corrió). **Un FAIL del verifier nunca llega aquí.** Este gate no repite los checks mecánicos: contiene solo lo que un humano debe decidir.

## Precondiciones (las comprueba el orquestador, no el humano)
- `06-verify.md`: `RESUMEN: PASS`, sha verificado = HEAD de la rama.
- `07-review.md`: veredicto `APROBADO` (sin hallazgos altos); los medios listados para decidir aquí.
- `07-security.md` (si corrió): sin hallazgos críticos/altos sin mitigación.
- PR abierto con `/pr-draft` (título + 3 secciones: qué cambia, por qué, verificación).

## Modo auto (`SDD_AUTONOMY=auto`)
El orquestador corre `gate2-auto.sh`. Si sale 0, el gate quedó registrado para el HEAD exacto y no hay parada humana: push, PR y merge hacia la rama base siguen solos. Si sale 1, sus motivos encabezan este checklist y decide el humano. Las preguntas de abajo son las que el modo auto da por respondidas solo cuando ningún artefacto marca `GATE 2: humano`, no hay ADR propuesto, no hay riesgo residual a decidir y el diff no toca rutas reservadas.

## Lo que el humano juzga
- [ ] **Alcance**: el diff corresponde a lo aprobado en GATE 1. Las desviaciones justificadas en el apply-progress son aceptables.
- [ ] **Producto**: lo construido resuelve el objetivo tal como lo entendí al aprobar la spec; los `AC-n` demostrados son los que importan.
- [ ] **Deuda aceptada**: los hallazgos medios de `07-review.md` que decido no corregir en este PR van al backlog con nombre.
- [ ] **Riesgo residual**: acepto explícitamente lo que `07-security.md` deja sin cubrir (y va al backlog), o no acepto y vuelve.
- [ ] **Migración**: go/no-go para aplicarla; orden migraciones → api → web; ventana; rollback entendido.
- [ ] **Decisiones sin firmar**: no queda ningún ADR `PROPUESTO` que este PR ya asuma como aceptado.
- [ ] **Entrega**: rama base correcta; estrategia de merge según `delivery-workflow` (feature→develop squash permitido; release develop→main merge commit).

## Registro (obligatorio)
```
GATE 2 · <YYYY-MM-DD> · <quién> · APROBADO | CAMBIOS | RECHAZADO · riesgo residual aceptado: [...] · migración: go | no-go · observaciones: ...
```
`APROBADO` → el humano mergea (o autoriza al agente a hacerlo con el comando exacto) → `archiver`.
`CAMBIOS` → tareas nuevas en `04-plan.md` → `implementer` → `verifier` → este gate de nuevo.
