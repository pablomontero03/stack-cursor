# Respaldo — nodo `Set - Params` original de los 3 monitores AKS (n8n-interno)
Fecha: 2026-09-18 16:31 CST
Motivo: antes de agregar el cluster `prod-onprem-01` al array `clusters`.
Instancia: n8n-interno (http://172.16.2.60:5678)

Solo se modifica el array `clusters` dentro del nodo `Set - Params` (jsonOutput).
Ningún otro nodo, conexión ni lógica cambia. Estado `clusters` ANTES del cambio
(idéntico en los 3 workflows): 3 entradas.

## Workflows afectados
| Workflow | ID | Trigger | clusters ANTES |
|---|---|---|---|
| AKS - Pod CPU Memory Usage Monitor | Hz7cAOVyqT0YYlEe | cada 1 min | 3 |
| AKS - PVC Disk Usage Monitor | 98B9ifB6yQCUSpA4 | cada 15 min | 3 |
| AKS - Pod Restart Monitor | 05BjFKmWmDiD5CI9 | cada 4 min | 3 |

## Array `clusters` ORIGINAL (los 3 lo comparten idéntico)
```json
"clusters": [
  {
    "clusterName": "lens-pasted-kubeconfig-9d0413cb",
    "clusterFriendlyName": "cluster desarrollo",
    "authMode": "kubeconfig",
    "kubeconfigFile": "/home/node/.kube/lens-pasted-kubeconfig.yaml"
  },
  {
    "clusterName": "gmon-prod-aks-eastus2-0001",
    "clusterFriendlyName": "AKS - gmon-prod-aks-eastus2-0001",
    "authMode": "az",
    "resourceGroup": "gmon_prod_rg_eastus2_0001"
  },
  {
    "clusterName": "gmon-prod-aks-eastus2-0004",
    "clusterFriendlyName": "AKS - gmon-prod-aks-eastus2-0004",
    "authMode": "az",
    "resourceGroup": "gmon_prod_rg_eastus2_0001"
  }
]
```

## Entrada NUEVA a agregar (4ta, sin tocar las 3 existentes)
```json
{
  "clusterName": "prod-onprem-01",
  "clusterFriendlyName": "k3s prod on-prem (.31)",
  "authMode": "kubeconfig",
  "kubeconfigFile": "/home/node/.kube/prod-onprem-01.yaml"
}
```

## Rollback
Volver el array `clusters` a las 3 entradas originales de arriba en el nodo
`Set - Params` de cada workflow. Nada más cambia.
