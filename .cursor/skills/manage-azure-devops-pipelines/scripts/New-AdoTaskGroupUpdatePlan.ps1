<#
Runner versionado que cierra el gap identificado 2026-10-29 (pipeline
service-bdip worker): la infra family='tg-update' ya existia en
Test-AdoClassicPlan.ps1 (validacion) y Apply-AdoClassicPlan.ps1 (Fase 1c,
operationType 'update-taskgroup' + -CurrentTaskGroupJson) desde 2026-10-16,
pero NINGUN script versionado GENERABA el plan (embeber el body del task
group + computar su bodyHash canonico). Construirlo exigia, hasta hoy, un
script de scratch ad hoc -- prohibido por el rol. Este archivo es ese
runner, UNA sola vez, versionado, revisable y probado.

Deliberadamente DELGADO: toda la logica real vive en
Invoke-AdoTaskGroupUpdatePlanGeneration (New-AdoClassicUpdatePayload.ps1),
para poder probarla dot-sourceada con Invoke-AdoRest mockeado -- mismo
patron que New-AdoClassicUpdatePlan.ps1 (delgado) + su funcion real. Este
archivo NUNCA agrega logica nueva -- solo el bloque param() para invocacion
por linea de comandos, el dot-sourcing en el orden requerido, y los
Write-Host de resumen final.

A diferencia de New-AdoClassicUpdatePlan.ps1 (Build/Release), este NO hace
GET de red: el body actual del task group se provee desde disco
(-CurrentTaskGroupJsonPath, el mismo JSON que luego se pasa como
-CurrentTaskGroupJson a Apply-AdoClassicPlan.ps1). NUNCA escribe a Azure
DevOps -- la escritura real (PUT) sigue siendo exclusiva de
Apply-AdoClassicPlan.ps1, con su propia aprobacion separada (un task group
es un recurso COMPARTIDO: approval-matrix.md lo marca como "siempre requiere
aprobacion separada").

Las mutaciones se describen en -MutationSpecPath (JSON array) y se despachan
SIEMPRE contra un switch literal cerrado (Invoke-AdoTaskGroupMutation) --
nunca Invoke-Expression, nunca '&'-dinamico. Mutaciones permitidas:
ExposeInput, MapTaskInput.

Uso (exponer 'arguments' en un clon de Build-MultiStage y mapearlo a la
tarea Docker buildAndPush, para pasar 'docker build --target <stage>'):

  pwsh -NoProfile -File ./New-AdoTaskGroupUpdatePlan.ps1 `
    -TaskGroupId 'a0f24cee-4948-47bc-8491-a20de85301b9' `
    -CurrentTaskGroupJsonPath '...\tg-clone.json' `
    -MutationSpecPath '...\mutations-bdip.json' `
    -OperationId 'expose-arguments-bdip-tg' `
    -OutBodyPath '...\tg-body-bdip.json' `
    -OutPlanPath '...\plan-tg-bdip.json'

Forma de -MutationSpecPath:
  [
    { "mutation": "ExposeInput", "Name": "arguments", "HelpMarkDown": "Docker build extra args, p.ej. --target worker" },
    { "mutation": "MapTaskInput", "TaskId": "e28912f1-0114-4464-802a-a3a35437fd16", "InputName": "arguments", "InputValue": "$(arguments)" }
  ]
Las claves (fuera de 'mutation') se pasan por splatting a
Invoke-AdoTaskGroupMutation. Despues de generar, correr Test-AdoClassicPlan.ps1
para validar y sellar el plan.
#>

param(
    [Parameter(Mandatory)] [string]$TaskGroupId,
    [Parameter(Mandatory)] [string]$CurrentTaskGroupJsonPath,
    [Parameter(Mandatory)] [string]$MutationSpecPath,
    [Parameter(Mandatory)] [string]$OperationId,
    [Parameter(Mandatory)] [string]$OutBodyPath,
    [Parameter(Mandatory)] [string]$OutPlanPath,
    [string]$Project = 'DevOps',
    [string]$Organization = 'Shared-Service-GM'
)

$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'Invoke-AdoRest.ps1')
. (Join-Path $scriptRoot 'New-AdoClassicPayloads.ps1')
. (Join-Path $scriptRoot 'New-AdoClassicUpdatePayload.ps1')

$result = Invoke-AdoTaskGroupUpdatePlanGeneration @PSBoundParameters

Write-Host "Body PUT (update-taskgroup) escrito en: $($result.BodyPath)" -ForegroundColor Green
Write-Host "Plan tg-update escrito en: $($result.PlanPath)" -ForegroundColor Green
Write-Host "Mutaciones aplicadas: $($result.AppliedMutations -join ', ')" -ForegroundColor Green
Write-Host "operationId: $($result.ApprovedOperation.operationId) | operationType: $($result.ApprovedOperation.operationType)" -ForegroundColor Green
Write-Host "Siguiente: validar con Test-AdoClassicPlan.ps1 -PlanPath '$($result.PlanPath)' (sin -InventoryPath: tg-update no usa inventario)." -ForegroundColor Cyan
