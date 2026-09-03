# ORCHESTRATOR — SDD + Strict TDD

Pipeline de 10 agentes para construir software con especificación verificable, diseño explícito, TDD estricto y dos paradas humanas. Agnóstico de producto y de lenguaje: el contexto de negocio y las invariantes viven en el `CLAUDE.md` y en la skill local de invariantes de cada proyecto; las reglas técnicas (capas, dominio, persistencia, tests, seguridad) las aporta el plugin de stack instalado junto a este core (`stack-typescript` u otro). Este documento define solo el proceso.

## 1. Pipeline

```
explorer → proposer → spec-writer → designer → task-planner → [GATE 1] →
(implementer ⟲ strict-tdd)* → verifier ∥ code-reviewer ∥ security-reviewer → [GATE 2] → merge → archiver
```

| # | Agente | Responsabilidad (una línea) | Artefacto que produce |
|---|---|---|---|
| 1 | `explorer` | Mapa read-only del terreno: qué existe, qué falta, riesgos, insumos faltantes | `00-explore.md` |
| 2 | `proposer` | 1–3 enfoques con reversibilidad y condiciones bloqueantes; ADR nace PROPUESTO | `01-proposal.md` (+ ADR propuesto) |
| 3 | `spec-writer` | Especificación verificable: criterios G/W/T numerados, bordes, contratos, fuera de alcance | `02-spec.md` |
| 4 | `designer` | Diseño por capa con imports declarados, plan de migración, amenazas con test asignado | `03-design.md` |
| 5 | `task-planner` | Tareas atómicas ordenadas con tipo, flag TDD, modelo, criterio de terminado, archivos previstos | `04-plan.md` |
| — | **GATE 1** | Humano aprueba spec + diseño + plan + amenazas con la palabra `acepto` | `gates.md` |
| 6 | `implementer` | Único que escribe código de producción; una tarea por vez; carga el protocolo `strict-tdd` | `05-apply-progress.md` + `tdd-evidence.log` (hook) |
| 7 | `verifier` | Checks mecánicos con salida literal; PASS/FAIL con recomendación por FAIL; no corrige | `06-verify.md` |
| 8 | `code-reviewer` | Revisión de código independiente: fidelidad al diseño, reglas de las skills, calidad de tests, duplicación, deuda; hallazgos por severidad | `07-review.md` |
| 9 | `security-reviewer` | Lectura adversarial del diff (y del diseño si toca auth/pagos/datos personales); riesgo residual | `07-security.md` |
| — | **GATE 2** | Humano decide merge: alcance, producto, riesgo residual, migración | `gates.md` |
| 10 | `archiver` | Post-merge: ADRs ratificados/enmendados, backlog, memoria sin datos personales, próximo paso | `08-close.md` |

`strict-tdd` **no es un agente**: es la skill/protocolo que el `implementer` carga en cada tarea con `TDD: ON`. Separarlo en otro subagente rompería el ciclo RED→GREEN a través de una frontera de contexto.

## 2. Niveles de uso

| Nivel | Cuándo | Recorrido |
|---|---|---|
| Completo | Feature nueva, cambio de esquema, migración, cualquier cosa que toque auth, pagos, datos personales o integraciones | Pipeline entero |
| Bugfix | Defecto acotado con test reproducible, sin cambio de contrato ni de esquema | `explorer` → `implementer` (TDD ON: el test que reproduce el bug es el RED) → `verifier` ∥ `code-reviewer` → GATE 2 |
| Trivial | Typo, comentario, copy, bump de patch sin cambio de API | Sin pipeline; commit directo bajo la skill `delivery-workflow` |

Si durante un bugfix aparece un cambio de contrato o de esquema, se detiene y se sube al nivel completo.

## 3. Protocolo de artefactos

Todo vive en `docs/sdd/<NNNN>-<slug>/` (número correlativo; el slug es el mismo de la rama). `docs/sdd/.current` contiene el nombre de la carpeta activa; lo escribe el `task-planner` y lo leen los hooks.

Reglas:
- Cada agente recibe **solo** las rutas de los artefactos previos y su tarea; nunca el historial de chat.
- Cada artefacto empieza con `RESUMEN` (≤ 10 líneas) para el agente siguiente y termina con `DUDAS ABIERTAS`.
- Ningún artefacto supera 150 líneas salvo `05-apply-progress.md`.
- Ningún artefacto contiene datos personales reales, secretos ni identificadores de producción. Los ejemplos son sintéticos. (Hook `guard-pii-artifacts` lo verifica.)
- El orquestador no arranca un agente si falta el artefacto previo.
- `07-review.md` y `07-security.md` son independientes entre sí y del `06-verify.md`; los tres entran juntos al GATE 2.
- `gates.md` registra cada gate: fecha, quién, veredicto (`APROBADO` / `CAMBIOS` / `RECHAZADO`), token explícito y observaciones. Un gate sin registro no ocurrió.

## 4. Gates

**GATE 1 — después del `task-planner`.** El humano aprueba la spec, el diseño, el plan y la tabla de amenazas juntos, porque el plan es lo que se va a ejecutar y el diseño es lo que se va a pagar. Antes del gate solo se escribe documentación; ningún archivo de código. Token: la palabra `acepto`. Sin token no hay implementación. Checklist en `gates/gate-1-design.md`.

**GATE 2 — después de `verifier` PASS, `code-reviewer` sin hallazgos altos (+ `security-reviewer` si corrió).** Contiene solo lo que la máquina no puede decidir: ¿es lo correcto para el producto?, ¿el diff coincide con lo aprobado en GATE 1?, ¿se acepta el riesgo residual?, ¿go/no-go de la migración?, ¿los ADRs quedaron firmados? Un FAIL del `verifier` nunca llega al gate. Checklist en `gates/gate-2-impl.md`.

## 5. Modelo por agente (valor por defecto; el proyecto puede subirlo, nunca bajarlo en agentes marcados ⬆)

| Agente | Modelo | Razón |
|---|---|---|
| explorer, spec-writer, task-planner, verifier, archiver | económico | Trabajo estructurado sobre insumos claros |
| proposer, designer ⬆ | capaz | Decisiones con trade-offs y reversibilidad |
| implementer | capaz para tareas de `domain`/`application`; económico para adapters/UI marcados así en el plan | El plan lo fija por tarea |
| code-reviewer ⬆, security-reviewer ⬆ | capaz | Lectura crítica y adversarial de código ajeno; el costo de un falso negativo es alto |

El modelo de planificación no implementa; el que implementa no se revisa ni se aprueba a sí mismo: `verifier`, `code-reviewer` y `security-reviewer` corren en contextos separados y solo reciben el diff y los artefactos, nunca el razonamiento del `implementer`.

## 6. Principios

1. **Skills primero.** Antes de escribir, el agente carga las skills de proceso de este core (`strict-tdd`, `delivery-workflow`), las del plugin de stack que apliquen y la skill local de invariantes del proyecto, si existe. La skill local prima sobre el default de los plugins.
2. **Nada se ratifica solo.** Un ADR nace `PROPUESTO` y solo un humano lo pasa a `ACEPTADO`. El `archiver` registra lo firmado; no firma.
3. **No romper lo verde.** Cada tarea deja typecheck, lint y tests en verde. Si el safety net falla antes de tocar nada, se reporta como falla preexistente y se para.
4. **Evidencia mecánica.** La evidencia TDD la captura un hook en `tdd-evidence.log`; la tabla del apply-progress la referencia. El `verifier` contrasta la tabla contra el log, no contra la palabra del `implementer`.
5. **Alcance cerrado.** El diff del PR debe corresponder a los archivos previstos en `04-plan.md` o justificar la diferencia. Scope creep es un FAIL.
6. **Datos personales y secretos fuera del proceso.** Ni en specs, ni en evidencia, ni en memoria, ni en commits, ni en ramas. El `explorer` nunca abre `.env*`, dumps ni seeds con datos reales; reporta que existen, no su contenido.
7. **Producción es de humanos.** Ninguna acción sobre producción sin OK humano explícito que nombre "producción". El hook `guard-prod` fuerza la confirmación.
8. **El PR dice qué, por qué y cómo se verificó.** Nada más (skill `delivery-workflow`). El resto vive en `docs/sdd/`.
