<#
Readback de solo lectura tras un Apply-AdoClassicPlan.ps1 exitoso:
confirma que los recursos creados existen y coinciden con el plan. No crea,
modifica ni elimina nada.

Para un plan de borrado (operationKind='delete', ver
New-AdoClassicDeletePlan.ps1) la semantica es la OPUESTA: el readback
confirma que el recurso YA NO EXISTE (un GET/list que lo siga
encontrando es el fallo, no el exito).

Uso:
  powershell -File .\Test-AdoCreatedResources.ps1 -PlanPath '...\aks-x-y-....json'
#>

param(
    [Parameter(Mandatory)] [string]$PlanPath
)

$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'Invoke-AdoRest.ps1')

if (-not (Test-Path -LiteralPath $PlanPath)) {
    throw "Test-AdoCreatedResources: no existe el archivo de plan '$PlanPath'."
}

$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json

$results = [System.Collections.Generic.List[object]]::new()

function Add-Check {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    $results.Add([PSCustomObject]@{ Check = $Name; Ok = $Ok; Detail = $Detail })
}

if ([string]$plan.operationKind -eq 'delete') {
    $collectionMap = @{
        VariableGroup     = @{ baseUrl = $script:AdoCoreBaseUrl; path = 'distributedtask/variablegroups'; queryParam = 'groupName' }
        BuildDefinition   = @{ baseUrl = $script:AdoCoreBaseUrl; path = 'build/definitions'; queryParam = 'name' }
        ReleaseDefinition = @{ baseUrl = $script:AdoReleaseBaseUrl; path = 'release/definitions'; queryParam = 'searchText' }
    }
    $map = $collectionMap[[string]$plan.resourceType]
    if (-not $map) {
        throw "Test-AdoCreatedResources: resourceType desconocido '$($plan.resourceType)' en un plan de borrado."
    }

    Write-Host "Confirmando que $($plan.resourceType) '$($plan.resourceName)' (id=$($plan.resourceId)) YA NO EXISTE..." -ForegroundColor Cyan
    try {
        $listUri = "$($map.baseUrl)/$($plan.project)/_apis/$($map.path)?$($map.queryParam)=$([uri]::EscapeDataString([string]$plan.resourceName))&api-version=$($script:AdoApiVersion)"
        $items = Get-AdoRestAllPages -BaseUri $listUri
        $stillThere = $items.Items | Where-Object { $_.name -eq [string]$plan.resourceName -and [int]$_.id -eq [int]$plan.resourceId }
        Add-Check -Name "$($plan.resourceType) borrado" -Ok (-not [bool]$stillThere) -Detail $(if ($stillThere) { "TODAVIA EXISTE (id=$($stillThere.id))" } else { 'Confirmado: ya no existe' })
    }
    catch {
        Add-Check -Name "$($plan.resourceType) borrado" -Ok $false -Detail $_.Exception.Message
    }

    $results | Format-Table -AutoSize
    $allOk = -not ($results | Where-Object { -not $_.Ok })
    exit $(if ($allOk) { 0 } else { 1 })
}

Write-Host "Confirmando definicion de Build '$($plan.names.build)'..." -ForegroundColor Cyan
try {
    $builds = Get-AdoRestAllPages -BaseUri "$($script:AdoCoreBaseUrl)/$($plan.project)/_apis/build/definitions?name=$([uri]::EscapeDataString($plan.names.build))&api-version=$($script:AdoApiVersion)"
    $found = $builds.Items | Where-Object { $_.name -eq $plan.names.build }
    Add-Check -Name 'Build existe' -Ok ([bool]$found) -Detail $(if ($found) { "id=$($found.id)" } else { 'No encontrado' })
}
catch {
    Add-Check -Name 'Build existe' -Ok $false -Detail $_.Exception.Message
}

Write-Host "Confirmando definicion de Release '$($plan.names.release)'..." -ForegroundColor Cyan
try {
    $releases = Get-AdoRestAllPages -BaseUri "$($script:AdoReleaseBaseUrl)/$($plan.project)/_apis/release/definitions?searchText=$([uri]::EscapeDataString($plan.names.release))&api-version=$($script:AdoApiVersion)"
    $found = $releases.Items | Where-Object { $_.name -eq $plan.names.release }
    Add-Check -Name 'Release existe' -Ok ([bool]$found) -Detail $(if ($found) { "id=$($found.id)" } else { 'No encontrado' })
}
catch {
    Add-Check -Name 'Release existe' -Ok $false -Detail $_.Exception.Message
}

if ($plan.family -eq 'aks') {
    Write-Host "Confirmando Variable Group '$($plan.variableGroup.name)'..." -ForegroundColor Cyan
    try {
        $vgs = Get-AdoRestAllPages -BaseUri "$($script:AdoCoreBaseUrl)/$($plan.project)/_apis/distributedtask/variablegroups?groupName=$([uri]::EscapeDataString($plan.variableGroup.name))&api-version=$($script:AdoApiVersion)"
        $found = $vgs.Items | Where-Object { $_.name -eq $plan.variableGroup.name }
        Add-Check -Name 'Variable Group existe' -Ok ([bool]$found) -Detail $(if ($found) { "id=$($found.id)" } else { 'No encontrado' })
    }
    catch {
        Add-Check -Name 'Variable Group existe' -Ok $false -Detail $_.Exception.Message
    }
}

$results | Format-Table -AutoSize

$allOk = -not ($results | Where-Object { -not $_.Ok })
exit $(if ($allOk) { 0 } else { 1 })
