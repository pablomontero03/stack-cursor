<#
Combina filas de costo ya normalizadas (ej. salida de Invoke-AzureCostQuery.ps1)
en Markdown/CSV/Excel/HTML/SVG bajo .local\azure\finops\, y escribe un
manifiesto sanitizado de la corrida bajo .local\azure\finops\executions\.
Elige el grafico segun -ChartTypes en vez de generar todo automaticamente
(ver references\reporting-and-charts.md). Sin dependencias externas: los
graficos son SVG generados a mano (sin modulo/libreria adicional); Excel
solo se genera si el modulo ImportExcel ya esta instalado -- si no lo
esta, se omite y se deja una advertencia explicita en vez de fallar.

Uso:
  $q = & '.\Invoke-AzureCostQuery.ps1' -SubscriptionId 69dc43ec-... -GroupBy ServiceName | ConvertFrom-Json
  & '.\New-AzureFinOpsReport.ps1' -Rows $q.rows -LabelColumn ServiceName -ValueColumn Cost -Title 'Costo por servicio - MonthToDate' -Formats Markdown,CSV,SVG -ChartTypes Bar,Pareto -SubscriptionId $q.subscriptionId -Scope $q.subscriptionId -Window "$($q.timeframe)" -CostType $q.costType -Sources @('Cost Management Query API')
#>
param(
    [Parameter(Mandatory)] [array]$Rows,
    [Parameter(Mandatory)] [string]$LabelColumn,
    [Parameter(Mandatory)] [string]$ValueColumn,
    [Parameter(Mandatory)] [string]$Title,
    [ValidateSet('Markdown', 'CSV', 'Excel', 'HTML', 'SVG')] [string[]]$Formats = @('Markdown', 'CSV'),
    [ValidateSet('Line', 'Bar', 'Pareto')] [string[]]$ChartTypes = @(),
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$Scope,
    [Parameter(Mandatory)] [string]$Window,
    [Parameter(Mandatory)] [string]$CostType,
    [string[]]$Sources = @(),
    [string]$FormulasAndAssumptions = '',
    [string[]]$Warnings = @(),
    [string[]]$MissingData = @(),
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
$azureCommonPath = Join-Path $PSScriptRoot '..\..\manage-azure-resources\scripts\Azure-Common.ps1'
. $azureCommonPath

if (-not $OutDir) { $OutDir = Join-Path (Get-AzureProjectRoot) '.local\azure\finops' }
$reportsDir = Join-Path $OutDir 'reports'
$chartsDir = Join-Path $OutDir 'charts'
$executionsDir = Join-Path $OutDir 'executions'
Assert-AzureDirectoryExists -Path $reportsDir
Assert-AzureDirectoryExists -Path $chartsDir
Assert-AzureDirectoryExists -Path $executionsDir

$slug = ($Title -replace '[^a-zA-Z0-9]+', '-').Trim('-').ToLowerInvariant()
if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'reporte-finops' }
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$baseName = "$slug-$stamp"

function ConvertTo-AzureFinOpsCurrencyLabel {
    param([array]$RowsIn)
    $currencies = @($RowsIn | ForEach-Object { $_.Currency } | Where-Object { $_ } | Select-Object -Unique)
    if ($currencies.Count -eq 1) { return $currencies[0] }
    if ($currencies.Count -gt 1) { return "MULTIPLES ($($currencies -join ', ')) -- desglosar por moneda, nunca sumar" }
    return 'sin moneda declarada en los datos'
}
$currencyLabel = ConvertTo-AzureFinOpsCurrencyLabel -RowsIn $Rows
$currencyCount = @($Rows | ForEach-Object { $_.Currency } | Where-Object { $_ } | Select-Object -Unique).Count

$sortedRows = @($Rows | Sort-Object { [double]([string]$_.$ValueColumn) } -Descending)
# Nunca sumar entre monedas distintas: si hay mas de una moneda en los
# datos, el total queda sin calcular (ver references/cost-definitions.md)
# -- el detalle por fila sigue disponible en la tabla/CSV/gráfico.
$totalValue = if ($currencyCount -gt 1) { $null } else { ($sortedRows | Measure-Object -Property $ValueColumn -Sum).Sum }
if ($currencyCount -gt 1) {
    $Warnings += "Total NO calculado: los datos mezclan $currencyCount monedas distintas ($currencyLabel) -- desglosar por moneda antes de sumar."
}

$outputPaths = [ordered]@{}

# ---------- Markdown ----------
if ($Formats -contains 'Markdown') {
    $mdPath = Join-Path $reportsDir "$baseName.md"
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# $Title")
    $lines.Add('')
    $lines.Add("- Suscripcion: $SubscriptionId")
    $lines.Add("- Scope: $Scope")
    $lines.Add("- Ventana: $Window")
    $lines.Add("- Tipo de costo: $CostType")
    $lines.Add("- Moneda: $currencyLabel")
    $lines.Add("- Total: $totalValue $currencyLabel")
    $lines.Add("- Fuentes: $($Sources -join ', ')")
    if ($Warnings.Count -gt 0) { $lines.Add("- Advertencias: $($Warnings -join ' | ')") }
    if ($MissingData.Count -gt 0) { $lines.Add("- Datos faltantes: $($MissingData -join ' | ')") }
    $lines.Add('')
    $lines.Add("| $LabelColumn | $ValueColumn ($currencyLabel) |")
    $lines.Add('|---|---|')
    foreach ($r in $sortedRows) {
        $lines.Add("| $($r.$LabelColumn) | $($r.$ValueColumn) |")
    }
    ($lines -join "`r`n") | Set-Content -LiteralPath $mdPath -Encoding utf8
    $outputPaths.markdown = $mdPath
}

# ---------- CSV ----------
if ($Formats -contains 'CSV') {
    $csvPath = Join-Path $reportsDir "$baseName.csv"
    # Formatear el valor numerico con cultura invariante (punto decimal)
    # ANTES de Export-Csv -- de lo contrario, en una maquina con cultura
    # regional que usa coma decimal, Export-Csv escribe "120,75" dentro de
    # un CSV delimitado por comas: sintacticamente valido (queda entre
    # comillas) pero ambiguo/incorrecto para Excel u otro lector que
    # espere punto decimal (bug real encontrado y corregido durante la
    # construccion de este script).
    $csvRows = $sortedRows | ForEach-Object {
        [PSCustomObject]@{
            $LabelColumn = $_.$LabelColumn
            $ValueColumn = ([double]$_.$ValueColumn).ToString('0.####', [System.Globalization.CultureInfo]::InvariantCulture)
            Currency     = $_.Currency
        }
    }
    $csvRows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8
    $outputPaths.csv = $csvPath
}

# ---------- Excel (solo si ImportExcel ya esta instalado) ----------
if ($Formats -contains 'Excel') {
    if (Get-Module -ListAvailable -Name ImportExcel) {
        $xlsxPath = Join-Path $reportsDir "$baseName.xlsx"
        Import-Module ImportExcel -ErrorAction Stop
        $sortedRows | Select-Object $LabelColumn, $ValueColumn, Currency | Export-Excel -Path $xlsxPath -AutoSize -TableName 'Costos' -WorksheetName 'Costos'
        $outputPaths.excel = $xlsxPath
    }
    else {
        $outputPaths.excel = $null
        $Warnings += 'Formato Excel solicitado pero el modulo ImportExcel no esta instalado -- se omitio (no se instalo nada automaticamente). Usar el CSV, o instalar ImportExcel con aprobacion explicita.'
    }
}

# ---------- SVG (graficos) ----------
function New-AzureFinOpsSvgHeader {
    param([int]$Width = 800, [int]$Height = 420)
    return "<svg xmlns=`"http://www.w3.org/2000/svg`" width=`"$Width`" height=`"$Height`" viewBox=`"0 0 $Width $Height`" font-family=`"sans-serif`" font-size=`"12`">"
}

function New-AzureFinOpsBarChartSvg {
    param([array]$RowsIn, [string]$LabelCol, [string]$ValueCol, [string]$TitleIn)
    $w = 800; $h = 420; $marginLeft = 60; $marginBottom = 100; $chartW = $w - $marginLeft - 20; $chartH = $h - $marginBottom - 40
    $vals = @($RowsIn | ForEach-Object { [double]$_.$ValueCol })
    $maxVal = if ($vals.Count -gt 0) { ($vals | Measure-Object -Maximum).Maximum } else { 1 }
    if ($maxVal -eq 0) { $maxVal = 1 }
    $barWidth = if ($RowsIn.Count -gt 0) { $chartW / $RowsIn.Count } else { $chartW }
    $svg = New-Object System.Collections.Generic.List[string]
    $svg.Add((New-AzureFinOpsSvgHeader -Width $w -Height $h))
    $svg.Add("<text x=`"20`" y=`"20`" font-size=`"14`" font-weight=`"bold`">$TitleIn</text>")
    $i = 0
    foreach ($r in $RowsIn) {
        $val = [double]$r.$ValueCol
        $barH = [Math]::Round(($val / $maxVal) * $chartH, 2)
        $x = $marginLeft + ($i * $barWidth) + 4
        $y = 40 + ($chartH - $barH)
        $bw = [Math]::Max($barWidth - 8, 1)
        $svg.Add("<rect x=`"$x`" y=`"$y`" width=`"$bw`" height=`"$barH`" fill=`"#3b6ea5`"></rect>")
        $labelX = $x + ($bw / 2)
        $labelY = 40 + $chartH + 14
        $svg.Add("<text x=`"$labelX`" y=`"$labelY`" text-anchor=`"end`" transform=`"rotate(-45 $labelX,$labelY)`">$($r.$LabelCol)</text>")
        $i++
    }
    $svg.Add('</svg>')
    return ($svg -join "`n")
}

function New-AzureFinOpsLineChartSvg {
    param([array]$RowsIn, [string]$LabelCol, [string]$ValueCol, [string]$TitleIn)
    $w = 800; $h = 420; $marginLeft = 60; $marginBottom = 100; $chartW = $w - $marginLeft - 20; $chartH = $h - $marginBottom - 40
    $vals = @($RowsIn | ForEach-Object { [double]$_.$ValueCol })
    $maxVal = if ($vals.Count -gt 0) { ($vals | Measure-Object -Maximum).Maximum } else { 1 }
    if ($maxVal -eq 0) { $maxVal = 1 }
    $stepX = if ($RowsIn.Count -gt 1) { $chartW / ($RowsIn.Count - 1) } else { 0 }
    $points = New-Object System.Collections.Generic.List[string]
    $i = 0
    foreach ($r in $RowsIn) {
        $val = [double]$r.$ValueCol
        $x = $marginLeft + ($i * $stepX)
        $y = 40 + ($chartH - (($val / $maxVal) * $chartH))
        $points.Add("$x,$([Math]::Round($y,2))")
        $i++
    }
    $svg = New-Object System.Collections.Generic.List[string]
    $svg.Add((New-AzureFinOpsSvgHeader -Width $w -Height $h))
    $svg.Add("<text x=`"20`" y=`"20`" font-size=`"14`" font-weight=`"bold`">$TitleIn</text>")
    $svg.Add("<polyline points=`"$($points -join ' ')`" fill=`"none`" stroke=`"#3b6ea5`" stroke-width=`"2`"></polyline>")
    $svg.Add('</svg>')
    return ($svg -join "`n")
}

function New-AzureFinOpsParetoChartSvg {
    param([array]$RowsIn, [string]$LabelCol, [string]$ValueCol, [string]$TitleIn)
    $sorted = @($RowsIn | Sort-Object { [double]$_.$ValueCol } -Descending)
    $total = ($sorted | Measure-Object -Property $ValueCol -Sum).Sum
    if ($total -eq 0) { $total = 1 }
    $bar = New-AzureFinOpsBarChartSvg -RowsIn $sorted -LabelCol $LabelCol -ValueCol $ValueCol -TitleIn $TitleIn
    $bar = $bar -replace '</svg>\s*$', ''
    $marginLeft = 60; $chartW = 800 - $marginLeft - 20; $chartH = 420 - 100 - 40
    $stepX = if ($sorted.Count -gt 1) { $chartW / ($sorted.Count - 1) } else { 0 }
    $cum = 0.0
    $points = New-Object System.Collections.Generic.List[string]
    $i = 0
    foreach ($r in $sorted) {
        $cum += [double]$r.$ValueCol
        $pct = $cum / $total
        $x = $marginLeft + ($i * $stepX)
        $y = 40 + ($chartH - ($pct * $chartH))
        $points.Add("$x,$([Math]::Round($y,2))")
        $i++
    }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($bar)
    $lines.Add("<polyline points=`"$($points -join ' ')`" fill=`"none`" stroke=`"#c0392b`" stroke-width=`"2`"></polyline>")
    $lines.Add("<text x=`"680`" y=`"20`" font-size=`"11`" fill=`"#c0392b`">% acumulado</text>")
    $lines.Add('</svg>')
    return ($lines -join "`n")
}

$chartRows = $sortedRows
foreach ($chartType in $ChartTypes) {
    $svgContent = switch ($chartType) {
        'Bar' { New-AzureFinOpsBarChartSvg -RowsIn $chartRows -LabelCol $LabelColumn -ValueCol $ValueColumn -TitleIn $Title }
        'Line' { New-AzureFinOpsLineChartSvg -RowsIn $Rows -LabelCol $LabelColumn -ValueCol $ValueColumn -TitleIn $Title }
        'Pareto' { New-AzureFinOpsParetoChartSvg -RowsIn $chartRows -LabelCol $LabelColumn -ValueCol $ValueColumn -TitleIn $Title }
    }
    $chartPath = Join-Path $chartsDir "$baseName-$($chartType.ToLowerInvariant()).svg"
    $svgContent | Set-Content -LiteralPath $chartPath -Encoding utf8
    if (-not $outputPaths.Contains('charts')) { $outputPaths.charts = [System.Collections.Generic.List[string]]::new() }
    $outputPaths.charts.Add($chartPath)
}

# ---------- HTML autocontenido ----------
if ($Formats -contains 'HTML') {
    $htmlPath = Join-Path $reportsDir "$baseName.html"
    $rowsHtml = ($sortedRows | ForEach-Object { "<tr><td>$($_.$LabelColumn)</td><td>$($_.$ValueColumn)</td></tr>" }) -join "`n"
    $chartsHtml = ''
    if ($outputPaths.Contains('charts')) {
        foreach ($c in $outputPaths.charts) {
            $chartsHtml += (Get-Content -LiteralPath $c -Raw) + "`n"
        }
    }
    $html = "<!doctype html><html><head><meta charset=`"utf-8`"><title>$Title</title>" +
        "<style>body{font-family:sans-serif;margin:24px} table{border-collapse:collapse} td,th{border:1px solid #ccc;padding:4px 8px}</style>" +
        "</head><body><h1>$Title</h1>" +
        "<p>Suscripcion: $SubscriptionId | Scope: $Scope | Ventana: $Window | Tipo de costo: $CostType | Moneda: $currencyLabel | Total: $totalValue</p>" +
        "$chartsHtml<table><tr><th>$LabelColumn</th><th>$ValueColumn</th></tr>$rowsHtml</table></body></html>"
    $html | Set-Content -LiteralPath $htmlPath -Encoding utf8
    $outputPaths.html = $htmlPath
}

# ---------- Manifiesto de ejecucion (sanitizado, nunca un secreto) ----------
$manifest = [ordered]@{
    schemaVersion          = 1
    title                  = $Title
    subscriptionId         = $SubscriptionId
    scope                  = $Scope
    window                 = $Window
    costType               = $CostType
    currency               = $currencyLabel
    total                  = $totalValue
    rowCount               = $Rows.Count
    sources                = @($Sources)
    extractedAtUtc         = (Get-Date).ToUniversalTime().ToString('o')
    formulasAndAssumptions = $FormulasAndAssumptions
    warnings               = @($Warnings)
    missingData            = @($MissingData)
    scriptVersion          = '1.0.0'
    outputPaths            = $outputPaths
}
$normalizedJsonPath = Join-Path (Join-Path $OutDir 'normalized') "$baseName.json"
Assert-AzureDirectoryExists -Path (Split-Path -Parent $normalizedJsonPath)
($sortedRows | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $normalizedJsonPath -Encoding utf8
$manifest.normalizedDataHash = Get-AzureFileSha256 -Path $normalizedJsonPath
$manifest.normalizedDataPath = $normalizedJsonPath

$manifestPath = Join-Path $executionsDir "$baseName.json"
($manifest | ConvertTo-Json -Depth 15) | Set-Content -LiteralPath $manifestPath -Encoding utf8

[PSCustomObject]@{
    manifestPath = $manifestPath
    outputPaths  = $outputPaths
    total        = $totalValue
    currency     = $currencyLabel
}
