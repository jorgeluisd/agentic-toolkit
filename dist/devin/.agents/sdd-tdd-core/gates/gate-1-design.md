# GATE 1 — Diseño (parada humana antes de escribir código)

**Posición:** después del `designer` (lite) o del `task-planner` (classic). Se aprueban juntos specs, diseño y tareas —`feature.md` en lite; `02-spec.md`, `03-design.md` y `04-plan.md` en classic— porque las tareas son lo que se ejecuta y el diseño es lo que se paga.

**Antes de este gate solo existe documentación.** Ningún archivo de código, test, migración ni configuración se crea antes del `acepto`.

## Insumos presentes (si falta uno, la feature no pasa; se avanza con otra)
Lite — `feature.md`:
- [ ] `## Log` con `L1` = el pedido textual, y cada corrección posterior como `Ln`.
- [ ] `## Exploración` sin insumos faltantes que bloqueen; `## Propuesta` si cerró con `DECISIÓN: sí`.
- [ ] `## Specs` numeradas `S#`, con las cadenas, mensajes y ejemplos del pedido **textuales**, y escenarios negativos de seguridad cuando toca datos.
- [ ] `## Diseño` con AMENAZAS y plan de migración (si hay esquema).
- [ ] `## Tasks` con cada `S#` cubierta y ninguna tarea `TDD ?`.

Classic:
- [ ] `00-explore.md` sin INSUMOS FALTANTES que bloqueen.
- [ ] `01-proposal.md` con recomendación y, si aplica, ADR en `PROPUESTO`.
- [ ] `02-spec.md` con `AC-n` numerados y escenarios negativos de seguridad cuando toca datos.
- [ ] `03-design.md` con tabla de AMENAZAS y PLAN DE MIGRACIÓN (si hay esquema).
- [ ] `04-plan.md` sin tareas `TDD: ?`.

## Lo que el humano juzga (la máquina no puede)
- [ ] ¿Es lo correcto para el producto? ¿El alcance es el mínimo que entrega valor?
- [ ] ¿La spec dice qué es inmediato y qué es eventual, y estoy de acuerdo?
- [ ] ¿Cada amenaza tiene mitigación **y** un test asignado a una tarea?
- [ ] ¿La migración es aditiva y tiene rollback? ¿Acepto el riesgo de lock/backfill?
- [ ] ¿Los ADRs propuestos se firman ahora, se rechazan o se posponen (y entonces la feature espera)?
- [ ] ¿El modelo asignado por tarea es razonable?
- [ ] ¿Las `S#` dicen lo que pedí con mis palabras, sin requisitos que no pedí?
- [ ] ¿Las invariantes del proyecto (`AGENTS.md`, skill local) están respetadas en el diseño?

## Registro (obligatorio; sin registro el gate no ocurrió)
Añadir a `docs/sdd/<feature>/gates.md`:
```
GATE 1 · <YYYY-MM-DD> · <quién> · APROBADO | CAMBIOS | RECHAZADO · token: "acepto" · ADRs firmados: [...] · observaciones: ...
```
`CAMBIOS` devuelve al agente que corresponda (lite: designer; classic: spec-writer, designer o task-planner) con la lista de cambios; en lite solo se reescriben las `S#` afectadas y se reabren sus `T#`, con el motivo en el `## Log`. El gate se repite.
