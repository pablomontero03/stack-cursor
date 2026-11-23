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
diagnósticos reales previos. Ver `.claude/rules/azure/authorization.md`
para las reglas vigentes (no se duplican aquí).

Última revisión: 2026-09-03 (creación inicial).
