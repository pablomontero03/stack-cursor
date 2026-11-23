# Fuentes de datos y análisis especializados

## Fuentes, en el orden en que conviene evaluarlas

1. **Cost Management Query API** (`Invoke-AzureCostQuery.ps1 -Mode Query`)
   — análisis interactivo, agrupaciones por servicio/recurso/RG/tag/meter/
   charge type, granularidad diaria o mensual. Fuente principal para casi
   todo este dominio.
2. **Cost Management Forecast API** (`Invoke-AzureCostQuery.ps1 -Mode
   Forecast`) — pronóstico de cierre con la misma forma de request que
   Query.
3. **Cost Details / Exports** — para datasets grandes, histórico extenso o
   automatización recurrente (no implementado como script propio en esta
   primera versión; si un análisis lo necesita, usar
   `Invoke-AzureCostQuery.ps1` paginado o documentar el gap en el reporte).
4. **Formato FOCUS** — cuando la cuenta lo expone, preferirlo para
   análisis normalizado entre proveedores; Cost Management Query es
   suficiente para la mayoría de las preguntas de esta suscripción.
5. **Azure Resource Graph** (`Get-AzureCostInventory.ps1`) — tipo,
   ubicación, tags, SKU, resource group, para correlacionar con costo.
   Reusa el mismo mecanismo que `Get-AzureInventory.ps1` del dominio
   general.
6. **Azure Monitor Metrics** (`Get-AzureResourceMetrics.ps1`) —
   utilización (CPU, memoria, IOPS, requests, etc.) para correlacionar
   con costo.
7. **Azure Advisor** (`Get-AzureCostRecommendations.ps1`) —
   recomendaciones de costo ya calculadas por Azure.
8. **Reservations / Savings Plans APIs** — cobertura, utilización y
   recomendaciones, vía `Get-AzureCostRecommendations.ps1` cuando estén
   disponibles para la suscripción; si el permiso o el dato no está
   disponible, reportarlo como dato faltante, nunca inventar cobertura.
9. **Price Sheet / precios contractuales** — precio real de la cuenta,
   cuando la API lo expone.
10. **Azure Retail Prices API** — únicamente como precio público de lista
    de referencia. **Nunca sustituir un costo facturado o un precio
    contractual/negociado por precio retail** — si solo hay retail
    disponible, marcar el resultado explícitamente como "estimación de
    precio de lista".

Azure CLI (`az`) y `az rest` con la sesión local ya autenticada son el
mecanismo de acceso a todas estas fuentes. El MCP `azure` no es requisito
— sigue diferido (ver `.claude/rules/azure/authorization.md`); si algún
día se instala y se valida, puede usarse para lecturas, pero Azure CLI/
Resource Graph/APIs oficiales deben seguir funcionando como vía completa
independiente.

## Análisis especializados

### AKS

Correlacionar costo de nodos/node pools/discos/red/balanceadores/
Container Registry/Monitor/Log Analytics (por Resource Group y tags del
clúster, vía Resource Graph) con CPU/memoria/réplicas/capacidad
solicitada vs. utilizada (vía Monitor Metrics del node pool y del
clúster). **Nunca inventar costo por namespace o workload** — solo
presentarlo si hay asignación confiable (tags de chargeback, exports
etiquetados, o una metodología de reparto documentada tipo OpenCost) y
documentando explícitamente la fórmula y qué recursos son compartidos
entre namespaces.

### SQL y bases de datos

Analizar SKU, vCores, almacenamiento, backup, redundancia,
licenciamiento (LicenseType: incluido vs. Azure Hybrid Benefit), reservas
aplicadas, utilización real (DTU/vCore %, IOPS, storage) y ventanas de
actividad (para detectar si el tamaño actual corresponde a un pico
puntual). Cualquier recomendación de reducir un SKU debe considerar
límites de escalado, impacto en rendimiento, alta disponibilidad
(réplicas/zonas) y tiempo de cambio (algunos cambios de tier son
disruptivos).

### Azure AI / OpenAI

Puede incluir costo por deployment/modelo (si la facturación lo permite a
ese nivel), tokens de entrada/salida, número de solicitudes, costo por
millón de tokens, costo por solicitud, latencia/errores/disponibilidad
(vía Monitor), picos de utilización y rate limiting, capacidad
provisionada vs. consumo real. Si Cost Management solo entrega costo a
nivel de recurso (la cuenta de Azure OpenAI completa) y las métricas de
uso están por deployment, cualquier reparto de costo por deployment debe
marcarse como **estimación** con la fórmula explícita (ej. proporcional a
tokens consumidos por deployment) — nunca atribuir un costo exacto a un
deployment sin datos que lo respalden directamente.

### Azure Monitor y Log Analytics

Analizar ingestión (GB/día), retención configurada, volumen de consultas,
alertas activas, métricas custom, Application Insights, y exports
configurados. Distinguir siempre datos operativos (logs, métricas) de
cargos facturados (ingestión + retención extendida + consultas
adicionales) — no todo lo que se ve en Log Analytics tiene un cargo
directo asociado.
