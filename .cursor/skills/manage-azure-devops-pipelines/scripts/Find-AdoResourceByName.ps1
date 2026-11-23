<#
Busca (solo lectura, sin red) Build/Release/Variable Group por nombre
dentro de un export ya generado por Export-AdoClassicInventory.ps1.
Reemplaza los one-liners de PowerShell -Command improvisados para esta
misma tarea (leer el inventario y filtrar por nombre) -- reusar este
script en vez de armar uno nuevo cada vez, para que quede cubierto por un
wildcard fijo de permisos.

Uso:
  powershell -File .\Find-AdoResourceByName.ps1 -InventoryPath 'C:\...\inventory-....json' -Pattern 'buklo-microservice-auth'
  powershell -File .\Find-AdoResourceByName.ps1 -InventoryPath '...' -Pattern 'administracion-proyectos' -ResourceType Build
#>

param(
    [Parameter(Mandatory)] [string]$InventoryPath,
    [Parameter(Mandatory)] [string]$Pattern,
    [ValidateSet('Build', 'Release', 'VariableGroup', 'All')] [string]$ResourceType = 'All'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $InventoryPath -PathType Leaf)) {
    throw "No existe el archivo de inventario: $InventoryPath"
}

$inv = Get-Content -LiteralPath $InventoryPath -Raw -Encoding UTF8 | ConvertFrom-Json

if ($ResourceType -in @('Build', 'All')) {
    Write-Output "=== Build definitions matching '$Pattern' ==="
    $inv.buildDefinitions | Where-Object { $_.name -match $Pattern } | ForEach-Object {
        Write-Output ("id={0} name={1}" -f $_.id, $_.name)
    }
}

if ($ResourceType -in @('Release', 'All')) {
    Write-Output "=== Release definitions matching '$Pattern' ==="
    $inv.releaseDefinitions | Where-Object { $_.name -match $Pattern } | ForEach-Object {
        Write-Output ("id={0} name={1}" -f $_.id, $_.name)
    }
}

if ($ResourceType -in @('VariableGroup', 'All')) {
    Write-Output "=== Variable Groups matching '$Pattern' ==="
    $inv.variableGroups | Where-Object { $_.name -match $Pattern } | ForEach-Object {
        Write-Output ("id={0} name={1}" -f $_.id, $_.name)
    }
}
