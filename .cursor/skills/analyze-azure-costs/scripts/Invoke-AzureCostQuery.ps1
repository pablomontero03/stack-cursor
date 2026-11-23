<#
Cost Management Query/Forecast via `az rest` (POST de solo lectura contra
el endpoint exacto ya clasificado por azure-security-gate.ps1 -- ver
Test-AzureCostManagementReadOnlyRestPost). Nunca usa `az costmanagement`
(extension separada no instalada por defecto) -- REST directo, sin
dependencias nuevas. Distingue ActualCost/AmortizedCost/Usage, valida
que la suscripcion sea la esperada, y devuelve JSON normalizado con
moneda/periodo/frescura declarada.

Uso:
  & '.\Invoke-AzureCostQuery.ps1' -SubscriptionId 69dc43ec-... -CostType ActualCost -Timeframe MonthToDate -Granularity Daily -GroupBy ServiceName
  & '.\Invoke-AzureCostQuery.ps1' -SubscriptionId 69dc43ec-... -Mode Forecast -CostType ActualCost -Timeframe MonthToDate
  & '.\Invoke-AzureCostQuery.ps1' -SubscriptionId 69dc43ec-... -ResourceId '/subscriptions/69dc43ec-.../resourceGroups/rg1/providers/Microsoft.CognitiveServices/accounts/gmo-prod-azure-ai-eastus2-0001'
#>
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [ValidateSet('Query', 'Forecast')] [string]$Mode = 'Query',
    [ValidateSet('ActualCost', 'AmortizedCost', 'Usage')] [string]$CostType = 'ActualCost',
    [ValidateSet('MonthToDate', 'BillingMonthToDate', 'TheLastMonth', 'TheLastBillingMonth', 'WeekToDate', 'Custom')] [string]$Timeframe = 'MonthToDate',
    [datetime]$From,
    [datetime]$To,
    [ValidateSet('Daily', 'Monthly', 'None')] [string]$Granularity = 'None',
    [string[]]$GroupBy = @(),
    [string]$ResourceGroup,
    [string[]]$ResourceId = @(),
    [string]$ApiVersion = '2023-11-01'
)

$ErrorActionPreference = 'Stop'
$azureCommonPath = Join-Path $PSScriptRoot '..\..\manage-azure-resources\scripts\Azure-Common.ps1'
. $azureCommonPath

$expectedSubscriptionId = '69dc43ec-5f24-4203-9239-a8d0f8506d44'
if ($SubscriptionId -ne $expectedSubscriptionId) {
    throw "Invoke-AzureCostQuery rechazado: '$SubscriptionId' no es la suscripcion FinOps autorizada ('$expectedSubscriptionId'). Este dominio esta acotado a Hospital Metropolitano -- confirmar con el usuario antes de analizar otra suscripcion."
}

$acct = Get-AzureAccountContext -SubscriptionId $SubscriptionId
if (-not $acct) {
    throw "Invoke-AzureCostQuery rechazado: no hay sesion activa de Azure CLI para '$SubscriptionId'. Pedir al usuario que corra 'az login' manualmente."
}

if ($Timeframe -eq 'Custom' -and (-not $From -or -not $To)) {
    throw "Invoke-AzureCostQuery rechazado: -Timeframe Custom requiere -From y -To."
}

foreach ($rid in $ResourceId) {
    if ($rid -notmatch "(?i)^/subscriptions/$([regex]::Escape($expectedSubscriptionId))/") {
        throw "Invoke-AzureCostQuery rechazado: -ResourceId '$rid' no pertenece a la suscripcion FinOps autorizada ('$expectedSubscriptionId')."
    }
}

$scope = if ($ResourceGroup) {
    "subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"
}
else {
    "subscriptions/$SubscriptionId"
}
$uri = "https://management.azure.com/$scope/providers/Microsoft.CostManagement/$($Mode.ToLowerInvariant())?api-version=$ApiVersion"

$dataset = [ordered]@{
    granularity = $Granularity
    aggregation = [ordered]@{ totalCost = [ordered]@{ name = 'Cost'; function = 'Sum' } }
}
if ($GroupBy.Count -gt 0) {
    $dataset.grouping = @($GroupBy | ForEach-Object { [ordered]@{ type = 'Dimension'; name = $_ } })
}
if ($ResourceId.Count -gt 0) {
    $dataset.filter = [ordered]@{
        dimensions = [ordered]@{ name = 'ResourceId'; operator = 'In'; values = @($ResourceId) }
    }
}

$body = [ordered]@{
    type      = $CostType
    timeframe = $Timeframe
    dataset   = $dataset
}
if ($Timeframe -eq 'Custom') {
    $body.timePeriod = [ordered]@{
        from = $From.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        to   = $To.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
}

$bodyJson = ($body | ConvertTo-Json -Depth 10 -Compress)
$argv = @('rest', '--method', 'post', '--uri', $uri, '--body', $bodyJson)
$queriedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
$raw = Invoke-AzureCliJson -Argv $argv

# Paginacion: Cost Management puede devolver properties.nextLink cuando el
# resultado no entra en una sola respuesta. Se sigue con GET (ya
# clasificado como lectura) hasta que no haya mas paginas, con un tope de
# seguridad para nunca entrar en un loop infinito.
$pageCount = 1
$maxPages = 20
while ($raw -and $raw.properties.nextLink -and $pageCount -lt $maxPages) {
    $nextUri = [string]$raw.properties.nextLink
    $nextPage = Invoke-AzureCliJson -Argv @('rest', '--method', 'get', '--uri', $nextUri)
    if (-not $nextPage) { break }
    if ($nextPage.properties.rows) {
        $raw.properties.rows = @($raw.properties.rows) + @($nextPage.properties.rows)
    }
    $raw.properties.nextLink = $nextPage.properties.nextLink
    $pageCount++
}

if ($null -eq $raw) {
    [PSCustomObject]@{
        ok            = $false
        note          = "Invoke-AzureCostQuery: la consulta a '$uri' fallo o no devolvio datos. Verificar permisos de Cost Management (rol Cost Management Reader o superior) sobre esa suscripcion/resource group."
        subscriptionId = $SubscriptionId
        mode          = $Mode
        costType      = $CostType
        timeframe     = $Timeframe
        queriedAtUtc  = $queriedAtUtc
    } | ConvertTo-Json -Depth 10
    return
}

$columns = @($raw.properties.columns | ForEach-Object { [string]$_.name })
$rows = @($raw.properties.rows)
$currencyIdx = [array]::IndexOf($columns, 'Currency')
# Envolver TODO el if/else con un @() exterior -- si el array interno
# queda con un solo elemento, PowerShell lo "desenvuelve" al recolectar la
# salida del bloque if/else antes de la asignacion (bug real encontrado y
# corregido durante la construccion de este script).
$currencies = @(if ($currencyIdx -ge 0) { $rows | ForEach-Object { $_[$currencyIdx] } | Select-Object -Unique })

$normalizedRows = @($rows | ForEach-Object {
    $row = $_
    $obj = [ordered]@{}
    for ($i = 0; $i -lt $columns.Count; $i++) {
        $obj[$columns[$i]] = $row[$i]
    }
    [PSCustomObject]$obj
})

# Un Timeframe "a la fecha" (MonthToDate/WeekToDate/BillingMonthToDate) es
# por definicion un periodo parcial -- nunca comparable directamente contra
# un mes/semana completo sin normalizar o indicarlo explicitamente (ver
# references/cost-definitions.md). Custom se evalua contra el fin de mes
# calendario de -To.
$partialTimeframes = @('MonthToDate', 'WeekToDate', 'BillingMonthToDate')
$isPartialPeriod = $false
if ($partialTimeframes -contains $Timeframe) {
    $isPartialPeriod = $true
}
elseif ($Timeframe -eq 'Custom' -and $To) {
    $endOfMonth = (Get-Date -Year $To.Year -Month $To.Month -Day 1).AddMonths(1).AddDays(-1).Date
    if ($To.Date -lt $endOfMonth) { $isPartialPeriod = $true }
}
$comparabilityWarning = if ($isPartialPeriod) {
    "Periodo parcial (timeframe=$Timeframe) -- no comparar directamente contra un periodo completo sin normalizar (ej. proyeccion lineal, o mismo dia del periodo anterior) o indicarlo explicitamente. Ver references/cost-definitions.md."
} else { $null }

[PSCustomObject]@{
    ok             = $true
    subscriptionId = $SubscriptionId
    subscriptionName = $acct.subscriptionName
    tenantId       = $acct.tenantId
    resourceGroup  = $ResourceGroup
    resourceIds    = @($ResourceId)
    mode           = $Mode
    costType       = $CostType
    timeframe      = $Timeframe
    granularity    = $Granularity
    groupBy        = @($GroupBy)
    from           = if ($From) { $From.ToUniversalTime().ToString('o') } else { $null }
    to             = if ($To) { $To.ToUniversalTime().ToString('o') } else { $null }
    currencies     = $currencies
    currencyWarning = if ($currencies.Count -gt 1) { "Multiples monedas en la misma respuesta ($($currencies -join ', ')) -- nunca sumar entre monedas distintas, desglosar por moneda." } else { $null }
    isPartialPeriod = $isPartialPeriod
    comparabilityWarning = $comparabilityWarning
    pageCount      = $pageCount
    columns        = $columns
    rowCount       = $rows.Count
    rows           = $normalizedRows
    queriedAtUtc   = $queriedAtUtc
    freshnessNote  = 'Cost Management puede tener un rezago de horas para datos muy recientes; el dia actual y el anterior pueden no estar cerrados todavia.'
}  | ConvertTo-Json -Depth 15
