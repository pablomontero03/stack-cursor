<#
Constructores para el body PUT de update-build-definition / update-
release-definition -- la mitad del flujo de "actualizar una definicion
clasica existente" que faltaba como script versionado (crear ya la cubre
New-AdoClassicAksPlan.ps1 + New-AdoClassicPayloads.ps1). Hasta 2026-08-27
esto se armaba con scripts de scratch ad hoc, una vez por cada
microservicio Buklo (Gateway/Auth/Engine/Notifications/Storage/AI/
Billing) -- este archivo codifica esa logica UNA sola vez, revisable y
probada, para que dejen de hacer falta scripts temporales.

Flujo tipico de uso (todo en memoria, nunca escribe a Azure DevOps por si
mismo -- eso lo sigue haciendo exclusivamente Apply-AdoClassicPlan.ps1
via -UpdateBuildBodyPath/-UpdateReleaseBodyPath):

  1. GET fresco del recurso real -- Get-AdoClassicDefinitionTemplate.ps1
     -Kind Build|Release -DefinitionId <id> -OutDir <scratch> (o
     Invoke-AdoRest -Method GET directo, dot-sourceado, dentro de otro
     script autorizado).
  2. $stripped = ConvertTo-AdoUpdateBuildBody -Build $get.Body
     (o ConvertTo-AdoUpdateReleaseBody -Release $get.Body)
  3. Cero o mas splices composables sobre $stripped (Set-AdoFileCreatorContent,
     Set-AdoReleaseEnvironmentVariableGroups, Add-AdoReleaseEnvironmentCdTrigger,
     Set-AdoReleaseProductionApprovalGate, Add-AdoReleaseEnvironmentReportarResultadoHu,
     Add-AdoBuildMergeBatchingSplice, etc. -- cada caller arma solo los
     que ese pipeline puntual necesita).
  4. $result = New-AdoClassicUpdateApprovedOperation -Kind Build|Release
     -DefinitionId <id> -Body $stripped -OperationId '<id-de-plan>'
  5. Escribir $result.body a disco (el mismo JSON que luego recibe
     -UpdateBuildBodyPath/-UpdateReleaseBodyPath) e incluir
     $result.approvedOperation en plan.approvedOperations -- exactamente
     como ya se hace hoy con New-AdoApprovedOperationEntry para create-*.

Nunca invocado directo desde Bash -- no tiene bloque de ejecucion propio,
solo definiciones de funcion. Depende de que el llamador YA haya
dot-sourceado, en este orden, Invoke-AdoRest.ps1 (Get-AdoBodyCanonicalHash,
$script:AdoCoreBaseUrl/$script:AdoReleaseBaseUrl/$script:AdoApiVersion) y
New-AdoClassicPayloads.ps1 (New-AdoApprovedOperationEntry,
New-AdoMergeBatchingPhases, New-AdoGanaElMasNuevoStep,
New-AdoReportarResultadoHuBuildStep) -- mismo patron que ese archivo usa
para depender de Invoke-AdoRest.ps1 (nunca se dot-sourcea a si mismo,
para no arriesgar un dot-source duplicado si el caller ya lo hizo).

## Decisiones que resuelven ambiguedades reales de la memoria anterior

Investigadas contra un GET fresco real (Release 373, Buklo Microservice
EMR, `.local/azure-devops/exports/raw-release-373-20260827-135633.json`,
y contra `references/Deploy-Desarrollo-UAT-Produccion-Administracion-Proyectos-Web.json`
para el caso de un gate manual real) antes de escribir este archivo, no
copiadas ciegamente de la memoria vieja:

1. **`environments[].properties` (Boards) NUNCA se quita.** La memoria
   `ado-put-update-field-stripping.md` (fecha 2026-08-25, caso
   Administracion-de-proyectos) decia que se quitaba -- pero esa app
   nunca tuvo `properties` poblado, asi que quitarlo era un no-op
   invisible. El caso real posterior (Auth, 2026-08-27) confirmo que en
   cualquier ambiente con despliegues reales `properties` SI tiene datos
   reales (`BoardsEnvironmentType`/`LinkBoardsWorkItems`) que un PUT sin
   ese campo resetea a `{}` -- confirmado ademas por el intento explicito
   de restauracion (properties SI se pudo restaurar via PUT, a diferencia
   de currentRelease que no). El GET fresco de EMR (Release 373, arriba)
   confirma el mismo patron poblado en sus 3 ambientes. Por eso
   ConvertTo-AdoUpdateReleaseBody de este archivo NUNCA quita
   'properties' -- se copia tal cual del GET siempre, sea cual sea su
   contenido (poblado o `{}` vacio, ambos casos son un no-op seguro con
   esta regla).
2. **`environments[].currentRelease` SI se sigue quitando siempre** --
   confirmado (intento de restauracion real 2026-08-27) que es
   autenticamente de solo lectura/calculado por el servidor en este
   endpoint: ni siquiera enviarlo explicito con su valor real lo
   preserva. No hay beneficio en intentar conservarlo.
3. **Ambiguedad NUEVA encontrada al escribir este archivo (no estaba en
   la memoria vieja), resuelta con el mismo criterio que el punto 1**:
   la memoria decia "por cada entrada de
   preDeployApprovals.approvals[]/postDeployApprovals.approvals[]: quitar
   'id' -- mantener SOLO rank/isAutomated/isNotificationOn". Tomado al
   pie de la letra, eso tambien borraria el campo 'approver' de un
   ambiente que YA tiene un gate manual real asignado (confirmado que
   existe con esa forma completa -- displayName/url/_links/id/uniqueName
   -- en el Release real de Administracion-de-proyectos). Igual que con
   'properties', ese detalle nunca goteo de un caso real porque los casos
   documentados hasta ahora aplicaban el update ANTES de que el gate
   manual existiera, o lo aplicaban EN el mismo PUT que lo creaba (nunca
   en un PUT posterior no relacionado). Este archivo usa la regla
   correcta y mas segura: cada aprobacion SOLO pierde su propio 'id'
   (el asignado por el servidor, que si rompe el PUT si se reenvia) --
   'approver'/'rank'/'isAutomated'/'isNotificationOn'/cualquier otro
   campo que el GET traiga se preserva tal cual, para no destruir un gate
   manual real como efecto colateral de un update no relacionado.
4. **BUG REAL corregido 2026-09-04 (Release 388, Buklo-logistics-web):**
   la version original de este archivo tambien quitaba el 'id' del propio
   environment (no solo el de las approvals), basada en una nota de
   `references/ado-classic-payload-templates.md` (2026-08-25, Release 381)
   que resulto mal atribuida -- ese update se hizo con un script de
   scratch ad hoc (esta libreria no existia todavia) y la regla se
   documento por analogia con el body de creacion, sin una ablacion real
   que aislara 'id' como la causa de aquel 400. La PRIMERA vez que esta
   libreria compartida se uso de verdad contra la API (Release 388,
   3 environments, todos sin 'id') el servidor respondio 400 "An item
   with the same key has already been added" -- consistente con el
   comportamiento conocido de Azure DevOps: un environment con id=0/
   ausente en un update-release-definition se interpreta como "environment
   NUEVO a crear", no como "actualizar el existente"; con 3 environments
   simultaneos sin id, los 3 se procesan como altas nuevas y colisionan.
   Fix: `ConvertTo-AdoUpdateReleaseBody` ya NO quita 'id' de
   `environments[]` -- se preserva tal cual vino del GET, igual que el
   'id' de la definicion raiz (que nunca se quito). Ver tambien
   `references/ado-classic-payload-templates.md`, seccion corregida en la
   misma fecha.
5. **BUG REAL corregido 2026-09-04 (mismo Release 388, mismo dia,
   segundo hallazgo inmediatamente despues del de 'id'):** 'owner'
   tambien estaba en la lista de quitar siempre, misma mala atribucion
   documental. El primer PUT ya con 'id' preservado fallo con 400
   "VS402873: Owner of release pipeline stage 'Desarrollo' cannot be
   empty" -- 'owner' es un campo REQUERIDO por la API en un
   update-release-definition, no opcional. Se preserva tal cual vino del
   GET (identidad ya visible en la UI de ADO, no es un secreto).
#>

# Debe coincidir siempre con el task.id usado por New-AdoFileCreatorStep
# (New-AdoClassicPayloads.ps1) -- mismo recurso real (task "File Creator"),
# nunca se duplica el literal sin comentario que explique por que deben
# coincidir.
$script:AdoFileCreatorTaskId = '1f81a8be-d8ce-497d-9791-190126f661e7'

function ConvertTo-AdoNormalizedRawString {
    <#
    Reconstruye un string leido con Get-Content -Raw en una instancia
    fresca (`[string]::new($s.ToCharArray())`) -- workaround confirmado
    para el bug real de PowerShell 5.1 donde un string asi, embebido en un
    objeto grande y luego pasado por ConvertTo-Json -Depth alto, puede
    colgar el proceso (~800x mas lento) en vez de tirar un error. Ver
    memoria de sesion 'ps51-getcontent-raw-convertjson-bug' y el caso real
    de Buklo Microservice Billing. Aplicado automaticamente dentro de
    Set-AdoFileCreatorContent para que un caller no necesite recordarlo.
    #>
    param([Parameter(Mandatory)] [AllowEmptyString()] [string]$Value)
    return [string]::new($Value.ToCharArray())
}

function Set-AdoPSObjectProperty {
    <#
    Asigna $Value a la propiedad $Name de $Object, exista o no todavia --
    a diferencia de la asignacion directa ($obj.Name = $Value), que en
    PowerShell 5.1 falla si la propiedad no existe aun en un
    [PSCustomObject]. Unico punto de este archivo que agrega/reemplaza una
    propiedad potencialmente ausente (ej. 'approver', que solo existe
    cuando ya hay un gate manual real).
    #>
    param([Parameter(Mandatory)] $Object, [Parameter(Mandatory)] [string]$Name, $Value)
    if ($Object.PSObject.Properties[$Name]) {
        $Object.PSObject.Properties[$Name].Value = $Value
    }
    else {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
    }
}

# ================================================================
# Field-stripping: GET real -> body PUT valido (ver ado-classic-payload-
# templates.md "Campos a quitar de un GET antes de usarlo como body de un
# PUT" para el detalle campo por campo, y las 3 decisiones del header de
# arriba para lo que ese documento tenia desactualizado/ambiguo).
# ================================================================

function ConvertTo-AdoUpdateBuildBody {
    <#
    Body para PUT .../build/definitions/{id}. Nunca muta $Build (clona
    primero via ConvertTo-Json/ConvertFrom-Json) -- el objeto original
    (el GET real) queda intacto para quien lo llamo.
    #>
    param([Parameter(Mandatory)] $Build)

    if (-not $Build.PSObject.Properties['id'] -or -not $Build.PSObject.Properties['revision']) {
        throw "ConvertTo-AdoUpdateBuildBody: el objeto recibido no tiene 'id'/'revision' -- debe venir de un GET real de una definicion de Build EXISTENTE, nunca reconstruirse desde cero (para crear, usar New-AdoBuildDefinitionPayload)."
    }

    $clone = $Build | ConvertTo-Json -Depth 60 -Compress | ConvertFrom-Json

    foreach ($field in @('_links', 'authoredBy', 'createdDate', 'drafts', 'uri', 'url', 'project')) {
        if ($clone.PSObject.Properties[$field]) { $clone.PSObject.Properties.Remove($field) }
    }
    if ($clone.PSObject.Properties['queue'] -and $clone.queue.PSObject.Properties['_links']) {
        $clone.queue.PSObject.Properties.Remove('_links')
    }

    return $clone
}

function ConvertTo-AdoUpdateReleaseBody {
    <#
    Body para PUT .../release/definitions/{id}. Nunca muta $Release. Ver
    las decisiones 1 y 3 del header de este archivo para 'properties' y
    'approver' -- las dos diferencias reales respecto a lo que decia la
    memoria/documentacion previa.
    #>
    param([Parameter(Mandatory)] $Release)

    if (-not $Release.PSObject.Properties['id'] -or -not $Release.PSObject.Properties['revision']) {
        throw "ConvertTo-AdoUpdateReleaseBody: el objeto recibido no tiene 'id'/'revision' -- debe venir de un GET real de una definicion de Release EXISTENTE, nunca reconstruirse desde cero (para crear, usar New-AdoReleaseDefinitionPayload)."
    }

    $clone = $Release | ConvertTo-Json -Depth 60 -Compress | ConvertFrom-Json

    foreach ($field in @('_links', 'createdBy', 'createdOn', 'modifiedBy', 'modifiedOn', 'url', 'projectReference', 'source', 'description', 'isDeleted', 'isDisabled')) {
        if ($clone.PSObject.Properties[$field]) { $clone.PSObject.Properties.Remove($field) }
    }

    foreach ($env in @($clone.environments)) {
        # BUG REAL corregido 2026-09-04 (Release 388, Buklo-logistics-web,
        # app-logistics): la version anterior de esta funcion tambien
        # quitaba 'id' de cada environment, basada en una nota de
        # documentacion (2026-08-25, Release 381) que resulto ser una mala
        # atribucion -- nunca hubo una ablacion real que aislara 'id' como
        # la causa de aquel 400 original; ese update se armo con un script
        # de scratch ad hoc (esta libreria compartida no existia todavia),
        # y la regla se documento por analogia con el body de creacion sin
        # volver a probar puntualmente si CONSERVAR el id real rompia algo.
        # Aplicado por primera vez de verdad contra la API real en esta
        # libreria (Release 388, 2026-09-04): un PUT con los 3 environments
        # SIN 'id' fallo con 400 "An item with the same key has already
        # been added" (System.ArgumentException) -- consistente con el
        # comportamiento conocido de Azure DevOps: un environment con
        # id=0/ausente en el body de un update-release-definition se trata
        # como "environment NUEVO a crear", no como "actualizar el
        # existente"; con 3 environments simultaneos sin id, el servidor
        # los procesa a todos como altas nuevas y colisiona en la
        # estructura interna que usa para asignarles alta (probablemente
        # keyed por el id=0 comun a los 3). El id real de cada environment
        # (568/569/570 en el caso de Release 388) es precisamente la senal
        # que le dice al servidor "esto ya existe, actualizalo" -- por eso
        # ahora se PRESERVA tal cual vino del GET, igual que el id de la
        # definicion raiz. 'properties' sigue sin quitarse nunca (decision
        # 1 del header).
        # BUG REAL corregido 2026-09-04 (Release 388, mismo dia, segundo
        # hallazgo tras el de 'id' arriba): 'owner' tambien estaba en esta
        # lista de quitar siempre, misma mala atribucion documental que
        # 'id'. El primer PUT real ya con 'id' preservado fallo con 400
        # "VS402873: Owner of release pipeline stage 'Desarrollo' cannot
        # be empty" -- confirma que 'owner' es un campo REQUERIDO por la
        # API en un update-release-definition, no opcional/de solo
        # lectura. Se preserva tal cual vino del GET (identidad real del
        # dueno del stage, dato ya visible en la UI de ADO para cualquiera
        # con acceso al proyecto -- no es un secreto).
        foreach ($field in @('deployStep', 'badgeUrl', 'currentRelease')) {
            if ($env.PSObject.Properties[$field]) { $env.PSObject.Properties.Remove($field) }
        }

        foreach ($approvalsPropName in @('preDeployApprovals', 'postDeployApprovals')) {
            if (-not $env.PSObject.Properties[$approvalsPropName]) { continue }
            $approvalGroup = $env.$approvalsPropName
            if (-not $approvalGroup -or -not $approvalGroup.PSObject.Properties['approvals']) { continue }
            foreach ($approval in @($approvalGroup.approvals)) {
                # SOLO 'id' -- nunca 'approver' (decision 3 del header):
                # un gate manual real ya asignado debe sobrevivir un
                # update que no lo toca a proposito.
                if ($approval.PSObject.Properties['id']) { $approval.PSObject.Properties.Remove('id') }
            }
        }
    }

    return $clone
}

# ================================================================
# Helpers de busqueda compartidos -- nunca crean un environment/fase
# nuevo en silencio, siempre exigen exactamente 1 coincidencia.
# ================================================================

function Find-AdoReleaseEnvironmentByStage {
    param([Parameter(Mandatory)] $Release, [Parameter(Mandatory)] [string]$Stage)
    $found = @($Release.environments | Where-Object { [string]$_.name -eq $Stage })
    if ($found.Count -eq 0) {
        throw "Find-AdoReleaseEnvironmentByStage: no existe ningun environment llamado '$Stage' en este Release."
    }
    if ($found.Count -gt 1) {
        throw "Find-AdoReleaseEnvironmentByStage: mas de un environment llamado '$Stage' ($($found.Count)) -- ambiguo, resolver a mano."
    }
    return $found[0]
}

function Find-AdoBuildPhaseByRefName {
    param([Parameter(Mandatory)] $Build, [Parameter(Mandatory)] [string]$RefName)
    $found = @($Build.process.phases | Where-Object { [string]$_.refName -eq $RefName })
    if ($found.Count -eq 0) {
        throw "Find-AdoBuildPhaseByRefName: no existe ninguna fase con refName '$RefName' -- confirmar el refName real contra un GET fresco (Show-AdoBuildSteps.ps1)."
    }
    if ($found.Count -gt 1) {
        throw "Find-AdoBuildPhaseByRefName: mas de una fase con refName '$RefName' ($($found.Count)) -- ambiguo."
    }
    return $found[0]
}

# ================================================================
# Splices de Build
# ================================================================

function Set-AdoFileCreatorContent {
    <#
    Encuentra EXACTAMENTE un step 'File Creator' (por displayName + el
    task.id real de ese task) y reemplaza su filecontent (y opcionalmente
    'enabled'). Lanza si encuentra 0 o mas de 1 -- nunca agrega un step
    nuevo en silencio ni adivina cual de varios homonimos es el correcto.
    Precedente real que esto evita: Build 586 (Engine) tenia el
    filecontent de OTRO servicio (Gateway) en sus File Creator dev/uat --
    detectado por longitud sospechosamente igual, nunca por este chequeo
    automatico (no existia todavia).
    #>
    param(
        [Parameter(Mandatory)] $Build,
        [Parameter(Mandatory)] [string]$DisplayName,
        [Parameter(Mandatory)] [string]$FileContent,
        [Nullable[bool]]$Enabled
    )

    $normalizedContent = ConvertTo-AdoNormalizedRawString -Value $FileContent

    $matches = @()
    foreach ($phase in @($Build.process.phases)) {
        foreach ($step in @($phase.steps)) {
            if ([string]$step.displayName -eq $DisplayName -and $step.task -and [string]$step.task.id -eq $script:AdoFileCreatorTaskId) {
                $matches += $step
            }
        }
    }
    if ($matches.Count -eq 0) {
        throw "Set-AdoFileCreatorContent: no se encontro ningun step File Creator con displayName '$DisplayName' -- nunca se agrega un step nuevo en silencio, confirmar el nombre exacto contra un GET fresco."
    }
    if ($matches.Count -gt 1) {
        throw "Set-AdoFileCreatorContent: se encontraron $($matches.Count) steps File Creator con displayName '$DisplayName' -- ambiguo, resolver a mano."
    }

    $matches[0].inputs.filecontent = $normalizedContent
    if ($null -ne $Enabled) { $matches[0].enabled = [bool]$Enabled }
    return $Build
}

function Add-AdoBuildPhase {
    <#
    Inserta una fase (clon, nunca la referencia original) al principio o
    al final de process.phases. Primitiva generica -- para insertar VARIAS
    fases en un orden relativo especifico (ej. las 2 de agrupacion de
    merges antes de la fase principal), construir el array combinado a
    mano en el caller o usar Add-AdoBuildMergeBatchingSplice, que ya lo
    hace con el orden correcto.
    #>
    param(
        [Parameter(Mandatory)] $Build,
        [Parameter(Mandatory)] $Phase,
        [ValidateSet('Prepend', 'Append')] [string]$Position = 'Append'
    )
    $phaseClone = $Phase | ConvertTo-Json -Depth 40 -Compress | ConvertFrom-Json
    if ($Position -eq 'Prepend') {
        $Build.process.phases = @(@($phaseClone) + @($Build.process.phases))
    }
    else {
        $Build.process.phases = @(@($Build.process.phases) + $phaseClone)
    }
    return $Build
}

function Add-AdoBuildStepToPhase {
    <#
    Inserta un step (clon) al principio o al final de los steps de la
    fase con el refName dado.
    #>
    param(
        [Parameter(Mandatory)] $Build,
        [Parameter(Mandatory)] [string]$PhaseRefName,
        [Parameter(Mandatory)] $Step,
        [ValidateSet('Prepend', 'Append')] [string]$Position = 'Append'
    )
    $phase = Find-AdoBuildPhaseByRefName -Build $Build -RefName $PhaseRefName
    $stepClone = $Step | ConvertTo-Json -Depth 40 -Compress | ConvertFrom-Json
    if ($Position -eq 'Prepend') {
        $phase.steps = @(@($stepClone) + @($phase.steps))
    }
    else {
        $phase.steps = @(@($phase.steps) + $stepClone)
    }
    return $Build
}

function Add-AdoBuildStepAfterDisplayName {
    <#
    Inserta un step (clon) INMEDIATAMENTE DESPUES del step existente cuyo
    displayName coincide -- primitiva generica, hermana de
    Add-AdoBuildStepToPhase (que solo soporta Prepend/Append en los
    extremos). Lanza si encuentra 0 o mas de 1 coincidencia -- nunca
    adivina la posicion ni agrega en silencio.
    #>
    param(
        [Parameter(Mandatory)] $Build,
        [Parameter(Mandatory)] [string]$PhaseRefName,
        [Parameter(Mandatory)] [string]$AfterDisplayName,
        [Parameter(Mandatory)] $Step
    )
    $phase = Find-AdoBuildPhaseByRefName -Build $Build -RefName $PhaseRefName
    $steps = @($phase.steps)
    $matchIndex = -1
    for ($i = 0; $i -lt $steps.Count; $i++) {
        if ([string]$steps[$i].displayName -eq $AfterDisplayName) {
            if ($matchIndex -ge 0) {
                throw "Add-AdoBuildStepAfterDisplayName: mas de un step con displayName '$AfterDisplayName' en la fase '$PhaseRefName' -- ambiguo, resolver a mano."
            }
            $matchIndex = $i
        }
    }
    if ($matchIndex -lt 0) {
        throw "Add-AdoBuildStepAfterDisplayName: no se encontro ningun step con displayName '$AfterDisplayName' en la fase '$PhaseRefName'."
    }
    $stepClone = $Step | ConvertTo-Json -Depth 40 -Compress | ConvertFrom-Json
    $newSteps = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -le $matchIndex; $i++) { $newSteps.Add($steps[$i]) }
    $newSteps.Add($stepClone)
    for ($i = $matchIndex + 1; $i -lt $steps.Count; $i++) { $newSteps.Add($steps[$i]) }
    $phase.steps = @($newSteps)
    return $Build
}

function Add-AdoBuildReplaceTokensStep {
    <#
    Splice retroactivo del bug real corregido 2026-09-07 en
    New-AdoBuildDefinitionPayload (ver New-AdoReplaceTokensStep,
    New-AdoClassicPayloads.ps1): agrega el step 'Replace tokens' a un
    Build clasico YA EXISTENTE que use un Dockerfile ya versionado del
    repo con tokens '#{...}#' sin resolver (ej. '#{appname}#'). Nunca
    duplica si el Build ya lo tiene. Posicion default (-AfterDisplayName
    'Task group: Gana-el-mas-nuevo') confirmada contra el unico Build real
    que ya lo tenia (633, Buklo-logistics-web) -- si el Build no tiene
    agrupacion de merges habilitada, pasar -AfterDisplayName vacio para
    insertarlo como PRIMER step de la fase en su lugar.
    #>
    param(
        [Parameter(Mandatory)] $Build,
        [Parameter(Mandatory)] [string]$PhaseRefName,
        [string]$AfterDisplayName = 'Task group: Gana-el-mas-nuevo',
        [string]$RootDirectory = '.',
        [string]$TargetFiles = 'Dockerfile'
    )
    $phase = Find-AdoBuildPhaseByRefName -Build $Build -RefName $PhaseRefName
    $already = @($phase.steps | Where-Object { [string]$_.displayName -eq 'Replace tokens' })
    if ($already.Count -gt 0) {
        throw "Add-AdoBuildReplaceTokensStep: el Build ya tiene un step 'Replace tokens' en la fase '$PhaseRefName' -- no se duplica."
    }
    $step = New-AdoReplaceTokensStep -RootDirectory $RootDirectory -TargetFiles $TargetFiles
    if ([string]::IsNullOrWhiteSpace($AfterDisplayName)) {
        return Add-AdoBuildStepToPhase -Build $Build -PhaseRefName $PhaseRefName -Step $step -Position 'Prepend'
    }
    return Add-AdoBuildStepAfterDisplayName -Build $Build -PhaseRefName $PhaseRefName -AfterDisplayName $AfterDisplayName -Step $step
}

function Set-AdoBuildTriggerMaxConcurrentBuilds {
    param([Parameter(Mandatory)] $Build, [Parameter(Mandatory)] [int]$MaxConcurrentBuildsPerBranch)
    $trigger = @($Build.triggers)[0]
    if (-not $trigger) { throw "Set-AdoBuildTriggerMaxConcurrentBuilds: el Build no tiene triggers[0]." }
    Set-AdoPSObjectProperty -Object $trigger -Name 'maxConcurrentBuildsPerBranch' -Value $MaxConcurrentBuildsPerBranch
    return $Build
}

function Set-AdoBuildTriggerPathFilter {
    <#
    Fija triggers[0].pathFilters de un Build YA EXISTENTE a un unico
    filtro (ej. '+apps/mi-app/**'). Corrige el bug real confirmado
    2026-09-08: New-AdoBuildDefinitionPayload (New-AdoClassicPayloads.ps1)
    nunca leia $Plan.repo.pathFilter al armar el trigger de creacion --
    todo Build creado antes del fix quedo con pathFilters=[] (dispara con
    cualquier commit al monorepo buklo-web, no solo el de su propia app).
    #>
    param([Parameter(Mandatory)] $Build, [Parameter(Mandatory)] [string]$PathFilter)
    $trigger = @($Build.triggers)[0]
    if (-not $trigger) { throw "Set-AdoBuildTriggerPathFilter: el Build no tiene triggers[0]." }
    # coma unaria: fuerza ARRAY JSON de 1 elemento; sin ella ConvertTo-Json
    # lo desenvuelve a string escalar y Azure DevOps descarta el filtro
    # (Build queda con pathFilters=[]). Mismo bug que New-AdoBuildDefinitionPayload.
    Set-AdoPSObjectProperty -Object $trigger -Name 'pathFilters' -Value (,@([string]$PathFilter))
    return $Build
}

function Add-AdoBuildVariables {
    <#
    Agrega/sobreescribe variables de pipeline del Build. Cada valor de
    -Variables es @{ value = '...'; isSecret = $true|$false (opcional,
    default $false) }. isSecret=true exige que 'value' sea el placeholder
    '${ADO_SECRET_...}' -- misma regla que el resto de este dominio
    (ver security.md), nunca se acepta un literal aca.
    #>
    param([Parameter(Mandatory)] $Build, [Parameter(Mandatory)] [hashtable]$Variables)
    foreach ($name in $Variables.Keys) {
        $spec = $Variables[$name]
        $isSecretFlag = $false
        # BUG REAL corregido 2026-09-07 (primera vez que esta funcion se
        # invoco de verdad via el despacho declarativo de splices, Build
        # 634 Buklo-directory-web): ConvertTo-AdoHashtableDeep convierte
        # cada objeto JSON anidado (incluido este $spec) a un
        # [ordered]@{} (System.Collections.Specialized.OrderedDictionary),
        # que NO tiene metodo 'ContainsKey' (solo 'Contains') -- a
        # diferencia de un [hashtable] literal (que tiene ambos). Todo
        # caller anterior de esta funcion (ej. Add-AdoBuildMergeBatchingSplice)
        # siempre paso un [hashtable] literal en memoria, nunca a traves
        # de esta conversion, por eso nunca se detecto antes. '.Contains'
        # funciona igual para ambos tipos.
        if ($spec.Contains('isSecret')) { $isSecretFlag = [bool]$spec['isSecret'] }
        $value = [string]$spec['value']
        if ($isSecretFlag -and $value -notmatch '^\$\{ADO_SECRET_[A-Z0-9_]+\}$') {
            throw "Add-AdoBuildVariables: la variable '$name' esta marcada isSecret=true pero su value no es un placeholder '`${ADO_SECRET_...}' -- nunca un literal."
        }
        $entry = [ordered]@{ value = $value }
        if ($isSecretFlag) { $entry['isSecret'] = $true }
        Set-AdoPSObjectProperty -Object $Build.variables -Name $name -Value ([PSCustomObject]$entry)
    }
    return $Build
}

function Add-AdoBuildMergeBatchingSplice {
    <#
    Aplica RETROACTIVAMENTE (splice sobre un Build ya existente, ya
    obtenido por GET y stripped por ConvertTo-AdoUpdateBuildBody) la
    convencion completa de agrupacion de merges ("gana el mas nuevo") --
    las 8 piezas documentadas en references/ado-classic-payload-templates.md
    "Convencion org-wide: fases de agrupacion de merges". Reusa las
    funciones ya existentes de New-AdoClassicPayloads.ps1
    (New-AdoMergeBatchingPhases/New-AdoGanaElMasNuevoStep/
    New-AdoReportarResultadoHuBuildStep) en vez de reimplementarlas -- esta
    funcion es solo el pegamento que las inserta en un Build que YA tiene
    su fase principal de build real, en el orden y con los campos
    correctos (el error historico documentado: omitir una o mas de las 8
    piezas al replicar esto a mano).

    $MainPhaseRefName debe ser el refName REAL de la fase de build
    (confirmado contra un GET fresco, normalmente 'Job_1' -- nunca se
    asume sin confirmar).

    Lanza si el Build YA tiene una fase 'Batch_Gate'/'Batch_Window' (nunca
    duplica el mecanismo).
    #>
    param(
        [Parameter(Mandatory)] $Build,
        [Parameter(Mandatory)] [string]$EvaluarVentanaTaskGroupId,
        [Parameter(Mandatory)] [string]$GanaElMasNuevoTaskGroupId,
        [Parameter(Mandatory)] [string]$ReportarResultadoTaskGroupId,
        [Parameter(Mandatory)] [string]$MainPhaseRefName,
        [string]$BatchWindowMinutes = '5'
    )

    $existingRefNames = @($Build.process.phases | ForEach-Object { [string]$_.refName })
    if ($existingRefNames -contains 'Batch_Gate' -or $existingRefNames -contains 'Batch_Window') {
        throw "Add-AdoBuildMergeBatchingSplice: el Build YA tiene una fase 'Batch_Gate'/'Batch_Window' -- no se duplica el mecanismo."
    }

    $mainPhase = Find-AdoBuildPhaseByRefName -Build $Build -RefName $MainPhaseRefName

    # Piezas 1-3 (Fase 1: 2 pasos; Fase 2: 1 paso) -- las 2 fases previas,
    # en orden, ANTES de la fase principal.
    $batchPhases = @((New-AdoMergeBatchingPhases -EvaluarVentanaTaskGroupId $EvaluarVentanaTaskGroupId) | ForEach-Object {
        $_ | ConvertTo-Json -Depth 40 -Compress | ConvertFrom-Json
    })
    $Build.process.phases = @(@($batchPhases) + @($Build.process.phases))

    # Pieza 4: Gana-el-mas-nuevo como PRIMER step de la fase principal.
    $alreadyGana = @($mainPhase.steps | Where-Object { [string]$_.displayName -eq 'Task group: Gana-el-mas-nuevo' })
    if ($alreadyGana.Count -eq 0) {
        Add-AdoBuildStepToPhase -Build $Build -PhaseRefName $MainPhaseRefName `
            -Step (New-AdoGanaElMasNuevoStep -TaskGroupId $GanaElMasNuevoTaskGroupId) -Position 'Prepend' | Out-Null
    }

    # Pieza 5: Reportar-resultado-HU al final de la fase principal, con su
    # condition propia (ya la trae New-AdoReportarResultadoHuBuildStep).
    $alreadyReportar = @($mainPhase.steps | Where-Object { [string]$_.displayName -eq 'Task group: Reportar-resultado-HU' })
    if ($alreadyReportar.Count -eq 0) {
        Add-AdoBuildStepToPhase -Build $Build -PhaseRefName $MainPhaseRefName `
            -Step (New-AdoReportarResultadoHuBuildStep -TaskGroupId $ReportarResultadoTaskGroupId) -Position 'Append' | Out-Null
    }

    # Pieza 6: OAuth (allowScriptsAuthAccessOption) tambien en la fase
    # principal (ya viene $true en las 2 fases nuevas, generadas arriba).
    Set-AdoPSObjectProperty -Object $mainPhase.target -Name 'allowScriptsAuthAccessOption' -Value $true

    # Pieza 7: dependencies + condition de la fase principal, linkeada a
    # Batch_Window -- shape ARRAY de 1 objeto, nunca un objeto simple (ver
    # el bug real documentado en debugging.md: un objeto simple aca se
    # ignora en silencio y el job de build real se salta).
    Set-AdoPSObjectProperty -Object $mainPhase -Name 'dependencies' -Value @([ordered]@{ scope = 'Batch_Window'; event = $null })
    $mainPhase.condition = "and(in(dependencies.Batch_Window.result, 'Succeeded', 'SucceededWithIssues', 'Skipped'), not(canceled()))"

    # Pieza 8: maxConcurrentBuildsPerBranch=5 en el trigger de CI (con 1,
    # un build nuevo mientras otro espera queda 'notStarted' y nunca entra
    # a la ventana de agrupacion).
    Set-AdoBuildTriggerMaxConcurrentBuilds -Build $Build -MaxConcurrentBuildsPerBranch 5 | Out-Null

    # Variables de Build requeridas por el mecanismo (valores fijos del
    # mecanismo salvo BATCH_WINDOW_MINUTES).
    Add-AdoBuildVariables -Build $Build -Variables @{
        BATCH_WINDOW_MINUTES  = @{ value = $BatchWindowMinutes }
        SUPERSEDE_REASONS     = @{ value = 'IndividualCI,BatchedCI' }
        BATCH_WAIT_REASONS    = @{ value = 'IndividualCI,BatchedCI' }
        BATCH_PR_TITLE_MARKER = @{ value = '[AUTO]' }
    } | Out-Null

    return $Build
}

# ================================================================
# Splices de Release
# ================================================================

function Set-AdoReleaseEnvironmentVariableGroups {
    <#
    Relinkea el/los Variable Group(s) de un environment YA EXISTENTE (ej.
    despues de recrear una VG con otro id). Reemplaza el array completo --
    para agregar uno mas sin perder los existentes, pasar
    @($env.variableGroups existentes + el nuevo) explicito.
    #>
    param(
        [Parameter(Mandatory)] $Release,
        [Parameter(Mandatory)] [string]$Stage,
        [Parameter(Mandatory)] [int[]]$VariableGroupIds
    )
    $env = Find-AdoReleaseEnvironmentByStage -Release $Release -Stage $Stage
    $env.variableGroups = @($VariableGroupIds)
    return $Release
}

function Set-AdoReleaseEnvironmentVariables {
    <#
    Fija (crea o sobrescribe) 1+ variables a nivel de un environment YA
    EXISTENTE (ej. containerRegistryUsername/containerRegistryPassword,
    forma confirmada contra Release 389 real: cada variable es
    { value, isSecret? }). NUNCA reemplaza el objeto 'variables' completo
    -- solo agrega/sobrescribe las claves indicadas, preservando
    cualquier otra variable de ese environment que ya existiera.

    Defensa en profundidad: si $IsSecret es true, $Value SOLO puede ser un
    placeholder '${ADO_SECRET_...}' -- nunca un literal. Esto es
    independiente del escaneo de secretos de Test-AdoClassicPlan.ps1 (que
    ya bloquearia un literal ahi tambien); esta funcion lo rechaza antes
    de que el valor llegue siquiera al body en memoria.
    #>
    param(
        [Parameter(Mandatory)] $Release,
        [Parameter(Mandatory)] [string]$Stage,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$Value,
        [bool]$IsSecret = $false
    )
    if ($IsSecret -and $Value -notmatch '^\$\{ADO_SECRET_[A-Z0-9_]+\}$') {
        throw "Set-AdoReleaseEnvironmentVariables: con -IsSecret `$true, -Value debe ser exactamente un placeholder '`${ADO_SECRET_NOMBRE}' -- nunca un literal."
    }

    $env = Find-AdoReleaseEnvironmentByStage -Release $Release -Stage $Stage
    if (-not $env.variables) { $env.variables = [PSCustomObject]@{} }

    $entry = if ($IsSecret) { [PSCustomObject]@{ value = $Value; isSecret = $true } } else { [PSCustomObject]@{ value = $Value } }

    if ($env.variables.PSObject.Properties.Name -contains $Name) {
        $env.variables.$Name = $entry
    }
    else {
        $env.variables | Add-Member -NotePropertyName $Name -NotePropertyValue $entry
    }
    return $Release
}

function Add-AdoReleaseEnvironmentCdTrigger {
    <#
    Agrega o reemplaza la condicion de tipo 'artifact' de un environment
    (el CD trigger real por ambiente -- que branch del artifact dispara el
    autodeploy). Nunca toca la condicion 'ReleaseStarted' si ya existe; la
    agrega si por algun motivo faltara (defensivo -- nunca visto ausente
    en un Release real, pero no se asume). Shape de 'value' confirmado
    contra New-AdoReleaseDefinitionPayload/GET reales.
    #>
    param(
        [Parameter(Mandatory)] $Release,
        [Parameter(Mandatory)] [string]$Stage,
        [Parameter(Mandatory)] [string]$ArtifactAlias,
        [Parameter(Mandatory)] [string]$SourceBranch,
        [bool]$UseBuildDefinitionBranch = $false,
        [bool]$CreateReleaseOnBuildTagging = $false
    )
    $env = Find-AdoReleaseEnvironmentByStage -Release $Release -Stage $Stage

    $keptConditions = @($env.conditions | Where-Object { [string]$_.conditionType -ne 'artifact' })
    $hasReleaseStarted = @($keptConditions | Where-Object { [string]$_.name -eq 'ReleaseStarted' -and [string]$_.conditionType -eq 'event' }).Count -gt 0
    if (-not $hasReleaseStarted) {
        $keptConditions += [PSCustomObject][ordered]@{ name = 'ReleaseStarted'; conditionType = 'event'; value = '' }
    }

    $artifactConditionValue = (@{
        sourceBranch                = $SourceBranch
        tags                        = @()
        useBuildDefinitionBranch    = $UseBuildDefinitionBranch
        createReleaseOnBuildTagging = $CreateReleaseOnBuildTagging
    } | ConvertTo-Json -Compress)

    $keptConditions += [PSCustomObject][ordered]@{ name = $ArtifactAlias; conditionType = 'artifact'; value = $artifactConditionValue }
    $env.conditions = @($keptConditions)
    return $Release
}

function Set-AdoReleaseProductionApprovalGate {
    <#
    Ajusta el gate de aprobacion real (pre o post deploy) de un
    environment YA EXISTENTE -- pese al nombre (heredado de la convencion
    ya usada en esta org para el caso mas comun, Produccion), funciona
    para cualquier -Stage. Implementa el patron de 2 pasos documentado:
    Azure DevOps rechaza isAutomated=false sin approver en el POST de
    creacion (400 VS402896) -- este es el segundo paso, un
    update-release-definition PUT posterior sobre un environment que ya
    existe automatico (o el ajuste de un gate ya manual).

    -ApproverId debe ser el id (GUID) real de la identidad/grupo
    aprobador, YA resuelto (nunca inventado por esta funcion). Nunca crea
    'preDeployApprovals'/'postDeployApprovals' desde cero -- exige que el
    environment ya tenga al menos 1 approval (siempre lo tiene, incluso
    automatico, en cualquier Release real).
    #>
    param(
        [Parameter(Mandatory)] $Release,
        [Parameter(Mandatory)] [string]$Stage,
        [ValidateSet('PreDeploy', 'PostDeploy')] [string]$Kind = 'PreDeploy',
        [Parameter(Mandatory)] [bool]$IsAutomated,
        [string]$ApproverId,
        [bool]$IsNotificationOn = $false
    )
    if (-not $IsAutomated -and [string]::IsNullOrWhiteSpace($ApproverId)) {
        throw "Set-AdoReleaseProductionApprovalGate: -IsAutomated `$false requiere -ApproverId -- Azure DevOps rechaza un gate manual sin approver asignado."
    }

    $env = Find-AdoReleaseEnvironmentByStage -Release $Release -Stage $Stage
    $approvalsPropName = if ($Kind -eq 'PreDeploy') { 'preDeployApprovals' } else { 'postDeployApprovals' }
    if (-not $env.PSObject.Properties[$approvalsPropName] -or -not @($env.$approvalsPropName.approvals).Count) {
        throw "Set-AdoReleaseProductionApprovalGate: el environment '$Stage' no tiene '$approvalsPropName.approvals' -- no se crea un gate desde cero con esta funcion, solo se ajusta uno ya existente."
    }

    $approval = @($env.$approvalsPropName.approvals)[0]
    $approval.isAutomated = $IsAutomated
    $approval.isNotificationOn = $IsNotificationOn
    if ($IsAutomated) {
        if ($approval.PSObject.Properties['approver']) { $approval.PSObject.Properties.Remove('approver') }
    }
    else {
        Set-AdoPSObjectProperty -Object $approval -Name 'approver' -Value ([ordered]@{ id = $ApproverId })
    }
    return $Release
}

function Add-AdoReleaseEnvironmentReportarResultadoHu {
    <#
    Agrega RETROACTIVAMENTE el 2do workflowTask 'Task group:
    Reportar-resultado-HU' al 'Agent job' (deployPhases[0]) de un
    environment YA EXISTENTE que todavia no lo tiene, y fuerza
    deploymentInput.enableAccessToken=true SOLO para ese environment --
    mismo mecanismo (lado Release) que New-AdoReleaseDefinitionPayload ya
    aplica al CREAR, pero aplicado como splice sobre un Release ya creado
    (el caso real: Release 381, Administracion-de-proyectos, que necesito
    agregarlo despues via un update-release-definition separado). Shape
    del workflowTask confirmado contra New-AdoReleaseDefinitionPayload.
    #>
    param(
        [Parameter(Mandatory)] $Release,
        [Parameter(Mandatory)] [string]$Stage,
        [Parameter(Mandatory)] [string]$TaskGroupId,
        [string]$Condition = 'always()'
    )
    $env = Find-AdoReleaseEnvironmentByStage -Release $Release -Stage $Stage
    $phase = @($env.deployPhases)[0]
    if (-not $phase) {
        throw "Add-AdoReleaseEnvironmentReportarResultadoHu: el environment '$Stage' no tiene deployPhases[0]."
    }
    $already = @($phase.workflowTasks | Where-Object { [string]$_.name -eq 'Task group: Reportar-resultado-HU' })
    if ($already.Count -gt 0) {
        throw "Add-AdoReleaseEnvironmentReportarResultadoHu: el environment '$Stage' YA tiene un workflowTask 'Reportar-resultado-HU' -- no se agrega un duplicado."
    }

    $newTask = [PSCustomObject][ordered]@{
        taskId                  = $TaskGroupId
        version                 = '1.*'
        name                    = 'Task group: Reportar-resultado-HU'
        refName                 = ''
        enabled                 = $true
        alwaysRun               = $true
        continueOnError         = $true
        timeoutInMinutes        = 0
        retryCountOnTaskFailure = 0
        definitionType          = 'metaTask'
        overrideInputs          = [ordered]@{}
        condition               = $Condition
        environment             = [ordered]@{}
        inputs                  = [ordered]@{}
    }
    $phase.workflowTasks = @(@($phase.workflowTasks) + $newTask)
    Set-AdoPSObjectProperty -Object $phase.deploymentInput -Name 'enableAccessToken' -Value $true
    return $Release
}

# ================================================================
# Ensamblado final de approvedOperations
# ================================================================

function New-AdoClassicUpdateOperationUri {
    param(
        [Parameter(Mandatory)] [ValidateSet('Build', 'Release')] [string]$Kind,
        [Parameter(Mandatory)] [int]$DefinitionId,
        [string]$Project = 'DevOps'
    )
    $base = if ($Kind -eq 'Build') { $script:AdoCoreBaseUrl } else { $script:AdoReleaseBaseUrl }
    $path = if ($Kind -eq 'Build') { 'build/definitions' } else { 'release/definitions' }
    return "$base/$Project/_apis/$path/$DefinitionId`?api-version=$($script:AdoApiVersion)"
}

function New-AdoClassicUpdateApprovedOperation {
    <#
    Ultimo paso: dado el body YA COMPUESTO (stripping + splices ya
    aplicados) de un update-build-definition/update-release-definition,
    arma la entrada de approvedOperations -- via New-AdoApprovedOperationEntry,
    que sigue siendo el UNICO punto que calcula bodyHash, nunca duplicado
    aca -- y devuelve tambien el body final, listo para: (a) escribirse a
    disco en el path que luego recibe -UpdateBuildBodyPath/
    -UpdateReleaseBodyPath de Invoke-AdoApplyPhases, y (b) incluirse en
    plan.approvedOperations.
    #>
    param(
        [Parameter(Mandatory)] [ValidateSet('Build', 'Release')] [string]$Kind,
        [Parameter(Mandatory)] [int]$DefinitionId,
        [Parameter(Mandatory)] $Body,
        [Parameter(Mandatory)] [string]$OperationId,
        [string]$Project = 'DevOps'
    )
    $operationType = if ($Kind -eq 'Build') { 'update-build-definition' } else { 'update-release-definition' }
    $uri = New-AdoClassicUpdateOperationUri -Kind $Kind -DefinitionId $DefinitionId -Project $Project
    $entry = New-AdoApprovedOperationEntry -OperationId $OperationId -OperationType $operationType -Uri $uri -Body $Body
    return [ordered]@{ approvedOperation = $entry; uri = $uri; body = $Body }
}

# ================================================================
# Runner (agregado 2026-08-27): cierra el 2do gap identificado el mismo
# dia que este archivo -- hasta ahora esto era solo una libreria
# composable, y armar el plan real seguia exigiendo un script de scratch
# ad hoc por cada microservicio. Invoke-AdoClassicUpdatePlanGeneration es
# la orquestacion completa (GET real -> stripping -> splices declarativos
# -> approvedOperations -> body/plan a disco), como FUNCION -- para poder
# probarla en el mismo proceso con Invoke-AdoRest/Invoke-WebRequest
# mockeados, exactamente igual que Invoke-AdoApplyPhases
# (New-AdoClassicPayloads.ps1). El wrapper ejecutable real para linea de
# comandos es New-AdoClassicUpdatePlan.ps1 (un archivo separado, deliberadamente
# delgado: solo el bloque param() + un llamado a esta funcion + los
# Write-Host de resumen -- nunca logica nueva ahi).
# ================================================================

# Mapa cerrado de splices permitidos. La UNICA forma real de despacho es
# el 'switch' literal de Invoke-AdoUpdateSplice mas abajo -- este array
# solo se usa para el mensaje de error (nunca para resolver el nombre a
# ejecutar). Nunca Invoke-Expression, nunca '&'-dinamico sobre un string,
# nunca Get-Command con un nombre recibido de una especificacion
# declarativa externa.
$script:AdoUpdateSpliceAllowedFunctions = @(
    'Set-AdoFileCreatorContent', 'Add-AdoBuildPhase', 'Add-AdoBuildStepToPhase',
    'Add-AdoBuildStepAfterDisplayName', 'Add-AdoBuildReplaceTokensStep',
    'Set-AdoBuildTriggerMaxConcurrentBuilds', 'Set-AdoBuildTriggerPathFilter', 'Add-AdoBuildVariables', 'Add-AdoBuildMergeBatchingSplice',
    'Set-AdoReleaseEnvironmentVariableGroups', 'Add-AdoReleaseEnvironmentCdTrigger',
    'Set-AdoReleaseProductionApprovalGate', 'Add-AdoReleaseEnvironmentReportarResultadoHu',
    'Set-AdoReleaseEnvironmentVariables'
)

function ConvertTo-AdoHashtableDeep {
    <#
    Convierte recursivamente un PSCustomObject (resultado tipico de
    ConvertFrom-Json) en un [ordered] hashtable splateable, preservando
    arrays (cada elemento tambien convertido) y dejando escalares tal
    cual. Necesario porque los parametros de algunas funciones splice
    (ej. Add-AdoBuildVariables -Variables [hashtable]) no aceptan un
    PSCustomObject directo.
    #>
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string]) { return $InputObject }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $out = [ordered]@{}
        foreach ($k in @($InputObject.Keys)) { $out[$k] = ConvertTo-AdoHashtableDeep -InputObject $InputObject[$k] }
        return $out
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $out = [ordered]@{}
        foreach ($p in $InputObject.PSObject.Properties) { $out[$p.Name] = ConvertTo-AdoHashtableDeep -InputObject $p.Value }
        return $out
    }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        $arr = @($InputObject | ForEach-Object { ConvertTo-AdoHashtableDeep -InputObject $_ })
        return , $arr
    }
    return $InputObject
}

function Invoke-AdoUpdateSplice {
    <#
    Unico punto de despacho de splices. $FunctionName SOLO puede coincidir
    con una de las ramas literales del switch -- cualquier otro valor cae
    en 'default' y lanza sin ejecutar nada. $Params nunca puede traer
    'build'/'release' (validado por el llamador antes de invocar esto).
    #>
    param(
        [Parameter(Mandatory)] $Target,
        [Parameter(Mandatory)] [ValidateSet('Build', 'Release')] [string]$Kind,
        [Parameter(Mandatory)] [string]$FunctionName,
        [Parameter(Mandatory)] [System.Collections.IDictionary]$Params
    )

    switch ($FunctionName) {
        'Set-AdoFileCreatorContent' {
            if ($Kind -ne 'Build') { throw "Invoke-AdoUpdateSplice: 'Set-AdoFileCreatorContent' solo aplica a -Kind Build." }
            return Set-AdoFileCreatorContent @Params -Build $Target
        }
        'Add-AdoBuildPhase' {
            if ($Kind -ne 'Build') { throw "Invoke-AdoUpdateSplice: 'Add-AdoBuildPhase' solo aplica a -Kind Build." }
            return Add-AdoBuildPhase @Params -Build $Target
        }
        'Add-AdoBuildStepToPhase' {
            if ($Kind -ne 'Build') { throw "Invoke-AdoUpdateSplice: 'Add-AdoBuildStepToPhase' solo aplica a -Kind Build." }
            return Add-AdoBuildStepToPhase @Params -Build $Target
        }
        'Add-AdoBuildStepAfterDisplayName' {
            if ($Kind -ne 'Build') { throw "Invoke-AdoUpdateSplice: 'Add-AdoBuildStepAfterDisplayName' solo aplica a -Kind Build." }
            return Add-AdoBuildStepAfterDisplayName @Params -Build $Target
        }
        'Add-AdoBuildReplaceTokensStep' {
            if ($Kind -ne 'Build') { throw "Invoke-AdoUpdateSplice: 'Add-AdoBuildReplaceTokensStep' solo aplica a -Kind Build." }
            return Add-AdoBuildReplaceTokensStep @Params -Build $Target
        }
        'Set-AdoBuildTriggerMaxConcurrentBuilds' {
            if ($Kind -ne 'Build') { throw "Invoke-AdoUpdateSplice: 'Set-AdoBuildTriggerMaxConcurrentBuilds' solo aplica a -Kind Build." }
            return Set-AdoBuildTriggerMaxConcurrentBuilds @Params -Build $Target
        }
        'Set-AdoBuildTriggerPathFilter' {
            if ($Kind -ne 'Build') { throw "Invoke-AdoUpdateSplice: 'Set-AdoBuildTriggerPathFilter' solo aplica a -Kind Build." }
            return Set-AdoBuildTriggerPathFilter @Params -Build $Target
        }
        'Add-AdoBuildVariables' {
            if ($Kind -ne 'Build') { throw "Invoke-AdoUpdateSplice: 'Add-AdoBuildVariables' solo aplica a -Kind Build." }
            return Add-AdoBuildVariables @Params -Build $Target
        }
        'Add-AdoBuildMergeBatchingSplice' {
            if ($Kind -ne 'Build') { throw "Invoke-AdoUpdateSplice: 'Add-AdoBuildMergeBatchingSplice' solo aplica a -Kind Build." }
            return Add-AdoBuildMergeBatchingSplice @Params -Build $Target
        }
        'Set-AdoReleaseEnvironmentVariableGroups' {
            if ($Kind -ne 'Release') { throw "Invoke-AdoUpdateSplice: 'Set-AdoReleaseEnvironmentVariableGroups' solo aplica a -Kind Release." }
            return Set-AdoReleaseEnvironmentVariableGroups @Params -Release $Target
        }
        'Add-AdoReleaseEnvironmentCdTrigger' {
            if ($Kind -ne 'Release') { throw "Invoke-AdoUpdateSplice: 'Add-AdoReleaseEnvironmentCdTrigger' solo aplica a -Kind Release." }
            return Add-AdoReleaseEnvironmentCdTrigger @Params -Release $Target
        }
        'Set-AdoReleaseProductionApprovalGate' {
            if ($Kind -ne 'Release') { throw "Invoke-AdoUpdateSplice: 'Set-AdoReleaseProductionApprovalGate' solo aplica a -Kind Release." }
            return Set-AdoReleaseProductionApprovalGate @Params -Release $Target
        }
        'Set-AdoReleaseEnvironmentVariables' {
            if ($Kind -ne 'Release') { throw "Invoke-AdoUpdateSplice: 'Set-AdoReleaseEnvironmentVariables' solo aplica a -Kind Release." }
            return Set-AdoReleaseEnvironmentVariables @Params -Release $Target
        }
        'Add-AdoReleaseEnvironmentReportarResultadoHu' {
            if ($Kind -ne 'Release') { throw "Invoke-AdoUpdateSplice: 'Add-AdoReleaseEnvironmentReportarResultadoHu' solo aplica a -Kind Release." }
            return Add-AdoReleaseEnvironmentReportarResultadoHu @Params -Release $Target
        }
        default {
            throw "Invoke-AdoUpdateSplice rechazado: la funcion '$FunctionName' no esta en el mapa cerrado de splices permitidos ($($script:AdoUpdateSpliceAllowedFunctions -join ', ')). Nunca se despacha una funcion arbitraria recibida por una especificacion declarativa externa."
        }
    }
}

function Write-AdoUpdatePlanUtf8NoBom {
    param([Parameter(Mandatory)] [string]$Path, [Parameter(Mandatory)] [string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-AdoClassicUpdatePlanGeneration {
    <#
    Orquestacion completa del runner (ver header de New-AdoClassicUpdatePlan.ps1
    para el flujo detallado paso a paso). Funcion separada del script de
    nivel superior para poder probarla dot-sourceada, con Invoke-AdoRest
    (via Invoke-WebRequest) mockeado -- mismo criterio que
    Invoke-AdoApplyPhases.

    Nunca hace ninguna escritura real en Azure DevOps: la unica llamada de
    red es un GET de solo lectura del recurso a actualizar. Devuelve un
    resumen (nunca el body completo, para no imprimirlo por error en un
    log de pruebas) con OperationType/BodyPath/PlanPath/
    AppliedFunctionNames/ApprovedOperation.
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
        [string]$ExistingPlanPath,
        [string]$BuildName,
        [string]$ReleaseName,
        [string]$BuildTaskGroupName = 'Build-MultiStage',
        [string]$DeployTaskGroupName = 'Deployment-Azur-Aks-v3',
        [string]$ServiceConnectionAcrName,
        [string]$ServiceConnectionAksName = '',
        [string]$ArtifactFilterBranch,
        [ValidateSet('Desarrollo', 'UAT', 'Produccion')] [string]$Stage = 'Produccion',
        # Solo relevante para el Modo 2 (esqueleto nuevo, sin -ExistingPlanPath).
        # 'aks' (default, comportamiento historico sin cambios) exige
        # Release+ACR; 'standalone-build' (agregado 2026-09-01, mismo gap que
        # ya se cerro en Test-AdoClassicPlan.ps1/Invoke-AdoApplyPhases) arma
        # un esqueleto minimo sin Release -- solo aplica a -Kind Build.
        [ValidateSet('aks', 'standalone-build')] [string]$Family = 'aks'
    )

    if ($Organization -ne 'Shared-Service-GM') {
        throw "Invoke-AdoClassicUpdatePlanGeneration rechazado: esta skill solo opera sobre la organizacion 'Shared-Service-GM'."
    }

    # ---- 1) GET fresco (solo lectura) del recurso real. ----

    $resourceUri = New-AdoClassicUpdateOperationUri -Kind $Kind -DefinitionId $DefinitionId -Project $Project
    $operationType = if ($Kind -eq 'Build') { 'update-build-definition' } else { 'update-release-definition' }

    # Defensa en profundidad, mismo patron que New-AdoClassicDeletePlan.ps1:
    # confirmar que la uri armada cumple EXACTO el contrato del
    # operationType ANTES de usarla, tanto para el GET como para la
    # entrada aprobada final.
    $null = Assert-AdoOperationRequestMatchesSpec -OperationType $operationType -Method 'PUT' -Uri $resourceUri -Label 'plan-generation'

    Write-Host "GET (solo lectura) $Kind $DefinitionId ..." -ForegroundColor Cyan
    $getResult = Invoke-AdoRest -Method GET -Uri $resourceUri
    $rawResource = $getResult.Body

    if ($null -eq $rawResource -or $null -eq $rawResource.PSObject.Properties['id']) {
        throw "Invoke-AdoClassicUpdatePlanGeneration rechazado: el GET de $Kind $DefinitionId no devolvio un recurso valido."
    }
    if ([int]$rawResource.id -ne $DefinitionId) {
        throw "Invoke-AdoClassicUpdatePlanGeneration rechazado: el GET devolvio id=$($rawResource.id), distinto de -DefinitionId ($DefinitionId)."
    }

    # ---- 2) Field-stripping. ----

    $currentTarget = if ($Kind -eq 'Build') { ConvertTo-AdoUpdateBuildBody -Build $rawResource } else { ConvertTo-AdoUpdateReleaseBody -Release $rawResource }

    # ---- 3) Splices declarativos, en orden, via el switch cerrado. ----

    if (-not (Test-Path -LiteralPath $SpliceSpecPath)) {
        throw "Invoke-AdoClassicUpdatePlanGeneration rechazado: no existe -SpliceSpecPath '$SpliceSpecPath'."
    }
    $spliceSpecParsed = Get-Content -LiteralPath $SpliceSpecPath -Raw -Encoding UTF8 | ConvertFrom-Json
    # ConvertFrom-Json de un array JSON vacio ('[]') puede devolver $null en
    # Windows PowerShell 5.1 -- se trata igual que "sin splices", nunca
    # como error.
    $spliceEntries = @()
    if ($null -ne $spliceSpecParsed) { $spliceEntries = @($spliceSpecParsed) }

    $appliedFunctionNames = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $spliceEntries) {
        if (-not $entry.PSObject.Properties['function'] -or [string]::IsNullOrWhiteSpace([string]$entry.function)) {
            throw "Invoke-AdoClassicUpdatePlanGeneration rechazado: una entrada de -SpliceSpecPath no tiene 'function'."
        }
        $functionName = [string]$entry.function

        $excludedKeys = @('function')
        $fileContentPathValue = $null
        if ($functionName -eq 'Set-AdoFileCreatorContent') {
            $pathPropName = $null
            if ($entry.PSObject.Properties['fileContentPath']) { $pathPropName = 'fileContentPath' }
            elseif ($entry.PSObject.Properties['contentPath']) { $pathPropName = 'contentPath' }
            if ($pathPropName) {
                if ($entry.PSObject.Properties['fileContent']) {
                    throw "Invoke-AdoClassicUpdatePlanGeneration rechazado: una entrada de 'Set-AdoFileCreatorContent' no puede traer 'fileContent' y '$pathPropName' a la vez -- ambiguo."
                }
                $fileContentPathValue = [string]$entry.$pathPropName
                $excludedKeys += $pathPropName
            }
        }

        $paramsHashtable = [ordered]@{}
        foreach ($prop in $entry.PSObject.Properties) {
            if ($excludedKeys -contains $prop.Name) { continue }
            if ($prop.Name -in @('build', 'release')) {
                throw "Invoke-AdoClassicUpdatePlanGeneration rechazado: la entrada de '$functionName' no puede traer una clave '$($prop.Name)' -- el objetivo (Build/Release) lo provee siempre esta funcion, nunca la especificacion declarativa."
            }
            $paramsHashtable[$prop.Name] = ConvertTo-AdoHashtableDeep -InputObject $prop.Value
        }

        if ($fileContentPathValue) {
            if (-not (Test-Path -LiteralPath $fileContentPathValue)) {
                throw "Invoke-AdoClassicUpdatePlanGeneration rechazado: el archivo de contenido '$fileContentPathValue' (Set-AdoFileCreatorContent) no existe."
            }
            $paramsHashtable['FileContent'] = (Get-Content -LiteralPath $fileContentPathValue -Raw -Encoding UTF8)
        }

        Write-Host "Aplicando splice: $functionName ..." -ForegroundColor Cyan
        $currentTarget = Invoke-AdoUpdateSplice -Target $currentTarget -Kind $Kind -FunctionName $functionName -Params $paramsHashtable
        $appliedFunctionNames.Add($functionName)
    }

    # ---- 4) Body final -> disco, PRIMERO, serializando una unica vez. ----
    #
    # Bug real encontrado 2026-09-02 (batch de cambio de nombre de BD UAT,
    # 10 Builds Buklo): Apply-AdoClassicPlan.ps1 rechazo el primer Apply
    # real (Build 585) con "el bodyHash aprobado no coincide con el body
    # solicitado" -- el body en disco era correcto (verificado por fuera),
    # pero el bodyHash se habia calculado sobre $currentTarget (el objeto
    # en memoria, resultado de GET -> ConvertTo-AdoUpdateBuildBody -> splice,
    # nunca releido de disco todavia), mientras que Apply-AdoClassicPlan.ps1
    # (via Invoke-AdoApplyPhases) reconstruye el body para la escritura real
    # con 'Get-Content -LiteralPath $UpdateBuildBodyPath -Raw | ConvertFrom-Json'
    # -- es decir, RELEYENDO EL ARCHIVO YA ESCRITO EN DISCO, sin especificar
    # -Encoding. Primer intento de fix (reparsear el mismo string en
    # memoria via '$bodyJsonText | ConvertFrom-Json', sin tocar disco) dio
    # el MISMO hash que el objeto original -- descartado, no reproducia la
    # diferencia real. Fix correcto: escribir a disco PRIMERO, y despues
    # RELEER ESE MISMO ARCHIVO desde disco (Get-Content, sin -Encoding,
    # exactamente como Invoke-AdoApplyPhases) para calcular
    # approvedOperations -- asi el bodyHash se computa siempre sobre el
    # resultado EXACTO de la misma lectura de disco que va a hacer
    # Apply-AdoClassicPlan.ps1 al aplicar, nunca sobre el objeto en memoria
    # previo a la escritura.

    $bodyJsonText = $currentTarget | ConvertTo-Json -Depth 60
    Write-AdoUpdatePlanUtf8NoBom -Path $OutBodyPath -Text $bodyJsonText
    # Bug real encontrado 2026-09-02 (2do hallazgo del mismo dia, ver Build
    # 585 rechazado por Azure DevOps con TF20507 tras el fix del bodyHash):
    # sin -Encoding UTF8, esta lectura reproduce el MISMO bug de codepage
    # que Invoke-AdoApplyPhases (ver ese comentario, New-AdoClassicPayloads.ps1)
    # -- sin el fix, el bodyHash calculado aca coincidiria con lo que
    # Apply-time enviaria, pero AMBOS estarian calculando sobre un body
    # corrupto (con caracteres de control C1 invalidos), no sobre el
    # correcto. Con -Encoding UTF8 en los dos lados, el body que se hashea
    # y el body que se envia son el mismo Y son el correcto.
    $reparsedBody = Get-Content -LiteralPath $OutBodyPath -Raw -Encoding UTF8 | ConvertFrom-Json

    # ---- 5) approvedOperations, calculado sobre el body RELEIDO DE DISCO
    #      (misma lectura exacta que Apply-AdoClassicPlan.ps1 va a hacer al
    #      aplicar), nunca sobre $currentTarget ni sobre el string en
    #      memoria directamente. ----

    $updateResult = New-AdoClassicUpdateApprovedOperation -Kind $Kind -DefinitionId $DefinitionId -Body $reparsedBody -OperationId $OperationId -Project $Project

    # ---- 6) Plan -> disco. ----

    if (-not [string]::IsNullOrWhiteSpace($ExistingPlanPath)) {
        # Modo 1: agregar sobre un plan ya existente.
        if (-not (Test-Path -LiteralPath $ExistingPlanPath)) {
            throw "Invoke-AdoClassicUpdatePlanGeneration rechazado: -ExistingPlanPath '$ExistingPlanPath' no existe."
        }
        $plan = Get-Content -LiteralPath $ExistingPlanPath -Raw -Encoding UTF8 | ConvertFrom-Json

        if ($plan.family -notin @('aks', 'dacpac', 'standalone-build')) {
            throw "Invoke-AdoClassicUpdatePlanGeneration rechazado: -ExistingPlanPath tiene family='$($plan.family)', debe ser 'aks', 'dacpac' o 'standalone-build'."
        }
        if ($plan.organization -ne $Organization) {
            throw "Invoke-AdoClassicUpdatePlanGeneration rechazado: -ExistingPlanPath es de la organizacion '$($plan.organization)', distinta de -Organization '$Organization'."
        }
        if ($plan.project -ne $Project) {
            throw "Invoke-AdoClassicUpdatePlanGeneration rechazado: -ExistingPlanPath es del proyecto '$($plan.project)', distinto de -Project '$Project'."
        }

        $existingApprovedOps = @()
        if ($null -ne $plan.approvedOperations) { $existingApprovedOps = @($plan.approvedOperations) }
        $duplicateOfSameType = @($existingApprovedOps | Where-Object { [string]$_.operationType -eq $operationType })
        if ($duplicateOfSameType.Count -gt 0) {
            throw "Invoke-AdoClassicUpdatePlanGeneration rechazado: -ExistingPlanPath ya tiene una operacion de tipo '$operationType' (approvedOperations no admite 2 operaciones del mismo tipo). Quitarla del plan de origen antes de volver a correr esto."
        }

        $plan.approvedOperations = @($existingApprovedOps + $updateResult.approvedOperation)
        Set-AdoPSObjectProperty -Object $plan -Name 'validated' -Value $false
        Set-AdoPSObjectProperty -Object $plan -Name 'validationHash' -Value $null
        Set-AdoPSObjectProperty -Object $plan -Name 'validationEvidence' -Value $null
        Set-AdoPSObjectProperty -Object $plan -Name 'lastValidatedAtUtc' -Value $null
        Set-AdoPSObjectProperty -Object $plan -Name 'validationBlockers' -Value @()
        Set-AdoPSObjectProperty -Object $plan -Name 'validationWarnings' -Value @()

        Write-AdoUpdatePlanUtf8NoBom -Path $OutPlanPath -Text ($plan | ConvertTo-Json -Depth 20)
    }
    elseif ($Family -eq 'standalone-build') {
        # Modo 2, familia standalone-build: esqueleto minimo, sin Release,
        # sin service connections -- ver Test-AdoClassicPlan.ps1 (una
        # entrada approvedOperations sin create-build-definition nunca
        # exige plan.repo, y names.release no aplica a esta familia).
        if ($Kind -ne 'Build') {
            throw "Invoke-AdoClassicUpdatePlanGeneration rechazado: -Family 'standalone-build' solo aplica a -Kind Build (esta familia nunca tiene Release)."
        }
        if ([string]::IsNullOrWhiteSpace($BuildName)) {
            throw "Invoke-AdoClassicUpdatePlanGeneration rechazado: sin -ExistingPlanPath hace falta armar un esqueleto nuevo, y falta -BuildName."
        }

        $plan = [ordered]@{
            family         = 'standalone-build'
            generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            organization   = $Organization
            project        = $Project
            validated      = $false

            names = [ordered]@{
                build = $BuildName
            }

            dependencies = [ordered]@{}

            approvedOperations = @($updateResult.approvedOperation)

            notes = @(
                "Plan de solo-actualizacion generado por New-AdoClassicUpdatePlan.ps1 (esqueleto minimo standalone-build, sin -ExistingPlanPath) -- ningun cambio en Azure DevOps ejecutado.",
                "Este plan NO crea ningun Build/Release/Variable Group nuevo (no trae ninguna operationType create-*): solo trae '$operationType' sobre el recurso id=$DefinitionId ya existente.",
                "Splices aplicados en esta corrida: $(if ($appliedFunctionNames.Count -gt 0) { $appliedFunctionNames -join ', ' } else { '(ninguno -- solo field-stripping)' })."
            )
        }

        Write-AdoUpdatePlanUtf8NoBom -Path $OutPlanPath -Text ($plan | ConvertTo-Json -Depth 20)
    }
    else {
        # Modo 2: esqueleto nuevo, familia aks (default historico).
        $missingSkeletonFields = [System.Collections.Generic.List[string]]::new()
        if ([string]::IsNullOrWhiteSpace($BuildName)) { $missingSkeletonFields.Add('-BuildName') }
        if ([string]::IsNullOrWhiteSpace($ReleaseName)) { $missingSkeletonFields.Add('-ReleaseName') }
        if ([string]::IsNullOrWhiteSpace($ServiceConnectionAcrName)) { $missingSkeletonFields.Add('-ServiceConnectionAcrName') }
        if ([string]::IsNullOrWhiteSpace($ArtifactFilterBranch)) { $missingSkeletonFields.Add('-ArtifactFilterBranch') }
        if ($missingSkeletonFields.Count -gt 0) {
            throw "Invoke-AdoClassicUpdatePlanGeneration rechazado: sin -ExistingPlanPath hace falta armar un esqueleto nuevo, y faltan: $($missingSkeletonFields -join ', ')."
        }

        $dependencies = [ordered]@{
            buildTaskGroup       = [ordered]@{ name = $BuildTaskGroupName; id = $null; revision = $null }
            deployTaskGroup      = [ordered]@{ name = $DeployTaskGroupName; id = $null; revision = $null }
            serviceConnectionAcr = [ordered]@{ name = $ServiceConnectionAcrName; id = $null }
            serviceConnectionAks = [ordered]@{ name = $ServiceConnectionAksName; id = $null }
            agentPool            = [ordered]@{ name = $null; id = $null }
        }

        $plan = [ordered]@{
            family         = 'aks'
            generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            organization   = $Organization
            project        = $Project
            validated      = $false

            names = [ordered]@{
                build   = $BuildName
                release = $ReleaseName
            }

            dependencies = $dependencies

            mergeBatching = [ordered]@{
                enabled       = $false
                windowMinutes = '5'
            }

            release = [ordered]@{
                cdTriggerEnabled     = $true
                stage                = $Stage
                deployTaskGroup      = $DeployTaskGroupName
                artifactFilterBranch = $ArtifactFilterBranch
            }

            approvedOperations = @($updateResult.approvedOperation)

            notes = @(
                "Plan de solo-actualizacion generado por New-AdoClassicUpdatePlan.ps1 (esqueleto minimo, sin -ExistingPlanPath) -- ningun cambio en Azure DevOps ejecutado.",
                "Este plan NO crea ningun Build/Release/Variable Group nuevo (no trae ninguna operationType create-*): solo trae '$operationType' sobre el recurso id=$DefinitionId ya existente.",
                "Splices aplicados en esta corrida: $(if ($appliedFunctionNames.Count -gt 0) { $appliedFunctionNames -join ', ' } else { '(ninguno -- solo field-stripping)' })."
            )
        }

        Write-AdoUpdatePlanUtf8NoBom -Path $OutPlanPath -Text ($plan | ConvertTo-Json -Depth 20)
    }

    return [ordered]@{
        OperationType        = $operationType
        BodyPath             = $OutBodyPath
        PlanPath             = $OutPlanPath
        AppliedFunctionNames = @($appliedFunctionNames)
        ApprovedOperation    = $updateResult.approvedOperation
    }
}
