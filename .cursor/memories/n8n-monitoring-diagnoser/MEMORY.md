# Memoria — n8n-monitoring-diagnoser

## Propósito

Diagnosticar ejecuciones fallidas de workflows n8n de monitoreo SQL
(instancia `n8n-interno`, `172.16.2.60:5678`) o del workflow de IA
`AIA-CC-MAIA-Chat` (instancia `n8n-productivo`,
automation.grupomontecristo.com — **no** `n8n-interno`), en modo solo
lectura, sin reintentar ni modificar nada.

## Alcance de la memoria

Causas raíz recurrentes ya vistas al diagnosticar ejecuciones de este
dominio. No duplica el proceso completo, que vive en
`.claude/agents/n8n-monitoring/n8n-monitoring-diagnoser.md` y
`docs/n8n-monitoring/N8N-API-RUNBOOK.md` (que ya trae su propia bitácora
de incidentes diagnosticados en el runbook original).

## Enlaces

- [Diagnóstico](./debugging.md)
- [Patrones](./patterns.md)

## Aprendizajes esenciales

- Este agente cubre dos instancias n8n distintas, no una sola: monitoreo
  SQL vía MCP `n8n-interno` (`172.16.2.60:5678`); `AIA-CC-MAIA-Chat` vía
  MCP `n8n-productivo` (`automation.grupomontecristo.com`). No asumir que
  ambos casos comparten instancia — confirmar cuál corresponde antes de
  interpretar datos ya obtenidos por quien invoca.

Última revisión: 2026-08-20 (corrección: MAIA vive en `n8n-productivo`,
no en `n8n-interno` como se documentó por error inicialmente).

## Regla operacional: no ejecutar setup.sh de Kiro
Confirmado en producción 2026-09-21. No ejecutar `setup-kiro.sh`. `./setup-cursor.sh` no reinicia el worker.

**Siempre usar en sesiones activas de Crew:**
```bash
set -a; source /home/cursor/stack-cursor/env/.env; set +a
export REPO_ROOT=/home/cursor/stack-cursor
```
O con el flag seguro: `set -a; source env/.env; set +a`

No ejecutar `source ./setup.sh`. Para variables: `set -a; source env/.env; set +a`.
