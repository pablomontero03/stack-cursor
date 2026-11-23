<#
Entrypoint ejecutable y sin red para clasificar un archivo .env. Carga la
biblioteca ConvertTo-AdoEnvClassification.ps1, escribe el resultado JSON en
-OutPath y solo imprime un resumen redactado de nombres/categorias.

-PopulateRealValues puede incluir valores reales en el JSON de salida y por
eso conserva una aprobacion puntual en el hook PermissionRequest. Sin ese
switch, un .env real nunca copia valores y un archivo example/sample solo
conserva valores no secretos conforme al clasificador existente.
#>

param(
    [Parameter(Mandatory)] [string]$EnvPath,
    [Parameter(Mandatory)] [string]$OutPath,
    [switch]$IsExampleFile,
    [switch]$PopulateRealValues
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $EnvPath -PathType Leaf)) {
    throw "Convert-AdoEnvFileClassification: no existe '$EnvPath'."
}

$resolvedEnvPath = (Resolve-Path -LiteralPath $EnvPath -ErrorAction Stop).Path
$resolvedOutCandidate = [IO.Path]::GetFullPath($OutPath)
if ([string]::Equals($resolvedEnvPath, $resolvedOutCandidate, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Convert-AdoEnvFileClassification: EnvPath y OutPath no pueden ser el mismo archivo.'
}

$outDirectory = Split-Path -Parent $resolvedOutCandidate
if ([string]::IsNullOrWhiteSpace($outDirectory) -or -not (Test-Path -LiteralPath $outDirectory -PathType Container)) {
    throw "Convert-AdoEnvFileClassification: el directorio de salida no existe ('$outDirectory')."
}

. (Join-Path $PSScriptRoot 'ConvertTo-AdoEnvClassification.ps1')

$raw = Get-Content -LiteralPath $resolvedEnvPath -Raw -Encoding UTF8
$classification = ConvertTo-AdoEnvClassification `
    -EnvFileContent $raw `
    -IsExampleFile ([bool]$IsExampleFile) `
    -PopulateRealValues:$PopulateRealValues

$classification | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolvedOutCandidate -Encoding UTF8

Write-Host 'Clasificacion .env completada (valores no impresos):' -ForegroundColor Cyan
foreach ($category in @('buildTimeVars', 'pipelineVars', 'secretVars', 'configMapVars', 'ambiguousVars')) {
    $items = @($classification[$category])
    $names = @($items | ForEach-Object { [string]$_.name } | Where-Object { $_ })
    Write-Host (" - {0}: {1} [{2}]" -f $category, $items.Count, ($names -join ', '))
}
Write-Host "Resultado JSON: $resolvedOutCandidate"
exit 0
