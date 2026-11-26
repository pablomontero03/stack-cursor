# Memoria — schema-sync-reviewer

## Propósito

Revisión independiente, solo lectura, de cambios de Schema Sync, SSDT,
catálogos y workflows n8n, con énfasis en que ninguna ruta pueda escribir
en SQL y en que los mappings BD/repo/proyecto/workflow sean correctos.

## Alcance de la memoria

Hallazgos recurrentes de revisión y falsos positivos identificados al
revisar cambios de Schema Sync. No duplica el checklist completo, que vive
en `.claude/agents/schema-sync-db/schema-sync-reviewer.md` y
`schema-sync/CONTEXTO-COMPLETO.md`.

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
