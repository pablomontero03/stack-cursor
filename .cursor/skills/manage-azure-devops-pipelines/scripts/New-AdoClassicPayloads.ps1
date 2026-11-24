<#
Constructores DETERMINISTAS de payload para Apply-AdoClassicPlan.ps1: dado
un plan ya validado (validated=true, ids resueltos por
Test-AdoClassicPlan.ps1 contra inventario en vivo) mas los pocos datos que
solo se conocen en el momento de aplicar (contenido real de los 3
manifiestos K8s, ids reales de recursos ya creados en fases previas),
arma el body EXACTO que se va a enviar a cada POST. Nunca inventa
valores: cualquier dato no resuelto lanza una excepcion explicita en vez
de improvisar un default silencioso, salvo los defaults DOCUMENTADOS en
references/ado-classic-payload-templates.md (queue/pool de Build y
Release, tomados de una definicion real existente).

'approvedOperations se genera automaticamente a partir de los payloads
finales' se cumple asi: nunca se escribe un bodyHash a mano en ningun
lado -- siempre se calcula con Get-AdoBodyCanonicalHash sobre el mismo
objeto que despues se envia con Invoke-AdoRest. New-AdoApprovedOperationEntry
es el unico punto que arma una entrada de approvedOperations, y siempre
parte de un body real construido por las funciones de este archivo.

Dot-sourceado por Apply-AdoClassicPlan.ps1 y por las pruebas (nunca
invocado directo desde Bash -- no tiene bloque de ejecucion propio, solo
definiciones de función).
#>

# Id real del proyecto DevOps (confirmado via core_list_projects del MCP
# oficial 2026-08-24) -- unico proyecto de pipelines de este dominio hoy.
# Necesario porque variableGroupProjectReferences exige el GUID real del
# proyecto, no solo el nombre.
$script:AdoDevOpsProjectId = '7f632f4b-b3cb-4530-a5ff-ee9f809ab478'

function New-AdoVariableGroupPayload {
    <#
    Body para POST .../distributedtask/variablegroups. Usa
    $Plan.variableGroup.name / .keys tal cual (ya son datos de la app,
    confirmados por el usuario o resueltos por Test-AdoClassicPlan.ps1 --
    esta funcion no los valida de nuevo, solo les da forma de payload).

    variableGroupProjectReferences es OBLIGATORIO para esta org/version de
    API -- confirmado con un GET real (VariableGroup 370,
    Desarrollo-portal-cmdb) el 2026-08-24 despues de que un primer intento
    de POST sin este campo fallara con 500. Sin este campo, Azure DevOps
    rechaza la creacion.
    #>
    param([Parameter(Mandatory)] $Plan)

    if (-not $Plan.variableGroup -or -not $Plan.variableGroup.name) {
        throw "New-AdoVariableGroupPayload: el plan no tiene variableGroup.name."
    }

    $variables = [ordered]@{}
    foreach ($prop in $Plan.variableGroup.keys.PSObject.Properties) {
        $variables[$prop.Name] = [ordered]@{ value = [string]$prop.Value }
    }

    $projectName = [string]$Plan.project
    $projectId = switch ($projectName) {
        'DevOps' { $script:AdoDevOpsProjectId }
        default  { $null }
    }
    if (-not $projectId) {
        throw "New-AdoVariableGroupPayload: no se pudo resolver el id real del proyecto '$projectName' para variableGroupProjectReferences -- solo 'DevOps' esta soportado hoy (id documentado y confirmado). Agregar un mapeo explicito (nunca inventado) antes de usar otro proyecto."
    }

    return [ordered]@{
        name      = [string]$Plan.variableGroup.name
        type      = 'Vsts'
        variables = $variables
        variableGroupProjectReferences = @(
            [ordered]@{
                projectReference = [ordered]@{ id = $projectId; name = $projectName }
                name             = [string]$Plan.variableGroup.name
                description      = ''
            }
        )
    }
}

function New-AdoVariableGroupUpdatePayload {
    <#
    Body para PUT .../distributedtask/variablegroups/<id>. Toma el VG actual
    ($CurrentVariableGroup, obtenido con un GET previo por el llamador) y
    MUTA solo las variables indicadas en $Plan.variableGroupUpdate.variables,
    PRESERVANDO todo lo demas (name, type, variableGroupProjectReferences,
    otras variables que no se tocan). Esto evita perder variables existentes
    o romper la estructura del VG.

    El llamador es responsable de:
    1. Hacer el GET del VG actual (lectura, MCP o Get-AdoClassicVariables)
    2. Pasar el body completo como $CurrentVariableGroup
    3. Este generador solo da forma al payload de update

    Agregado 2026-10-14 como parte de la capacidad update-variable-group
    (Pablo pidio que los agentes puedan editar VG existentes).
    #>
    param(
        [Parameter(Mandatory)] $Plan,
        [Parameter(Mandatory)] $CurrentVariableGroup
    )

    if (-not $Plan.variableGroupUpdate -or -not $Plan.variableGroupUpdate.id) {
        throw "New-AdoVariableGroupUpdatePayload: el plan no tiene variableGroupUpdate.id."
    }
    if (-not $Plan.variableGroupUpdate.variables -or $Plan.variableGroupUpdate.variables.Count -eq 0) {
        throw "New-AdoVariableGroupUpdatePayload: el plan no tiene variableGroupUpdate.variables (hashtable de claves a mutar)."
    }
    if (-not $CurrentVariableGroup -or -not $CurrentVariableGroup.id) {
        throw "New-AdoVariableGroupUpdatePayload: CurrentVariableGroup no es un objeto VG valido (falta .id)."
    }
    if ([int]$CurrentVariableGroup.id -ne [int]$Plan.variableGroupUpdate.id) {
        throw "New-AdoVariableGroupUpdatePayload: el id del CurrentVariableGroup ($($CurrentVariableGroup.id)) no coincide con el plan ($($Plan.variableGroupUpdate.id)) -- mismatch peligroso, abortando."
    }

    # Clonar las variables existentes para no mutar el original.
    # El VG puede venir como hashtable (desde PowerShell) o PSCustomObject (desde JSON).
    $variables = [ordered]@{}
    $sourceVars = $CurrentVariableGroup.variables
    if ($sourceVars -is [hashtable] -or $sourceVars -is [System.Collections.Specialized.OrderedDictionary]) {
        # Iterar sobre las keys del hashtable/dictionary
        foreach ($key in $sourceVars.Keys) {
            $variables[$key] = $sourceVars[$key]
        }
    } else {
        # Iterar sobre las propiedades del PSCustomObject
        foreach ($prop in $sourceVars.PSObject.Properties) {
            $variables[$prop.Name] = $prop.Value
        }
    }

    # Aplicar las mutaciones indicadas en el plan.
    # Igual que arriba, manejar hashtable y PSCustomObject.
    $planVars = $Plan.variableGroupUpdate.variables
    $mutationKeys = @()
    if ($planVars -is [hashtable] -or $planVars -is [System.Collections.Specialized.OrderedDictionary]) {
        $mutationKeys = @($planVars.Keys)
    } else {
        $mutationKeys = @($planVars.PSObject.Properties | ForEach-Object { $_.Name })
    }
    
    foreach ($varName in $mutationKeys) {
        # El valor del plan puede ser (a) un string plano (comportamiento
        # historico) o (b) un objeto { secretEnvVar = 'ADO_SECRET_...' } para
        # declarar una variable SECRETA (agregado 2026-10-29). Un secreto NUNCA
        # trae value literal: va como placeholder '${ADO_SECRET_...}' +
        # isSecret=true, y el llamador (Apply Fase 1b) lo resuelve en memoria
        # con New-AdoBodyWithResolvedSecrets. Asi se dejan los VG dev/uat igual
        # a cotizadores (containerRegistryPassword secreto) sin exponer el valor.
        # Acceso ROBUSTO al valor: $planVars puede ser hashtable (indexable por
        # clave) o PSCustomObject (tras ConvertFrom-Json en Apply, donde
        # $planVars[$name] devuelve $null). Resolver por tipo.
        if ($planVars -is [hashtable] -or $planVars -is [System.Collections.Specialized.OrderedDictionary]) {
            $planVal = $planVars[$varName]
        } else {
            $planVal = $planVars.PSObject.Properties[$varName].Value
        }
        # Deteccion PRECISA de "objeto secreto": un string SIEMPRE es valor plano
        # (nunca entra aca, aunque tras ConvertFrom-Json su tipo parezca PSObject);
        # solo un no-string que EXPONE 'secretEnvVar' es un secreto.
        $secretEnvVar = $null
        if ($planVal -isnot [string]) {
            if ($planVal -is [hashtable] -or $planVal -is [System.Collections.Specialized.OrderedDictionary]) {
                if ($planVal.Contains('secretEnvVar')) { $secretEnvVar = [string]$planVal['secretEnvVar'] }
            }
            elseif ($null -ne $planVal.PSObject -and $null -ne $planVal.PSObject.Properties['secretEnvVar']) {
                $secretEnvVar = [string]$planVal.secretEnvVar
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($secretEnvVar)) {
            if ($secretEnvVar -notmatch '^ADO_SECRET_[A-Z0-9_]+$') {
                throw "New-AdoVariableGroupUpdatePayload: 'secretEnvVar' de '$varName' ('$secretEnvVar') no tiene la forma ADO_SECRET_<NOMBRE>."
            }
            # Un secreto NUNCA debe traer un 'value' literal acompanante -- solo
            # 'secretEnvVar'. Rechazar para no embeber jamas un valor en claro.
            $hasLiteralValue = $false
            if ($planVal -is [hashtable] -or $planVal -is [System.Collections.Specialized.OrderedDictionary]) {
                $hasLiteralValue = $planVal.Contains('value') -and -not [string]::IsNullOrWhiteSpace([string]$planVal['value'])
            } elseif ($null -ne $planVal.PSObject.Properties['value']) {
                $hasLiteralValue = -not [string]::IsNullOrWhiteSpace([string]$planVal.value)
            }
            if ($hasLiteralValue) {
                throw "New-AdoVariableGroupUpdatePayload: la variable secreta '$varName' trae un 'value' literal junto a 'secretEnvVar' -- un secreto NUNCA lleva value literal, solo secretEnvVar."
            }
            $variables[$varName] = [ordered]@{ value = "`${$secretEnvVar}"; isSecret = $true }
            continue
        }

        $newValue = [string]$planVal
        if ($variables.Contains($varName)) {
            # La variable existe: reemplazar preservando isSecret si existe
            $existingVar = $variables[$varName]
            $isSecret = $false
            if ($existingVar -is [hashtable] -and $existingVar.ContainsKey('isSecret')) {
                $isSecret = $existingVar.isSecret
            } elseif ($null -ne $existingVar.PSObject -and $null -ne $existingVar.PSObject.Properties['isSecret']) {
                $isSecret = $existingVar.isSecret
            }
            if ($isSecret) {
                $variables[$varName] = [ordered]@{ value = $newValue; isSecret = $true }
            } else {
                $variables[$varName] = [ordered]@{ value = $newValue }
            }
        } else {
            # Variable nueva: crear con value simple
            $variables[$varName] = [ordered]@{ value = $newValue }
        }
    }

    # Construir el payload preservando la estructura completa del VG
    return [ordered]@{
        id                             = [int]$CurrentVariableGroup.id
        name                           = [string]$CurrentVariableGroup.name
        type                           = [string]$CurrentVariableGroup.type
        variables                      = $variables
        variableGroupProjectReferences = $CurrentVariableGroup.variableGroupProjectReferences
    }
}

# Queue/pool default documentados en references/ado-classic-payload-templates.md
# -- tomados de Build-portal-cmdb (578) y su Release (360), definiciones
# reales y funcionales del mismo tipo de app en este mismo proyecto
# DevOps. Sobreescribibles via $Plan.dependencies.agentPool si esta
# presente (nombre+id ya resueltos por Test-AdoClassicPlan.ps1).
$script:AdoDefaultBuildQueue = [ordered]@{ id = 127; pool = [ordered]@{ id = 9; name = 'Azure Pipelines' } }
$script:AdoDefaultReleaseDeployQueueId = 308

# Las 2 "options" de un Build clasico de esta org (CI habilitado a nivel
# de opcion + creacion de work item en fallo, deshabilitada) son fijas
# para toda la organizacion -- mismo id de definicion de opcion siempre,
# tomado de Build-portal-cmdb (578).
$script:AdoStandardBuildOptions = @(
    [ordered]@{
        enabled    = $true
        definition = [ordered]@{ id = '5d58cc01-7c75-450c-be18-a388ddb129ec' }
        inputs     = [ordered]@{ branchFilters = '["+refs/heads/*"]'; additionalFields = '{}' }
    },
    [ordered]@{
        enabled    = $false
        definition = [ordered]@{ id = 'a9db38f9-9fdc-478c-b0f9-464221e58316' }
        inputs     = [ordered]@{ workItemType = 'Bug'; assignToRequestor = 'true'; additionalFields = '{}' }
    }
)

# Script puente EXACTO de la convencion org-wide de agrupacion de merges
# ("gana el mas nuevo") -- ver references/ado-classic-payload-templates.md
# § "Convencion org-wide: fases de agrupacion de merges". Texto fijo,
# confirmado contra Build-portal-cmdb (552) real -- nunca se genera ni se
# parametriza, es logica de plomeria entre el task group
# Evaluar-ventana-agrupacion y la fase siguiente.
$script:AdoMergeBatchingBridgeScript = @'
$ErrorActionPreference = 'Continue'
$v = $env:SHOULDWAIT
if ([string]::IsNullOrWhiteSpace($v)) { $v = $env:shouldWait }
if ([string]::IsNullOrWhiteSpace($v)) {
  $v = 'true'
  Write-Host '##vso[task.logissue type=warning]shouldWait no llego del task group; se espera por precaucion.'
}
Write-Host "Puente: shouldWait=$v"
Write-Host "##vso[task.setvariable variable=shouldWait;isOutput=true]$v"
exit 0
'@

function New-AdoMergeBatchingPhases {
    <#
    Arma las 2 fases previas a la fase de build real ('Evaluar ventana' y
    'Ventana de agrupacion') de la convencion org-wide de agrupacion de
    merges ("gana el mas nuevo") -- ver
    references/ado-classic-payload-templates.md. Confirmado campo por
    campo contra Build-portal-cmdb (552, real) y aplicado a
    Build-administracion-proyectos-web (622, revision 8).

    $EvaluarVentanaTaskGroupId debe venir YA RESUELTO por
    Test-AdoClassicPlan.ps1 contra inventario en vivo -- esta funcion
    nunca inventa un id.
    #>
    param(
        [Parameter(Mandatory)] [string]$EvaluarVentanaTaskGroupId
    )

    return @(
        [ordered]@{
            steps = @(
                [ordered]@{
                    environment             = [ordered]@{}
                    enabled                 = $true
                    continueOnError         = $true
                    alwaysRun               = $false
                    displayName             = 'Task group: Evaluar-ventana-agrupacion'
                    timeoutInMinutes        = 5
                    retryCountOnTaskFailure = 0
                    condition               = 'succeeded()'
                    task                    = [ordered]@{ id = $EvaluarVentanaTaskGroupId; versionSpec = '1.*'; definitionType = 'metaTask' }
                    inputs                  = [ordered]@{}
                },
                [ordered]@{
                    environment             = [ordered]@{}
                    enabled                 = $true
                    continueOnError         = $true
                    alwaysRun               = $false
                    displayName             = 'Publicar shouldWait al job siguiente'
                    timeoutInMinutes        = 5
                    retryCountOnTaskFailure = 0
                    condition               = 'succeeded()'
                    task                    = [ordered]@{ id = 'e213ff0f-5d5c-4791-802d-52ea3e7be1f1'; versionSpec = '2.*'; definitionType = 'task' }
                    refName                 = 'gate'
                    inputs                  = [ordered]@{
                        targetType               = 'inline'
                        filePath                 = ''
                        arguments                = ''
                        script                   = $script:AdoMergeBatchingBridgeScript
                        errorActionPreference    = 'continue'
                        failOnStderr             = 'false'
                        showWarnings             = 'false'
                        ignoreLASTEXITCODE       = 'true'
                        pwsh                     = 'false'
                        workingDirectory         = ''
                        runScriptInSeparateScope = 'false'
                    }
                }
            )
            name                  = 'Evaluar ventana'
            refName               = 'Batch_Gate'
            condition             = 'and(succeeded(), not(canceled()))'
            target                = [ordered]@{
                executionOptions             = [ordered]@{ type = 0 }
                allowScriptsAuthAccessOption = $true
                type                         = 1
            }
            jobAuthorizationScope     = 'projectCollection'
            jobTimeoutInMinutes       = 10
            jobCancelTimeoutInMinutes = 1
        },
        [ordered]@{
            steps = @(
                [ordered]@{
                    environment             = [ordered]@{}
                    enabled                 = $true
                    continueOnError         = $false
                    alwaysRun               = $false
                    displayName             = 'Esperar ventana para agrupar merges de varias HU'
                    timeoutInMinutes        = 0
                    retryCountOnTaskFailure = 0
                    condition               = 'succeeded()'
                    task                    = [ordered]@{ id = '28782b92-5e8e-4458-9751-a71cd1492bae'; versionSpec = '1.*'; definitionType = 'task' }
                    inputs                  = [ordered]@{ delayForMinutes = '$(BATCH_WINDOW_MINUTES)' }
                }
            )
            name                  = 'Ventana de agrupacion'
            refName               = 'Batch_Window'
            # ARRAY de 1 objeto {scope,event}, NUNCA un objeto simple --
            # bug real encontrado 2026-08-26 en un Build real (21316,
            # Build 584): un objeto simple aca hace que Azure DevOps
            # ignore el campo EN SILENCIO (sin error de validacion ni de
            # API), dejando el phase siguiente sin ningun link real hacia
            # este -- 'dependencies.Batch_Window.result' llega Null en la
            # condition de Job_1, y el job de build real se salta
            # completo aunque el Build termine en verde. Shape confirmado
            # contra Build 552 (real, en produccion, GET fresco):
            # "dependencies":[{"scope":"Batch_Gate","event":null}].
            dependencies          = @([ordered]@{ scope = 'Batch_Gate'; event = $null })
            condition             = "and(and(succeeded(), ne(variables['BATCH_WINDOW_MINUTES'], '0'), eq(dependencies.Batch_Gate.outputs['gate.shouldWait'], 'true')), not(canceled()))"
            target                = [ordered]@{
                executionOptions = [ordered]@{ type = 0 }
                type             = 2
            }
            jobAuthorizationScope     = 'projectCollection'
            jobTimeoutInMinutes       = 120
            jobCancelTimeoutInMinutes = 1
        }
    )
}

function New-AdoGanaElMasNuevoStep {
    <#
    Step 'Task group: Gana-el-mas-nuevo' -- debe ir SIEMPRE como PRIMER
    step de la fase de build real cuando la agrupacion de merges esta
    habilitada (se omitio por error la primera vez que se replico esta
    convencion a mano, ver memoria ado-batching-phases-standing-convention).
    #>
    param([Parameter(Mandatory)] [string]$TaskGroupId)
    return [ordered]@{
        environment             = [ordered]@{}
        enabled                 = $true
        continueOnError         = $false
        alwaysRun               = $false
        displayName             = 'Task group: Gana-el-mas-nuevo'
        timeoutInMinutes        = 5
        retryCountOnTaskFailure = 0
        condition               = 'succeeded()'
        task                    = [ordered]@{ id = $TaskGroupId; versionSpec = '1.*'; definitionType = 'metaTask' }
        inputs                  = [ordered]@{}
    }
}

function New-AdoReportarResultadoHuBuildStep {
    <#
    Step 'Task group: Reportar-resultado-HU' con la forma de un step de
    BUILD (process.phases[].steps[], campos task.id/versionSpec) -- NO
    confundir con la forma de Release (New-AdoReleaseDefinitionPayload
    arma su propio workflowTask con forma distinta: taskId/version).
    $Condition default coincide con el real de 552/622 rev8: un build
    superado por la agrupacion no debe comentar ERROR en la HU.

    CORREGIDO 2026-08-25 (dry-run de comparacion contra Build 622/552
    reales): `alwaysRun` es `$false` en AMBOS Build 552 y Build 622
    reales (confirmado via GET), no `$true` como se asumio la primera
    vez -- esa suposicion se copio del lado Release (donde si es `true`)
    sin confirmar el lado Build por separado. La `condition` propia
    (`and(always(), not(canceled()))`) ya cubre el "correr aunque el
    step anterior haya fallado"; `alwaysRun=true` seria redundante/
    innecesario y no es lo que la organizacion usa de verdad.
    #>
    param(
        [Parameter(Mandatory)] [string]$TaskGroupId,
        [string]$Condition = 'and(always(), not(canceled()))'
    )
    return [ordered]@{
        environment             = [ordered]@{}
        enabled                 = $true
        continueOnError         = $true
        alwaysRun               = $false
        displayName             = 'Task group: Reportar-resultado-HU'
        timeoutInMinutes        = 0
        retryCountOnTaskFailure = 0
        condition               = $Condition
        task                    = [ordered]@{ id = $TaskGroupId; versionSpec = '1.*'; definitionType = 'metaTask' }
        inputs                  = [ordered]@{}
    }
}

function New-AdoFileCreatorStep {
    param(
        [Parameter(Mandatory)] [string]$DisplayName,
        [Parameter(Mandatory)] [string]$FilePath,
        [Parameter(Mandatory)] [string]$FileContent,
        [Parameter(Mandatory)] [bool]$Enabled
    )
    return [ordered]@{
        environment         = [ordered]@{}
        enabled             = $Enabled
        continueOnError     = $false
        alwaysRun           = $false
        displayName         = $DisplayName
        timeoutInMinutes    = 0
        retryCountOnTaskFailure = 0
        condition           = 'succeeded()'
        task                = [ordered]@{ id = '1f81a8be-d8ce-497d-9791-190126f661e7'; versionSpec = '6.*'; definitionType = 'task' }
        inputs              = [ordered]@{
            filepath      = $FilePath
            filecontent   = $FileContent
            fileoverwrite = 'true'
            skipempty     = 'false'
            endWithNewLine = 'false'
            verbose       = 'false'
        }
    }
}

# Debe coincidir siempre con el task.id real del task "Replace Tokens"
# (extension de mercado qetza.replacetokens) -- confirmado 2026-09-07
# contra un GET fresco de Build 633 (Build-Buklo-logistics-web, unico
# Build real de esta org que ya lo tenia, agregado ahi via un
# update-build-definition posterior a su creacion, nunca por este
# generador -- ver New-AdoReplaceTokensStep mas abajo para el detalle
# completo del bug que esto corrige).
$script:AdoReplaceTokensTaskId = 'a8515ec8-7254-4ffd-912c-86772e2b5962'

function New-AdoReplaceTokensStep {
    <#
    Step 'Replace tokens' -- sustituye tokens con forma #{...}# dentro de
    un archivo YA VERSIONADO del repo (tipicamente el Dockerfile generico
    de la raiz que trae 'ARG APP_NAME=#{appname}#') ANTES de que
    Build-MultiStage lo use para construir la imagen Docker. Docker no
    entiende la sintaxis #{...}#: sin este step, el build recibe el
    literal sin resolver.

    BUG REAL confirmado 2026-09-07 (Build 634, Buklo-directory-web,
    primer Build real de esta app, fallo en su primera corrida real):
    `New-AdoBuildDefinitionPayload` nunca genero este step para NINGUNA
    app -- ni siquiera para las que ya lo necesitan hoy (toda la familia
    buklo-web: shell-web/hr-web/ontology-web/ticketing-web/logistics-web,
    que comparten el mismo Dockerfile generico con token #{appname}#).
    Confirmado comparando un GET fresco de Build 633 (logistics-web, SI
    lo tiene, con este contrato exacto de inputs) contra Build 634 recien
    creado (NO lo tiene) -- ambos generados por el mismo codigo de este
    archivo, la unica diferencia es que 633 lo recibio despues via un
    update-build-definition manual/ad-hoc que nunca se documento como fix
    de este generador. Este archivo es ese fix, para que ninguna app
    futura dependa de un parche posterior.

    Contrato de -Inputs confirmado EXACTO contra ese GET real de Build
    633 -- ningun valor default inventado.
    #>
    param(
        [string]$RootDirectory = '.',
        [string]$TargetFiles = 'Dockerfile'
    )
    return [ordered]@{
        environment             = [ordered]@{}
        enabled                 = $true
        continueOnError         = $false
        alwaysRun               = $false
        displayName             = 'Replace tokens'
        timeoutInMinutes        = 0
        retryCountOnTaskFailure = 0
        condition               = 'succeeded()'
        task                    = [ordered]@{ id = $script:AdoReplaceTokensTaskId; versionSpec = '7.*'; definitionType = 'task' }
        inputs                  = [ordered]@{
            rootDirectory              = $RootDirectory
            targetFiles                = $TargetFiles
            tokenPattern               = 'default'
            tokenPrefix                = ''
            tokenSuffix                = ''
            caseInsensitivePaths       = 'true'
            includeDotPaths            = 'true'
            encoding                   = 'auto'
            writeBOM                  = 'false'
            additionalVariables        = ''
            variableSeparator          = '.'
            useAdditionalVariablesOnly = 'false'
            escapeType                 = 'auto'
            escapeChar                 = ''
            charsToEscape              = ''
            verbosity                  = 'info'
            missingVarAction           = 'none'
            defaultValue               = ''
            actionOnMissing            = 'warn'
            actionOnNoFiles            = 'ignore'
            enableRecursion            = 'false'
            enableTransforms           = 'false'
            transformPrefix            = '('
            transformSuffix            = ')'
            telemetryOptout            = 'false'
        }
    }
}

function New-AdoPowerShellTaskStep {
    <#
    Step generico para el task PowerShell@2 (id fijo
    'e213ff0f-5d5c-4791-802d-52ea3e7be1f1', versionSpec '2.*',
    definitionType 'task'). Contrato de inputs confirmado 2026-08-27
    contra un step REAL (Build 584, proyecto DevOps, step "Publicar
    shouldWait al job siguiente" -- ver New-AdoMergeBatchingBridgeScript/
    New-AdoMergeBatchingPhases mas arriba, que arma el mismo task a mano
    en modo 'inline'). Esta funcion generaliza ese mismo contrato para
    cualquier caso nuevo -- no reemplaza el uso a mano ya existente en
    New-AdoMergeBatchingPhases (no tocado).

    Soporta los 2 modos reales de este task, mutuamente excluyentes segun
    el propio contrato del task de Azure DevOps:
      -TargetType 'inline'   -> exige -Script no vacio, deja filePath=''.
      -TargetType 'filePath' -> exige -FilePath no vacio, deja script=''.
    Nunca adivina cual modo usar -- el llamador lo decide siempre.
    #>
    param(
        [Parameter(Mandatory)] [string]$DisplayName,
        [Parameter(Mandatory)] [ValidateSet('inline', 'filePath')] [string]$TargetType,
        [string]$Script = '',
        [string]$FilePath = '',
        [string]$Arguments = '',
        [bool]$Pwsh = $false,
        [string]$ErrorActionPreference = 'stop',
        [bool]$FailOnStderr = $false,
        [bool]$ShowWarnings = $false,
        [bool]$IgnoreLASTEXITCODE = $false,
        [string]$WorkingDirectory = '',
        [bool]$RunScriptInSeparateScope = $false,
        [bool]$Enabled = $true,
        [string]$Condition = 'succeeded()',
        [int]$TimeoutInMinutes = 0
    )

    if ($TargetType -eq 'inline' -and [string]::IsNullOrWhiteSpace($Script)) {
        throw "New-AdoPowerShellTaskStep: -TargetType 'inline' exige -Script no vacio."
    }
    if ($TargetType -eq 'filePath' -and [string]::IsNullOrWhiteSpace($FilePath)) {
        throw "New-AdoPowerShellTaskStep: -TargetType 'filePath' exige -FilePath no vacio."
    }

    return [ordered]@{
        environment             = [ordered]@{}
        enabled                 = $Enabled
        continueOnError         = $false
        alwaysRun               = $false
        displayName             = $DisplayName
        timeoutInMinutes        = $TimeoutInMinutes
        retryCountOnTaskFailure = 0
        condition                = $Condition
        task                    = [ordered]@{ id = 'e213ff0f-5d5c-4791-802d-52ea3e7be1f1'; versionSpec = '2.*'; definitionType = 'task' }
        inputs                  = [ordered]@{
            targetType               = $TargetType
            filePath                 = $FilePath
            arguments                = $Arguments
            script                   = $Script
            errorActionPreference    = $ErrorActionPreference
            failOnStderr             = $(if ($FailOnStderr) { 'true' } else { 'false' })
            showWarnings             = $(if ($ShowWarnings) { 'true' } else { 'false' })
            ignoreLASTEXITCODE       = $(if ($IgnoreLASTEXITCODE) { 'true' } else { 'false' })
            pwsh                     = $(if ($Pwsh) { 'true' } else { 'false' })
            workingDirectory         = $WorkingDirectory
            runScriptInSeparateScope = $(if ($RunScriptInSeparateScope) { 'true' } else { 'false' })
        }
    }
}

function New-AdoStandaloneBuildDefinitionPayload {
    <#
    Body para POST .../build/definitions de un Build clasico STANDALONE:
    sin familia AKS/DACPAC, sin manifiestos K8s, sin buildTaskGroup
    Docker, sin agrupacion de merges -- pensado para casos como una
    politica de "Build Validation" de Pull Request que dispara via Branch
    Policy (no via CI trigger). Funcion PARALELA a
    New-AdoBuildDefinitionPayload (familia AKS): no la reemplaza, no la
    modifica, no comparte ningun default especifico de AKS con ella salvo
    lo genuinamente reutilizable ($script:AdoStandardBuildOptions,
    fetchDepth/cleanOptions/etc. de repository.properties).

    Agregada 2026-08-27 (gap identificado armando
    Build-Validation-buklo-backend, ver memoria de agente
    ado-pipeline-builder: "Gap real de capacidad").

    $Steps es una lista YA ARMADA por el llamador (tipicamente via
    New-AdoFileCreatorStep / New-AdoPowerShellTaskStep) -- esta funcion
    nunca decide que steps van, solo los envuelve en un unico phase/agent
    job. Nunca vacia.

    Sin CI trigger por defecto (-CiBranchFilters omitido/vacio): el Build
    queda con triggers=[] (ningun trigger continuousIntegration) -- valido
    para un Build pensado para dispararse SOLO via una policy de Build
    Validation de PR, nunca por push directo. Pasar -CiBranchFilters
    explicito si algun caso futuro SI necesita CI ademas de la policy.

    $Project/$RepoId/$RepoName/$DefaultBranch nunca se asumen: deben venir
    resueltos por el llamador contra el inventario REAL del proyecto
    exacto donde vive el repo -- puede ser distinto del proyecto de
    pipelines 'DevOps' (ver 'Gap real de capacidad' en la memoria del
    agente: el proyecto de pipelines de ESTE Build puede no ser 'DevOps'
    en absoluto).

    -QueueId queda deliberadamente SIN valor por defecto (a diferencia de
    $script:AdoDefaultBuildQueue, que fija id=127): ese id es una "agent
    queue" resuelta POR PROYECTO en Azure DevOps (distinto del id del pool
    organizacional), y 127 esta confirmado real y funcional solo para el
    proyecto 'DevOps' (Build-portal-cmdb, 578) -- nunca asumido valido en
    otro proyecto sin confirmarlo primero contra un Build real de ESE
    proyecto. Sin -QueueId, el objeto 'queue' se arma solo con 'pool'
    (sin la clave 'id'), dejando que Azure DevOps resuelva/cree la
    asignacion de queue del proyecto -- comportamiento documentado como
    no verificado en produccion todavia (ver referencia de la skill),
    nunca ocultado.
    #>
    param(
        [Parameter(Mandatory)] [string]$Project,
        [Parameter(Mandatory)] [string]$Name,
        [string]$FolderPath = '\\',
        [Parameter(Mandatory)] [string]$RepoId,
        [Parameter(Mandatory)] [string]$RepoName,
        [string]$RepoProject,
        [Parameter(Mandatory)] [string]$DefaultBranch,
        # NO Mandatory a proposito (mismo motivo documentado junto a
        # -Environments en New-AdoReleaseDefinitionPayload): PowerShell
        # rechaza un [array] MANDATORY que llega vacio (Count=0) como si
        # no se hubiera pasado nada, antes de que el cuerpo de la funcion
        # pueda validarlo con su propio mensaje. El chequeo de "vacio" se
        # hace a mano mas abajo.
        [array]$Steps,
        [string]$FetchDepth = '0',
        [string[]]$CiBranchFilters = @(),
        [bool]$CiBatchChangesEnabled = $false,
        [string]$AgentSpecificationIdentifier = 'ubuntu latest',
        [int]$AgentPoolId = 9,
        [string]$AgentPoolName = 'Azure Pipelines',
        [Nullable[int]]$QueueId,
        [int]$JobTimeoutInMinutes = 60,
        [int]$JobCancelTimeoutInMinutes = 5
    )

    if ($null -eq $Steps -or @($Steps).Count -eq 0) {
        throw "New-AdoStandaloneBuildDefinitionPayload: -Steps no puede estar vacio."
    }
    if ([string]::IsNullOrWhiteSpace($Project) -or [string]::IsNullOrWhiteSpace($Name) -or [string]::IsNullOrWhiteSpace($RepoId) -or [string]::IsNullOrWhiteSpace($RepoName) -or [string]::IsNullOrWhiteSpace($DefaultBranch)) {
        throw "New-AdoStandaloneBuildDefinitionPayload: -Project/-Name/-RepoId/-RepoName/-DefaultBranch son obligatorios y no se infieren."
    }

    $effectiveRepoProject = if ([string]::IsNullOrWhiteSpace($RepoProject)) { $Project } else { $RepoProject }

    $triggers = @()
    if (@($CiBranchFilters).Count -gt 0) {
        $branchFilters = @($CiBranchFilters | ForEach-Object { "+refs/heads/$_" })
        $triggers = @(
            [ordered]@{
                branchFilters                = $branchFilters
                pathFilters                  = @()
                batchChanges                 = $CiBatchChangesEnabled
                maxConcurrentBuildsPerBranch  = 1
                pollingInterval               = 0
                triggerType                   = 'continuousIntegration'
            }
        )
    }

    $pool = [ordered]@{ id = $AgentPoolId; name = $AgentPoolName }
    $queue = if ($QueueId) { [ordered]@{ id = $QueueId; pool = $pool } } else { [ordered]@{ pool = $pool } }

    return [ordered]@{
        options                   = $script:AdoStandardBuildOptions
        triggers                  = @($triggers)
        variables                 = [ordered]@{}
        properties                = [ordered]@{}
        tags                      = @()
        buildNumberFormat         = '$(date:yyyyMMdd)$(rev:.r)'
        jobAuthorizationScope     = 'projectCollection'
        jobTimeoutInMinutes       = $JobTimeoutInMinutes
        jobCancelTimeoutInMinutes = $JobCancelTimeoutInMinutes
        process                   = [ordered]@{
            phases = @(
                [ordered]@{
                    steps                 = @($Steps)
                    name                  = 'Agent job 1'
                    refName               = 'Job_1'
                    condition             = 'succeeded()'
                    target                = [ordered]@{
                        executionOptions              = [ordered]@{ type = 0 }
                        allowScriptsAuthAccessOption  = $false
                        type                           = 1
                    }
                    jobAuthorizationScope = 'projectCollection'
                }
            )
            target = [ordered]@{ agentSpecification = [ordered]@{ identifier = $AgentSpecificationIdentifier } }
            type   = 1
        }
        repository                = [ordered]@{
            properties = [ordered]@{
                labelSources             = '0'
                labelSourcesFormat       = '$(build.buildNumber)'
                reportBuildStatus        = 'true'
                fetchDepth               = $FetchDepth
                cleanOptions             = '0'
                gitLfsSupport            = 'false'
                skipSyncSource           = 'false'
                checkoutNestedSubmodules = 'false'
            }
            id                 = $RepoId
            type               = 'TfsGit'
            name               = $RepoName
            url                = "https://dev.azure.com/Shared-Service-GM/$effectiveRepoProject/_git/$RepoName"
            defaultBranch      = "refs/heads/$DefaultBranch"
            clean              = 'false'
            checkoutSubmodules = $false
        }
        processParameters         = [ordered]@{}
        quality                   = 'definition'
        queue                     = $queue
        name                      = $Name
        path                      = $FolderPath
        type                      = 'build'
        queueStatus               = 'enabled'
    }
}

function ConvertFrom-AdoStepsSpecFile {
    <#
    Parsea el JSON DECLARATIVO de -StepsSpecPath (array de entradas
    { kind: 'FileCreator'|'PowerShellTask', ... }) y devuelve el array de
    steps ya armados con New-AdoFileCreatorStep/New-AdoPowerShellTaskStep,
    listos para -Steps de New-AdoStandaloneBuildDefinitionPayload.

    Factorizada 2026-09-01 desde el bloque inline 'StandaloneBuild' de
    New-AdoClassicCreatePlan.ps1 -- unica fuente de verdad de este parseo
    ahora, usada tanto en tiempo de CREACION (New-AdoClassicCreatePlan.ps1,
    para calcular el bodyHash inicial) como, indirectamente, en tiempo de
    APLICACION: Invoke-AdoApplyPhases NO vuelve a llamar esta funcion --
    usa los steps YA RESUELTOS que New-AdoClassicCreatePlan.ps1 guardo en
    plan.dependencies.standaloneBuild.steps, precisamente para que la
    reconstruccion en Apply sea determinista y no dependa de que un
    archivo -StepsSpecPath externo (ni sus fileContentPath referenciados)
    sigan existiendo o sin cambios en disco al momento de aplicar.

    NUNCA envolver "Get-Content -Raw | ConvertFrom-Json" directamente en
    @(...) (bug real encontrado 2026-08-27, ver el mismo fix en el branch
    'Release' de New-AdoClassicCreatePlan.ps1): con 2+ elementos produce
    un array ANIDADO de 1 elemento en vez de un array plano de N --
    silencioso, nunca lanza. Fix: asignar primero SIN @(), reenvolver
    despues en un statement aparte.
    #>
    param([Parameter(Mandatory)] [string]$StepsSpecPath)

    if ([string]::IsNullOrWhiteSpace($StepsSpecPath) -or -not (Test-Path -LiteralPath $StepsSpecPath -PathType Leaf)) {
        throw "ConvertFrom-AdoStepsSpecFile: no existe -StepsSpecPath ('$StepsSpecPath')."
    }

    $stepsSpecParsed = Get-Content -LiteralPath $StepsSpecPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $stepsSpecRaw = @($stepsSpecParsed)
    if ($stepsSpecRaw.Count -eq 0) {
        throw "ConvertFrom-AdoStepsSpecFile: -StepsSpecPath ('$StepsSpecPath') no tiene ninguna entrada -- se necesita al menos 1 step."
    }

    $steps = [System.Collections.Generic.List[object]]::new()
    foreach ($stepSpec in $stepsSpecRaw) {
        $stepKind = [string]$stepSpec.kind
        switch ($stepKind) {
            'FileCreator' {
                foreach ($req in @('displayName', 'filePath')) {
                    if (-not $stepSpec.PSObject.Properties[$req] -or [string]::IsNullOrWhiteSpace([string]$stepSpec.$req)) {
                        throw "ConvertFrom-AdoStepsSpecFile: una entrada 'FileCreator' de -StepsSpecPath no tiene '$req'."
                    }
                }
                # $stepSpec.fileContent (inline, dentro del JSON) o
                # $stepSpec.fileContentPath (ruta a un archivo de texto
                # aparte, leido tal cual) -- exactamente uno de los 2.
                # fileContentPath evita tener que escapar a mano un
                # script multilinea con comillas dentro de JSON. El
                # RESULTADO ya resuelto (nunca la ruta) es lo que termina
                # en el step devuelto -- por eso Invoke-AdoApplyPhases no
                # necesita volver a leer ningun archivo externo.
                $hasInlineContent = $stepSpec.PSObject.Properties['fileContent'] -and -not [string]::IsNullOrWhiteSpace([string]$stepSpec.fileContent)
                $hasContentPath = $stepSpec.PSObject.Properties['fileContentPath'] -and -not [string]::IsNullOrWhiteSpace([string]$stepSpec.fileContentPath)
                if ($hasInlineContent -and $hasContentPath) {
                    throw "ConvertFrom-AdoStepsSpecFile: una entrada 'FileCreator' de -StepsSpecPath tiene 'fileContent' Y 'fileContentPath' -- solo uno de los 2."
                }
                if (-not $hasInlineContent -and -not $hasContentPath) {
                    throw "ConvertFrom-AdoStepsSpecFile: una entrada 'FileCreator' de -StepsSpecPath no tiene 'fileContent' ni 'fileContentPath'."
                }
                $resolvedFileContent = if ($hasContentPath) {
                    $contentPath = [string]$stepSpec.fileContentPath
                    if (-not (Test-Path -LiteralPath $contentPath -PathType Leaf)) {
                        throw "ConvertFrom-AdoStepsSpecFile: 'fileContentPath' ('$contentPath') de una entrada 'FileCreator' no existe."
                    }
                    Get-Content -LiteralPath $contentPath -Raw -Encoding UTF8
                }
                else {
                    [string]$stepSpec.fileContent
                }
                $enabledValue = $true
                if ($stepSpec.PSObject.Properties['enabled']) { $enabledValue = [bool]$stepSpec.enabled }
                $steps.Add((New-AdoFileCreatorStep -DisplayName ([string]$stepSpec.displayName) -FilePath ([string]$stepSpec.filePath) -FileContent $resolvedFileContent -Enabled $enabledValue))
            }
            'PowerShellTask' {
                foreach ($req in @('displayName', 'targetType')) {
                    if (-not $stepSpec.PSObject.Properties[$req] -or [string]::IsNullOrWhiteSpace([string]$stepSpec.$req)) {
                        throw "ConvertFrom-AdoStepsSpecFile: una entrada 'PowerShellTask' de -StepsSpecPath no tiene '$req'."
                    }
                }
                $psParams = @{
                    DisplayName = [string]$stepSpec.displayName
                    TargetType  = [string]$stepSpec.targetType
                }
                foreach ($optionalString in @('script', 'filePath', 'arguments', 'errorActionPreference', 'workingDirectory', 'condition')) {
                    if ($stepSpec.PSObject.Properties[$optionalString] -and -not [string]::IsNullOrWhiteSpace([string]$stepSpec.$optionalString)) {
                        $psParamName = (Get-Culture).TextInfo.ToTitleCase($optionalString)
                        if ($optionalString -eq 'errorActionPreference') { $psParamName = 'ErrorActionPreference' }
                        $psParams[$psParamName] = [string]$stepSpec.$optionalString
                    }
                }
                foreach ($optionalBool in @('pwsh', 'failOnStderr', 'showWarnings', 'ignoreLASTEXITCODE', 'runScriptInSeparateScope', 'enabled')) {
                    if ($stepSpec.PSObject.Properties[$optionalBool]) {
                        $psParamName = switch ($optionalBool) {
                            'pwsh' { 'Pwsh' }
                            'failOnStderr' { 'FailOnStderr' }
                            'showWarnings' { 'ShowWarnings' }
                            'ignoreLASTEXITCODE' { 'IgnoreLASTEXITCODE' }
                            'runScriptInSeparateScope' { 'RunScriptInSeparateScope' }
                            'enabled' { 'Enabled' }
                        }
                        $psParams[$psParamName] = [bool]$stepSpec.$optionalBool
                    }
                }
                if ($stepSpec.PSObject.Properties['timeoutInMinutes']) { $psParams['TimeoutInMinutes'] = [int]$stepSpec.timeoutInMinutes }
                $steps.Add((New-AdoPowerShellTaskStep @psParams))
            }
            default {
                throw "ConvertFrom-AdoStepsSpecFile: -StepsSpecPath tiene una entrada con kind='$stepKind' desconocido -- solo se soportan 'FileCreator' y 'PowerShellTask'."
            }
        }
    }

    return @($steps)
}

function New-AdoBuildDefinitionPayload {
    <#
    Body para POST .../build/definitions. $DeploymentManifests debe traer
    EXACTAMENTE 3 keys (dev/uat/prod) con el filecontent real de cada
    manifiesto -- nunca se inventa ni se reusa el de otra app. El step
    "File Creator deployment-prod.yml" se crea con enabled=$false (mismo
    patron real observado en Build-portal-cmdb: Produccion se prepara
    pero no se activa hasta una aprobacion aparte).

    $Plan.dependencies.buildTaskGroup.id/.revision deben venir YA
    resueltos por Test-AdoClassicPlan.ps1 contra inventario en vivo --
    esta funcion lanza si faltan, nunca asume un id.

    Agrupacion de merges ("gana el mas nuevo"): SOLO se activa si
    $Plan.mergeBatching.enabled -eq $true (el plan lo trae explicito,
    nunca un default silencioso aca -- el default "on" de la convencion
    org-wide vive en New-AdoClassicAksPlan.ps1, que es quien arma el
    plan). Cuando esta activo, $Plan.dependencies.evaluarVentanaTaskGroup.id,
    .ganaElMasNuevoTaskGroup.id y .reportarResultadoTaskGroup.id deben
    venir YA resueltos (mismo patron que buildTaskGroup). Ver
    references/ado-classic-payload-templates.md § "Convencion org-wide:
    fases de agrupacion de merges" para el checklist completo de 8 piezas
    que esto reproduce.

    Contrato del step del task group de build (displayName dinamico segun
    $Plan.dependencies.buildTaskGroup.name -- nunca hardcodeado): por
    defecto arma el contrato de `Build-MultiStage` (ambiente/
    ambienteOverride/conexcontainerregistries/image/rutadockerfile/tag),
    el ESTANDAR de la org confirmado 2026-08-25 (reemplaza al task group
    `Build`, mas viejo, cuyo contrato usaba `servicesname` en vez de
    `image` y no tenia `ambienteOverride`). Pasar -BuildTaskGroupInputs
    (hashtable) para usar otro contrato explicito (ej. si algun pipeline
    puntual sigue en `Build`) -- esta funcion NUNCA adivina el contrato
    por el nombre del task group, siempre hay un default explicito y
    documentado, sobreescribible.

    $Plan.buildVariables.image debe venir con el guion final ya incluido
    (ej. "mi-app-web-") -- Build-MultiStage arma el nombre del repositorio
    Docker concatenando $(image)$(ambiente) SIN separador (confirmado
    2026-08-25 contra Build-administracion-proyectos-web real); el mismo
    valor de `image` se usa igual en el token #{image}# de los manifiestos
    K8s (ver references/ado-classic-payload-templates.md § "Convencion
    org-wide: plantilla de manifiestos K8s"), asi que ya era una
    convencion existente, no una exigencia nueva de este cambio.
    #>
    param(
        [Parameter(Mandatory)] $Plan,
        [Parameter(Mandatory)] [hashtable]$DeploymentManifests,
        [hashtable]$BuildTaskGroupInputs
    )

    foreach ($envKey in @('dev', 'uat', 'prod')) {
        if (-not $DeploymentManifests.ContainsKey($envKey) -or [string]::IsNullOrWhiteSpace($DeploymentManifests[$envKey])) {
            throw "New-AdoBuildDefinitionPayload: falta DeploymentManifests['$envKey'] (contenido real del manifiesto, nunca se inventa)."
        }
    }

    if (-not $Plan.dependencies.buildTaskGroup -or -not $Plan.dependencies.buildTaskGroup.id) {
        throw "New-AdoBuildDefinitionPayload: plan.dependencies.buildTaskGroup.id no esta resuelto. Correr Test-AdoClassicPlan.ps1 con -InventoryPath primero."
    }
    if (-not $Plan.repo -or -not $Plan.repo.id) {
        throw "New-AdoBuildDefinitionPayload: plan.repo.id no esta resuelto. Correr Test-AdoClassicPlan.ps1 con -InventoryPath primero."
    }
    if (-not $Plan.repo.ciBranchFilters -or @($Plan.repo.ciBranchFilters).Count -eq 0) {
        throw "New-AdoBuildDefinitionPayload: falta plan.repo.ciBranchFilters (las ramas que disparan CI)."
    }

    $mergeBatchingEnabled = $false
    if ($Plan.PSObject.Properties['mergeBatching'] -and $Plan.mergeBatching -and $Plan.mergeBatching.PSObject.Properties['enabled']) {
        $mergeBatchingEnabled = [bool]$Plan.mergeBatching.enabled
    }
    $batchWindowMinutes = '5'
    if ($mergeBatchingEnabled -and $Plan.mergeBatching.PSObject.Properties['windowMinutes'] -and -not [string]::IsNullOrWhiteSpace([string]$Plan.mergeBatching.windowMinutes)) {
        $batchWindowMinutes = [string]$Plan.mergeBatching.windowMinutes
    }

    if ($mergeBatchingEnabled) {
        foreach ($dep in @('evaluarVentanaTaskGroup', 'ganaElMasNuevoTaskGroup', 'reportarResultadoTaskGroup')) {
            if (-not $Plan.dependencies.$dep -or -not $Plan.dependencies.$dep.id) {
                throw "New-AdoBuildDefinitionPayload: plan.mergeBatching.enabled=true pero plan.dependencies.$dep.id no esta resuelto. Correr Test-AdoClassicPlan.ps1 con -InventoryPath primero."
            }
        }
    }

    $branchFilters = @($Plan.repo.ciBranchFilters | ForEach-Object { "+refs/heads/$_" })
    $batchChanges = [bool]$Plan.repo.ciBatchChangesEnabled

    # image: contrato VIGENTE de Build-MultiStage (ver
    # ado-classic-payload-templates.md). Debe venir con el guion final ya
    # incluido -- ver docstring de la funcion. Nunca se inventa ni se
    # deriva de otro campo.
    $imageValue = [string]$Plan.buildVariables.image
    if ([string]::IsNullOrWhiteSpace($imageValue)) {
        throw "New-AdoBuildDefinitionPayload: falta plan.buildVariables.image (requerido por el contrato de Build-MultiStage; debe terminar en guion, ver docstring de esta funcion)."
    }

    $buildVariables = [ordered]@{
        ambiente                 = [ordered]@{ value = [string]$Plan.variableGroup.keys.ambiente }
        conexcontainerregistries = [ordered]@{ value = [string]$Plan.buildVariables.conexcontainerregistries }
        image                    = [ordered]@{ value = $imageValue }
        rutadockerfile           = [ordered]@{ value = [string]$Plan.buildVariables.rutadockerfile }
        'system.debug'           = [ordered]@{ value = [string]$Plan.buildVariables.'system.debug'; allowOverride = $true }
        tag                      = [ordered]@{ value = [string]$Plan.buildVariables.tag }
    }
    # BUG REAL corregido 2026-09-07 (Build 634, Buklo-directory-web): esta
    # funcion nunca copiaba 'appname' de $Plan.buildVariables hacia el
    # 'variables' real del body -- omision incondicional, sin relacion con
    # rutadockerfile, que afectaba a CUALQUIER app (confirmado comparando
    # Build 633 real -- que si tiene 'appname', pero solo porque se le
    # agrego despues via un update-build-definition manual nunca
    # documentado como fix de este generador -- contra Build 634 recien
    # creado por este mismo codigo, sin 'appname'). Soft-optional (solo se
    # agrega si el plan lo trae) para no romper un caller hipotetico que
    # arme $Plan.buildVariables a mano sin esta clave.
    if ($Plan.buildVariables.PSObject.Properties['appname'] -and -not [string]::IsNullOrWhiteSpace([string]$Plan.buildVariables.appname)) {
        $buildVariables['appname'] = [ordered]@{ value = [string]$Plan.buildVariables.appname }
    }
    if ($mergeBatchingEnabled) {
        $buildVariables['BATCH_WINDOW_MINUTES'] = [ordered]@{ value = $batchWindowMinutes }
        $buildVariables['SUPERSEDE_REASONS'] = [ordered]@{ value = 'IndividualCI,BatchedCI' }
        $buildVariables['BATCH_WAIT_REASONS'] = [ordered]@{ value = 'IndividualCI,BatchedCI' }
        $buildVariables['BATCH_PR_TITLE_MARKER'] = [ordered]@{ value = '[AUTO]' }
    }

    # Precedencia de los inputs del step del task group de build (fix 2026-10-29
    # del gap "helper a medias"): el body del Build se RECONSTRUYE en Apply
    # (Invoke-AdoApplyPhases llama a esta funcion -Plan $Plan SIN
    # -BuildTaskGroupInputs), asi que un -BuildTaskGroupInputs pasado SOLO al
    # generar se perderia en Apply y el Build se crearia con el contrato default
    # (sin 'arguments' -> en BDIP worker, SIN --target worker: fallo silencioso).
    # Fix: cuando se pasa -BuildTaskGroupInputs, se PERSISTE en
    # $Plan.dependencies.buildTaskGroup.inputs (queda en el plan en disco), y
    # esta funcion lee, por orden: (1) el parametro explicito, (2) lo persistido
    # en el plan, (3) el contrato default de 6 inputs de Build-MultiStage. Asi el
    # body que se hashea al generar y el que se reconstruye en Apply son identicos.
    $persistedBuildTgInputs = $null
    if ($Plan.PSObject.Properties['dependencies'] -and $Plan.dependencies -and `
        $Plan.dependencies.PSObject.Properties['buildTaskGroup'] -and $Plan.dependencies.buildTaskGroup -and `
        $Plan.dependencies.buildTaskGroup.PSObject.Properties['inputs'] -and $Plan.dependencies.buildTaskGroup.inputs) {
        $persistedBuildTgInputs = $Plan.dependencies.buildTaskGroup.inputs
    }
    $effectiveBuildTaskGroupInputs = if ($BuildTaskGroupInputs) {
        # Persistir en el plan para que el Apply (que reconstruye el body sin
        # el parametro) use EXACTAMENTE los mismos inputs -> bodyHash coincide.
        # Add-Member -Force (no Set-AdoPSObjectProperty: esa funcion vive en
        # New-AdoClassicUpdatePayload.ps1, que el CLI de create NO dot-sourcea).
        $Plan.dependencies.buildTaskGroup | Add-Member -NotePropertyName 'inputs' -NotePropertyValue $BuildTaskGroupInputs -Force
        $BuildTaskGroupInputs
    }
    elseif ($persistedBuildTgInputs) {
        $persistedBuildTgInputs
    }
    else {
        [ordered]@{
            ambiente                 = '$(ambiente)'
            ambienteOverride         = 'auto'
            conexcontainerregistries = '$(conexcontainerregistries)'
            image                    = '$(image)'
            rutadockerfile           = '$(rutadockerfile)'
            tag                      = '$(tag)'
        }
    }

    $steps = [System.Collections.Generic.List[object]]::new()
    if ($mergeBatchingEnabled) {
        $steps.Add((New-AdoGanaElMasNuevoStep -TaskGroupId ([string]$Plan.dependencies.ganaElMasNuevoTaskGroup.id)))
    }
    # BUG REAL corregido 2026-09-07 (Build 634, Buklo-directory-web): esta
    # funcion nunca generaba el step 'Replace tokens' para NINGUNA app --
    # sin el, un Dockerfile YA VERSIONADO en el repo (no generado por File
    # Creator) que use '#{appname}#'/otros tokens '#{...}#' llega intacto
    # a Build-MultiStage, y Docker recibe el literal sin resolver (falla
    # el build real). Se agrega SOLO cuando el Dockerfile no fue generado
    # por File Creator (generatedByFileCreator=false, ver plan.dockerfile
    # -- el caso de un Dockerfile generado inline ya trae sus valores
    # reales embebidos, sin tokens que resolver). Posicion confirmada
    # contra un GET real de Build 633 (logistics-web, unica app que ya lo
    # tenia, agregado ahi por un update posterior nunca documentado):
    # inmediatamente despues de 'Gana-el-mas-nuevo' (o como primer step si
    # la agrupacion de merges esta deshabilitada), SIEMPRE antes de los
    # File Creator y de Build-MultiStage.
    # Defensivo a proposito (nunca "-not [bool]$Plan.dockerfile.generatedByFileCreator"
    # a secas): un plan viejo/fixture de prueba que no trae 'dockerfile' en
    # absoluto (ninguno de los que existian antes de este cambio lo trae)
    # no debe activar este step nuevo por accidente -- solo se activa
    # cuando el plan trae EXPLICITAMENTE generatedByFileCreator=false (el
    # unico valor que New-AdoClassicAksPlan.ps1 escribe siempre, nunca lo
    # omite, para cualquier plan generado de verdad).
    $usesVersionedRepoDockerfile = $false
    if ($Plan.PSObject.Properties['dockerfile'] -and $Plan.dockerfile -and $Plan.dockerfile.PSObject.Properties['generatedByFileCreator']) {
        $usesVersionedRepoDockerfile = -not [bool]$Plan.dockerfile.generatedByFileCreator
    }
    # 2026-11-24 Dr.Max-Project / Optica-Ecosystem: Dockerfiles versionados
    # SIN tokens '#{...}#' -- Replace tokens sobra (Builds 713/714/715).
    # Solo agregar el step si el plan lo pide EXPLICITO (requiresReplaceTokens)
    # o si el repo NO es Dr.Max-Project y el Dockerfile viene del repo.
    # Buklo con '#{appname}#' en Dockerfile: setear dockerfile.requiresReplaceTokens=true
    # o dejar repo fuera de Dr.Max-Project (comportamiento historico).
    $requiresReplaceTokens = $false
    if ($Plan.PSObject.Properties['dockerfile'] -and $Plan.dockerfile -and $Plan.dockerfile.PSObject.Properties['requiresReplaceTokens']) {
        $requiresReplaceTokens = [bool]$Plan.dockerfile.requiresReplaceTokens
    }
    $repoProjectForReplace = if ($Plan.repo -and $Plan.repo.project) { [string]$Plan.repo.project } else { '' }
    $skipReplaceTokensForDrMax = ($repoProjectForReplace -eq 'Dr.Max-Project') -and (-not $requiresReplaceTokens)
    if ($usesVersionedRepoDockerfile -and -not $skipReplaceTokensForDrMax) {
        if ($requiresReplaceTokens -or ($repoProjectForReplace -ne 'Dr.Max-Project')) {
            $steps.Add((New-AdoReplaceTokensStep))
        }
    }
    $steps.Add((New-AdoFileCreatorStep -DisplayName 'File Creator deployment-dev.yml' -FilePath './deployment-dev.yml' -FileContent $DeploymentManifests['dev'] -Enabled $true))
    $steps.Add((New-AdoFileCreatorStep -DisplayName 'File Creator deployment-uat.yml' -FilePath './deployment-uat.yml' -FileContent $DeploymentManifests['uat'] -Enabled $true))
    $steps.Add((New-AdoFileCreatorStep -DisplayName 'File Creator deployment-prod.yml' -FilePath './deployment-prod.yml' -FileContent $DeploymentManifests['prod'] -Enabled $false))
    $steps.Add([ordered]@{
        environment         = [ordered]@{}
        enabled             = $true
        continueOnError     = $true
        alwaysRun           = $true
        displayName         = "Task group: $([string]$Plan.dependencies.buildTaskGroup.name)"
        timeoutInMinutes    = 0
        retryCountOnTaskFailure = 0
        condition           = 'succeededOrFailed()'
        task                = [ordered]@{ id = [string]$Plan.dependencies.buildTaskGroup.id; versionSpec = '1.*'; definitionType = 'metaTask' }
        inputs              = $effectiveBuildTaskGroupInputs
    })
    if ($mergeBatchingEnabled) {
        $steps.Add((New-AdoReportarResultadoHuBuildStep -TaskGroupId ([string]$Plan.dependencies.reportarResultadoTaskGroup.id)))
    }

    $repoProject = if ($Plan.repo.project) { [string]$Plan.repo.project } else { [string]$Plan.project }
    $defaultBranch = if (@($Plan.repo.ciBranchFilters).Count -gt 0) { "refs/heads/$($Plan.repo.ciBranchFilters[0])" } else { "refs/heads/$($Plan.repo.prodBranch)" }

    $queue = $script:AdoDefaultBuildQueue
    if ($Plan.dependencies.agentPool -and $Plan.dependencies.agentPool.id) {
        $queue = [ordered]@{ id = $script:AdoDefaultBuildQueue.id; pool = [ordered]@{ id = $Plan.dependencies.agentPool.id; name = [string]$Plan.dependencies.agentPool.name } }
    }

    $mainPhase = [ordered]@{
        steps               = @($steps)
        name                = 'Agent job 1'
        refName             = 'Job_1'
        condition           = 'succeeded()'
        target              = [ordered]@{
            executionOptions              = [ordered]@{ type = 0 }
            allowScriptsAuthAccessOption  = $mergeBatchingEnabled
            type                           = 1
        }
        jobAuthorizationScope = 'projectCollection'
    }

    $phases = [System.Collections.Generic.List[object]]::new()
    if ($mergeBatchingEnabled) {
        foreach ($p in (New-AdoMergeBatchingPhases -EvaluarVentanaTaskGroupId ([string]$Plan.dependencies.evaluarVentanaTaskGroup.id))) {
            $phases.Add($p)
        }
        # ARRAY, mismo motivo/bug documentado junto a New-AdoMergeBatchingPhases
        # mas arriba -- shape confirmado contra Build 552 real.
        $mainPhase['dependencies'] = @([ordered]@{ scope = 'Batch_Window'; event = $null })
        $mainPhase['condition'] = "and(in(dependencies.Batch_Window.result, 'Succeeded', 'SucceededWithIssues', 'Skipped'), not(canceled()))"
    }
    $phases.Add($mainPhase)

    return [ordered]@{
        options              = $script:AdoStandardBuildOptions
        triggers             = @(
            [ordered]@{
                branchFilters                = $branchFilters
                # coma unaria: fuerza un ARRAY JSON aunque haya un solo path
                # filter -- sin ella, ConvertTo-Json desenvuelve el array de 1
                # elemento a string escalar y Azure DevOps lo descarta (Build
                # queda con pathFilters=[]). Bug real observado en Build 638.
                pathFilters                  = $(if ($Plan.repo.pathFilter) { ,@([string]$Plan.repo.pathFilter) } else { @() })
                batchChanges                 = $batchChanges
                maxConcurrentBuildsPerBranch  = $(if ($mergeBatchingEnabled) { 5 } else { 1 })
                pollingInterval               = 0
                triggerType                   = 'continuousIntegration'
            }
        )
        variables            = $buildVariables
        properties           = [ordered]@{}
        tags                 = @()
        buildNumberFormat    = '$(date:yyyyMMdd)$(rev:.r)'
        jobAuthorizationScope = 'projectCollection'
        jobTimeoutInMinutes  = 60
        jobCancelTimeoutInMinutes = 5
        process              = [ordered]@{
            phases = @($phases)
            target = [ordered]@{ agentSpecification = [ordered]@{ identifier = 'ubuntu latest' } }
            type   = 1
        }
        repository           = [ordered]@{
            properties = [ordered]@{
                labelSources             = '0'
                labelSourcesFormat       = '$(build.buildNumber)'
                reportBuildStatus        = 'true'
                fetchDepth               = '0'
                cleanOptions             = '0'
                gitLfsSupport            = 'false'
                skipSyncSource           = 'false'
                checkoutNestedSubmodules = 'false'
            }
            id                 = [string]$Plan.repo.id
            type               = 'TfsGit'
            name               = [string]$Plan.repo.name
            url                = "https://dev.azure.com/Shared-Service-GM/$repoProject/_git/$($Plan.repo.name)"
            defaultBranch      = $defaultBranch
            clean              = 'false'
            checkoutSubmodules = $false
        }
        processParameters    = [ordered]@{}
        quality              = 'definition'
        queue                = $queue
        name                 = [string]$Plan.names.build
        path                 = [string]$Plan.names.folder
        type                 = 'build'
        queueStatus          = 'enabled'
    }
}

function New-AdoReleaseEnvironmentEntry {
    <#
    Arma UNA entrada del array -Environments que necesita
    New-AdoReleaseDefinitionPayload -- la pieza que hoy se ensamblaba a
    mano cada vez que se armaba un Release de varios ambientes
    (Desarrollo/UAT/Produccion). No reemplaza a New-AdoClassicAksPlan.ps1
    (que sigue armando UN plan por ambiente, sin cambios) ni a
    New-AdoReleaseDefinitionPayload (que sigue esperando exactamente el
    mismo array de hashtables que siempre) -- esta funcion solo evita
    tener que recordar/escribir a mano el contrato de
    deployTaskGroupInputs de cada task group de deploy conocido, y
    reduce el ensamblado de 3 ambientes a 3 llamadas + un array literal.

    $DeployTaskGroupName decide el contrato de $deployTaskGroupInputs --
    confirmado contra definiciones reales (Deployment-Azur-Aks-v3 en
    Release 381/360 Produccion; Deployment-MultiStage-Cluster-Desarrollo
    en Release 381/360 Desarrollo/UAT), ver
    references/ado-classic-payload-templates.md. Un nombre de task group
    de deploy que no sea uno de estos dos NUNCA se adivina -- lanza
    explicito para que el llamador arme $DeployTaskGroupInputsOverride a
    mano en ese caso (parametro de escape, nunca usado por los 2
    contratos conocidos).

    $VariableGroupId y $DeployTaskGroupId deben venir YA resueltos (el
    primero, el id real de una Variable Group YA CREADA; el segundo,
    resuelto por Test-AdoClassicPlan.ps1 contra inventario en vivo) --
    esta funcion nunca los inventa ni los resuelve por si sola.
    #>
    param(
        [Parameter(Mandatory)] [string]$Stage,
        [Parameter(Mandatory)] [int]$VariableGroupId,
        [Parameter(Mandatory)] [string]$ArtifactFilterBranch,
        [Parameter(Mandatory)] [string]$DeployTaskGroupName,
        [Parameter(Mandatory)] [string]$DeployTaskGroupId,
        [bool]$ApprovalRequired = $false,
        [string]$ReportarResultadoTaskGroupId,
        [hashtable]$StageVariables,
        # Approver de la aprobacion MANUAL (fix 2026-10-29): solo aplica
        # con -ApprovalRequired. -ApproverId es el id de grupo/usuario
        # (p.ej. 'Release Executers'); -ReleaseCreatorCanBeApprover por
        # defecto $false. Se emiten en la entrada y los consume
        # New-AdoReleaseDefinitionPayload.
        [string]$ApproverId,
        [bool]$ReleaseCreatorCanBeApprover = $false,
        # Campos usados segun el contrato de $DeployTaskGroupName (ver
        # tabla de arriba) -- pasar solo los que ese contrato pide,
        # el resto se ignora si no aplica.
        [string]$Ambiente,
        [string]$Namespace,
        [string]$Pipeline,
        [string]$AksClusterName,
        [string]$AksResourceGroup,
        [string]$ContainerRegistries,
        [string]$Image,
        [string]$ServicesName,
        [string]$Tag = '$(Build.BuildId)',
        # Escape hatch: si $DeployTaskGroupName es un contrato nuevo, no
        # contemplado todavia, el llamador arma el hashtable de inputs a
        # mano y lo pasa aca -- nunca se adivina un contrato desconocido.
        [hashtable]$DeployTaskGroupInputsOverride
    )

    $inputs = if ($DeployTaskGroupInputsOverride) {
        $DeployTaskGroupInputsOverride
    }
    else {
        switch ($DeployTaskGroupName) {
            'Deployment-Azur-Aks-v3' {
                foreach ($req in @('AksClusterName', 'AksResourceGroup', 'Ambiente', 'Namespace', 'Pipeline')) {
                    if ([string]::IsNullOrWhiteSpace((Get-Variable -Name $req -ValueOnly))) {
                        throw "New-AdoReleaseEnvironmentEntry: falta -$req (requerido por el contrato de 'Deployment-Azur-Aks-v3')."
                    }
                }
                [ordered]@{ aksClusterName = $AksClusterName; aksResourceGroup = $AksResourceGroup; ambiente = $Ambiente; namespace = $Namespace; pipeline = $Pipeline }
            }
            'Deployment-MultiStage-Cluster-Desarrollo' {
                foreach ($req in @('Ambiente', 'ContainerRegistries', 'Image', 'Namespace', 'Pipeline', 'ServicesName')) {
                    if ([string]::IsNullOrWhiteSpace((Get-Variable -Name $req -ValueOnly))) {
                        throw "New-AdoReleaseEnvironmentEntry: falta -$req (requerido por el contrato de 'Deployment-MultiStage-Cluster-Desarrollo')."
                    }
                }
                [ordered]@{ ambiente = $Ambiente; containerregistries = $ContainerRegistries; containerRegistryUsername = ''; containerRegistryPassword = ''; image = $Image; namespace = $Namespace; pipeline = $Pipeline; servicesname = $ServicesName; tag = $Tag }
            }
            default {
                throw "New-AdoReleaseEnvironmentEntry: contrato de deployTaskGroupInputs desconocido para '$DeployTaskGroupName'. Pasar -DeployTaskGroupInputsOverride explicito -- nunca se adivina un contrato nuevo."
            }
        }
    }

    # Hashtable PLANO a proposito (no [ordered]) -- New-AdoReleaseDefinitionPayload
    # valida cada environment con .ContainsKey(), metodo que
    # [OrderedDictionary] no implementa (solo .Contains()). El orden de
    # claves no importa aca: esto es un dato intermedio que esa funcion
    # vuelve a reordenar en su propio [ordered]@{} de salida.
    $entry = @{
        stage                 = $Stage
        variableGroupId       = $VariableGroupId
        artifactFilterBranch  = $ArtifactFilterBranch
        deployTaskGroupId     = $DeployTaskGroupId
        deployTaskGroupName   = $DeployTaskGroupName
        deployTaskGroupInputs = $inputs
        approvalRequired      = $ApprovalRequired
    }
    if ($StageVariables) { $entry['stageVariables'] = $StageVariables }
    if (-not [string]::IsNullOrWhiteSpace($ApproverId)) { $entry['approverId'] = $ApproverId }
    if ($ReleaseCreatorCanBeApprover) { $entry['releaseCreatorCanBeApprover'] = $true }
    if (-not [string]::IsNullOrWhiteSpace($ReportarResultadoTaskGroupId)) { $entry['reportarResultadoTaskGroupId'] = $ReportarResultadoTaskGroupId }

    return $entry
}

function New-AdoReleaseDefinitionPayload {
    <#
    Body para POST .../release/definitions. $Environments es un array
    ORDENADO de hashtables, uno por stage, cada uno con:
      stage, variableGroupId (int, YA EXISTENTE -- ver nota de alcance),
      artifactFilterBranch, deployTaskGroupId, deployTaskGroupName
      (nombre EXACTO del task group -- confirmado 2026-08-24 contra un GET
      real que workflowTasks[0].name = "Task group: <nombre>" es
      obligatorio, la API rechaza con 400 si falta), deployTaskGroupInputs
      (hashtable de nombre->valor, ya en el contrato del task group
      correspondiente -- distinto para Deployment-Azur-Aks-v3 vs
      Deployment-MultiStage-Cluster-Desarrollo, ver
      ado-classic-payload-templates.md), stageAutoDeploy (bool),
      approvalRequired (bool, default false).

    $BuildDefinitionId / $BuildDefinitionName deben ser de un Build QUE
    YA EXISTE (ids reales, nunca inventados) -- igual que
    $variableGroupId de cada stage. Esta funcion no crea nada ni resuelve
    nada por si sola, solo da forma al payload.
    #>
    param(
        [Parameter(Mandatory)] $Plan,
        # NO Mandatory a proposito (mismo motivo que -CreatedSoFar en
        # Invoke-AdoApplyPhases): PowerShell rechaza un [array] MANDATORY
        # que llega vacio como si no se hubiera pasado nada, antes de que
        # el cuerpo de la funcion pueda validarlo con su propio mensaje.
        # El chequeo de "vacio" se hace a mano mas abajo.
        [array]$Environments,
        [Parameter(Mandatory)] [int]$BuildDefinitionId,
        [Parameter(Mandatory)] [string]$BuildDefinitionName
    )

    if ($null -eq $Environments -or $Environments.Count -eq 0) {
        throw "New-AdoReleaseDefinitionPayload: -Environments no puede estar vacio."
    }

    # sourceId / definitionReference.project -- confirmados 2026-08-24
    # contra un GET real (Release 360): sourceId = "<projectId>:<buildDefinitionId>".
    # Mismo mapeo de proyecto conocido que New-AdoVariableGroupPayload,
    # nunca inventado.
    $releaseProjectName = [string]$Plan.project
    $releaseProjectId = switch ($releaseProjectName) {
        'DevOps' { $script:AdoDevOpsProjectId }
        default  { $null }
    }
    if (-not $releaseProjectId) {
        throw "New-AdoReleaseDefinitionPayload: no se pudo resolver el id real del proyecto '$releaseProjectName' para artifacts[0].sourceId/definitionReference.project -- solo 'DevOps' esta soportado hoy. Agregar un mapeo explicito (nunca inventado) antes de usar otro proyecto."
    }

    $artifactAlias = "_$BuildDefinitionName"
    $envPayloads = [System.Collections.Generic.List[object]]::new()
    $rank = 1
    foreach ($env in $Environments) {
        foreach ($required in @('stage', 'variableGroupId', 'artifactFilterBranch', 'deployTaskGroupId', 'deployTaskGroupName', 'deployTaskGroupInputs')) {
            if (-not $env.ContainsKey($required) -or $null -eq $env[$required]) {
                throw "New-AdoReleaseDefinitionPayload: falta '$required' en el environment #$rank ('$($env['stage'])')."
            }
        }

        $isAutomated = -not [bool]($env['approvalRequired'])

        $envPayloads.Add([ordered]@{
            name             = [string]$env['stage']
            rank             = $rank
            variables        = (& {
                # Variables de STAGE (distintas de la Library / Variable
                # Group linkeada): $env['stageVariables'] es opcional,
                # hashtable de nombre -> @{ value=...; isSecret=$true|$false }.
                # Un valor secreto SIEMPRE debe llegar aca como el
                # placeholder '${ADO_SECRET_...}' (nunca el valor real) --
                # esta funcion arma el payload aprobado/hasheable; la
                # resolucion real la hace New-AdoBodyWithResolvedSecrets
                # mas tarde, en memoria, dentro de Invoke-AdoRest.
                $vars = [ordered]@{}
                if ($env.ContainsKey('stageVariables') -and $env['stageVariables']) {
                    foreach ($key in $env['stageVariables'].Keys) {
                        $v = $env['stageVariables'][$key]
                        $isSecretFlag = [bool]$v['isSecret']
                        if ($isSecretFlag -and [string]$v['value'] -notmatch '^\$\{ADO_SECRET_[A-Z0-9_]+\}$') {
                            throw "New-AdoReleaseDefinitionPayload: la variable de stage '$key' esta marcada isSecret=true pero su value no es un placeholder '`${ADO_SECRET_...}' -- nunca se acepta un valor literal aca."
                        }
                        $entry = [ordered]@{ value = [string]$v['value'] }
                        if ($isSecretFlag) { $entry['isSecret'] = $true }
                        $vars[$key] = $entry
                    }
                }
                return $vars
            })
            variableGroups   = @([int]$env['variableGroupId'])
            preDeployApprovals  = (& {
                # Fix 2026-10-29 (gap del path de aprobacion MANUAL, nunca
                # ejercitado antes): una aprobacion manual (isAutomated=$false)
                # EXIGE un approver -- la API rechaza/deja roto el stage si el
                # approval manual no lleva approver={id=...}. Cuando el env trae
                # 'approverId' (un grupo/usuario, p.ej. 'Release Executers'
                # 397ddbfe...) se emite el objeto approver y se respeta
                # 'releaseCreatorCanBeApprover' (default $false). Un stage
                # automatico (approvalRequired=$false) NO lleva approver, igual
                # que antes -- comportamiento historico intacto.
                $approvalEntry = [ordered]@{ rank = 1; isAutomated = $isAutomated; isNotificationOn = $false }
                if (-not $isAutomated -and $env.ContainsKey('approverId') -and -not [string]::IsNullOrWhiteSpace([string]$env['approverId'])) {
                    $approvalEntry['approver'] = [ordered]@{ id = [string]$env['approverId'] }
                }
                $creatorCanApprove = $false
                if ($env.ContainsKey('releaseCreatorCanBeApprover')) { $creatorCanApprove = [bool]$env['releaseCreatorCanBeApprover'] }
                [ordered]@{
                    approvals       = @($approvalEntry)
                    approvalOptions = [ordered]@{
                        requiredApproverCount                             = $null
                        releaseCreatorCanBeApprover                       = $creatorCanApprove
                        autoTriggeredAndPreviousEnvironmentApprovedCanBeSkipped = $false
                        enforceIdentityRevalidation                       = $false
                        timeoutInMinutes                                  = 0
                        executionOrder                                    = 'beforeGates'
                    }
                }
            })
            postDeployApprovals = [ordered]@{
                approvals       = @([ordered]@{ rank = 1; isAutomated = $true; isNotificationOn = $false })
                approvalOptions = [ordered]@{
                    requiredApproverCount                             = $null
                    releaseCreatorCanBeApprover                       = $false
                    autoTriggeredAndPreviousEnvironmentApprovedCanBeSkipped = $false
                    enforceIdentityRevalidation                       = $false
                    timeoutInMinutes                                  = 0
                    executionOrder                                    = 'afterSuccessfulGates'
                }
            }
            deployPhases     = @(
                [ordered]@{
                    deploymentInput = [ordered]@{
                        parallelExecution        = [ordered]@{ parallelExecutionType = 'none' }
                        agentSpecification       = $null
                        skipArtifactsDownload    = $false
                        artifactsDownloadInput   = [ordered]@{ downloadInputs = @() }
                        queueId                  = $script:AdoDefaultReleaseDeployQueueId
                        demands                  = @()
                        # enableAccessToken=true SOLO cuando este ambiente
                        # trae 'reportarResultadoTaskGroupId' -- ese step
                        # necesita SYSTEM_ACCESSTOKEN (OAuth) para comentar
                        # en la HU / moverla a "Applied in production". Ver
                        # references/ado-classic-payload-templates.md §
                        # "Piezas equivalentes del lado Release", confirmado
                        # contra Release 348/381 reales 2026-08-25.
                        enableAccessToken        = $(if ($env.ContainsKey('reportarResultadoTaskGroupId') -and $env['reportarResultadoTaskGroupId']) { $true } else { $false })
                        timeoutInMinutes         = 0
                        jobCancelTimeoutInMinutes = 1
                        condition                = 'succeeded()'
                        overrideInputs           = [ordered]@{}
                    }
                    rank            = 1
                    phaseType       = 'agentBasedDeployment'
                    name            = 'Agent job'
                    refName         = ''
                    workflowTasks   = @(
                        (& {
                            $tasks = [System.Collections.Generic.List[object]]::new()
                            $tasks.Add([ordered]@{
                                taskId          = [string]$env['deployTaskGroupId']
                                version         = '1.*'
                                name            = "Task group: $($env['deployTaskGroupName'])"
                                refName         = ''
                                enabled         = $true
                                alwaysRun       = $true
                                continueOnError = $true
                                timeoutInMinutes = 0
                                retryCountOnTaskFailure = 0
                                definitionType  = 'metaTask'
                                overrideInputs  = [ordered]@{}
                                condition       = 'succeededOrFailed()'
                                environment     = [ordered]@{}
                                inputs          = $env['deployTaskGroupInputs']
                            })
                            if ($env.ContainsKey('reportarResultadoTaskGroupId') -and $env['reportarResultadoTaskGroupId']) {
                                $tasks.Add([ordered]@{
                                    taskId          = [string]$env['reportarResultadoTaskGroupId']
                                    version         = '1.*'
                                    name            = 'Task group: Reportar-resultado-HU'
                                    refName         = ''
                                    enabled         = $true
                                    alwaysRun       = $true
                                    continueOnError = $true
                                    timeoutInMinutes = 0
                                    retryCountOnTaskFailure = 0
                                    definitionType  = 'metaTask'
                                    overrideInputs  = [ordered]@{}
                                    condition       = 'always()'
                                    environment     = [ordered]@{}
                                    inputs          = [ordered]@{}
                                })
                            }
                            return @($tasks)
                        })
                    )
                }
            )
            environmentOptions = [ordered]@{
                emailNotificationType    = 'OnlyOnFailure'
                emailRecipients          = 'release.environment.owner;release.creator'
                skipArtifactsDownload    = $false
                timeoutInMinutes         = 0
                enableAccessToken        = $false
                publishDeploymentStatus  = $true
                badgeEnabled             = $false
                autoLinkWorkItems        = $false
                pullRequestDeploymentEnabled = $false
            }
            demands          = @()
            conditions       = @(
                [ordered]@{ name = 'ReleaseStarted'; conditionType = 'event'; value = '' },
                [ordered]@{
                    name          = $artifactAlias
                    conditionType = 'artifact'
                    value         = (@{ sourceBranch = [string]$env['artifactFilterBranch']; tags = @(); useBuildDefinitionBranch = $false; createReleaseOnBuildTagging = $false } | ConvertTo-Json -Compress)
                }
            )
            executionPolicy  = [ordered]@{ concurrencyCount = 1; queueDepthCount = 1 }
            schedules        = @()
            retentionPolicy  = [ordered]@{ daysToKeep = 30; releasesToKeep = 3; retainBuild = $true }
            processParameters = [ordered]@{}
            preDeploymentGates  = [ordered]@{ id = 0; gatesOptions = [ordered]@{ isEnabled = $false; timeout = 1440; samplingInterval = 15; stabilizationTime = 5; minimumSuccessDuration = 0 }; gates = @() }
            postDeploymentGates = [ordered]@{ id = 0; gatesOptions = $null; gates = @() }
            environmentTriggers = @()
        })
        $rank++
    }

    return [ordered]@{
        variables       = [ordered]@{}
        variableGroups  = @()
        environments    = @($envPayloads)
        artifacts       = @(
            [ordered]@{
                type              = 'Build'
                alias             = $artifactAlias
                sourceId          = "$($releaseProjectId):$BuildDefinitionId"
                definitionReference = [ordered]@{
                    definition    = [ordered]@{ id = [string]$BuildDefinitionId; name = $BuildDefinitionName }
                    defaultVersionType = [ordered]@{ id = 'latestType'; name = 'Latest' }
                    project       = [ordered]@{ id = $releaseProjectId; name = $releaseProjectName }
                    repository    = [ordered]@{ id = ''; name = '' }
                }
                isPrimary         = $true
                isRetained        = $false
            }
        )
        triggers        = @(
            [ordered]@{ artifactAlias = $artifactAlias; triggerConditions = @(); triggerType = 'artifactSource' }
        )
        releaseNameFormat = 'Release-$(rev:r)'
        tags            = @()
        properties      = [ordered]@{}
        name            = [string]$Plan.names.release
        path            = [string]$Plan.names.folder
    }
}

function New-AdoApprovedOperationEntry {
    <#
    Unico punto que arma una entrada de plan.approvedOperations. SIEMPRE
    calcula bodyHash con Get-AdoBodyCanonicalHash sobre el $Body real
    recibido -- nunca acepta un bodyHash como parametro, precisamente
    para que sea imposible "poblarlo a mano": quien llama esta funcion
    tiene que construir el body real primero (con las funciones de
    arriba), nunca puede inventar el hash. 'method' tampoco se acepta
    como parametro -- se deriva SIEMPRE de
    $script:AdoAllowedOperationTypes[$OperationType].method (bug real
    encontrado 2026-08-25: antes de esto, method quedaba hardcodeado en
    'POST' para TODO operationType, lo que rompia silenciosamente los
    2 tipos update-* agregados ese mismo dia -- Invoke-AdoRest rechazaba
    la escritura real con "el metodo aprobado no coincide" porque el
    body decia PUT pero la entrada aprobada decia POST).
    #>
    param(
        [Parameter(Mandatory)] [string]$OperationId,
        [Parameter(Mandatory)] [ValidateSet('create-variable-group', 'create-build-definition', 'create-release-definition', 'update-variable-group', 'update-build-definition', 'update-release-definition', 'update-taskgroup', 'create-taskgroup', 'delete-variable-group', 'delete-build-definition', 'delete-release-definition')] [string]$OperationType,
        [Parameter(Mandatory)] [string]$Uri,
        # [AllowNull()] a proposito: los 3 operationType delete-* SIEMPRE
        # pasan $null aca (un DELETE nunca lleva body) -- sin este
        # atributo, PowerShell trata un $null explicito como "no se paso
        # ningun valor" para un parametro Mandatory sin tipo declarado y
        # lo rechaza (bug real encontrado 2026-08-26 escribiendo las
        # pruebas de esta misma funcion).
        [Parameter(Mandatory)] [AllowNull()] $Body
    )

    return [ordered]@{
        operationId   = $OperationId
        operationType = $OperationType
        method        = $script:AdoAllowedOperationTypes[$OperationType].method
        uri           = $Uri
        bodyHash      = (Get-AdoBodyCanonicalHash -Body $Body)
    }
}

function Invoke-AdoApplyPhases {
    <#
    Orquesta las 3 fases posibles (Variable Group -> Build -> Release),
    SOLO para los operationType que el plan aprobado realmente trae,
    en ese orden fijo. Funcion separada del cuerpo de
    Apply-AdoClassicPlan.ps1 para poder probarla completa (con
    Invoke-WebRequest mockeado, igual que el resto de esta skill) sin
    depender del guard de BuildPhaseImplemented/ReleasePhaseImplemented
    del script de nivel superior -- ese guard solo protege la invocacion
    del ARCHIVO .ps1 completo, esta funcion es la logica real que
    ejecuta cuando el guard ya paso.

    Nunca hace rollback: si una fase lanza, la excepcion sale tal cual
    (el llamador decide como reportarlo). $CreatedSoFar (lista mutable
    que el llamador provee) acumula un renglon por cada recurso
    efectivamente creado en esta corrida, para que el llamador pueda
    reportarlo aunque una fase posterior falle.
    #>
    param(
        [Parameter(Mandatory)] $Plan,
        [Parameter(Mandatory)] [string]$PlanPath,
        # NO Mandatory a proposito: PowerShell rechaza un [List[string]]
        # MANDATORY cuando llega vacio (Count=0), tratandolo como "no se
        # paso ningun valor" -- un bug/comportamiento conocido de binding
        # con colecciones fuertemente tipadas. Se valida $null a mano en
        # su lugar, y se crea una lista nueva si no se paso ninguna.
        [System.Collections.Generic.List[string]]$CreatedSoFar,
        [string]$DeploymentDevYamlPath,
        [string]$DeploymentUatYamlPath,
        [string]$DeploymentProdYamlPath,
        [string]$ReleaseEnvironmentsPath,
        [Nullable[int]]$ExistingBuildDefinitionId,
        [string]$BuildDefinitionName,
        # Referencias de secretos controladas para la fase Release (ver
        # security.md "Referencias de secretos controladas"). Array de
        # @{ Path=...; EnvVarName='ADO_SECRET_...' }, atado a ESTA fase
        # nada mas -- nunca se reutiliza para VG o Build. Opcional: una
        # fase sin secretos de stage simplemente no pasa esto.
        [array]$ReleaseSecretReferences,
        # Fases 4/5 (update-*, agregadas 2026-08-25): a diferencia de las
        # 3 fases create-*, el body de un PUT de actualizacion NO se
        # reconstruye deterministicamente desde $Plan (depende del GET
        # en vivo del recurso al momento de armar el plan) -- viene de un
        # archivo JSON ya armado (mutar-y-guardar, fuera de esta
        # funcion), cuyo contenido es EXACTAMENTE lo que se hasheo al
        # aprobar la operacion.
        [string]$UpdateBuildBodyPath,
        [string]$UpdateReleaseBodyPath,
        # Fase 1b (update-variable-group, agregada 2026-10-14): el body
        # actual del VG obtenido con un GET previo, necesario para
        # preservar variables existentes al mutar solo algunas. JSON string.
        [string]$CurrentVariableGroupJson,
        # Fase 1c (update-taskgroup, agregada 2026-10-16): el body actual
        # del task group (GET previo), para confirmar que la revision en
        # vivo es exactamente la que el plan esperaba editar antes del PUT
        # (anti-pisada de un cambio concurrente). JSON string.
        [string]$CurrentTaskGroupJson
    )

    if ($null -eq $CreatedSoFar) {
        $CreatedSoFar = [System.Collections.Generic.List[string]]::new()
    }

    $approvedOps = @()
    if ($null -ne $Plan.approvedOperations) { $approvedOps = @($Plan.approvedOperations) }

    function Get-AdoApprovedOpByTypeLocal {
        param([string]$OperationType)
        return ($approvedOps | Where-Object { $_.operationType -eq $OperationType } | Select-Object -First 1)
    }

    function Test-AdoOperationAlreadySucceededLocal {
        param([string]$OperationId)
        $journalPath = Get-AdoExecutionJournalPath -PlanValidationHash $Plan.validationHash
        if (-not (Test-Path -LiteralPath $journalPath)) { return $false }
        try {
            $journal = Get-Content -LiteralPath $journalPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $op = $journal.operations.PSObject.Properties[$OperationId]
            return ($op -and $op.Value.state -eq 'succeeded')
        }
        catch {
            return $false
        }
    }

    $vgOp = Get-AdoApprovedOpByTypeLocal -OperationType 'create-variable-group'
    $buildOp = Get-AdoApprovedOpByTypeLocal -OperationType 'create-build-definition'
    $releaseOp = Get-AdoApprovedOpByTypeLocal -OperationType 'create-release-definition'

    $createdBuildDefinitionId = $ExistingBuildDefinitionId

    # ---- Fase 1: Variable Group ----
    if ($vgOp) {
        if (Test-AdoOperationAlreadySucceededLocal -OperationId $vgOp.operationId) {
            Write-Host "Fase 1 (Variable Group '$($Plan.variableGroup.name)'): ya estaba 'succeeded' en el journal de una corrida anterior -- se omite, no se reintenta." -ForegroundColor Yellow
        }
        else {
            Write-Host "Fase 1: Variable Group '$($Plan.variableGroup.name)'..." -ForegroundColor Cyan

            if (Test-AdoClassicResourceNameAlreadyExists -Kind 'VariableGroup' -Name ([string]$Plan.variableGroup.name) -Project ([string]$Plan.project)) {
                throw "Apply-AdoClassicPlan detenido ANTES de escribir: ya existe un Variable Group llamado '$($Plan.variableGroup.name)' en el proyecto '$($Plan.project)' (chequeo en vivo, independiente del journal). Esto puede pasar si el journal se perdio/edito despues de una creacion real anterior -- NO se crea un duplicado. Reconciliar manualmente (leer el recurso real, corregir o recrear el journal) antes de reintentar."
            }

            $vgBody = New-AdoVariableGroupPayload -Plan $Plan
            $vgUri = "$($script:AdoCoreBaseUrl)/$($Plan.project)/_apis/distributedtask/variablegroups?api-version=$($script:AdoApiVersion)"
            $vgResult = Invoke-AdoRest -Method POST -Uri $vgUri -Body $vgBody -RequireApprovedPlan -PlanPath $PlanPath -OperationId $vgOp.operationId
            $CreatedSoFar.Add("Variable Group '$($Plan.variableGroup.name)' (id $($vgResult.Body.id))")
            Write-Host "Variable Group creado: id=$($vgResult.Body.id)" -ForegroundColor Green
        }
    }

    # ---- Fase 1b: Variable Group UPDATE ----
    # Agregado 2026-10-14 (Pablo). El update de un VG existente va separado
    # del create porque requiere diferente payload (viene de $CurrentVariableGroupJson
    # que trae el body actual del VG, no de $Plan.variableGroup que es para crear).
    $vgUpdateOp = Get-AdoApprovedOpByTypeLocal -OperationType 'update-variable-group'
    if ($vgUpdateOp) {
        if (Test-AdoOperationAlreadySucceededLocal -OperationId $vgUpdateOp.operationId) {
            Write-Host "Fase 1b (Variable Group update id=$($Plan.variableGroupUpdate.id)): ya estaba 'succeeded' en el journal de una corrida anterior -- se omite, no se reintenta." -ForegroundColor Yellow
        }
        else {
            if (-not $Plan.variableGroupUpdate -or -not $Plan.variableGroupUpdate.id) {
                throw "Apply-AdoClassicPlan rechazado: el plan tiene aprobada 'update-variable-group' pero falta plan.variableGroupUpdate.id."
            }
            if (-not $CurrentVariableGroupJson) {
                throw "Apply-AdoClassicPlan rechazado: el plan tiene aprobada 'update-variable-group' pero no se paso -CurrentVariableGroupJson (el body actual del VG obtenido con un GET previo, necesario para preservar variables existentes)."
            }

            $currentVG = $null
            try {
                $currentVG = $CurrentVariableGroupJson | ConvertFrom-Json
            }
            catch {
                throw "Apply-AdoClassicPlan rechazado: -CurrentVariableGroupJson no es JSON valido: $($_.Exception.Message)"
            }

            Write-Host "Fase 1b: Variable Group update (id=$($Plan.variableGroupUpdate.id), name='$($currentVG.name)')..." -ForegroundColor Cyan

            $vgUpdateBody = New-AdoVariableGroupUpdatePayload -Plan $Plan -CurrentVariableGroup $currentVG
            $vgUpdateUri = "$($script:AdoCoreBaseUrl)/$($Plan.project)/_apis/distributedtask/variablegroups/$($Plan.variableGroupUpdate.id)?api-version=$($script:AdoApiVersion)"
            # Secretos (agregado 2026-10-29): una variable del plan declarada como
            # objeto { secretEnvVar='ADO_SECRET_...' } quedo en el body como
            # placeholder '${ADO_SECRET_...}' + isSecret=true. Se arma su
            # SecretReference (Path=variables.<name>.value) para que Invoke-AdoRest
            # valide el bodyHash sobre el placeholder y resuelva el valor real SOLO
            # para el PUT (nunca se hashea ni se loggea el secreto).
            $vgSecretRefs = [System.Collections.Generic.List[object]]::new()
            $planUpdVars = $Plan.variableGroupUpdate.variables
            $updVarNames = if ($planUpdVars -is [hashtable] -or $planUpdVars -is [System.Collections.Specialized.OrderedDictionary]) { @($planUpdVars.Keys) } else { @($planUpdVars.PSObject.Properties | ForEach-Object { $_.Name }) }
            foreach ($uvn in $updVarNames) {
                $uv = $planUpdVars[$uvn]
                $sev = $null
                if ($uv -is [hashtable] -or $uv -is [System.Collections.Specialized.OrderedDictionary]) {
                    if ($uv.Contains('secretEnvVar')) { $sev = [string]$uv['secretEnvVar'] }
                } elseif ($uv -is [System.Management.Automation.PSObject] -and $null -ne $uv.PSObject.Properties['secretEnvVar']) {
                    $sev = [string]$uv.secretEnvVar
                }
                if (-not [string]::IsNullOrWhiteSpace($sev)) {
                    $vgSecretRefs.Add(@{ Path = "variables.$uvn.value"; EnvVarName = $sev })
                }
            }
            $vgUpdateInvokeParams = @{ Method = 'PUT'; Uri = $vgUpdateUri; Body = $vgUpdateBody; RequireApprovedPlan = $true; PlanPath = $PlanPath; OperationId = $vgUpdateOp.operationId }
            if ($vgSecretRefs.Count -gt 0) { $vgUpdateInvokeParams['SecretReferences'] = @($vgSecretRefs) }
            $vgUpdateResult = Invoke-AdoRest @vgUpdateInvokeParams
            $CreatedSoFar.Add("Variable Group update '$($currentVG.name)' (id $($Plan.variableGroupUpdate.id))")
            Write-Host "Variable Group actualizado: id=$($vgUpdateResult.Body.id)" -ForegroundColor Green
        }
    }

    # ---- Fase 1c: Task Group UPDATE (agregada 2026-10-16) ----
    # PUT a un task group COMPARTIDO existente. A diferencia de la fase 1b
    # (VG, que hace merge para preservar variables), aca el body rev N+1
    # YA VIENE COMPLETO en $Plan.taskGroupUpdate.body -- no se reconstruye
    # ni se mergea. Lo unico que se consulta de $CurrentTaskGroupJson es la
    # REVISION en vivo: debe ser exactamente la que el plan esperaba editar
    # (body.revision - 1), para no pisar un cambio concurrente que haya
    # subido la revision entre que se genero el plan y se aplica.
    $tgUpdateOp = Get-AdoApprovedOpByTypeLocal -OperationType 'update-taskgroup'
    if ($tgUpdateOp) {
        if (Test-AdoOperationAlreadySucceededLocal -OperationId $tgUpdateOp.operationId) {
            Write-Host "Fase 1c (Task Group update id=$($Plan.taskGroupUpdate.id)): ya estaba 'succeeded' en el journal de una corrida anterior -- se omite, no se reintenta." -ForegroundColor Yellow
        }
        else {
            if (-not $Plan.taskGroupUpdate -or -not $Plan.taskGroupUpdate.id) {
                throw "Apply-AdoClassicPlan rechazado: el plan tiene aprobada 'update-taskgroup' pero falta plan.taskGroupUpdate.id."
            }
            if (-not $Plan.taskGroupUpdate.body) {
                throw "Apply-AdoClassicPlan rechazado: el plan tiene aprobada 'update-taskgroup' pero falta plan.taskGroupUpdate.body (el task group completo rev N+1 a enviar)."
            }
            if (-not $CurrentTaskGroupJson) {
                throw "Apply-AdoClassicPlan rechazado: el plan tiene aprobada 'update-taskgroup' pero no se paso -CurrentTaskGroupJson (el body actual del task group obtenido con un GET previo, necesario para confirmar la revision en vivo antes de pisarla)."
            }

            $currentTG = $null
            try {
                $currentTG = $CurrentTaskGroupJson | ConvertFrom-Json
            }
            catch {
                throw "Apply-AdoClassicPlan rechazado: -CurrentTaskGroupJson no es JSON valido: $($_.Exception.Message)"
            }

            # Confirmacion de identidad: el id del TG en vivo debe ser el del plan.
            if ([string]$currentTG.id -ne [string]$Plan.taskGroupUpdate.id) {
                throw "Apply-AdoClassicPlan rechazado: el task group en vivo (id=$($currentTG.id)) no coincide con el del plan (id=$($Plan.taskGroupUpdate.id)). No se aplica."
            }

            # Anti-pisada concurrente: el body lleva la revision VIGENTE
            # (ADO la incrementa solo al aplicar). La revision en vivo debe
            # ser EXACTAMENTE esa. Si alguien edito el TG entre la generacion
            # del plan y el apply, la revision en vivo no coincidira -> se
            # aborta en vez de sobrescribir ciegamente.
            $expectedLiveRevision = [int]$Plan.taskGroupUpdate.body.revision
            if ([int]$currentTG.revision -ne $expectedLiveRevision) {
                throw "Apply-AdoClassicPlan rechazado: el task group en vivo esta en revision $($currentTG.revision), pero el plan esperaba la revision vigente $expectedLiveRevision (ADO la subira a $($expectedLiveRevision + 1)). Alguien edito el task group desde que se genero el plan. Regenerar el plan contra el estado actual antes de reintentar."
            }

            Write-Host "Fase 1c: Task Group update (id=$($Plan.taskGroupUpdate.id), name='$($currentTG.name)', rev $($currentTG.revision) -> $($currentTG.revision + 1))..." -ForegroundColor Cyan

            # El body se pasa como OBJETO (no string): Invoke-AdoRest lo
            # serializa una sola vez con ConvertTo-Json. Pasar un string
            # pre-serializado causaba doble serializacion -> el servidor
            # recibia un string JSON escapado y devolvia 500 'Input
            # TaskGroup parameter cannot be null'. El bodyHash del plan se
            # calcula sobre el MISMO objeto (ver generador), via
            # Get-AdoBodyCanonicalHash, asi que coincide.
            $tgUpdateBody = $Plan.taskGroupUpdate.body
            $tgUpdateUri = "$($script:AdoCoreBaseUrl)/$($Plan.project)/_apis/distributedtask/taskgroups/$($Plan.taskGroupUpdate.id)?api-version=$($script:AdoApiVersion)"
            $tgUpdateResult = Invoke-AdoRest -Method PUT -Uri $tgUpdateUri -Body $tgUpdateBody -RequireApprovedPlan -PlanPath $PlanPath -OperationId $tgUpdateOp.operationId
            $CreatedSoFar.Add("Task Group update '$($currentTG.name)' (id $($Plan.taskGroupUpdate.id), rev -> $($Plan.taskGroupUpdate.body.revision))")
            Write-Host "Task Group actualizado: id=$($tgUpdateResult.Body.id) rev=$($tgUpdateResult.Body.revision)" -ForegroundColor Green
        }
    }

    # ---- Fase 1d: Task Group CREATE (agregada 2026-10-29) ----
    # POST para crear/clonar un task group NUEVO. A diferencia de la fase 1c
    # (update, PUT a un id existente), aca el id lo asigna ADO -> la URI es la
    # ruta base (sin id), el body NO lleva id, y no hay -CurrentTaskGroupJson
    # que confirmar. El body completo YA VIENE en $Plan.taskGroupCreate.body
    # (su bodyHash fue aprobado). Chequeo en vivo anti-duplicado por NOMBRE
    # antes de escribir (igual criterio que VG/Build/Release create).
    $tgCreateOp = Get-AdoApprovedOpByTypeLocal -OperationType 'create-taskgroup'
    if ($tgCreateOp) {
        if (Test-AdoOperationAlreadySucceededLocal -OperationId $tgCreateOp.operationId) {
            Write-Host "Fase 1d (Task Group create '$($Plan.taskGroupCreate.body.name)'): ya estaba 'succeeded' en el journal de una corrida anterior -- se omite, no se reintenta." -ForegroundColor Yellow
        }
        else {
            if (-not $Plan.taskGroupCreate -or -not $Plan.taskGroupCreate.body) {
                throw "Apply-AdoClassicPlan rechazado: el plan tiene aprobada 'create-taskgroup' pero falta plan.taskGroupCreate.body (el task group completo a crear)."
            }
            $tgCreateName = [string]$Plan.taskGroupCreate.body.name
            if ([string]::IsNullOrWhiteSpace($tgCreateName)) {
                throw "Apply-AdoClassicPlan rechazado: plan.taskGroupCreate.body.name vacio."
            }
            # Anti-duplicado en vivo por nombre: un task group nuevo con un
            # nombre ya usado es casi siempre un error (re-corrida sin journal).
            $tgListUri = "$($script:AdoCoreBaseUrl)/$($Plan.project)/_apis/distributedtask/taskgroups?api-version=$($script:AdoApiVersion)"
            $tgList = (Invoke-AdoRest -Method GET -Uri $tgListUri).Body
            $tgDup = @($tgList.value | Where-Object { [string]$_.name -eq $tgCreateName })
            if ($tgDup.Count -gt 0) {
                throw "Apply-AdoClassicPlan detenido ANTES de escribir: ya existe un Task Group llamado '$tgCreateName' en el proyecto '$($Plan.project)' (id $($tgDup[0].id)). No se crea un duplicado. Si la corrida anterior ya lo creo y el journal se perdio, reconciliar manualmente antes de reintentar."
            }

            Write-Host "Fase 1d: Task Group create '$tgCreateName'..." -ForegroundColor Cyan
            $tgCreateBody = $Plan.taskGroupCreate.body
            $tgCreateUri = "$($script:AdoCoreBaseUrl)/$($Plan.project)/_apis/distributedtask/taskgroups?api-version=$($script:AdoApiVersion)"
            $tgCreateResult = Invoke-AdoRest -Method POST -Uri $tgCreateUri -Body $tgCreateBody -RequireApprovedPlan -PlanPath $PlanPath -OperationId $tgCreateOp.operationId
            $CreatedSoFar.Add("Task Group create '$tgCreateName' (id $($tgCreateResult.Body.id))")
            Write-Host "Task Group creado: id=$($tgCreateResult.Body.id) name='$($tgCreateResult.Body.name)'" -ForegroundColor Green
        }
    }

    # ---- Fase 2: Build definition ----
    if ($buildOp) {
        if (Test-AdoOperationAlreadySucceededLocal -OperationId $buildOp.operationId) {
            Write-Host "Fase 2 (Build '$($Plan.names.build)'): ya estaba 'succeeded' en el journal de una corrida anterior -- se omite, no se reintenta." -ForegroundColor Yellow
        }
        else {
            Write-Host "Fase 2: Build '$($Plan.names.build)'..." -ForegroundColor Cyan

            if (Test-AdoClassicResourceNameAlreadyExists -Kind 'Build' -Name ([string]$Plan.names.build) -Project ([string]$Plan.project)) {
                throw "Apply-AdoClassicPlan detenido ANTES de escribir: ya existe una definicion de Build llamada '$($Plan.names.build)' en el proyecto '$($Plan.project)' (chequeo en vivo, independiente del journal). No se crea un duplicado. Reconciliar manualmente antes de reintentar."
            }

            $buildBody = $null
            if ([string]$Plan.family -eq 'standalone-build') {
                # Rama agregada 2026-09-01 -- ver ConvertFrom-AdoStepsSpecFile
                # y el bloque 'plan.dependencies.standaloneBuild' que escribe
                # New-AdoClassicCreatePlan.ps1 -Kind StandaloneBuild. Nunca
                # exige los 3 manifiestos K8s (esos son exclusivos de la
                # familia aks/dacpac, rama de abajo) -- reconstruye el body
                # EXCLUSIVAMENTE desde datos ya resueltos y guardados en el
                # plan (steps YA RESUELTOS, nunca releidos de un archivo
                # externo que podria haber cambiado desde que se valido).
                if (-not $Plan.dependencies -or -not $Plan.dependencies.standaloneBuild -or -not $Plan.dependencies.standaloneBuild.steps -or @($Plan.dependencies.standaloneBuild.steps).Count -eq 0) {
                    throw "Apply-AdoClassicPlan rechazado: el plan (family='standalone-build') tiene aprobada 'create-build-definition' pero no trae plan.dependencies.standaloneBuild.steps -- regenerar el plan con la version actual de New-AdoClassicCreatePlan.ps1 -Kind StandaloneBuild."
                }
                $sb = $Plan.dependencies.standaloneBuild
                $sbQueueId = $null
                if ($sb.PSObject.Properties['queueId'] -and $null -ne $sb.queueId) { $sbQueueId = [int]$sb.queueId }
                $sbRepoProject = if ($Plan.repo.PSObject.Properties['project'] -and $Plan.repo.project) { [string]$Plan.repo.project } else { [string]$Plan.project }
                $buildBody = New-AdoStandaloneBuildDefinitionPayload -Project ([string]$Plan.project) -Name ([string]$Plan.names.build) `
                    -RepoId ([string]$Plan.repo.id) -RepoName ([string]$Plan.repo.name) -RepoProject $sbRepoProject `
                    -DefaultBranch ([string]$Plan.repo.prodBranch) -Steps @($sb.steps) -FetchDepth ([string]$sb.fetchDepth) `
                    -CiBranchFilters @($sb.ciBranchFilters) -CiBatchChangesEnabled ([bool]$sb.ciBatchChangesEnabled) `
                    -AgentSpecificationIdentifier ([string]$sb.agentSpecificationIdentifier) -AgentPoolId ([int]$sb.agentPoolId) `
                    -AgentPoolName ([string]$sb.agentPoolName) -QueueId $sbQueueId
            }
            else {
                foreach ($reqParam in @('DeploymentDevYamlPath', 'DeploymentUatYamlPath', 'DeploymentProdYamlPath')) {
                    $val = (Get-Variable -Name $reqParam -ValueOnly)
                    if ([string]::IsNullOrWhiteSpace($val)) {
                        throw "Apply-AdoClassicPlan rechazado: el plan tiene aprobada la creacion del Build ('create-build-definition') pero falta -$reqParam. No se puede reconstruir el body real sin el contenido de los 3 manifiestos."
                    }
                    if (-not (Test-Path -LiteralPath $val)) {
                        throw "Apply-AdoClassicPlan rechazado: -$reqParam ('$val') no existe."
                    }
                }

                $manifests = @{
                    dev  = (Get-Content -LiteralPath $DeploymentDevYamlPath -Raw -Encoding UTF8)
                    uat  = (Get-Content -LiteralPath $DeploymentUatYamlPath -Raw -Encoding UTF8)
                    prod = (Get-Content -LiteralPath $DeploymentProdYamlPath -Raw -Encoding UTF8)
                }
                $buildBody = New-AdoBuildDefinitionPayload -Plan $Plan -DeploymentManifests $manifests
            }

            $buildUri = "$($script:AdoCoreBaseUrl)/$($Plan.project)/_apis/build/definitions?api-version=$($script:AdoApiVersion)"
            $buildResult = Invoke-AdoRest -Method POST -Uri $buildUri -Body $buildBody -RequireApprovedPlan -PlanPath $PlanPath -OperationId $buildOp.operationId
            $createdBuildDefinitionId = $buildResult.Body.id
            $CreatedSoFar.Add("Build '$($Plan.names.build)' (id $createdBuildDefinitionId)")
            Write-Host "Build definition creada: id=$createdBuildDefinitionId" -ForegroundColor Green
        }
    }

    # ---- Fase 3: Release definition ----
    if ($releaseOp) {
        if (Test-AdoOperationAlreadySucceededLocal -OperationId $releaseOp.operationId) {
            Write-Host "Fase 3 (Release '$($Plan.names.release)'): ya estaba 'succeeded' en el journal de una corrida anterior -- se omite, no se reintenta." -ForegroundColor Yellow
        }
        else {
            if ([string]::IsNullOrWhiteSpace($ReleaseEnvironmentsPath) -or -not (Test-Path -LiteralPath $ReleaseEnvironmentsPath)) {
                throw "Apply-AdoClassicPlan rechazado: el plan tiene aprobada la creacion del Release ('create-release-definition') pero falta -ReleaseEnvironmentsPath (JSON con la lista de stages, cada uno con variableGroupId YA EXISTENTE, artifactFilterBranch, deployTaskGroupId, deployTaskGroupInputs)."
            }
            if (-not $createdBuildDefinitionId -or -not $BuildDefinitionName) {
                throw "Apply-AdoClassicPlan rechazado: falta el Build ya existente que el Release debe referenciar -- pasar -ExistingBuildDefinitionId/-BuildDefinitionName (si el Build se creo en una corrida anterior) o dejar que la Fase 2 de ESTA corrida lo cree primero."
            }

            Write-Host "Fase 3: Release '$($Plan.names.release)'..." -ForegroundColor Cyan

            if (Test-AdoClassicResourceNameAlreadyExists -Kind 'Release' -Name ([string]$Plan.names.release) -Project ([string]$Plan.project)) {
                throw "Apply-AdoClassicPlan detenido ANTES de escribir: ya existe una definicion de Release llamada '$($Plan.names.release)' en el proyecto '$($Plan.project)' (chequeo en vivo, independiente del journal). No se crea un duplicado. Reconciliar manualmente antes de reintentar."
            }

            $environmentsRaw = Get-Content -LiteralPath $ReleaseEnvironmentsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $environments = @($environmentsRaw | ForEach-Object {
                $envEntry = @{
                    stage                 = [string]$_.stage
                    variableGroupId       = [int]$_.variableGroupId
                    artifactFilterBranch  = [string]$_.artifactFilterBranch
                    deployTaskGroupId     = [string]$_.deployTaskGroupId
                    deployTaskGroupName   = [string]$_.deployTaskGroupName
                    deployTaskGroupInputs = ($_.deployTaskGroupInputs | ForEach-Object { $_ })
                    approvalRequired      = [bool]$_.approvalRequired
                }
                # Mismo passthrough del approver que el bloque de generacion
                # (New-AdoClassicCreatePlan ~L148). DEBE espejar exactamente a
                # aquel: si uno agrega campos al body y el otro no, el body
                # reconstruido en Apply difiere del aprobado -> rompe el bodyHash
                # (mismo tipo de bug que el de 2026-08-26 de arriba).
                if ($_.PSObject.Properties['approverId'] -and -not [string]::IsNullOrWhiteSpace([string]$_.approverId)) {
                    $envEntry['approverId'] = [string]$_.approverId
                }
                if ($_.PSObject.Properties['releaseCreatorCanBeApprover']) {
                    $envEntry['releaseCreatorCanBeApprover'] = [bool]$_.releaseCreatorCanBeApprover
                }
                # Bug real encontrado 2026-08-26 (aplicando Administracion-de-proyectos):
                # estos 2 campos opcionales que New-AdoReleaseEnvironmentEntry SI produce
                # (y que New-AdoReleaseDefinitionPayload SI consume via .ContainsKey())
                # se perdian silenciosamente al reconstruir $environments desde el JSON
                # de -ReleaseEnvironmentsPath -- el body real armado en Apply terminaba
                # sin Reportar-resultado-HU/enableAccessToken aunque el body APROBADO
                # (hasheado antes de aprobar) si los tuviera, lo que rompia el bodyHash
                # y rechazaba la escritura (correctamente, pero por una causa que no era
                # "alguien modifico el plan"). Se agregan solo cuando el JSON de origen
                # los trae, para no alterar el body de un plan que nunca los uso.
                if ($_.PSObject.Properties['reportarResultadoTaskGroupId'] -and -not [string]::IsNullOrWhiteSpace([string]$_.reportarResultadoTaskGroupId)) {
                    $envEntry['reportarResultadoTaskGroupId'] = [string]$_.reportarResultadoTaskGroupId
                }
                if ($_.PSObject.Properties['stageVariables'] -and $_.stageVariables) {
                    $stageVars = @{}
                    foreach ($prop in $_.stageVariables.PSObject.Properties) {
                        $stageVars[$prop.Name] = @{ value = [string]$prop.Value.value; isSecret = [bool]$prop.Value.isSecret }
                    }
                    $envEntry['stageVariables'] = $stageVars
                }
                $envEntry
            })

            $releaseBody = New-AdoReleaseDefinitionPayload -Plan $Plan -Environments $environments -BuildDefinitionId $createdBuildDefinitionId -BuildDefinitionName $BuildDefinitionName
            $releaseUri = "$($script:AdoReleaseBaseUrl)/$($Plan.project)/_apis/release/definitions?api-version=$($script:AdoApiVersion)"
            $releaseInvokeParams = @{
                Method             = 'POST'
                Uri                = $releaseUri
                Body               = $releaseBody
                RequireApprovedPlan = $true
                PlanPath           = $PlanPath
                OperationId        = $releaseOp.operationId
            }
            if ($ReleaseSecretReferences -and @($ReleaseSecretReferences).Count -gt 0) {
                $releaseInvokeParams['SecretReferences'] = @($ReleaseSecretReferences)
            }
            $releaseResult = Invoke-AdoRest @releaseInvokeParams
            $CreatedSoFar.Add("Release '$($Plan.names.release)' (id $($releaseResult.Body.id))")
            Write-Host "Release definition creada: id=$($releaseResult.Body.id)" -ForegroundColor Green
        }
    }

    # ---- Fase 4: actualizar (PUT) un Build existente ----
    $updateBuildOp = Get-AdoApprovedOpByTypeLocal -OperationType 'update-build-definition'
    if ($updateBuildOp) {
        if (Test-AdoOperationAlreadySucceededLocal -OperationId $updateBuildOp.operationId) {
            Write-Host "Fase 4 (actualizar Build): ya estaba 'succeeded' en el journal de una corrida anterior -- se omite, no se reintenta." -ForegroundColor Yellow
        }
        else {
            if ([string]::IsNullOrWhiteSpace($UpdateBuildBodyPath) -or -not (Test-Path -LiteralPath $UpdateBuildBodyPath)) {
                throw "Apply-AdoClassicPlan rechazado: el plan tiene aprobada 'update-build-definition' pero falta -UpdateBuildBodyPath (JSON con el body PUT exacto, el mismo que se hasheo al aprobar)."
            }
            Write-Host "Fase 4: actualizando Build (PUT)..." -ForegroundColor Cyan
            # Bug real encontrado 2026-09-02 (batch de cambio de nombre de BD
            # UAT, 10 Builds Buklo): sin -Encoding UTF8, Windows PowerShell
            # 5.1 lee este archivo (UTF-8 sin BOM) con el codepage ANSI del
            # sistema por defecto -- un caracter multibyte real (ej. banner
            # de box-drawing '===' en un comentario de otro step del mismo
            # Build, o cualquier tilde/em-dash) se reinterpreta byte a byte y
            # puede producir caracteres de control C1 invalidos (U+0080-
            # U+009F) que Azure DevOps rechaza con TF20507 ("The string
            # argument contains a character that is not valid"). El archivo
            # en disco esta bien (confirmado con inspeccion de bytes crudos);
            # el bug esta en ESTA lectura. Nunca quitar -Encoding UTF8 aca.
            $updateBuildBody = Get-Content -LiteralPath $UpdateBuildBodyPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $updateBuildResult = Invoke-AdoRest -Method PUT -Uri $updateBuildOp.uri -Body $updateBuildBody -RequireApprovedPlan -PlanPath $PlanPath -OperationId $updateBuildOp.operationId
            $CreatedSoFar.Add("Build actualizado (id $($updateBuildResult.Body.id), revision $($updateBuildResult.Body.revision))")
            Write-Host "Build actualizado: id=$($updateBuildResult.Body.id) revision=$($updateBuildResult.Body.revision)" -ForegroundColor Green
        }
    }

    # ---- Fase 5: actualizar (PUT) un Release existente ----
    $updateReleaseOp = Get-AdoApprovedOpByTypeLocal -OperationType 'update-release-definition'
    if ($updateReleaseOp) {
        if (Test-AdoOperationAlreadySucceededLocal -OperationId $updateReleaseOp.operationId) {
            Write-Host "Fase 5 (actualizar Release): ya estaba 'succeeded' en el journal de una corrida anterior -- se omite, no se reintenta." -ForegroundColor Yellow
        }
        else {
            if ([string]::IsNullOrWhiteSpace($UpdateReleaseBodyPath) -or -not (Test-Path -LiteralPath $UpdateReleaseBodyPath)) {
                throw "Apply-AdoClassicPlan rechazado: el plan tiene aprobada 'update-release-definition' pero falta -UpdateReleaseBodyPath (JSON con el body PUT exacto, el mismo que se hasheo al aprobar)."
            }
            Write-Host "Fase 5: actualizando Release (PUT)..." -ForegroundColor Cyan
            # Mismo bug/fix que $UpdateBuildBodyPath arriba -- ver ese comentario.
            $updateReleaseBody = Get-Content -LiteralPath $UpdateReleaseBodyPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $updateReleaseResult = Invoke-AdoRest -Method PUT -Uri $updateReleaseOp.uri -Body $updateReleaseBody -RequireApprovedPlan -PlanPath $PlanPath -OperationId $updateReleaseOp.operationId
            $CreatedSoFar.Add("Release actualizado (id $($updateReleaseResult.Body.id), revision $($updateReleaseResult.Body.revision))")
            Write-Host "Release actualizado: id=$($updateReleaseResult.Body.id) revision=$($updateReleaseResult.Body.revision)" -ForegroundColor Green
        }
    }

    # ---- Fase 6: borrar (DELETE) un recurso existente, con respaldo OBLIGATORIO ----
    # Agregada 2026-08-26, autorizada explicitamente por el usuario tras la
    # prueba de reconstruccion completa de administracion-proyectos-web (los
    # 2 archivos de referencia guardados a mano en esa prueba fueron lo que
    # permitio validar la reconstruccion despues -- por eso el respaldo aca
    # es obligatorio, no una sugerencia). Un plan de borrado solo trae UNA
    # de estas 3 entradas (nunca mas de una, ver Test-AdoClassicDeletePlan.ps1),
    # pero se revisan las 3 por si acaso en vez de asumir cual.
    $deleteOpsByKind = [ordered]@{
        VariableGroup = Get-AdoApprovedOpByTypeLocal -OperationType 'delete-variable-group'
        Build         = Get-AdoApprovedOpByTypeLocal -OperationType 'delete-build-definition'
        Release       = Get-AdoApprovedOpByTypeLocal -OperationType 'delete-release-definition'
    }
    foreach ($kind in $deleteOpsByKind.Keys) {
        $deleteOp = $deleteOpsByKind[$kind]
        if (-not $deleteOp) { continue }

        if (Test-AdoOperationAlreadySucceededLocal -OperationId $deleteOp.operationId) {
            Write-Host "Fase 6 (borrar $kind): ya estaba 'succeeded' en el journal de una corrida anterior -- se omite, no se reintenta." -ForegroundColor Yellow
            continue
        }

        Write-Host "Fase 6: borrando $kind (respaldo de solo lectura obligatorio primero)..." -ForegroundColor Cyan

        if ($deleteOp.uri -notmatch '/(\d+)(\?|$)') {
            throw "Apply-AdoClassicPlan rechazado: no se pudo extraer un id numerico de la uri aprobada para '$($deleteOp.operationId)' ('$($deleteOp.uri)')."
        }
        $resourceId = [int]$Matches[1]

        # Respaldo OBLIGATORIO de solo lectura antes de cualquier DELETE
        # real. Un GET fallido o vacio detiene todo antes de tocar la red
        # con DELETE -- nunca se borra sin poder respaldar primero. El GET
        # es de solo lectura (no pasa por -RequireApprovedPlan, igual que
        # cualquier otra lectura de esta skill).
        $backupResult = $null
        try {
            $backupResult = Invoke-AdoRest -Method GET -Uri $deleteOp.uri
        }
        catch {
            throw "Apply-AdoClassicPlan rechazado: no se pudo leer $kind (id=$resourceId) para el respaldo obligatorio antes de borrar -- $($_.Exception.Message). No se procede a borrar sin poder respaldar primero."
        }
        if ($null -eq $backupResult -or $null -eq $backupResult.Body) {
            throw "Apply-AdoClassicPlan rechazado: el GET de respaldo para $kind (id=$resourceId) devolvio vacio -- no se procede a borrar sin un respaldo real."
        }

        $backupPath = Write-AdoPreDeleteBackup -ResourceKind $kind -ResourceId $resourceId -ResourceBody $backupResult.Body
        Write-Host "Respaldo escrito: $backupPath" -ForegroundColor Green

        $deleteResult = Invoke-AdoRest -Method DELETE -Uri $deleteOp.uri -Body $null -RequireApprovedPlan -PlanPath $PlanPath -OperationId $deleteOp.operationId
        $CreatedSoFar.Add("$kind id=$resourceId BORRADO (respaldo: $backupPath)")
        Write-Host "$kind borrado: id=$resourceId" -ForegroundColor Green
    }
}

function Write-AdoPreDeleteBackup {
    <#
    Escribe SIEMPRE un respaldo de solo lectura (JSON real tal cual lo
    devuelve Azure DevOps) a
    .local/azure-devops/exports/pre-delete-backups/ antes de cualquier
    DELETE real -- obligatorio, no opcional (decision explicita del
    usuario 2026-08-26). Un GET de Build/Release/Variable Group nunca
    trae el VALOR de un secreto (Azure DevOps jamas lo devuelve, isSecret
    o no), asi que no hay nada que sanitizar aca -- mismo principio que ya
    aplican los 2 archivos de referencia guardados a mano en
    references/Build-administracion-proyectos-web.json /
    Deploy-Desarrollo-UAT-Produccion-Administracion-Proyectos-Web.json.

    Escribe con [System.IO.File]::WriteAllText + UTF8Encoding($false) en
    vez de Set-Content -Encoding UTF8 a proposito: en Windows PowerShell
    5.1, Set-Content -Encoding UTF8 SI agrega BOM, un bug real ya
    encontrado el mismo dia 2026-08-26 revisando los archivos de plan de
    esta misma prueba -- no repetirlo aca.
    #>
    param(
        [Parameter(Mandatory)] [ValidateSet('VariableGroup', 'Build', 'Release')] [string]$ResourceKind,
        [Parameter(Mandatory)] [int]$ResourceId,
        [Parameter(Mandatory)] $ResourceBody
    )

    $projectRoot = $env:REPO_ROOT
    if ([string]::IsNullOrWhiteSpace($projectRoot)) { $projectRoot = (Get-Location).Path }

    $backupDir = Join-Path $projectRoot '.local\azure-devops\exports\pre-delete-backups'
    if (-not (Test-Path -LiteralPath $backupDir)) {
        New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    }

    $resourceName = [string]$ResourceBody.name
    $safeName = ($resourceName -replace '[^A-Za-z0-9_.-]', '_')
    if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = 'sin-nombre' }
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $fileName = "$ResourceKind-$safeName-$ResourceId-$timestamp.json"
    $backupPath = Join-Path $backupDir $fileName

    $json = $ResourceBody | ConvertTo-Json -Depth 40
    [System.IO.File]::WriteAllText($backupPath, $json, (New-Object System.Text.UTF8Encoding($false)))

    return $backupPath
}

$script:AdoSecretEnvVarNamePattern = '^ADO_SECRET_[A-Z0-9_]+$'

function Resolve-AdoSecretEnvValue {
    <#
    Lee el valor REAL de una referencia de secreto controlada
    ($env:ADO_SECRET_*) -- ver security.md "Referencias de secretos
    controladas". Nunca imprime, loggea ni devuelve el NOMBRE en un
    mensaje que tambien incluya el valor. El valor devuelto vive solo en
    memoria del proceso mientras dure la operacion que lo necesita -- el
    llamador nunca debe escribirlo a disco, plan, journal, log ni
    mensaje de error.
    #>
    param([Parameter(Mandatory)] [string]$EnvVarName)

    if ($EnvVarName -notmatch $script:AdoSecretEnvVarNamePattern) {
        throw "Resolve-AdoSecretEnvValue: '$EnvVarName' no tiene la forma ADO_SECRET_<NOMBRE> (mayusculas/digitos/guion bajo) esperada para una referencia de secreto controlada."
    }

    $value = [Environment]::GetEnvironmentVariable($EnvVarName, 'Process')
    if ([string]::IsNullOrEmpty($value)) {
        $value = [Environment]::GetEnvironmentVariable($EnvVarName, 'User')
    }
    if ([string]::IsNullOrEmpty($value)) {
        throw "Resolve-AdoSecretEnvValue: la variable de entorno '$EnvVarName' no esta configurada o esta vacia. Nunca se trata un valor vacio como si fuera el secreto real -- configurarla en una terminal propia del usuario (nunca pasarla por chat) antes de reintentar."
    }
    return $value
}

function Get-AdoObjectValueAtPath {
    <#
    Navega un objeto (PSCustomObject/array anidados) siguiendo un path
    tipo 'variables.containerRegistryPassword.value' o
    'environments[0].variables.foo.value' (indices de array entre
    corchetes). Devuelve $null si algun segmento intermedio no existe --
    nunca lanza por un path parcialmente ausente, el llamador decide que
    hacer con $null.
    #>
    param([Parameter(Mandatory)] $Node, [Parameter(Mandatory)] [string]$Path)

    $current = $Node
    foreach ($segment in ($Path -split '\.')) {
        if ($null -eq $current) { return $null }
        if ($segment -match '^([A-Za-z0-9_]+)\[(\d+)\]$') {
            $propName = $Matches[1]
            $idx = [int]$Matches[2]
            $current = $current.$propName
            if ($null -eq $current) { return $null }
            $asArray = @($current)
            if ($idx -ge $asArray.Count) { return $null }
            $current = $asArray[$idx]
        }
        else {
            $current = $current.$segment
        }
    }
    return $current
}

function Set-AdoObjectValueAtPath {
    <#
    Misma navegacion que Get-AdoObjectValueAtPath, pero para el PADRE del
    ultimo segmento, sobre el que asigna $Value. Lanza si algun segmento
    intermedio (o el padre final) no existe -- a diferencia del getter,
    escribir en un path que no existe de verdad es un bug del llamador,
    nunca algo que deba pasar en silencio.
    #>
    param([Parameter(Mandatory)] $Node, [Parameter(Mandatory)] [string]$Path, [Parameter(Mandatory)] $Value)

    $segments = @($Path -split '\.')
    $current = $Node
    for ($i = 0; $i -lt $segments.Count - 1; $i++) {
        $segment = $segments[$i]
        if ($segment -match '^([A-Za-z0-9_]+)\[(\d+)\]$') {
            $propName = $Matches[1]
            $idx = [int]$Matches[2]
            $current = $current.$propName
            if ($null -eq $current) { throw "Set-AdoObjectValueAtPath: el segmento '$segment' del path '$Path' no existe." }
            $asArray = @($current)
            if ($idx -ge $asArray.Count) { throw "Set-AdoObjectValueAtPath: el indice $idx de '$segment' en el path '$Path' no existe." }
            $current = $asArray[$idx]
        }
        else {
            $current = $current.$segment
            if ($null -eq $current) { throw "Set-AdoObjectValueAtPath: el segmento '$segment' del path '$Path' no existe." }
        }
    }

    $lastSegment = $segments[-1]
    if ($null -eq $current.PSObject.Properties[$lastSegment]) {
        throw "Set-AdoObjectValueAtPath: la propiedad final '$lastSegment' del path '$Path' no existe en el objeto."
    }
    $current.$lastSegment = $Value
}

function New-AdoBodyWithResolvedSecrets {
    <#
    Toma un body YA APROBADO (el mismo objeto cuyo bodyHash con
    placeholders paso Assert-AdoOperationRequestMatchesSpec /
    Get-AdoBodyCanonicalHash en Invoke-AdoRest) y devuelve una COPIA
    nueva (nunca muta $Body) con los campos listados en
    -SecretReferences resueltos a su valor real. $Body original queda
    intacto -- sigue siendo lo unico que se hashea/compara/loggea; la
    copia resuelta NUNCA se hashea, nunca se escribe a disco, solo se usa
    para el Body real de UNA llamada Invoke-WebRequest.

    Cada entrada de -SecretReferences es @{ Path=...; EnvVarName=... }:
      - Path debe terminar en '.value' (el ultimo segmento).
      - Antes de sustituir, se valida (item 8: "destino... validado"):
          a) el path 'isSecret' hermano (mismo padre que 'value') es
             $true -- si no, se rechaza (nunca se resuelve un secreto
             hacia un campo marcado isSecret=false).
          b) el valor ACTUAL en ese path es EXACTAMENTE el placeholder
             "${<EnvVarName>}" -- si el body ya trae otra cosa (valor
             manipulado, placeholder de otra variable), se rechaza en vez
             de sobreescribir a ciegas.
    #>
    param([Parameter(Mandatory)] $Body, [Parameter(Mandatory)] [array]$SecretReferences)

    if ($SecretReferences.Count -eq 0) { return $Body }

    $clone = $Body | ConvertTo-Json -Depth 40 -Compress | ConvertFrom-Json

    foreach ($ref in $SecretReferences) {
        $path = [string]$ref.Path
        $envVarName = [string]$ref.EnvVarName

        if (-not $path.EndsWith('.value')) {
            throw "New-AdoBodyWithResolvedSecrets: el path '$path' debe terminar en '.value' (solo se resuelven valores de variable, nunca otro campo)."
        }
        if ($envVarName -notmatch $script:AdoSecretEnvVarNamePattern) {
            throw "New-AdoBodyWithResolvedSecrets: '$envVarName' no tiene la forma ADO_SECRET_<NOMBRE> esperada."
        }

        $isSecretPath = $path.Substring(0, $path.Length - '.value'.Length) + '.isSecret'
        $isSecretValue = Get-AdoObjectValueAtPath -Node $clone -Path $isSecretPath
        if ($isSecretValue -ne $true) {
            throw "New-AdoBodyWithResolvedSecrets: '$isSecretPath' no es isSecret=true -- rechazado. Nunca se resuelve un secreto real hacia un campo que no esta marcado como secreto en el body aprobado."
        }

        $expectedPlaceholder = "`${$envVarName}"
        $currentValue = Get-AdoObjectValueAtPath -Node $clone -Path $path
        if ($currentValue -ne $expectedPlaceholder) {
            throw "New-AdoBodyWithResolvedSecrets: '$path' no contiene el placeholder esperado '$expectedPlaceholder' (destino no validado) -- rechazado. Nunca se sustituye en base a una coincidencia de texto suelta."
        }

        $realValue = Resolve-AdoSecretEnvValue -EnvVarName $envVarName
        Set-AdoObjectValueAtPath -Node $clone -Path $path -Value $realValue
    }

    return $clone
}

function Test-AdoClassicResourceNameAlreadyExists {
    <#
    Chequeo de duplicado EN VIVO (GET, solo lectura) inmediatamente antes
    de crear un recurso -- independiente del journal. Cierra el escenario
    "operacion succeeded -> journal borrado por accidente -> segundo
    intento se ve como si nunca hubiera pasado": aunque el journal ya no
    tenga memoria de la primera creacion, esto SIEMPRE vuelve a listar el
    recurso real por nombre antes de decidir escribir.

    Devuelve $true si YA existe una definicion/VG con ese nombre exacto
    en el proyecto (nunca se crea un segundo recurso con el mismo
    nombre). Usa Get-AdoRestAllPages (misma paginacion robusta que el
    resto de la skill), nunca asume que la primera pagina alcanza.
    #>
    param(
        [Parameter(Mandatory)] [ValidateSet('VariableGroup', 'Build', 'Release')] [string]$Kind,
        [Parameter(Mandatory)] [string]$Name,
        [string]$Project = 'DevOps'
    )

    $baseUri = switch ($Kind) {
        'VariableGroup' { "$($script:AdoCoreBaseUrl)/$Project/_apis/distributedtask/variablegroups?api-version=$($script:AdoApiVersion)" }
        'Build' { "$($script:AdoCoreBaseUrl)/$Project/_apis/build/definitions?api-version=$($script:AdoApiVersion)" }
        'Release' { "$($script:AdoReleaseBaseUrl)/$Project/_apis/release/definitions?api-version=$($script:AdoApiVersion)" }
    }

    $result = Get-AdoRestAllPages -BaseUri $baseUri
    foreach ($item in $result.Items) {
        if ([string]$item.name -eq $Name) { return $true }
    }
    return $false
}
