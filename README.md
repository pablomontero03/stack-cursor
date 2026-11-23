# stack-cursor

Stack de operación con agentes para Grupo Montecristo, versionado para usarse en Cursor.

Cursor no está instalado en este servidor. Esta carpeta es el proyecto: se abre desde Cursor en el PC, por Remote SSH, sobre `/home/cursor/stack-cursor`. En el servidor ya están `pwsh`, `az`, `kubectl` y `node`.

## Estado

Fase 1 cerrada el 2026-11-23. Hay esqueleto, contrato y el inventario de propósitos del stack Kiro. Las skills, los subagentes, las rules y los hooks todavía no están convertidos.

La fuente de verdad del comportamiento sigue siendo `/home/cursor/automation-kiro`. No se reescribe: se porta.

El avance y el propósito de cada skill, steering y subagente están en [docs/MIGRACION-CURSOR.md](docs/MIGRACION-CURSOR.md).

## Qué hay en este commit

- `AGENTS.md` — contrato operativo (SQL de solo lectura, plan, revisión, aprobación).
- `env/.env.example` — nombres de variables, sin valores reales.
- `.gitignore` — secretos y área de trabajo `.local/` fuera de git.
- `docs/MIGRACION-CURSOR.md` — checklist vivo e inventario fiel al stack Kiro.

## Secretos

Los valores reales van en `env/.env`, que no se versiona. No se copian claves, PEM ni tokens que hoy están trackeados por error en `automation-kiro`.
