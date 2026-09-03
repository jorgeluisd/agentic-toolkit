---
name: sdd-pipeline
description: "Cómo se ejecuta cualquier cambio de código: el pipeline SDD+TDD de sdd-tdd-core con agentes, gates y artefactos, por nivel (completo, bugfix, trivial). Usar cuando el usuario pide implementar, agregar, crear, cambiar, arreglar o migrar algo en el código, aunque no invoque ningún comando."
---

# El pipeline es la forma de trabajar, no un comando opcional

Cuando el usuario pide un cambio de código en lenguaje natural ("agrega un endpoint", "arregla el bug de X", "implementa la feature Y", "migra la tabla Z"), **no se implementa directo**. Se hace exactamente lo que haría `/sdd-tdd-core:sdd <objetivo>`: leer `ORCHESTRATOR.md` del plugin, clasificar el nivel y lanzar los agentes en orden con artefactos en `docs/sdd/<NNNN>-<slug>/`.

Si el usuario escribe "con sdd", "usa sdd+tdd", "con tdd" o "por el pipeline", no hay nada que interpretar: es una orden explícita de ejecutar el pipeline en nivel completo (o bugfix si además lo dice).

## 1. Clasificar antes de tocar nada

| Nivel | Señales en el pedido | Recorrido |
|---|---|---|
| **Completo** | feature nueva, endpoint nuevo, cambio de esquema o migración, cualquier cosa que toque auth, pagos, datos personales, integraciones, contratos públicos | `explorer` → `proposer` → `spec-writer` → `designer` → `task-planner` → **GATE 1** (`acepto`) → `implementer` por tarea → `verifier` ∥ `code-reviewer` ∥ `security-reviewer` → `/sdd-tdd-core:pr-draft` → **GATE 2** → `archiver` |
| **Bugfix** | defecto acotado y reproducible, sin cambio de contrato ni de esquema | `explorer` → `implementer` (TDD ON: el test que reproduce el bug es el RED) → `verifier` ∥ `code-reviewer` → **GATE 2** |
| **Trivial** | typo, copy, comentario, bump de patch sin cambio de API, cambio de una línea sin lógica | Sin pipeline; commit bajo `delivery-workflow` |

Ante la duda entre dos niveles, se elige el más alto. Si un bugfix revela un cambio de contrato o de esquema, se detiene y sube a completo.

## 2. Qué decirle al usuario

Antes de lanzar el primer agente, una línea: "Esto es nivel **<completo|bugfix|trivial>**: <razón en 10 palabras>. Arranco el pipeline en `docs/sdd/<NNNN>-<slug>/`." Si el usuario responde que lo quiere directo sin pipeline, se hace **solo en nivel trivial**; en los otros dos se explica por qué no (sin spec no hay tests que prueben el comportamiento; sin gate no hay decisión humana registrada) y se ofrece el nivel bugfix como mínimo.

## 3. Reglas que no cambian por venir en lenguaje natural

- Cada agente recibe rutas de artefactos, nunca el historial del chat.
- Ningún archivo de código antes del `acepto` del GATE 1 (nivel completo).
- Un FAIL del `verifier` o un hallazgo alto del `code-reviewer` nunca llega al GATE 2.
- No se commitea, mergea ni pushea sin pedido explícito; el PR se redacta con `/sdd-tdd-core:pr-draft`.
- El `CLAUDE.md` del proyecto y su skill local de invariantes priman sobre cualquier default del plugin.

## 4. Cómo se verifica que se aplicó

Existe `docs/sdd/<NNNN>-<slug>/` con `gates.md` registrado. Si un cambio de código de nivel completo o bugfix llega a un PR sin esa carpeta, el pipeline no se ejecutó: el `verifier` lo reporta como FAIL de proceso.
