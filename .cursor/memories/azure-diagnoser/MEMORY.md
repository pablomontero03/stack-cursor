# Memoria — azure-diagnoser

## Propósito

Diagnóstico de solo lectura de recursos de Azure Resource Manager —
Activity Log, estado de recursos, Resource Graph, locks, RBAC, redes y
salud general. Nunca aplica una corrección; deriva cualquier corrección
propuesta al flujo de `azure-operator`.

## Alcance de esta memoria

Aprendizajes reutilizables sobre: patrones de fallo reales encontrados en
recursos Azure de este proyecto, particularidades de tenants/
suscripciones/recursos con los que se trabajó, y causas raíz frecuentes
por tipo de recurso.

- [debugging.md](debugging.md) — diagnósticos y causas raíz confirmadas.
- [patterns.md](patterns.md) — convenciones y decisiones técnicas
  confirmadas.

## Aprendizajes esenciales

Ninguno todavía — este agente se implementó el 2026-09-03 y no tiene
diagnósticos reales previos. Ver `.cursor/rules/azure.mdc`
para las reglas vigentes (no se duplican aquí).

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
