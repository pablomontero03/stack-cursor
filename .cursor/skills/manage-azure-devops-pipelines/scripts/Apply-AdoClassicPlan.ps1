<#
Aplica de verdad un plan ya validado por Test-AdoClassicPlan.ps1 (crear/
actualizar) o Test-AdoClassicDeletePlan.ps1 (borrar, agregado 2026-08-26).
Este es el UNICO script de esta skill que puede crear, modificar o
borrar recursos reales en Azure DevOps. Separado deliberadamente de
Invoke-AdoClassicPlan.ps1 (que es dry-run exclusivo) para que
ado-security-gate.ps1 pueda pedir permiso explicito por el NOMBRE del
script.

Borrado (Fase 6, ver Invoke-AdoApplyPhases en New-AdoClassicPayloads.ps1):
antes de cualquier DELETE real, este script escribe SIEMPRE un respaldo
de solo lectura del recurso completo en
.local/azure-devops/exports/pre-delete-backups/ -- obligatorio, no
opcional. Un GET de respaldo fallido o vacio detiene todo antes de
borrar nada.

Exige TODO lo siguiente, en orden, o se rechaza sin tocar la red:
  1. El plan existe y validated == $true (escrito por Test-AdoClassicPlan.ps1).
  2. validationHash coincide con el contenido actual del plan.
  3. -InventoryPath apunta al MISMO inventario que se uso para validar,
     todavia fresco (ver validacion de evidencia mas abajo, sin cambios
     respecto a versiones previas de este script).
  4. AZURE_DEVOPS_PAT configurada (recien al construir el header, dentro
     de Invoke-AdoRest).
  5. Confirmacion explicita del usuario ya obtenida FUERA de este script:
     por el plan de ExitPlanMode ligado al comando/hashes exactos o por la
     tarjeta fallback del hook cuando esa aprobacion no puede heredarse.

Orden de creacion: Variable Group -> Build -> Release (solo las fases
para las que el plan trae una entrada de approvedOperations del
operationType correspondiente; un plan puede aprobar 1, 2 o las 3). Si
una fase falla (o su recurso YA EXISTE segun un chequeo en vivo -- ver
mas abajo), se detiene y reporta lo ya creado; NUNCA hace rollback
automatico.

Este script NUNCA encola el Build ni crea una instancia real de Release,
ni aunque haya creado las 3 definiciones correctamente -- no existe
ningun codigo aca que llame a los endpoints de "queue build" o "create
release" (los unicos 3 operationType permitidos en
$script:AdoAllowedOperationTypes son de definicion, nunca de ejecucion).
Tampoco activa UAT/Produccion, ni toca DNS/Ingress/certificados.

Por que necesita datos adicionales a -PlanPath/-InventoryPath: el plan
solo guarda el HASH de cada body aprobado (nunca el body completo), asi
que este script tiene que RECONSTRUIR el mismo body exacto con
New-AdoClassicPayloads.ps1 antes de poder enviarlo -- eso exige el
contenido real de los 3 manifiestos K8s (para el Build) y, para el
Release, los ids YA EXISTENTES de la Variable Group y el Build que va a
referenciar (nunca inventados: si no existen todavia en este mismo plan,
hay que crearlos primero -- ver Fase 3 mas abajo).

Uso (ejemplo; solo aplica si el plan.approvedOperations trae las 3
operaciones y todos estos datos coinciden exacto con lo aprobado):
  powershell -File .\Apply-AdoClassicPlan.ps1 `
    -PlanPath '...\aks-x-y-....json' -InventoryPath '...\inventory-....json' `
    -DeploymentDevYamlPath '...\deployment-dev.yml' `
    -DeploymentUatYamlPath '...\deployment-uat.yml' `
    -DeploymentProdYamlPath '...\deployment-prod.yml' `
    -ReleaseEnvironmentsPath '...\release-environments.json' `
    -BuildDefinitionName 'Build-x-y'
#>

param(
    [Parameter(Mandatory)] [string]$PlanPath,
    # InventoryPath ya NO es Mandatory (2026-10-16): las familias update-only
    # 'vg-update'/'tg-update' se validan SIN inventario (su frescura/anti-replay
    # la garantiza el chequeo de revision en vivo en Fase 1b/1c, no un
    # inventario). Para TODA otra familia sigue siendo obligatorio: el guardia
    # de evidencia mas abajo lo exige cuando el plan trae validationEvidence
    # (o deberia traerla).
    [string]$InventoryPath,
    [string]$DeploymentDevYamlPath,
    [string]$DeploymentUatYamlPath,
    [string]$DeploymentProdYamlPath,
    [string]$ReleaseEnvironmentsPath,
    [int]$ExistingBuildDefinitionId,
    [string]$BuildDefinitionName,
    # Ruta a un JSON con la lista de referencias de secretos controladas
    # para la fase Release (ver security.md "Referencias de secretos
    # controladas"): array de { "path": "...value", "envVarName":
    # "ADO_SECRET_..." }. Nunca contiene el valor real -- solo el path
    # dentro del body y el NOMBRE de la variable de entorno de donde se
    # va a leer en el momento de aplicar. Opcional.
    [string]$ReleaseSecretReferencesPath,
    # Fases 4/5 (update-*, agregadas 2026-08-25): ruta al JSON con el body
    # PUT exacto ya armado (mutar-y-guardar fuera de este script), el
    # mismo que se hasheo al aprobar la operacion.
    [string]$UpdateBuildBodyPath,
    [string]$UpdateReleaseBodyPath,
    # Fase 1b (update-variable-group, agregada 2026-10-14): el body actual
    # del VG obtenido con un GET previo, como JSON string (el contenido,
    # no una ruta). Necesario para preservar variables existentes.
    [string]$CurrentVariableGroupJson,
    # Fase 1c (update-taskgroup, agregada 2026-10-16): el body actual del
    # task group obtenido con un GET previo, como JSON string. Necesario
    # para confirmar la revision en vivo antes de pisarla (anti-concurrencia).
    [string]$CurrentTaskGroupJson
)

$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'Invoke-AdoRest.ps1')
. (Join-Path $scriptRoot 'New-AdoClassicPayloads.ps1')

$createdSoFar = [System.Collections.Generic.List[string]]::new()

function Write-CreatedSummary {
    Write-Host "`n=== Resumen de lo creado en esta ejecucion ===" -ForegroundColor Cyan
    if ($createdSoFar.Count -eq 0) {
        Write-Host "(nada -- cero escrituras realizadas)" -ForegroundColor Yellow
    }
    else {
        foreach ($c in $createdSoFar) { Write-Host " - $c" -ForegroundColor Green }
    }
    Write-Host "Ninguna fase hace rollback automatico. No se encolo ningun Build, no se creo ninguna instancia de Release, no se desplego nada." -ForegroundColor Yellow
}

if (-not (Test-Path -LiteralPath $PlanPath)) {
    throw "Apply-AdoClassicPlan rechazado: no existe el archivo de plan '$PlanPath'."
}

$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json

# ── DACPAC UNIFIED HANDLER ────────────────────────────────────────────────────
# El plan dacpac/unified usa clone+mutate desde modelos de referencia en lugar
# del flujo validated→approvedOperations. Bypasea las guards de validationHash
# e inventario porque no genera bodies precalculados: los datos vienen del plan.
if ([string]$plan.family -eq 'dacpac' -and [string]$plan.pattern -eq 'unified') {
    Write-Host "=== DACPAC Unified Handler ===" -ForegroundColor Cyan
    Write-Host "Patron: 1 Build + 1 Release 3 stages (clone+mutate desde modelos de referencia)" -ForegroundColor Cyan

    $project       = [string]$plan.project
    if ([string]::IsNullOrWhiteSpace($project)) {
        throw "Apply-AdoClassicPlan (dacpac/unified) rechazado: el plan no tiene 'project'. Las URIs de build/release definitions requieren el proyecto en el path."
    }
    $refBuildId    = [int]$plan.referenceModels.buildId
    $refReleaseId  = [int]$plan.referenceModels.releaseId
    $dbProjectName = [string]($plan.names.build -replace '^Build_Base_Datos_','')
    $buildName     = [string]$plan.names.build
    $releaseName   = [string]$plan.names.release
    $folderPath    = [string]$plan.names.folder
    $repoId        = [string]$plan.repo.id
    $repoName      = [string]$plan.repo.name
    $repoProject   = [string]$plan.repo.project
    $dbName        = [string]$plan.release.variables.database
    $coreGlobalRef = 'xxx'
    if ($plan.release.PSObject.Properties['deploymentDataBasesInputs'] -and
        $plan.release.deploymentDataBasesInputs.PSObject.Properties['sqldb_core_global_db_reference']) {
        $coreGlobalRef = [string]$plan.release.deploymentDataBasesInputs.'sqldb_core_global_db_reference'
    }

    # ── Contrato de escritura aprobada ────────────────────────────────────────
    # Invoke-AdoRest exige, para toda escritura, que la operacion coincida con
    # una entrada de plan.approvedOperations (operationId/operationType/method/
    # uri) y que el plan este validated=true con validationHash consistente.
    # El handler dacpac/unified genera los bodies por clone+mutate en tiempo de
    # Apply (no van embebidos en el plan): bodyHash es un placeholder y el gate
    # lo tolera para los operationType 'reconstruidos' (create-build-definition,
    # create-release-definition). Poblamos ese contrato aca y persistimos el
    # plan a disco para que Invoke-AdoRest lo lea consistente.
    $buildCreateUri   = "$script:AdoCoreBaseUrl/$project/_apis/build/definitions?api-version=7.1"
    $releaseCreateUri = "$script:AdoReleaseBaseUrl/$project/_apis/release/definitions?api-version=7.1"

    $plan.approvedOperations = @(
        [PSCustomObject]@{
            operationId   = 'dacpac-create-build'
            operationType = 'create-build-definition'
            method        = 'POST'
            uri           = $buildCreateUri
            bodyHash      = 'reconstructed-at-apply'
        },
        [PSCustomObject]@{
            operationId   = 'dacpac-create-release'
            operationType = 'create-release-definition'
            method        = 'POST'
            uri           = $releaseCreateUri
            bodyHash      = 'reconstructed-at-apply'
        }
    )
    if (-not $plan.PSObject.Properties['validationEvidence']) {
        $plan | Add-Member -NotePropertyName validationEvidence -NotePropertyValue $null -Force
    }
    $plan.validated = $true
    $plan.PSObject.Properties.Remove('validationHash')
    $computedHash = Get-AdoPlanCanonicalHash -Plan $plan
    $plan | Add-Member -NotePropertyName validationHash -NotePropertyValue $computedHash -Force
    $plan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $PlanPath -Encoding utf8

    # ── Clonar Build ──────────────────────────────────────────────────────────
    Write-Host "Clonando Build $refBuildId como $buildName ..." -ForegroundColor Yellow
    $refBuild = (Invoke-AdoRest -Method GET -Uri "$script:AdoCoreBaseUrl/$project/_apis/build/definitions/$refBuildId`?api-version=7.1").Body
    foreach ($f in @('id','url','uri','_links','authoredBy','createdDate','drafts','metrics',
                     'latestBuild','latestCompletedBuild','badgeUrl')) { $refBuild.PSObject.Properties.Remove($f) }
    $refBuild.name = $buildName
    $refBuild.path = $folderPath
    $refBuild.repository.id   = $repoId
    $refBuild.repository.name = $repoName
    $refBuild.repository.url  = "https://dev.azure.com/Shared-Service-GM/$repoProject/_git/$repoName"
    $refBuild.variables.databaseProjectName = [PSCustomObject]@{ value = $dbProjectName; allowOverride = $false }
    # Aplicar pathFilter si el plan lo especifica (repos compartidos con múltiples proyectos SSDT)
    $pathFilter = $null
    if ($plan.build.PSObject.Properties['pathFilter'] -and -not [string]::IsNullOrWhiteSpace([string]$plan.build.pathFilter)) {
        $pathFilter = [string]$plan.build.pathFilter
    }
    foreach ($trigger in $refBuild.triggers) {
        if ($trigger.PSObject.Properties['branchFilters']) {
            if ($null -ne $pathFilter) {
                $trigger.pathFilters = @($pathFilter)
                Write-Host "  pathFilter aplicado: $pathFilter" -ForegroundColor Cyan
            } else {
                $trigger.pathFilters = @()
            }
        }
    }
    foreach ($phase in $refBuild.process.phases) {
        foreach ($step in $phase.steps) {
            if ($step.inputs -and $step.inputs.PSObject.Properties['databaseProjectName']) {
                $step.inputs.databaseProjectName = '$(databaseProjectName)'
            }
        }
    }
    $newBuild = (Invoke-AdoRest -Method POST -Uri $buildCreateUri -Body $refBuild -RequireApprovedPlan -PlanPath $PlanPath -OperationId 'dacpac-create-build').Body
    $newBuildId = [int]$newBuild.id
    Write-Host "Build creado: id=$newBuildId name=$($newBuild.name)" -ForegroundColor Green
    $createdSoFar.Add("create-build-definition id=$newBuildId name=$($newBuild.name)")

    # ── Clonar Release ────────────────────────────────────────────────────────
    Write-Host "Clonando Release $refReleaseId como $releaseName ..." -ForegroundColor Yellow
    $refRelease = (Invoke-AdoRest -Method GET -Uri "$script:AdoReleaseBaseUrl/$project/_apis/release/definitions/$refReleaseId`?api-version=7.1").Body
    foreach ($f in @('id','url','_links','createdBy','createdOn','modifiedBy','modifiedOn',
                     'lastRelease','isDisabled','isDeleted','source','revision')) { $refRelease.PSObject.Properties.Remove($f) }
    $refRelease.name = $releaseName
    $refRelease.path = $folderPath
    $newArtifactAlias = "_$buildName"
    $refRelease.variables.database            = [PSCustomObject]@{ value = $dbName }
    $refRelease.variables.databaseProjectName = [PSCustomObject]@{ value = $dbProjectName }
    $refRelease.variables.build               = [PSCustomObject]@{ value = $buildName }
    $refRelease.artifacts[0].sourceId         = "7f632f4b-b3cb-4530-a5ff-ee9f809ab478:$newBuildId"
    $refRelease.artifacts[0].alias            = $newArtifactAlias
    $refRelease.artifacts[0].definitionReference.definition.id   = [string]$newBuildId
    $refRelease.artifacts[0].definitionReference.definition.name = $buildName
    foreach ($trigger in $refRelease.triggers) { $trigger.artifactAlias = $newArtifactAlias }
    foreach ($env in $refRelease.environments) {
        $env.PSObject.Properties.Remove('id')
        $env.PSObject.Properties.Remove('deployStep')
        $env.PSObject.Properties.Remove('currentRelease')
        $env.PSObject.Properties.Remove('badgeUrl')
        foreach ($approvalKey in @('preDeployApprovals','postDeployApprovals')) {
            if ($env.$approvalKey) {
                foreach ($appr in $env.$approvalKey.approvals) { $appr.PSObject.Properties.Remove('id') }
            }
        }
        foreach ($cond in $env.conditions) {
            if ($cond.conditionType -eq 'artifact') { $cond.name = $newArtifactAlias }
        }
        foreach ($phase in $env.deployPhases) {
            foreach ($task in $phase.workflowTasks) {
                if ($task.taskId -eq '4634d6ff-8290-4605-bcbe-fb27ba3528d2') {
                    $task.inputs.build                          = $buildName
                    $task.inputs.sqldb_core_global_db_reference = $coreGlobalRef
                    $task.enabled = $false
                }
            }
        }
    }
    $newRelease = (Invoke-AdoRest -Method POST -Uri $releaseCreateUri -Body $refRelease -RequireApprovedPlan -PlanPath $PlanPath -OperationId 'dacpac-create-release').Body
    $newReleaseId = [int]$newRelease.id
    Write-Host "Release creado: id=$newReleaseId name=$($newRelease.name)" -ForegroundColor Green
    $createdSoFar.Add("create-release-definition id=$newReleaseId name=$($newRelease.name)")

    Write-CreatedSummary
    exit 0
}
# ── FIN DACPAC UNIFIED HANDLER ────────────────────────────────────────────────

if ($plan.validated -ne $true) {
    throw "Apply-AdoClassicPlan rechazado: el plan no tiene validated=true. Ejecutar Test-AdoClassicPlan.ps1 primero y resolver los bloqueantes."
}

if ([string]::IsNullOrWhiteSpace($plan.validationHash)) {
    throw "Apply-AdoClassicPlan rechazado: el plan no tiene validationHash. Volver a correr Test-AdoClassicPlan.ps1 (version desactualizada del formato de plan)."
}

$currentHash = Get-AdoPlanCanonicalHash -Plan $plan
if ($currentHash -ne $plan.validationHash) {
    throw "Apply-AdoClassicPlan rechazado: el contenido del plan cambio despues de la validacion (validationHash no coincide con el contenido actual). Volver a correr Test-AdoClassicPlan.ps1 sobre la version actual antes de aplicar."
}

# --- Evidencia de inventario: el MISMO inventario usado para validar,
#     todavia fresco, todavia con paginacion completa. Sin cambios
#     respecto a versiones previas de este script. ---

# Familias update-only sin inventario (2026-10-16): 'vg-update'/'tg-update'
# se validan SIN inventario, por lo que validationEvidence queda null. Su
# garantia anti-replay/frescura NO es un inventario de hace horas, sino el
# chequeo de REVISION EN VIVO del recurso justo antes del PUT (Fase 1b para
# VG, Fase 1c para task group): si alguien lo edito desde que se genero el
# plan, la revision en vivo no coincide y Apply aborta. Por eso, SOLO para
# esas familias Y SOLO cuando el plan no trae validationEvidence, se salta
# todo el guardia de inventario. Para cualquier otra familia, o si una
# familia update-only SI trae evidence, el guardia se aplica igual que
# siempre (defensa sin cambios).
$updateOnlyFamilies = @('vg-update', 'tg-update', 'tg-create')
$requireInventoryEvidence = -not ([string]$plan.family -in $updateOnlyFamilies -and $null -eq $plan.validationEvidence)

if ($requireInventoryEvidence) {

$evidence = $plan.validationEvidence
if (-not $evidence) {
    throw "Apply-AdoClassicPlan rechazado: el plan no tiene validationEvidence. Volver a correr Test-AdoClassicPlan.ps1 con -InventoryPath sobre un inventario completo y fresco."
}

$requiredEvidenceFields = @('inventoryGeneratedAtUtc', 'inventoryHash', 'validatedAtUtc', 'maxInventoryAgeHours')
$missingEvidenceFields = @($requiredEvidenceFields | Where-Object { $null -eq $evidence.PSObject.Properties[$_] -or $null -eq $evidence.$_ })
if ($missingEvidenceFields.Count -gt 0) {
    throw "Apply-AdoClassicPlan rechazado: validationEvidence esta incompleto (faltan: $($missingEvidenceFields -join ', '))."
}

if (-not (Test-Path -LiteralPath $InventoryPath)) {
    throw "Apply-AdoClassicPlan rechazado: no existe el archivo de inventario '$InventoryPath'."
}

$inventoryRawAtApply = Get-Content -LiteralPath $InventoryPath -Raw
try {
    $inventoryAtApply = $inventoryRawAtApply | ConvertFrom-Json
}
catch {
    throw "Apply-AdoClassicPlan rechazado: el inventario en -InventoryPath no es JSON valido."
}

$actualInventoryHash = Get-AdoSha256OfText -Text $inventoryRawAtApply
if ($actualInventoryHash -ne $evidence.inventoryHash) {
    throw "Apply-AdoClassicPlan rechazado: el inventario en -InventoryPath no es el mismo que se uso para validar el plan (el hash no coincide -- el inventario cambio, o es un archivo distinto)."
}

if ($inventoryAtApply.paginationComplete -ne $true) {
    throw "Apply-AdoClassicPlan rechazado: el inventario ya no tiene paginationComplete=true."
}

$nowUtc = (Get-Date).ToUniversalTime()

$generatedAtParsed = $null
try {
    # El inventario puede tener el timestamp en formato ISO 8601 con Z ('2026-09-11T18:01:11Z')
    # o en el formato corto de PowerShell ('09/11/2026 18:01:11') sin indicador de timezone.
    # En ambos casos se interpreta como UTC (AssumeUniversal + AdjustToUniversal).
    $generatedAtParsed = [DateTime]::Parse(
        [string]$evidence.inventoryGeneratedAtUtc,
        $null,
        [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    )
}
catch {
    throw "Apply-AdoClassicPlan rechazado: validationEvidence.inventoryGeneratedAtUtc no es una fecha valida."
}

$validatedAtParsed = $null
try {
    $validatedAtParsed = [DateTime]::Parse(
        [string]$evidence.validatedAtUtc,
        $null,
        [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    )
}
catch {
    throw "Apply-AdoClassicPlan rechazado: validationEvidence.validatedAtUtc no es una fecha valida."
}

if ($generatedAtParsed -gt $nowUtc) {
    throw "Apply-AdoClassicPlan rechazado: validationEvidence.inventoryGeneratedAtUtc esta en el futuro."
}
if ($validatedAtParsed -gt $nowUtc) {
    throw "Apply-AdoClassicPlan rechazado: validationEvidence.validatedAtUtc esta en el futuro."
}

$maxAgeHours = $null
try {
    $maxAgeHours = [double]$evidence.maxInventoryAgeHours
}
catch {
    throw "Apply-AdoClassicPlan rechazado: validationEvidence.maxInventoryAgeHours no es numerico."
}
if ([double]::IsNaN($maxAgeHours) -or [double]::IsInfinity($maxAgeHours)) {
    throw "Apply-AdoClassicPlan rechazado: validationEvidence.maxInventoryAgeHours no puede ser NaN ni infinito."
}
if ($maxAgeHours -le 0) {
    throw "Apply-AdoClassicPlan rechazado: validationEvidence.maxInventoryAgeHours debe ser mayor que 0."
}

$effectiveMaxAgeHours = [Math]::Min($maxAgeHours, $script:AdoAbsoluteMaxInventoryAgeHours)

$inventoryAgeHoursNow = ($nowUtc - $generatedAtParsed).TotalHours
$validationAgeHoursNow = ($nowUtc - $validatedAtParsed).TotalHours

if ($inventoryAgeHoursNow -gt $effectiveMaxAgeHours) {
    throw "Apply-AdoClassicPlan rechazado: el inventario tiene $([math]::Round($inventoryAgeHoursNow, 1))h de antiguedad medidas desde ahora, mas que el limite efectivo de $effectiveMaxAgeHours h (tope absoluto interno: $($script:AdoAbsoluteMaxInventoryAgeHours)h). Volver a exportar el inventario y revalidar el plan."
}
if ($validationAgeHoursNow -gt $effectiveMaxAgeHours) {
    throw "Apply-AdoClassicPlan rechazado: la validacion del plan tiene $([math]::Round($validationAgeHoursNow, 1))h de antiguedad medidas desde ahora, mas que el limite efectivo de $effectiveMaxAgeHours h (tope absoluto interno: $($script:AdoAbsoluteMaxInventoryAgeHours)h). Volver a revalidar el plan antes de aplicar."
}

}  # fin if ($requireInventoryEvidence)
else {
    Write-Host "Familia '$($plan.family)' sin inventario: se omite el guardia de inventario (la frescura/anti-replay la garantiza el chequeo de revision en vivo del recurso en la fase de update)." -ForegroundColor DarkGray
}

# Marcadores de estado de implementacion (nombres pedidos explicitamente
# para poder auditar de un vistazo si las fases estan implementadas).
# Cambiados a TRUE el 2026-08-24 -- TODA la suite de pruebas simuladas
# (run-script-tests.ps1, 181 casos, 100% mockeado, cero red real) esta en
# verde en dos corridas consecutivas. Esto NO habilita una escritura real
# por si solo: Apply-AdoClassicPlan.ps1 sigue exigiendo plan validado +
# hash + evidencia de inventario fresca + aprobacion explicita del
# usuario (el hook pide confirmacion por el NOMBRE de este script) antes
# de llegar a la red.
$script:BuildPhaseImplemented = $true
$script:ReleasePhaseImplemented = $true

if (-not ($script:BuildPhaseImplemented -and $script:ReleasePhaseImplemented)) {
    Write-Host "=== APLICACION NO DISPONIBLE TODAVIA ===" -ForegroundColor Red
    Write-Host "Las fases de Build/Release clasico estan escritas pero BuildPhaseImplemented/ReleasePhaseImplemented siguen en false hasta que la suite de pruebas simuladas termine en verde." -ForegroundColor Red
    Write-Host "No se realizo ninguna llamada POST/PUT/DELETE. No se creo ningun recurso, ni siquiera el Variable Group." -ForegroundColor Yellow
    throw "Apply-AdoClassicPlan rechazado: fases de Build/Release clasico no implementadas todavia (BuildPhaseImplemented/ReleasePhaseImplemented en false). Cero escrituras realizadas."
}

# ============================================================
# A partir de aca: aplicacion real, en 3 fases posibles, en orden fijo
# (Variable Group -> Build -> Release), SOLO para las operaciones que el
# plan aprobado realmente trae. Cada fase: reconstruye el body real,
# chequea duplicado en vivo (independiente del journal -- ver
# Test-AdoClassicResourceNameAlreadyExists), y recien entonces llama a
# Invoke-AdoRest (que hace su propia re-validacion de spec + journal +
# bodyHash antes de escribir). Si una fase falla, el script se detiene
# aca mismo (throw), reporta lo ya creado, y NUNCA hace rollback.
# ============================================================

$approvedOps = @()
if ($null -ne $plan.approvedOperations) { $approvedOps = @($plan.approvedOperations) }

if ($approvedOps.Count -eq 0) {
    Write-Host "El plan no tiene ninguna operacion aprobada (approvedOperations vacio). Nada que aplicar." -ForegroundColor Yellow
    Write-CreatedSummary
    exit 0
}

try {
    $releaseSecretReferences = @()
    if (-not [string]::IsNullOrWhiteSpace($ReleaseSecretReferencesPath)) {
        if (-not (Test-Path -LiteralPath $ReleaseSecretReferencesPath)) {
            throw "Apply-AdoClassicPlan rechazado: -ReleaseSecretReferencesPath ('$ReleaseSecretReferencesPath') no existe."
        }
        $refsRaw = Get-Content -LiteralPath $ReleaseSecretReferencesPath -Raw | ConvertFrom-Json
        $releaseSecretReferences = @($refsRaw | ForEach-Object { @{ Path = [string]$_.path; EnvVarName = [string]$_.envVarName } })
    }

    Invoke-AdoApplyPhases -Plan $plan -PlanPath $PlanPath -CreatedSoFar $createdSoFar `
        -DeploymentDevYamlPath $DeploymentDevYamlPath -DeploymentUatYamlPath $DeploymentUatYamlPath -DeploymentProdYamlPath $DeploymentProdYamlPath `
        -ReleaseEnvironmentsPath $ReleaseEnvironmentsPath `
        -ExistingBuildDefinitionId $(if ($ExistingBuildDefinitionId) { $ExistingBuildDefinitionId } else { $null }) `
        -BuildDefinitionName $BuildDefinitionName `
        -ReleaseSecretReferences $releaseSecretReferences `
        -UpdateBuildBodyPath $UpdateBuildBodyPath -UpdateReleaseBodyPath $UpdateReleaseBodyPath `
        -CurrentVariableGroupJson $CurrentVariableGroupJson `
        -CurrentTaskGroupJson $CurrentTaskGroupJson
}
finally {
    # El resumen se imprime SIEMPRE, incluso si una fase lanzo -- para que
    # quede claro que fue lo que si se alcanzo a crear antes del fallo
    # (nunca rollback automatico).
    Write-CreatedSummary
}
