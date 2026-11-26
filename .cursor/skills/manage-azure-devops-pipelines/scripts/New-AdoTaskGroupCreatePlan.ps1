<#
Runner versionado que cierra el gap identificado 2026-10-29 (pipeline
service-bdip worker): no existia forma versionada de CREAR/CLONAR un task
group -- habia que hacerlo a mano en la UI de ADO. Este runner genera un plan
family='tg-create' (POST a distributedtask/taskgroups), que Test-AdoClassicPlan.ps1
valida y Apply-AdoClassicPlan.ps1 (Fase 1d) aplica con su propia aprobacion
separada (un task group es un recurso COMPARTIDO -> approval-matrix.md).

Deliberadamente DELGADO: la logica real vive en
Invoke-AdoTaskGroupCreatePlanGeneration (New-AdoClassicUpdatePayload.ps1), para
poder probarla dot-sourceada -- mismo patron que New-AdoClassicUpdatePlan.ps1 /
New-AdoTaskGroupUpdatePlan.ps1. NUNCA escribe a Azure DevOps ni hace red: todo
sale de disco.

Reusa Invoke-AdoTaskGroupMutation (el mismo switch cerrado de tg-update) para
que un clon nazca ya con los inputs/mapeos deseados en UNA operacion.

Uso (clonar Build-MultiStage y, en el mismo paso, exponer 'arguments' y
mapearlo a la tarea Docker buildAndPush -- lo que para BDIP se hizo en 2 pasos
manuales):

  pwsh -NoProfile -File ./New-AdoTaskGroupCreatePlan.ps1 `
    -NewName 'Build-MultiStage-Worker' `
    -SourceTaskGroupJsonPath '...\tg-build-multistage.json' `
    -MutationSpecPath '...\mutations.json' `
    -OperationId 'create-tg-worker' `
    -OutBodyPath '...\tg-body.json' -OutPlanPath '...\plan-tg-create.json'

Uso (from-scratch, body ya armado, sin mutaciones):

  pwsh -NoProfile -File ./New-AdoTaskGroupCreatePlan.ps1 `
    -NewName 'Mi-TG-Nuevo' -BodyJsonPath '...\body.json' `
    -OperationId 'create-tg-nuevo' -OutBodyPath '...\b.json' -OutPlanPath '...\p.json'

Forma de -MutationSpecPath: igual que New-AdoTaskGroupUpdatePlan.ps1
(array de { mutation: 'ExposeInput'|'MapTaskInput', ... }). Despues de generar,
correr Test-AdoClassicPlan.ps1 para validar/sellar el plan.
#>

param(
    [Parameter(Mandatory)] [string]$NewName,
    [Parameter(Mandatory)] [string]$OperationId,
    [Parameter(Mandatory)] [string]$OutBodyPath,
    [Parameter(Mandatory)] [string]$OutPlanPath,
    [string]$SourceTaskGroupJsonPath,
    [string]$BodyJsonPath,
    [string]$MutationSpecPath,
    [string]$Project = 'DevOps',
    [string]$Organization = 'Shared-Service-GM'
)

$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'Invoke-AdoRest.ps1')
. (Join-Path $scriptRoot 'New-AdoClassicPayloads.ps1')
. (Join-Path $scriptRoot 'New-AdoClassicUpdatePayload.ps1')

$result = Invoke-AdoTaskGroupCreatePlanGeneration @PSBoundParameters

Write-Host "Body POST (create-taskgroup) escrito en: $($result.BodyPath)" -ForegroundColor Green
Write-Host "Plan tg-create escrito en: $($result.PlanPath)" -ForegroundColor Green
Write-Host "Task group nuevo: '$($result.NewName)' | Mutaciones: $(if ($result.AppliedMutations.Count -gt 0) { $result.AppliedMutations -join ', ' } else { '(ninguna)' })" -ForegroundColor Green
Write-Host "operationId: $($result.ApprovedOperation.operationId) | operationType: $($result.ApprovedOperation.operationType)" -ForegroundColor Green
Write-Host "Siguiente: validar con Test-AdoClassicPlan.ps1 -PlanPath '$($result.PlanPath)' (sin -InventoryPath: tg-create no usa inventario)." -ForegroundColor Cyan
