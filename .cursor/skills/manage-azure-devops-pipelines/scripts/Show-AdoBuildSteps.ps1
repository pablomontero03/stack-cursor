<#
Imprime (solo lectura, sin red) un resumen legible de las phases/steps/
variables de un body de Build ya descargado por
Get-AdoClassicDefinitionTemplate.ps1 -Kind Build. Reemplaza los one-liners
de PowerShell -Command improvisados para esta misma tarea -- reusar este
script en vez de armar uno nuevo cada vez, para que quede cubierto por un
wildcard fijo de permisos.

Uso:
  powershell -File .\Show-AdoBuildSteps.ps1 -JsonPath 'C:\...\raw-build-584-....json'
  powershell -File .\Show-AdoBuildSteps.ps1 -JsonPath '...' -IncludeVariables
#>

param(
    [Parameter(Mandatory)] [string]$JsonPath,
    [switch]$IncludeVariables
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $JsonPath -PathType Leaf)) {
    throw "No existe el archivo: $JsonPath"
}

$b = Get-Content -LiteralPath $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json

Write-Output "name=$($b.name) id=$($b.id) revision=$($b.revision)"
Write-Output "phases count=$($b.process.phases.Count)"

foreach ($p in $b.process.phases) {
    Write-Output "--- phase name='$($p.name)' refName='$($p.refName)' condition='$($p.condition)' dependencies=$($p.dependencies | ConvertTo-Json -Compress)"
    Write-Output "    target: $($p.target | ConvertTo-Json -Compress)"
    $i = 0
    foreach ($s in $p.steps) {
        Write-Output "    [$i] displayName='$($s.displayName)' enabled=$($s.enabled) taskId=$($s.task.id) definitionType=$($s.task.definitionType) refName='$($s.refName)'"
        $i++
    }
}

if ($IncludeVariables) {
    Write-Output '--- variables ---'
    $b.variables.PSObject.Properties | ForEach-Object { Write-Output "$($_.Name) = $($_.Value.value)" }
}
