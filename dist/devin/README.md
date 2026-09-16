# agentic-toolkit para Devin

Salida generada por `node bin/atk build --target=devin`. No editar a mano:
el contenido vive en `source/` del repositorio del toolkit.

## Instalación

1. Copiá `.agents/` a la raíz de tu repositorio y commiteá. Devin lo lee del repo.
2. Pegá el contenido de `AGENTS.md` en el `AGENTS.md` de tu repositorio.
3. Subí los 8 playbooks de `playbooks/*.devin.md` a Devin
   (arrastrarlos al iniciar una sesión, o crearlos en la web).
4. Opcional: cargá las 14 entradas de `knowledge/` en el Knowledge de
   Devin. El *trigger* de cada una es la línea "Cuándo aplica".

## Qué NO funciona acá

Devin no tiene hooks ni subagentes. Dos consecuencias, sin disimulo:

- **El pipeline corre en modo solo.** Una sesión adopta las diez fases en orden.
  No hay gatekeeper que deniegue lanzar una fase sin sus insumos: esa disciplina la
  sostiene el bucle de `ORCHESTRATOR-solo.md` §2.
- **Los guardrails son instructivos.** Producción, secretos, PII, comentarios,
  trailers de IA y evidencia TDD están escritos como reglas en `AGENTS.md`, y Devin
  puede no cumplirlas. Fue una decisión explícita del toolkit: no se agrega
  enforcement por CI ni por pre-commit.

Si necesitás que se hagan cumplir de verdad, el camino es un job de CI en tu
repositorio, fuera del alcance de este toolkit.
