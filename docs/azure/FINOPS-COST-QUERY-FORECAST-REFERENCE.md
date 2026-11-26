# Referencia FinOps — Cost Management + ARG (para uso del agente)

> Material de **consulta operativa** para el sub-skill `analyze-azure-costs`.
> Extraído y adaptado del skill público `microsoft/azure-skills/azure-cost`
> (MIT, v1.3.1) el 2026-10-02. NO instalamos el bundle; rescatamos las partes que
> el agente puede usar directamente al operar.
>
> **Clave:** el skill original expone estos flujos vía el MCP `azure` oficial
> (`query_costs`, `forecast_costs`, ARM MCP). Aquí ese MCP está **diferido**, así que
> todo está traducido al patrón que SÍ usamos: `az rest` contra Cost Management
> (ya clasificado como lectura en la steering) y `az graph query` para ARG.

## Contexto del stack (automation-kiro)

- **Solo lectura / análisis.** FinOps solo analiza y recomienda; los cambios de
  optimización van al flujo estándar de Azure (plan→aprobación→apply). `az rest
  --method post` contra Cost Management Query/Forecast = lectura.
- Suscripción objetivo FinOps: `Hospital Metropolitano`
  (`69dc43ec-5f24-4203-9239-a8d0f8506d44`), tenant `Grupo Montecristo`.
- Roles necesarios en el scope: Cost Management Reader + Monitoring Reader + Reader.
- Datos financieros → `.local/azure/finops/` (no versionado). Nunca en docs versionados.
- **Restricción dura:** `pref.k8s.no_new_nodes_cost_frozen` — no agregar nodos AKS.
  Las recomendaciones de optimización que impliquen reescalar/añadir cómputo AKS
  se reportan, no se aplican como efecto colateral.

---

## 1. Cost Query — costos históricos

**API:** `POST {scope}/providers/Microsoft.CostManagement/query?api-version=2023-11-01`

Scopes:
- Suscripción: `/subscriptions/<id>`
- Resource Group: `/subscriptions/<id>/resourceGroups/<name>`
- Management Group: `/providers/Microsoft.Management/managementGroups/<id>`
- Billing Account: `/providers/Microsoft.Billing/billingAccounts/<id>`

Patrón con `az rest` (lectura):

```bash
SCOPE="/subscriptions/69dc43ec-5f24-4203-9239-a8d0f8506d44"
az rest --method post \
  --url "https://management.azure.com${SCOPE}/providers/Microsoft.CostManagement/query?api-version=2023-11-01" \
  --body @body.json
```

### Parámetros / contrato de un Query

| Campo | Valores |
|---|---|
| `timeframe` | `MonthToDate`, `BillingMonthToDate`, `TheLastMonth`, `TheLastBillingMonth`, `WeekToDate`, `TheCurrentMonth`, `Custom` |
| `timePeriod.from` / `.to` | `YYYY-MM-DD` (requiere `timeframe=Custom`) |
| `dataset.granularity` | `None` (default), `Daily`, `Monthly` |
| `dataset.aggregation` | p.ej. `{"totalCost":{"name":"PreTaxCost","function":"Sum"}}` |
| `dataset.grouping` | hasta **5** dimensiones |
| métrica | `PreTaxCost` (default), `Cost`, `AmortizedCost` |
| `top` | 1–5000 (default 100) |

Body JSON ejemplo (costo por servicio, mes en curso):

```json
{
  "type": "ActualCost",
  "timeframe": "MonthToDate",
  "dataset": {
    "granularity": "None",
    "aggregation": { "totalCost": { "name": "PreTaxCost", "function": "Sum" } },
    "grouping": [ { "type": "Dimension", "name": "ServiceName" } ]
  }
}
```

### Dimensiones válidas (whitelist)

**En todos los scopes:** `ServiceName`, `ServiceTier`, `ChargeType`, `PublisherType`,
`PricingModel`, `BenefitName`, `BenefitId`, `Frequency`, `SubscriptionName`,
`SubscriptionId`, `ReservationId`, `ReservationName`, `BillingPeriod`,
`BillingAccountName`, `BillingProfileName`, `InvoiceNumber`, `DepartmentName`,
`EnrollmentAccountName`, `CustomerName`, `InvoiceSectionName`, `PartNumber`.

**Solo scope suscripción / resource-group:** `ResourceGroupName`, `ResourceGroup`,
`ResourceType`, `ResourceId`, `ResourceLocation`, `ResourceGuid`, `MeterCategory`,
`MeterSubCategory`, `Meter`.

Notas de acuerdo: `DepartmentName`/`EnrollmentAccountName` → Enterprise Agreement;
`BillingProfileName`/`InvoiceSectionName` → Microsoft Customer Agreement.

**Leer la respuesta por índice de columna, no por orden fijo** (la API devuelve
`columns` + `rows`; mapear cada fila contra su columna, incluyendo moneda).

---

## 2. Cost Forecast — proyección

**API:** `POST {scope}/providers/Microsoft.CostManagement/forecast?api-version=2023-11-01`

| Parámetro | Requerido | Valores |
|---|---|---|
| `scope` | sí | path de scope Azure |
| `from` / `to` | juntos | `YYYY-MM-DD`; default = límites del mes actual |
| `granularity` | no | `Daily` (default), `Monthly` |
| `filterDimension` + `filterValues` | juntos | una dimensión del whitelist + valores exactos CSV |
| métrica | no | `PreTaxCost` (default), `Cost`, `AmortizedCost` |

El servidor fija `timeframe=Custom` y usa el mismo whitelist de dimensiones que el
Query. La respuesta incluye `CostStatus` (actual vs. forecast) por fila — interpretarla.

---

## 3. Checklist de optimización vía Azure Resource Graph (recursos huérfanos)

Patrón: `az graph query -q "<KQL>" --subscriptions 69dc43ec-... --query "data[]" -o table`
(requiere `az extension add --name resource-graph`). Usar `limit` y `=~` (types en minúscula).

### Discos administrados huérfanos (sin adjuntar)

```kql
Resources
| where type =~ 'microsoft.compute/disks'
| where isempty(managedBy)
| project name, resourceGroup, location, diskSizeGb=properties.diskSizeGB, sku=sku.name
```

### IPs públicas sin asociar

```kql
Resources
| where type =~ 'microsoft.network/publicipaddresses'
| where isempty(properties.ipConfiguration)
| project name, resourceGroup, location, sku=sku.name
```

### NICs huérfanas

```kql
Resources
| where type =~ 'microsoft.network/networkinterfaces'
| where isempty(properties.virtualMachine)
| project name, resourceGroup, location
```

### Load balancers sin backend pools

```kql
Resources
| where type =~ 'microsoft.network/loadbalancers'
| where array_length(properties.backendAddressPools) == 0
| project name, resourceGroup, location, sku=sku.name
```
> Un backend-pool vacío es **señal de investigación**, NO prueba de que el LB sea
> seguro de eliminar. Cruzar con costos antes de recomendar baja.

### Cobertura de tags para asignación de costos

```kql
Resources
| extend hasCostCenter = isnotnull(tags['CostCenter'])
| summarize total=count(), tagged=countif(hasCostCenter) by type
| extend coverage=round(100.0 * tagged / total, 1)
| order by total desc
```

### Recomendaciones de costo de Azure Advisor

```kql
AdvisorResources
| where subscriptionId =~ '69dc43ec-5f24-4203-9239-a8d0f8506d44'
| where properties.category == 'Cost'
| extend resourceId=tostring(properties.resourceMetadata.resourceId)
| project name, resourceId, impact=properties.impact,
          solution=properties.shortDescription.solution,
          savingsDetails=tostring(properties.extendedProperties)
```
> Reportar ahorro/moneda/periodo SOLO si vienen en `savingsDetails`; si no, marcar
> la recomendación como cualitativa. Cruzar recursos huérfanos con los costos reales
> del Query antes de concluir.

---

## Priorización de recomendaciones (priority score)

Cuando el análisis produce varias optimizaciones, ordenarlas por ROI con un score, en vez de atacarlas
en cualquier orden. Fórmula (destilada de `az-cost-optimize`, adaptada):

```
Priority Score = (Valor × Ahorro mensual estimado) / (Riesgo × Días de implementación)

  Alta   : score > 20
  Media  : score 5–20
  Baja   : score < 5
```

- **Valor** y **Riesgo**: escala 1–10 (criterio del analista, justificado con evidencia).
- **Ahorro**: del cálculo real (SKU/tier actual → objetivo), no inventado; citar la fuente de precio.
- **Días de implementación**: esfuerzo realista, no optimista.

Toda recomendación lleva **evidencia** (configuración actual, patrón de uso por métricas/ARG, costo
actual→objetivo). Sin evidencia de respaldo, el ahorro no se declara.

> **Costos congelados:** las optimizaciones que impliquen right-size, auto-scaling, scheduling o
> agregar/reescalar nodos AKS **chocan con la regla `no_new_nodes_cost_frozen`** → se **reportan** como
> hallazgo, no se aplican. El priority score igual sirve para priorizar las que sí son aplicables
> (huérfanos a investigar, lifecycle de storage, tiers sobredimensionados fuera de AKS).

## Tracking de hallazgos — ADO Boards, no GitHub

El skill original cierra creando **issues de GitHub + un EPIC**. Nosotros estamos en **Azure DevOps**:
si un conjunto de optimizaciones hay que trackearlo, va como **work items de ADO Boards** (un item por
optimización + uno coordinador tipo Feature/Epic), no issues de GitHub.

- Al crear cualquier Task en ADO Boards, **pedir las horas al usuario** y setear
  `Microsoft.VSTS.Scheduling.OriginalEstimate` (y `CompletedWork` cuando aplique). Nunca inventar el
  número — si no lo dio, preguntarlo antes de dar la tarea por cerrada.
- Crear work items es **acción con aprobación**; el análisis/priorización en sí es lectura.

## Precios de lista — Retail Prices API (cuánto CUESTA, no cuánto gastamos)

Cost Management (arriba) responde **qué gastamos** (histórico/forecast de la factura). Para **cuánto
cuesta** un servicio/SKU antes de crearlo o cambiarlo —estimar un alta, comparar tiers, calcular el
"ahorro" del priority score— se usa la **Azure Retail Prices API**, que es **pública y sin
autenticación** (endpoint distinto, no necesita SP ni sesión):

```bash
# Público, sin auth. Guardar a archivo si pagina (NextPageLink) para no saturar el chat.
BASE="https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview"
# VM D4s v5 en eastus2, solo consumo:
curl -s "$BASE&\$filter=armSkuName eq 'Standard_D4s_v5' and armRegionName eq 'eastus2' and priceType eq 'Consumption'" -o "/tmp/price.json"
```

**Filtros OData** (combinar con `and`, `contains(campo,'x')` para parcial):

| Campo | Ejemplo |
|---|---|
| `serviceName` (case-sensitive) | `'Virtual Machines'`, `'Storage'`, `'Azure Cosmos DB'` |
| `serviceFamily` | `'Compute'`, `'Databases'`, `'AI + Machine Learning'` |
| `armRegionName` (lowercase) | `'eastus2'`, `'westeurope'` |
| `armSkuName` | `'Standard_D4s_v5'`, `'Standard_LRS'` |
| `priceType` | `'Consumption'`, `'Reservation'`, `'DevTestConsumption'` |
| `meterName` (contains) | `'Spot'` |

**Campos de respuesta clave:** `retailPrice`, `unitPrice`, `unitOfMeasure`, `currencyCode` (USD),
`armRegionName`, `skuName`, `meterName`, `priceType`, y el array **`savingsPlan`** (1Y/3Y, solo con
`api-version=2023-01-01-preview`). Usar `isPrimaryMeterRegion == true` salvo que se pida lo contrario.

**Reglas:** solo lectura (API pública, no toca nada); `serviceName` es case-sensitive — si da vacío,
filtrar primero por `serviceFamily` para descubrir el nombre exacto; URL-encode espacios (`%20`) y
comillas (`%27`) o usar comillas simples en bash; guardar a archivo si `NextPageLink` no es null.
Combina con el **priority score**: `retailPrice` del SKU actual vs. el objetivo = el ahorro con
evidencia. (La parte de Copilot Studio del skill original NO aplica — no la usamos.)

## Reglas de uso para el agente

1. **Nunca** aplicar una optimización como efecto colateral del análisis: generar
   recomendación → plan Azure estándar → aprobación separada.
2. Un recurso "huérfano" por ARG es **candidato a investigar**, no a borrar; toda
   eliminación es `Apply-AzureDeletePlan.ps1` con respaldo y aprobación propia.
3. No tocar cómputo AKS (nodos congelados); recomendaciones AKS → reportar.
4. No imprimir subscription IDs de más de lo necesario ni ningún secreto.

## Fuente

- Skill `microsoft/azure-skills/azure-cost` (MIT), archivos:
  `cost-analysis/references/cost-query/{request-body-schema,dimensions-by-scope}.md`,
  `cost-estimation/references/cost-forecast/request-body-schema.md`,
  `cost-optimization/references/resource-graph.md`.
- Complementa el sub-skill interno `analyze-azure-costs`.
