# Patterns — aks-diagnoser

## Clústeres reales de este proyecto viven en kubeconfigs de Lens

Confirmado 2026-08-26 — mismo hallazgo que en la memoria de
`aks-operator` (ver ese archivo para la tabla completa). Resumen: NO usar
la resolución ambiente por defecto (`$env:USERPROFILE\.kube\config`
apunta a un clúster ajeno, `gmon-innovacion-aks-eastus2-0001`). Los reales
son 3 kubeconfigs bajo `$env:APPDATA\Lens\kubeconfigs\`: 1 desarrollo
(k3s, nodo único `srv-desarrollo-5`) y 2 con clústeres AKS de dev/qa/prod
(incluido `gmon-prod-aks-eastus2-0004`, ya conocido de los pipelines ADO
de este proyecto).

**How to apply:** cualquier diagnóstico pedido "sobre el cluster de
desarrollo/producción" debe resolver primero CUÁL de los 3 kubeconfigs y
qué contexto usar (el mismo nombre de contexto puede repetirse entre los
2 archivos de prod) — nunca asumir el kubeconfig por defecto de la
máquina. `Test-AksEnvironment.ps1` reporta la lista y sus contextos.
