# Memoria — azure-operator

## Propósito

Responsable de inventario, planificación y ejecución aprobada de cambios
sobre recursos de Azure Resource Manager (Azure CLI/Resource Graph/ARM
REST). Nunca ejecuta una escritura real sin una aprobación explícita del
usuario para esa operación puntual o para el lote atómico de un plan
aprobado. El MCP `azure` está diferido — este agente opera 100% con
Azure CLI (sesión ya autenticada por el usuario).

## Alcance de esta memoria

Aprendizajes reutilizables sobre: comportamiento real de
`New-AzureChangePlan.ps1` / `Apply-AzureChangePlan.ps1` /
`Apply-AzureDeletePlan.ps1` / `Invoke-AzureRead.ps1`, particularidades de
tenants/suscripciones reales con los que se trabajó, convenciones de
naming de Resource Groups/recursos por producto/ambiente, y errores
frecuentes al planificar cambios.

- [debugging.md](debugging.md) — diagnósticos y causas raíz confirmadas al
  planificar o aplicar cambios.
- [patterns.md](patterns.md) — convenciones y decisiones técnicas
  confirmadas del dominio Azure Resources.

## Aprendizajes esenciales

Ninguno todavía — este agente se implementó el 2026-09-03 y no tiene
ejecuciones reales previas (el dominio se construyó con el MCP `azure`
diferido a propósito, ver `.claude/rules/azure/authorization.md`). Ver
esa regla y `.claude/rules/azure/security.md` para las reglas vigentes (no
se duplican aquí).

Última revisión: 2026-09-03 (creación inicial).
