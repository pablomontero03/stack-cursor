<#
Aplica un plan de replicacion de Branch Policies ya validado
(Test-AdoPolicyPlan.ps1, validated=true, validationHash vigente). Crea
las Policy Configurations reales en Azure DevOps (POST), una por
operacion aprobada, usando Invoke-AdoPermissionsRest -RequireApprovedPlan.

NUNCA actualiza ni elimina una policy existente -- este plan solo contiene
creaciones (New-AdoPolicyPlan.ps1 ya excluye cualquier policy que
duplicaria una existente).

El hook de seguridad (ado-permissions-security-gate.ps1) pide confirmacion
explicita del usuario por el nombre de este script, misma politica que
Apply-AdoPermissionsPlan.ps1.

Uso:
  & '.\Apply-AdoPolicyPlan.ps1' -PlanPath '...\plan.json'
#>

param(
    [Parameter(Mandatory)] [string]$PlanPath
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Invoke-AdoPermissionsRest.ps1')

if (-not (Test-Path -LiteralPath $PlanPath)) { throw "No existe el plan: $PlanPath" }

$plan = Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8 | ConvertFrom-Json

if ($plan.kind -ne 'ado-policy-configuration-plan') {
    throw "El plan no tiene kind='ado-policy-configuration-plan'."
}
if (-not $plan.validated -or $plan.validated -ne $true) {
    throw "El plan no esta validado (validated=true). Ejecutar Test-AdoPolicyPlan.ps1 primero."
}

$currentHash = Get-AdoPermissionsPlanCanonicalHash -Plan $plan
if ($currentHash -ne $plan.validationHash) {
    throw "El contenido del plan cambio despues de validarlo (validationHash no coincide). Volver a validar."
}

Assert-AdoPermissionsPlanIsNonDestructive -Plan $plan

$approvedOps = @($plan.approvedOperations)
if ($approvedOps.Count -eq 0) {
    Write-Output 'El plan no tiene operaciones aprobadas. Nada que aplicar.'
    return
}

$results = [System.Collections.Generic.List[object]]::new()

foreach ($op in $approvedOps) {
    $label = "$($op.operationId) ($($op.typeName) / $($op.branch))"
    try {
        $response = Invoke-AdoPermissionsRest -Method POST -Uri ([string]$op.uri) -Body $op.body -RequireApprovedPlan -PlanPath $PlanPath -OperationId ([string]$op.operationId)
        $newId = if ($response.Body -and ($response.Body.PSObject.Properties.Name -contains 'id')) { $response.Body.id } else { $null }
        Write-Output "OK   $label -> creado (id destino: $newId)"
        $results.Add([ordered]@{ operationId = $op.operationId; status = 'created'; newPolicyId = $newId })
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -match "ya tiene estado 'succeeded'") {
            Write-Output "SKIP $label -> ya se habia aplicado antes (journal: succeeded)."
            $results.Add([ordered]@{ operationId = $op.operationId; status = 'already-applied' })
        }
        else {
            Write-Output "FAIL $label -> $msg"
            $results.Add([ordered]@{ operationId = $op.operationId; status = 'failed'; error = $msg })
        }
    }
}

Write-Output ''
Write-Output 'Resumen:'
$results | Group-Object status | ForEach-Object { Write-Output "  $($_.Name): $($_.Count)" }
