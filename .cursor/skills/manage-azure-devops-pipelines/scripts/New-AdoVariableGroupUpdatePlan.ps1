<#
Runner versionado (2026-10-29) que cierra el ultimo gap de la capacidad
update-variable-group (agregada 2026-10-14: payload + Apply Fase 1b + Test,
pero SIN generador de plan ni tests): genera un plan family='vg-update' con
una entrada approvedOperations 'update-variable-group' (PUT) cuyo bodyHash se
calcula sobre EXACTAMENTE el body que Apply reconstruira
(New-AdoVariableGroupUpdatePayload -Plan -CurrentVariableGroup).

Soporta variables SECRETAS (agregado 2026-10-29 para dejar los VG dev/uat
igual a cotizadores): una entrada del spec con 'secretEnvVar' se embebe como
placeholder '${ADO_SECRET_...}' + isSecret=true; Apply resuelve el valor real
en memoria (New-AdoBodyWithResolvedSecrets) antes del PUT. El secreto NUNCA se
embebe en claro ni se hashea.

Deliberadamente DELGADO: la logica real vive en New-AdoVariableGroupUpdatePayload
y New-AdoApprovedOperationEntry. NO hace GET de red: el VG actual se provee
desde disco (-CurrentVariableGroupJsonPath, un GET read-only del operador, el
MISMO que luego se pasa como -CurrentVariableGroupJson a Apply). NUNCA escribe
en Azure DevOps.

Uso:
  pwsh -NoProfile -File ./New-AdoVariableGroupUpdatePlan.ps1 `
    -VariableGroupId 521 `
    -CurrentVariableGroupJsonPath '...\vg-521.json' `
    -VariableSpecPath '...\vg-creds-spec.json' `
    -OperationId 'vg-update-bdip-dev' `
    -OutPlanPath '...\plan-vg-update-dev.json'

Forma de -VariableSpecPath (JSON object nombre->valor; un secreto es un objeto):
  {
    "containerRegistryUsername": "gmonhubacreastus20001",
    "containerRegistryPassword": { "secretEnvVar": "ADO_SECRET_CONTAINERREGISTRYPASSWORD" }
  }
Despues de generar, correr Test-AdoClassicPlan.ps1 (sin -InventoryPath) para validar/sellar.
#>

param(
    [Parameter(Mandatory)] [int]$VariableGroupId,
    [Parameter(Mandatory)] [string]$CurrentVariableGroupJsonPath,
    [Parameter(Mandatory)] [string]$VariableSpecPath,
    [Parameter(Mandatory)] [string]$OperationId,
    [Parameter(Mandatory)] [string]$OutPlanPath,
    [string]$Project = 'DevOps',
    [string]$Organization = 'Shared-Service-GM'
)

$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'Invoke-AdoRest.ps1')
. (Join-Path $scriptRoot 'New-AdoClassicPayloads.ps1')
. (Join-Path $scriptRoot 'New-AdoClassicUpdatePayload.ps1')

if ($Organization -ne 'Shared-Service-GM') { throw "New-AdoVariableGroupUpdatePlan rechazado: solo organizacion 'Shared-Service-GM'." }
if ($VariableGroupId -le 0) { throw "New-AdoVariableGroupUpdatePlan rechazado: -VariableGroupId debe ser entero positivo." }
foreach ($p in @($CurrentVariableGroupJsonPath, $VariableSpecPath)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "New-AdoVariableGroupUpdatePlan rechazado: no existe '$p'." }
}

# VG actual desde disco (GET devuelve objeto directo o { value:[...] }).
$rawParsed = Get-Content -LiteralPath $CurrentVariableGroupJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
$currentVG = if ($rawParsed.PSObject.Properties['value'] -and $null -ne $rawParsed.value) { @($rawParsed.value)[0] } else { $rawParsed }
if ($null -eq $currentVG -or -not $currentVG.PSObject.Properties['id']) { throw "New-AdoVariableGroupUpdatePlan rechazado: el JSON no es un VG valido (sin 'id')." }
if ([int]$currentVG.id -ne [int]$VariableGroupId) { throw "New-AdoVariableGroupUpdatePlan rechazado: el VG del archivo (id=$($currentVG.id)) no coincide con -VariableGroupId ($VariableGroupId)." }

# Spec de variables -> hashtable del plan (string plano, u objeto {secretEnvVar}).
$specParsed = Get-Content -LiteralPath $VariableSpecPath -Raw -Encoding UTF8 | ConvertFrom-Json
$planVars = [ordered]@{}
foreach ($prop in $specParsed.PSObject.Properties) {
    $v = $prop.Value
    if ($v -is [System.Management.Automation.PSObject] -and $null -ne $v.PSObject.Properties['secretEnvVar']) {
        $planVars[$prop.Name] = @{ secretEnvVar = [string]$v.secretEnvVar }
    } else {
        $planVars[$prop.Name] = [string]$v
    }
}
if ($planVars.Count -eq 0) { throw "New-AdoVariableGroupUpdatePlan rechazado: -VariableSpecPath no trae variables." }

# Plan parcial para pasar al payload (mismo objeto que Apply usara).
$planForPayload = [pscustomobject]@{
    project             = $Project
    variableGroupUpdate = [pscustomobject]@{ id = $VariableGroupId; variables = $planVars }
}
# Body aprobado = EXACTAMENTE lo que Apply reconstruye (con placeholders de secreto).
$approvedBody = New-AdoVariableGroupUpdatePayload -Plan $planForPayload -CurrentVariableGroup $currentVG

$uri = "$($script:AdoCoreBaseUrl)/$Project/_apis/distributedtask/variablegroups/$VariableGroupId`?api-version=$($script:AdoApiVersion)"
$null = Assert-AdoOperationRequestMatchesSpec -OperationType 'update-variable-group' -Method 'PUT' -Uri $uri -Label 'vg-update-plan-generation'
$approvedOperation = New-AdoApprovedOperationEntry -OperationId $OperationId -OperationType 'update-variable-group' -Uri $uri -Body $approvedBody

$secretVarNames = @($planVars.Keys | Where-Object { $planVars[$_] -is [hashtable] -and $planVars[$_].ContainsKey('secretEnvVar') })

$plan = [ordered]@{
    family              = 'vg-update'
    organization        = $Organization
    project             = $Project
    variableGroupUpdate = [ordered]@{ id = $VariableGroupId; variables = $planVars }
    approvedOperations  = @($approvedOperation)
    validated           = $false
    validationHash      = $null
    validationEvidence  = $null
    notes               = @(
        "Plan vg-update generado por New-AdoVariableGroupUpdatePlan.ps1 -- ninguna escritura en Azure DevOps ejecutada.",
        "Agrega/actualiza variables en el VG EXISTENTE id=$VariableGroupId (Apply exige -CurrentVariableGroupJson para preservar las demas).",
        "Variables: $(@($planVars.Keys) -join ', '). Secretas: $(if ($secretVarNames.Count) { $secretVarNames -join ', ' } else { '(ninguna)' }).",
        "Un secreto va como placeholder; Apply lo resuelve en memoria, nunca se embebe el valor real."
    )
}
$planJson = $plan | ConvertTo-Json -Depth 60
$enc = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($OutPlanPath, $planJson, $enc)

Write-Host "Plan vg-update escrito en: $OutPlanPath" -ForegroundColor Green
Write-Host "Variables: $(@($planVars.Keys) -join ', ')" -ForegroundColor Green
Write-Host "Secretas: $(if ($secretVarNames.Count) { $secretVarNames -join ', ' } else { '(ninguna)' })" -ForegroundColor Green
Write-Host "operationId: $($approvedOperation.operationId) | operationType: $($approvedOperation.operationType)" -ForegroundColor Green
Write-Host "Siguiente: Test-AdoClassicPlan.ps1 -PlanPath '$OutPlanPath' (sin -InventoryPath)." -ForegroundColor Cyan
