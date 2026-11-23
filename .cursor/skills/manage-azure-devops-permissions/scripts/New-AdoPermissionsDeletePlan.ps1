<#
Genera un plan de eliminacion (operationKind='destructive') con EXACTAMENTE
una eliminacion: un grupo de seguridad (SecurityGroup) o una membresia
(GroupMembership). Nunca agrupa varias eliminaciones. No toca la red.

Uso:
  .\New-AdoPermissionsDeletePlan.ps1 -ResourceType SecurityGroup -GroupDescriptor 'vssgp.X' -InventoryPath '...' -OutPath '...'
  .\New-AdoPermissionsDeletePlan.ps1 -ResourceType GroupMembership -MemberDescriptor 'aad.X' -ContainerDescriptor 'vssgp.Y' -InventoryPath '...' -OutPath '...'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('SecurityGroup', 'GroupMembership')]
    [string]$ResourceType,

    [Parameter(Mandatory)]
    [string]$InventoryPath,

    [string]$GroupDescriptor,
    [string]$MemberDescriptor,
    [string]$ContainerDescriptor,

    [string]$Reason,

    [string]$OutPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'Invoke-AdoPermissionsRest.ps1')

if (-not (Test-Path -LiteralPath $InventoryPath)) {
    throw "New-AdoPermissionsDeletePlan rechazado: no se encontro el inventario '$InventoryPath'."
}
$inventoryRaw = Get-Content -LiteralPath $InventoryPath -Raw -Encoding UTF8
$inventory = $inventoryRaw | ConvertFrom-Json
$inventoryHash = Get-AdoPermissionsSha256OfText -Text ([string]::new($inventoryRaw.ToCharArray()))

$graphBase = 'https://vssps.dev.azure.com/Shared-Service-GM'

if ($ResourceType -eq 'SecurityGroup') {
    if ([string]::IsNullOrWhiteSpace($GroupDescriptor)) {
        throw "New-AdoPermissionsDeletePlan rechazado: -GroupDescriptor es obligatorio para -ResourceType SecurityGroup."
    }
    $foundGroup = $null
    foreach ($proj in @($inventory.projects)) {
        foreach ($cand in @($proj.groups.developmentTeamCandidates)) {
            if ($cand -and $cand.descriptor -eq $GroupDescriptor) { $foundGroup = $cand }
        }
        if ($proj.groups.codeReviewers -and $proj.groups.codeReviewers.descriptor -eq $GroupDescriptor) { $foundGroup = $proj.groups.codeReviewers }
    }
    if (-not $foundGroup) {
        throw "New-AdoPermissionsDeletePlan rechazado: el descriptor '$GroupDescriptor' no aparece como Development Team/Development Teams/Code-Reviewers en el inventario. Este mecanismo solo elimina grupos administrados por este dominio."
    }

    $uri = "$graphBase/_apis/graph/groups/$([uri]::EscapeDataString($GroupDescriptor))?api-version=$($script:AdoPermissionsGraphApiVersion)"
    $entry = [ordered]@{
        operationId   = 'delete-001'
        operationType = 'delete-security-group'
        method        = 'DELETE'
        uri           = $uri
        body          = $null
        bodyHash      = Get-AdoPermissionsBodyCanonicalHash -Body $null
        precondition  = [ordered]@{ groupDescriptor = $GroupDescriptor; expectedDisplayName = [string]$foundGroup.displayName }
    }
    $resourceSummary = "Grupo '$($foundGroup.displayName)' ($GroupDescriptor)"
}
else {
    if ([string]::IsNullOrWhiteSpace($MemberDescriptor) -or [string]::IsNullOrWhiteSpace($ContainerDescriptor)) {
        throw "New-AdoPermissionsDeletePlan rechazado: -MemberDescriptor y -ContainerDescriptor son obligatorios para -ResourceType GroupMembership."
    }
    $foundMembership = $false
    $containerDisplayName = $null
    foreach ($proj in @($inventory.projects)) {
        foreach ($cand in @($proj.groups.developmentTeamCandidates)) {
            if ($cand -and $cand.descriptor -eq $ContainerDescriptor -and (@($cand.members) -contains $MemberDescriptor)) { $foundMembership = $true; $containerDisplayName = $cand.displayName }
        }
        if ($proj.groups.codeReviewers -and $proj.groups.codeReviewers.descriptor -eq $ContainerDescriptor -and (@($proj.groups.codeReviewers.members) -contains $MemberDescriptor)) {
            $foundMembership = $true; $containerDisplayName = $proj.groups.codeReviewers.displayName
        }
    }
    if (-not $foundMembership) {
        throw "New-AdoPermissionsDeletePlan rechazado: no se encontro la membresia de '$MemberDescriptor' en '$ContainerDescriptor' dentro del inventario."
    }

    $uri = "$graphBase/_apis/graph/memberships/$([uri]::EscapeDataString($MemberDescriptor))/$([uri]::EscapeDataString($ContainerDescriptor))?api-version=$($script:AdoPermissionsGraphApiVersion)"
    $entry = [ordered]@{
        operationId   = 'delete-001'
        operationType = 'remove-group-membership'
        method        = 'DELETE'
        uri           = $uri
        body          = $null
        bodyHash      = Get-AdoPermissionsBodyCanonicalHash -Body $null
        precondition  = [ordered]@{ memberDescriptor = $MemberDescriptor; containerDescriptor = $ContainerDescriptor; expectedContainerDisplayName = [string]$containerDisplayName }
    }
    $resourceSummary = "Membresia de '$MemberDescriptor' en '$containerDisplayName' ($ContainerDescriptor)"
}

$plan = [PSCustomObject]@{
    schemaVersion       = 1
    operationKind       = 'destructive'
    resourceType        = $ResourceType
    resourceSummary     = $resourceSummary
    reason              = $Reason
    generatedAtUtc      = (Get-Date).ToUniversalTime().ToString('o')
    organization        = 'Shared-Service-GM'
    inventoryPath       = (Resolve-Path -LiteralPath $InventoryPath).ProviderPath
    inventoryHash       = $inventoryHash
    backupRequired      = $true
    approvedOperations  = @([PSCustomObject]$entry)
    notes               = @()
    validationBlockers  = @()
    validated           = $false
    lastValidatedAtUtc  = $null
    validationWarnings  = @()
    validationEvidence  = $null
    validationHash      = $null
}

if (-not $OutPath) {
    $projectRoot = if ($env:REPO_ROOT) { $env:REPO_ROOT } else { (Get-Location).Path }
    $plansDir = Join-Path $projectRoot '.local\azure-devops-permissions\plans'
    if (-not (Test-Path -LiteralPath $plansDir)) { New-Item -ItemType Directory -Force -Path $plansDir | Out-Null }
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $OutPath = Join-Path $plansDir "permissions-delete-$ResourceType-$timestamp.json"
}

$plan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutPath -Encoding utf8
Write-Host "Plan de eliminacion escrito en: $OutPath" -ForegroundColor Yellow
Write-Host "Recurso a eliminar: $resourceSummary" -ForegroundColor Yellow
return $OutPath
