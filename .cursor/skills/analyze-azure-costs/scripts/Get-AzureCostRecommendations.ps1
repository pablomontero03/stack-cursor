<#
Recomendaciones de costo de Azure Advisor (siempre de solo lectura) mas,
cuando esten disponibles para la suscripcion, cobertura/utilizacion de
Reservations y Savings Plans. Si un dato no esta disponible (falta de
permiso, feature no habilitada), se reporta como dato faltante -- nunca
se inventa cobertura.

Uso:
  & '.\Get-AzureCostRecommendations.ps1' -SubscriptionId 69dc43ec-...
#>
param(
    [Parameter(Mandatory)] [string]$SubscriptionId
)

$ErrorActionPreference = 'Stop'
$azureCommonPath = Join-Path $PSScriptRoot '..\..\manage-azure-resources\scripts\Azure-Common.ps1'
. $azureCommonPath

$expectedSubscriptionId = '69dc43ec-5f24-4203-9239-a8d0f8506d44'
if ($SubscriptionId -ne $expectedSubscriptionId) {
    throw "Get-AzureCostRecommendations rechazado: '$SubscriptionId' no es la suscripcion FinOps autorizada ('$expectedSubscriptionId')."
}

$queriedAtUtc = (Get-Date).ToUniversalTime().ToString('o')

$advisorRaw = Invoke-AzureCliJson -Argv @('advisor', 'recommendation', 'list', '--subscription', $SubscriptionId, '--category', 'Cost')
$advisorAvailable = $null -ne $advisorRaw
# @() exterior envolviendo TODO el if -- si adentro queda un solo elemento,
# PowerShell lo desenvuelve al recolectar la salida del if/else antes de
# la asignacion (mismo bug corregido en Invoke-AzureCostQuery.ps1).
$advisorRecommendations = @(if ($advisorAvailable) {
    $advisorRaw | ForEach-Object {
        [PSCustomObject]@{
            resourceId       = [string]$_.resourceMetadata.resourceId
            impact           = [string]$_.impact
            problem          = [string]$_.shortDescription.problem
            solution         = [string]$_.shortDescription.solution
            extendedProperties = $_.extendedProperties
        }
    }
})

$reservationRaw = Invoke-AzureCliJson -Argv @('consumption', 'reservation', 'summary', 'list', '--reservation-order-id', 'placeholder')
# La llamada anterior con un id placeholder siempre falla -- es intencional:
# Reservations exige un reservation-order-id real para "summary". Sin uno
# conocido, se reporta como dato pendiente en vez de listar (evita asumir
# cobertura sin evidencia). Un analisis puntual con un order id real puede
# invocar la misma familia de comandos directamente.
$reservationAvailable = $false

[PSCustomObject]@{
    ok                       = $true
    subscriptionId           = $SubscriptionId
    advisor                  = [ordered]@{
        available       = $advisorAvailable
        note            = if (-not $advisorAvailable) { 'No se pudo consultar Azure Advisor (permiso faltante o sin recomendaciones de costo activas).' } else { $null }
        recommendationCount = $advisorRecommendations.Count
        recommendations = $advisorRecommendations
    }
    reservationsAndSavingsPlans = [ordered]@{
        available = $reservationAvailable
        note      = 'Cobertura/utilizacion de Reservations y Savings Plans requiere un reservation-order-id o savings-plan-order-id real (az consumption reservation summary list / az costmanagement benefit ...). No se listo automaticamente para evitar asumir cobertura sin evidencia -- consultar puntualmente cuando el analisis lo requiera.'
    }
    queriedAtUtc = $queriedAtUtc
} | ConvertTo-Json -Depth 15
