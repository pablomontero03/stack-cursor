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
    [Parameter(Mandatory)] [string]$InventoryPath,
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
    [string]$UpdateReleaseBodyPath
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
    $generatedAtParsed = [DateTime]::Parse([string]$evidence.inventoryGeneratedAtUtc, $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}
catch {
    throw "Apply-AdoClassicPlan rechazado: validationEvidence.inventoryGeneratedAtUtc no es una fecha valida."
}

$validatedAtParsed = $null
try {
    $validatedAtParsed = [DateTime]::Parse([string]$evidence.validatedAtUtc, $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
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
        -UpdateBuildBodyPath $UpdateBuildBodyPath -UpdateReleaseBodyPath $UpdateReleaseBodyPath
}
finally {
    # El resumen se imprime SIEMPRE, incluso si una fase lanzo -- para que
    # quede claro que fue lo que si se alcanzo a crear antes del fallo
    # (nunca rollback automatico).
    Write-CreatedSummary
}
