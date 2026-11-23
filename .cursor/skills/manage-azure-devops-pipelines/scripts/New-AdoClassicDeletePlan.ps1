<#
Genera un plan de BORRADO para UN solo recurso clasico existente
(Variable Group, Build o Release), a partir de un inventario fresco.
Nunca borra nada -- solo arma el archivo de plan que despues
Test-AdoClassicDeletePlan.ps1 valida (confirma que el recurso existe de
verdad, con el id exacto) y Apply-AdoClassicPlan.ps1 aplica (con
respaldo de solo lectura OBLIGATORIO antes del DELETE real -- ver
New-AdoClassicPayloads.ps1, Invoke-AdoApplyPhases, Fase 6).

Agregado 2026-08-26: borrar un Build/Release/Variable Group NUNCA fue
soportado por esta skill hasta hoy (ni el MCP oficial de Azure DevOps ni
Apply-AdoClassicPlan.ps1 tenian una operationType de borrado). Se agrega
tras una prueba real donde el usuario borro estos 3 tipos de recurso a
mano desde el portal para validar la reconstruccion completa del
generador -- ver memoria de sesion [[ado-e2e-rebuild-test-2026-08-26]].

Este plan NUNCA borra por si solo -- sigue exigiendo el mismo flujo de
siempre: Test-AdoClassicPlan.ps1 (aca, la variante de borrado) ->
aprobacion explicita del usuario -> Apply-AdoClassicPlan.ps1 (que
respalda antes de borrar, sin excepcion).

Uso:
  powershell -File .\New-AdoClassicDeletePlan.ps1 `
    -ResourceType VariableGroup -ResourceName 'Desarrollo-administracion-proyectos-web' `
    -InventoryPath '...\inventory-....json' -OutPath '...\plans\delete-....json'
#>
param(
    [Parameter(Mandatory)] [ValidateSet('VariableGroup', 'BuildDefinition', 'ReleaseDefinition')] [string]$ResourceType,
    [Parameter(Mandatory)] [string]$ResourceName,
    [Parameter(Mandatory)] [string]$InventoryPath,
    [string]$Project = 'DevOps',
    [string]$Organization = 'Shared-Service-GM',
    [Parameter(Mandatory)] [string]$OutPath
)

$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'Invoke-AdoRest.ps1')
. (Join-Path $scriptRoot 'New-AdoClassicPayloads.ps1')

if ($Organization -ne 'Shared-Service-GM') {
    throw "New-AdoClassicDeletePlan rechazado: esta skill solo opera sobre la organizacion 'Shared-Service-GM'."
}

if (-not (Test-Path -LiteralPath $InventoryPath)) {
    throw "New-AdoClassicDeletePlan rechazado: no existe el inventario '$InventoryPath'. Generar uno fresco con Export-AdoClassicInventory.ps1 primero."
}
$inventory = Get-Content -LiteralPath $InventoryPath -Raw | ConvertFrom-Json

$resourceMap = @{
    VariableGroup     = @{ collection = 'variableGroups'; operationType = 'delete-variable-group'; uriSuffix = 'distributedtask/variablegroups' }
    BuildDefinition   = @{ collection = 'buildDefinitions'; operationType = 'delete-build-definition'; uriSuffix = 'build/definitions' }
    ReleaseDefinition = @{ collection = 'releaseDefinitions'; operationType = 'delete-release-definition'; uriSuffix = 'release/definitions' }
}
$map = $resourceMap[$ResourceType]

if (-not $inventory.PSObject.Properties[$map.collection] -or $null -eq $inventory.$($map.collection)) {
    throw "New-AdoClassicDeletePlan rechazado: el inventario en '$InventoryPath' no tiene la coleccion '$($map.collection)' -- no es un inventario valido de Export-AdoClassicInventory.ps1 para este proyecto."
}

# Nunca se inventa un id: el recurso debe existir de verdad en el
# inventario fresco, con el nombre EXACTO (sin match parcial), y debe
# haber exactamente uno -- un nombre ambiguo (mas de un resultado) se
# rechaza en vez de adivinar cual borrar.
$candidates = @($inventory.$($map.collection) | Where-Object { $_.name -eq $ResourceName })
if ($candidates.Count -eq 0) {
    throw "New-AdoClassicDeletePlan rechazado: no se encontro ningun $ResourceType llamado '$ResourceName' en el inventario. No se arma un plan de borrado para un recurso que no existe."
}
if ($candidates.Count -gt 1) {
    throw "New-AdoClassicDeletePlan rechazado: se encontraron $($candidates.Count) recursos $ResourceType llamados '$ResourceName' en el inventario -- ambiguo, resolver a mano cual id borrar antes de generar este plan."
}
$resource = $candidates[0]
$resourceId = [int]$resource.id

$baseUrl = if ($ResourceType -eq 'ReleaseDefinition') { $script:AdoReleaseBaseUrl } else { $script:AdoCoreBaseUrl }
$uri = "$baseUrl/$Project/_apis/$($map.uriSuffix)/$resourceId" + "?api-version=$($script:AdoApiVersion)"

# Confirmar que la uri armada cumple EXACTO el contrato del operationType
# -- misma funcion que usa Test-AdoClassicDeletePlan.ps1/Invoke-AdoRest,
# para que un bug en la construccion de arriba se detecte aca mismo, no
# recien al aplicar.
$null = Assert-AdoOperationRequestMatchesSpec -OperationType $map.operationType -Method 'DELETE' -Uri $uri -Label 'plan-generation'

$operationId = "delete-$($ResourceType.ToLowerInvariant())-$resourceId"
$approvedOperation = New-AdoApprovedOperationEntry -OperationId $operationId -OperationType $map.operationType -Uri $uri -Body $null

$plan = [ordered]@{
    operationKind      = 'delete'
    generatedAtUtc     = (Get-Date).ToUniversalTime().ToString('o')
    organization       = $Organization
    project            = $Project
    resourceType       = $ResourceType
    resourceName       = $ResourceName
    resourceId         = $resourceId
    validated          = $false
    backupRequired     = $true
    approvedOperations = @($approvedOperation)
    notes              = @(
        "Plan de borrado generado sin ejecutar ningun cambio en Azure DevOps.",
        "resourceId=$resourceId resuelto contra el inventario fresco '$InventoryPath' (nunca inventado).",
        "backupRequired=true es fijo, no configurable -- Apply-AdoClassicPlan.ps1 (Fase 6) escribe un respaldo de solo lectura del recurso completo antes de cualquier DELETE real, sin excepcion."
    )
    validationBlockers = @()
    validationWarnings = @()
    validationEvidence = $null
    validationHash     = $null
}

$json = $plan | ConvertTo-Json -Depth 20
[System.IO.File]::WriteAllText($OutPath, $json, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Plan de borrado escrito en: $OutPath" -ForegroundColor Green
Write-Host "$ResourceType '$ResourceName' (id=$resourceId) -- correr Test-AdoClassicDeletePlan.ps1 antes de poder aplicar." -ForegroundColor Cyan
