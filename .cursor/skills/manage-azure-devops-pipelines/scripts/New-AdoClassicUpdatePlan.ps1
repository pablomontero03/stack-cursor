<#
Runner versionado que cierra el 2do gap identificado 2026-08-27 (ver
memoria de agente ado-emr-scratch-script-authorization-declined-2026-08-27
y el header de New-AdoClassicUpdatePayload.ps1): ese archivo solo exponia
una LIBRERIA composable (field-stripping + splices) para armar el body PUT
de update-build-definition/update-release-definition -- construir el plan
real seguia exigiendo, hasta hoy, un script de scratch ad hoc distinto por
cada microservicio. Este archivo es ese runner, UNA sola vez, versionado,
revisable y probado.

Deliberadamente DELGADO: toda la logica real vive en la funcion
Invoke-AdoClassicUpdatePlanGeneration (New-AdoClassicUpdatePayload.ps1),
para poder probarla dot-sourceada con Invoke-AdoRest/Invoke-WebRequest
mockeados -- mismo patron que Apply-AdoClassicPlan.ps1 (delgado) +
Invoke-AdoApplyPhases (logica real, en New-AdoClassicPayloads.ps1). Este
archivo NUNCA agrega logica nueva -- solo el bloque param() para invocacion
por linea de comandos, el dot-sourcing en el orden requerido, y los
Write-Host de resumen final.

Flujo que ejecuta (ver el header de Invoke-AdoClassicUpdatePlanGeneration
para el detalle completo paso a paso). Nunca escribe a Azure DevOps -- la
unica llamada de red que hace es un GET de solo lectura del recurso a
actualizar; la escritura real sigue siendo exclusiva de
Apply-AdoClassicPlan.ps1, con su propia aprobacion explicita por fuera de
este script.

El nombre de funcion de cada splice se despacha SIEMPRE contra un 'switch'
literal cerrado (Invoke-AdoUpdateSplice) -- nunca Invoke-Expression, nunca
'&'-dinamico sobre un string, nunca Get-Command/reflexion abierta sobre el
nombre recibido de -SpliceSpecPath. Un nombre que no este en ese switch
literal se rechaza sin ejecutar nada.

Uso (Kind Build, esqueleto nuevo, familia aks):
  powershell -File .\New-AdoClassicUpdatePlan.ps1 `
    -Kind Build -DefinitionId 591 -SpliceSpecPath '...\splices-build-591.json' `
    -OperationId 'update-build-591' `
    -OutBodyPath '...\body-build-591.json' -OutPlanPath '...\plan-emr-591.json' `
    -BuildName 'Build-Buklo-EMR' -ReleaseName 'Deploy-Desarrollo-UAT-Produccion-Buklo-EMR' `
    -ServiceConnectionAcrName 'ACR Hub-2' -ArtifactFilterBranch 'release'

Uso (Kind Release, agregando sobre el plan que acabo de generar arriba):
  powershell -File .\New-AdoClassicUpdatePlan.ps1 `
    -Kind Release -DefinitionId 373 -SpliceSpecPath '...\splices-release-373.json' `
    -OperationId 'update-release-373' `
    -OutBodyPath '...\body-release-373.json' -OutPlanPath '...\plan-emr-591-373.json' `
    -ExistingPlanPath '...\plan-emr-591.json'

Forma de -SpliceSpecPath (array vacio '[]' es valido -- solo field-stripping,
sin splices):
  [
    { "function": "Set-AdoFileCreatorContent", "displayName": "File Creator deployment-dev.yml", "fileContentPath": "C:\...\emr-591-dev-NEW.yml", "enabled": true },
    { "function": "Add-AdoReleaseEnvironmentCdTrigger", "stage": "Desarrollo", "artifactAlias": "_Build-Buklo-EMR", "sourceBranch": "development" }
  ]
Las claves de cada entrada (fuera de 'function'/'fileContentPath'/'contentPath')
se pasan tal cual, por SPLATTING, a la funcion real -- el binding de
PowerShell no distingue mayusculas/minusculas, asi que 'displayName' liga
igual que '-DisplayName'. Un nombre de parametro que la funcion real no
tenga hace fallar el binding normal de PowerShell (no un chequeo especial
de este script). 'build'/'release' como clave se rechaza siempre: el
objetivo lo provee siempre esta funcion, nunca la especificacion
declarativa.
#>

param(
    [Parameter(Mandatory)] [ValidateSet('Build', 'Release')] [string]$Kind,
    [Parameter(Mandatory)] [int]$DefinitionId,
    [string]$Project = 'DevOps',
    [string]$Organization = 'Shared-Service-GM',
    [Parameter(Mandatory)] [string]$SpliceSpecPath,
    [Parameter(Mandatory)] [string]$OperationId,
    [Parameter(Mandatory)] [string]$OutBodyPath,
    [Parameter(Mandatory)] [string]$OutPlanPath,

    # Modo 1: agregar esta operacion a un plan ya existente (cualquier
    # forma valida ya emitida por esta skill). Si se omite, cae al modo 2
    # (esqueleto nuevo, solo familia aks).
    [string]$ExistingPlanPath,

    # ---- Esqueleto nuevo (solo cuando -ExistingPlanPath NO se paso;
    # ignorados si se paso) ----
    [string]$BuildName,
    [string]$ReleaseName,
    [string]$BuildTaskGroupName = 'Build-MultiStage',
    [string]$DeployTaskGroupName = 'Deployment-Azur-Aks-v3',
    [string]$ServiceConnectionAcrName,
    [string]$ServiceConnectionAksName = '',
    [string]$ArtifactFilterBranch,
    [ValidateSet('Desarrollo', 'UAT', 'Produccion')] [string]$Stage = 'Produccion',
    [ValidateSet('aks', 'standalone-build')] [string]$Family = 'aks'
)

$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'Invoke-AdoRest.ps1')
. (Join-Path $scriptRoot 'New-AdoClassicPayloads.ps1')
. (Join-Path $scriptRoot 'New-AdoClassicUpdatePayload.ps1')

$result = Invoke-AdoClassicUpdatePlanGeneration @PSBoundParameters

Write-Host "Body PUT ($($result.OperationType)) escrito en: $($result.BodyPath)" -ForegroundColor Green
Write-Host "Plan escrito en: $($result.PlanPath)" -ForegroundColor Green
if (@($result.AppliedFunctionNames).Count -gt 0) {
    Write-Host "Splices aplicados: $($result.AppliedFunctionNames -join ', ')" -ForegroundColor Cyan
}
Write-Host "Siguiente paso: Test-AdoClassicPlan.ps1 -PlanPath '$($result.PlanPath)' -InventoryPath '...'" -ForegroundColor Yellow
