# Memoria — n8n-monitoring-reviewer

## Propósito

Revisión independiente, solo lectura, de clones de packs de monitoreo SQL
(`n8n-interno`) y de cambios masivos (ej. timeouts) sobre
`AIA-CC-MAIA-Chat` (`n8n-productivo` — instancia distinta), antes de que se
apliquen.

## Alcance de la memoria

Hallazgos recurrentes y falsos positivos identificados al revisar clones o
cambios masivos. No duplica el checklist completo, que vive en
`.claude/agents/n8n-monitoring/n8n-monitoring-reviewer.md`,
`docs/n8n-monitoring/CLONE-INSTANCIA-SQL.md` y
`docs/n8n-monitoring/MAIA-timeouts-recomendados.md`.

## Enlaces

- [Diagnóstico](./debugging.md)
- [Patrones](./patterns.md)

## Aprendizajes esenciales

- El conteo de workflows de un pack a clonar no es fijo (no asumir ~10 ni
  ningún número): siempre viene de un listado dinámico real de la carpeta
  origen.
- `AIA-CC-MAIA-Chat` vive en `n8n-productivo`, no en `n8n-interno` — no
  asumir que un cambio masivo de timeouts sobre ese workflow usa la misma
  instancia que un clon de pack SQL.

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
