---
name: analyze-azure-costs
description: Analisis FinOps de la suscripcion Azure Hospital Metropolitano: costos, consumo, anomalias, tendencias, pronosticos y oportunidades de optimizacion de cualquier servicio Azure.
triggers: [costos, finops, cost management, presupuesto, optimizacion, billing, azure costs]
always: false
---

# Analyze Azure Costs (FinOps)

Sub-skill del dominio Azure general (`manage-azure-resources`) — reusa su
`Azure-Common.ps1`, su mecanismo de plan/aprobacion, sus agentes
`azure-operator`/`azure-reviewer`, y su hook `azure-security-gate.ps1`
(ampliado con una excepcion narrow para Cost Management, ver
`.cursor/rules/azure/security.md`). No duplica ninguno de esos
mecanismos.

## Alcance

Suscripcion objetivo: `Hospital Metropolitano`
(`69dc43ec-5f24-4203-9239-a8d0f8506d44`), tenant `Grupo Montecristo`,
sesion local ya autenticada con `az login` (nunca se ejecuta login/logout
desde este flujo). Todo script de este dominio valida esa suscripcion
exacta antes de consultar — ver `Test-AzureFinOpsContext.ps1`.

Este dominio investiga costos de **cualquier** servicio — no se limita a
una familia predeterminada. Los análisis especializados de
`references/cost-data-sources.md` (AKS, SQL, Azure AI/OpenAI, Monitor/Log
Analytics) son ejemplos profundizados, no una lista cerrada.

`documentacion-metricas-azure-monitor-cli.md` (si existe en el repo) está
fuera de alcance de esta skill — no se lee, copia, mueve ni referencia
como fuente. Cubre métricas operativas de Azure Monitor/OpenAI, no
costos.

## Regla de oro de este dominio

Ningún script aplica un cambio de infraestructura real. Un plan de
optimización (budget, alerta, export, tag, cambio de SKU) se arma y
valida con `New-AzureChangePlan.ps1`/`Test-AzureChangePlan.ps1` del
dominio general y se ejecuta únicamente con `Apply-AzureChangePlan.ps1`
(no destructivo, una aprobación) o `Apply-AzureDeletePlan.ps1`
(eliminación, siempre aprobación separada) — este subagente prepara y
transfiere, nunca aplica.

## Agente

**`azure-finops-analyst`** (`.cursor/agents/azure-finops-analyst.md`):
descubre alcance, consulta costos/inventario/métricas/recomendaciones sin
modificar nada, combina fuentes, detecta tendencias/anomalías/desperdicio,
genera reportes y gráficos, cuantifica ahorro potencial con evidencia, y
transfiere cualquier plan de optimización a `azure-operator` (ejecución)
y `azure-reviewer` (revisión) — nunca aplica cambios él mismo.

## Cargar solo el contexto necesario

| Referencia | Cuándo |
|---|---|
| `references/cost-definitions.md` | Antes de reportar cualquier cifra — distinciones obligatorias (ActualCost/AmortizedCost, moneda, mes parcial vs completo, etc.) |
| `references/cost-data-sources.md` | Elegir la fuente correcta (Cost Management Query/Forecast, Resource Graph, Monitor Metrics, Advisor, Reservations/Savings Plans, Retail Prices) y los análisis especializados por servicio |
| `references/utilization-correlation.md` | Correlacionar costo con utilización (CPU/memoria/IOPS/requests) sin inventar atribución no demostrable |
| `references/reporting-and-charts.md` | Elegir el gráfico según la pregunta y el formato de entrega |

## Scripts (`scripts/`)

Todos dot-sourcean `..\..\manage-azure-resources\scripts\Azure-Common.ps1`
del dominio general — nunca duplican esa librería.

| Script | Uso | Aprobación |
|---|---|---|
| `Test-AzureFinOpsContext.ps1` | Valida sesión, tenant, y que la suscripción objetivo sea exactamente `69dc43ec-5f24-4203-9239-a8d0f8506d44` | No |
| `Invoke-AzureCostQuery.ps1` | Cost Management Query/Forecast vía `az rest` (endpoint exacto ya clasificado como lectura por el hook). Soporta `-GroupBy` (por servicio/producto/etc.) y `-ResourceId` (uno o más, filtra a recurso(s) exacto(s) — valida que pertenezcan a la suscripción FinOps autorizada) | No |
| `Get-AzureCostInventory.ps1` | Resource Graph — tipo, ubicación, tags, SKU, resource group, para correlacionar costo | No |
| `Get-AzureResourceMetrics.ps1` | Azure Monitor Metrics — utilización | No |
| `Get-AzureCostRecommendations.ps1` | Azure Advisor (recomendaciones de costo) + cobertura de Reservations/Savings Plans si están disponibles | No |
| `New-AzureFinOpsReport.ps1` | Combina todo en Markdown/CSV/Excel/HTML/gráficos bajo `.local/azure/finops/` | No |

Ninguno de estos scripts ejecuta `New-AzureChangePlan.ps1`/
`Apply-AzureChangePlan.ps1`/`Apply-AzureDeletePlan.ps1` — esos siguen
siendo exclusivos del dominio general, invocados por `azure-operator`
tras aprobación.

## Rutas locales (`.local/azure/finops/`, no versionado)

`raw/` (respuestas crudas sanitizadas), `normalized/` (datos
normalizados con moneda/período/fórmulas), `reports/` (Markdown/CSV/
Excel/HTML), `charts/` (PNG/SVG), `executions/` (manifiesto sanitizado
de cada corrida: scope, ventana, tipo de costo, moneda, fuentes, hora de
extracción, frescura, hash, fórmulas/supuestos, advertencias — nunca un
token ni secreto). No se escriben datos financieros descargados en
`docs/`, memoria de agentes ni ningún archivo versionado.

## Modelo de aprobación

Igual criterio que `manage-azure-resources` (ver
`.cursor/rules/azure/authorization.md`), con estas precisiones FinOps:

- **Sin aprobación**: consultas de costo/forecast, Resource Graph,
  métricas de Monitor, recomendaciones de Advisor ya existentes,
  inventario, lectura de budgets/exports/alertas existentes, generación
  local de reportes/gráficos en `.local/`, cálculos/correlaciones/
  simulaciones, preparación y revisión de un plan de optimización.
- **Una aprobación del plan**: crear/actualizar budgets, alertas,
  scheduled actions, exports, tags, o aplicar una optimización de SKU —
  vía el flujo estándar `New-AzureChangePlan.ps1` →
  `Test-AzureChangePlan.ps1` → `Apply-AzureChangePlan.ps1` del dominio
  general.
- **Aprobación separada obligatoria**: cualquier eliminación (recurso,
  budget, export, alerta, scheduled action), quitar una reserva o
  configuración que afecte facturación/disponibilidad, o cualquier acción
  irreversible — vía `Apply-AzureDeletePlan.ps1`.

## Caso especial: Cost Management usa POST para consultas de lectura

`az rest --method post` contra
`.../subscriptions/69dc43ec-.../providers/Microsoft.CostManagement/
(query|forecast)` con un `--body` inline cuyas claves están todas en el
set permitido se clasifica como lectura automática — ver
`Test-AzureCostManagementReadOnlyRestPost` en
`.cursor/hooks/azure/azure-security-gate.ps1` y
`.cursor/rules/azure/security.md` § Caso especial. Cualquier otra
suscripción, ruta, o clave de body desconocida sigue preguntando —
nunca se asume lectura sin poder verificar el esquema exacto.

## Fuentes de verdad

- Autorización y seguridad del dominio general:
  `.cursor/rules/azure/authorization.md` y `.cursor/rules/azure/security.md`.
- Arquitectura: `docs/azure/AZURE-AUTOMATION-ARCHITECTURE.md` §
  Azure FinOps.
- Especificación original: `INSTRUCCIONES-SUBAGENTE-AZURE-FINOPS.md`
  (raíz del proyecto).
- Referencia operativa Cost Query/Forecast (bodies `az rest`, dimensiones válidas,
  timeframes) + checklist ARG de recursos huérfanos y Advisor de costo:
  `docs/azure/FINOPS-COST-QUERY-FORECAST-REFERENCE.md`.
