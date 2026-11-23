<#
Readback de solo lectura tras un Apply (no destructivo o destructivo).
Vuelve a consultar cada resourceId del plan y compara contra
expectedFinalState + desiredState -- no ejecuta ninguna escritura. Se usa
tanto despues de Apply-AzureChangePlan.ps1 (fase 8 del flujo) como despues
de Apply-AzureDeletePlan.ps1 (fase 6).

Uso:
  & '.\Test-AzurePostChange.ps1' -PlanPath plan.json
#>
param([Parameter(Mandatory)] [string]$PlanPath)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Azure-Common.ps1')

if (-not (Test-Path -LiteralPath $PlanPath)) {
    throw "Test-AzurePostChange rechazado: no existe el plan '$PlanPath'."
}
$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json

$journalPath = Get-AzureExecutionJournalPath -PlanValidationHash ([string]$plan.validationHash)
$journal = $null
if (Test-Path -LiteralPath $journalPath) {
    $journal = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
}

$results = [System.Collections.Generic.List[object]]::new()
$allOps = @(@($plan.approvedOperations) + @($plan.pendingDeleteOperations))

foreach ($op in $allOps) {
    $opId = [string]$op.operationId
    $journalState = if ($journal -and $journal.operations.$opId) { [string]$journal.operations.$opId.state } else { 'unknown' }

    $liveResource = $null
    $existsNow = $false
    if ($journalState -ne 'unknown') {
        $raw = & az resource show --ids $op.resourceId --output json 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]($raw | Out-String))) {
            $existsNow = $true
            try { $liveResource = ($raw | Out-String) | ConvertFrom-Json } catch { $liveResource = $null }
        }
    }

    $expectedToExist = -not [bool]$op.destructive
    $matchesExpectation = ($existsNow -eq $expectedToExist)

    $results.Add([PSCustomObject]@{
        operationId         = $opId
        journalState        = $journalState
        existsNow           = $existsNow
        expectedToExist     = $expectedToExist
        matchesExpectation  = $matchesExpectation
        expectedFinalState  = [string]$op.expectedFinalState
        location            = if ($liveResource) { [string]$liveResource.location } else { $null }
        provisioningState   = if ($liveResource -and $liveResource.properties) { [string]$liveResource.properties.provisioningState } else { $null }
    })
}

$mismatches = @($results | Where-Object { -not $_.matchesExpectation })

[PSCustomObject]@{
    planValidationHash = [string]$plan.validationHash
    checkedAtUtc        = (Get-Date).ToUniversalTime().ToString('o')
    operationResults     = @($results)
    mismatchCount        = $mismatches.Count
    allMatch             = ($mismatches.Count -eq 0)
}
