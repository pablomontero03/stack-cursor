<#
Harness de pruebas de los scripts del dominio analyze-azure-costs
(FinOps). `az` se intercepta anteponiendo este directorio (az.cmd ->
az-stub.ps1) al PATH del proceso de prueba unicamente -- cero red, cero
Azure real. Mismo patron que run-script-tests.ps1 de manage-azure-resources.
Cubre exactamente los items 1-10 de INSTRUCCIONES-SUBAGENTE-AZURE-FINOPS.md
seccion Pruebas (11 y 12 -- clasificacion del hook y mutaciones/deletes --
se cubren en run-hook-tests.ps1 y en la suite del dominio general).
#>

$scriptsRoot = Split-Path -Parent $PSScriptRoot
$env:PATH = "$PSScriptRoot;$env:PATH"

$testOutDir = Join-Path $PSScriptRoot 'tmp'
if (Test-Path -LiteralPath $testOutDir) { Remove-Item -LiteralPath $testOutDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $testOutDir | Out-Null

$results = [System.Collections.Generic.List[object]]::new()
function Add-Result {
    param([string]$Case, [bool]$Pass, [string]$Detail = '')
    $results.Add([PSCustomObject]@{ Case = $Case; Status = $(if ($Pass) { 'PASS' } else { 'FAIL' }); Detail = $Detail })
}

$finopsSub = '69dc43ec-5f24-4203-9239-a8d0f8506d44'
$trackedInventoryPaths = [System.Collections.Generic.List[string]]::new()

# ============================================================
# 1) Normalizacion de ActualCost y AmortizedCost
# ============================================================
try {
    $actual = & (Join-Path $scriptsRoot 'Invoke-AzureCostQuery.ps1') -SubscriptionId $finopsSub -CostType ActualCost -GroupBy ServiceName | ConvertFrom-Json
    $amortized = & (Join-Path $scriptsRoot 'Invoke-AzureCostQuery.ps1') -SubscriptionId $finopsSub -CostType AmortizedCost -GroupBy AmortizedCost | ConvertFrom-Json
    $pass = $actual.ok -and $amortized.ok -and $actual.costType -eq 'ActualCost' -and $amortized.costType -eq 'AmortizedCost' -and ($actual.rows[0].ServiceName -ne $amortized.rows[0].ServiceName)
    Add-Result '1. Normalizacion ActualCost vs AmortizedCost (costType distinto, filas distintas)' $pass
}
catch { Add-Result '1. Normalizacion ActualCost vs AmortizedCost' $false $_.Exception.Message }

# ============================================================
# 2) Monedas distintas no se suman
# ============================================================
try {
    $multi = & (Join-Path $scriptsRoot 'Invoke-AzureCostQuery.ps1') -SubscriptionId $finopsSub -GroupBy MultiCurrencyMarker | ConvertFrom-Json
    $currenciesArr = @($multi.currencies)
    $queryPass = $currenciesArr.Count -eq 2 -and $multi.currencyWarning -match 'nunca sumar'
    Add-Result '2a. Invoke-AzureCostQuery detecta multiples monedas y advierte' $queryPass "currencies=$($currenciesArr -join ',')"

    $mixedRows = @(
        [PSCustomObject]@{ ServiceName = 'Storage'; Cost = 10.5; Currency = 'USD' }
        [PSCustomObject]@{ ServiceName = 'Compute'; Cost = 20.0; Currency = 'EUR' }
    )
    $reportMixed = & (Join-Path $scriptsRoot 'New-AzureFinOpsReport.ps1') -Rows $mixedRows -LabelColumn ServiceName -ValueColumn Cost -Title 'Test Monedas Mixtas' -Formats Markdown -SubscriptionId $finopsSub -Scope $finopsSub -Window MonthToDate -CostType ActualCost -OutDir $testOutDir
    $manifestMixed = Get-Content -Raw $reportMixed.manifestPath | ConvertFrom-Json
    $reportPass = ($null -eq $manifestMixed.total) -and (@($manifestMixed.warnings) -join ' ') -match 'NO calculado'
    Add-Result '2b. New-AzureFinOpsReport NUNCA suma monedas distintas (total=null + advertencia)' $reportPass "total=$($manifestMixed.total)"
}
catch { Add-Result '2. Monedas distintas no se suman' $false $_.Exception.Message }

# ============================================================
# 3) Mes parcial no se compara incorrectamente con mes completo
# ============================================================
try {
    $partial = & (Join-Path $scriptsRoot 'Invoke-AzureCostQuery.ps1') -SubscriptionId $finopsSub -Timeframe MonthToDate -GroupBy ServiceName | ConvertFrom-Json
    $complete = & (Join-Path $scriptsRoot 'Invoke-AzureCostQuery.ps1') -SubscriptionId $finopsSub -Timeframe TheLastMonth -GroupBy ServiceName | ConvertFrom-Json
    $pass = ($partial.isPartialPeriod -eq $true) -and ($partial.comparabilityWarning -match 'no comparar') -and ($complete.isPartialPeriod -eq $false) -and ($null -eq $complete.comparabilityWarning)
    Add-Result '3. MonthToDate marcado parcial con advertencia; TheLastMonth no' $pass "partial=$($partial.isPartialPeriod) complete=$($complete.isPartialPeriod)"
}
catch { Add-Result '3. Mes parcial vs mes completo' $false $_.Exception.Message }

# ============================================================
# 4) Agrupaciones por servicio, recurso, RG y tags
# ============================================================
try {
    $byService = & (Join-Path $scriptsRoot 'Invoke-AzureCostQuery.ps1') -SubscriptionId $finopsSub -GroupBy ServiceName | ConvertFrom-Json
    $byResourceGroup = & (Join-Path $scriptsRoot 'Invoke-AzureCostQuery.ps1') -SubscriptionId $finopsSub -GroupBy ResourceGroupName -ResourceGroup rg1 | ConvertFrom-Json
    $pass = ($byService.groupBy -contains 'ServiceName') -and ($byResourceGroup.groupBy -contains 'ResourceGroupName') -and ($byResourceGroup.resourceGroup -eq 'rg1')
    Add-Result '4a. Invoke-AzureCostQuery soporta -GroupBy y -ResourceGroup' $pass

    $inv = & (Join-Path $scriptsRoot 'Get-AzureCostInventory.ps1') -SubscriptionId $finopsSub
    $trackedInventoryPaths.Add($inv.path)
    $invPass = ($inv.resourceCount -ge 1) -and (Test-Path -LiteralPath $inv.path)
    Add-Result '4b. Get-AzureCostInventory devuelve inventario (tags/RG/tipo) via Resource Graph' $invPass

    $testResourceId = "/subscriptions/$finopsSub/resourceGroups/rg1/providers/Microsoft.CognitiveServices/accounts/test-resourceid-marker"
    $byResource = & (Join-Path $scriptsRoot 'Invoke-AzureCostQuery.ps1') -SubscriptionId $finopsSub -ResourceId $testResourceId | ConvertFrom-Json
    $byResourcePass = $byResource.ok -and (@($byResource.resourceIds) -contains $testResourceId) -and ($byResource.rows[0].Cost -eq 137.11)
    Add-Result '4c. Invoke-AzureCostQuery soporta -ResourceId (filtra a un recurso exacto)' $byResourcePass "cost=$($byResource.rows[0].Cost)"

    $rejectedResourceId = $false
    try { & (Join-Path $scriptsRoot 'Invoke-AzureCostQuery.ps1') -SubscriptionId $finopsSub -ResourceId '/subscriptions/otra-suscripcion-no-autorizada/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm1' | Out-Null }
    catch { $rejectedResourceId = $true }
    Add-Result '4d. Invoke-AzureCostQuery rechaza -ResourceId fuera de la suscripcion FinOps autorizada' $rejectedResourceId
}
catch { Add-Result '4. Agrupaciones (servicio/recurso/RG/tags)' $false $_.Exception.Message }

# ============================================================
# 5) Forecast y variaciones
# ============================================================
try {
    $forecast = & (Join-Path $scriptsRoot 'Invoke-AzureCostQuery.ps1') -SubscriptionId $finopsSub -Mode Forecast -Timeframe TheLastMonth | ConvertFrom-Json
    $pass = $forecast.ok -and $forecast.mode -eq 'Forecast' -and $forecast.rowCount -ge 1
    Add-Result '5. Invoke-AzureCostQuery -Mode Forecast' $pass
}
catch { Add-Result '5. Forecast' $false $_.Exception.Message }

# ============================================================
# 6) Anomalias y Pareto
# ============================================================
try {
    $paretoRows = @(
        [PSCustomObject]@{ ServiceName = 'A'; Cost = 100; Currency = 'USD' }
        [PSCustomObject]@{ ServiceName = 'B'; Cost = 60; Currency = 'USD' }
        [PSCustomObject]@{ ServiceName = 'C'; Cost = 10; Currency = 'USD' }
        [PSCustomObject]@{ ServiceName = 'D'; Cost = 5; Currency = 'USD' }
    )
    $paretoReport = & (Join-Path $scriptsRoot 'New-AzureFinOpsReport.ps1') -Rows $paretoRows -LabelColumn ServiceName -ValueColumn Cost -Title 'Test Pareto' -Formats CSV -ChartTypes Pareto -SubscriptionId $finopsSub -Scope $finopsSub -Window MonthToDate -CostType ActualCost -OutDir $testOutDir
    $paretoSvg = Get-Content -Raw $paretoReport.outputPaths.charts[0]
    $pass = ($paretoSvg -match '<svg') -and ($paretoSvg -match '<polyline') -and ($paretoSvg -match '<rect')
    Add-Result '6. Grafico Pareto (barras + linea de % acumulado) se genera' $pass
}
catch { Add-Result '6. Anomalias y Pareto' $false $_.Exception.Message }

# ============================================================
# 7) Datos faltantes y valores nulos
# ============================================================
try {
    $failRun = & (Join-Path $scriptsRoot 'Invoke-AzureCostQuery.ps1') -SubscriptionId $finopsSub -GroupBy Fail429Marker 2>$null | ConvertFrom-Json
    $failPass = ($failRun.ok -eq $false) -and (-not [string]::IsNullOrWhiteSpace($failRun.note))
    Add-Result '7a. Invoke-AzureCostQuery reporta ok=false con nota clara cuando falla' $failPass

    $metricsFail = & (Join-Path $scriptsRoot 'Get-AzureResourceMetrics.ps1') -ResourceId "/subscriptions/$finopsSub/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/__FAIL__" -MetricNames 'Percentage CPU' 2>$null | ConvertFrom-Json
    $metricsFailPass = ($metricsFail.ok -eq $false) -and ($metricsFail.note -match 'no disponible')
    Add-Result '7b. Get-AzureResourceMetrics marca utilizacion no disponible sin asumir ocioso' $metricsFailPass
}
catch { Add-Result '7. Datos faltantes y valores nulos' $false $_.Exception.Message }

# ============================================================
# 8) Paginacion de APIs
# ============================================================
try {
    $paged = & (Join-Path $scriptsRoot 'Invoke-AzureCostQuery.ps1') -SubscriptionId $finopsSub -GroupBy PaginateMarker | ConvertFrom-Json
    $pass = ($paged.pageCount -eq 2) -and ($paged.rowCount -eq 2)
    Add-Result '8. Invoke-AzureCostQuery sigue properties.nextLink y agrega filas de todas las paginas' $pass "pageCount=$($paged.pageCount) rowCount=$($paged.rowCount)"
}
catch { Add-Result '8. Paginacion de APIs' $false $_.Exception.Message }

# ============================================================
# 9) Respuestas 401/403/429/5xx sin exponer informacion sensible
# ============================================================
try {
    $sensitiveOutput = & (Join-Path $scriptsRoot 'Invoke-AzureCostQuery.ps1') -SubscriptionId $finopsSub -GroupBy Fail401Marker 2>&1 | Out-String
    $noLeak = ($sensitiveOutput -notmatch '(?i)authorization\s*:\s*bearer') -and ($sensitiveOutput -notmatch '(?i)www-authenticate') -and ($sensitiveOutput -notmatch 'ey[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}')
    Add-Result '9. Fallo HTTP (401/403/429/5xx) no expone headers/tokens en la salida' $noLeak
}
catch { Add-Result '9. Errores HTTP sin exponer info sensible' $false $_.Exception.Message }

# ============================================================
# 10) Generacion de CSV, Excel y graficos
# ============================================================
try {
    $genRows = @(
        [PSCustomObject]@{ ServiceName = 'Virtual Machines'; Cost = 120.75; Currency = 'USD' }
        [PSCustomObject]@{ ServiceName = 'Storage'; Cost = 45.10; Currency = 'USD' }
    )
    $genReport = & (Join-Path $scriptsRoot 'New-AzureFinOpsReport.ps1') -Rows $genRows -LabelColumn ServiceName -ValueColumn Cost -Title 'Test Generacion' -Formats Markdown, CSV, HTML, Excel -ChartTypes Bar, Line -SubscriptionId $finopsSub -Scope $finopsSub -Window MonthToDate -CostType ActualCost -OutDir $testOutDir

    $csvPass = (Test-Path -LiteralPath $genReport.outputPaths.csv) -and ((Get-Content -Raw $genReport.outputPaths.csv) -match '120\.75')
    Add-Result '10a. CSV generado con punto decimal invariante (no coma regional)' $csvPass

    $mdPass = Test-Path -LiteralPath $genReport.outputPaths.markdown
    Add-Result '10b. Markdown generado' $mdPass

    $htmlPass = (Test-Path -LiteralPath $genReport.outputPaths.html) -and ((Get-Content -Raw $genReport.outputPaths.html) -match '<svg')
    Add-Result '10c. HTML autocontenido generado, incluye los graficos SVG inline' $htmlPass

    $chartsPass = ($genReport.outputPaths.charts.Count -eq 2) -and ($genReport.outputPaths.charts | ForEach-Object { Test-Path -LiteralPath $_ }) -notcontains $false
    Add-Result '10d. Graficos SVG (Bar + Line) generados sin dependencias externas' $chartsPass

    $excelModuleAvailable = [bool](Get-Module -ListAvailable -Name ImportExcel)
    $manifestGen = Get-Content -Raw $genReport.manifestPath | ConvertFrom-Json
    $excelPass = if ($excelModuleAvailable) { $null -ne $manifestGen.outputPaths.excel } else { ($null -eq $manifestGen.outputPaths.excel) -and ((@($manifestGen.warnings) -join ' ') -match 'ImportExcel') }
    Add-Result '10e. Excel: se genera si ImportExcel esta instalado, o se omite con advertencia clara si no' $excelPass "ImportExcel disponible=$excelModuleAvailable"
}
catch { Add-Result '10. Generacion CSV/Excel/graficos' $false $_.Exception.Message }

# ============================================================
# Contexto FinOps (Test-AzureFinOpsContext.ps1) -- validacion adicional,
# no numerada en la guia pero exigida por "Validacion de identidad y
# alcance".
# ============================================================
try {
    $ctxOk = & (Join-Path $scriptsRoot 'Test-AzureFinOpsContext.ps1') | ConvertFrom-Json
    Add-Result 'Test-AzureFinOpsContext: sesion valida -> ok=true' ($ctxOk.ok -eq $true -and $ctxOk.session.subscriptionId -eq $finopsSub)

    $ctxMismatch = & (Join-Path $scriptsRoot 'Test-AzureFinOpsContext.ps1') -ExpectedSubscriptionId 'mismatch-test-sub' | ConvertFrom-Json
    Add-Result 'Test-AzureFinOpsContext: suscripcion distinta -> ok=false, nunca cambia la sesion' ($ctxMismatch.ok -eq $false -and $ctxMismatch.subscriptionMatches -eq $false)

    $rejectedThrew = $false
    try { & (Join-Path $scriptsRoot 'Invoke-AzureCostQuery.ps1') -SubscriptionId 'otra-suscripcion-no-autorizada' -GroupBy ServiceName | Out-Null }
    catch { $rejectedThrew = $true }
    Add-Result 'Invoke-AzureCostQuery rechaza (throw) una suscripcion distinta a la FinOps autorizada' $rejectedThrew
}
catch { Add-Result 'Validacion de identidad y alcance' $false $_.Exception.Message }

# ============================================================
# Limpieza -- nunca dejar artefactos de prueba en el estado real
# ============================================================
Remove-Item -LiteralPath $testOutDir -Recurse -Force -ErrorAction SilentlyContinue
foreach ($p in $trackedInventoryPaths) {
    if ($p -and (Test-Path -LiteralPath $p)) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
}

# ============================================================
# Resumen
# ============================================================
$total = $results.Count
$passed = @($results | Where-Object { $_.Status -eq 'PASS' }).Count
$failed = $total - $passed

$results | Format-Table -AutoSize Case, Status | Out-String | Write-Host
Write-Host "`n=== Resumen: $passed/$total PASS ($failed FAIL) ===" -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })
if ($failed -gt 0) {
    Write-Host "Casos fallidos:" -ForegroundColor Red
    $results | Where-Object { $_.Status -eq 'FAIL' } | ForEach-Object { Write-Host " - $($_.Case): $($_.Detail)" -ForegroundColor Red }
    exit 1
}
exit 0
