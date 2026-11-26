# Referencia KQL + Azure Resource Graph (diagnóstico)

> Material de **consulta rápida**, no un procedimiento. Extraído y adaptado del skill
> público `microsoft/azure-skills/azure-diagnostics` (MIT, v1.2.6) el 2026-10-02.
> No instalamos el skill (ver análisis en el chat); solo rescatamos estas queries.

## Contexto del stack (automation-kiro)

- **Solo lectura.** Estas queries son diagnóstico/lectura. `az graph query` y
  `az monitor app-insights query` NO escriben. Toda BD SQL sigue siendo solo lectura.
- **MCP `azure` oficial diferido:** el skill original asume `mcp_azure_mcp_*`
  (AppLens, monitor, resourcehealth). Aquí NO existen — usamos `az` CLI directo.
- Suscripción por defecto: `Hospital Metropolitano`
  (`69dc43ec-5f24-4203-9239-a8d0f8506d44`), tenant `Grupo Montecristo`
  (`33dd4184-3068-47da-891d-a70e02f8c0c9`). Confirmar siempre contra inventario vivo.
- Requisito ARG: `az extension add --name resource-graph` (una vez).
- Para diagnóstico de AKS preferir el MCP `aks` (`aks_monitoring`, `aks_detector`)
  sobre estas queries genéricas; esto es para el plano ARM.

---

## Azure Resource Graph (`az graph query`) — APLICA HOY

Patrón base:

```bash
az graph query -q "<KQL>" --subscriptions 69dc43ec-5f24-4203-9239-a8d0f8506d44 \
  --query "data[]" -o table
# --first N para limitar; --subscriptions para acotar scope
```

### Estado de salud de recursos (resource health)

```kql
HealthResources
| where type =~ 'microsoft.resourcehealth/availabilitystatuses'
| project name, availabilityState=properties.availabilityState, reasonType=properties.reasonType
```

### Recursos NO disponibles o degradados

```kql
HealthResources
| where type =~ 'microsoft.resourcehealth/availabilitystatuses'
| where properties.availabilityState != 'Available'
| project name, state=properties.availabilityState, reason=properties.reasonType, summary=properties.summary
```

### Incidentes de Azure Service Health activos

```kql
ServiceHealthResources
| where type =~ 'microsoft.resourcehealth/events'
| where properties.Status == 'Active'
| project name, title=properties.Title, impact=properties.Impact, status=properties.Status
```

### Despliegues fallidos o atascados (provisioningState)

```kql
Resources
| where properties.provisioningState != 'Succeeded'
| project name, type, resourceGroup, provisioningState=properties.provisioningState
```

### Tablas clave de ARG

| Tabla | Contiene |
|-------|----------|
| `Resources` | Todos los recursos ARM (name, type, location, properties, tags) |
| `HealthResources` | Estado de disponibilidad (resource health) |
| `ServiceHealthResources` | Eventos/incidentes de Azure Service Health |
| `ResourceContainers` | Suscripciones, resource groups, management groups |

**Tips ARG:** `=~` para match case-insensitive (los types van en minúscula);
navegar propiedades con `properties.campo`; chequear `HealthResources` ANTES de
bucear en logs de aplicación.

---

## KQL App Insights / Log Analytics — SOLO SI el recurso lo tiene

> Hoy Buklo corre en Deployments de k3s/AKS, no en App Service. Estas queries aplican
> solo a recursos con Application Insights / Log Analytics configurado y diagnostic
> settings habilitado. Para pods usar el MCP `aks` (logs, detectors, inspektor-gadget).

Patrón: `az monitor app-insights query --apps <APP-INSIGHTS> -g <RG> --analytics-query "<KQL>"`

### Errores recientes

```kql
AppExceptions
| where TimeGenerated > ago(1h)
| project TimeGenerated, Message, StackTrace
| order by TimeGenerated desc
```

### Requests fallidos

```kql
AppRequests
| where Success == false
| where TimeGenerated > ago(1h)
| summarize count() by Name, ResultCode
| order by count_ desc
```

### Requests lentos (>5s)

```kql
AppRequests
| where TimeGenerated > ago(1h)
| where DurationMs > 5000
| project TimeGenerated, Name, DurationMs
| order by DurationMs desc
```

### Fallas de dependencias

```kql
AppDependencies
| where Success == false
| where TimeGenerated > ago(1h)
| summarize count() by Name, ResultCode, Target
```

**Tips KQL:** incluir siempre filtro de tiempo (`TimeGenerated > ago(Xh)`);
limitar con `take 50`; agregar con `summarize` antes de analizar.

---

## Referencias upstream

- [KQL Quick Reference (MS Learn)](https://learn.microsoft.com/azure/data-explorer/kql-quick-reference)
- [Application Insights Queries (MS Learn)](https://learn.microsoft.com/azure/azure-monitor/logs/queries)
- Fuente: skill `microsoft/azure-skills/azure-diagnostics` (`references/kql-queries.md`, `references/azure-resource-graph.md`)
