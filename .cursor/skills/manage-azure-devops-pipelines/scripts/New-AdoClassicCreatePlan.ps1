<#
Agrega una operacion create-* determinista a un plan clasico existente.
Este runner solo prepara archivos locales: no realiza llamadas HTTP y nunca
invoca Apply-AdoClassicPlan.ps1.

Se ejecuta una vez por operacion para mantener cada body reproducible. Puede
encadenarse usando el OutPlanPath anterior como InputPlanPath. Release exige
ids ya existentes porque Azure DevOps asigna los ids de Build/Variable Group
al crearlos; esos ids no se inventan ni se sustituyen con scripts scratch.
#>

param(
    [Parameter(Mandatory)]
    [ValidateSet('VariableGroup', 'Build', 'Release', 'StandaloneBuild')]
    [string]$Kind,

    [Parameter(Mandatory)] [string]$InputPlanPath,
    [Parameter(Mandatory)] [string]$OutPlanPath,
    [Parameter(Mandatory)] [string]$OperationId,

    [string]$DeploymentDevYamlPath,
    [string]$DeploymentUatYamlPath,
    [string]$DeploymentProdYamlPath,

    [string]$ReleaseEnvironmentsPath,
    [Nullable[int]]$ExistingBuildDefinitionId,
    [string]$BuildDefinitionName,

    # ---- Solo para -Kind StandaloneBuild (agregado 2026-08-27, ver
    # New-AdoStandaloneBuildDefinitionPayload en New-AdoClassicPayloads.ps1
    # para el detalle completo de cada default). $StepsSpecPath es un JSON
    # DECLARATIVO (nunca objetos PowerShell ya armados -- este runner solo
    # acepta invocacion literal por CLI, sin code injection): un array de
    # entradas { kind: 'FileCreator'|'PowerShellTask', ... } que esta
    # funcion traduce a New-AdoFileCreatorStep/New-AdoPowerShellTaskStep. ----
    [string]$StepsSpecPath,
    [string]$FetchDepth = '0',
    [string[]]$CiBranchFilters = @(),
    [switch]$CiBatchChangesEnabled,
    [string]$AgentSpecificationIdentifier = 'ubuntu latest',
    [int]$AgentPoolId = 9,
    [string]$AgentPoolName = 'Azure Pipelines',
    [Nullable[int]]$QueueId
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Invoke-AdoRest.ps1')
. (Join-Path $PSScriptRoot 'New-AdoClassicPayloads.ps1')

if (-not (Test-Path -LiteralPath $InputPlanPath -PathType Leaf)) {
    throw "New-AdoClassicCreatePlan: no existe -InputPlanPath '$InputPlanPath'."
}
if ([IO.Path]::GetFullPath($InputPlanPath) -eq [IO.Path]::GetFullPath($OutPlanPath)) {
    throw 'New-AdoClassicCreatePlan: InputPlanPath y OutPlanPath deben ser distintos; el plan de origen nunca se modifica.'
}

$plan = Get-Content -LiteralPath $InputPlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
$operationType = "create-$($Kind.ToLowerInvariant())-definition"
if ($Kind -eq 'VariableGroup') { $operationType = 'create-variable-group' }
# StandaloneBuild sigue siendo, a nivel de Azure DevOps, un POST a
# .../build/definitions -- MISMO operationType que Kind=Build (nunca uno
# nuevo: $script:AdoAllowedOperationTypes no tiene ni necesita una
# entrada separada). Un plan nunca puede tener a la vez Kind=Build y
# Kind=StandaloneBuild (el chequeo de operationType duplicado de abajo ya
# lo impide).
if ($Kind -eq 'StandaloneBuild') { $operationType = 'create-build-definition' }

$approvedOperations = @()
if ($null -ne $plan.approvedOperations) {
    $approvedOperations = @($plan.approvedOperations)
}
if (@($approvedOperations | Where-Object { $_.operationId -ceq $OperationId }).Count -gt 0) {
    throw "New-AdoClassicCreatePlan: operationId duplicado '$OperationId'."
}
if (@($approvedOperations | Where-Object { $_.operationType -ceq $operationType }).Count -gt 0) {
    throw "New-AdoClassicCreatePlan: el plan ya contiene '$operationType'."
}

$body = $null
$uri = $null

switch ($Kind) {
    'VariableGroup' {
        $body = New-AdoVariableGroupPayload -Plan $plan
        $uri = "$($script:AdoCoreBaseUrl)/$($plan.project)/_apis/distributedtask/variablegroups?api-version=$($script:AdoApiVersion)"
    }
    'Build' {
        $paths = @($DeploymentDevYamlPath, $DeploymentUatYamlPath, $DeploymentProdYamlPath)
        if (@($paths | Where-Object { [string]::IsNullOrWhiteSpace($_) -or -not (Test-Path -LiteralPath $_ -PathType Leaf) }).Count -gt 0) {
            throw 'New-AdoClassicCreatePlan: Kind=Build exige los tres manifiestos existentes: DeploymentDevYamlPath, DeploymentUatYamlPath y DeploymentProdYamlPath.'
        }
        $manifests = @{
            dev  = Get-Content -LiteralPath $DeploymentDevYamlPath -Raw -Encoding UTF8
            uat  = Get-Content -LiteralPath $DeploymentUatYamlPath -Raw -Encoding UTF8
            prod = Get-Content -LiteralPath $DeploymentProdYamlPath -Raw -Encoding UTF8
        }
        $body = New-AdoBuildDefinitionPayload -Plan $plan -DeploymentManifests $manifests
        $uri = "$($script:AdoCoreBaseUrl)/$($plan.project)/_apis/build/definitions?api-version=$($script:AdoApiVersion)"
    }
    'Release' {
        if (-not $ExistingBuildDefinitionId -or [string]::IsNullOrWhiteSpace($BuildDefinitionName)) {
            throw 'New-AdoClassicCreatePlan: Kind=Release exige ExistingBuildDefinitionId y BuildDefinitionName reales; no se aceptan ids futuros o inventados.'
        }
        if ([string]::IsNullOrWhiteSpace($ReleaseEnvironmentsPath) -or -not (Test-Path -LiteralPath $ReleaseEnvironmentsPath -PathType Leaf)) {
            throw 'New-AdoClassicCreatePlan: Kind=Release exige ReleaseEnvironmentsPath existente.'
        }

        # NUNCA envolver "Get-Content -Raw | ConvertFrom-Json" directamente
        # en @(...) (bug real encontrado 2026-08-27, ver el mismo fix junto
        # a $stepsSpecParsed en la rama StandaloneBuild de este archivo):
        # con 2+ elementos produce un array ANIDADO de 1 (el unico elemento
        # es a su vez el array real de N environments) en vez de un array
        # plano de N -- silencioso, nunca lanza, y el ForEach-Object de
        # abajo terminaria iterando UNA sola vez con $_ = el array
        # completo, auto-enumerando cada propiedad ($_.stage, etc.) en un
        # array de N valores en lugar de procesar cada environment por
        # separado. Con exactamente 1 environment es indistinguible del
        # colapso normal de JSON de 1 elemento a escalar -- por eso nunca
        # se detecto antes (ningun test previo de este Kind usaba 2+
        # environments). Fix: asignar primero SIN @() (deja que
        # ConvertFrom-Json enumere el pipeline normalmente), reenvolver en
        # un statement aparte.
        $rawEnvironmentsParsed = Get-Content -LiteralPath $ReleaseEnvironmentsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $rawEnvironments = @($rawEnvironmentsParsed)
        $environments = @($rawEnvironments | ForEach-Object {
            $entry = @{
                stage                 = [string]$_.stage
                variableGroupId       = [int]$_.variableGroupId
                artifactFilterBranch  = [string]$_.artifactFilterBranch
                deployTaskGroupId     = [string]$_.deployTaskGroupId
                deployTaskGroupName   = [string]$_.deployTaskGroupName
                # NUNCA envolver en @(...) (2do bug real encontrado
                # 2026-08-27 en este mismo bloque, junto al de
                # $rawEnvironments mas arriba): deployTaskGroupInputs debe
                # ser el objeto PLANO (PSCustomObject/hashtable de
                # nombre->valor) que New-AdoReleaseDefinitionPayload
                # asigna tal cual a 'inputs' -- @() lo envolvia en un
                # array de 1 elemento, lo que habria serializado 'inputs'
                # como '[{...}]' en vez de '{...}' (forma que Azure
                # DevOps rechazaria). Nunca antes ejecutado por ningun
                # test previo de este Kind (todos fallaban antes de
                # llegar aca por falta de -ExistingBuildDefinitionId).
                deployTaskGroupInputs = $_.deployTaskGroupInputs
                approvalRequired      = [bool]$_.approvalRequired
            }
            if ($_.PSObject.Properties['reportarResultadoTaskGroupId'] -and -not [string]::IsNullOrWhiteSpace([string]$_.reportarResultadoTaskGroupId)) {
                $entry['reportarResultadoTaskGroupId'] = [string]$_.reportarResultadoTaskGroupId
            }
            if ($_.PSObject.Properties['stageVariables'] -and $_.stageVariables) {
                $stageVariables = @{}
                foreach ($property in $_.stageVariables.PSObject.Properties) {
                    $stageVariables[$property.Name] = @{
                        value    = [string]$property.Value.value
                        isSecret = [bool]$property.Value.isSecret
                    }
                }
                $entry['stageVariables'] = $stageVariables
            }
            $entry
        })
        $body = New-AdoReleaseDefinitionPayload -Plan $plan -Environments $environments -BuildDefinitionId $ExistingBuildDefinitionId -BuildDefinitionName $BuildDefinitionName
        $uri = "$($script:AdoReleaseBaseUrl)/$($plan.project)/_apis/release/definitions?api-version=$($script:AdoApiVersion)"
    }
    'StandaloneBuild' {
        if ([string]::IsNullOrWhiteSpace($StepsSpecPath) -or -not (Test-Path -LiteralPath $StepsSpecPath -PathType Leaf)) {
            throw "New-AdoClassicCreatePlan: Kind=StandaloneBuild exige -StepsSpecPath existente (JSON declarativo de steps, ver New-AdoStandaloneBuildDefinitionPayload)."
        }
        if (-not $plan.project -or -not $plan.names -or -not $plan.names.build) {
            throw "New-AdoClassicCreatePlan: Kind=StandaloneBuild exige plan.project y plan.names.build ya presentes en -InputPlanPath."
        }
        if (-not $plan.repo -or -not $plan.repo.id -or -not $plan.repo.name -or -not $plan.repo.prodBranch) {
            throw "New-AdoClassicCreatePlan: Kind=StandaloneBuild exige plan.repo.id/name/prodBranch ya resueltos -- correr Test-AdoClassicPlan.ps1 con -InventoryPath primero para resolver plan.repo.id."
        }

        # Parseo factorizado 2026-09-01 en ConvertFrom-AdoStepsSpecFile
        # (New-AdoClassicPayloads.ps1) -- unica fuente de verdad, usada
        # tambien (indirectamente, via los steps ya resueltos guardados en
        # plan.dependencies.standaloneBuild.steps) por Invoke-AdoApplyPhases.
        $steps = ConvertFrom-AdoStepsSpecFile -StepsSpecPath $StepsSpecPath

        $body = New-AdoStandaloneBuildDefinitionPayload -Project ([string]$plan.project) -Name ([string]$plan.names.build) `
            -RepoId ([string]$plan.repo.id) -RepoName ([string]$plan.repo.name) -RepoProject $(if ($plan.repo.project) { [string]$plan.repo.project } else { [string]$plan.project }) `
            -DefaultBranch ([string]$plan.repo.prodBranch) -Steps @($steps) -FetchDepth $FetchDepth -CiBranchFilters $CiBranchFilters `
            -CiBatchChangesEnabled:$CiBatchChangesEnabled.IsPresent -AgentSpecificationIdentifier $AgentSpecificationIdentifier `
            -AgentPoolId $AgentPoolId -AgentPoolName $AgentPoolName -QueueId $QueueId
        $uri = "$($script:AdoCoreBaseUrl)/$($plan.project)/_apis/build/definitions?api-version=$($script:AdoApiVersion)"

        # plan.dependencies.standaloneBuild: retiene, de forma inmutable y
        # cubierta por validationHash (Get-AdoPlanCanonicalHash incluye
        # 'dependencies' completo), TODO lo necesario para que
        # Invoke-AdoApplyPhases reconstruya el body EXACTO al aplicar --
        # los steps YA RESUELTOS (nunca una ruta externa: fileContentPath
        # ya se leyo dentro de ConvertFrom-AdoStepsSpecFile) mas los
        # parametros que no se derivan de plan.project/names.build/repo.*.
        # Agregado 2026-09-01 -- antes de esto, Invoke-AdoApplyPhases no
        # tenia ningun dato para reconstruir un Build family=standalone-
        # build (siempre exigia los 3 manifiestos K8s de la familia AKS).
        if (-not $plan.PSObject.Properties['dependencies'] -or $null -eq $plan.dependencies) {
            $plan | Add-Member -NotePropertyName 'dependencies' -NotePropertyValue ([PSCustomObject]@{}) -Force
        }
        $standaloneBuildDependency = [ordered]@{
            steps                       = @($steps)
            fetchDepth                  = $FetchDepth
            ciBranchFilters             = @($CiBranchFilters)
            ciBatchChangesEnabled       = [bool]$CiBatchChangesEnabled.IsPresent
            agentSpecificationIdentifier = $AgentSpecificationIdentifier
            agentPoolId                 = $AgentPoolId
            agentPoolName               = $AgentPoolName
            queueId                     = $QueueId
        }
        $plan.dependencies | Add-Member -NotePropertyName 'standaloneBuild' -NotePropertyValue ([PSCustomObject]$standaloneBuildDependency) -Force
    }
}

$newOperation = New-AdoApprovedOperationEntry -OperationId $OperationId -OperationType $operationType -Uri $uri -Body $body
$plan.approvedOperations = @($approvedOperations + $newOperation)
$plan.validated = $false
foreach ($propertyName in @('validationHash', 'validationEvidence')) {
    if ($plan.PSObject.Properties[$propertyName]) {
        $plan.$propertyName = $null
    }
}

$outDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($OutPlanPath))
if (-not (Test-Path -LiteralPath $outDirectory)) {
    New-Item -ItemType Directory -Path $outDirectory -Force | Out-Null
}
$json = $plan | ConvertTo-Json -Depth 100
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutPlanPath), $json, [Text.UTF8Encoding]::new($false))

Write-Host "Operacion preparada: $operationType ($OperationId)" -ForegroundColor Green
Write-Host "Plan escrito en: $([IO.Path]::GetFullPath($OutPlanPath))" -ForegroundColor Green
Write-Host "Siguiente paso: Test-AdoClassicPlan.ps1 -PlanPath '$([IO.Path]::GetFullPath($OutPlanPath))' -InventoryPath '...'" -ForegroundColor Yellow
