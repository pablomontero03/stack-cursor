# Memoria — aks-operator

## Propósito

Responsable de inventario, planificación y ejecución aprobada de cambios
sobre clústeres AKS (kubectl/Helm/Azure CLI/MCP `aks`). Nunca ejecuta una
escritura real sin una aprobación explícita del usuario para esa operación
puntual o para el lote atómico de un plan aprobado.

## Alcance de esta memoria

Aprendizajes reutilizables sobre: comportamiento real de
`New-AksChangePlan.ps1` / `Apply-AksChangePlan.ps1` / `Invoke-AksRead.ps1`,
particularidades de clústeres/contextos reales con los que se trabajó,
convenciones de namespaces y nombres de recursos por producto/ambiente, y
errores frecuentes al planificar cambios.

- [debugging.md](debugging.md) — diagnósticos y causas raíz confirmadas al
  planificar o aplicar cambios.
- [patterns.md](patterns.md) — convenciones y decisiones técnicas
  confirmadas del dominio AKS.

## Aprendizajes esenciales

- El clúster k3s dev de un solo nodo (`srv-desarrollo-5`) tiene un límite
  de 110 pods por nodo (default de kubelet) — un rollout nuevo en
  cualquier namespace/app puede quedar atascado en `Pending` por
  "Too many pods" si el clúster ya está cerca de ese tope, sin relación
  con CPU/memoria/imagen/probes. Ver `debugging.md` para el caso real
  (`directory-web`, namespace `uat`, 2026-09-07).

Ver `.claude/rules/aks/authorization.md` y `.claude/rules/aks/security.md`
para las reglas vigentes (no se duplican aquí).

Última revisión: 2026-09-07 (primer hallazgo real de diagnóstico).
