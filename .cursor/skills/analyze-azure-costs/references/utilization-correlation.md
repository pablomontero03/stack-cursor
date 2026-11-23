# Correlación costo ↔ utilización

## Objetivo

Combinar el costo de un recurso (Cost Management, agrupado por
`ResourceId`) con su utilización real (Azure Monitor Metrics) y sus
metadatos (Resource Graph: SKU, tags, resource group) para identificar:
capacidad ociosa/sobredimensionada, recursos detenidos que siguen
generando costo, y candidatos a cambio de SKU o apagado.

## Método

1. `Get-AzureCostInventory.ps1` — inventario de recursos con SKU/tags/RG.
2. `Invoke-AzureCostQuery.ps1 -GroupBy ResourceId` — costo por recurso en
   el período.
3. `Get-AzureResourceMetrics.ps1` — métricas de utilización relevantes
   por tipo de recurso (ver tabla abajo) para el mismo período.
4. Unir por `resourceId` (normalizar a minúsculas — Azure a veces
   devuelve el mismo ID con distinto casing entre APIs).
5. Clasificar: alto costo + baja utilización → candidato a
   reducir/apagar; costo estable + utilización cercana al límite →
   candidato a aumentar (evitar degradación, no es un hallazgo de
   ahorro).

## Métricas relevantes por tipo de recurso

| Tipo de recurso | Métricas típicas |
|---|---|
| Virtual Machines / VMSS | `Percentage CPU`, `Available Memory Bytes` (requiere Azure Monitor Agent), `Network In/Out Total`, `Disk Read/Write Bytes` |
| AKS (node pools) | `node_cpu_usage_percentage`, `node_memory_working_set_percentage` (Container Insights), o métricas del VMSS subyacente |
| Azure SQL / SQL MI | `dtu_consumption_percent` / `cpu_percent`, `storage_percent`, `sessions_percent` |
| App Service / Functions | `CpuPercentage`, `MemoryPercentage`, `Requests`, `Http5xx` |
| Storage Accounts | `Transactions`, `Ingress`, `Egress`, `UsedCapacity` |
| Azure OpenAI | `TokenTransaction`, `AzureOpenAIRequests`, `TimeToResponseTokens` (si expuestas) |
| Application Gateway / Load Balancer | `Throughput`, `HealthyHostCount`, `ByteCount` |

## Señales de desperdicio a buscar

- Recursos con `provisioningState`/power state detenido (`deallocated`,
  `stopped`) que Resource Graph sigue listando — verificar si Cost
  Management todavía les atribuye costo (discos/IPs asociados siguen
  facturando aunque la VM esté apagada).
- Discos, snapshots, IPs públicas o NICs sin asociación a un recurso en
  uso (`Get-AzureCostInventory.ps1` + Resource Graph para detectar
  huérfanos).
- SKU cuya utilización pico del período está muy por debajo de su
  capacidad (ej. una VM D8s con CPU pico <20%).
- Costos de red/transferencia de datos anómalamente altos frente al
  tráfico esperado del servicio.
- Log Analytics con retención larga configurada pero consultas mínimas.
- Backups o storage redundante (GRS/ZRS) en recursos donde el RPO/RTO
  real no lo justifica.

## Límites del método — declarar siempre

- Azure Monitor Metrics no cubre el 100% de los tipos de recurso ni toda
  la granularidad deseada — si una métrica no está disponible, reportar
  el recurso igual (por costo) pero marcar la utilización como "dato no
  disponible", nunca asumir que está ocioso sin evidencia.
- Un período corto (pocos días) puede no representar el patrón real de
  uso (ej. picos mensuales, procesos batch) — declarar la ventana
  analizada y sugerir un período más largo si la evidencia es débil.
