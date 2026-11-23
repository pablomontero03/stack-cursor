<#
Diagnostico de solo lectura del entorno de este dominio: Azure CLI instalada,
sesion activa, y estado del MCP `azure` (hoy siempre "no configurado", ver
.kiro/rules/azure/authorization.md). No modifica nada, no ejecuta az login.

Uso:
  & '.\Test-AzureEnvironment.ps1' [-SubscriptionId <id>]
#>
param([string]$SubscriptionId)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Azure-Common.ps1')

$result = [ordered]@{
    azureCli      = [ordered]@{ installed = $false; version = $null }
    session       = [ordered]@{ loggedIn = $false; tenantId = $null; subscriptionId = $null; subscriptionName = $null; userName = $null }
    resourceGraph = [ordered]@{ available = $false; detail = $null }
    mcpAzure      = [ordered]@{ configured = $false; note = 'MCP oficial azure diferido a proposito -- no existe en .mcp.json (ver .kiro/rules/azure/authorization.md). Este dominio opera 100% via Azure CLI/ARM REST.' }
    projectRoot   = Get-AzureProjectRoot
}

$cliVersion = Get-AzureCliVersion
if ($cliVersion) {
    $result.azureCli.installed = $true
    $result.azureCli.version = [string]$cliVersion.'azure-cli'
}

$acct = Get-AzureAccountContext -SubscriptionId $SubscriptionId
if ($acct) {
    $result.session.loggedIn = $true
    $result.session.tenantId = $acct.tenantId
    $result.session.subscriptionId = $acct.subscriptionId
    $result.session.subscriptionName = $acct.subscriptionName
    $result.session.userName = $acct.userName
}
else {
    $result.session.note = 'No hay sesion activa o expiro. Pedir al usuario que corra `az login` manualmente -- este dominio nunca lo ejecuta.'
}

if ($result.session.loggedIn) {
    $rgTest = Invoke-AzureCliJson -Argv @('graph', 'query', '-q', "Resources | project id | limit 1", '--subscriptions', $result.session.subscriptionId)
    if ($null -ne $rgTest) {
        $result.resourceGraph.available = $true
    }
    else {
        $result.resourceGraph.detail = 'La extension `resource-graph` puede no estar instalada (`az extension add --name resource-graph`) o la consulta fallo.'
    }
}

[PSCustomObject]$result | ConvertTo-Json -Depth 10
