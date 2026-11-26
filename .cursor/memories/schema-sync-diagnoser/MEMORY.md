# Memoria — schema-sync-diagnoser

## Propósito

Diagnosticar fallos de corridas de Schema Sync (SqlPackage, DacFx, SSDT,
Git, Azure DevOps, n8n) a partir de result JSON y logs, en modo solo
lectura, sin volver a ejecutar la corrida.

## Alcance de la memoria

Aprendizajes reutilizables de diagnóstico específicos de Schema Sync
(causas raíz confirmadas, patrones de fallo recurrentes). No duplica el
procedimiento completo, que vive en
`.claude/agents/schema-sync-db/schema-sync-diagnoser.md`,
`schema-sync/CONTEXTO-COMPLETO.md` y `.claude/skills/manage-schema-sync-ssdt/SKILL.md`.

## Enlaces

- [Diagnóstico](./debugging.md)
- [Patrones](./patterns.md)

## Aprendizajes esenciales

Ninguno todavía. Este archivo se actualiza solo cuando exista una
modificación real.

## Regla operacional: no ejecutar setup.sh de Kiro
Confirmado en producción 2026-09-21. No ejecutar `setup-kiro.sh`. `./setup-cursor.sh` no reinicia el worker.

**Siempre usar en sesiones activas de Crew:**
```bash
set -a; source /home/cursor/stack-cursor/env/.env; set +a
export REPO_ROOT=/home/cursor/stack-cursor
```
O con el flag seguro: `set -a; source env/.env; set +a`

No ejecutar `source ./setup.sh`. Para variables: `set -a; source env/.env; set +a`.
