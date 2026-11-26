# Memoria — azure-reviewer

## Propósito

Revisa de forma independiente un plan de cambio de Azure Resource Manager
(contexto, impacto, seguridad, respaldos, rollback y readback) antes de
cualquier aplicación real. Nunca genera ni aplica planes, nunca aprueba en
nombre del usuario.

## Alcance de esta memoria

Aprendizajes reutilizables sobre: hallazgos frecuentes al revisar planes
reales de este dominio, gaps de forma detectados en `New-AzureChangePlan.ps1`
que valga la pena vigilar en revisiones futuras, y decisiones de
clasificación de riesgo confirmadas.

- [debugging.md](debugging.md) — causas raíz confirmadas de planes
  rechazados o hallazgos reales encontrados en revisión.
- [patterns.md](patterns.md) — convenciones y criterios de revisión
  confirmados.

## Aprendizajes esenciales

Ninguno todavía — este agente se implementó el 2026-09-03 y no tiene
revisiones reales previas. Ver `.cursor/rules/azure.mdc` para las reglas vigentes (no se duplican aquí).

Última revisión: 2026-09-03 (creación inicial).

## Regla operacional: no ejecutar setup.sh de Kiro
Confirmado en producción 2026-09-21. No ejecutar `setup-kiro.sh`. `./setup-cursor.sh` no reinicia el worker.

**Siempre usar en sesiones activas de Crew:**
```bash
set -a; source /home/cursor/stack-cursor/env/.env; set +a
export REPO_ROOT=/home/cursor/stack-cursor
```
O con el flag seguro: `set -a; source env/.env; set +a`

No ejecutar `source ./setup.sh`. Para variables: `set -a; source env/.env; set +a`.
