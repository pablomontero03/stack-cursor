<#
Valida el contexto de sesion para el dominio FinOps: Azure CLI instalada,
sesion activa, tenant, y que la suscripcion objetivo sea EXACTAMENTE
69dc43ec-5f24-4203-9239-a8d0f8506d44 (Hospital Metropolitano). Nunca
ejecuta az login/logout ni cambia la suscripcion activa -- si la sesion
expiro o apunta a otro tenant/suscripcion, se detiene y lo reporta.

Uso:
  & '.\Test-AzureFinOpsContext.ps1' [-ExpectedSubscriptionId <id>]
#>
param(
    [string]$ExpectedSubscriptionId = '69dc43ec-5f24-4203-9239-a8d0f8506d44'
)

$ErrorActionPreference = 'Stop'
$azureCommonPath = Join-Path $PSScriptRoot '..\..\manage-azure-resources\scripts\Azure-Common.ps1'
if (-not (Test-Path -LiteralPath $azureCommonPath)) {
    throw "Test-AzureFinOpsContext rechazado: no se encuentra Azure-Common.ps1 del dominio general en '$azureCommonPath'."
}
. $azureCommonPath

$result = [ordered]@{
    azureCli           = [ordered]@{ installed = $false; version = $null }
    session            = [ordered]@{ loggedIn = $false; tenantId = $null; subscriptionId = $null; subscriptionName = $null; userName = $null }
    expectedSubscriptionId = $ExpectedSubscriptionId
    subscriptionMatches = $false
    ok                 = $false
    note               = $null
}

$cliVersion = Get-AzureCliVersion
if ($cliVersion) {
    $result.azureCli.installed = $true
    $result.azureCli.version = [string]$cliVersion.'azure-cli'
}
else {
    $result.note = 'Azure CLI no disponible en PATH.'
    [PSCustomObject]$result | ConvertTo-Json -Depth 10
    return
}

$acct = Get-AzureAccountContext -SubscriptionId $ExpectedSubscriptionId
if (-not $acct) {
    $result.note = 'No hay sesion activa de Azure CLI, o expiro, o no tiene acceso a esa suscripcion. Pedir al usuario que corra "az login" manualmente -- este dominio nunca lo ejecuta.'
    [PSCustomObject]$result | ConvertTo-Json -Depth 10
    return
}

$result.session.loggedIn = $true
$result.session.tenantId = $acct.tenantId
$result.session.subscriptionId = $acct.subscriptionId
$result.session.subscriptionName = $acct.subscriptionName
$result.session.userName = $acct.userName

if ($acct.subscriptionId -eq $ExpectedSubscriptionId) {
    $result.subscriptionMatches = $true
    $result.ok = $true
}
else {
    $result.note = "La sesion activa apunta a la suscripcion '$($acct.subscriptionId)' ($($acct.subscriptionName)), no a la esperada '$ExpectedSubscriptionId'. Detenerse -- no se cambia la suscripcion activa automaticamente (usar --subscription $ExpectedSubscriptionId explicito en cada consulta, o pedir al usuario que confirme cual suscripcion analizar)."
}

[PSCustomObject]$result | ConvertTo-Json -Depth 10
