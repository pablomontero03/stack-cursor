<#
Valida de forma independiente un plan generado por New-AdoClassicAksPlan.ps1
o New-AdoClassicDatabasePlan.ps1. No ejecuta ningun cambio en Azure DevOps
(no llama a Invoke-AdoRest; solo lee el plan y, si se provee, un inventario
ya exportado por Export-AdoClassicInventory.ps1).

Si se provee -InventoryPath, valida ademas: organization/project, frescura
del inventario, existencia de repo+branch, task groups (nombre+id+revision),
agent pool, service connections, y duplicados de nombre (Build/Release/
Variable Group/Library compartida). Sin inventario, todos esos puntos
quedan NOT_VERIFIED, que es SIEMPRE bloqueante -- un plan nunca queda
validated=true sin confirmar contra el inventario en vivo.

Cuando el plan queda validated=true (y hubo inventario completo/fresco),
se le agregan:
  - validationEvidence: inventoryGeneratedAtUtc, inventoryHash (SHA-256
    del archivo de inventario usado), validatedAtUtc, maxInventoryAgeHours
    -- Apply-AdoClassicPlan.ps1 exige el mismo -InventoryPath, recalcula
    el hash y rechaza si el inventario cambio o si esta (o la validacion)
    supera maxInventoryAgeHours.
  - validationHash: SHA-256 del contenido de negocio del plan, que
    INCLUYE validationEvidence y approvedOperations. Invoke-AdoRest.ps1
    recalcula este hash antes de cualquier escritura y rechaza el plan si
    no coincide.

approvedOperations (si el plan lo trae) se valida en forma: operationId
unico, operationType uno de los tipos exactos permitidos (ver
$script:AdoAllowedOperationTypes en Invoke-AdoRest.ps1: create-variable-
group, create-build-definition, create-release-definition -- POST, sin id
de recurso; y, agregados 2026-08-25 con aprobacion separada del usuario,
update-build-definition, update-release-definition -- PUT, exigen un id
de recurso numerico al final de la ruta), method/host/ruta/query EXACTOS
para ese tipo, operationType apropiado para la familia del plan, y
bodyHash con forma de SHA-256. Un array vacio o ausente es valido --
significa que no hay ninguna operacion aprobada todavia.

Uso:
  powershell -File .\Test-AdoClassicPlan.ps1 -PlanPath '...\aks-x-y-....json' [-InventoryPath '...\inventory-....json'] [-MaxInventoryAgeHours 24]
#>

param(
    [Parameter(Mandatory)] [string]$PlanPath,
    [string]$InventoryPath,
    [ValidateRange(0.01, 24)] [double]$MaxInventoryAgeHours = 24
)

$ErrorActionPreference = 'Stop'

# [ValidateRange] no atrapa NaN (todas las comparaciones con NaN son
# false, asi que NaN "pasa" cualquier rango sin lanzar) -- se rechaza
# explicitamente aca, junto con infinito, como defensa adicional. El
# limite superior de 24h es un TOPE, nunca configurable mas alla de eso:
# no existe forma de pasar -MaxInventoryAgeHours 999 y que esto lo acepte.
if ([double]::IsNaN($MaxInventoryAgeHours) -or [double]::IsInfinity($MaxInventoryAgeHours)) {
    throw "Test-AdoClassicPlan: -MaxInventoryAgeHours no puede ser NaN ni infinito."
}

$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'Invoke-AdoRest.ps1')

$RequiredOrganization = 'Shared-Service-GM'
# Lista de proyectos permitidos: $script:AdoAllowedProjects, definida en
# Invoke-AdoRest.ps1 (fuente unica de verdad, ver ese archivo). Un plan
# debe declarar UNO de esos proyectos -- nunca un valor de texto libre.

if (-not (Test-Path -LiteralPath $PlanPath)) {
    throw "Test-AdoClassicPlan: no existe el archivo de plan '$PlanPath'."
}

$planRaw = Get-Content -LiteralPath $PlanPath -Raw
$plan = $planRaw | ConvertFrom-Json

$inventory = $null
$inventoryRaw = $null
$inventoryComplete = $false
if ($InventoryPath) {
    if (-not (Test-Path -LiteralPath $InventoryPath)) {
        throw "Test-AdoClassicPlan: no existe el archivo de inventario '$InventoryPath'."
    }
    $inventoryRaw = Get-Content -LiteralPath $InventoryPath -Raw
    $inventory = $inventoryRaw | ConvertFrom-Json
}

$blockers = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

# Un plan "solo-actualizacion" (approvedOperations con al menos una
# operacion y NINGUNA de tipo create-*) referencia, por diseno, un Build/
# Release/Variable Group que YA EXISTE con ese nombre exacto -- son el
# recurso que se esta actualizando, no un duplicado accidental. Los
# chequeos de "posible duplicado" (mas abajo) solo tienen sentido para un
# plan que va a CREAR algo nuevo. Un plan vacio (approvedOperations
# ausente o [] -- todavia sin ninguna operacion aprobada) NO cuenta como
# update-only: sigue tratandose como plan de creacion en preparacion.
$approvedOpsForModeCheck = @()
if ($null -ne $plan.approvedOperations) { $approvedOpsForModeCheck = @($plan.approvedOperations) }
$isUpdateOnlyPlan = ($approvedOpsForModeCheck.Count -gt 0) -and `
    (-not ($approvedOpsForModeCheck | Where-Object { [string]$_.operationType -like 'create-*' }))

# Independiente de $isUpdateOnlyPlan (que se vuelve false apenas el plan
# incluye CUALQUIER create-*, incluido create-variable-group -- un plan
# real puede perfectamente crear 2 Variable Groups nuevas Y actualizar un
# Build/Release ya existentes en la misma operacion atomica, sin crear
# ningun Build). Lo unico que realmente consume plan.repo/plan.dockerfile
# para armar un payload es 'create-build-definition' (New-AdoBuildDefinitionPayload).
#
# OJO: un plan recien generado por New-AdoClassicAksPlan.ps1 (antes de que
# alguien decida y apruebe approvedOperations) NO tiene approvedOperations
# todavia -- ese es el caso normal de "plan en preparacion para crear un
# Build nuevo" y DEBE seguir exigiendo repo/dockerfile como siempre. Por
# eso el skip de abajo solo aplica cuando approvedOperations YA esta
# poblado Y ninguna entrada es create-build-definition -- nunca por el
# solo hecho de que la lista este vacia/ausente.
$planDeclaresNoNewBuild = ($approvedOpsForModeCheck.Count -gt 0) -and `
    (-not ($approvedOpsForModeCheck | Where-Object { [string]$_.operationType -eq 'create-build-definition' }))

function Add-Blocker { param([string]$Msg) $blockers.Add($Msg) }
function Add-Warning { param([string]$Msg) $warnings.Add($Msg) }

# 1. Familia correcta
# 'standalone-build' agregada 2026-08-27 (Build clasico sin
# Release/Variable Group, ver New-AdoClassicStandaloneBuildPlan.ps1 /
# New-AdoStandaloneBuildDefinitionPayload) -- nunca crea una instancia de
# Release ni un Variable Group, asi que varias secciones de abajo (2, 10,
# 11) se saltan a proposito para esta familia.
# 'vg-update' agregada 2026-10-14 (plan standalone para actualizar un
# Variable Group existente, sin crear ningun Build/Release/VG nuevo).
# Solo requiere: organization, project, variableGroupUpdate (id +
# variables a mutar), approvedOperations con una sola entrada
# update-variable-group. Salta casi todas las validaciones de pipeline.
if ($plan.family -notin @('aks', 'dacpac', 'standalone-build', 'vg-update', 'tg-update', 'tg-create')) {
    Add-Blocker "family debe ser 'aks', 'dacpac', 'standalone-build', 'vg-update', 'tg-update' o 'tg-create', encontrado: '$($plan.family)'."
}

# 2. Nombres y rutas presentes -- names.release solo se exige para
# 'aks'/'dacpac' (que siempre planean un Release, aunque approvedOperations
# todavia no lo incluya); 'standalone-build' nunca tiene Release;
# 'vg-update'/'tg-update'/'tg-create' no crean Build/Release, solo tocan un
# Variable Group o un task group.
$releaseNameRequiredForFamily = ($plan.family -ne 'standalone-build') -and ($plan.family -ne 'vg-update') -and ($plan.family -ne 'tg-update') -and ($plan.family -ne 'tg-create')
$buildNameRequiredForFamily = ($plan.family -ne 'vg-update') -and ($plan.family -ne 'tg-update') -and ($plan.family -ne 'tg-create')
if ($buildNameRequiredForFamily -and (-not $plan.names -or -not $plan.names.build)) {
    Add-Blocker "Faltan nombres de build en el plan."
}
if ($releaseNameRequiredForFamily -and (-not $plan.names -or -not $plan.names.release)) {
    Add-Blocker "Faltan nombres de release en el plan."
}

# 3. Organizacion y proyecto (independiente del inventario)
if ($plan.organization -ne $RequiredOrganization) {
    Add-Blocker "plan.organization debe ser '$RequiredOrganization', encontrado: '$($plan.organization)'."
}
if ($script:AdoAllowedProjects -notcontains $plan.project) {
    Add-Blocker "plan.project debe ser uno de: $($script:AdoAllowedProjects -join ', '). Encontrado: '$($plan.project)'."
}

# 3b. Validacion especifica de familia 'vg-update': debe tener
#     variableGroupUpdate con id (numerico) y variables (hashtable).
#     No requiere inventario porque el VG ya existe y se pasa via
#     -CurrentVariableGroupJson en Apply.
if ($plan.family -eq 'vg-update') {
    if (-not $plan.variableGroupUpdate) {
        Add-Blocker "Falta 'variableGroupUpdate' para familia vg-update."
    }
    elseif (-not $plan.variableGroupUpdate.id -or $plan.variableGroupUpdate.id -notmatch '^\d+$') {
        Add-Blocker "variableGroupUpdate.id debe ser un numero entero (ID del VG a actualizar). Encontrado: '$($plan.variableGroupUpdate.id)'."
    }
    elseif (-not $plan.variableGroupUpdate.variables -or ($plan.variableGroupUpdate.variables | Get-Member -MemberType NoteProperty).Count -eq 0) {
        Add-Blocker "variableGroupUpdate.variables debe tener al menos una variable a mutar."
    }
}

# 3c. Validacion especifica de familia 'tg-update' (agregada 2026-10-16):
#     debe tener taskGroupUpdate con id (UUID) y body (el task group
#     completo rev N+1 a enviar en el PUT). No requiere inventario porque
#     el task group ya existe y su estado actual se confirma via
#     -CurrentTaskGroupJson en Apply (compare-and-replace). El body debe
#     traer revision (int) y tasks (array) -- es el contrato del PUT de
#     distributedtask/taskgroups.
if ($plan.family -eq 'tg-update') {
    if (-not $plan.taskGroupUpdate) {
        Add-Blocker "Falta 'taskGroupUpdate' para familia tg-update."
    }
    elseif (-not $plan.taskGroupUpdate.id -or $plan.taskGroupUpdate.id -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        Add-Blocker "taskGroupUpdate.id debe ser un UUID (ID del task group a actualizar). Encontrado: '$($plan.taskGroupUpdate.id)'."
    }
    elseif (-not $plan.taskGroupUpdate.body) {
        Add-Blocker "taskGroupUpdate.body debe traer el task group completo (rev N+1) a enviar en el PUT."
    }
    elseif ($null -eq $plan.taskGroupUpdate.body.revision -or [string]$plan.taskGroupUpdate.body.revision -notmatch '^\d+$') {
        Add-Blocker "taskGroupUpdate.body.revision debe ser un entero (revision del task group). Encontrado: '$($plan.taskGroupUpdate.body.revision)'."
    }
    elseif (-not $plan.taskGroupUpdate.body.tasks -or @($plan.taskGroupUpdate.body.tasks).Count -eq 0) {
        Add-Blocker "taskGroupUpdate.body.tasks debe tener al menos una task (el PUT reemplaza el task group completo)."
    }
    elseif ([string]$plan.taskGroupUpdate.body.id -ne [string]$plan.taskGroupUpdate.id) {
        Add-Blocker "taskGroupUpdate.body.id ('$($plan.taskGroupUpdate.body.id)') debe coincidir con taskGroupUpdate.id ('$($plan.taskGroupUpdate.id)')."
    }
}

# 3d. Validacion especifica de familia 'tg-create' (agregada 2026-10-29):
#     POST para crear/clonar un task group NUEVO. A diferencia de tg-update,
#     el body NO lleva 'id' (ADO lo asigna) ni se exige 'revision'; debe traer
#     'name' (no vacio) y 'tasks' (>=1). El bodyHash de la unica operacion
#     (create-taskgroup) cubre la integridad del body embebido.
if ($plan.family -eq 'tg-create') {
    if (-not $plan.taskGroupCreate) {
        Add-Blocker "Falta 'taskGroupCreate' para familia tg-create."
    }
    elseif (-not $plan.taskGroupCreate.body) {
        Add-Blocker "taskGroupCreate.body debe traer el task group completo a crear (POST)."
    }
    elseif ([string]::IsNullOrWhiteSpace([string]$plan.taskGroupCreate.body.name)) {
        Add-Blocker "taskGroupCreate.body.name debe ser el nombre (no vacio) del task group nuevo."
    }
    elseif (-not $plan.taskGroupCreate.body.tasks -or @($plan.taskGroupCreate.body.tasks).Count -eq 0) {
        Add-Blocker "taskGroupCreate.body.tasks debe tener al menos una task (el POST crea el task group completo)."
    }
}

# 4. Inventario: completitud, organizacion/proyecto y frescura -- ANTES de
#    usarlo para cualquier otra verificacion. Un inventario incompleto o
#    viejo se trata igual que no tener inventario (bloqueante), y ademas
#    no se usa para resolver nada mas abajo.
if ($inventory) {
    $requiredInventoryFields = @('generatedAtUtc', 'organization', 'project', 'paginationComplete', 'projects', 'buildDefinitions', 'releaseDefinitions', 'variableGroups', 'taskGroups', 'serviceConnections', 'agentPools', 'repositories')
    $missingFields = @($requiredInventoryFields | Where-Object { $null -eq $inventory.PSObject.Properties[$_] -or $null -eq $inventory.$_ })
    if ($missingFields.Count -gt 0) {
        Add-Blocker "El inventario esta incompleto: faltan los campos $($missingFields -join ', '). Volver a correr Export-AdoClassicInventory.ps1."
    }
    elseif ($inventory.paginationComplete -ne $true) {
        Add-Blocker "El inventario tiene paginationComplete=$($inventory.paginationComplete) (no true). Solo se acepta un inventario en el que, para cada endpoint exportado, se hayan seguido todos los continuation tokens que Azure DevOps devolvio hasta agotarlos (ver Export-AdoClassicInventory.ps1)."
    }
    elseif ($inventory.organization -ne $RequiredOrganization) {
        Add-Blocker "El inventario es de otra organizacion ('$($inventory.organization)'), no de '$RequiredOrganization'. No se usa para validar este plan."
    }
    elseif ($inventory.project -ne $plan.project) {
        Add-Blocker "El inventario es del proyecto '$($inventory.project)', pero el plan es de '$($plan.project)'. No se usa para validar este plan."
    }
    elseif ($inventory.projects.name -notcontains [string]$plan.project) {
        Add-Blocker "El proyecto '$($plan.project)' no aparece en inventory.projects. No se puede confirmar que exista."
    }
    else {
        $inventoryAgeHours = $null
        try {
            # generatedAtUtc es SIEMPRE UTC (lo escribe Export-AdoClassicInventory.ps1
            # con sufijo Z). Pero cuando el inventario se lee via ConvertFrom-Json,
            # PowerShell puede haber coaccionado el string ISO a un [DateTime] con
            # Kind=Unspecified (pierde la Z), y en un host con offset negativo
            # .ToUniversalTime() sobre un Unspecified lo trata como hora local y
            # resta el offset -> el inventario parece estar "en el futuro". Para ser
            # robustos en cualquier zona horaria, interpretamos el valor como UTC
            # (AssumeUniversal) y lo normalizamos a UTC (AdjustToUniversal),
            # independientemente de si venia como string con Z o como DateTime ya
            # coaccionado.
            $utcStyles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
            $generatedAt = [DateTime]::Parse([string]$inventory.generatedAtUtc, [System.Globalization.CultureInfo]::InvariantCulture, $utcStyles)
            $inventoryAgeHours = ([DateTime]::UtcNow - $generatedAt).TotalHours
        }
        catch {
            Add-Blocker "No se pudo interpretar inventory.generatedAtUtc ('$($inventory.generatedAtUtc)') para calcular su antiguedad."
        }

        if ($null -ne $inventoryAgeHours) {
            if ($inventoryAgeHours -lt 0) {
                Add-Blocker "inventory.generatedAtUtc esta en el futuro. Inventario invalido."
            }
            elseif ($inventoryAgeHours -gt $MaxInventoryAgeHours) {
                Add-Blocker "El inventario tiene $([math]::Round($inventoryAgeHours, 1))h de antiguedad, mas que el limite de $MaxInventoryAgeHours h. Volver a correr Export-AdoClassicInventory.ps1 antes de validar."
            }
            else {
                $inventoryComplete = $true
            }
        }
    }
}

# 5. Repo y branch
# Un plan solo-actualizacion (sin create-build-definition) no crea ningun
# Build nuevo, asi que nunca consume plan.repo para armar un payload -- el
# repo real del pipeline puede vivir en OTRO proyecto de Azure DevOps
# (ej. el repo de la app en un proyecto separado del proyecto de pipelines),
# invisible para Export-AdoClassicInventory.ps1 (que solo lista repos del
# proyecto de pipelines). Exigir que exista ahi siempre bloquearia, sin
# motivo, cualquier update-*/create-variable-group para esos pipelines.
if ($planDeclaresNoNewBuild) {
    Add-Warning "Plan sin create-build-definition: se omite la verificacion de 'repo y branch existentes en el inventario' -- ningun update-*/create-variable-group/create-release-definition consume plan.repo para armar su payload (solo New-AdoBuildDefinitionPayload lo usa, al crear un Build nuevo)."
}
elseif (-not $plan.repo -or -not $plan.repo.name -or -not $plan.repo.prodBranch) {
    Add-Blocker "Falta repo.name o repo.prodBranch."
}
elseif (-not $inventoryComplete) {
    Add-Blocker "NOT_VERIFIED: 'repo y branch existentes' requiere -InventoryPath con un export completo y fresco de Export-AdoClassicInventory.ps1."
}
else {
    # Repo cross-project: el Build puede source-ar un repo que vive en OTRO
    # proyecto de Azure DevOps (ej. la app en proyecto 'Buklo', mientras los
    # pipelines viven en 'DevOps'). Ese repo es invisible para
    # Export-AdoClassicInventory.ps1, que solo lista repos del proyecto de
    # pipelines. Para no bloquear ese escenario legitimo -- ni inventar un id
    # -- se acepta SOLO cuando el plan declara explicitamente repo.project
    # distinto de plan.project Y trae un repo.id (GUID) ya resuelto en vivo
    # por quien genero el plan. El caso normal (mismo proyecto) NO cambia:
    # sigue exigiendo que el repo+branch existan en el inventario.
    $repoIsCrossProject = $plan.repo.PSObject.Properties['project'] -and `
        (-not [string]::IsNullOrWhiteSpace([string]$plan.repo.project)) -and `
        ([string]$plan.repo.project -ne [string]$plan.project)

    if ($repoIsCrossProject) {
        if ([string]::IsNullOrWhiteSpace([string]$plan.repo.id)) {
            Add-Blocker "El repo '$($plan.repo.name)' es cross-project (repo.project='$($plan.repo.project)' != plan.project='$($plan.project)'), invisible para el inventario del proyecto de pipelines. Debe traer un repo.id (GUID) ya resuelto en vivo -- no se puede confirmar sin el."
        }
        elseif ([string]$plan.repo.project -notin $script:AdoAllowedProjects) {
            Add-Blocker "El repo cross-project declara repo.project='$($plan.repo.project)', que no esta en la lista de proyectos permitidos ($($script:AdoAllowedProjects -join ', '))."
        }
        else {
            Add-Warning "Repo '$($plan.repo.name)' es cross-project (proyecto '$($plan.repo.project)', distinto del proyecto de pipelines '$($plan.project)'): no se valida contra el inventario. Se confia en el repo.id resuelto en vivo ('$($plan.repo.id)') y en la branch '$($plan.repo.prodBranch)' declarada -- ambos verificados por el preflight de la sesion coordinadora, no por este validador."
        }
    }
    else {
        $matchedRepo = $inventory.repositories | Where-Object { $_.name -eq $plan.repo.name } | Select-Object -First 1
        if (-not $matchedRepo) {
            Add-Blocker "El repositorio '$($plan.repo.name)' no existe en el inventario del proyecto '$($plan.project)'."
        }
        else {
            if ($matchedRepo.branches -notcontains $plan.repo.prodBranch) {
                Add-Blocker "La branch '$($plan.repo.prodBranch)' no existe en el repositorio '$($plan.repo.name)' segun el inventario."
            }
            else {
                # Id confirmado -- se incluye en el plan.
                $plan.repo | Add-Member -NotePropertyName 'id' -NotePropertyValue $matchedRepo.id -Force
            }
        }
    }
}

# 6. Dockerfile y contexto (solo familia aks, y solo si el plan crea un Build nuevo)
if ($plan.family -eq 'aks' -and -not $planDeclaresNoNewBuild) {
    if (-not $plan.dockerfile -or -not $plan.dockerfile.path) {
        Add-Blocker "Falta dockerfile.path para familia aks."
    }
    if (-not $plan.repo.pathFilter) {
        Add-Blocker "Falta repo.pathFilter (path filter del CI) para familia aks."
    }
}

# 7. Variables sin mezclar capas
if ($plan.family -eq 'aks') {
    $forbiddenDacpacKeys = @('databaseProjectName', 'instanciadb_prod', 'instanciadb_dev', 'instanciadb_uat', 'usuario_db', 'pass_db')
    foreach ($k in $forbiddenDacpacKeys) {
        if ($plan.buildVariables.PSObject.Properties.Name -contains $k -or ($plan.variableGroup -and $plan.variableGroup.keys.PSObject.Properties.Name -contains $k)) {
            Add-Blocker "El plan AKS contiene la key '$k' propia de la familia DACPAC. No mezclar familias."
        }
    }
}
if ($plan.family -eq 'dacpac') {
    $forbiddenAksKeys = @('servicesname', 'aksClusterName', 'aksResourceGroup', 'conexkubernetes', 'namespace')
    foreach ($k in $forbiddenAksKeys) {
        if ($plan.buildVariables.PSObject.Properties.Name -contains $k) {
            Add-Blocker "El plan DACPAC contiene la key '$k' propia de la familia AKS. No mezclar familias."
        }
    }
}

# 8. Task groups (nombre + id + revision), agent pool y service connections
function Resolve-TaskGroupDependency {
    param($DependencyNode, [string]$Label)

    if (-not $DependencyNode -or -not $DependencyNode.name) {
        Add-Blocker "Falta el nombre del task group '$Label' en dependencies."
        return
    }
    if (-not $inventoryComplete) {
        Add-Blocker "NOT_VERIFIED: task group '$($DependencyNode.name)' ($Label) requiere -InventoryPath con un export completo y fresco."
        return
    }

    $matches = @($inventory.taskGroups | Where-Object { $_.name -eq $DependencyNode.name })
    if ($matches.Count -eq 0) {
        Add-Blocker "El task group '$($DependencyNode.name)' ($Label) no existe en el inventario."
        return
    }

    $latest = $matches | Sort-Object { [int]$_.revision } -Descending | Select-Object -First 1
    if ($matches.Count -gt 1) {
        Add-Warning "El task group '$($DependencyNode.name)' ($Label) tiene $($matches.Count) revisiones en el inventario; se tomo la revision vigente $($latest.revision)."
    }

    $DependencyNode | Add-Member -NotePropertyName 'id' -NotePropertyValue $latest.id -Force
    $DependencyNode | Add-Member -NotePropertyName 'revision' -NotePropertyValue $latest.revision -Force
}

function Resolve-ServiceConnectionDependency {
    param($DependencyNode, [string]$Label, [string]$ExpectedType)

    if (-not $DependencyNode -or -not $DependencyNode.name) {
        Add-Blocker "Falta el nombre de la service connection '$Label' en dependencies."
        return
    }
    if (-not $inventoryComplete) {
        Add-Blocker "NOT_VERIFIED: service connection '$($DependencyNode.name)' ($Label) requiere -InventoryPath con un export completo y fresco."
        return
    }

    $matches = @($inventory.serviceConnections | Where-Object { $_.name -eq $DependencyNode.name })
    if ($matches.Count -eq 0) {
        Add-Blocker "La service connection '$($DependencyNode.name)' ($Label) no existe en el inventario."
        return
    }
    if ($matches.Count -gt 1) {
        Add-Blocker "Hay $($matches.Count) service connections llamadas '$($DependencyNode.name)' ($Label) en el inventario -- nombre ambiguo, no se puede resolver cual usar."
        return
    }

    $matched = $matches[0]
    if ($matched.isReady -ne $true) {
        Add-Blocker "La service connection '$($DependencyNode.name)' ($Label) existe pero isReady=$($matched.isReady) (no true). No se referencia una connection que no este lista."
    }
    if ($ExpectedType -and $matched.type -ne $ExpectedType) {
        Add-Blocker "La service connection '$($DependencyNode.name)' ($Label) tiene type='$($matched.type)', se esperaba '$ExpectedType'."
    }

    $DependencyNode | Add-Member -NotePropertyName 'id' -NotePropertyValue $matched.id -Force
}

function Resolve-AgentPoolDependency {
    param($DependencyNode, [string]$Label, [bool]$Required)

    if (-not $DependencyNode -or [string]::IsNullOrWhiteSpace($DependencyNode.name)) {
        if ($Required) {
            Add-Blocker "Falta el agent pool ($Label): es obligatorio para esta familia."
        }
        else {
            Add-Warning "No se especifico agent pool ($Label); se usara la cola por defecto del Build."
        }
        return
    }
    if (-not $inventoryComplete) {
        Add-Blocker "NOT_VERIFIED: agent pool '$($DependencyNode.name)' ($Label) requiere -InventoryPath con un export completo y fresco."
        return
    }

    $matches = @($inventory.agentPools | Where-Object { $_.name -eq $DependencyNode.name })
    if ($matches.Count -eq 0) {
        Add-Blocker "El agent pool '$($DependencyNode.name)' ($Label) no existe en el inventario."
        return
    }
    if ($matches.Count -gt 1) {
        Add-Blocker "Hay $($matches.Count) agent pools llamados '$($DependencyNode.name)' ($Label) en el inventario -- nombre ambiguo, no se puede resolver cual usar."
        return
    }

    $DependencyNode | Add-Member -NotePropertyName 'id' -NotePropertyValue $matches[0].id -Force
}

if (-not $plan.dependencies) {
    # 'vg-update'/'tg-update'/'tg-create' no necesitan dependencies (no crean Build/Release, no usan task groups/pools/SCs)
    if ($plan.family -notin @('vg-update', 'tg-update', 'tg-create')) {
        Add-Blocker "El plan no tiene bloque 'dependencies' (formato desactualizado). Regenerarlo con la version actual de New-AdoClassicAksPlan.ps1 / New-AdoClassicDatabasePlan.ps1."
    }
}
elseif ($plan.family -eq 'aks') {
    Resolve-TaskGroupDependency -DependencyNode $plan.dependencies.buildTaskGroup -Label 'build'
    Resolve-TaskGroupDependency -DependencyNode $plan.dependencies.deployTaskGroup -Label 'deploy'
    Resolve-ServiceConnectionDependency -DependencyNode $plan.dependencies.serviceConnectionAcr -Label 'ACR' -ExpectedType 'dockerregistry'
    # Deployment-Azur-Aks-v3 (task group real, confirmado contra 2
    # definiciones de Produccion en vivo -- portal-cmdb e
    # insurance-platform-web-frontend, ver references/ado-classic-payload-templates.md)
    # resuelve el cluster unicamente con aksClusterName+aksResourceGroup;
    # no consume una service connection de tipo Kubernetes como input de
    # Release. Exigirla ahi es un falso bloqueante -- Deployment-MultiStage-Cluster-Desarrollo
    # (Desarrollo/UAT) si la necesita, se sigue exigiendo igual que antes.
    # Actualizacion 2026-09-11: Deployment-MultiStage-Cluster-Desarrollo tambien esta exento
    # porque usa una service connection SSH (172.16.2.43-desarrollo) interna del task group,
    # no una SC de tipo kubernetes como input del Release. El deploy es SSH directo al servidor.
    $exemptDeployTaskGroups = @('Deployment-Azur-Aks-v3', 'Deployment-MultiStage-Cluster-Desarrollo')
    if ([string]$plan.dependencies.deployTaskGroup.name -notin $exemptDeployTaskGroups) {
        Resolve-ServiceConnectionDependency -DependencyNode $plan.dependencies.serviceConnectionAks -Label 'AKS' -ExpectedType 'kubernetes'
    }
    # Para task groups exentos: si el plan declara una SC (SSH o kubernetes), se verifica que
    # existe en el inventario pero NO se valida el tipo -- el task group la gestiona internamente.
    Resolve-AgentPoolDependency -DependencyNode $plan.dependencies.agentPool -Label 'build' -Required $false

    # Convencion org-wide de agrupacion de merges ("gana el mas nuevo") --
    # ver references/ado-classic-payload-templates.md. Solo se resuelven
    # estos 3 task groups extra cuando el plan trae mergeBatching.enabled=true
    # explicito (nunca por default aca -- un plan viejo sin este campo no
    # debe empezar a exigir dependencias nuevas de la nada).
    if ($plan.mergeBatching -and $plan.mergeBatching.enabled -eq $true) {
        Resolve-TaskGroupDependency -DependencyNode $plan.dependencies.evaluarVentanaTaskGroup -Label 'evaluar-ventana-agrupacion'
        Resolve-TaskGroupDependency -DependencyNode $plan.dependencies.ganaElMasNuevoTaskGroup -Label 'gana-el-mas-nuevo'
        Resolve-TaskGroupDependency -DependencyNode $plan.dependencies.reportarResultadoTaskGroup -Label 'reportar-resultado-hu'
    }
}
elseif ($plan.family -eq 'dacpac') {
    foreach ($tg in @($plan.dependencies.buildTaskGroups)) {
        Resolve-TaskGroupDependency -DependencyNode $tg -Label "build:$($tg.name)"
    }
    Resolve-TaskGroupDependency -DependencyNode $plan.dependencies.deployTaskGroup -Label 'deploy'
    Resolve-AgentPoolDependency -DependencyNode $plan.dependencies.agentPool -Label 'build' -Required $true
}

# 9. Duplicados de nombre y Library compartida (DACPAC)
# Granular por tipo de recurso (2026-08-26, mismo criterio que
# $planDeclaresNoNewBuild del punto 5): un plan puede crear SOLO una
# Variable Group nueva mientras actualiza un Build/Release ya existentes
# en la misma operacion atomica (ej. configurar Dev/UAT de un pipeline que
# ya tiene Build/Release en Produccion). Exigir que el NOMBRE del Build o
# del Release tampoco exista ya no tiene sentido cuando el plan ni
# siquiera va a crear uno -- ese chequeo es (y debe seguir siendo) solo
# para el recurso que el plan realmente va a crear. $isUpdateOnlyPlan
# (todo-o-nada: ausente en cuanto hay CUALQUIER create-*) sigue sin
# alcanzar para este caso, igual que no alcanzaba para el punto 5.
$planCreatesBuild = ($approvedOpsForModeCheck.Count -eq 0) -or [bool]($approvedOpsForModeCheck | Where-Object { [string]$_.operationType -eq 'create-build-definition' })
$planCreatesRelease = ($approvedOpsForModeCheck.Count -eq 0) -or [bool]($approvedOpsForModeCheck | Where-Object { [string]$_.operationType -eq 'create-release-definition' })
$planCreatesVariableGroup = ($approvedOpsForModeCheck.Count -eq 0) -or [bool]($approvedOpsForModeCheck | Where-Object { [string]$_.operationType -eq 'create-variable-group' })

if (-not $inventoryComplete) {
    # vg-update/tg-update/tg-create no necesitan inventario: el recurso ya existe
    # (update) y se confirma via -Current*Json en Apply, o es un create de task
    # group cuyo nombre-no-duplicado se verifica en vivo en Apply, no por inventario.
    if ($plan.family -notin @('vg-update', 'tg-update', 'tg-create')) {
        Add-Blocker "NOT_VERIFIED: 'Variable Group/Build/Release destino no duplicado' requiere -InventoryPath con un export completo y fresco."
    }
}
else {
    if ($isUpdateOnlyPlan) {
        Add-Warning "Plan solo-actualizacion (sin operationType create-*): se omiten los chequeos de 'posible duplicado' de nombre para Build/Release/Variable Group -- el objetivo de un update-* es justamente el recurso que ya existe con ese nombre."
    }
    else {
        if (-not $planCreatesBuild) {
            Add-Warning "Plan sin create-build-definition: se omite el chequeo de 'posible duplicado' de nombre de Build -- este plan no va a crear un Build nuevo."
        }
        elseif ($plan.names.build -and $inventory.buildDefinitions.name -contains $plan.names.build) {
            Add-Blocker "Ya existe una definicion de Build llamada '$($plan.names.build)' - posible duplicado."
        }
        if (-not $planCreatesRelease) {
            Add-Warning "Plan sin create-release-definition: se omite el chequeo de 'posible duplicado' de nombre de Release -- este plan no va a crear un Release nuevo."
        }
        elseif ($plan.names.release -and $inventory.releaseDefinitions.name -contains $plan.names.release) {
            Add-Blocker "Ya existe una definicion de Release llamada '$($plan.names.release)' - posible duplicado."
        }
        if ($plan.family -eq 'aks' -and -not $planCreatesVariableGroup) {
            Add-Warning "Plan sin create-variable-group: se omite el chequeo de 'posible duplicado' de nombre de Variable Group -- este plan no va a crear una Library nueva."
        }
        elseif ($plan.family -eq 'aks' -and $plan.variableGroup.name -and $inventory.variableGroups.name -contains $plan.variableGroup.name) {
            Add-Blocker "Ya existe un Variable Group llamado '$($plan.variableGroup.name)' - posible duplicado."
        }
    }
    if ($plan.family -eq 'dacpac' -and $plan.sharedLibrary.expectedExisting) {
        $matchedLibrary = $inventory.variableGroups | Where-Object { $_.name -eq $plan.sharedLibrary.name } | Select-Object -First 1
        if (-not $matchedLibrary) {
            Add-Blocker "La Library compartida '$($plan.sharedLibrary.name)' no aparece en el inventario. No se crea una nueva: confirmar el nombre real."
        }
        else {
            $plan.sharedLibrary | Add-Member -NotePropertyName 'id' -NotePropertyValue $matchedLibrary.id -Force
        }
    }
}

# 10. CD trigger y artifact filter planificados -- solo aplica a familias
# que planean un Release ('aks'/'dacpac'); 'standalone-build' nunca tiene
# 'release' en el plan, y no es un bloqueante que le falte.
if ($plan.family -in @('aks', 'dacpac')) {
    if (-not $plan.release.cdTriggerEnabled) {
        Add-Blocker "release.cdTriggerEnabled debe ser true (el CD trigger se activa siempre segun las guias)."
    }
    if ($plan.family -eq 'aks' -and -not $plan.release.artifactFilterBranch) {
        Add-Blocker "Falta release.artifactFilterBranch (Include + Build branch de Prod)."
    }

    # 11. Aprobacion de Produccion (gobernanza) - informativo, no bloqueante
    # por si solo. Solo tiene sentido para familias con un stage
    # Produccion real (aks/dacpac) -- 'standalone-build' nunca despliega.
    Add-Warning "Confirmar con el usuario si el stage Produccion requiere pre-deployment approval segun la gobernanza vigente del producto; el plan no lo decide por si solo."
}

# 12. Ausencia de secretos
# Se escanea el plan EXCLUYENDO taskGroupCreate.body/taskGroupUpdate.body: esos
# embeben SCRIPTS de deploy legitimos que contienen 'docker login
# --password-stdin' y '--docker-password="$(containerRegistryPassword)"' (una
# MACRO $(...), no un secreto literal) -- mismo criterio que el escaner de
# placeholders de abajo. Su integridad la cubre el bodyHash (create/update
# -taskgroup), no este escaner de texto. El resto del plan SI se escanea, asi
# que un password literal real en cualquier otro campo sigue bloqueando.
$planForSecretScanObj = $planRaw | ConvertFrom-Json
if ($planForSecretScanObj.PSObject.Properties['taskGroupCreate'] -and $planForSecretScanObj.taskGroupCreate.PSObject.Properties['body']) {
    $planForSecretScanObj.taskGroupCreate.PSObject.Properties.Remove('body')
}
if ($planForSecretScanObj.PSObject.Properties['taskGroupUpdate'] -and $planForSecretScanObj.taskGroupUpdate.PSObject.Properties['body']) {
    $planForSecretScanObj.taskGroupUpdate.PSObject.Properties.Remove('body')
}
$planRawForSecretScan = $planForSecretScanObj | ConvertTo-Json -Depth 40 -Compress
$secretPatterns = @('(?i)password\s*[:=]\s*\S+', '(?i)pat\s*[:=]\s*[a-z0-9]{20,}', '(?i)authorization\s*[:=]\s*basic\s+\S+', '(?i)connectionstring\s*[:=]\s*\S+.*(password|pwd)=')
foreach ($p in $secretPatterns) {
    if ($planRawForSecretScan -match $p) {
        Add-Blocker "El plan parece contener un secreto embebido (patron: $p). Revisar y quitarlo."
    }
}
if ($planRawForSecretScan -match '(?i)AZURE_DEVOPS_PAT\s*[:=]\s*[^$]') {
    Add-Blocker "El plan referencia AZURE_DEVOPS_PAT con un valor literal en vez de un placeholder."
}

# 13. Ausencia de placeholders sin resolver / referencias heredadas de Buklo
#
# Escanea el plan EXCLUYENDO 'validationBlockers'/'validationWarnings' --
# esos dos campos los escribe este mismo script al final de una corrida
# anterior (linea ~538 mas abajo) y pueden contener, como TEXTO DEL
# MENSAJE, las propias palabras que este patron busca (p.ej. este mismo
# bloqueante dice literalmente "CHANGE_ME/xxx/TBD/TODO/<...>" -- si se
# escaneara tal cual, una vez que el plan se guarda con este bloqueante
# una sola vez, cada corrida siguiente lo re-dispara para siempre contra
# su propio texto, sin relacion con el contenido real del plan). Un bug
# real encontrado 2026-08-25 corrigiendo Build 622 revision 6: la palabra
# en espanol "Todo" dentro de una nota (\btodo\b, case-insensitive)
# tambien puede disparar un falso positivo -- eso SI sigue siendo
# deteccion valida (una nota de negocio puede legitimamente decir
# "todo lo demas"), asi que no se excluye 'notes' de este escaneo; el
# autor de la nota simplemente debe evitar esa palabra si le pega al
# patron.
$planClone = $planRaw | ConvertFrom-Json
foreach ($f in @('validationBlockers', 'validationWarnings')) {
    if ($planClone.PSObject.Properties[$f]) { $planClone.PSObject.Properties.Remove($f) }
}
# tg-update (2026-10-16): taskGroupUpdate.body es el task group completo,
# que EMBEBE un script arbitrario (filecontent del File Creator). Un
# script legitimamente contiene '<branch>' en un comentario, 'xxxx' en un
# manifiesto de ejemplo, 'TODO' en una nota de codigo, etc. -- nada de eso
# es un placeholder de NEGOCIO del plan. Escanear el cuerpo del script
# daria falsos positivos perpetuos, asi que se excluye del escaneo de
# placeholders (igual que validationBlockers/Warnings). El resto del plan
# (description, notes, taskGroupUpdate.id, approvedOperations) SI se
# escanea. La integridad del body esta cubierta por su bodyHash, no por
# este escaner de texto.
if ($planClone.PSObject.Properties['taskGroupUpdate'] -and $planClone.taskGroupUpdate.PSObject.Properties['body']) {
    $planClone.taskGroupUpdate.PSObject.Properties.Remove('body')
}
# tg-create (2026-10-29): mismo criterio que taskGroupUpdate.body -- el body
# del task group a crear EMBEBE scripts arbitrarios (filecontent, bash inline)
# que legitimamente contienen '<...>'/'xxx'/'TODO' en comentarios o ejemplos.
# Su integridad la cubre el bodyHash, no este escaner de texto.
if ($planClone.PSObject.Properties['taskGroupCreate'] -and $planClone.taskGroupCreate.PSObject.Properties['body']) {
    $planClone.taskGroupCreate.PSObject.Properties.Remove('body')
}
$planRawForPlaceholderScan = $planClone | ConvertTo-Json -Depth 10 -Compress

$placeholderPattern = '(?i)(change_me|\bxxx+\b|\btbd\b|\btodo\b|<[a-z_]+>)'
if ($planRawForPlaceholderScan -match $placeholderPattern) {
    Add-Blocker "El plan contiene placeholders sin resolver (CHANGE_ME/xxx/TBD/TODO/<...>)."
}

$knownBukloIds = @('584', '585', '586', '587', '588', '589', '590', '591', '592', '593', '594', '595', '596', '621', '367', '368', '369', '370', '371', '372', '373', '374', '375', '376', '377', '378', '380', '488', '298', '392', '393', '394', '395', '396', '397', '398', '399', '400', '401', '402', '403', '408', '181')
foreach ($id in $knownBukloIds) {
    if ($planRaw -match "\b$id\b") {
        Add-Warning "El plan menciona el numero '$id', que coincide con un id de referencia historico de Buklo en las guias. Confirmar que no se copio por error - este plan debe usar ids reales confirmados en vivo, no los de ejemplo."
    }
}

# 14. approvedOperations: manifiesto de escrituras aprobadas. Un array
#     vacio o ausente es VALIDO (significa "nada aprobado todavia", que es
#     el estado real hoy -- ningun generador de planes puebla payloads de
#     Build/Release). Si hay entradas, cada una debe ser EXACTAMENTE una de
#     las 3 operaciones POST autorizadas en $script:AdoAllowedOperationTypes
#     (ver Invoke-AdoRest.ps1): create-variable-group, create-build-
#     definition, create-release-definition, en la URI exacta de esa
#     operacion (organizacion Shared-Service-GM, proyecto DevOps,
#     api-version=7.1, sin id de recurso al final, sin parametros de query
#     extra). Cualquier GET/PUT/DELETE/PATCH, cualquier URI que no calce
#     byte a byte con la plantilla, o un operationType inapropiado para la
#     familia del plan (DACPAC nunca crea una Variable Group/Library nueva)
#     es bloqueante. Invoke-AdoRest.ps1 vuelve a exigir la misma
#     coincidencia exacta (method+uri+bodyHash) antes de cualquier
#     escritura real -- esta validacion es una segunda capa, no la unica.
# OJO doble con arrays de 1 elemento en Windows PowerShell 5.1:
#  1) @($plan.approvedOperations) cuando la propiedad no existe devuelve
#     un array de 1 elemento CONTENIENDO $null (no un array vacio) -- se
#     comprueba $null primero.
#  2) "$x = if (cond) {@()} else {@($y)}" COLAPSA un array de 1 elemento
#     al escalar que contiene (la captura de salida de una rama if/else
#     no preserva el wrapping de @() igual que una asignacion directa) --
#     por eso NO se usa if/else como expresion aca; se asigna @() primero
#     y se reasigna en una sentencia @() aparte dentro del if.
$approvedOperations = @()
if ($null -ne $plan.approvedOperations) {
    $approvedOperations = @($plan.approvedOperations)
}
if ($approvedOperations.Count -gt 0) {
    $seenOperationIds = [System.Collections.Generic.HashSet[string]]::new()
    $seenOperationTypes = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($op in $approvedOperations) {
        if (-not $op.operationId -or [string]::IsNullOrWhiteSpace([string]$op.operationId)) {
            Add-Blocker "Una entrada de approvedOperations no tiene operationId."
            continue
        }
        $opIdLabel = [string]$op.operationId
        if (-not $seenOperationIds.Add($opIdLabel)) {
            Add-Blocker "approvedOperations tiene operationId duplicado: '$opIdLabel'."
        }

        $opType = [string]$op.operationType
        if ([string]::IsNullOrWhiteSpace($opType) -or -not $script:AdoAllowedOperationTypes.Contains($opType)) {
            Add-Blocker "approvedOperations['$opIdLabel'].operationType debe ser uno de: $($script:AdoAllowedOperationTypes.Keys -join ', '). Encontrado: '$($op.operationType)'."
            continue
        }
        if (-not $seenOperationTypes.Add($opType)) {
            Add-Blocker "approvedOperations tiene operationType duplicado: '$opType'. Solo se permite una operacion de cada tipo por plan."
        }
        if ($plan.family -eq 'dacpac' -and $opType -eq 'create-variable-group') {
            Add-Blocker "approvedOperations['$opIdLabel']: 'create-variable-group' no es apropiado para la familia dacpac -- DACPAC nunca crea una Variable Group/Library nueva, siempre referencia la compartida existente (sharedLibrary.expectedExisting)."
        }

        $spec = $script:AdoAllowedOperationTypes[$opType]

        if ($op.method -ne $spec.method) {
            Add-Blocker "approvedOperations['$opIdLabel'].method debe ser '$($spec.method)' para operationType '$opType'. Encontrado: '$($op.method)'."
        }

        if ([string]::IsNullOrWhiteSpace([string]$op.uri)) {
            Add-Blocker "approvedOperations['$opIdLabel'] no tiene uri."
        }
        else {
            $parsedOpUri = $null
            try {
                $parsedOpUri = Assert-AdoAllowedUri -Uri ([string]$op.uri)
            }
            catch {
                Add-Blocker "approvedOperations['$opIdLabel'].uri no es una URI autorizada de Shared-Service-GM: $($_.Exception.Message)"
            }

            if ($parsedOpUri) {
                if ($parsedOpUri.Host -ne $spec.host) {
                    Add-Blocker "approvedOperations['$opIdLabel'].uri debe usar el host '$($spec.host)' para operationType '$opType'. Encontrado: '$($parsedOpUri.Host)'."
                }
                # Proyecto de la ruta: debe estar en $script:AdoAllowedProjects
                # (Invoke-AdoRest.ps1) Y coincidir con plan.project -- mismo
                # criterio que Assert-AdoOperationRequestMatchesSpec (que
                # re-valida esto mismo inmediatamente antes de cada
                # escritura, alli con -ExpectedProject $plan.project), nunca
                # duplicada de forma divergente.
                $expectedOpPath = $null
                if ($parsedOpUri.AbsolutePath -notmatch '^/Shared-Service-GM/([^/]+)(/.*)$') {
                    Add-Blocker "approvedOperations['$opIdLabel'].uri: no se pudo extraer el proyecto de la ruta '$($parsedOpUri.AbsolutePath)'."
                }
                else {
                    $opProjectInUri = $Matches[1]
                    if ($script:AdoAllowedProjects -notcontains $opProjectInUri) {
                        Add-Blocker "approvedOperations['$opIdLabel'].uri: el proyecto '$opProjectInUri' no esta en la lista de proyectos permitidos para escritura ($($script:AdoAllowedProjects -join ', '))."
                    }
                    elseif ($opProjectInUri -ne [string]$plan.project) {
                        Add-Blocker "approvedOperations['$opIdLabel'].uri apunta al proyecto '$opProjectInUri', pero plan.project es '$($plan.project)'."
                    }
                    else {
                        $expectedOpPath = "/Shared-Service-GM/$opProjectInUri$($spec.pathSuffix)"
                    }
                }

                # Comparacion EXACTA (sin TrimEnd) -- alineado con
                # Assert-AdoOperationRequestMatchesSpec en Invoke-AdoRest.ps1,
                # que re-valida esto mismo inmediatamente antes de cada
                # escritura y ya no tolera un '/' extra al final. Los tipos
                # 'update-*' (requiresIdSuffix=$true, agregados 2026-08-25)
                # exigen en cambio un id numerico al final -- misma regla
                # que la funcion compartida, nunca duplicada de forma
                # divergente. Si $expectedOpPath quedo null arriba (proyecto
                # invalido o distinto de plan.project), ya se agrego un
                # blocker especifico -- no se agrega ademas un mensaje de
                # ruta generico y confuso.
                if ($expectedOpPath) {
                    if ([bool]$spec.requiresIdSuffix) {
                        # idPattern: 'uuid' (task group) vs numerico por defecto
                        # (VG/build/release) -- misma regla que
                        # Assert-AdoOperationRequestMatchesSpec en Invoke-AdoRest.ps1.
                        $opIdRegex = if ([string]$spec.idPattern -eq 'uuid') {
                            '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'
                        }
                        else {
                            '(\d+)'
                        }
                        $opIdLabelKind = if ([string]$spec.idPattern -eq 'uuid') { 'id uuid' } else { 'id numerico' }
                        if ($parsedOpUri.AbsolutePath -notmatch "^$([regex]::Escape($expectedOpPath))/$opIdRegex$") {
                            Add-Blocker "approvedOperations['$opIdLabel'].uri debe tener exactamente la ruta '$expectedOpPath/<$opIdLabelKind>' para operationType '$opType'. Encontrada: '$($parsedOpUri.AbsolutePath)'."
                        }
                    }
                    elseif ($parsedOpUri.AbsolutePath -ne $expectedOpPath) {
                        Add-Blocker "approvedOperations['$opIdLabel'].uri debe tener exactamente la ruta '$expectedOpPath' (sin id de recurso ni segmentos extra) para operationType '$opType'. Encontrada: '$($parsedOpUri.AbsolutePath)'."
                    }
                }

                $queryPairs = @{}
                $rawQuery = $parsedOpUri.Query.TrimStart('?')
                if ($rawQuery) {
                    foreach ($pair in ($rawQuery -split '&')) {
                        if (-not $pair) { continue }
                        $kv = $pair -split '=', 2
                        $qKey = [uri]::UnescapeDataString($kv[0])
                        $qVal = if ($kv.Count -gt 1) { [uri]::UnescapeDataString($kv[1]) } else { '' }
                        $queryPairs[$qKey] = $qVal
                    }
                }

                $requiredKeys = @($spec.requiredQuery.Keys)
                $actualKeys = @($queryPairs.Keys)
                $extraKeys = @($actualKeys | Where-Object { $requiredKeys -notcontains $_ })
                $missingKeys = @($requiredKeys | Where-Object { $actualKeys -notcontains $_ })

                if ($extraKeys.Count -gt 0) {
                    Add-Blocker "approvedOperations['$opIdLabel'].uri tiene parametros de query extra no permitidos: $($extraKeys -join ', ')."
                }
                if ($missingKeys.Count -gt 0) {
                    Add-Blocker "approvedOperations['$opIdLabel'].uri no tiene el parametro de query requerido: $($missingKeys -join ', ')."
                }
                foreach ($rk in $requiredKeys) {
                    if ($queryPairs.ContainsKey($rk) -and $queryPairs[$rk] -ne $spec.requiredQuery[$rk]) {
                        Add-Blocker "approvedOperations['$opIdLabel'].uri tiene '$rk=$($queryPairs[$rk])', se esperaba '$rk=$($spec.requiredQuery[$rk])'."
                    }
                }
            }
        }

        if ([string]$op.bodyHash -notmatch '^[0-9a-f]{64}$') {
            Add-Blocker "approvedOperations['$opIdLabel'].bodyHash no es un SHA-256 valido (64 hex)."
        }
    }
}

# Resultado
$nowUtc = (Get-Date).ToUniversalTime().ToString('o')
$plan.validated = ($blockers.Count -eq 0)
$plan | Add-Member -NotePropertyName 'lastValidatedAtUtc' -NotePropertyValue $nowUtc -Force
$plan | Add-Member -NotePropertyName 'validationBlockers' -NotePropertyValue @($blockers) -Force
$plan | Add-Member -NotePropertyName 'validationWarnings' -NotePropertyValue @($warnings) -Force

# validationEvidence: solo se registra cuando realmente hubo un inventario
# completo y fresco usado para validar (inventoryComplete=true). Queda
# DENTRO del contenido protegido por validationHash (no esta en la lista
# de exclusiones de Get-AdoPlanCanonicalHash) -- si alguien edita estos
# campos despues de validar, el hash deja de coincidir igual que con
# cualquier otro campo del plan. Apply-AdoClassicPlan.ps1 recalcula el
# hash del inventario en el momento de aplicar contra esta evidencia.
if ($inventoryComplete) {
    $plan | Add-Member -NotePropertyName 'validationEvidence' -NotePropertyValue ([PSCustomObject]@{
        inventoryGeneratedAtUtc = $inventory.generatedAtUtc
        inventoryHash           = (Get-AdoSha256OfText -Text $inventoryRaw)
        validatedAtUtc          = $nowUtc
        maxInventoryAgeHours    = $MaxInventoryAgeHours
    }) -Force
}
else {
    $plan | Add-Member -NotePropertyName 'validationEvidence' -NotePropertyValue $null -Force
}

if ($plan.validated) {
    $hash = Get-AdoPlanCanonicalHash -Plan $plan
    $plan | Add-Member -NotePropertyName 'validationHash' -NotePropertyValue $hash -Force
}
else {
    $plan | Add-Member -NotePropertyName 'validationHash' -NotePropertyValue $null -Force
}

$plan | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $PlanPath -Encoding utf8

Write-Host "=== Resultado de validacion: $PlanPath ===" -ForegroundColor Cyan
if ($blockers.Count -eq 0) {
    Write-Host "Sin bloqueantes. plan.validated = true (validationHash calculado)" -ForegroundColor Green
}
else {
    Write-Host "Bloqueantes ($($blockers.Count)):" -ForegroundColor Red
    foreach ($b in $blockers) { Write-Host " - $b" -ForegroundColor Red }
}
if ($warnings.Count -gt 0) {
    Write-Host "Advertencias ($($warnings.Count)):" -ForegroundColor Yellow
    foreach ($w in $warnings) { Write-Host " - $w" -ForegroundColor Yellow }
}

exit $(if ($blockers.Count -eq 0) { 0 } else { 1 })
