<#
Inventario de solo lectura via Azure Resource Graph, para correlacionar
costo con tipo/ubicacion/tags/SKU/resource group. Wrapper delgado sobre
Get-AzureInventory.ps1 del dominio general -- no duplica su logica,
reusa el mismo mecanismo (hash SHA-256, snapshot bajo .local/azure/
inventory/).

Uso:
  & '.\Get-AzureCostInventory.ps1' -SubscriptionId 69dc43ec-... [-ResourceGroup <rg>]
#>
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [string]$ResourceGroup
)

$ErrorActionPreference = 'Stop'

$expectedSubscriptionId = '69dc43ec-5f24-4203-9239-a8d0f8506d44'
if ($SubscriptionId -ne $expectedSubscriptionId) {
    throw "Get-AzureCostInventory rechazado: '$SubscriptionId' no es la suscripcion FinOps autorizada ('$expectedSubscriptionId')."
}

$generalInventoryScript = Join-Path $PSScriptRoot '..\..\manage-azure-resources\scripts\Get-AzureInventory.ps1'
if (-not (Test-Path -LiteralPath $generalInventoryScript)) {
    throw "Get-AzureCostInventory rechazado: no se encuentra Get-AzureInventory.ps1 del dominio general en '$generalInventoryScript'."
}

$params = @{ SubscriptionId = $SubscriptionId; IncludeLocks = $false; IncludeActivityLog = $false }
if ($ResourceGroup) { $params.ResourceGroup = $ResourceGroup }

& $generalInventoryScript @params
