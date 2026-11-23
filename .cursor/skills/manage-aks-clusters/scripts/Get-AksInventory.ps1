<#
Genera un inventario SANITIZADO de solo lectura de un contexto/namespace
(o de todos los namespaces si no se especifica) hacia .local\aks\inventory\.
Nunca escribe en el cluster. Nunca incluye valores de Secret ni contenido
de kubeconfig -- solo nombres, tipos, namespaces y metadatos.

Uso:
  powershell -File .\Get-AksInventory.ps1 -Context <contexto> [-Namespace <ns>] [-KubeconfigPath <ruta>]

-KubeconfigPath es opcional (default: resolucion ambiente de kubectl).
Los clusteres reales de este proyecto viven en kubeconfigs exportados por
Lens -- ver references/kubeconfig-and-contexts.md § Clusteres reales
conocidos.
#>

param(
    [Parameter(Mandatory)] [string]$Context,
    [string]$Namespace,
    [string]$KubeconfigPath,
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Aks-Common.ps1')

if (-not $OutDir) { $OutDir = Get-AksInventoryDir }
Assert-AksDirectoryExists -Path $OutDir

$nsArgs = if ($Namespace) { @('-n', $Namespace) } else { @('--all-namespaces') }
$connArgs = Get-AksKubectlConnectionArgs -Context $Context -KubeconfigPath $KubeconfigPath

function Get-KubectlJson {
    param([string[]]$Args)
    $raw = & kubectl @Args -o json @connArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        return [PSCustomObject]@{ error = ($raw | Out-String).Trim() }
    }
    try { return ($raw | Out-String | ConvertFrom-Json) }
    catch { return [PSCustomObject]@{ error = 'JSON invalido en la respuesta de kubectl' } }
}

Write-Host "Generando inventario para contexto '$Context'$(if ($Namespace) { " / namespace '$Namespace'" } else { ' / todos los namespaces' })..." -ForegroundColor Cyan

$inventory = [ordered]@{
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    context        = $Context
    kubeconfigPath = if ($KubeconfigPath) { (Resolve-Path -LiteralPath $KubeconfigPath).Path } else { $null }
    namespace      = if ($Namespace) { $Namespace } else { '(todos)' }
}

$resourceKinds = @('pods', 'deployments', 'statefulsets', 'daemonsets', 'services', 'ingresses', 'configmaps', 'jobs', 'cronjobs', 'horizontalpodautoscalers', 'persistentvolumeclaims')
foreach ($kind in $resourceKinds) {
    $raw = Get-KubectlJson -Args (@('get', $kind) + $nsArgs)
    if ($raw.PSObject.Properties.Name -contains 'error') {
        $inventory[$kind] = @{ error = $raw.error }
        continue
    }
    $items = @($raw.items | ForEach-Object {
        [PSCustomObject]@{
            name      = $_.metadata.name
            namespace = $_.metadata.namespace
            kind      = $kind
            createdAt = $_.metadata.creationTimestamp
        }
    })
    $inventory[$kind] = $items
}

# Secrets: SOLO nombres/tipos, nunca 'data'.
$secretsRaw = Get-KubectlJson -Args (@('get', 'secrets') + $nsArgs)
if ($secretsRaw.PSObject.Properties.Name -contains 'error') {
    $inventory.secrets = @{ error = $secretsRaw.error }
}
else {
    $inventory.secrets = @($secretsRaw.items | ForEach-Object {
        [PSCustomObject]@{ name = $_.metadata.name; namespace = $_.metadata.namespace; type = $_.type }
    })
}

$nodesRaw = Get-KubectlJson -Args @('get', 'nodes')
if ($nodesRaw.PSObject.Properties.Name -notcontains 'error') {
    $inventory.nodes = @($nodesRaw.items | ForEach-Object {
        [PSCustomObject]@{
            name       = $_.metadata.name
            conditions = @($_.status.conditions | Where-Object { $_.status -eq 'True' } | ForEach-Object { $_.type })
        }
    })
}

$timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$outPath = Join-Path $OutDir "inventory-$timestamp.json"
$inventory | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $outPath -Encoding utf8

Write-Host "Inventario guardado en: $outPath" -ForegroundColor Green
[PSCustomObject]@{ outPath = $outPath; generatedAtUtc = $inventory.generatedAtUtc }
