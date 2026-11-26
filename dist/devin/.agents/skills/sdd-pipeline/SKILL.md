---
name: sdd-pipeline
description: "Cómo se ejecuta cualquier cambio de código: el pipeline SDD+TDD de sdd-tdd-core con agentes, gates y artefactos, por nivel (completo, bugfix, trivial). Usar cuando el usuario pide implementar, agregar, crear, cambiar, arreglar o migrar algo en el código, aunque no invoque ningún comando."
---

# El pipeline es la forma de trabajar, no un comando opcional

Cuando el usuario pide un cambio de código en lenguaje natural ("agrega un endpoint", "arregla el bug de X", "implementa la feature Y", "migra la tabla Z"), **no se implementa directo**. Se hace exactamente lo que haría `playbook sdd <objetivo>`: leer `ORCHESTRATOR-solo.md` del plugin, clasificar el nivel y correr las fases en orden con artefactos en `docs/sdd/<NNNN>-<slug>/`.

Si el usuario escribe "con sdd", "usa sdd+tdd", "con tdd" o "por el pipeline", no hay nada que interpretar: es una orden explícita de ejecutar el pipeline en nivel completo (o bugfix si además lo dice).

## 1. Clasificar antes de tocar nada

| Nivel | Señales en el pedido | Recorrido |
|---|---|---|
| **Completo** | feature nueva, endpoint nuevo, cambio de esquema o migración, cualquier cosa que toque auth, pagos, datos personales, integraciones, contratos públicos — o un cambio que **no pasa el test de reanudación** | lite: `explorer` → (`proposer` si hay decisión) → `designer` → **GATE 1** (`acepto`) → `implementer` por tarea → revisores según `review-plan.sh` → `playbook pr-draft` → **GATE 2** → `archiver` |
| **Bugfix** | defecto acotado y reproducible que pasa el test de reanudación, sin cambio de contrato ni de esquema | `explorer` (escribe `S1` y `T1`) → `implementer` (TDD ON: el test que reproduce el bug es el RED) → `verifier` ∥ `code-reviewer` → **GATE 2** |
| **Trivial** | typo, copy, comentario, bump de patch sin cambio de API, cambio de una línea sin lógica | Sin pipeline; commit bajo `delivery-workflow` |

**Test de reanudación:** si la sesión se corta ahora, ¿otra sesión terminaría el trabajo con solo el pedido y el `git diff`? Si no, hay decisiones que tienen que quedar escritas: nivel completo. La cantidad de archivos no decide el nivel.

Ante la duda entre dos niveles, se elige el más alto. Si un bugfix revela un cambio de contrato o de esquema, se detiene y sube a completo.

## 2. Qué decirle al usuario

Antes de lanzar el primer agente, una línea: "Esto es nivel **<completo|bugfix|trivial>**: <razón en 10 palabras>. Arranco el pipeline en `docs/sdd/<NNNN>-<slug>/`." Si el usuario responde que lo quiere directo sin pipeline, se hace **solo en nivel trivial**; en los otros dos se explica por qué no (sin spec no hay tests que prueben el comportamiento; sin gate no hay decisión humana registrada) y se ofrece el nivel bugfix como mínimo.

## 3. Reglas que no cambian por venir en lenguaje natural

- El pedido del humano entra **textual** como `L1` en el `## Log` de `feature.md` antes de la primera fase.
- Cada agente recibe una referencia (`Spec: <ruta>/feature.md (lee hasta ## Log). Haz T3; S2.`), nunca el historial del chat ni una paráfrasis.
- Ningún archivo de código antes del `acepto` del GATE 1 (nivel completo).
- Un FAIL del `verifier` o un hallazgo alto del `code-reviewer` nunca llega al GATE 2.
- Los commits en la rama de feature son autónomos (uno por tarea en verde); push, PR y merge los autoriza el humano. El PR se redacta con `playbook pr-draft`.
- El `AGENTS.md` del proyecto y su skill local de invariantes priman sobre cualquier default del plugin.

## 4. Cómo se verifica que se aplicó

Existe `docs/sdd/<NNNN>-<slug>/` con `feature.md` (o los artefactos classic) y `gates.md` registrado. Si un cambio de código de nivel completo o bugfix llega a un PR sin esa carpeta, el pipeline no se ejecutó: el `verifier` lo reporta como FAIL de proceso.
