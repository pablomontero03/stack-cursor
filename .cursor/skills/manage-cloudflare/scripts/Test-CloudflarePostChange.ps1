<#
Readback de solo lectura tras aplicar un plan (change o delete). Vuelve a
leer (GET) cada recurso afectado y compara contra expectedFinalState /
expectedReadback declarados en el plan. Nunca escribe nada en Cloudflare.
#>
param(
    [Parameter(Mandatory)] [string]$PlanPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Cloudflare-Common.ps1')

if (-not (Test-Path -LiteralPath $PlanPath -PathType Leaf)) {
    throw "El plan '$PlanPath' no existe."
}
$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json

$operations = @(@($plan.approvedOperations) + @($plan.pendingDeleteOperations))
$results = [System.Collections.Generic.List[object]]::new()

foreach ($op in $operations) {
    $readback = $null
    if ($op.uri -and [string]$op.action -ne 'delete') {
        $readback = Invoke-CloudflareApiRequest -Method GET -Uri $op.uri
    }

    $matches = $null
    if ([string]$op.action -eq 'delete') {
        # Para un recurso eliminado, "coincide" significa que ya no se puede leer (404/vacio).
        $stillReadable = Invoke-CloudflareApiRequest -Method GET -Uri $op.uri
        $matches = ($null -eq $stillReadable)
    }
    elseif ($readback -and $op.expectedReadback) {
        $matches = ([string]($readback | ConvertTo-Json -Depth 10 -Compress)) -like "*$($op.expectedReadback)*"
    }
    else {
        $matches = $null
    }

    $results.Add([PSCustomObject]@{
        operationId    = [string]$op.operationId
        resourceType   = [string]$op.resourceType
        resourceId     = [string]$op.resourceId
        expectedFinalState = [string]$op.expectedFinalState
        matches        = $matches
    })
}

[PSCustomObject]@{ readback = @($results) } | ConvertTo-Json -Depth 10
