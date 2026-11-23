<#
Genera un plan JSON sanitizado para un pipeline clasico AKS (Library +
Build + Release), sin ejecutar ningun cambio en Azure DevOps. Falla si
falta un dato obligatorio o si detecta un placeholder sin resolver.

No linkea la familia DACPAC. No crea nada - solo escribe el plan bajo
.local/azure-devops/plans/ para que Test-AdoClassicPlan.ps1 lo valide,
Invoke-AdoClassicPlan.ps1 lo revise en modo dry-run (nunca escribe) y,
recien despues de una aprobacion explicita, Apply-AdoClassicPlan.ps1 (el
unico script habilitado para escribir) lo aplique -- hoy Apply-
AdoClassicPlan.ps1 siempre rechaza porque las fases de Build/Release
clasico no estan implementadas contra un payload confirmado en vivo.

Uso (ejemplo con datos ficticios, stage Produccion por defecto):
  powershell -File .\New-AdoClassicAksPlan.ps1 `
    -Producto 'Ejemplo' -App 'Api-Demo' `
    -RepoName 'project_ejemplo_api' -ProdBranch 'release' `
    -Dockerfile './Dockerfile' -PathFilter '+/**' `
    -ServicesName 'ejemplo-api' -Image 'ejemplo-api' `
    -Namespace 'application-services' `
    -AksClusterName 'gmon-prod-aks-eastus2-0004' -AksResourceGroup 'gmon_prod_rg_eastus2_0001' `
    -ConexContainerRegistries 'ACR Hub-2' -ConexKubernetes 'AKS-PROD-SVC' `
    -ContainerRegistries 'gmonhubacreastus20001.azurecr.io'

Uso para Desarrollo/UAT (sin cluster de Producción, con
-DeployTaskGroupName distinto): agregado 2026-08-26 -- ver
-Stage/-DeployTaskGroupName mas abajo y
references/ado-classic-payload-templates.md.
#>

param(
    [Parameter(Mandatory)] [string]$Producto,
    [Parameter(Mandatory)] [string]$App,
    [Parameter(Mandatory)] [string]$RepoName,
    [Parameter(Mandatory)] [string]$ProdBranch,
    # Repo cross-project: cuando el repo de la app vive en OTRO proyecto de
    # Azure DevOps (ej. 'Buklo') distinto del proyecto de pipelines
    # ('DevOps'), es invisible para Export-AdoClassicInventory.ps1. En ese
    # caso, declarar -RepoProject con el proyecto real del repo y -RepoId
    # con su GUID ya resuelto en vivo (ej. via 'az repos show'). Con ambos,
    # Test-AdoClassicPlan.ps1 acepta el repo sin buscarlo en el inventario
    # (lo confia al preflight de la sesion coordinadora). Omitir ambos para
    # el caso normal (repo en el mismo proyecto que los pipelines).
    [string]$RepoProject = '',
    [string]$RepoId = '',
    [Parameter(Mandatory)] [string]$Dockerfile,
    [Parameter(Mandatory)] [string]$PathFilter,
    [Parameter(Mandatory)] [string]$ServicesName,
    [Parameter(Mandatory)] [string]$Image,
    [Parameter(Mandatory)] [string]$Namespace,
    # AksClusterName/AksResourceGroup dejaron de ser Mandatory 2026-08-26:
    # solo se exigen (Assert-NoPlaceholder mas abajo) cuando
    # -DeployTaskGroupName es 'Deployment-Azur-Aks-v3' (el default) --
    # para otros task groups de deploy (ej.
    # 'Deployment-MultiStage-Cluster-Desarrollo', que resuelve el cluster
    # de otra forma) estas 2 claves NO deben aparecer en
    # variableGroup.keys en absoluto (confirmado contra Variable Groups
    # reales de Desarrollo/UAT -- nunca las llevan). Antes de este cambio
    # el generador las agregaba siempre, vacias o con un valor
    # descartable, y habia que borrarlas del JSON a mano despues.
    [string]$AksClusterName,
    [string]$AksResourceGroup,
    # ConexKubernetes dejo de ser Mandatory 2026-08-26: un string vacio ya
    # producia correctamente dependencies.serviceConnectionAks={name='';id=$null}
    # (el patron real de una Produccion que resuelve el cluster solo con
    # AksClusterName+AksResourceGroup, sin Service Connection de
    # Kubernetes) -- solo hacia falta dejar de forzar que alguien la
    # pasara siempre.
    #
    # ADVERTENCIA (bug real de PowerShell encontrado 2026-08-26 escribiendo
    # las pruebas de este mismo parametro): para obtener el default vacio,
    # OMITIR este parametro por completo -- nunca pasar
    # '-ConexKubernetes ""' de forma explicita al invocar este script via
    # 'powershell -File' (o '&'). Windows PowerShell 5.1 descarta en
    # silencio un argumento de string VACIO al armar la linea de comandos
    # de un proceso externo, lo que corre todos los parametros
    # posicionales/con nombre siguientes un lugar y produce un error
    # confuso de "falta un argumento" en el parametro que en realidad SI
    # se paso despues. Repro minimo confirmado con
    # '& powershell -File x.ps1 -A "" -B valor' -- '-A' nunca llega, '-B'
    # termina interpretado como el valor de '-A'.
    [string]$ConexKubernetes = '',
    [Parameter(Mandatory)] [string]$ConexContainerRegistries,
    [Parameter(Mandatory)] [string]$ContainerRegistries,
    [string]$AppName,              # nombre logico del Build (appname). Si se omite, usa ServicesName -- nunca el App "visual"
    [string]$ServiceName,          # solo monorepo; se omite del plan si no se provee
    [string]$RutaDockerfile,       # si distinto de Dockerfile (File Creator)
    [string]$ReqCpu = '75',
    [string]$ReqMem = '128',
    [string]$LimCpu = '300',
    [string]$LimMem = '300',
    [string]$AksBuildAgentPool,
    [string]$DeployTaskGroupName = 'Deployment-Azur-Aks-v3',
    # 'Build-MultiStage' es el estandar de la org confirmado 2026-08-25
    # (reemplaza al task group 'Build', mas viejo) -- ver
    # references/ado-classic-payload-templates.md. -Image debe venir con
    # el guion final (ej. 'mi-app-web-'): Build-MultiStage arma el
    # nombre del repositorio Docker concatenando $(image)$(ambiente) SIN
    # separador.
    [string]$BuildTaskGroupName = 'Build-MultiStage',
    # Convencion org-wide de agrupacion de merges ("gana el mas nuevo") --
    # ver references/ado-classic-payload-templates.md § "Convencion
    # org-wide: fases de agrupacion de merges". ON por defecto: es el
    # estandar confirmado por el usuario 2026-08-25 para TODO pipeline AKS
    # nuevo de este dominio, no una excepcion. Switch INVERTIDO (default
    # false = agrupacion activa) a proposito: un [bool] con default $true
    # invocado via 'powershell -File' no se puede desactivar de forma
    # confiable con '-Param:$false' ni '-Param $false' en esta version de
    # PowerShell -- el argumento llega vacio al binder y siempre lanza
    # ParameterArgumentTransformationError (confirmado 2026-08-25 con un
    # script minimo de prueba). Un switch ausente/presente evita el
    # problema por completo. Pasar -DisableMergeBatching solo cuando el
    # usuario diga explicitamente que esta app no necesita la convencion
    # (ej. app de bajo trafico donde cada push debe buildear individual).
    [switch]$DisableMergeBatching,
    [string]$BatchWindowMinutes = '5',

    # ---- Agregado 2026-08-26: cierra 3 gaps reales encontrados
    # reconstruyendo administracion-proyectos-web con los subagentes (ver
    # memoria de agente ado-classic-aks-plan-multi-env-generator-gaps) --
    # todos con default que reproduce EXACTO el comportamiento anterior a
    # este cambio cuando no se pasan. ----

    # Gap 1: el CI trigger del repo no tenia forma de especificarse --
    # New-AdoBuildDefinitionPayload siempre lo exigio (tira si falta
    # ciBranchFilters), asi que en la practica SIEMPRE habia que
    # agregarlo a mano despues de generar. Ahora se genera desde el
    # principio. -DisableCi sigue el mismo patron invertido que
    # -DisableMergeBatching (mismo motivo: bool con default $true no se
    # puede apagar de forma confiable via -File). ciBatchChangesEnabled
    # no tiene parametro propio a proposito -- es 'false' en TODOS los
    # ejemplos reales confirmados hasta hoy; si algun caso futuro
    # necesitara 'true', editar el campo del plan a mano (mismo criterio
    # que otros casos borde ya documentados en este dominio).
    [switch]$DisableCi,
    [string[]]$CiBranchFilters = @('development', 'uat', 'release'),

    # Gap 2: el generador solo sabia producir el "sabor" Produccion
    # (nombre de VG, ambiente, release.stage siempre hardcodeados a ese
    # valor) sin importar para que ambiente se estuviera planificando en
    # realidad -- construir Desarrollo/UAT exigia parchear a mano
    # names.variableGroup/variableGroup.name/keys.ambiente/release.stage
    # despues de generar. Default 'Produccion' preserva EXACTO el
    # comportamiento previo a este cambio para cualquier invocacion que
    # no pase -Stage.
    [ValidateSet('Desarrollo', 'UAT', 'Produccion')]
    [string]$Stage = 'Produccion',
    # release.stageAutoDeploy/preDeploymentApprovalRequired/
    # preDeploymentApprovalGroup NO EXISTIAN antes en el objeto generado
    # (Test-AdoClassicPlan.ps1/quien ensamblara el Release tenia que
    # agregarlos con Add-Member -Force a mano) -- ahora siempre existen.
    # stageAutoDeploy tiene un default sensato POR STAGE (Desarrollo=true,
    # UAT/Produccion=false, el patron real confirmado); la aprobacion de
    # Produccion NUNCA se asume por default (sigue exigiendo que el
    # usuario la confirme explicitamente cada vez, ver authorization.md) --
    # por eso -PreDeploymentApprovalRequired es un switch aparte, no algo
    # que -Stage decida solo.
    [switch]$PreDeploymentApprovalRequired,
    [string]$PreDeploymentApprovalGroup,
    # Claves extra de Variable Group que no forman parte del set fijo
    # estandar (ej. 'loglevel') -- antes exigian Add-Member -Force sobre
    # variableGroup.keys despues de generar. Vacio por defecto: no cambia
    # nada si no se usa.
    #
    # Formato 'clave=valor;clave=valor', NO [hashtable] ni JSON, a
    # proposito -- 2 fallas reales encontradas 2026-08-26 escribiendo las
    # pruebas de este mismo parametro, ambas al invocar este script via
    # 'powershell -File' (un proceso separado): (1) un literal de
    # hashtable de PowerShell no sobrevive el paso de argumentos entre
    # procesos (se aplana a texto que el binder del hijo no puede
    # reconstruir); (2) un string JSON con comillas dobles incrustadas
    # ('{"loglevel":"info"}') tambien se corrompe -- PowerShell 5.1 puede
    # perder las comillas internas al armar la linea de comandos de un
    # proceso EXTERNO. Un formato plano sin comillas ni llaves anidadas
    # (';' entre pares, '=' dentro de cada par) es seguro como argumento
    # de linea de comandos porque no necesita ningun caracter especial
    # que el marshalling de PowerShell pueda mutilar.
    [string]$ExtraVariableGroupKeys = '',

    # Gap 3: sobreescribir el nombre real del Build en minuscula (el
    # patron real de esta org, ej. 'Build-administracion-proyectos-web')
    # dejaba 'pipeline'/'artifactAlias' desincronizados en casing porque
    # ambos seguian derivandose de -Producto/-App por separado. Ahora
    # -BuildName/-ReleaseName son la UNICA fuente de esos 2 nombres --
    # sobreescribirlos aca los mantiene sincronizados automaticamente. Sin
    # pasar ninguno de los dos, el default reproduce EXACTO el nombre que
    # ya se generaba antes de este cambio.
    [string]$BuildName,
    [string]$ReleaseName,
    # Mismo motivo que -BuildName/-ReleaseName, encontrado en la SEGUNDA
    # prueba de reconstruccion (2026-08-26): sin esto, el nombre del
    # Variable Group se seguia derivando de "$Stage-$Producto-$App" con
    # el casing crudo pasado en -Producto/-App (ej.
    # 'Desarrollo-Administracion-Proyectos-Web'), distinto del real de la
    # org en minuscula ('Desarrollo-administracion-proyectos-web') --
    # mismo tipo de desincronizacion que el Gap 3 original, pero para el
    # nombre del VG en vez del Build. Default identico al comportamiento
    # previo si se omite.
    [string]$VariableGroupName,

    [string]$OutDir
)

$ErrorActionPreference = 'Stop'

$placeholderPattern = '(?i)^(change_me.*|xxx+|tbd|todo|<.*>)$'

function Assert-NoPlaceholder {
    param([string]$Name, [string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "New-AdoClassicAksPlan: falta el dato obligatorio '$Name'."
    }
    if ($Value -match $placeholderPattern) {
        throw "New-AdoClassicAksPlan: '$Name' contiene un placeholder sin resolver ('$Value')."
    }
}

$fieldsToCheck = @{
    Producto                 = $Producto
    App                      = $App
    RepoName                 = $RepoName
    ProdBranch                = $ProdBranch
    Dockerfile                = $Dockerfile
    PathFilter                 = $PathFilter
    ServicesName               = $ServicesName
    Image                       = $Image
    Namespace                   = $Namespace
    ConexContainerRegistries    = $ConexContainerRegistries
    ContainerRegistries         = $ContainerRegistries
}

foreach ($kv in $fieldsToCheck.GetEnumerator()) {
    Assert-NoPlaceholder -Name $kv.Key -Value $kv.Value
}

# AksClusterName/AksResourceGroup: solo obligatorios cuando el deploy
# task group es el estandar 'Deployment-Azur-Aks-v3' (que resuelve el
# cluster exclusivamente con estos 2 datos) -- otros task groups de
# deploy (ej. Deployment-MultiStage-Cluster-Desarrollo) no los usan en
# absoluto, y no deben aparecer ni vacios en variableGroup.keys.
$usaDeployTaskGroupAksV3 = ($DeployTaskGroupName -eq 'Deployment-Azur-Aks-v3')
if ($usaDeployTaskGroupAksV3) {
    Assert-NoPlaceholder -Name 'AksClusterName' -Value $AksClusterName
    Assert-NoPlaceholder -Name 'AksResourceGroup' -Value $AksResourceGroup
}
elseif (-not [string]::IsNullOrWhiteSpace($AksClusterName) -or -not [string]::IsNullOrWhiteSpace($AksResourceGroup)) {
    throw "New-AdoClassicAksPlan: -AksClusterName/-AksResourceGroup no aplican para -DeployTaskGroupName '$DeployTaskGroupName' (solo para 'Deployment-Azur-Aks-v3') -- omitirlos, no pasar valores que despues quedarian sin uso."
}

# appname es el nombre LOGICO del Build (tab Variables). No asumir que
# coincide con el nombre visual -App -- por defecto usa ServicesName
# (el nombre de recurso K8s real), y si se pasa -AppName explicito se
# valida igual que el resto de los campos obligatorios.
if ([string]::IsNullOrWhiteSpace($AppName)) {
    $AppName = $ServicesName
}
else {
    Assert-NoPlaceholder -Name 'AppName' -Value $AppName
}

$EnableMergeBatching = -not [bool]$DisableMergeBatching
$EnableCi = -not [bool]$DisableCi

$projectRoot = $env:REPO_ROOT
if ([string]::IsNullOrWhiteSpace($projectRoot)) { $projectRoot = (Get-Location).Path }

if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $projectRoot '.local\azure-devops\plans'
}
if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
}

$rutaDockerfileEfectiva = if ($RutaDockerfile) { $RutaDockerfile } else { $Dockerfile }

# buildVariables: SERVICE_NAME solo se agrega si es monorepo (evita
# escribir "SERVICE_NAME": null en el plan cuando no aplica).
$buildVariables = [ordered]@{
    appname                  = $AppName
    image                    = $Image
    rutadockerfile           = $rutaDockerfileEfectiva
    conexcontainerregistries = $ConexContainerRegistries
    tag                      = '$(Build.BuildId)'
    'system.debug'           = 'false'
}
if (-not [string]::IsNullOrWhiteSpace($ServiceName)) {
    $buildVariables['SERVICE_NAME'] = $ServiceName
}

# dependencies: nombres conocidos ahora; id/revision quedan null hasta
# que Test-AdoClassicPlan.ps1 los resuelva y confirme contra un
# -InventoryPath real. Nunca se inventan valores aca.
$dependencies = [ordered]@{
    buildTaskGroup = [ordered]@{ name = $BuildTaskGroupName; id = $null; revision = $null }
    deployTaskGroup = [ordered]@{ name = $DeployTaskGroupName; id = $null; revision = $null }
    serviceConnectionAcr = [ordered]@{ name = $ConexContainerRegistries; id = $null }
    serviceConnectionAks = [ordered]@{ name = $ConexKubernetes; id = $null }
    agentPool = [ordered]@{ name = $AksBuildAgentPool; id = $null }
}
if ($EnableMergeBatching) {
    # Nombres reales, confirmados contra Build-portal-cmdb (552) y
    # Build-administracion-proyectos-web (622) -- ids se resuelven contra
    # inventario en vivo por Test-AdoClassicPlan.ps1, nunca inventados aca.
    $dependencies['evaluarVentanaTaskGroup'] = [ordered]@{ name = 'Evaluar-ventana-agrupacion'; id = $null; revision = $null }
    $dependencies['ganaElMasNuevoTaskGroup'] = [ordered]@{ name = 'Gana-el-mas-nuevo'; id = $null; revision = $null }
    $dependencies['reportarResultadoTaskGroup'] = [ordered]@{ name = 'Reportar-resultado-HU'; id = $null; revision = $null }
}

# Gap 3: -BuildName/-ReleaseName son la unica fuente de estos nombres --
# default identico al que se generaba antes de este cambio.
$buildNameEfectivo = if (-not [string]::IsNullOrWhiteSpace($BuildName)) { $BuildName } else { "Build-$Producto-$App" }
$releaseNameEfectivo = if (-not [string]::IsNullOrWhiteSpace($ReleaseName)) { $ReleaseName } else { "Deploy-Desarrollo-UAT-Produccion-$Producto-$App" }

# Gap 2: mapeo Stage -> ambiente (valor real usado en cada VG de esta
# org) y defaults de stageAutoDeploy por stage (patron real confirmado:
# Desarrollo se autodespliega, UAT/Produccion no).
$ambientePorStage = @{ Desarrollo = 'dev'; UAT = 'uat'; Produccion = 'prod' }
$stageAutoDeployPorStage = @{ Desarrollo = $true; UAT = $false; Produccion = $false }

# Bug real encontrado 2026-08-26 (Buklo Gateway) y de nuevo 2026-09-04
# (revision independiente de app-logistics): release.artifactFilterBranch
# se armaba SIEMPRE con $ProdBranch, sin importar -Stage -- para
# Desarrollo/UAT terminaba apuntando a la rama 'release', que nunca tiene
# un build real en esos ambientes, asi que el CD automatico jamas
# matcheaba nada. Desarrollo/UAT siempre filtran por su propia rama fija
# ('development'/'uat', mismo patron ya hardcodeado en $ambientePorStage);
# solo Produccion sigue seleccionando la rama real de -ProdBranch (que
# puede no ser literalmente 'release' en otro producto).
$artifactFilterBranchPorStage = @{ Desarrollo = 'development'; UAT = 'uat'; Produccion = $ProdBranch }

$variableGroupKeys = [ordered]@{
    ambiente                 = $ambientePorStage[$Stage]
    containerregistries      = $ContainerRegistries
    conexcontainerregistries = $ConexContainerRegistries
    conexkubernetes          = $ConexKubernetes
    namespace                = $Namespace
}
if ($usaDeployTaskGroupAksV3) {
    $variableGroupKeys['aksClusterName'] = $AksClusterName
    $variableGroupKeys['aksResourceGroup'] = $AksResourceGroup
}
$variableGroupKeys['tag'] = '$(Build.BuildId)'
$variableGroupKeys['reqcpu'] = $ReqCpu
$variableGroupKeys['reqmem'] = $ReqMem
$variableGroupKeys['limcpu'] = $LimCpu
$variableGroupKeys['limmem'] = $LimMem
$variableGroupKeys['servicesname'] = $ServicesName
$variableGroupKeys['image'] = $Image
$variableGroupKeys['pipeline'] = $buildNameEfectivo
$variableGroupKeys['rutadockerfile'] = $rutaDockerfileEfectiva

if (-not [string]::IsNullOrWhiteSpace($ExtraVariableGroupKeys)) {
    foreach ($pair in ($ExtraVariableGroupKeys -split ';')) {
        if ([string]::IsNullOrWhiteSpace($pair)) { continue }
        $kv = $pair -split '=', 2
        if ($kv.Count -ne 2 -or [string]::IsNullOrWhiteSpace($kv[0])) {
            throw "New-AdoClassicAksPlan: -ExtraVariableGroupKeys tiene un par invalido ('$pair') -- formato esperado 'clave=valor;clave=valor'."
        }
        $variableGroupKeys[$kv[0].Trim()] = $kv[1]
    }
}

$variableGroupNameEfectivo = if (-not [string]::IsNullOrWhiteSpace($VariableGroupName)) { $VariableGroupName } else { "$Stage-$Producto-$App" }

$plan = [PSCustomObject]@{
    family      = 'aks'
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    organization   = 'Shared-Service-GM'
    project        = 'DevOps'
    validated      = $false

    names = @{
        build           = $buildNameEfectivo
        release         = $releaseNameEfectivo
        variableGroup   = $variableGroupNameEfectivo
        folder          = "\$Producto"
    }

    repo = @{
        name                  = $RepoName
        prodBranch            = $ProdBranch
        pathFilter            = $PathFilter
        # Agregado 2026-08-26 (Gap 1) -- New-AdoBuildDefinitionPayload ya
        # exige estos 3 campos para poder armar el trigger del Build;
        # antes del cambio SIEMPRE habia que agregarlos a mano despues de
        # generar. ciBatchChangesEnabled queda fijo en $false (patron real
        # confirmado en todos los ejemplos existentes).
        ciEnabled             = $EnableCi
        ciBatchChangesEnabled = $false
        ciBranchFilters       = @($CiBranchFilters)
    }

    dockerfile = @{
        path            = $Dockerfile
        rutadockerfile  = $rutaDockerfileEfectiva
        generatedByFileCreator = [bool]$RutaDockerfile -and ($RutaDockerfile -ne $Dockerfile)
        isMonorepo      = -not [string]::IsNullOrWhiteSpace($ServiceName)
    }

    buildVariables = $buildVariables

    dependencies = $dependencies

    # Convencion org-wide de agrupacion de merges. New-AdoBuildDefinitionPayload
    # solo activa las 8 piezas del lado Build cuando mergeBatching.enabled=true
    # esta explicito aca -- nunca por default silencioso a ese nivel. El
    # lado Release (Reportar-resultado-HU + enableAccessToken por ambiente)
    # se arma aparte al ensamblar el array $Environments para
    # New-AdoReleaseDefinitionPayload (pasar 'reportarResultadoTaskGroupId'
    # en cada environment que lo necesite) -- ver
    # references/ado-classic-payload-templates.md § "Piezas equivalentes
    # del lado Release".
    mergeBatching = [ordered]@{
        enabled       = $EnableMergeBatching
        windowMinutes = $BatchWindowMinutes
    }

    variableGroup = @{
        name = $variableGroupNameEfectivo
        keys = $variableGroupKeys
    }

    release = @{
        artifactAlias      = "_$buildNameEfectivo"
        cdTriggerEnabled   = $true
        stage              = $Stage
        deployTaskGroup    = $DeployTaskGroupName
        artifactFilterBranch = $artifactFilterBranchPorStage[$Stage]
        agentPool          = $AksBuildAgentPool
        # Agregado 2026-08-26 (Gap 2) -- antes NO EXISTIAN en el objeto
        # generado (habia que Add-Member -Force a mano cada vez).
        # stageAutoDeploy usa el default real por stage;
        # preDeploymentApprovalRequired/Group NUNCA se asumen solos --
        # siguen exigiendo que el usuario los confirme explicitamente
        # (ver authorization.md), por eso son parametros aparte y no algo
        # que -Stage decida.
        stageAutoDeploy    = $stageAutoDeployPorStage[$Stage]
        preDeploymentApprovalRequired = [bool]$PreDeploymentApprovalRequired
        preDeploymentApprovalGroup = $(if ($PreDeploymentApprovalRequired) { $PreDeploymentApprovalGroup } else { $null })
        # Marcador para quien ensamble el array $Environments de
        # New-AdoReleaseDefinitionPayload mas adelante: si es true, ese
        # stage debe pasar 'reportarResultadoTaskGroupId' (resuelto contra
        # dependencies.reportarResultadoTaskGroup.id de este mismo plan)
        # para activar el step + enableAccessToken=true en ese ambiente.
        reportarResultadoHU = $EnableMergeBatching
    }

    # Manifiesto de escrituras aprobadas: vacio a proposito. Los payloads
    # de Build/Release clasico no estan confirmados todavia (ver
    # references/ado-classic-playbook-any-project.md Sec. 10); hasta que
    # existan, ninguna escritura puede aprobarse aca. Invoke-AdoRest.ps1
    # rechaza toda escritura si este array esta vacio.
    approvedOperations = @()

    notes = @(
        'Plan generado sin ejecutar ningun cambio en Azure DevOps.',
        "Stage planificado: $Stage. Los otros 2 ambientes quedan fuera de este plan salvo que se generen explicitamente (uno por invocacion)."
    )
}

$outFile = Join-Path $OutDir ("aks-$Producto-$App-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss')).ToLowerInvariant()
# Repo cross-project (opcional): solo se agregan cuando se proveen, para no
# alterar la forma del plan del caso normal (repo en el mismo proyecto).
if (-not [string]::IsNullOrWhiteSpace($RepoProject)) {
    $plan.repo.project = $RepoProject
}
if (-not [string]::IsNullOrWhiteSpace($RepoId)) {
    $plan.repo.id = $RepoId
}

$plan | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $outFile -Encoding utf8

Write-Host "Plan AKS (sin validar todavia) escrito en: $outFile" -ForegroundColor Green
Write-Host "Stage: $Stage" -ForegroundColor Cyan
Write-Host "Siguiente paso: Test-AdoClassicPlan.ps1 -PlanPath '$outFile'" -ForegroundColor Yellow
