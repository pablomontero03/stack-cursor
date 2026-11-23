<#
Pruebas de regresion a nivel de script (no de hooks) para
manage-azure-devops-pipelines. Usa unicamente datos ficticios y un
directorio temporal propio (nunca .local/azure-devops/ real, nunca la
red). No hace ningun POST/PUT/DELETE contra Azure DevOps: cuando se
invoca Invoke-AdoRest con una URI valida y AZURE_DEVOPS_PAT sin
configurar, la llamada se detiene ANTES de la red (falla al construir
credenciales), lo cual es precisamente lo que estas pruebas verifican.

Uso:
  powershell -NoProfile -ExecutionPolicy Bypass -File .\run-script-tests.ps1
#>

$ErrorActionPreference = 'Stop'

$scriptsRoot = Split-Path -Parent $PSScriptRoot
$testTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ado-script-tests-{0}" -f ([Guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Force -Path $testTempRoot | Out-Null

$results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
    param([string]$Name, [bool]$Pass, [string]$Detail)
    $results.Add([PSCustomObject]@{ Name = $Name; Status = $(if ($Pass) { 'PASS' } else { 'FAIL' }); Detail = $Detail })
}

function Invoke-ExpectThrow {
    param([string]$Name, [scriptblock]$Block, [string]$ExpectedMessagePattern)
    try {
        & $Block
        Add-Result -Name $Name -Pass $false -Detail 'Se esperaba una excepcion y no se lanzo ninguna.'
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -match $ExpectedMessagePattern) {
            Add-Result -Name $Name -Pass $true -Detail $msg
        }
        else {
            Add-Result -Name $Name -Pass $false -Detail "Excepcion no coincide con el patron esperado ('$ExpectedMessagePattern'). Mensaje real: $msg"
        }
    }
}

function Invoke-ExpectNoThrow {
    param([string]$Name, [scriptblock]$Block)
    try {
        $null = & $Block
        Add-Result -Name $Name -Pass $true -Detail 'OK'
    }
    catch {
        Add-Result -Name $Name -Pass $false -Detail "No se esperaba excepcion. Mensaje: $($_.Exception.Message)"
    }
}

function Copy-OrderedHash {
    param([System.Collections.Specialized.OrderedDictionary]$Source)
    $copy = [ordered]@{}
    foreach ($key in $Source.Keys) { $copy[$key] = $Source[$key] }
    return $copy
}

function Invoke-ChildScript {
    # Redirige stderr a un archivo (no a 2>&1) para no disparar el
    # envoltorio NativeCommandError de PowerShell 5.1 sobre stderr de
    # procesos nativos, que con $ErrorActionPreference='Stop' abortaria
    # este arnes aunque el hijo termine con throw de forma esperada.
    param([string]$ScriptPath, [string[]]$ScriptArgs)
    $stderrFile = Join-Path $testTempRoot ("stderr-{0}.txt" -f ([Guid]::NewGuid().ToString('N')))
    $previousEap = $ErrorActionPreference
    try {
        # Un throw no controlado en el hijo escribe en su stderr; con
        # $ErrorActionPreference='Stop' aca, PowerShell 5.1 convierte esa
        # salida nativa en un NativeCommandError terminante aunque el
        # exit code se lea bien despues. Se baja a 'Continue' solo para
        # esta llamada puntual (que es exactamente el caso que estamos
        # probando: que el script hijo rechace con throw).
        $ErrorActionPreference = 'Continue'
        $fullArgs = @('-NoProfile', '-File', $ScriptPath) + $ScriptArgs
        $stdout = & powershell @fullArgs 2> $stderrFile
        $exitCode = $LASTEXITCODE
        $stderrText = if (Test-Path -LiteralPath $stderrFile) { Get-Content -LiteralPath $stderrFile -Raw } else { '' }
        $combined = (($stdout | Out-String)) + "`n" + $stderrText
        # PowerShell 5.1 renderiza un ErrorRecord no controlado envolviendo
        # el texto al ancho de consola vigente al momento de la captura
        # (aunque stderr este redirigido a un archivo, no a una consola
        # real) -- eso puede partir una frase de mensaje a mitad de
        # palabra con un salto de linea justo en el punto de wrap. Se
        # devuelve TAMBIEN una version con todo espacio en blanco (saltos
        # de linea incluidos) colapsado a un solo espacio, para que los
        # -match de este arnes contra frases de varias palabras no
        # dependan del ancho de consola del proceso que ejecuta las
        # pruebas. Text conserva el original (para depuracion); usar
        # TextFlat para cualquier -match de una frase con espacios.
        $flat = ($combined -replace '\s+', ' ').Trim()
        return [PSCustomObject]@{ Text = $combined; TextFlat = $flat; ExitCode = $exitCode }
    }
    finally {
        $ErrorActionPreference = $previousEap
        Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

# Aislar el PAT de este proceso de pruebas: nunca debe llegar a
# construirse un header con un valor real durante estas pruebas.
$originalPat = $env:AZURE_DEVOPS_PAT
Remove-Item Env:\AZURE_DEVOPS_PAT -ErrorAction SilentlyContinue

try {
    . (Join-Path $scriptsRoot 'Invoke-AdoRest.ps1')

    # ============================================================
    # Grupo A: Assert-AdoAllowedUri -- validacion ANTES de credenciales
    # ============================================================

    Invoke-ExpectNoThrow -Name 'URI: dev.azure.com/Shared-Service-GM valida' -Block {
        Assert-AdoAllowedUri -Uri 'https://dev.azure.com/Shared-Service-GM/_apis/projects?api-version=7.1'
    }
    Invoke-ExpectNoThrow -Name 'URI: vsrm.dev.azure.com/Shared-Service-GM valida' -Block {
        Assert-AdoAllowedUri -Uri 'https://vsrm.dev.azure.com/Shared-Service-GM/DevOps/_apis/release/definitions?api-version=7.1'
    }
    Invoke-ExpectThrow -Name 'URI: HTTP en vez de HTTPS rechazada' -ExpectedMessagePattern 'solo se permite el esquema https' -Block {
        Assert-AdoAllowedUri -Uri 'http://dev.azure.com/Shared-Service-GM/_apis/projects?api-version=7.1'
    }
    Invoke-ExpectThrow -Name 'URI: host externo rechazado' -ExpectedMessagePattern 'host no autorizado' -Block {
        Assert-AdoAllowedUri -Uri 'https://evil.example.invalid/Shared-Service-GM/_apis/projects?api-version=7.1'
    }
    Invoke-ExpectThrow -Name 'URI: otra organizacion (path) rechazada' -ExpectedMessagePattern 'la ruta debe empezar con' -Block {
        Assert-AdoAllowedUri -Uri 'https://dev.azure.com/Otra-Organizacion/_apis/projects?api-version=7.1'
    }
    Invoke-ExpectThrow -Name 'URI: userinfo (usuario:pass@host) rechazada' -ExpectedMessagePattern 'userinfo' -Block {
        Assert-AdoAllowedUri -Uri 'https://usuario:secreto@dev.azure.com/Shared-Service-GM/_apis/projects?api-version=7.1'
    }
    Invoke-ExpectThrow -Name 'URI: puerto no estandar rechazado' -ExpectedMessagePattern 'puerto no estandar' -Block {
        Assert-AdoAllowedUri -Uri 'https://dev.azure.com:8443/Shared-Service-GM/_apis/projects?api-version=7.1'
    }
    Invoke-ExpectThrow -Name 'URI: no absoluta / invalida rechazada' -ExpectedMessagePattern 'URI invalida' -Block {
        Assert-AdoAllowedUri -Uri 'no-es-una-uri'
    }

    # ============================================================
    # Grupo B: el PAT nunca se toca para una URI no autorizada, y las
    # escrituras exigen el flujo de plan aprobado
    # ============================================================

    Invoke-ExpectThrow -Name 'Invoke-AdoRest: URI externa rechazada ANTES de pedir el PAT' -ExpectedMessagePattern 'host no autorizado' -Block {
        Invoke-AdoRest -Method GET -Uri 'https://evil.example.invalid/robar-pat'
    }
    Invoke-ExpectThrow -Name 'Invoke-AdoRest: URI valida + sin PAT -> falla en credenciales (prueba que la validacion de URI paso primero)' -ExpectedMessagePattern 'AZURE_DEVOPS_PAT no esta configurada' -Block {
        Invoke-AdoRest -Method GET -Uri 'https://dev.azure.com/Shared-Service-GM/_apis/projects?api-version=7.1'
    }
    Invoke-ExpectThrow -Name 'Invoke-AdoRest: POST directo sin -RequireApprovedPlan rechazado (sin llegar a la red)' -ExpectedMessagePattern 'no paso por el flujo de plan aprobado' -Block {
        Invoke-AdoRest -Method POST -Uri 'https://dev.azure.com/Shared-Service-GM/DevOps/_apis/distributedtask/variablegroups?api-version=7.1' -Body @{ name = 'x' }
    }

    # ============================================================
    # Grupo C: New-AdoClassicAksPlan.ps1 -- appname y SERVICE_NAME
    # ============================================================

    $aksPlanNoServiceName = Join-Path $testTempRoot 'aks-no-service-name.json'
    & powershell -NoProfile -File (Join-Path $scriptsRoot 'New-AdoClassicAksPlan.ps1') `
        -Producto 'Ejemplo' -App 'Api-Demo-Visual' `
        -RepoName 'project_ejemplo_api_demo' -ProdBranch 'release' `
        -Dockerfile './Dockerfile' -PathFilter '+/**' `
        -ServicesName 'ejemplo-api-demo' -Image 'ejemplo-api-demo' `
        -Namespace 'application-services-example' `
        -AksClusterName 'gmon-example-aks-eastus2-9999' -AksResourceGroup 'gmon_example_rg_eastus2_9999' `
        -ConexContainerRegistries 'ACR-Example' -ConexKubernetes 'AKS-EXAMPLE-SVC' `
        -ContainerRegistries 'example.azurecr.io' `
        -OutDir $testTempRoot | Out-Null
    $generated = Get-ChildItem $testTempRoot -Filter 'aks-ejemplo-api-demo-visual-*.json' | Select-Object -Last 1
    if ($generated) { Copy-Item $generated.FullName $aksPlanNoServiceName -Force }

    if (Test-Path -LiteralPath $aksPlanNoServiceName) {
        $planNoSvc = Get-Content -LiteralPath $aksPlanNoServiceName -Raw | ConvertFrom-Json
        $appnameIsServicesName = $planNoSvc.buildVariables.appname -eq 'ejemplo-api-demo'
        $appnameIsNotVisualApp = $planNoSvc.buildVariables.appname -ne 'Api-Demo-Visual'
        Add-Result -Name 'New-AdoClassicAksPlan: appname usa ServicesName, no el App visual' `
            -Pass ($appnameIsServicesName -and $appnameIsNotVisualApp) `
            -Detail "appname='$($planNoSvc.buildVariables.appname)'"

        $hasServiceNameKey = $planNoSvc.buildVariables.PSObject.Properties.Name -contains 'SERVICE_NAME'
        Add-Result -Name 'New-AdoClassicAksPlan: SERVICE_NAME omitido cuando no es monorepo (no null)' `
            -Pass (-not $hasServiceNameKey) `
            -Detail "presente=$hasServiceNameKey"

        Add-Result -Name 'New-AdoClassicAksPlan: BuildTaskGroupName default es Build-MultiStage (reemplaza a Build, estandar 2026-08-25)' `
            -Pass ($planNoSvc.dependencies.buildTaskGroup.name -eq 'Build-MultiStage') `
            -Detail "buildTaskGroup.name=$($planNoSvc.dependencies.buildTaskGroup.name)"
        Add-Result -Name 'New-AdoClassicAksPlan: mergeBatching.enabled=true por defecto (convencion org-wide, sin pasar -EnableMergeBatching)' `
            -Pass ($planNoSvc.mergeBatching.enabled -eq $true -and $planNoSvc.mergeBatching.windowMinutes -eq '5') `
            -Detail ($planNoSvc.mergeBatching | ConvertTo-Json -Compress)
        Add-Result -Name 'New-AdoClassicAksPlan: por defecto agrega las 3 dependencias de agrupacion (nombre, id/revision null hasta resolver)' `
            -Pass ($planNoSvc.dependencies.evaluarVentanaTaskGroup.name -eq 'Evaluar-ventana-agrupacion' -and $planNoSvc.dependencies.ganaElMasNuevoTaskGroup.name -eq 'Gana-el-mas-nuevo' -and $planNoSvc.dependencies.reportarResultadoTaskGroup.name -eq 'Reportar-resultado-HU' -and $null -eq $planNoSvc.dependencies.ganaElMasNuevoTaskGroup.id) `
            -Detail ($planNoSvc.dependencies | ConvertTo-Json -Compress -Depth 5)
        Add-Result -Name 'New-AdoClassicAksPlan: release.reportarResultadoHU=true por defecto (marcador para ensamblar $Environments despues)' `
            -Pass ($planNoSvc.release.reportarResultadoHU -eq $true) `
            -Detail "reportarResultadoHU=$($planNoSvc.release.reportarResultadoHU)"
    }
    else {
        Add-Result -Name 'New-AdoClassicAksPlan: generacion de plan sin ServiceName' -Pass $false -Detail 'No se genero el archivo de plan.'
    }

    # Opt-out explicito: -EnableMergeBatching:$false no agrega ninguna de
    # las 3 dependencias ni el bloque mergeBatching queda enabled=true.
    $aksPlanNoBatching = Join-Path $testTempRoot 'aks-no-batching.json'
    & powershell -NoProfile -File (Join-Path $scriptsRoot 'New-AdoClassicAksPlan.ps1') `
        -Producto 'Ejemplo' -App 'Api-SinBatching' `
        -RepoName 'project_ejemplo_api_sinbatching' -ProdBranch 'release' `
        -Dockerfile './Dockerfile' -PathFilter '+/**' `
        -ServicesName 'ejemplo-api-sinbatching' -Image 'ejemplo-api-sinbatching' `
        -Namespace 'application-services-example' `
        -AksClusterName 'gmon-example-aks-eastus2-9999' -AksResourceGroup 'gmon_example_rg_eastus2_9999' `
        -ConexContainerRegistries 'ACR-Example' -ConexKubernetes 'AKS-EXAMPLE-SVC' `
        -ContainerRegistries 'example.azurecr.io' `
        -DisableMergeBatching `
        -OutDir $testTempRoot | Out-Null
    $generatedNoBatching = Get-ChildItem $testTempRoot -Filter 'aks-ejemplo-api-sinbatching-*.json' | Select-Object -Last 1
    if ($generatedNoBatching) { Copy-Item $generatedNoBatching.FullName $aksPlanNoBatching -Force }

    if (Test-Path -LiteralPath $aksPlanNoBatching) {
        $planNoBatching = Get-Content -LiteralPath $aksPlanNoBatching -Raw | ConvertFrom-Json
        Add-Result -Name 'New-AdoClassicAksPlan -DisableMergeBatching: mergeBatching.enabled=false, sin las 3 dependencias nuevas' `
            -Pass ($planNoBatching.mergeBatching.enabled -eq $false -and -not $planNoBatching.dependencies.PSObject.Properties.Name.Contains('evaluarVentanaTaskGroup') -and -not $planNoBatching.dependencies.PSObject.Properties.Name.Contains('ganaElMasNuevoTaskGroup') -and -not $planNoBatching.dependencies.PSObject.Properties.Name.Contains('reportarResultadoTaskGroup')) `
            -Detail "mergeBatching=$($planNoBatching.mergeBatching | ConvertTo-Json -Compress); dependencies keys=$(($planNoBatching.dependencies.PSObject.Properties.Name) -join ', ')"
    }
    else {
        Add-Result -Name 'New-AdoClassicAksPlan -DisableMergeBatching: generacion de plan' -Pass $false -Detail 'No se genero el archivo de plan.'
    }

    $aksPlanWithServiceName = Join-Path $testTempRoot 'aks-with-service-name.json'
    & powershell -NoProfile -File (Join-Path $scriptsRoot 'New-AdoClassicAksPlan.ps1') `
        -Producto 'Ejemplo' -App 'Api-Demo-Visual' -AppName 'ejemplo-appname-logico' `
        -RepoName 'project_ejemplo_api_demo' -ProdBranch 'release' `
        -Dockerfile './Dockerfile.service' -PathFilter '+services/ejemplo/**' `
        -ServicesName 'ejemplo-api-demo' -Image 'ejemplo-api-demo' -ServiceName 'ejemplo' `
        -Namespace 'application-services-example' `
        -AksClusterName 'gmon-example-aks-eastus2-9999' -AksResourceGroup 'gmon_example_rg_eastus2_9999' `
        -ConexContainerRegistries 'ACR-Example' -ConexKubernetes 'AKS-EXAMPLE-SVC' `
        -ContainerRegistries 'example.azurecr.io' `
        -OutDir $testTempRoot | Out-Null
    $generated2 = Get-ChildItem $testTempRoot -Filter 'aks-ejemplo-api-demo-visual-*.json' | Sort-Object LastWriteTime | Select-Object -Last 1
    if ($generated2) { Copy-Item $generated2.FullName $aksPlanWithServiceName -Force }

    if (Test-Path -LiteralPath $aksPlanWithServiceName) {
        $planWithSvc = Get-Content -LiteralPath $aksPlanWithServiceName -Raw | ConvertFrom-Json
        Add-Result -Name 'New-AdoClassicAksPlan: -AppName explicito se respeta' `
            -Pass ($planWithSvc.buildVariables.appname -eq 'ejemplo-appname-logico') `
            -Detail "appname='$($planWithSvc.buildVariables.appname)'"
        Add-Result -Name 'New-AdoClassicAksPlan: SERVICE_NAME presente cuando es monorepo' `
            -Pass ($planWithSvc.buildVariables.SERVICE_NAME -eq 'ejemplo') `
            -Detail "SERVICE_NAME='$($planWithSvc.buildVariables.SERVICE_NAME)'"
    }
    else {
        Add-Result -Name 'New-AdoClassicAksPlan: generacion de plan con ServiceName' -Pass $false -Detail 'No se genero el archivo de plan.'
    }

    # ============================================================
    # Grupo C2: New-AdoClassicAksPlan.ps1 -- 3 gaps reales corregidos
    # 2026-08-26 (CI trigger no parametrizado, "Produccion" hardcodeado
    # para cualquier ambiente, casing de pipeline/artifactAlias
    # desincronizado al overridear el nombre del Build). Ver memoria
    # ado-classic-aks-plan-multi-env-generator-gaps.
    # ============================================================

    # C2-1: invocacion SIN ninguno de los parametros nuevos -> debe seguir
    # dando el mismo resultado de siempre (Stage=Produccion por default),
    # ahora con los campos que antes faltaban ya poblados correctamente.
    $aksPlanDefaultStage = Join-Path $testTempRoot 'aks-default-stage.json'
    & powershell -NoProfile -File (Join-Path $scriptsRoot 'New-AdoClassicAksPlan.ps1') `
        -Producto 'Ejemplo' -App 'Gaps-Default' `
        -RepoName 'project_ejemplo_gaps' -ProdBranch 'release' `
        -Dockerfile './Dockerfile' -PathFilter '+/**' `
        -ServicesName 'ejemplo-gaps' -Image 'ejemplo-gaps' `
        -Namespace 'application-services-example' `
        -AksClusterName 'gmon-example-aks-eastus2-9999' -AksResourceGroup 'gmon_example_rg_eastus2_9999' `
        -ConexContainerRegistries 'ACR-Example' -ConexKubernetes 'AKS-EXAMPLE-SVC' `
        -ContainerRegistries 'example.azurecr.io' `
        -OutDir $testTempRoot | Out-Null
    $generatedDefaultStage = Get-ChildItem $testTempRoot -Filter 'aks-ejemplo-gaps-default-*.json' | Select-Object -Last 1
    if ($generatedDefaultStage) { Copy-Item $generatedDefaultStage.FullName $aksPlanDefaultStage -Force }

    if (Test-Path -LiteralPath $aksPlanDefaultStage) {
        $planDefaultStage = Get-Content -LiteralPath $aksPlanDefaultStage -Raw | ConvertFrom-Json
        Add-Result -Name 'C2-1: sin -Stage -> sigue siendo Produccion (compatibilidad exacta con el comportamiento previo)' `
            -Pass ($planDefaultStage.release.stage -eq 'Produccion' -and $planDefaultStage.variableGroup.keys.ambiente -eq 'prod' -and $planDefaultStage.names.variableGroup -eq 'Produccion-Ejemplo-Gaps-Default') `
            -Detail "stage=$($planDefaultStage.release.stage); ambiente=$($planDefaultStage.variableGroup.keys.ambiente); vgName=$($planDefaultStage.names.variableGroup)"
        Add-Result -Name 'C2-1 (Gap 1): repo.ciEnabled/ciBatchChangesEnabled/ciBranchFilters ya vienen poblados (antes faltaban siempre)' `
            -Pass ($planDefaultStage.repo.ciEnabled -eq $true -and $planDefaultStage.repo.ciBatchChangesEnabled -eq $false -and (($planDefaultStage.repo.ciBranchFilters -join ',') -eq 'development,uat,release')) `
            -Detail ($planDefaultStage.repo | ConvertTo-Json -Compress)
        Add-Result -Name 'C2-1 (Gap 2): release.stageAutoDeploy/preDeploymentApprovalRequired ya existen (antes exigian Add-Member a mano)' `
            -Pass ($planDefaultStage.release.PSObject.Properties.Name -contains 'stageAutoDeploy' -and $planDefaultStage.release.stageAutoDeploy -eq $false -and $planDefaultStage.release.preDeploymentApprovalRequired -eq $false -and $null -eq $planDefaultStage.release.preDeploymentApprovalGroup) `
            -Detail "stageAutoDeploy=$($planDefaultStage.release.stageAutoDeploy); preDeploymentApprovalRequired=$($planDefaultStage.release.preDeploymentApprovalRequired)"
        Add-Result -Name 'C2-1: aksClusterName/aksResourceGroup presentes cuando el deploy task group es Deployment-Azur-Aks-v3 (default)' `
            -Pass ($planDefaultStage.variableGroup.keys.aksClusterName -eq 'gmon-example-aks-eastus2-9999' -and $planDefaultStage.variableGroup.keys.aksResourceGroup -eq 'gmon_example_rg_eastus2_9999') `
            -Detail ($planDefaultStage.variableGroup.keys | ConvertTo-Json -Compress)
    }
    else {
        Add-Result -Name 'C2-1: generacion de plan default (sin parametros nuevos)' -Pass $false -Detail 'No se genero el archivo de plan.'
    }

    # C2-2: -Stage Desarrollo + deploy task group que NO usa cluster de
    # Produccion -> no exige AksClusterName/AksResourceGroup, y esas 2
    # claves NO deben aparecer en variableGroup.keys.
    $aksPlanDesarrollo = Join-Path $testTempRoot 'aks-desarrollo.json'
    & powershell -NoProfile -File (Join-Path $scriptsRoot 'New-AdoClassicAksPlan.ps1') `
        -Producto 'Ejemplo' -App 'Gaps-Dev' `
        -RepoName 'project_ejemplo_gaps' -ProdBranch 'development' `
        -Dockerfile './Dockerfile' -PathFilter '+/**' `
        -ServicesName 'ejemplo-gaps-dev' -Image 'ejemplo-gaps-dev' `
        -Namespace 'desarrollo' `
        -ConexContainerRegistries 'ACR-Example' -ConexKubernetes 'AKS-DEV-SVC' `
        -ContainerRegistries 'example.azurecr.io' `
        -DeployTaskGroupName 'Deployment-MultiStage-Cluster-Desarrollo' `
        -Stage Desarrollo `
        -OutDir $testTempRoot | Out-Null
    $generatedDesarrollo = Get-ChildItem $testTempRoot -Filter 'aks-ejemplo-gaps-dev-*.json' | Select-Object -Last 1
    if ($generatedDesarrollo) { Copy-Item $generatedDesarrollo.FullName $aksPlanDesarrollo -Force }

    if (Test-Path -LiteralPath $aksPlanDesarrollo) {
        $planDesarrollo = Get-Content -LiteralPath $aksPlanDesarrollo -Raw | ConvertFrom-Json
        Add-Result -Name 'C2-2 (Gap 2): -Stage Desarrollo -> ambiente=dev, variableGroup.name=Desarrollo-..., release.stage=Desarrollo' `
            -Pass ($planDesarrollo.variableGroup.keys.ambiente -eq 'dev' -and $planDesarrollo.names.variableGroup -eq 'Desarrollo-Ejemplo-Gaps-Dev' -and $planDesarrollo.release.stage -eq 'Desarrollo') `
            -Detail "ambiente=$($planDesarrollo.variableGroup.keys.ambiente); vgName=$($planDesarrollo.names.variableGroup); stage=$($planDesarrollo.release.stage)"
        Add-Result -Name 'C2-2: stageAutoDeploy=true por default en Desarrollo (patron real)' `
            -Pass ($planDesarrollo.release.stageAutoDeploy -eq $true) -Detail "stageAutoDeploy=$($planDesarrollo.release.stageAutoDeploy)"
        Add-Result -Name 'C2-2: sin -AksClusterName/-AksResourceGroup, deploy task group distinto de Deployment-Azur-Aks-v3 -> no exige esos datos' `
            -Pass $true -Detail 'La generacion no lanzo excepcion sin pasar AksClusterName/AksResourceGroup.'
        Add-Result -Name 'C2-2: aksClusterName/aksResourceGroup NUNCA aparecen en variableGroup.keys para este deploy task group (antes habia que borrarlos a mano)' `
            -Pass (-not ($planDesarrollo.variableGroup.keys.PSObject.Properties.Name -contains 'aksClusterName') -and -not ($planDesarrollo.variableGroup.keys.PSObject.Properties.Name -contains 'aksResourceGroup')) `
            -Detail "keys=$(($planDesarrollo.variableGroup.keys.PSObject.Properties.Name) -join ', ')"
    }
    else {
        Add-Result -Name 'C2-2: generacion de plan Desarrollo (sin cluster de Produccion)' -Pass $false -Detail 'No se genero el archivo de plan.'
    }

    # C2-3: pasar -AksClusterName con un deploy task group que no es
    # Deployment-Azur-Aks-v3 -> rechazado (guardarrail nuevo).
    Invoke-ExpectThrow -Name 'C2-3: -AksClusterName con -DeployTaskGroupName distinto de Deployment-Azur-Aks-v3 -> rechazado' `
        -ExpectedMessagePattern 'no aplican para -DeployTaskGroupName' -Block {
        & powershell -NoProfile -File (Join-Path $scriptsRoot 'New-AdoClassicAksPlan.ps1') `
            -Producto 'Ejemplo' -App 'Gaps-Bad' -RepoName 'project_ejemplo_gaps' -ProdBranch 'uat' `
            -Dockerfile './Dockerfile' -PathFilter '+/**' -ServicesName 'ejemplo-gaps-bad' -Image 'ejemplo-gaps-bad' `
            -Namespace 'uat' -ConexContainerRegistries 'ACR-Example' -ConexKubernetes 'AKS-DEV-SVC' `
            -ContainerRegistries 'example.azurecr.io' -DeployTaskGroupName 'Deployment-MultiStage-Cluster-Desarrollo' `
            -AksClusterName 'no-deberia-usarse' -OutDir $testTempRoot
        if ($LASTEXITCODE -ne 0) { throw "New-AdoClassicAksPlan rechazado: -AksClusterName/-AksResourceGroup no aplican para -DeployTaskGroupName 'Deployment-MultiStage-Cluster-Desarrollo'" }
    }

    # C2-4 (Gap 3): -BuildName sobreescribe names.build Y mantiene
    # pipeline/artifactAlias sincronizados automaticamente (antes se
    # desincronizaban si solo se pisaba names.build a mano despues).
    $aksPlanBuildNameOverride = Join-Path $testTempRoot 'aks-buildname-override.json'
    & powershell -NoProfile -File (Join-Path $scriptsRoot 'New-AdoClassicAksPlan.ps1') `
        -Producto 'Administracion-Proyectos' -App 'Web' `
        -RepoName 'Administracion-de-proyectos' -ProdBranch 'release' `
        -Dockerfile './Dockerfile' -PathFilter '+/**' `
        -ServicesName 'administracion-proyectos-web' -Image 'administracion-proyectos-web-' `
        -Namespace 'apps-web' `
        -AksClusterName 'gmon-prod-aks-eastus2-0004' -AksResourceGroup 'gmon_prod_rg_eastus2_0001' `
        -ConexContainerRegistries 'ACR Hub-2' `
        -ContainerRegistries 'gmonhubacreastus20001.azurecr.io' `
        -BuildName 'Build-administracion-proyectos-web' `
        -VariableGroupName 'Produccion-administracion-proyectos-web' `
        -ExtraVariableGroupKeys 'loglevel=info' `
        -OutDir $testTempRoot | Out-Null
    $generatedBuildNameOverride = Get-ChildItem $testTempRoot -Filter 'aks-administracion-proyectos-web-*.json' | Select-Object -Last 1
    if ($generatedBuildNameOverride) { Copy-Item $generatedBuildNameOverride.FullName $aksPlanBuildNameOverride -Force }

    if (Test-Path -LiteralPath $aksPlanBuildNameOverride) {
        $planBuildNameOverride = Get-Content -LiteralPath $aksPlanBuildNameOverride -Raw | ConvertFrom-Json
        Add-Result -Name 'C2-4 (Gap 3): -BuildName sobreescribe names.build al valor real (minuscula)' `
            -Pass ($planBuildNameOverride.names.build -eq 'Build-administracion-proyectos-web') `
            -Detail "names.build=$($planBuildNameOverride.names.build)"
        Add-Result -Name 'C2-4 (Gap 3): variableGroup.keys.pipeline queda SINCRONIZADO con -BuildName automaticamente (antes se desincronizaba)' `
            -Pass ($planBuildNameOverride.variableGroup.keys.pipeline -eq 'Build-administracion-proyectos-web') `
            -Detail "pipeline=$($planBuildNameOverride.variableGroup.keys.pipeline)"
        Add-Result -Name 'C2-4 (Gap 3): release.artifactAlias queda SINCRONIZADO con -BuildName automaticamente (antes se desincronizaba)' `
            -Pass ($planBuildNameOverride.release.artifactAlias -eq '_Build-administracion-proyectos-web') `
            -Detail "artifactAlias=$($planBuildNameOverride.release.artifactAlias)"
        Add-Result -Name 'C2-4: -ExtraVariableGroupKeys agrega la clave loglevel (antes exigia Add-Member a mano)' `
            -Pass ($planBuildNameOverride.variableGroup.keys.loglevel -eq 'info') `
            -Detail "loglevel=$($planBuildNameOverride.variableGroup.keys.loglevel)"
        Add-Result -Name 'C2-4: -ConexKubernetes vacio ya no exige el parametro (antes era Mandatory) y produce serviceConnectionAks.name=vacio' `
            -Pass ($planBuildNameOverride.variableGroup.keys.conexkubernetes -eq '' -and $planBuildNameOverride.dependencies.serviceConnectionAks.name -eq '') `
            -Detail "conexkubernetes='$($planBuildNameOverride.variableGroup.keys.conexkubernetes)'"
        Add-Result -Name 'C2-4 (gap encontrado en la 2da prueba real 2026-08-26): -VariableGroupName sobreescribe names.variableGroup/variableGroup.name al valor real (minuscula), no el casing crudo de -Producto/-App' `
            -Pass ($planBuildNameOverride.names.variableGroup -eq 'Produccion-administracion-proyectos-web' -and $planBuildNameOverride.variableGroup.name -eq 'Produccion-administracion-proyectos-web') `
            -Detail "names.variableGroup=$($planBuildNameOverride.names.variableGroup); variableGroup.name=$($planBuildNameOverride.variableGroup.name)"
    }
    else {
        Add-Result -Name 'C2-4: generacion de plan con -BuildName/-ExtraVariableGroupKeys' -Pass $false -Detail 'No se genero el archivo de plan.'
    }

    # C2-5: -PreDeploymentApprovalRequired + -PreDeploymentApprovalGroup
    # -> ambos campos quedan poblados (nunca se asume solo por -Stage).
    $aksPlanApproval = Join-Path $testTempRoot 'aks-approval.json'
    & powershell -NoProfile -File (Join-Path $scriptsRoot 'New-AdoClassicAksPlan.ps1') `
        -Producto 'Ejemplo' -App 'Gaps-Approval' -RepoName 'project_ejemplo_gaps' -ProdBranch 'release' `
        -Dockerfile './Dockerfile' -PathFilter '+/**' -ServicesName 'ejemplo-gaps-approval' -Image 'ejemplo-gaps-approval' `
        -Namespace 'application-services-example' `
        -AksClusterName 'gmon-example-aks-eastus2-9999' -AksResourceGroup 'gmon_example_rg_eastus2_9999' `
        -ConexContainerRegistries 'ACR-Example' -ConexKubernetes 'AKS-EXAMPLE-SVC' -ContainerRegistries 'example.azurecr.io' `
        -PreDeploymentApprovalRequired -PreDeploymentApprovalGroup '[Shared-Service-GM]\Release Executers' `
        -OutDir $testTempRoot | Out-Null
    $generatedApproval = Get-ChildItem $testTempRoot -Filter 'aks-ejemplo-gaps-approval-*.json' | Select-Object -Last 1
    if ($generatedApproval) { Copy-Item $generatedApproval.FullName $aksPlanApproval -Force }
    if (Test-Path -LiteralPath $aksPlanApproval) {
        $planApproval = Get-Content -LiteralPath $aksPlanApproval -Raw | ConvertFrom-Json
        Add-Result -Name 'C2-5: -PreDeploymentApprovalRequired + -PreDeploymentApprovalGroup quedan poblados juntos' `
            -Pass ($planApproval.release.preDeploymentApprovalRequired -eq $true -and $planApproval.release.preDeploymentApprovalGroup -eq '[Shared-Service-GM]\Release Executers') `
            -Detail "preDeploymentApprovalRequired=$($planApproval.release.preDeploymentApprovalRequired); preDeploymentApprovalGroup=$($planApproval.release.preDeploymentApprovalGroup)"
    }
    else {
        Add-Result -Name 'C2-5: generacion de plan con aprobacion de Produccion' -Pass $false -Detail 'No se genero el archivo de plan.'
    }

    # ============================================================
    # Grupo D: Test-AdoClassicPlan.ps1 -- inventario incompleto / de otra
    # organizacion / viejo / completo y fresco -- usando el plan de Grupo C
    # (con ServiceName, dependencies ya presentes)
    # ============================================================

    if (Test-Path -LiteralPath $aksPlanWithServiceName) {

        # D0: sin inventario -> NOT_VERIFIED, validated=false
        $planD0 = Join-Path $testTempRoot 'plan-d0.json'
        Copy-Item $aksPlanWithServiceName $planD0 -Force
        & powershell -NoProfile -File (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -PlanPath $planD0 | Out-Null
        $resultD0 = Get-Content -LiteralPath $planD0 -Raw | ConvertFrom-Json
        Add-Result -Name 'Test-AdoClassicPlan: sin inventario -> validated=false' -Pass ($resultD0.validated -eq $false) -Detail "validated=$($resultD0.validated)"
        Add-Result -Name 'Test-AdoClassicPlan: sin inventario -> sin validationHash' -Pass ([string]::IsNullOrEmpty($resultD0.validationHash)) -Detail "validationHash='$($resultD0.validationHash)'"

        # Inventario base (completo, fresco, org/proyecto correctos, todo matchea el plan)
        $baseInventory = [ordered]@{
            generatedAtUtc     = (Get-Date).ToUniversalTime().ToString('o')
            organization       = 'Shared-Service-GM'
            project            = 'DevOps'
            paginationComplete = $true
            projects           = @(@{ id = 'proj1'; name = 'DevOps' })
            buildDefinitions   = @()
            releaseDefinitions = @()
            variableGroups     = @()
            taskGroups         = @(
                @{ id = 'tg-build'; name = 'Build'; revision = 3 },
                # Estandar vigente 2026-08-25 -- New-AdoClassicAksPlan.ps1
                # ahora usa 'Build-MultiStage' por defecto (reemplaza a
                # 'Build'), asi que un inventario real y completo lo trae.
                @{ id = 'tg-build-multistage'; name = 'Build-MultiStage'; revision = 1 },
                @{ id = 'tg-deploy'; name = 'Deployment-Azur-Aks-v3'; revision = 5 },
                # Convencion org-wide de agrupacion de merges -- New-AdoClassicAksPlan.ps1
                # los agrega por defecto (EnableMergeBatching=$true), asi que
                # cualquier inventario "completo y real" de esta org los trae.
                @{ id = 'tg-evaluar-ventana'; name = 'Evaluar-ventana-agrupacion'; revision = 2 },
                @{ id = 'tg-gana-el-mas-nuevo'; name = 'Gana-el-mas-nuevo'; revision = 2 },
                @{ id = 'tg-reportar-resultado-hu'; name = 'Reportar-resultado-HU'; revision = 1 }
            )
            serviceConnections = @(
                @{ id = 'sc-acr'; name = 'ACR-Example'; type = 'dockerregistry'; isReady = $true },
                @{ id = 'sc-aks'; name = 'AKS-EXAMPLE-SVC'; type = 'kubernetes'; isReady = $true }
            )
            agentPools         = @(@{ id = 1; name = 'Azure Pipelines'; isHosted = $true })
            repositories       = @(@{ id = 'repo1'; name = 'project_ejemplo_api_demo'; defaultBranch = 'release'; branches = @('release', 'main') })
        }

        # D1: inventario incompleto (falta 'repositories')
        $incompleteInventory = Copy-OrderedHash -Source $baseInventory
        $incompleteInventory.Remove('repositories')
        $incompleteInventoryPath = Join-Path $testTempRoot 'inventory-incomplete.json'
        [PSCustomObject]$incompleteInventory | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $incompleteInventoryPath -Encoding utf8

        $planD1 = Join-Path $testTempRoot 'plan-d1.json'
        Copy-Item $aksPlanWithServiceName $planD1 -Force
        & powershell -NoProfile -File (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -PlanPath $planD1 -InventoryPath $incompleteInventoryPath | Out-Null
        $resultD1 = Get-Content -LiteralPath $planD1 -Raw | ConvertFrom-Json
        $mentionsIncomplete = @($resultD1.validationBlockers) -match 'incompleto'
        Add-Result -Name 'Test-AdoClassicPlan: inventario incompleto -> bloqueante + validated=false' `
            -Pass (($resultD1.validated -eq $false) -and $mentionsIncomplete) `
            -Detail "validated=$($resultD1.validated); blockers=$($resultD1.validationBlockers -join ' | ')"

        # D2: inventario de otra organizacion
        $wrongOrgInventory = Copy-OrderedHash -Source $baseInventory
        $wrongOrgInventory.organization = 'Otra-Organizacion'
        $wrongOrgInventoryPath = Join-Path $testTempRoot 'inventory-wrong-org.json'
        [PSCustomObject]$wrongOrgInventory | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $wrongOrgInventoryPath -Encoding utf8

        $planD2 = Join-Path $testTempRoot 'plan-d2.json'
        Copy-Item $aksPlanWithServiceName $planD2 -Force
        & powershell -NoProfile -File (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -PlanPath $planD2 -InventoryPath $wrongOrgInventoryPath | Out-Null
        $resultD2 = Get-Content -LiteralPath $planD2 -Raw | ConvertFrom-Json
        $mentionsWrongOrg = @($resultD2.validationBlockers) -match 'otra organizacion'
        Add-Result -Name 'Test-AdoClassicPlan: inventario de otra organizacion -> bloqueante + validated=false' `
            -Pass (($resultD2.validated -eq $false) -and $mentionsWrongOrg) `
            -Detail "validated=$($resultD2.validated); blockers=$($resultD2.validationBlockers -join ' | ')"

        # D3: inventario viejo (48h, limite default 24h)
        $staleInventory = Copy-OrderedHash -Source $baseInventory
        $staleInventory.generatedAtUtc = (Get-Date).ToUniversalTime().AddHours(-48).ToString('o')
        $staleInventoryPath = Join-Path $testTempRoot 'inventory-stale.json'
        [PSCustomObject]$staleInventory | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $staleInventoryPath -Encoding utf8

        $planD3 = Join-Path $testTempRoot 'plan-d3.json'
        Copy-Item $aksPlanWithServiceName $planD3 -Force
        & powershell -NoProfile -File (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -PlanPath $planD3 -InventoryPath $staleInventoryPath | Out-Null
        $resultD3 = Get-Content -LiteralPath $planD3 -Raw | ConvertFrom-Json
        $mentionsStale = @($resultD3.validationBlockers) -match 'antiguedad'
        Add-Result -Name 'Test-AdoClassicPlan: inventario viejo (48h > 24h limite) -> bloqueante + validated=false' `
            -Pass (($resultD3.validated -eq $false) -and $mentionsStale) `
            -Detail "validated=$($resultD3.validated); blockers=$($resultD3.validationBlockers -join ' | ')"

        # D4: inventario completo, fresco y matching -> validated=true + validationHash
        $freshInventoryPath = Join-Path $testTempRoot 'inventory-fresh.json'
        [PSCustomObject]$baseInventory | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $freshInventoryPath -Encoding utf8

        $planD4 = Join-Path $testTempRoot 'plan-d4.json'
        Copy-Item $aksPlanWithServiceName $planD4 -Force
        & powershell -NoProfile -File (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -PlanPath $planD4 -InventoryPath $freshInventoryPath | Out-Null
        $resultD4 = Get-Content -LiteralPath $planD4 -Raw | ConvertFrom-Json

        Add-Result -Name 'Test-AdoClassicPlan: inventario completo/fresco/matching -> validated=true' `
            -Pass ($resultD4.validated -eq $true) `
            -Detail "validated=$($resultD4.validated); blockers=$($resultD4.validationBlockers -join ' | ')"
        Add-Result -Name 'Test-AdoClassicPlan: validationHash es un SHA-256 (64 hex)' `
            -Pass ($resultD4.validationHash -match '^[0-9a-f]{64}$') `
            -Detail "validationHash='$($resultD4.validationHash)'"
        Add-Result -Name 'Test-AdoClassicPlan: repo.id resuelto en el plan' `
            -Pass ($resultD4.repo.id -eq 'repo1') `
            -Detail "repo.id='$($resultD4.repo.id)'"
        Add-Result -Name 'Test-AdoClassicPlan: dependencies.deployTaskGroup.id/revision resueltos' `
            -Pass ($resultD4.dependencies.deployTaskGroup.id -eq 'tg-deploy' -and $resultD4.dependencies.deployTaskGroup.revision -eq 5) `
            -Detail "id='$($resultD4.dependencies.deployTaskGroup.id)' revision=$($resultD4.dependencies.deployTaskGroup.revision)"

        # D5: inventario sin paginationComplete (o en false) -> bloqueante
        $noPaginationInventory = Copy-OrderedHash -Source $baseInventory
        $noPaginationInventory.paginationComplete = $false
        $noPaginationInventoryPath = Join-Path $testTempRoot 'inventory-no-pagination.json'
        [PSCustomObject]$noPaginationInventory | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $noPaginationInventoryPath -Encoding utf8

        $planD5b = Join-Path $testTempRoot 'plan-d5b.json'
        Copy-Item $aksPlanWithServiceName $planD5b -Force
        & powershell -NoProfile -File (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -PlanPath $planD5b -InventoryPath $noPaginationInventoryPath | Out-Null
        $resultD5b = Get-Content -LiteralPath $planD5b -Raw | ConvertFrom-Json
        $mentionsPagination = @($resultD5b.validationBlockers) -match 'paginationComplete'
        Add-Result -Name 'Test-AdoClassicPlan: inventario con paginationComplete=false -> bloqueante + validated=false' `
            -Pass (($resultD5b.validated -eq $false) -and $mentionsPagination) `
            -Detail "validated=$($resultD5b.validated); blockers=$($resultD5b.validationBlockers -join ' | ')"

        # D6: service connection con isReady=false -> bloqueante
        $notReadyInventory = Copy-OrderedHash -Source $baseInventory
        $notReadyInventory.serviceConnections = @(
            @{ id = 'sc-acr'; name = 'ACR-Example'; type = 'dockerregistry'; isReady = $false },
            @{ id = 'sc-aks'; name = 'AKS-EXAMPLE-SVC'; type = 'kubernetes'; isReady = $true }
        )
        $notReadyInventoryPath = Join-Path $testTempRoot 'inventory-not-ready.json'
        [PSCustomObject]$notReadyInventory | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $notReadyInventoryPath -Encoding utf8

        $planD6 = Join-Path $testTempRoot 'plan-d6.json'
        Copy-Item $aksPlanWithServiceName $planD6 -Force
        & powershell -NoProfile -File (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -PlanPath $planD6 -InventoryPath $notReadyInventoryPath | Out-Null
        $resultD6 = Get-Content -LiteralPath $planD6 -Raw | ConvertFrom-Json
        $mentionsNotReady = @($resultD6.validationBlockers) -match 'isReady=False'
        Add-Result -Name 'Test-AdoClassicPlan: service connection isReady=false -> bloqueante (no solo warning)' `
            -Pass (($resultD6.validated -eq $false) -and $mentionsNotReady) `
            -Detail "validated=$($resultD6.validated); blockers=$($resultD6.validationBlockers -join ' | ')"

        # D7: service connection ACR con type incorrecto -> bloqueante
        $wrongTypeInventory = Copy-OrderedHash -Source $baseInventory
        $wrongTypeInventory.serviceConnections = @(
            @{ id = 'sc-acr'; name = 'ACR-Example'; type = 'azurerm'; isReady = $true },
            @{ id = 'sc-aks'; name = 'AKS-EXAMPLE-SVC'; type = 'kubernetes'; isReady = $true }
        )
        $wrongTypeInventoryPath = Join-Path $testTempRoot 'inventory-wrong-type.json'
        [PSCustomObject]$wrongTypeInventory | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $wrongTypeInventoryPath -Encoding utf8

        $planD7 = Join-Path $testTempRoot 'plan-d7.json'
        Copy-Item $aksPlanWithServiceName $planD7 -Force
        & powershell -NoProfile -File (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -PlanPath $planD7 -InventoryPath $wrongTypeInventoryPath | Out-Null
        $resultD7 = Get-Content -LiteralPath $planD7 -Raw | ConvertFrom-Json
        $mentionsWrongType = @($resultD7.validationBlockers) -match "type='azurerm', se esperaba 'dockerregistry'"
        Add-Result -Name 'Test-AdoClassicPlan: service connection ACR con type != dockerregistry -> bloqueante' `
            -Pass (($resultD7.validated -eq $false) -and $mentionsWrongType) `
            -Detail "validated=$($resultD7.validated); blockers=$($resultD7.validationBlockers -join ' | ')"

        # D8: dos service connections con el mismo nombre -> bloqueante (ambiguo)
        $duplicateScInventory = Copy-OrderedHash -Source $baseInventory
        $duplicateScInventory.serviceConnections = @(
            @{ id = 'sc-acr-1'; name = 'ACR-Example'; type = 'dockerregistry'; isReady = $true },
            @{ id = 'sc-acr-2'; name = 'ACR-Example'; type = 'dockerregistry'; isReady = $true },
            @{ id = 'sc-aks'; name = 'AKS-EXAMPLE-SVC'; type = 'kubernetes'; isReady = $true }
        )
        $duplicateScInventoryPath = Join-Path $testTempRoot 'inventory-duplicate-sc.json'
        [PSCustomObject]$duplicateScInventory | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $duplicateScInventoryPath -Encoding utf8

        $planD8 = Join-Path $testTempRoot 'plan-d8.json'
        Copy-Item $aksPlanWithServiceName $planD8 -Force
        & powershell -NoProfile -File (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -PlanPath $planD8 -InventoryPath $duplicateScInventoryPath | Out-Null
        $resultD8 = Get-Content -LiteralPath $planD8 -Raw | ConvertFrom-Json
        $mentionsAmbiguousSc = @($resultD8.validationBlockers) -match 'nombre ambiguo'
        Add-Result -Name 'Test-AdoClassicPlan: dos service connections con el mismo nombre -> bloqueante' `
            -Pass (($resultD8.validated -eq $false) -and $mentionsAmbiguousSc) `
            -Detail "validated=$($resultD8.validated); blockers=$($resultD8.validationBlockers -join ' | ')"

        # D9: dos agent pools con el mismo nombre -> bloqueante (ambiguo).
        # Usa el plan DACPAC (agent pool obligatorio) para forzar la resolucion.
        $dacpacPlanPath = Join-Path $testTempRoot 'dacpac-for-pool-test.json'
        & powershell -NoProfile -File (Join-Path $scriptsRoot 'New-AdoClassicDatabasePlan.ps1') `
            -DatabaseProjectName 'sqldb_ejemplo' -DatabaseName 'ejemplo_db' `
            -RepoName 'project_sqldb_ejemplo' -ProdBranch 'release' `
            -BuildAgentPoolName 'pool-example-msbuild' `
            -OutDir $testTempRoot | Out-Null
        $generatedDacpac = Get-ChildItem $testTempRoot -Filter 'dacpac-sqldb_ejemplo-*.json' | Select-Object -Last 1
        if ($generatedDacpac) {
            Copy-Item $generatedDacpac.FullName $dacpacPlanPath -Force

            $duplicatePoolInventory = Copy-OrderedHash -Source $baseInventory
            $duplicatePoolInventory.agentPools = @(
                @{ id = 1; name = 'pool-example-msbuild'; isHosted = $false },
                @{ id = 2; name = 'pool-example-msbuild'; isHosted = $false }
            )
            $duplicatePoolInventory.repositories = @(@{ id = 'repo2'; name = 'project_sqldb_ejemplo'; defaultBranch = 'release'; branches = @('release') })
            $duplicatePoolInventory.taskGroups = @(
                @{ id = 'tg1'; name = 'Evaluar-ventana-agrupacion'; revision = 1 },
                @{ id = 'tg2'; name = 'Gana-el-mas-nuevo'; revision = 1 },
                @{ id = 'tg3'; name = 'Build-DataBases'; revision = 1 },
                @{ id = 'tg4'; name = 'Reportar-resultado-HU'; revision = 1 },
                @{ id = 'tg5'; name = 'Deployment-DataBases'; revision = 1 }
            )
            $duplicatePoolInventory.variableGroups = @(@{ id = 'vg1'; name = 'Bases Datos SQL'; type = 'Vsts'; variables = @{} })
            $duplicatePoolInventoryPath = Join-Path $testTempRoot 'inventory-duplicate-pool.json'
            [PSCustomObject]$duplicatePoolInventory | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $duplicatePoolInventoryPath -Encoding utf8

            & powershell -NoProfile -File (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -PlanPath $dacpacPlanPath -InventoryPath $duplicatePoolInventoryPath | Out-Null
            $resultD9 = Get-Content -LiteralPath $dacpacPlanPath -Raw | ConvertFrom-Json
            $mentionsAmbiguousPool = @($resultD9.validationBlockers) -match 'nombre ambiguo'
            Add-Result -Name 'Test-AdoClassicPlan: dos agent pools con el mismo nombre -> bloqueante' `
                -Pass (($resultD9.validated -eq $false) -and $mentionsAmbiguousPool) `
                -Detail "validated=$($resultD9.validated); blockers=$($resultD9.validationBlockers -join ' | ')"
        }
        else {
            Add-Result -Name 'Test-AdoClassicPlan: dos agent pools con el mismo nombre -> bloqueante' -Pass $false -Detail 'No se genero el plan DACPAC base.'
        }

        # ============================================================
        # Grupo E: hash de integridad -- deteccion de manipulacion posterior
        # ============================================================

        $planD5Tampered = Join-Path $testTempRoot 'plan-d5-tampered.json'
        Copy-Item $planD4 $planD5Tampered -Force
        $tamperedObj = Get-Content -LiteralPath $planD5Tampered -Raw | ConvertFrom-Json
        $tamperedObj.variableGroup.keys.namespace = 'namespace-modificado-despues-de-validar'
        $tamperedObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $planD5Tampered -Encoding utf8

        $reloadedTampered = Get-Content -LiteralPath $planD5Tampered -Raw | ConvertFrom-Json
        $recomputedHash = Get-AdoPlanCanonicalHash -Plan $reloadedTampered
        Add-Result -Name 'Hash: editar el plan validado despues cambia el hash recalculado' `
            -Pass ($recomputedHash -ne $reloadedTampered.validationHash) `
            -Detail "hashGuardado='$($reloadedTampered.validationHash)' hashRecalculado='$recomputedHash'"

        Invoke-ExpectThrow -Name 'Invoke-AdoRest: rechaza escritura sobre plan validado pero editado despues (hash no coincide)' `
            -ExpectedMessagePattern 'no coincide' -Block {
            Invoke-AdoRest -Method POST -Uri 'https://dev.azure.com/Shared-Service-GM/DevOps/_apis/distributedtask/variablegroups?api-version=7.1' `
                -Body @{ name = 'x' } -RequireApprovedPlan -PlanPath $planD5Tampered
        }

        # ============================================================
        # Grupo F: Apply-AdoClassicPlan.ps1 sobre plan totalmente validado
        # (D4, sin tamper) -- debe producir CERO llamadas de escritura,
        # incluso antes de tocar el Variable Group. Invoke-AdoClassicPlan.ps1
        # ya no acepta -Apply (dry-run exclusivo, ver Grupo C2 mas abajo).
        # ============================================================

        # Nota: BuildPhaseImplemented/ReleasePhaseImplemented ya estan en
        # true (fases implementadas y probadas -- ver Grupos P-V). El
        # plan D4 (generado por New-AdoClassicAksPlan.ps1) sigue teniendo
        # approvedOperations VACIO -- ningun generador de planes lo puebla
        # todavia (eso se hace a mano con New-AdoApprovedOperationEntry,
        # ver Grupo S/U) -- asi que Apply-AdoClassicPlan.ps1 debe salir
        # limpio (exit 0) sin crear nada, nunca "no implementado".
        $applyResult = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'Apply-AdoClassicPlan.ps1') -ScriptArgs @('-PlanPath', $planD4, '-InventoryPath', $freshInventoryPath)
        $applyExit = $applyResult.ExitCode
        $applyText = $applyResult.Text
        $noOpsToApply = $applyText -match 'no tiene ninguna operacion aprobada'
        $noVariableGroupCreatedMessage = $applyText -notmatch 'Variable Group creado:'
        Add-Result -Name 'Apply-AdoClassicPlan: plan con approvedOperations vacio -> nada que aplicar, cero POST' `
            -Pass ($applyExit -eq 0 -and $noOpsToApply -and $noVariableGroupCreatedMessage) `
            -Detail "exit=$applyExit; noOpsToApply=$noOpsToApply; sinVGCreado=$noVariableGroupCreatedMessage"

        # Dry-run sigue funcionando sin aprobacion ni escrituras
        $dryRunResult = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'Invoke-AdoClassicPlan.ps1') -ScriptArgs @('-PlanPath', $planD4)
        Add-Result -Name 'Invoke-AdoClassicPlan: dry-run sigue funcionando (exit 0, sin cambios)' `
            -Pass ($dryRunResult.ExitCode -eq 0 -and $dryRunResult.Text -match 'DRY-RUN') `
            -Detail "exit=$($dryRunResult.ExitCode)"

        # Invoke-AdoClassicPlan.ps1 ya no declara -Apply: pasarlo debe
        # fallar como parametro desconocido, nunca aplicar nada en silencio.
        $legacyApplyResult = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'Invoke-AdoClassicPlan.ps1') -ScriptArgs @('-PlanPath', $planD4, '-Apply')
        Add-Result -Name 'Invoke-AdoClassicPlan: -Apply ya no existe como parametro (falla, no aplica en silencio)' `
            -Pass ($legacyApplyResult.ExitCode -ne 0) `
            -Detail "exit=$($legacyApplyResult.ExitCode); texto=$($legacyApplyResult.Text.Substring(0, [Math]::Min(200, $legacyApplyResult.Text.Length)))"
    }
    else {
        Add-Result -Name 'Grupo D/E/F: requieren el plan con ServiceName del Grupo C' -Pass $false -Detail 'Plan base no disponible, se omiten estos grupos.'
    }

    # ============================================================
    # Grupo G: verificacion estatica de proteccion contra redirecciones
    # (no se dispara una redireccion real: Assert-AdoAllowedUri ya
    # rechaza cualquier host que no sea de esta org, asi que una
    # redireccion HTTP real solo puede probarse contra los hosts
    # autorizados con credenciales reales -- fuera de alcance de una
    # prueba local sin PAT. Se verifica en cambio que el codigo fuerza
    # MaximumRedirection=0 para toda llamada, para que ninguna
    # redireccion se siga sin revalidar.)
    # ============================================================

    $restSource = Get-Content -LiteralPath (Join-Path $scriptsRoot 'Invoke-AdoRest.ps1') -Raw
    Add-Result -Name 'Invoke-AdoRest: fuerza MaximumRedirection=0 en toda llamada (verificacion estatica)' `
        -Pass ($restSource -match 'MaximumRedirection\s*=\s*0') `
        -Detail 'Revision de codigo fuente; no se disparo una redireccion real (requeriria contactar un host autorizado con PAT real, fuera de alcance de esta prueba).'

    # ============================================================
    # Grupo H: Get-AdoRestAllPages -- paginacion simulada de dos paginas
    # (nunca red real). Se reemplaza Invoke-AdoRest por una version
    # simulada que devuelve paginas ya preparadas en memoria; como
    # Get-AdoRestAllPages fue dot-sourceada en este mismo scope, al
    # redefinir la funcion en este mismo scope la nueva definicion
    # reemplaza a la real para las llamadas que haga Get-AdoRestAllPages.
    # ============================================================

    function Set-MockAdoPages {
        param([array]$Pages)  # cada elemento: @{ Items = @(...); NextToken = 'x' o $null }
        $script:mockPages = $Pages
        $script:mockCallIndex = 0
    }

    function Invoke-AdoRest {
        param([string]$Method, [string]$Uri, $Body, [switch]$RequireApprovedPlan, [string]$PlanPath)
        if ($script:mockCallIndex -ge $script:mockPages.Count) {
            throw "Mock de Invoke-AdoRest: se pidieron mas paginas ($($script:mockCallIndex + 1)) de las simuladas ($($script:mockPages.Count))."
        }
        $page = $script:mockPages[$script:mockCallIndex]
        $script:mockCallIndex++
        $headers = @{}
        if ($page.NextToken) { $headers['x-ms-continuationtoken'] = $page.NextToken }
        return [PSCustomObject]@{
            Body       = [PSCustomObject]@{ value = $page.Items }
            Headers    = $headers
            StatusCode = 200
        }
    }

    # H1: dos paginas se fusionan correctamente (item que solo esta en pagina 2)
    Set-MockAdoPages -Pages @(
        @{ Items = @(@{ id = 1; name = 'SoloEnPagina1' }); NextToken = 'token-a' },
        @{ Items = @(@{ id = 2; name = 'SoloEnPagina2' }); NextToken = $null }
    )
    $twoPageResult = Get-AdoRestAllPages -BaseUri 'https://dev.azure.com/Shared-Service-GM/DevOps/_apis/build/definitions?api-version=7.1'
    $mergedNames = @($twoPageResult.Items | ForEach-Object { $_.name })
    Add-Result -Name 'Get-AdoRestAllPages: fusiona 2 paginas (item solo en pagina 2 aparece en el resultado)' `
        -Pass ($twoPageResult.PagesFetched -eq 2 -and $mergedNames -contains 'SoloEnPagina1' -and $mergedNames -contains 'SoloEnPagina2') `
        -Detail "PagesFetched=$($twoPageResult.PagesFetched); items=$($mergedNames -join ',')"

    # H2: definicion de Build duplicada SOLO en pagina 2 -- Test-AdoClassicPlan
    # debe detectarla igual (prueba que no se corta en la primera pagina).
    Set-MockAdoPages -Pages @(
        @{ Items = @(@{ id = 'other'; name = 'Build-Otro-Producto' }); NextToken = 'token-b1' },
        @{ Items = @(@{ id = 'dup'; name = 'Build-Ejemplo-Api-Demo-Visual' }); NextToken = $null }
    )
    $buildDefsTwoPages = Get-AdoRestAllPages -BaseUri 'https://dev.azure.com/Shared-Service-GM/DevOps/_apis/build/definitions?api-version=7.1'

    if (Test-Path -LiteralPath $aksPlanWithServiceName) {
        $dupInventory = Copy-OrderedHash -Source $baseInventory
        $dupInventory.buildDefinitions = @($buildDefsTwoPages.Items)
        $dupInventoryPath = Join-Path $testTempRoot 'inventory-dup-page2.json'
        [PSCustomObject]$dupInventory | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $dupInventoryPath -Encoding utf8

        $planH2 = Join-Path $testTempRoot 'plan-h2.json'
        Copy-Item $aksPlanWithServiceName $planH2 -Force
        # Test-AdoClassicPlan.ps1 corre en un proceso hijo real (no usa el
        # mock, lee el archivo de inventario ya fusionado que si vino de
        # paginacion simulada), asi que esto SIGUE sin tocar la red.
        & powershell -NoProfile -File (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -PlanPath $planH2 -InventoryPath $dupInventoryPath | Out-Null
        $resultH2 = Get-Content -LiteralPath $planH2 -Raw | ConvertFrom-Json
        $mentionsDupBuild = @($resultH2.validationBlockers) -match 'posible duplicado'
        Add-Result -Name 'Paginacion: definicion de Build duplicada SOLO en pagina 2 -> detectada como bloqueante' `
            -Pass (($resultH2.validated -eq $false) -and $mentionsDupBuild) `
            -Detail "validated=$($resultH2.validated); blockers=$($resultH2.validationBlockers -join ' | ')"

        # H3: branch requerida SOLO en pagina 2 de refs -- el repo se resuelve igual.
        Set-MockAdoPages -Pages @(
            @{ Items = @(@{ name = 'refs/heads/development' }); NextToken = 'token-c1' },
            @{ Items = @(@{ name = 'refs/heads/release' }); NextToken = $null }
        )
        $refsTwoPages = Get-AdoRestAllPages -BaseUri 'https://dev.azure.com/Shared-Service-GM/DevOps/_apis/git/repositories/repo1/refs?filter=heads/&api-version=7.1'
        $branchesFromPages = @($refsTwoPages.Items | ForEach-Object { $_.name -replace '^refs/heads/', '' })

        $branchInventory = Copy-OrderedHash -Source $baseInventory
        $branchInventory.repositories = @(@{ id = 'repo1'; name = 'project_ejemplo_api_demo'; defaultBranch = 'release'; branches = $branchesFromPages })
        $branchInventoryPath = Join-Path $testTempRoot 'inventory-branch-page2.json'
        [PSCustomObject]$branchInventory | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $branchInventoryPath -Encoding utf8

        $planH3 = Join-Path $testTempRoot 'plan-h3.json'
        Copy-Item $aksPlanWithServiceName $planH3 -Force
        & powershell -NoProfile -File (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -PlanPath $planH3 -InventoryPath $branchInventoryPath | Out-Null
        $resultH3 = Get-Content -LiteralPath $planH3 -Raw | ConvertFrom-Json
        # OJO: "@(...) -notmatch 'x'" sobre un array VACIO devuelve @()
        # (falsy), no $true -- por eso se niega el resultado de -match en
        # vez de usar -notmatch directamente sobre la coleccion.
        Add-Result -Name 'Paginacion: branch requerida SOLO en pagina 2 de refs -> repo/branch resueltos igual' `
            -Pass ($resultH3.repo.id -eq 'repo1' -and -not (@($resultH3.validationBlockers) -match 'no existe en el repositorio')) `
            -Detail "repo.id='$($resultH3.repo.id)'; blockers=$($resultH3.validationBlockers -join ' | ')"

        # H4: task group SOLO en pagina 2 -- se resuelve id/revision igual.
        Set-MockAdoPages -Pages @(
            @{ Items = @(@{ id = 'tg-other'; name = 'Otro-Task-Group'; revision = 1 }); NextToken = 'token-d1' },
            @{ Items = @(@{ id = 'tg-build'; name = 'Build'; revision = 3 }, @{ id = 'tg-deploy'; name = 'Deployment-Azur-Aks-v3'; revision = 5 }); NextToken = $null }
        )
        $taskGroupsTwoPages = Get-AdoRestAllPages -BaseUri 'https://dev.azure.com/Shared-Service-GM/DevOps/_apis/distributedtask/taskgroups?api-version=7.1'

        $tgInventory = Copy-OrderedHash -Source $baseInventory
        $tgInventory.taskGroups = @($taskGroupsTwoPages.Items)
        $tgInventoryPath = Join-Path $testTempRoot 'inventory-taskgroup-page2.json'
        [PSCustomObject]$tgInventory | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tgInventoryPath -Encoding utf8

        $planH4 = Join-Path $testTempRoot 'plan-h4.json'
        Copy-Item $aksPlanWithServiceName $planH4 -Force
        & powershell -NoProfile -File (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -PlanPath $planH4 -InventoryPath $tgInventoryPath | Out-Null
        $resultH4 = Get-Content -LiteralPath $planH4 -Raw | ConvertFrom-Json
        Add-Result -Name 'Paginacion: task group deploy SOLO en pagina 2 -> id/revision resueltos igual' `
            -Pass ($resultH4.dependencies.deployTaskGroup.id -eq 'tg-deploy' -and $resultH4.dependencies.deployTaskGroup.revision -eq 5) `
            -Detail "id='$($resultH4.dependencies.deployTaskGroup.id)' revision=$($resultH4.dependencies.deployTaskGroup.revision)"
    }
    else {
        Add-Result -Name 'Grupo H2-H4: requieren el plan con ServiceName del Grupo C' -Pass $false -Detail 'Plan base no disponible.'
    }

    # H5: continuation token faltante -> se detiene tras 1 pagina (caso base)
    Set-MockAdoPages -Pages @(
        @{ Items = @(@{ id = 1; name = 'UnicaPagina' }); NextToken = $null }
    )
    $singlePageResult = Get-AdoRestAllPages -BaseUri 'https://dev.azure.com/Shared-Service-GM/DevOps/_apis/build/definitions?api-version=7.1'
    Add-Result -Name 'Paginacion: token de continuacion ausente -> se detiene tras 1 pagina' `
        -Pass ($singlePageResult.PagesFetched -eq 1 -and $singlePageResult.Items.Count -eq 1) `
        -Detail "PagesFetched=$($singlePageResult.PagesFetched)"

    # H6: ciclo de continuation tokens -> throw explicito, nunca bucle infinito
    Set-MockAdoPages -Pages @(
        @{ Items = @(@{ id = 1; name = 'Pagina1' }); NextToken = 'token-cyclico' },
        @{ Items = @(@{ id = 2; name = 'Pagina2' }); NextToken = 'token-cyclico' },
        @{ Items = @(@{ id = 3; name = 'Pagina3-nunca-deberia-llegar' }); NextToken = $null }
    )
    Invoke-ExpectThrow -Name 'Paginacion: ciclo de continuation tokens -> throw (no bucle infinito)' `
        -ExpectedMessagePattern 'ciclo de continuation tokens' -Block {
        Get-AdoRestAllPages -BaseUri 'https://dev.azure.com/Shared-Service-GM/DevOps/_apis/build/definitions?api-version=7.1'
    }

    # H7: se supera el limite de paginas -> throw explicito ANTES de la
    # llamada adicional (red de seguridad adicional al detector de
    # ciclos, para tokens siempre distintos pero que nunca terminan).
    # Con MaxPages=3, nunca debe llegarse a una 4a llamada real -- se
    # verifica leyendo mockCallIndex (cuantas paginas del mock realmente
    # se consumieron) despues del throw.
    $manyPages = 1..5 | ForEach-Object {
        $isLast = $_ -eq 5
        @{ Items = @(@{ id = $_; name = "Pagina$_" }); NextToken = $(if ($isLast) { $null } else { "token-unico-$_" }) }
    }
    Set-MockAdoPages -Pages $manyPages
    Invoke-ExpectThrow -Name 'Paginacion: se supera -MaxPages=3 -> throw explicito ANTES de una 4a llamada' `
        -ExpectedMessagePattern 'se alcanzo el limite de' -Block {
        Get-AdoRestAllPages -BaseUri 'https://dev.azure.com/Shared-Service-GM/DevOps/_apis/build/definitions?api-version=7.1' -MaxPages 3
    }
    Add-Result -Name 'Paginacion: MaxPages=3 -> exactamente 3 llamadas reales, nunca una 4a' `
        -Pass ($script:mockCallIndex -eq 3) `
        -Detail "mockCallIndex (llamadas reales consumidas)=$($script:mockCallIndex)"

    # H8: -MaxPages=0 rechazado (debe ser al menos 1), sin llegar a llamar
    # a Invoke-AdoRest ni una sola vez.
    Set-MockAdoPages -Pages @(@{ Items = @(@{ id = 1; name = 'NuncaSeDeberiaPedir' }); NextToken = $null })
    Invoke-ExpectThrow -Name 'Paginacion: -MaxPages=0 rechazado (minimo 1)' `
        -ExpectedMessagePattern 'MaxPages debe ser al menos 1' -Block {
        Get-AdoRestAllPages -BaseUri 'https://dev.azure.com/Shared-Service-GM/DevOps/_apis/build/definitions?api-version=7.1' -MaxPages 0
    }
    Add-Result -Name 'Paginacion: -MaxPages=0 -> cero llamadas reales (rechazado antes de la primera)' `
        -Pass ($script:mockCallIndex -eq 0) `
        -Detail "mockCallIndex=$($script:mockCallIndex)"

    # H9: dos paginas validas -- caso base sin errores.
    Set-MockAdoPages -Pages @(
        @{ Items = @(@{ id = 1; name = 'Pag1' }); NextToken = 'token-x' },
        @{ Items = @(@{ id = 2; name = 'Pag2' }); NextToken = $null }
    )
    $twoValidPages = Get-AdoRestAllPages -BaseUri 'https://dev.azure.com/Shared-Service-GM/DevOps/_apis/build/definitions?api-version=7.1'
    Add-Result -Name 'Paginacion: dos paginas validas -> 2 fetches, 2 items' `
        -Pass ($twoValidPages.PagesFetched -eq 2 -and $twoValidPages.Items.Count -eq 2) `
        -Detail "PagesFetched=$($twoValidPages.PagesFetched); Items=$($twoValidPages.Items.Count)"

    # ============================================================
    # Grupo I: Get-AdoRestAllPages -- respuestas malformadas SIEMPRE
    # rechazadas con throw, nunca aceptadas "por si acaso" como pagina
    # vacia valida.
    # ============================================================

    function Set-MockAdoRawResponses {
        # Variante del mock que devuelve respuestas RAW (Body/Headers/
        # StatusCode ya armados tal cual los devolveria Invoke-AdoRest),
        # para simular respuestas malformadas que Get-AdoRestAllPages
        # debe rechazar (body nulo, sin 'value', 'value' con formato
        # invalido, StatusCode no exitoso).
        param([array]$Responses)
        $script:mockRawResponses = $Responses
        $script:mockRawCallIndex = 0
    }

    function Invoke-AdoRest {
        param([string]$Method, [string]$Uri, $Body, [switch]$RequireApprovedPlan, [string]$PlanPath, [string]$OperationId)
        if ($script:mockRawCallIndex -ge $script:mockRawResponses.Count) {
            throw "Mock: se pidieron mas respuestas de las simuladas."
        }
        $r = $script:mockRawResponses[$script:mockRawCallIndex]
        $script:mockRawCallIndex++
        return [PSCustomObject]@{ Body = $r.Body; Headers = $(if ($r.Headers) { $r.Headers } else { @{} }); StatusCode = $(if ($r.StatusCode) { $r.StatusCode } else { 200 }) }
    }

    Set-MockAdoRawResponses -Responses @(@{ Body = $null; StatusCode = 200 })
    Invoke-ExpectThrow -Name 'Get-AdoRestAllPages: body nulo -> throw (no se acepta como pagina vacia)' `
        -ExpectedMessagePattern 'body nulo' -Block {
        Get-AdoRestAllPages -BaseUri 'https://dev.azure.com/Shared-Service-GM/DevOps/_apis/build/definitions?api-version=7.1'
    }

    Set-MockAdoRawResponses -Responses @(@{ Body = [PSCustomObject]@{ count = 0 }; StatusCode = 200 })
    Invoke-ExpectThrow -Name "Get-AdoRestAllPages: body sin 'value' -> throw" `
        -ExpectedMessagePattern "no tiene la propiedad 'value'" -Block {
        Get-AdoRestAllPages -BaseUri 'https://dev.azure.com/Shared-Service-GM/DevOps/_apis/build/definitions?api-version=7.1'
    }

    Set-MockAdoRawResponses -Responses @(@{ Body = [PSCustomObject]@{ value = @() }; StatusCode = 200 })
    Invoke-ExpectNoThrow -Name "Get-AdoRestAllPages: 'value':[] (array vacio) -> aceptado como pagina valida" -Block {
        $r = Get-AdoRestAllPages -BaseUri 'https://dev.azure.com/Shared-Service-GM/DevOps/_apis/build/definitions?api-version=7.1'
        if ($r.Items.Count -ne 0) { throw "Se esperaban 0 items, hubo $($r.Items.Count)." }
    }

    Set-MockAdoRawResponses -Responses @(@{ Body = [PSCustomObject]@{ value = 'esto-es-un-string-no-una-coleccion' }; StatusCode = 200 })
    Invoke-ExpectThrow -Name "Get-AdoRestAllPages: 'value' es un string -> throw (formato incompatible)" `
        -ExpectedMessagePattern 'formato incompatible con una coleccion' -Block {
        Get-AdoRestAllPages -BaseUri 'https://dev.azure.com/Shared-Service-GM/DevOps/_apis/build/definitions?api-version=7.1'
    }

    Set-MockAdoRawResponses -Responses @(@{ Body = [PSCustomObject]@{ value = 42 }; StatusCode = 200 })
    Invoke-ExpectThrow -Name "Get-AdoRestAllPages: 'value' es un numero -> throw (formato incompatible)" `
        -ExpectedMessagePattern 'formato incompatible con una coleccion' -Block {
        Get-AdoRestAllPages -BaseUri 'https://dev.azure.com/Shared-Service-GM/DevOps/_apis/build/definitions?api-version=7.1'
    }

    Set-MockAdoRawResponses -Responses @(@{ Body = [PSCustomObject]@{ value = $null }; StatusCode = 200 })
    Invoke-ExpectThrow -Name "Get-AdoRestAllPages: 'value' es null -> throw (formato incompatible)" `
        -ExpectedMessagePattern 'formato incompatible con una coleccion' -Block {
        Get-AdoRestAllPages -BaseUri 'https://dev.azure.com/Shared-Service-GM/DevOps/_apis/build/definitions?api-version=7.1'
    }

    Set-MockAdoRawResponses -Responses @(@{ Body = [PSCustomObject]@{ value = @(@{ id = 1 }) }; StatusCode = 404 })
    Invoke-ExpectThrow -Name 'Get-AdoRestAllPages: StatusCode no exitoso (404) -> throw' `
        -ExpectedMessagePattern 'codigo HTTP no exitoso' -Block {
        Get-AdoRestAllPages -BaseUri 'https://dev.azure.com/Shared-Service-GM/DevOps/_apis/build/definitions?api-version=7.1'
    }

    # ============================================================
    # Grupo J: manifiesto de operaciones aprobadas (approvedOperations) --
    # Invoke-AdoRest debe rechazar toda escritura que no coincida EXACTO
    # con method+uri+bodyHash de una operacion no consumida, con datos
    # 100% ficticios, sin tocar la red.
    # ============================================================

    . (Join-Path $scriptsRoot 'Invoke-AdoRest.ps1')  # restaura la version REAL (no mockeada) para este grupo

    function New-FakeApprovedPlan {
        param([array]$ApprovedOperations, [bool]$Validated = $true)
        $planObj = [PSCustomObject]@{
            family             = 'aks'
            organization       = 'Shared-Service-GM'
            project            = 'DevOps'
            approvedOperations = $ApprovedOperations
            validated          = $false
            validationHash     = $null
        }
        $planObj.validated = $Validated
        if ($Validated) {
            $planObj.validationHash = Get-AdoPlanCanonicalHash -Plan $planObj
        }
        $planPath = Join-Path $testTempRoot ("fake-approved-plan-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
        $planObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $planPath -Encoding utf8
        return $planPath
    }

    $approvedUri = 'https://dev.azure.com/Shared-Service-GM/DevOps/_apis/distributedtask/variablegroups?api-version=7.1'
    $approvedBody = @{ name = 'Produccion-Ejemplo-Ficticio'; type = 'Vsts'; variables = @{} }
    $approvedBodyHash = Get-AdoBodyCanonicalHash -Body $approvedBody

    $goodOp = @{ operationId = 'create-vg-ejemplo'; operationType = 'create-variable-group'; method = 'POST'; uri = $approvedUri; bodyHash = $approvedBodyHash }

    # J1: sin approvedOperations -> rechazado
    $planNoOps = New-FakeApprovedPlan -ApprovedOperations @()
    Invoke-ExpectThrow -Name 'approvedOperations: plan sin ninguna operacion aprobada -> rechazado' `
        -ExpectedMessagePattern 'no tiene approvedOperations' -Block {
        Invoke-AdoRest -Method POST -Uri $approvedUri -Body $approvedBody -RequireApprovedPlan -PlanPath $planNoOps -OperationId 'create-vg-ejemplo'
    }

    # J2: operacion inexistente (operationId que no esta en el manifiesto)
    $planWithGoodOp = New-FakeApprovedPlan -ApprovedOperations @($goodOp)
    Invoke-ExpectThrow -Name 'approvedOperations: operationId inexistente -> rechazado' `
        -ExpectedMessagePattern 'no existe la operacion' -Block {
        Invoke-AdoRest -Method POST -Uri $approvedUri -Body $approvedBody -RequireApprovedPlan -PlanPath $planWithGoodOp -OperationId 'operacion-que-no-existe'
    }

    # J3: URI distinta a la aprobada
    $planForUriTest = New-FakeApprovedPlan -ApprovedOperations @($goodOp)
    Invoke-ExpectThrow -Name 'approvedOperations: URI distinta a la aprobada -> rechazado' `
        -ExpectedMessagePattern 'la URI aprobada' -Block {
        Invoke-AdoRest -Method POST -Uri 'https://dev.azure.com/Shared-Service-GM/DevOps/_apis/build/definitions?api-version=7.1' -Body $approvedBody -RequireApprovedPlan -PlanPath $planForUriTest -OperationId 'create-vg-ejemplo'
    }

    # J4: metodo distinto al aprobado
    $planForMethodTest = New-FakeApprovedPlan -ApprovedOperations @($goodOp)
    Invoke-ExpectThrow -Name 'approvedOperations: metodo distinto al aprobado -> rechazado' `
        -ExpectedMessagePattern 'el metodo aprobado' -Block {
        Invoke-AdoRest -Method DELETE -Uri $approvedUri -Body $approvedBody -RequireApprovedPlan -PlanPath $planForMethodTest -OperationId 'create-vg-ejemplo'
    }

    # J5: body modificado (bodyHash ya no coincide)
    $planForBodyTest = New-FakeApprovedPlan -ApprovedOperations @($goodOp)
    Invoke-ExpectThrow -Name 'approvedOperations: body modificado (bodyHash no coincide) -> rechazado' `
        -ExpectedMessagePattern 'bodyHash aprobado' -Block {
        Invoke-AdoRest -Method POST -Uri $approvedUri -Body @{ name = 'Produccion-Ejemplo-Ficticio-MODIFICADO'; type = 'Vsts'; variables = @{} } -RequireApprovedPlan -PlanPath $planForBodyTest -OperationId 'create-vg-ejemplo'
    }

    # J6: hash incorrecto directamente en el manifiesto (bodyHash no es un SHA-256 real del body declarado)
    $badHashOp = @{ operationId = 'create-vg-hash-malo'; operationType = 'create-variable-group'; method = 'POST'; uri = $approvedUri; bodyHash = ('0' * 64) }
    $planForBadHash = New-FakeApprovedPlan -ApprovedOperations @($badHashOp)
    Invoke-ExpectThrow -Name 'approvedOperations: bodyHash del manifiesto no coincide con el body real -> rechazado' `
        -ExpectedMessagePattern 'bodyHash aprobado' -Block {
        Invoke-AdoRest -Method POST -Uri $approvedUri -Body $approvedBody -RequireApprovedPlan -PlanPath $planForBadHash -OperationId 'create-vg-hash-malo'
    }

    # J7: "reutilizar una operacion ya consumida" -- el mecanismo que
    # decidia esto (marcar consumed/consumedAtUtc REESCRIBIENDO el
    # archivo de plan) fue eliminado (invalidaba validationHash para el
    # resto de las operaciones de un plan multi-operacion). El
    # equivalente ahora es el JOURNAL de ejecucion, separado del plan --
    # ver Grupo M (journal de ejecucion) mas abajo, que cubre reintento
    # bloqueado, concurrencia, estados ambiguous/in-progress y la
    # inmutabilidad del archivo de plan de punta a punta.

    # J8: falta -OperationId por completo
    $planForNoOpId = New-FakeApprovedPlan -ApprovedOperations @($goodOp)
    Invoke-ExpectThrow -Name 'approvedOperations: falta -OperationId -> rechazado' `
        -ExpectedMessagePattern 'falta -OperationId' -Block {
        Invoke-AdoRest -Method POST -Uri $approvedUri -Body $approvedBody -RequireApprovedPlan -PlanPath $planForNoOpId
    }

    # J9: Test-AdoClassicPlan.ps1 valida la FORMA de approvedOperations
    # (duplicados, uri no autorizada, bodyHash con forma invalida)
    if (Test-Path -LiteralPath $aksPlanWithServiceName) {
        $planJ9Base = Get-Content -LiteralPath $aksPlanWithServiceName -Raw | ConvertFrom-Json
        $planJ9Base | Add-Member -NotePropertyName 'approvedOperations' -NotePropertyValue @(
            @{ operationId = 'dup'; method = 'POST'; uri = $approvedUri; bodyHash = ('a' * 64) },
            @{ operationId = 'dup'; method = 'POST'; uri = $approvedUri; bodyHash = ('b' * 64) }
        ) -Force
        $planJ9Path = Join-Path $testTempRoot 'plan-j9-duplicate-opid.json'
        $planJ9Base | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $planJ9Path -Encoding utf8
        & powershell -NoProfile -File (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -PlanPath $planJ9Path | Out-Null
        $resultJ9 = Get-Content -LiteralPath $planJ9Path -Raw | ConvertFrom-Json
        $mentionsDupOpId = @($resultJ9.validationBlockers) -match 'operationId duplicado'
        Add-Result -Name 'Test-AdoClassicPlan: approvedOperations con operationId duplicado -> bloqueante' `
            -Pass (($resultJ9.validated -eq $false) -and $mentionsDupOpId) `
            -Detail "blockers=$($resultJ9.validationBlockers -join ' | ')"

        $planJ10Base = Get-Content -LiteralPath $aksPlanWithServiceName -Raw | ConvertFrom-Json
        $planJ10Base | Add-Member -NotePropertyName 'approvedOperations' -NotePropertyValue @(
            @{ operationId = 'uri-mala'; operationType = 'create-variable-group'; method = 'POST'; uri = 'https://evil.example.invalid/robar-datos'; bodyHash = ('a' * 64) }
        ) -Force
        $planJ10Path = Join-Path $testTempRoot 'plan-j10-bad-uri.json'
        $planJ10Base | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $planJ10Path -Encoding utf8
        & powershell -NoProfile -File (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -PlanPath $planJ10Path | Out-Null
        $resultJ10 = Get-Content -LiteralPath $planJ10Path -Raw | ConvertFrom-Json
        $mentionsBadUri = @($resultJ10.validationBlockers) -match 'no es una URI autorizada'
        Add-Result -Name 'Test-AdoClassicPlan: approvedOperations con uri no autorizada -> bloqueante' `
            -Pass (($resultJ10.validated -eq $false) -and $mentionsBadUri) `
            -Detail "blockers=$($resultJ10.validationBlockers -join ' | ')"
    }
    else {
        Add-Result -Name 'Grupo J9-J10: requieren el plan con ServiceName del Grupo C' -Pass $false -Detail 'Plan base no disponible.'
    }

    # ============================================================
    # Grupo N: Test-AdoClassicPlan.ps1 -- operationType exacto en
    # approvedOperations (item 3). Cada entrada debe ser EXACTAMENTE una
    # de las 3 operaciones POST permitidas, en la URI exacta (sin id de
    # recurso, sin query extra), method=POST siempre, y apropiada para la
    # familia del plan. Todo con datos ficticios, sin red real.
    # ============================================================

    function Test-PlanWithApprovedOp {
        param([string]$PlanTemplatePath, $Op)
        $planObj = Get-Content -LiteralPath $PlanTemplatePath -Raw | ConvertFrom-Json
        $planObj | Add-Member -NotePropertyName 'approvedOperations' -NotePropertyValue @($Op) -Force
        $path = Join-Path $testTempRoot ("plan-n-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
        $planObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
        & powershell -NoProfile -File (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -PlanPath $path | Out-Null
        return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    }

    if (Test-Path -LiteralPath $aksPlanWithServiceName) {

        $vgUri = 'https://dev.azure.com/Shared-Service-GM/DevOps/_apis/distributedtask/variablegroups?api-version=7.1'
        $buildDefUri = 'https://dev.azure.com/Shared-Service-GM/DevOps/_apis/build/definitions?api-version=7.1'
        $releaseDefUri = 'https://vsrm.dev.azure.com/Shared-Service-GM/DevOps/_apis/release/definitions?api-version=7.1'
        $fakeHash64 = ('a' * 64)

        # N1: los 3 operationType exactos, URI exacta, method POST -> SIN bloqueante de forma
        $n1Ops = @(
            @{ operationId = 'n1-vg'; operationType = 'create-variable-group'; method = 'POST'; uri = $vgUri; bodyHash = $fakeHash64 },
            @{ operationId = 'n1-build'; operationType = 'create-build-definition'; method = 'POST'; uri = $buildDefUri; bodyHash = $fakeHash64 },
            @{ operationId = 'n1-release'; operationType = 'create-release-definition'; method = 'POST'; uri = $releaseDefUri; bodyHash = $fakeHash64 }
        )
        $planObjN1 = Get-Content -LiteralPath $aksPlanWithServiceName -Raw | ConvertFrom-Json
        $planObjN1 | Add-Member -NotePropertyName 'approvedOperations' -NotePropertyValue $n1Ops -Force
        $pathN1 = Join-Path $testTempRoot 'plan-n1.json'
        $planObjN1 | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $pathN1 -Encoding utf8
        & powershell -NoProfile -File (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -PlanPath $pathN1 | Out-Null
        $resultN1 = Get-Content -LiteralPath $pathN1 -Raw | ConvertFrom-Json
        $n1NoOpTypeBlockers = -not (@($resultN1.validationBlockers) -match 'operationType')
        Add-Result -Name 'operationType: los 3 tipos exactos con URI/method correctos -> sin bloqueante de forma' `
            -Pass $n1NoOpTypeBlockers `
            -Detail "blockers=$($resultN1.validationBlockers -join ' | ')"

        # N2: operationType invalido/desconocido -> bloqueante. Usa un
        # nombre que nunca va a coincidir con un operationType real
        # (a diferencia de 'delete-build-definition', que dejo de servir
        # como ejemplo de "desconocido" el 2026-08-26 al agregarse como
        # tipo valido de verdad -- ver Grupo R-DELETE).
        $resultN2 = Test-PlanWithApprovedOp -PlanTemplatePath $aksPlanWithServiceName -Op @{ operationId = 'n2'; operationType = 'archivar-build-definition'; method = 'POST'; uri = $buildDefUri; bodyHash = $fakeHash64 }
        Add-Result -Name 'operationType: desconocido -> bloqueante' `
            -Pass ([bool](@($resultN2.validationBlockers) -match 'operationType debe ser uno de')) `
            -Detail "blockers=$($resultN2.validationBlockers -join ' | ')"

        # N3: operationType ausente -> bloqueante
        $resultN3 = Test-PlanWithApprovedOp -PlanTemplatePath $aksPlanWithServiceName -Op @{ operationId = 'n3'; method = 'POST'; uri = $buildDefUri; bodyHash = $fakeHash64 }
        Add-Result -Name 'operationType: ausente -> bloqueante' `
            -Pass ([bool](@($resultN3.validationBlockers) -match 'operationType debe ser uno de')) `
            -Detail "blockers=$($resultN3.validationBlockers -join ' | ')"

        # N4: method GET en el manifiesto -> bloqueante (nunca se acepta una lectura como "operacion aprobada")
        $resultN4 = Test-PlanWithApprovedOp -PlanTemplatePath $aksPlanWithServiceName -Op @{ operationId = 'n4'; operationType = 'create-build-definition'; method = 'GET'; uri = $buildDefUri; bodyHash = $fakeHash64 }
        Add-Result -Name 'operationType: method GET -> bloqueante (debe ser POST)' `
            -Pass ([bool](@($resultN4.validationBlockers) -match "method debe ser 'POST'")) `
            -Detail "blockers=$($resultN4.validationBlockers -join ' | ')"

        # N5: method PUT -> bloqueante
        $resultN5 = Test-PlanWithApprovedOp -PlanTemplatePath $aksPlanWithServiceName -Op @{ operationId = 'n5'; operationType = 'create-build-definition'; method = 'PUT'; uri = $buildDefUri; bodyHash = $fakeHash64 }
        Add-Result -Name 'operationType: method PUT -> bloqueante' `
            -Pass ([bool](@($resultN5.validationBlockers) -match "method debe ser 'POST'")) `
            -Detail "blockers=$($resultN5.validationBlockers -join ' | ')"

        # N6: method DELETE -> bloqueante
        $resultN6 = Test-PlanWithApprovedOp -PlanTemplatePath $aksPlanWithServiceName -Op @{ operationId = 'n6'; operationType = 'create-build-definition'; method = 'DELETE'; uri = $buildDefUri; bodyHash = $fakeHash64 }
        Add-Result -Name 'operationType: method DELETE -> bloqueante' `
            -Pass ([bool](@($resultN6.validationBlockers) -match "method debe ser 'POST'")) `
            -Detail "blockers=$($resultN6.validationBlockers -join ' | ')"

        # N7: URI con id de recurso al final -> bloqueante (ruta no calza EXACTO)
        $buildDefUriWithId = $buildDefUri -replace '/definitions\?', '/definitions/12345?'
        $resultN7 = Test-PlanWithApprovedOp -PlanTemplatePath $aksPlanWithServiceName -Op @{ operationId = 'n7'; operationType = 'create-build-definition'; method = 'POST'; uri = $buildDefUriWithId; bodyHash = $fakeHash64 }
        Add-Result -Name 'operationType: URI con id de recurso al final -> bloqueante' `
            -Pass ([bool](@($resultN7.validationBlockers) -match 'debe tener exactamente la ruta')) `
            -Detail "blockers=$($resultN7.validationBlockers -join ' | ')"

        # N8: parametro de query extra -> bloqueante
        $resultN8 = Test-PlanWithApprovedOp -PlanTemplatePath $aksPlanWithServiceName -Op @{ operationId = 'n8'; operationType = 'create-build-definition'; method = 'POST'; uri = "$buildDefUri&definitionToCloneId=999"; bodyHash = $fakeHash64 }
        Add-Result -Name 'operationType: parametro de query extra -> bloqueante' `
            -Pass ([bool](@($resultN8.validationBlockers) -match 'parametros de query extra no permitidos')) `
            -Detail "blockers=$($resultN8.validationBlockers -join ' | ')"

        # N9: host incorrecto para el tipo (create-release-definition debe ir a vsrm., no dev.azure.com)
        $resultN9 = Test-PlanWithApprovedOp -PlanTemplatePath $aksPlanWithServiceName -Op @{ operationId = 'n9'; operationType = 'create-release-definition'; method = 'POST'; uri = ($releaseDefUri -replace 'vsrm\.dev\.azure\.com', 'dev.azure.com'); bodyHash = $fakeHash64 }
        Add-Result -Name 'operationType: host incorrecto para el tipo -> bloqueante' `
            -Pass ([bool](@($resultN9.validationBlockers) -match 'debe usar el host')) `
            -Detail "blockers=$($resultN9.validationBlockers -join ' | ')"

        # N10: operationType duplicado (dos entradas del mismo tipo) -> bloqueante
        $planObjN10 = Get-Content -LiteralPath $aksPlanWithServiceName -Raw | ConvertFrom-Json
        $planObjN10 | Add-Member -NotePropertyName 'approvedOperations' -NotePropertyValue @(
            @{ operationId = 'n10-a'; operationType = 'create-build-definition'; method = 'POST'; uri = $buildDefUri; bodyHash = $fakeHash64 },
            @{ operationId = 'n10-b'; operationType = 'create-build-definition'; method = 'POST'; uri = $buildDefUri; bodyHash = $fakeHash64 }
        ) -Force
        $pathN10 = Join-Path $testTempRoot 'plan-n10.json'
        $planObjN10 | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $pathN10 -Encoding utf8
        & powershell -NoProfile -File (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -PlanPath $pathN10 | Out-Null
        $resultN10 = Get-Content -LiteralPath $pathN10 -Raw | ConvertFrom-Json
        Add-Result -Name 'operationType: duplicado (2 entradas del mismo tipo) -> bloqueante' `
            -Pass ([bool](@($resultN10.validationBlockers) -match 'operationType duplicado')) `
            -Detail "blockers=$($resultN10.validationBlockers -join ' | ')"

        # N11: create-variable-group en un plan de familia dacpac -> bloqueante (DACPAC nunca crea VG/Library nueva)
        if (Test-Path -LiteralPath $dacpacPlanPath) {
            $resultN11 = Test-PlanWithApprovedOp -PlanTemplatePath $dacpacPlanPath -Op @{ operationId = 'n11'; operationType = 'create-variable-group'; method = 'POST'; uri = $vgUri; bodyHash = $fakeHash64 }
            Add-Result -Name 'operationType: create-variable-group en plan dacpac -> bloqueante (familia inapropiada)' `
                -Pass ([bool](@($resultN11.validationBlockers) -match 'no es apropiado para la familia dacpac')) `
                -Detail "blockers=$($resultN11.validationBlockers -join ' | ')"
        }
        else {
            Add-Result -Name 'operationType: create-variable-group en plan dacpac -> bloqueante (familia inapropiada)' -Pass $false -Detail 'Plan DACPAC base no disponible (Grupo D9).'
        }
    }
    else {
        Add-Result -Name 'Grupo N: requiere el plan con ServiceName del Grupo C' -Pass $false -Detail 'Plan base no disponible, se omite este grupo.'
    }

    # ============================================================
    # Grupo N-REPO: Test-AdoClassicPlan.ps1 -- verificacion de repo/branch
    # y de dockerfile/pathFilter se omiten (advertencia, no bloqueante)
    # cuando el plan NO incluye create-build-definition, incluso si
    # incluye OTROS create-* (ej. create-variable-group) -- caso real:
    # crear 2 Variable Groups + actualizar un Build/Release ya existentes
    # cuyo repo vive en OTRO proyecto de Azure DevOps, invisible para
    # Export-AdoClassicInventory.ps1 del proyecto de pipelines. Agregado
    # 2026-08-26 tras un bloqueo real tratando de configurar Dev/UAT de
    # un pipeline Buklo (repo en el proyecto "Buklo", pipeline en "DevOps").
    # ============================================================

    if (Test-Path -LiteralPath $aksPlanWithServiceName) {
        $updateBuildUriNRepo = "$buildDefUri" -replace '/definitions\?', '/definitions/9001?'

        # N-REPO-1: plan con create-variable-group + update-build-definition
        # (SIN create-build-definition) y repo.name que NO existe en
        # ningun inventario -> solo advertencia, nunca bloqueante.
        $planObjNRepo1 = Get-Content -LiteralPath $aksPlanWithServiceName -Raw | ConvertFrom-Json
        $planObjNRepo1.repo.name = 'repo-que-no-existe-en-DevOps'
        $planObjNRepo1 | Add-Member -NotePropertyName 'approvedOperations' -NotePropertyValue @(
            @{ operationId = 'nrepo1-vg'; operationType = 'create-variable-group'; method = 'POST'; uri = $vgUri; bodyHash = $fakeHash64 },
            @{ operationId = 'nrepo1-build'; operationType = 'update-build-definition'; method = 'PUT'; uri = $updateBuildUriNRepo; bodyHash = $fakeHash64 }
        ) -Force
        $pathNRepo1 = Join-Path $testTempRoot 'plan-nrepo1.json'
        $planObjNRepo1 | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $pathNRepo1 -Encoding utf8
        & powershell -NoProfile -File (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -PlanPath $pathNRepo1 | Out-Null
        $resultNRepo1 = Get-Content -LiteralPath $pathNRepo1 -Raw | ConvertFrom-Json
        $noRepoBlocker1 = -not (@($resultNRepo1.validationBlockers) -match 'repo\.name|repo\.prodBranch|no existe en el inventario|no existe en el repositorio')
        $hasRepoWarning1 = [bool](@($resultNRepo1.validationWarnings) -match 'se omite la verificacion')
        Add-Result -Name 'Repo/branch: plan create-variable-group+update-build-definition (sin create-build-definition), repo inexistente -> solo advertencia, sin bloqueante' `
            -Pass ($noRepoBlocker1 -and $hasRepoWarning1) `
            -Detail "blockers=$($resultNRepo1.validationBlockers -join ' | '); warnings=$($resultNRepo1.validationWarnings -join ' | ')"

        # N-REPO-2: mismo caso pero SIN ningun dockerfile.path/repo.pathFilter
        # -- tampoco debe bloquear (familia aks, pero no crea Build nuevo).
        $planObjNRepo2 = Get-Content -LiteralPath $aksPlanWithServiceName -Raw | ConvertFrom-Json
        $planObjNRepo2.PSObject.Properties.Remove('dockerfile')
        $planObjNRepo2.repo.PSObject.Properties.Remove('pathFilter')
        $planObjNRepo2 | Add-Member -NotePropertyName 'approvedOperations' -NotePropertyValue @(
            @{ operationId = 'nrepo2-build'; operationType = 'update-build-definition'; method = 'PUT'; uri = $updateBuildUriNRepo; bodyHash = $fakeHash64 }
        ) -Force
        $pathNRepo2 = Join-Path $testTempRoot 'plan-nrepo2.json'
        $planObjNRepo2 | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $pathNRepo2 -Encoding utf8
        & powershell -NoProfile -File (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -PlanPath $pathNRepo2 | Out-Null
        $resultNRepo2 = Get-Content -LiteralPath $pathNRepo2 -Raw | ConvertFrom-Json
        $noDockerfileBlocker2 = -not (@($resultNRepo2.validationBlockers) -match 'dockerfile\.path|repo\.pathFilter')
        Add-Result -Name 'Dockerfile/pathFilter: plan update-build-definition sin create-build-definition, sin dockerfile/pathFilter -> sin bloqueante' `
            -Pass $noDockerfileBlocker2 `
            -Detail "blockers=$($resultNRepo2.validationBlockers -join ' | ')"

        # N-REPO-3: control -- un plan que SI incluye create-build-definition,
        # con repo.name inexistente, sigue bloqueando exactamente igual que
        # antes del fix (no se debilito la validacion para creacion real).
        $planObjNRepo3 = Get-Content -LiteralPath $aksPlanWithServiceName -Raw | ConvertFrom-Json
        $planObjNRepo3.repo.name = 'repo-que-no-existe-en-DevOps'
        $planObjNRepo3 | Add-Member -NotePropertyName 'approvedOperations' -NotePropertyValue @(
            @{ operationId = 'nrepo3-build'; operationType = 'create-build-definition'; method = 'POST'; uri = $buildDefUri; bodyHash = $fakeHash64 }
        ) -Force
        $pathNRepo3 = Join-Path $testTempRoot 'plan-nrepo3.json'
        $planObjNRepo3 | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $pathNRepo3 -Encoding utf8
        & powershell -NoProfile -File (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -PlanPath $pathNRepo3 -InventoryPath $freshInventoryPath | Out-Null
        $resultNRepo3 = Get-Content -LiteralPath $pathNRepo3 -Raw | ConvertFrom-Json
        Add-Result -Name 'Repo/branch: plan CON create-build-definition, repo inexistente -> sigue bloqueando (control, sin regresion)' `
            -Pass ([bool](@($resultNRepo3.validationBlockers) -match "no existe en el inventario")) `
            -Detail "blockers=$($resultNRepo3.validationBlockers -join ' | ')"
    }
    else {
        Add-Result -Name 'Grupo N-REPO: requiere el plan con ServiceName del Grupo C' -Pass $false -Detail 'Plan base no disponible, se omite este grupo.'
    }

    # ============================================================
    # Grupo N-DUP: Test-AdoClassicPlan.ps1 -- el chequeo de "posible
    # duplicado" de nombre (punto 9) es granular por tipo de recurso, no
    # todo-o-nada. Caso real: un plan que SOLO crea una Variable Group
    # nueva (create-variable-group) no debe bloquear porque el NOMBRE del
    # Build o del Release (que ese plan nunca va a crear) ya existan en el
    # inventario -- pero SI debe seguir bloqueando si el nombre de la
    # propia Variable Group que va a crear ya existe. Agregado 2026-08-26,
    # mismo dia que el fix de repo (Grupo N-REPO), mismo caso real (Buklo
    # Dev/UAT: crear 2 Libraries + actualizar un Build/Release existentes).
    # ============================================================

    if (Test-Path -LiteralPath $aksPlanWithServiceName) {
        $basePlanForDup = Get-Content -LiteralPath $aksPlanWithServiceName -Raw | ConvertFrom-Json
        $dupBuildName = $basePlanForDup.names.build
        $dupReleaseName = $basePlanForDup.names.release
        $dupVgName = $basePlanForDup.variableGroup.name

        $dupNamesInventory = Copy-OrderedHash -Source $baseInventory
        $dupNamesInventory.buildDefinitions = @(@{ id = 'existing-build'; name = $dupBuildName })
        $dupNamesInventory.releaseDefinitions = @(@{ id = 'existing-release'; name = $dupReleaseName })
        $dupNamesInventory.variableGroups = @(@{ id = 'existing-vg'; name = $dupVgName })
        $dupNamesInventoryPath = Join-Path $testTempRoot 'inventory-dup-names.json'
        [PSCustomObject]$dupNamesInventory | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $dupNamesInventoryPath -Encoding utf8

        # N-DUP-1: plan con SOLO create-variable-group, los 3 nombres YA
        # existen en el inventario -> bloqueante SOLO de Variable Group,
        # Build y Release quedan como advertencia (el plan no los crea).
        $planObjNDup1 = Get-Content -LiteralPath $aksPlanWithServiceName -Raw | ConvertFrom-Json
        $planObjNDup1 | Add-Member -NotePropertyName 'approvedOperations' -NotePropertyValue @(
            @{ operationId = 'ndup1-vg'; operationType = 'create-variable-group'; method = 'POST'; uri = $vgUri; bodyHash = $fakeHash64 }
        ) -Force
        $pathNDup1 = Join-Path $testTempRoot 'plan-ndup1.json'
        $planObjNDup1 | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $pathNDup1 -Encoding utf8
        & powershell -NoProfile -File (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -PlanPath $pathNDup1 -InventoryPath $dupNamesInventoryPath | Out-Null
        $resultNDup1 = Get-Content -LiteralPath $pathNDup1 -Raw | ConvertFrom-Json
        $vgBlocked1 = [bool](@($resultNDup1.validationBlockers) -match "Ya existe un Variable Group llamado")
        $buildNotBlocked1 = -not (@($resultNDup1.validationBlockers) -match "Ya existe una definicion de Build")
        $releaseNotBlocked1 = -not (@($resultNDup1.validationBlockers) -match "Ya existe una definicion de Release")
        Add-Result -Name 'Duplicado granular: plan SOLO create-variable-group, los 3 nombres ya existen -> bloquea solo VG, Build/Release quedan advertencia' `
            -Pass ($vgBlocked1 -and $buildNotBlocked1 -and $releaseNotBlocked1) `
            -Detail "blockers=$($resultNDup1.validationBlockers -join ' | '); warnings=$($resultNDup1.validationWarnings -join ' | ')"

        # N-DUP-2: control -- plan SIN approvedOperations todavia (recien
        # generado, en preparacion) con los mismos 3 nombres ya existentes
        # -> sigue bloqueando los 3, exactamente igual que antes del fix
        # (sin regresion para el caso de creacion real desde cero).
        $planObjNDup2 = Get-Content -LiteralPath $aksPlanWithServiceName -Raw | ConvertFrom-Json
        $pathNDup2 = Join-Path $testTempRoot 'plan-ndup2.json'
        $planObjNDup2 | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $pathNDup2 -Encoding utf8
        & powershell -NoProfile -File (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -PlanPath $pathNDup2 -InventoryPath $dupNamesInventoryPath | Out-Null
        $resultNDup2 = Get-Content -LiteralPath $pathNDup2 -Raw | ConvertFrom-Json
        $allThreeBlocked2 = ([bool](@($resultNDup2.validationBlockers) -match "Ya existe un Variable Group llamado")) -and `
            ([bool](@($resultNDup2.validationBlockers) -match "Ya existe una definicion de Build")) -and `
            ([bool](@($resultNDup2.validationBlockers) -match "Ya existe una definicion de Release"))
        Add-Result -Name 'Duplicado granular: plan sin approvedOperations (en preparacion), los 3 nombres ya existen -> sigue bloqueando los 3 (control, sin regresion)' `
            -Pass $allThreeBlocked2 `
            -Detail "blockers=$($resultNDup2.validationBlockers -join ' | ')"
    }
    else {
        Add-Result -Name 'Grupo N-DUP: requiere el plan con ServiceName del Grupo C' -Pass $false -Detail 'Plan base no disponible, se omite este grupo.'
    }

    # ============================================================
    # Grupo K: validationEvidence + Apply-AdoClassicPlan.ps1 -InventoryPath
    # -- todo con datos ficticios, sin red real. El guard de fases no
    # implementadas SIGUE disparando al final (K1 lo confirma), pero
    # estas pruebas verifican que las validaciones de evidencia rechazan
    # ANTES de llegar ahi, con mensajes especificos.
    # ============================================================

    function New-FakeInventoryFile {
        param([bool]$PaginationComplete = $true, [string]$GeneratedAtUtc)
        if (-not $GeneratedAtUtc) { $GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('o') }
        $inv = [ordered]@{
            generatedAtUtc     = $GeneratedAtUtc
            organization       = 'Shared-Service-GM'
            project            = 'DevOps'
            paginationComplete = $PaginationComplete
            marker             = [Guid]::NewGuid().ToString('N')  # para que cada archivo tenga un hash distinto
        }
        $path = Join-Path $testTempRoot ("fake-inv-evidence-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
        [PSCustomObject]$inv | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
        return $path
    }

    function New-FakePlanWithEvidence {
        param(
            [string]$InventoryHash,
            [string]$InventoryGeneratedAtUtc,
            [string]$ValidatedAtUtc,
            [double]$MaxInventoryAgeHours = 24,
            [bool]$IncludeEvidence = $true
        )
        $planObj = [PSCustomObject]@{
            family             = 'aks'
            organization       = 'Shared-Service-GM'
            project            = 'DevOps'
            approvedOperations = @()
            validated          = $true
            validationHash     = $null
        }
        if ($IncludeEvidence) {
            $planObj | Add-Member -NotePropertyName 'validationEvidence' -NotePropertyValue ([PSCustomObject]@{
                inventoryGeneratedAtUtc = $InventoryGeneratedAtUtc
                inventoryHash           = $InventoryHash
                validatedAtUtc          = $ValidatedAtUtc
                maxInventoryAgeHours    = $MaxInventoryAgeHours
            })
        }
        $planObj.validationHash = Get-AdoPlanCanonicalHash -Plan $planObj
        $planPath = Join-Path $testTempRoot ("fake-evidence-plan-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
        $planObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $planPath -Encoding utf8
        return $planPath
    }

    $nowIso = (Get-Date).ToUniversalTime().ToString('o')
    $staleIso = (Get-Date).ToUniversalTime().AddHours(-48).ToString('o')
    $futureIso = (Get-Date).ToUniversalTime().AddHours(2).ToString('o')

    # K1: todo consistente y fresco -> pasa TODAS las validaciones de
    # evidencia y llega hasta el final sin encontrar approvedOperations
    # (planK1 no tiene ninguna) -- nada que aplicar, cero POST, exit 0.
    $invK1 = New-FakeInventoryFile
    $invK1Hash = Get-AdoSha256OfText -Text (Get-Content -LiteralPath $invK1 -Raw)
    $planK1 = New-FakePlanWithEvidence -InventoryHash $invK1Hash -InventoryGeneratedAtUtc $nowIso -ValidatedAtUtc $nowIso
    $resultK1 = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'Apply-AdoClassicPlan.ps1') -ScriptArgs @('-PlanPath', $planK1, '-InventoryPath', $invK1)
    Add-Result -Name 'validationEvidence: todo consistente/fresco -> pasa evidencia, sin approvedOperations -> nada que aplicar' `
        -Pass ($resultK1.ExitCode -eq 0 -and $resultK1.TextFlat -match 'no tiene ninguna operacion aprobada') `
        -Detail "exit=$($resultK1.ExitCode))"

    # K2: inventario modificado despues de validar (mismo archivo, contenido distinto)
    $invK2 = New-FakeInventoryFile
    $invK2HashOriginal = Get-AdoSha256OfText -Text (Get-Content -LiteralPath $invK2 -Raw)
    $planK2 = New-FakePlanWithEvidence -InventoryHash $invK2HashOriginal -InventoryGeneratedAtUtc $nowIso -ValidatedAtUtc $nowIso
    # Se modifica el inventario DESPUES de calcular el hash que quedo en la evidencia.
    Add-Content -LiteralPath $invK2 -Value ' ' -Encoding utf8
    $resultK2 = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'Apply-AdoClassicPlan.ps1') -ScriptArgs @('-PlanPath', $planK2, '-InventoryPath', $invK2)
    Add-Result -Name 'validationEvidence: inventario modificado despues de validar -> rechazado' `
        -Pass ($resultK2.ExitCode -ne 0 -and $resultK2.TextFlat -match 'no es el mismo que se uso para validar') `
        -Detail "exit=$($resultK2.ExitCode)"

    # K3: mas viejo de 24 horas (medido desde ahora, aunque en su momento hubiera sido fresco)
    $invK3 = New-FakeInventoryFile -GeneratedAtUtc $staleIso
    $invK3Hash = Get-AdoSha256OfText -Text (Get-Content -LiteralPath $invK3 -Raw)
    $planK3 = New-FakePlanWithEvidence -InventoryHash $invK3Hash -InventoryGeneratedAtUtc $staleIso -ValidatedAtUtc $staleIso
    $resultK3 = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'Apply-AdoClassicPlan.ps1') -ScriptArgs @('-PlanPath', $planK3, '-InventoryPath', $invK3)
    Add-Result -Name 'validationEvidence: inventario/validacion de mas de 24h (medido desde ahora) -> rechazado' `
        -Pass ($resultK3.ExitCode -ne 0 -and $resultK3.TextFlat -match 'mas que el limite efectivo de') `
        -Detail "exit=$($resultK3.ExitCode)"

    # K4: fecha futura
    $invK4 = New-FakeInventoryFile -GeneratedAtUtc $futureIso
    $invK4Hash = Get-AdoSha256OfText -Text (Get-Content -LiteralPath $invK4 -Raw)
    $planK4 = New-FakePlanWithEvidence -InventoryHash $invK4Hash -InventoryGeneratedAtUtc $futureIso -ValidatedAtUtc $nowIso
    $resultK4 = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'Apply-AdoClassicPlan.ps1') -ScriptArgs @('-PlanPath', $planK4, '-InventoryPath', $invK4)
    Add-Result -Name 'validationEvidence: inventoryGeneratedAtUtc en el futuro -> rechazado' `
        -Pass ($resultK4.ExitCode -ne 0 -and $resultK4.TextFlat -match 'esta en el futuro') `
        -Detail "exit=$($resultK4.ExitCode)"

    # K5: sin paginationComplete=true (re-verificado en el momento de aplicar)
    $invK5 = New-FakeInventoryFile -PaginationComplete $false
    $invK5Hash = Get-AdoSha256OfText -Text (Get-Content -LiteralPath $invK5 -Raw)
    $planK5 = New-FakePlanWithEvidence -InventoryHash $invK5Hash -InventoryGeneratedAtUtc $nowIso -ValidatedAtUtc $nowIso
    $resultK5 = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'Apply-AdoClassicPlan.ps1') -ScriptArgs @('-PlanPath', $planK5, '-InventoryPath', $invK5)
    Add-Result -Name 'validationEvidence: inventario sin paginationComplete=true -> rechazado' `
        -Pass ($resultK5.ExitCode -ne 0 -and $resultK5.TextFlat -match 'paginationComplete=true') `
        -Detail "exit=$($resultK5.ExitCode)"

    # K6: hash incorrecto en la evidencia (no corresponde a NINGUN archivo real)
    $invK6 = New-FakeInventoryFile
    $planK6 = New-FakePlanWithEvidence -InventoryHash ('f' * 64) -InventoryGeneratedAtUtc $nowIso -ValidatedAtUtc $nowIso
    $resultK6 = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'Apply-AdoClassicPlan.ps1') -ScriptArgs @('-PlanPath', $planK6, '-InventoryPath', $invK6)
    Add-Result -Name 'validationEvidence: inventoryHash incorrecto en la evidencia -> rechazado' `
        -Pass ($resultK6.ExitCode -ne 0 -and $resultK6.TextFlat -match 'no es el mismo que se uso para validar') `
        -Detail "exit=$($resultK6.ExitCode)"

    # K7: -InventoryPath apunta a un archivo DIFERENTE (valido, pero no el que se uso para validar)
    $invK7A = New-FakeInventoryFile
    $invK7AHash = Get-AdoSha256OfText -Text (Get-Content -LiteralPath $invK7A -Raw)
    $invK7B = New-FakeInventoryFile
    $planK7 = New-FakePlanWithEvidence -InventoryHash $invK7AHash -InventoryGeneratedAtUtc $nowIso -ValidatedAtUtc $nowIso
    $resultK7 = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'Apply-AdoClassicPlan.ps1') -ScriptArgs @('-PlanPath', $planK7, '-InventoryPath', $invK7B)
    Add-Result -Name 'validationEvidence: -InventoryPath apunta a un archivo distinto del validado -> rechazado' `
        -Pass ($resultK7.ExitCode -ne 0 -and $resultK7.TextFlat -match 'no es el mismo que se uso para validar') `
        -Detail "exit=$($resultK7.ExitCode)"

    # K8: evidencia ausente por completo
    $invK8 = New-FakeInventoryFile
    $planK8 = New-FakePlanWithEvidence -IncludeEvidence $false
    $resultK8 = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'Apply-AdoClassicPlan.ps1') -ScriptArgs @('-PlanPath', $planK8, '-InventoryPath', $invK8)
    Add-Result -Name 'validationEvidence: ausente en el plan -> rechazado' `
        -Pass ($resultK8.ExitCode -ne 0 -and $resultK8.TextFlat -match 'no tiene validationEvidence') `
        -Detail "exit=$($resultK8.ExitCode)"

    # ============================================================
    # Grupo O: tope de antiguedad de inventario/validacion (item 2). Test-
    # AdoClassicPlan.ps1 nunca acepta -MaxInventoryAgeHours > 24 (o <=0,
    # o NaN/infinito) via [ValidateRange] + chequeo explicito; Apply-
    # AdoClassicPlan.ps1 nunca supera un tope absoluto interno de 24h sin
    # importar lo que declare validationEvidence.maxInventoryAgeHours.
    # ============================================================

    # O1: -MaxInventoryAgeHours 25 (por encima del tope) -> rechazado por [ValidateRange]
    $planO1 = Join-Path $testTempRoot 'plan-o1.json'
    Copy-Item $aksPlanWithServiceName $planO1 -Force
    $resultO1 = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -ScriptArgs @('-PlanPath', $planO1, '-InventoryPath', $freshInventoryPath, '-MaxInventoryAgeHours', '25')
    Add-Result -Name 'MaxInventoryAgeHours: 25 (por encima del tope de 24) -> rechazado' `
        -Pass ($resultO1.ExitCode -ne 0) `
        -Detail "exit=$($resultO1.ExitCode)"

    # O2: -MaxInventoryAgeHours 0 -> rechazado (minimo 0.01)
    $planO2 = Join-Path $testTempRoot 'plan-o2.json'
    Copy-Item $aksPlanWithServiceName $planO2 -Force
    $resultO2 = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -ScriptArgs @('-PlanPath', $planO2, '-InventoryPath', $freshInventoryPath, '-MaxInventoryAgeHours', '0')
    Add-Result -Name 'MaxInventoryAgeHours: 0 -> rechazado' `
        -Pass ($resultO2.ExitCode -ne 0) `
        -Detail "exit=$($resultO2.ExitCode)"

    # O3: -MaxInventoryAgeHours negativo -> rechazado
    $planO3 = Join-Path $testTempRoot 'plan-o3.json'
    Copy-Item $aksPlanWithServiceName $planO3 -Force
    $resultO3 = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -ScriptArgs @('-PlanPath', $planO3, '-InventoryPath', $freshInventoryPath, '-MaxInventoryAgeHours', '-1')
    Add-Result -Name 'MaxInventoryAgeHours: negativo -> rechazado' `
        -Pass ($resultO3.ExitCode -ne 0) `
        -Detail "exit=$($resultO3.ExitCode)"

    # O4: -MaxInventoryAgeHours NaN -> rechazado ([ValidateRange] no atrapa NaN por si solo; hay un chequeo explicito)
    $planO4 = Join-Path $testTempRoot 'plan-o4.json'
    Copy-Item $aksPlanWithServiceName $planO4 -Force
    $resultO4 = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -ScriptArgs @('-PlanPath', $planO4, '-InventoryPath', $freshInventoryPath, '-MaxInventoryAgeHours', 'NaN')
    Add-Result -Name 'MaxInventoryAgeHours: NaN -> rechazado' `
        -Pass ($resultO4.ExitCode -ne 0) `
        -Detail "exit=$($resultO4.ExitCode); texto=$($resultO4.Text.Substring(0, [Math]::Min(150, $resultO4.Text.Length)))"

    # O5: -MaxInventoryAgeHours Infinity -> rechazado
    $planO5 = Join-Path $testTempRoot 'plan-o5.json'
    Copy-Item $aksPlanWithServiceName $planO5 -Force
    $resultO5 = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -ScriptArgs @('-PlanPath', $planO5, '-InventoryPath', $freshInventoryPath, '-MaxInventoryAgeHours', 'Infinity')
    Add-Result -Name 'MaxInventoryAgeHours: Infinity -> rechazado' `
        -Pass ($resultO5.ExitCode -ne 0) `
        -Detail "exit=$($resultO5.ExitCode)"

    # O6: -MaxInventoryAgeHours 24 (limite exacto, valido) -> aceptado por [ValidateRange] (no impide validar)
    $planO6 = Join-Path $testTempRoot 'plan-o6.json'
    Copy-Item $aksPlanWithServiceName $planO6 -Force
    $resultO6 = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -ScriptArgs @('-PlanPath', $planO6, '-InventoryPath', $freshInventoryPath, '-MaxInventoryAgeHours', '24')
    Add-Result -Name 'MaxInventoryAgeHours: 24 (limite exacto) -> aceptado por ValidateRange' `
        -Pass ($resultO6.ExitCode -eq 0) `
        -Detail "exit=$($resultO6.ExitCode)"

    # O7: -MaxInventoryAgeHours 0.01 (minimo exacto, valido) -> aceptado por ValidateRange
    $planO7 = Join-Path $testTempRoot 'plan-o7.json'
    Copy-Item $aksPlanWithServiceName $planO7 -Force
    $resultO7 = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -ScriptArgs @('-PlanPath', $planO7, '-InventoryPath', $freshInventoryPath, '-MaxInventoryAgeHours', '0.01')
    $o7MentionsStale = @($((Get-Content -LiteralPath $planO7 -Raw | ConvertFrom-Json)).validationBlockers) -match 'antiguedad'
    Add-Result -Name 'MaxInventoryAgeHours: 0.01 (minimo exacto) -> aceptado por ValidateRange (puede seguir bloqueando por antiguedad real, no por el parametro)' `
        -Pass ($resultO7.ExitCode -eq 0 -or $o7MentionsStale) `
        -Detail "exit=$($resultO7.ExitCode); mencionaAntiguedad=$o7MentionsStale"

    # O8: Apply-AdoClassicPlan.ps1 -- tope absoluto interno (24h) se impone
    # AUNQUE validationEvidence.maxInventoryAgeHours declare un valor mucho
    # mayor (999h, como si el archivo de plan hubiera sido manipulado a
    # mano evitando el [ValidateRange] de Test-AdoClassicPlan.ps1).
    # Inventario de 30h de antiguedad: por debajo del limite declarado
    # (999h) pero por encima del tope absoluto real (24h) -> DEBE rechazarse.
    $invO8 = New-FakeInventoryFile -GeneratedAtUtc ((Get-Date).ToUniversalTime().AddHours(-30).ToString('o'))
    $invO8Hash = Get-AdoSha256OfText -Text (Get-Content -LiteralPath $invO8 -Raw)
    $planO8 = New-FakePlanWithEvidence -InventoryHash $invO8Hash -InventoryGeneratedAtUtc ((Get-Date).ToUniversalTime().AddHours(-30).ToString('o')) -ValidatedAtUtc $nowIso -MaxInventoryAgeHours 999
    $resultO8 = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'Apply-AdoClassicPlan.ps1') -ScriptArgs @('-PlanPath', $planO8, '-InventoryPath', $invO8)
    Add-Result -Name 'Apply-AdoClassicPlan: tope absoluto interno (24h) rechaza aunque evidence declare 999h' `
        -Pass ($resultO8.ExitCode -ne 0 -and $resultO8.TextFlat -match 'tope absoluto interno') `
        -Detail "exit=$($resultO8.ExitCode)"

    # ============================================================
    # Grupo L: Export-AdoClassicInventory.ps1 -- NINGUN valor de variable
    # se exporta, ni siquiera un placeholder. Se extrae y evalua la
    # funcion Strip-Secrets REAL del archivo (via AST, sin ejecutar el
    # resto del script -- que hace llamadas de red reales) para probar
    # el codigo de produccion tal cual, no una copia.
    # ============================================================

    $exportScriptPath = Join-Path $scriptsRoot 'Export-AdoClassicInventory.ps1'
    $exportScriptText = Get-Content -LiteralPath $exportScriptPath -Raw
    $exportAst = [System.Management.Automation.Language.Parser]::ParseInput($exportScriptText, [ref]$null, [ref]$null)
    $stripSecretsAst = $exportAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Strip-Secrets' }, $true)

    if (-not $stripSecretsAst) {
        Add-Result -Name 'Export-AdoClassicInventory: se encontro la funcion Strip-Secrets para probarla' -Pass $false -Detail 'No se encontro la funcion en el archivo actual.'
    }
    else {
        # Define SOLO esa funcion en este scope (no ejecuta el resto del
        # script, que haria llamadas de red reales).
        Invoke-Expression $stripSecretsAst.Extent.Text

        $fakeVariableGroup = [PSCustomObject]@{
            id   = 'vg-fake-1'
            name = 'Produccion-Ejemplo-Ficticio'
            type = 'Vsts'
            variables = [PSCustomObject]@{
                'DB_PASSWORD'    = [PSCustomObject]@{ isSecret = $true; value = 'EsteValorNuncaDeberiaQuedarEnElInventario' }
                'NON_SECRET_VAR' = [PSCustomObject]@{ isSecret = $false; value = 'este-tampoco-deberia-quedar-aunque-no-sea-secreto' }
            }
        }

        $sanitized = Strip-Secrets -VariableGroup $fakeVariableGroup
        $sanitizedJson = $sanitized | ConvertTo-Json -Depth 10 -Compress

        Add-Result -Name 'Export-AdoClassicInventory: Strip-Secrets NUNCA incluye el valor secreto' `
            -Pass ($sanitizedJson -notmatch 'EsteValorNuncaDeberiaQuedarEnElInventario') `
            -Detail 'OK si no aparece el valor ficticio secreto en el JSON resultante.'

        Add-Result -Name 'Export-AdoClassicInventory: Strip-Secrets NUNCA incluye el valor NO secreto tampoco' `
            -Pass ($sanitizedJson -notmatch 'este-tampoco-deberia-quedar-aunque-no-sea-secreto') `
            -Detail 'OK si el valor ficticio no-secreto tampoco aparece (isSecret=false no autoriza guardar el value).'

        Add-Result -Name 'Export-AdoClassicInventory: Strip-Secrets NUNCA incluye la propiedad "value" en absoluto' `
            -Pass ($sanitizedJson -notmatch '"value"') `
            -Detail "JSON resultante: $sanitizedJson"

        Add-Result -Name 'Export-AdoClassicInventory: Strip-Secrets conserva isSecret=true para la variable secreta' `
            -Pass ($sanitized.variables.'DB_PASSWORD'.isSecret -eq $true) `
            -Detail "isSecret='$($sanitized.variables.'DB_PASSWORD'.isSecret)'"

        Add-Result -Name 'Export-AdoClassicInventory: Strip-Secrets conserva isSecret=false para la variable no secreta' `
            -Pass ($sanitized.variables.'NON_SECRET_VAR'.isSecret -eq $false) `
            -Detail "isSecret='$($sanitized.variables.'NON_SECRET_VAR'.isSecret)'"
    }

    # ============================================================
    # Grupo M: journal de ejecucion (item 1) + flujo simulado de punta a
    # punta (item 6): inventario -> plan -> validacion -> aprobacion
    # simulada -> 3 operaciones simuladas -> journal -> readback simulado.
    # Se shadea Invoke-WebRequest (nunca Invoke-AdoRest) para que el
    # codigo REAL de produccion de Invoke-AdoRest.ps1 (validacion de
    # plan, manifiesto, journal) corra sin cambios -- solo la capa HTTP
    # se simula. El journal se escribe SIEMPRE bajo $testTempRoot (nunca
    # .local/azure-devops/ real) via la variable de entorno
    # ADO_TEST_EXECUTIONS_ROOT -- el UNICO mecanismo de override que
    # existe (Get-AdoExecutionsDir ya no acepta -ProjectRoot: ningun
    # llamador de produccion puede redirigir el journal). Se usa un PAT
    # FICTICIO temporal (nunca el real del usuario, ya removido al inicio
    # de este harness) solo para que Get-AdoAuthHeader no corte antes de
    # llegar a la capa HTTP simulada -- ese PAT ficticio nunca sale de
    # este proceso, porque Invoke-WebRequest esta mockeado: cero llamadas
    # de red reales.
    # ============================================================

    . (Join-Path $scriptsRoot 'Invoke-AdoRest.ps1')  # version REAL, sin mocks de grupos anteriores
    . (Join-Path $scriptsRoot 'New-AdoClassicPayloads.ps1')
    . (Join-Path $scriptsRoot 'ConvertTo-AdoEnvClassification.ps1')

    $originalAdoTestExecutionsRoot = $env:ADO_TEST_EXECUTIONS_ROOT
    $env:ADO_TEST_EXECUTIONS_ROOT = $testTempRoot

    $env:AZURE_DEVOPS_PAT = 'FICTICIO-NUNCA-REAL-TEST-0000000000'
    $originalWriteJournalAtomic = (Get-Item function:Write-AdoExecutionJournalAtomic).ScriptBlock

    function Reset-MockWebRequest {
        $script:mockWebResponseQueue = [System.Collections.Generic.Queue[object]]::new()
        $script:mockWebCallCount = 0
    }
    function Add-MockWebSuccessResponse {
        param([string]$ResultId)
        $content = ([PSCustomObject]@{ id = $ResultId }) | ConvertTo-Json -Compress
        $script:mockWebResponseQueue.Enqueue([PSCustomObject]@{ Throw = $false; StatusCode = 200; Content = $content })
    }
    function Set-MockWebThrowNext {
        param([string]$Message = 'Fallo de red simulado (timeout/conexion perdida)')
        $script:mockWebResponseQueue.Enqueue([PSCustomObject]@{ Throw = $true; Message = $Message })
    }
    function Invoke-WebRequest {
        param([string]$Method, [string]$Uri, $Headers, $Body, [int]$MaximumRedirection, [switch]$UseBasicParsing)
        $script:mockWebCallCount++
        $script:lastMockBody = $Body
        if ($script:mockWebResponseQueue.Count -eq 0) {
            throw "Mock de Invoke-WebRequest: se pidio una respuesta simulada de mas (llamada #$($script:mockWebCallCount))."
        }
        $next = $script:mockWebResponseQueue.Dequeue()
        if ($next.Throw) { throw $next.Message }
        return [PSCustomObject]@{ StatusCode = $next.StatusCode; Content = $next.Content; Headers = @{} }
    }
    function Set-MockJournalWriteFailure {
        param([int]$FailOnCallNumber = -1)
        $script:journalWriteCallCount = 0
        $script:journalWriteFailOn = $FailOnCallNumber
    }
    function Write-AdoExecutionJournalAtomic {
        param([string]$JournalPath, $Journal)
        $script:journalWriteCallCount++
        if ($script:journalWriteCallCount -eq $script:journalWriteFailOn) {
            throw 'Fallo simulado de disco al escribir el journal.'
        }
        & $originalWriteJournalAtomic -JournalPath $JournalPath -Journal $Journal
    }
    Set-MockJournalWriteFailure -FailOnCallNumber -1

    function Test-PlanFileBytesUnchanged {
        param([string]$PlanPath, [byte[]]$BaselineBytes)
        $current = [System.IO.File]::ReadAllBytes($PlanPath)
        if ($current.Length -ne $BaselineBytes.Length) { return $false }
        for ($i = 0; $i -lt $current.Length; $i++) { if ($current[$i] -ne $BaselineBytes[$i]) { return $false } }
        return $true
    }

    # ============================================================
    # Grupo M-UTF8: Invoke-AdoRest.ps1 -- el body real transmitido a
    # Invoke-WebRequest debe ser bytes UTF-8 explicitos, nunca un [string]
    # dejado a la codificacion por defecto del sistema (bug real
    # encontrado 2026-08-26 configurando Buklo Gateway Dev/UAT: en
    # Windows PowerShell 5.1, un -Body [string] se codifica con el
    # codepage del sistema -- Windows-1252 en este entorno -- cuando el
    # Content-Type se fija via -Headers en vez de -ContentType, corrompiendo
    # cualquier caracter no-ASCII silenciosamente o generando bytes UTF-8
    # invalidos que Azure DevOps rechaza con 400). Ver
    # [[ado-test-classic-plan-update-fixes]] / memoria del proyecto.
    # ============================================================

    $mUtf8Body = @{ name = 'Configuración “Ñoño” — é'; type = 'Vsts' }
    $mUtf8Ops = @(
        @{ operationId = 'm-utf8'; operationType = 'create-variable-group'; method = 'POST'; uri = $vgUri; bodyHash = (Get-AdoBodyCanonicalHash -Body $mUtf8Body) }
    )
    $planMUtf8 = New-FakeApprovedPlan -ApprovedOperations $mUtf8Ops
    Reset-MockWebRequest
    Add-MockWebSuccessResponse -ResultId 'vg-utf8-real-id'
    Invoke-ExpectNoThrow -Name 'Invoke-AdoRest UTF-8: body con caracteres no-ASCII se envia sin lanzar' -Block {
        Invoke-AdoRest -Method POST -Uri $vgUri -Body $mUtf8Body -RequireApprovedPlan -PlanPath $planMUtf8 -OperationId 'm-utf8' -JournalLockTimeoutMs 2000
    }
    $expectedUtf8Json = $mUtf8Body | ConvertTo-Json -Depth 20
    $expectedUtf8Bytes = [System.Text.Encoding]::UTF8.GetBytes($expectedUtf8Json)
    $isByteArray = $script:lastMockBody -is [byte[]]
    $bytesMatch = $false
    if ($isByteArray -and $script:lastMockBody.Length -eq $expectedUtf8Bytes.Length) {
        $bytesMatch = $true
        for ($bi = 0; $bi -lt $expectedUtf8Bytes.Length; $bi++) {
            if ($script:lastMockBody[$bi] -ne $expectedUtf8Bytes[$bi]) { $bytesMatch = $false; break }
        }
    }
    Add-Result -Name 'Invoke-AdoRest UTF-8: el Body pasado a Invoke-WebRequest es [byte[]] UTF-8 exacto (no [string] a merced del codepage del sistema)' `
        -Pass ($isByteArray -and $bytesMatch) `
        -Detail "esByteArray=$isByteArray; longitudRecibida=$(if ($isByteArray) { $script:lastMockBody.Length } else { 'n/a' }); longitudEsperada=$($expectedUtf8Bytes.Length)"
    $decodedBack = [System.Text.Encoding]::UTF8.GetString($script:lastMockBody)
    Add-Result -Name 'Invoke-AdoRest UTF-8: decodificando los bytes recibidos como UTF-8 se recupera el JSON original exacto (round-trip)' `
        -Pass ($decodedBack -ceq $expectedUtf8Json) `
        -Detail "decodedBack=$decodedBack"

    $mVgBody = @{ name = 'Produccion-Simulado-E2E'; type = 'Vsts'; variables = @{ ambiente = @{ value = 'prod' } } }
    $mBuildBody = @{ name = 'Build-Simulado-E2E'; type = 'build' }
    $mReleaseBody = @{ name = 'Release-Simulado-E2E'; type = 'release' }

    $mOps = @(
        @{ operationId = 'm-vg'; operationType = 'create-variable-group'; method = 'POST'; uri = $vgUri; bodyHash = (Get-AdoBodyCanonicalHash -Body $mVgBody) },
        @{ operationId = 'm-build'; operationType = 'create-build-definition'; method = 'POST'; uri = $buildDefUri; bodyHash = (Get-AdoBodyCanonicalHash -Body $mBuildBody) },
        @{ operationId = 'm-release'; operationType = 'create-release-definition'; method = 'POST'; uri = $releaseDefUri; bodyHash = (Get-AdoBodyCanonicalHash -Body $mReleaseBody) }
    )
    $planM = New-FakeApprovedPlan -ApprovedOperations $mOps
    $planMBytesBefore = [System.IO.File]::ReadAllBytes($planM)
    $planMValidationHash = (Get-Content -LiteralPath $planM -Raw | ConvertFrom-Json).validationHash
    $journalPathM = Get-AdoExecutionJournalPath -PlanValidationHash $planMValidationHash

    Add-Result -Name 'Journal E2E: el archivo de journal NO existe antes de la primera operacion' `
        -Pass (-not (Test-Path -LiteralPath $journalPathM)) -Detail "journalPath=$journalPathM"

    # M1: operacion 1/3 (create-variable-group) -- exito
    Reset-MockWebRequest
    Add-MockWebSuccessResponse -ResultId 'vg-real-id-111'
    Invoke-ExpectNoThrow -Name 'Journal E2E: operacion 1/3 (create-variable-group) se ejecuta con exito' -Block {
        Invoke-AdoRest -Method POST -Uri $vgUri -Body $mVgBody -RequireApprovedPlan -PlanPath $planM -OperationId 'm-vg' -JournalLockTimeoutMs 2000
    }
    Add-Result -Name 'Journal E2E: plan.json permanece BYTE A BYTE identico tras la operacion 1' `
        -Pass (Test-PlanFileBytesUnchanged -PlanPath $planM -BaselineBytes $planMBytesBefore) -Detail 'Comparacion byte a byte del archivo de plan.'
    $planMReload1 = Get-Content -LiteralPath $planM -Raw | ConvertFrom-Json
    Add-Result -Name 'Journal E2E: validationHash sigue siendo valido tras la operacion 1' `
        -Pass ((Get-AdoPlanCanonicalHash -Plan $planMReload1) -eq $planMReload1.validationHash) -Detail "hash=$($planMReload1.validationHash)"

    # M2: operaciones 2/3 y 3/3 -- exito, mismo plan (inmutable), journal compartido
    Add-MockWebSuccessResponse -ResultId 'build-real-id-222'
    Invoke-ExpectNoThrow -Name 'Journal E2E: operacion 2/3 (create-build-definition) se ejecuta con exito' -Block {
        Invoke-AdoRest -Method POST -Uri $buildDefUri -Body $mBuildBody -RequireApprovedPlan -PlanPath $planM -OperationId 'm-build' -JournalLockTimeoutMs 2000
    }
    Add-MockWebSuccessResponse -ResultId 'release-real-id-333'
    Invoke-ExpectNoThrow -Name 'Journal E2E: operacion 3/3 (create-release-definition) se ejecuta con exito' -Block {
        Invoke-AdoRest -Method POST -Uri $releaseDefUri -Body $mReleaseBody -RequireApprovedPlan -PlanPath $planM -OperationId 'm-release' -JournalLockTimeoutMs 2000
    }
    Add-Result -Name 'Journal E2E: plan.json sigue BYTE A BYTE identico tras las 3 operaciones' `
        -Pass (Test-PlanFileBytesUnchanged -PlanPath $planM -BaselineBytes $planMBytesBefore) -Detail 'Comparacion byte a byte del archivo de plan.'

    # Readback simulado: leer el journal (nunca la red) y confirmar las 3 operaciones succeeded con resultId distinto
    $journalM = Get-Content -LiteralPath $journalPathM -Raw | ConvertFrom-Json
    $allSucceeded = ($journalM.operations.'m-vg'.state -eq 'succeeded') -and ($journalM.operations.'m-build'.state -eq 'succeeded') -and ($journalM.operations.'m-release'.state -eq 'succeeded')
    $resultIdsDistinct = ($journalM.operations.'m-vg'.resultId -eq 'vg-real-id-111') -and ($journalM.operations.'m-build'.resultId -eq 'build-real-id-222') -and ($journalM.operations.'m-release'.resultId -eq 'release-real-id-333')
    Add-Result -Name 'Journal E2E (readback simulado): las 3 operaciones quedan succeeded con resultId correcto' `
        -Pass ($allSucceeded -and $resultIdsDistinct) -Detail "journal=$($journalM | ConvertTo-Json -Compress -Depth 10)"
    Add-Result -Name 'Journal E2E: planValidationHash del journal coincide con el del plan' `
        -Pass ($journalM.planValidationHash -eq $planMValidationHash) -Detail "journal.planValidationHash=$($journalM.planValidationHash)"

    # M3: reintentar una operacion ya succeeded -> rechazada, exactamente-una-vez
    Invoke-ExpectThrow -Name 'Journal: reintentar una operacion ya succeeded -> rechazado (exactamente una vez)' `
        -ExpectedMessagePattern "ya tiene estado 'succeeded'" -Block {
        Invoke-AdoRest -Method POST -Uri $vgUri -Body $mVgBody -RequireApprovedPlan -PlanPath $planM -OperationId 'm-vg' -JournalLockTimeoutMs 2000
    }
    Add-Result -Name 'Journal: cero llamadas HTTP adicionales al rechazar el reintento' `
        -Pass ($script:mockWebCallCount -eq 3) -Detail "mockWebCallCount=$($script:mockWebCallCount) (esperado 3, una por operacion real)"

    # M4: dos "procesos" concurrentes sobre el MISMO operationId -- se
    # simula manteniendo el lock file abierto exclusivamente (como lo
    # haria otro proceso real) y verificando que la segunda llamada se
    # rechaza por timeout de lock en vez de proceder sin proteccion.
    $planM4 = New-FakeApprovedPlan -ApprovedOperations @(@{ operationId = 'm4-op'; operationType = 'create-variable-group'; method = 'POST'; uri = $vgUri; bodyHash = (Get-AdoBodyCanonicalHash -Body $mVgBody) })
    $planM4Hash = (Get-Content -LiteralPath $planM4 -Raw | ConvertFrom-Json).validationHash
    $journalPathM4 = Get-AdoExecutionJournalPath -PlanValidationHash $planM4Hash
    $lockPathM4 = "$journalPathM4.lock"
    $lockDirM4 = Split-Path -Parent $lockPathM4
    New-Item -ItemType Directory -Force -Path $lockDirM4 | Out-Null
    $heldLockStream = [System.IO.File]::Open($lockPathM4, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        Reset-MockWebRequest
        Add-MockWebSuccessResponse -ResultId 'no-deberia-usarse'
        Invoke-ExpectThrow -Name 'Journal: concurrencia -- lock ya tomado por "otro proceso" -> rechazado, no procede sin proteccion' `
            -ExpectedMessagePattern 'no se pudo obtener el lock exclusivo del journal' -Block {
            Invoke-AdoRest -Method POST -Uri $vgUri -Body $mVgBody -RequireApprovedPlan -PlanPath $planM4 -OperationId 'm4-op' -JournalLockTimeoutMs 300
        }
        Add-Result -Name 'Journal: concurrencia -- ninguna llamada HTTP se realizo mientras el lock estaba tomado' `
            -Pass ($script:mockWebCallCount -eq 0) -Detail "mockWebCallCount=$($script:mockWebCallCount)"
    }
    finally {
        $heldLockStream.Close()
        $heldLockStream.Dispose()
    }
    # Liberado el lock, la MISMA operacion ahora si procede (una sola llamada real).
    Invoke-ExpectNoThrow -Name 'Journal: concurrencia -- liberado el lock, la operacion procede normalmente' -Block {
        Invoke-AdoRest -Method POST -Uri $vgUri -Body $mVgBody -RequireApprovedPlan -PlanPath $planM4 -OperationId 'm4-op' -JournalLockTimeoutMs 2000
    }
    Add-Result -Name 'Journal: concurrencia -- exactamente 1 llamada HTTP se realizo en total para esa operacion' `
        -Pass ($script:mockWebCallCount -eq 1) -Detail "mockWebCallCount=$($script:mockWebCallCount)"

    # M5: fallo ANTES de enviar la solicitud (manifiesto no coincide) ->
    # el journal NUNCA se crea para ese plan (cero contacto con el journal).
    $planM5 = New-FakeApprovedPlan -ApprovedOperations @(@{ operationId = 'm5-op'; operationType = 'create-variable-group'; method = 'POST'; uri = $vgUri; bodyHash = (Get-AdoBodyCanonicalHash -Body $mVgBody) })
    $planM5Hash = (Get-Content -LiteralPath $planM5 -Raw | ConvertFrom-Json).validationHash
    $journalPathM5 = Get-AdoExecutionJournalPath -PlanValidationHash $planM5Hash
    Reset-MockWebRequest
    Invoke-ExpectThrow -Name 'Journal: fallo ANTES de enviar (operationId inexistente) -> rechazado sin tocar el journal' `
        -ExpectedMessagePattern 'no existe la operacion' -Block {
        Invoke-AdoRest -Method POST -Uri $vgUri -Body $mVgBody -RequireApprovedPlan -PlanPath $planM5 -OperationId 'operacion-que-no-existe' -JournalLockTimeoutMs 2000
    }
    Add-Result -Name 'Journal: fallo antes de enviar -> el archivo de journal nunca se creo' `
        -Pass (-not (Test-Path -LiteralPath $journalPathM5)) -Detail "journalPath=$journalPathM5"
    Add-Result -Name 'Journal: fallo antes de enviar -> cero llamadas HTTP' `
        -Pass ($script:mockWebCallCount -eq 0) -Detail "mockWebCallCount=$($script:mockWebCallCount)"

    # M6: fallo de red DURANTE el intento (estado incierto real) -> ambiguous, reintento bloqueado
    $planM6 = New-FakeApprovedPlan -ApprovedOperations @(@{ operationId = 'm6-op'; operationType = 'create-variable-group'; method = 'POST'; uri = $vgUri; bodyHash = (Get-AdoBodyCanonicalHash -Body $mVgBody) })
    Reset-MockWebRequest
    Set-MockWebThrowNext -Message 'Conexion perdida a mitad de la solicitud (simulado)'
    Invoke-ExpectThrow -Name 'Journal: fallo de red durante el intento -> Invoke-AdoRest reporta el error (nunca en silencio)' `
        -ExpectedMessagePattern 'Invoke-AdoRest fallo' -Block {
        Invoke-AdoRest -Method POST -Uri $vgUri -Body $mVgBody -RequireApprovedPlan -PlanPath $planM6 -OperationId 'm6-op' -JournalLockTimeoutMs 2000
    }
    $planM6Hash = (Get-Content -LiteralPath $planM6 -Raw | ConvertFrom-Json).validationHash
    $journalM6 = Get-Content -LiteralPath (Get-AdoExecutionJournalPath -PlanValidationHash $planM6Hash) -Raw | ConvertFrom-Json
    Add-Result -Name 'Journal: fallo de red durante el intento -> la operacion queda "ambiguous" (no se asume exito ni fracaso)' `
        -Pass ($journalM6.operations.'m6-op'.state -eq 'ambiguous') -Detail "state=$($journalM6.operations.'m6-op'.state)"
    Invoke-ExpectThrow -Name 'Journal: una operacion "ambiguous" nunca se reintenta automaticamente' `
        -ExpectedMessagePattern "ya tiene estado 'ambiguous'.*readback y aprobacion explicita" -Block {
        Invoke-AdoRest -Method POST -Uri $vgUri -Body $mVgBody -RequireApprovedPlan -PlanPath $planM6 -OperationId 'm6-op' -JournalLockTimeoutMs 2000
    }

    # M7: la solicitud SI tuvo exito (Azure DevOps confirmo), pero la
    # escritura del journal a 'succeeded' falla despues -> se bloquea el
    # reintento automatico y se reporta estado incierto explicito (nunca
    # en silencio). La entrada queda 'in-progress' (ya escrita ANTES de
    # la llamada de red), que por diseno ya bloquea cualquier reintento.
    $planM7 = New-FakeApprovedPlan -ApprovedOperations @(@{ operationId = 'm7-op'; operationType = 'create-variable-group'; method = 'POST'; uri = $vgUri; bodyHash = (Get-AdoBodyCanonicalHash -Body $mVgBody) })
    Reset-MockWebRequest
    Add-MockWebSuccessResponse -ResultId 'nunca-deberia-quedar-registrado'
    Set-MockJournalWriteFailure -FailOnCallNumber 2  # 1a escritura (in-progress) OK, 2a (succeeded) falla
    Invoke-ExpectThrow -Name 'Journal: exito de red + fallo al escribir journal -> estado incierto explicito, nunca en silencio' `
        -ExpectedMessagePattern 'Estado incierto' -Block {
        Invoke-AdoRest -Method POST -Uri $vgUri -Body $mVgBody -RequireApprovedPlan -PlanPath $planM7 -OperationId 'm7-op' -JournalLockTimeoutMs 2000
    }
    Set-MockJournalWriteFailure -FailOnCallNumber -1
    $planM7Hash = (Get-Content -LiteralPath $planM7 -Raw | ConvertFrom-Json).validationHash
    $journalM7 = Get-Content -LiteralPath (Get-AdoExecutionJournalPath -PlanValidationHash $planM7Hash) -Raw | ConvertFrom-Json
    Add-Result -Name 'Journal: exito + fallo al escribir -> la entrada queda "in-progress" (bloquea reintento igual)' `
        -Pass ($journalM7.operations.'m7-op'.state -eq 'in-progress') -Detail "state=$($journalM7.operations.'m7-op'.state)"
    Invoke-ExpectThrow -Name 'Journal: no se puede reintentar automaticamente una operacion "in-progress"' `
        -ExpectedMessagePattern "ya tiene estado 'in-progress'" -Block {
        Invoke-AdoRest -Method POST -Uri $vgUri -Body $mVgBody -RequireApprovedPlan -PlanPath $planM7 -OperationId 'm7-op' -JournalLockTimeoutMs 2000
    }

    # M8: journal corrupto (JSON invalido) -> bloqueo seguro, nunca se asume un estado
    $planM8 = New-FakeApprovedPlan -ApprovedOperations @(@{ operationId = 'm8-op'; operationType = 'create-variable-group'; method = 'POST'; uri = $vgUri; bodyHash = (Get-AdoBodyCanonicalHash -Body $mVgBody) })
    $planM8Hash = (Get-Content -LiteralPath $planM8 -Raw | ConvertFrom-Json).validationHash
    $journalPathM8 = Get-AdoExecutionJournalPath -PlanValidationHash $planM8Hash
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $journalPathM8) | Out-Null
    Set-Content -LiteralPath $journalPathM8 -Value '{ esto no es json valido ' -Encoding utf8
    Reset-MockWebRequest
    Invoke-ExpectThrow -Name 'Journal: archivo corrupto (JSON invalido) -> bloqueo seguro (throw, nunca se asume estado)' `
        -ExpectedMessagePattern 'corrupto' -Block {
        Invoke-AdoRest -Method POST -Uri $vgUri -Body $mVgBody -RequireApprovedPlan -PlanPath $planM8 -OperationId 'm8-op' -JournalLockTimeoutMs 2000
    }
    Add-Result -Name 'Journal: archivo corrupto -> cero llamadas HTTP (nunca procede sobre un estado desconocido)' `
        -Pass ($script:mockWebCallCount -eq 0) -Detail "mockWebCallCount=$($script:mockWebCallCount)"

    # M9: journal existente con planValidationHash de OTRO plan -> bloqueo seguro
    $planM9 = New-FakeApprovedPlan -ApprovedOperations @(@{ operationId = 'm9-op'; operationType = 'create-variable-group'; method = 'POST'; uri = $vgUri; bodyHash = (Get-AdoBodyCanonicalHash -Body $mVgBody) })
    $planM9Hash = (Get-Content -LiteralPath $planM9 -Raw | ConvertFrom-Json).validationHash
    $journalPathM9 = Get-AdoExecutionJournalPath -PlanValidationHash $planM9Hash
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $journalPathM9) | Out-Null
    ([PSCustomObject]@{ planValidationHash = ('0' * 64); createdAtUtc = (Get-Date).ToUniversalTime().ToString('o'); operations = [PSCustomObject]@{} }) | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $journalPathM9 -Encoding utf8
    Reset-MockWebRequest
    Invoke-ExpectThrow -Name 'Journal: planValidationHash del journal no coincide con este plan -> bloqueo seguro' `
        -ExpectedMessagePattern 'no coincide con este plan' -Block {
        Invoke-AdoRest -Method POST -Uri $vgUri -Body $mVgBody -RequireApprovedPlan -PlanPath $planM9 -OperationId 'm9-op' -JournalLockTimeoutMs 2000
    }

    # ============================================================
    # Grupo P: exactitud del journal contra el manifiesto aprobado (item 1
    # ampliado) -- un journal EXISTENTE debe tener EXACTAMENTE el mismo
    # conjunto de operationIds que plan.approvedOperations. Falta una,
    # sobra una, duplicada en el texto crudo, o con forma/estado invalido
    # -> corrupto, bloqueo seguro. Todo con datos ficticios, sin red real.
    # ============================================================

    function New-FakeApprovedPlanTwoOps {
        # Plan con 2 operaciones aprobadas (VG + Build), para poder armar
        # journals con una operationId de mas o de menos respecto al plan.
        # -Suffix hace que CADA llamada produzca approvedOperations (y por
        # lo tanto un validationHash, y por lo tanto una ruta de journal)
        # DISTINTOS -- sin esto, dos llamadas con el mismo body producen
        # el MISMO hash y terminan compartiendo (pisandose) el mismo
        # archivo de journal entre pruebas distintas de este grupo.
        param([Parameter(Mandatory)] [string]$Suffix)
        $ops = @(
            @{ operationId = "p-vg-$Suffix"; operationType = 'create-variable-group'; method = 'POST'; uri = $vgUri; bodyHash = (Get-AdoBodyCanonicalHash -Body @{ name = "P-Ficticio-$Suffix" }) },
            @{ operationId = "p-build-$Suffix"; operationType = 'create-build-definition'; method = 'POST'; uri = $buildDefUri; bodyHash = (Get-AdoBodyCanonicalHash -Body @{ name = "P-Ficticio-Build-$Suffix" }) }
        )
        return New-FakeApprovedPlan -ApprovedOperations $ops
    }

    # P1: journal existente le FALTA una operacion que si esta en el plan -> corrupto
    $planP1 = New-FakeApprovedPlanTwoOps -Suffix 'P1'
    $planP1Hash = (Get-Content -LiteralPath $planP1 -Raw | ConvertFrom-Json).validationHash
    $journalPathP1 = Get-AdoExecutionJournalPath -PlanValidationHash $planP1Hash
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $journalPathP1) | Out-Null
    ([PSCustomObject]@{
        planValidationHash = $planP1Hash
        createdAtUtc        = (Get-Date).ToUniversalTime().ToString('o')
        operations          = [PSCustomObject]@{ 'p-vg-P1' = [PSCustomObject]@{ state = 'pending'; startedAtUtc = $null; completedAtUtc = $null; resultId = $null } }
    }) | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $journalPathP1 -Encoding utf8
    Reset-MockWebRequest
    Invoke-ExpectThrow -Name 'Journal exacto: falta una operacion del plan en el journal existente -> corrupto' `
        -ExpectedMessagePattern "falta\(n\) la\(s\) operacion" -Block {
        Invoke-AdoRest -Method POST -Uri $vgUri -Body @{ name = 'P-Ficticio-P1' } -RequireApprovedPlan -PlanPath $planP1 -OperationId 'p-vg-P1' -JournalLockTimeoutMs 2000
    }
    Add-Result -Name 'Journal exacto: cero llamadas HTTP cuando el journal esta corrupto (falta operacion)' -Pass ($script:mockWebCallCount -eq 0) -Detail "mockWebCallCount=$($script:mockWebCallCount)"

    # P2: journal existente tiene una operacion EXTRA que no esta en el plan -> corrupto
    $planP2 = New-FakeApprovedPlanTwoOps -Suffix 'P2'
    $planP2Hash = (Get-Content -LiteralPath $planP2 -Raw | ConvertFrom-Json).validationHash
    $journalPathP2 = Get-AdoExecutionJournalPath -PlanValidationHash $planP2Hash
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $journalPathP2) | Out-Null
    ([PSCustomObject]@{
        planValidationHash = $planP2Hash
        createdAtUtc        = (Get-Date).ToUniversalTime().ToString('o')
        operations          = [PSCustomObject]@{
            'p-vg-P2'          = [PSCustomObject]@{ state = 'pending'; startedAtUtc = $null; completedAtUtc = $null; resultId = $null }
            'p-build-P2'       = [PSCustomObject]@{ state = 'pending'; startedAtUtc = $null; completedAtUtc = $null; resultId = $null }
            'p-operacion-extra' = [PSCustomObject]@{ state = 'pending'; startedAtUtc = $null; completedAtUtc = $null; resultId = $null }
        }
    }) | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $journalPathP2 -Encoding utf8
    Reset-MockWebRequest
    Invoke-ExpectThrow -Name 'Journal exacto: sobra una operacion en el journal existente que no esta en el plan -> corrupto' `
        -ExpectedMessagePattern 'tiene la\(s\) operacion' -Block {
        Invoke-AdoRest -Method POST -Uri $vgUri -Body @{ name = 'P-Ficticio-P2' } -RequireApprovedPlan -PlanPath $planP2 -OperationId 'p-vg-P2' -JournalLockTimeoutMs 2000
    }

    # P3: journal con operationId DUPLICADO en el texto crudo -> corrupto
    # (se escribe a mano el texto para producir dos claves iguales -- algo
    # que Write-AdoExecutionJournalAtomic nunca produciria por si solo).
    $planP3 = New-FakeApprovedPlanTwoOps -Suffix 'P3'
    $planP3Hash = (Get-Content -LiteralPath $planP3 -Raw | ConvertFrom-Json).validationHash
    $journalPathP3 = Get-AdoExecutionJournalPath -PlanValidationHash $planP3Hash
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $journalPathP3) | Out-Null
    $dupJson = @"
{
  "planValidationHash": "$planP3Hash",
  "createdAtUtc": "$((Get-Date).ToUniversalTime().ToString('o'))",
  "operations": {
    "p-vg-P3": { "state": "pending", "startedAtUtc": null, "completedAtUtc": null, "resultId": null },
    "p-build-P3": { "state": "pending", "startedAtUtc": null, "completedAtUtc": null, "resultId": null },
    "p-vg-P3": { "state": "succeeded", "startedAtUtc": null, "completedAtUtc": null, "resultId": "fake-id" }
  }
}
"@
    Set-Content -LiteralPath $journalPathP3 -Value $dupJson -Encoding utf8
    Reset-MockWebRequest
    Invoke-ExpectThrow -Name 'Journal exacto: operationId duplicado en el texto crudo -> corrupto' `
        -ExpectedMessagePattern 'operationId duplicado en el texto crudo' -Block {
        Invoke-AdoRest -Method POST -Uri $vgUri -Body @{ name = 'P-Ficticio-P3' } -RequireApprovedPlan -PlanPath $planP3 -OperationId 'p-vg-P3' -JournalLockTimeoutMs 2000
    }

    # P4: journal con un 'state' invalido -> corrupto
    $planP4 = New-FakeApprovedPlanTwoOps -Suffix 'P4'
    $planP4Hash = (Get-Content -LiteralPath $planP4 -Raw | ConvertFrom-Json).validationHash
    $journalPathP4 = Get-AdoExecutionJournalPath -PlanValidationHash $planP4Hash
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $journalPathP4) | Out-Null
    ([PSCustomObject]@{
        planValidationHash = $planP4Hash
        createdAtUtc        = (Get-Date).ToUniversalTime().ToString('o')
        operations          = [PSCustomObject]@{
            'p-vg-P4'    = [PSCustomObject]@{ state = 'finalizado-invalido'; startedAtUtc = $null; completedAtUtc = $null; resultId = $null }
            'p-build-P4' = [PSCustomObject]@{ state = 'pending'; startedAtUtc = $null; completedAtUtc = $null; resultId = $null }
        }
    }) | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $journalPathP4 -Encoding utf8
    Reset-MockWebRequest
    Invoke-ExpectThrow -Name 'Journal exacto: estado invalido en una operacion -> corrupto' `
        -ExpectedMessagePattern 'estado invalido' -Block {
        Invoke-AdoRest -Method POST -Uri $vgUri -Body @{ name = 'P-Ficticio-P4' } -RequireApprovedPlan -PlanPath $planP4 -OperationId 'p-vg-P4' -JournalLockTimeoutMs 2000
    }

    # P5: journal con una operacion de forma invalida (falta 'resultId') -> corrupto
    $planP5 = New-FakeApprovedPlanTwoOps -Suffix 'P5'
    $planP5Hash = (Get-Content -LiteralPath $planP5 -Raw | ConvertFrom-Json).validationHash
    $journalPathP5 = Get-AdoExecutionJournalPath -PlanValidationHash $planP5Hash
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $journalPathP5) | Out-Null
    ([PSCustomObject]@{
        planValidationHash = $planP5Hash
        createdAtUtc        = (Get-Date).ToUniversalTime().ToString('o')
        operations          = [PSCustomObject]@{
            'p-vg-P5'    = [PSCustomObject]@{ state = 'pending'; startedAtUtc = $null; completedAtUtc = $null }
            'p-build-P5' = [PSCustomObject]@{ state = 'pending'; startedAtUtc = $null; completedAtUtc = $null; resultId = $null }
        }
    }) | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $journalPathP5 -Encoding utf8
    Reset-MockWebRequest
    Invoke-ExpectThrow -Name 'Journal exacto: operacion con forma invalida (falta resultId) -> corrupto' `
        -ExpectedMessagePattern 'forma invalida' -Block {
        Invoke-AdoRest -Method POST -Uri $vgUri -Body @{ name = 'P-Ficticio-P5' } -RequireApprovedPlan -PlanPath $planP5 -OperationId 'p-vg-P5' -JournalLockTimeoutMs 2000
    }

    # P6: journal donde, cuando NO existia, se crea con TODAS las
    # operaciones aprobadas en pending (no solo la que se esta iniciando)
    # -- comportamiento ya existente, se reconfirma explicitamente aca.
    $planP6 = New-FakeApprovedPlanTwoOps -Suffix 'P6'
    $planP6Hash = (Get-Content -LiteralPath $planP6 -Raw | ConvertFrom-Json).validationHash
    Reset-MockWebRequest
    Add-MockWebSuccessResponse -ResultId 'p6-vg-id'
    Invoke-ExpectNoThrow -Name 'Journal exacto: plan nuevo sin journal previo -> primera operacion procede con exito' -Block {
        Invoke-AdoRest -Method POST -Uri $vgUri -Body @{ name = 'P-Ficticio-P6' } -RequireApprovedPlan -PlanPath $planP6 -OperationId 'p-vg-P6' -JournalLockTimeoutMs 2000
    }
    $journalP6 = Get-Content -LiteralPath (Get-AdoExecutionJournalPath -PlanValidationHash $planP6Hash) -Raw | ConvertFrom-Json
    Add-Result -Name 'Journal exacto: al crearse por primera vez, incluye TODAS las operaciones aprobadas (no solo la iniciada)' `
        -Pass ($journalP6.operations.PSObject.Properties.Name.Count -eq 2 -and $journalP6.operations.'p-build-P6'.state -eq 'pending') `
        -Detail "operations=$($journalP6 | ConvertTo-Json -Compress -Depth 5)"

    # ============================================================
    # Grupo Q: reproduccion del escenario de duplicado real -- operacion
    # ejecutada con exito, journal borrado por accidente, segundo intento
    # DEBE quedar bloqueado por el chequeo en vivo (independiente del
    # journal), nunca crea un recurso duplicado. Usa Invoke-AdoApplyPhases
    # (la logica real de las 3 fases), con Invoke-WebRequest mockeado.
    # ============================================================

    function Add-MockWebListResponse {
        param([array]$Items = @())
        $content = ([PSCustomObject]@{ value = $Items }) | ConvertTo-Json -Compress -Depth 10
        $script:mockWebResponseQueue.Enqueue([PSCustomObject]@{ Throw = $false; StatusCode = 200; Content = $content })
    }

    function New-FakePlanForApplyPhases {
        param([string]$VgName, [string[]]$ApprovedOperationTypes)
        $vgBodyLocal = New-AdoVariableGroupPayload -Plan ([PSCustomObject]@{ project = 'DevOps'; variableGroup = [PSCustomObject]@{ name = $VgName; keys = [PSCustomObject]@{ ambiente = 'dev' } } })
        $ops = [System.Collections.Generic.List[object]]::new()
        if ($ApprovedOperationTypes -contains 'create-variable-group') {
            $ops.Add(@{ operationId = 'q-vg'; operationType = 'create-variable-group'; method = 'POST'; uri = $vgUri; bodyHash = (Get-AdoBodyCanonicalHash -Body $vgBodyLocal) })
        }
        $planObj = [PSCustomObject]@{
            family        = 'aks'
            organization  = 'Shared-Service-GM'
            project       = 'DevOps'
            names         = [PSCustomObject]@{ build = "Build-$VgName"; release = "Deploy-$VgName"; variableGroup = $VgName; folder = '\Ficticio' }
            variableGroup = [PSCustomObject]@{ name = $VgName; keys = [PSCustomObject]@{ ambiente = 'dev' } }
            approvedOperations = @($ops)
            validated     = $false
            validationHash = $null
        }
        $planObj.validated = $true
        $planObj.validationHash = Get-AdoPlanCanonicalHash -Plan $planObj
        $path = Join-Path $testTempRoot ("fake-apply-plan-{0}.json" -f ([Guid]::NewGuid().ToString('N')))
        $planObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
        return $path
    }

    $planQPath = New-FakePlanForApplyPhases -VgName 'Q-Duplicado-Test' -ApprovedOperationTypes @('create-variable-group')
    $planQ = Get-Content -LiteralPath $planQPath -Raw | ConvertFrom-Json

    # Primer intento: GET de duplicado (vacio, no existe) + POST exitoso.
    Reset-MockWebRequest
    Add-MockWebListResponse -Items @()
    Add-MockWebSuccessResponse -ResultId 'q-vg-real-id'
    $createdListQ1 = [System.Collections.Generic.List[string]]::new()
    Invoke-ExpectNoThrow -Name 'Duplicado real: primer intento crea el Variable Group con exito' -Block {
        Invoke-AdoApplyPhases -Plan $planQ -PlanPath $planQPath -CreatedSoFar $createdListQ1
    }
    Add-Result -Name 'Duplicado real: primer intento -> exactamente 2 llamadas HTTP (GET duplicado + POST)' -Pass ($script:mockWebCallCount -eq 2) -Detail "mockWebCallCount=$($script:mockWebCallCount)"

    # Journal borrado "por accidente".
    $journalPathQ = Get-AdoExecutionJournalPath -PlanValidationHash $planQ.validationHash
    Remove-Item -LiteralPath $journalPathQ -Force -ErrorAction SilentlyContinue
    Add-Result -Name 'Duplicado real: journal efectivamente borrado antes del segundo intento' -Pass (-not (Test-Path -LiteralPath $journalPathQ)) -Detail "journalPath=$journalPathQ"

    # Segundo intento: el journal ya no tiene memoria (se veria como
    # 'pending'/nuevo), PERO el chequeo en vivo (GET) ahora SI devuelve el
    # recurso real -- debe bloquear ANTES de cualquier POST.
    Reset-MockWebRequest
    Add-MockWebListResponse -Items @(@{ id = 999; name = 'Q-Duplicado-Test' })
    $createdListQ2 = [System.Collections.Generic.List[string]]::new()
    Invoke-ExpectThrow -Name 'Duplicado real: segundo intento (journal borrado) queda BLOQUEADO por el chequeo en vivo, no crea un duplicado' `
        -ExpectedMessagePattern 'ya existe un Variable Group' -Block {
        Invoke-AdoApplyPhases -Plan $planQ -PlanPath $planQPath -CreatedSoFar $createdListQ2
    }
    Add-Result -Name 'Duplicado real: segundo intento -> CERO llamadas POST (solo el GET de duplicado)' -Pass ($script:mockWebCallCount -eq 1) -Detail "mockWebCallCount=$($script:mockWebCallCount)"
    Add-Result -Name 'Duplicado real: segundo intento -> CreatedSoFar queda vacio (nada se creo)' -Pass ($createdListQ2.Count -eq 0) -Detail "CreatedSoFar=$($createdListQ2 -join ' | ')"

    # ============================================================
    # Grupo R: Assert-AdoOperationRequestMatchesSpec -- re-validacion
    # INDEPENDIENTE de Invoke-AdoRest inmediatamente antes de escribir.
    # Se aprueba a mano (bypaseando Test-AdoClassicPlan.ps1, igual que el
    # Grupo J) un plan con una operacion cuya URI ya es invalida para su
    # operationType, y se llama con ESA MISMA uri (para que el chequeo
    # literal matchedOp.uri==Uri pase) -- demuestra que esta segunda capa
    # de validacion la atrapa igual, sin depender de que
    # Test-AdoClassicPlan.ps1 la hubiera detectado antes.
    # ============================================================

    # R1: host incorrecto para create-release-definition (deberia ir a vsrm., no dev.azure.com)
    $badHostUri = $releaseDefUri -replace 'vsrm\.dev\.azure\.com', 'dev.azure.com'
    $r1Body = @{ name = 'R-Ficticio' }
    $r1Op = @{ operationId = 'r1'; operationType = 'create-release-definition'; method = 'POST'; uri = $badHostUri; bodyHash = (Get-AdoBodyCanonicalHash -Body $r1Body) }
    $planR1 = New-FakeApprovedPlan -ApprovedOperations @($r1Op)
    Invoke-ExpectThrow -Name 'Invoke-AdoRest (re-validacion independiente): host incorrecto para el operationType -> rechazado antes de escribir' `
        -ExpectedMessagePattern 'debe usar el host' -Block {
        Invoke-AdoRest -Method POST -Uri $badHostUri -Body $r1Body -RequireApprovedPlan -PlanPath $planR1 -OperationId 'r1'
    }

    # R2: query duplicada (api-version aparece 2 veces) en la uri aprobada
    $dupQueryUri = "$buildDefUri&api-version=7.1"
    $r2Body = @{ name = 'R-Ficticio-2' }
    $r2Op = @{ operationId = 'r2'; operationType = 'create-build-definition'; method = 'POST'; uri = $dupQueryUri; bodyHash = (Get-AdoBodyCanonicalHash -Body $r2Body) }
    $planR2 = New-FakeApprovedPlan -ApprovedOperations @($r2Op)
    Invoke-ExpectThrow -Name 'Invoke-AdoRest (re-validacion independiente): query duplicada -> rechazado antes de escribir' `
        -ExpectedMessagePattern 'parametro de query.*duplicado' -Block {
        Invoke-AdoRest -Method POST -Uri $dupQueryUri -Body $r2Body -RequireApprovedPlan -PlanPath $planR2 -OperationId 'r2'
    }

    # R3: ruta con id de recurso al final en la uri aprobada
    $idSuffixUri = $buildDefUri -replace '/definitions\?', '/definitions/424242?'
    $r3Body = @{ name = 'R-Ficticio-3' }
    $r3Op = @{ operationId = 'r3'; operationType = 'create-build-definition'; method = 'POST'; uri = $idSuffixUri; bodyHash = (Get-AdoBodyCanonicalHash -Body $r3Body) }
    $planR3 = New-FakeApprovedPlan -ApprovedOperations @($r3Op)
    Invoke-ExpectThrow -Name 'Invoke-AdoRest (re-validacion independiente): id de recurso al final de la ruta -> rechazado antes de escribir' `
        -ExpectedMessagePattern 'debe tener exactamente la ruta' -Block {
        Invoke-AdoRest -Method POST -Uri $idSuffixUri -Body $r3Body -RequireApprovedPlan -PlanPath $planR3 -OperationId 'r3'
    }

    # R4: metodo diferente de POST (aunque spec.method siempre es POST
    # para los 3 tipos permitidos, se confirma el rechazo end-to-end)
    $r4Op = @{ operationId = 'r4'; operationType = 'create-build-definition'; method = 'POST'; uri = $buildDefUri; bodyHash = (Get-AdoBodyCanonicalHash -Body @{ name = 'R4' }) }
    $planR4 = New-FakeApprovedPlan -ApprovedOperations @($r4Op)
    Invoke-ExpectThrow -Name 'Invoke-AdoRest (re-validacion independiente): metodo DELETE contra operacion aprobada como POST -> rechazado' `
        -ExpectedMessagePattern 'el metodo aprobado' -Block {
        Invoke-AdoRest -Method DELETE -Uri $buildDefUri -Body @{ name = 'R4' } -RequireApprovedPlan -PlanPath $planR4 -OperationId 'r4'
    }

    # ============================================================
    # Grupo R-PUT: Assert-AdoOperationRequestMatchesSpec / operationTypes
    # 'update-build-definition' y 'update-release-definition' (PUT,
    # agregados 2026-08-25) -- mismo nivel de rigor que el Grupo R para
    # los 3 tipos POST, pero cubriendo requiresIdSuffix.
    # ============================================================

    $updateBuildUri = "$buildDefUri" -replace '/definitions\?', '/definitions/622?'
    $updateReleaseUri = "$releaseDefUri" -replace '/definitions\?', '/definitions/381?'

    Add-Result -Name 'Assert-AdoOperationRequestMatchesSpec: update-build-definition con id numerico -> valido' `
        -Pass ($null -ne (Assert-AdoOperationRequestMatchesSpec -OperationType 'update-build-definition' -Method 'PUT' -Uri $updateBuildUri -Label 'rput1')) -Detail 'OK'

    Add-Result -Name 'Assert-AdoOperationRequestMatchesSpec: update-release-definition con id numerico -> valido' `
        -Pass ($null -ne (Assert-AdoOperationRequestMatchesSpec -OperationType 'update-release-definition' -Method 'PUT' -Uri $updateReleaseUri -Label 'rput2')) -Detail 'OK'

    Invoke-ExpectThrow -Name 'Assert-AdoOperationRequestMatchesSpec: update-build-definition SIN id de recurso -> rechazado' `
        -ExpectedMessagePattern 'id numerico' -Block {
        Assert-AdoOperationRequestMatchesSpec -OperationType 'update-build-definition' -Method 'PUT' -Uri $buildDefUri -Label 'rput3'
    }

    Invoke-ExpectThrow -Name 'Assert-AdoOperationRequestMatchesSpec: update-build-definition con id NO numerico -> rechazado' `
        -ExpectedMessagePattern 'id numerico' -Block {
        Assert-AdoOperationRequestMatchesSpec -OperationType 'update-build-definition' -Method 'PUT' -Uri ($buildDefUri -replace '/definitions\?', '/definitions/abc?') -Label 'rput4'
    }

    Invoke-ExpectThrow -Name 'Assert-AdoOperationRequestMatchesSpec: update-build-definition con metodo POST (en vez de PUT) -> rechazado' `
        -ExpectedMessagePattern "method debe ser 'PUT'" -Block {
        Assert-AdoOperationRequestMatchesSpec -OperationType 'update-build-definition' -Method 'POST' -Uri $updateBuildUri -Label 'rput5'
    }

    Invoke-ExpectThrow -Name 'Assert-AdoOperationRequestMatchesSpec: create-build-definition (POST) CON id de recurso -> sigue rechazado (requiresIdSuffix no aplica a los tipos create)' `
        -ExpectedMessagePattern 'debe tener exactamente la ruta' -Block {
        Assert-AdoOperationRequestMatchesSpec -OperationType 'create-build-definition' -Method 'POST' -Uri $updateBuildUri -Label 'rput6'
    }

    # R-PUT7: end-to-end real -- Invoke-AdoRest con un update-build-definition
    # aprobado, mockeando una respuesta PUT exitosa, confirma que el flujo
    # completo (bodyHash + spec + journal) funciona igual que para POST.
    $rPutBody = @{ id = 622; name = 'Build-Ficticio-Actualizado' }
    $rPutOp = @{ operationId = 'rput7'; operationType = 'update-build-definition'; method = 'PUT'; uri = $updateBuildUri; bodyHash = (Get-AdoBodyCanonicalHash -Body $rPutBody) }
    $planRPut7 = New-FakeApprovedPlan -ApprovedOperations @($rPutOp)
    Reset-MockWebRequest
    Add-MockWebSuccessResponse -ResultId 622
    Invoke-ExpectNoThrow -Name 'Invoke-AdoRest: update-build-definition (PUT) end-to-end con body/spec/journal aprobados -> exitoso' -Block {
        Invoke-AdoRest -Method PUT -Uri $updateBuildUri -Body $rPutBody -RequireApprovedPlan -PlanPath $planRPut7 -OperationId 'rput7'
    }

    # ============================================================
    # Grupo S: constructores de payload deterministas
    # (New-AdoClassicPayloads.ps1) -- unit tests con datos ficticios.
    # ============================================================

    $fixturePlan = [PSCustomObject]@{
        family   = 'aks'
        project  = 'DevOps'
        names    = [PSCustomObject]@{ build = 'Build-S-Ficticio'; release = 'Deploy-S-Ficticio'; folder = '\S-Ficticio' }
        repo     = [PSCustomObject]@{ id = 'repo-s-1'; name = 'repo-s-ficticio'; project = 'Proyecto-App-S'; prodBranch = 'release'; ciBranchFilters = @('development', 'uat', 'release'); ciBatchChangesEnabled = $false }
        buildVariables = [PSCustomObject]@{ conexcontainerregistries = 'ACR-S-Ficticia'; rutadockerfile = './Dockerfile'; tag = '$(Build.BuildId)'; 'system.debug' = 'false'; image = 's-ficticio-web-'; servicesname = 's-ficticio-web' }
        dependencies = [PSCustomObject]@{ buildTaskGroup = [PSCustomObject]@{ name = 'Build-MultiStage'; id = 'tg-build-s'; revision = 7 }; agentPool = $null }
        variableGroup = [PSCustomObject]@{ name = 'Desarrollo-S-Ficticio'; keys = [PSCustomObject]@{ ambiente = 'dev'; servicesname = 's-ficticio-web'; namespace = 'desarrollo'; tag = '$(Build.BuildId)' } }
    }

    $vgPayloadS = New-AdoVariableGroupPayload -Plan $fixturePlan
    Add-Result -Name 'New-AdoVariableGroupPayload: name/type correctos' `
        -Pass ($vgPayloadS.name -eq 'Desarrollo-S-Ficticio' -and $vgPayloadS.type -eq 'Vsts') `
        -Detail "name=$($vgPayloadS.name); type=$($vgPayloadS.type)"
    Add-Result -Name 'New-AdoVariableGroupPayload: cada variable queda como {value:string}' `
        -Pass ($vgPayloadS.variables.ambiente.value -eq 'dev' -and $vgPayloadS.variables.namespace.value -eq 'desarrollo') `
        -Detail ($vgPayloadS.variables | ConvertTo-Json -Compress)
    Add-Result -Name 'New-AdoVariableGroupPayload: variableGroupProjectReferences con el GUID real de DevOps (2026-08-25, requerido por la org real)' `
        -Pass ($vgPayloadS.variableGroupProjectReferences.Count -eq 1 -and $vgPayloadS.variableGroupProjectReferences[0].projectReference.id -eq '7f632f4b-b3cb-4530-a5ff-ee9f809ab478' -and $vgPayloadS.variableGroupProjectReferences[0].projectReference.name -eq 'DevOps' -and $vgPayloadS.variableGroupProjectReferences[0].name -eq 'Desarrollo-S-Ficticio') `
        -Detail ($vgPayloadS.variableGroupProjectReferences | ConvertTo-Json -Compress -Depth 5)
    Invoke-ExpectThrow -Name 'New-AdoVariableGroupPayload: proyecto sin mapeo de id conocido -> rechazado, nunca inventa un GUID' `
        -ExpectedMessagePattern "no se pudo resolver el id real del proyecto" -Block {
        New-AdoVariableGroupPayload -Plan ([PSCustomObject]@{ project = 'Otro-Proyecto-Sin-Mapear'; variableGroup = [PSCustomObject]@{ name = 'X'; keys = [PSCustomObject]@{ ambiente = 'dev' } } })
    }

    $manifestsS = @{ dev = 'contenido-dev-ficticio'; uat = 'contenido-uat-ficticio'; prod = 'contenido-prod-ficticio' }
    Invoke-ExpectThrow -Name 'New-AdoBuildDefinitionPayload: falta un manifiesto (prod) -> rechazado' `
        -ExpectedMessagePattern "falta DeploymentManifests\['prod'\]" -Block {
        New-AdoBuildDefinitionPayload -Plan $fixturePlan -DeploymentManifests @{ dev = 'x'; uat = 'y' }
    }

    $buildPayloadS = New-AdoBuildDefinitionPayload -Plan $fixturePlan -DeploymentManifests $manifestsS
    Add-Result -Name 'New-AdoBuildDefinitionPayload: usa image (contrato vigente de Build-MultiStage), nunca servicesname' `
        -Pass ($buildPayloadS.variables.image.value -eq 's-ficticio-web-' -and -not $buildPayloadS.variables.PSObject.Properties.Name.Contains('servicesname')) `
        -Detail ($buildPayloadS.variables | ConvertTo-Json -Compress)
    Add-Result -Name 'New-AdoBuildDefinitionPayload: triggers.branchFilters con las 3 ramas del plan, prefijo +refs/heads/' `
        -Pass ((@($buildPayloadS.triggers[0].branchFilters) -join ',') -eq '+refs/heads/development,+refs/heads/uat,+refs/heads/release') `
        -Detail ($buildPayloadS.triggers[0].branchFilters -join ', ')
    $prodStepS = $buildPayloadS.process.phases[0].steps | Where-Object { $_.displayName -eq 'File Creator deployment-prod.yml' }
    $devStepS = $buildPayloadS.process.phases[0].steps | Where-Object { $_.displayName -eq 'File Creator deployment-dev.yml' }
    Add-Result -Name 'New-AdoBuildDefinitionPayload: step deployment-prod.yml queda enabled=false' -Pass ($prodStepS.enabled -eq $false) -Detail "enabled=$($prodStepS.enabled)"
    Add-Result -Name 'New-AdoBuildDefinitionPayload: step deployment-dev.yml queda enabled=true' -Pass ($devStepS.enabled -eq $true) -Detail "enabled=$($devStepS.enabled)"
    $buildTgStepS = $buildPayloadS.process.phases[0].steps | Where-Object { $_.displayName -eq 'Task group: Build-MultiStage' }
    Add-Result -Name 'New-AdoBuildDefinitionPayload: displayName dinamico + id de buildTaskGroup YA RESUELTO (nunca inventado)' `
        -Pass ($buildTgStepS.task.id -eq 'tg-build-s') `
        -Detail "displayName=$($buildTgStepS.displayName); task.id=$($buildTgStepS.task.id)"
    Add-Result -Name 'New-AdoBuildDefinitionPayload: inputs = contrato Build-MultiStage (ambiente/ambienteOverride/conexcontainerregistries/image/rutadockerfile/tag), sin servicesname' `
        -Pass ($buildTgStepS.inputs.ambienteOverride -eq 'auto' -and $buildTgStepS.inputs.image -eq '$(image)' -and -not $buildTgStepS.inputs.PSObject.Properties.Name.Contains('servicesname')) `
        -Detail ($buildTgStepS.inputs | ConvertTo-Json -Compress)
    Add-Result -Name 'New-AdoBuildDefinitionPayload: repository.url usa el proyecto REAL del repo (cross-project), no DevOps' `
        -Pass ($buildPayloadS.repository.url -eq 'https://dev.azure.com/Shared-Service-GM/Proyecto-App-S/_git/repo-s-ficticio') `
        -Detail "repository.url=$($buildPayloadS.repository.url)"

    Invoke-ExpectThrow -Name 'New-AdoBuildDefinitionPayload: falta plan.buildVariables.image (contrato Build-MultiStage) -> rechazado' `
        -ExpectedMessagePattern 'falta plan\.buildVariables\.image' -Block {
        $planSinImage = [PSCustomObject]@{
            family = 'aks'; project = 'DevOps'
            names = [PSCustomObject]@{ build = 'Build-SinImage'; release = 'Deploy-SinImage'; folder = '\SinImage' }
            repo = [PSCustomObject]@{ id = 'repo-sinimage'; name = 'repo-sinimage'; project = 'Proyecto-App-S'; prodBranch = 'release'; ciBranchFilters = @('development', 'uat', 'release'); ciBatchChangesEnabled = $false }
            buildVariables = [PSCustomObject]@{ conexcontainerregistries = 'ACR-X'; rutadockerfile = './Dockerfile'; tag = '$(Build.BuildId)'; 'system.debug' = 'false' }
            dependencies = [PSCustomObject]@{ buildTaskGroup = [PSCustomObject]@{ name = 'Build-MultiStage'; id = 'tg-x'; revision = 1 }; agentPool = $null }
            variableGroup = [PSCustomObject]@{ name = 'X'; keys = [PSCustomObject]@{ ambiente = 'dev' } }
        }
        New-AdoBuildDefinitionPayload -Plan $planSinImage -DeploymentManifests $manifestsS
    }

    $customInputsS = [ordered]@{ ambiente = '$(ambiente)'; conexcontainerregistries = '$(conexcontainerregistries)'; rutadockerfile = '$(rutadockerfile)'; servicesname = '$(servicesname)'; tag = '$(tag)' }
    $buildPayloadCustomInputs = New-AdoBuildDefinitionPayload -Plan $fixturePlan -DeploymentManifests $manifestsS -BuildTaskGroupInputs $customInputsS
    $buildTgStepCustom = $buildPayloadCustomInputs.process.phases[0].steps | Where-Object { $_.displayName -eq 'Task group: Build-MultiStage' }
    Add-Result -Name 'New-AdoBuildDefinitionPayload: -BuildTaskGroupInputs sobreescribe el contrato default (nunca lo adivina por el nombre)' `
        -Pass ($buildTgStepCustom.inputs.servicesname -eq '$(servicesname)' -and -not $buildTgStepCustom.inputs.PSObject.Properties.Name.Contains('image')) `
        -Detail ($buildTgStepCustom.inputs | ConvertTo-Json -Compress)

    Invoke-ExpectThrow -Name 'New-AdoReleaseDefinitionPayload: -Environments vacio -> rechazado' `
        -ExpectedMessagePattern 'no puede estar vacio' -Block {
        New-AdoReleaseDefinitionPayload -Plan $fixturePlan -Environments @() -BuildDefinitionId 1 -BuildDefinitionName 'Build-S-Ficticio'
    }
    Invoke-ExpectThrow -Name 'New-AdoReleaseDefinitionPayload: environment sin variableGroupId -> rechazado' `
        -ExpectedMessagePattern "falta 'variableGroupId'" -Block {
        New-AdoReleaseDefinitionPayload -Plan $fixturePlan -Environments @(@{ stage = 'Desarrollo'; artifactFilterBranch = 'development'; deployTaskGroupId = 'tg-x'; deployTaskGroupInputs = @{} }) -BuildDefinitionId 1 -BuildDefinitionName 'Build-S-Ficticio'
    }

    $envsS = @(
        @{ stage = 'Desarrollo'; variableGroupId = 501; artifactFilterBranch = 'development'; deployTaskGroupId = 'tg-deploy-dev'; deployTaskGroupName = 'Deployment-MultiStage-Cluster-Desarrollo'; deployTaskGroupInputs = @{ ambiente = '$(ambiente)' }; approvalRequired = $false },
        @{ stage = 'UAT'; variableGroupId = 502; artifactFilterBranch = 'uat'; deployTaskGroupId = 'tg-deploy-dev'; deployTaskGroupName = 'Deployment-MultiStage-Cluster-Desarrollo'; deployTaskGroupInputs = @{ ambiente = '$(ambiente)' }; approvalRequired = $false },
        @{ stage = 'Produccion'; variableGroupId = 503; artifactFilterBranch = 'release'; deployTaskGroupId = 'tg-deploy-prod'; deployTaskGroupName = 'Deployment-Azur-Aks-v3'; deployTaskGroupInputs = @{ aksClusterName = '$(aksClusterName)' }; approvalRequired = $true }
    )
    $releasePayloadS = New-AdoReleaseDefinitionPayload -Plan $fixturePlan -Environments $envsS -BuildDefinitionId 4242 -BuildDefinitionName 'Build-S-Ficticio'
    Add-Result -Name 'New-AdoReleaseDefinitionPayload: 3 environments en el orden dado, rank 1/2/3' `
        -Pass ((($releasePayloadS.environments | ForEach-Object { $_.rank }) -join ',') -eq '1,2,3') `
        -Detail (($releasePayloadS.environments | ForEach-Object { "$($_.name)=$($_.rank)" }) -join ' | ')
    Add-Result -Name 'New-AdoReleaseDefinitionPayload: variableGroups de cada stage es exactamente [variableGroupId]' `
        -Pass ($releasePayloadS.environments[0].variableGroups[0] -eq 501 -and $releasePayloadS.environments[2].variableGroups[0] -eq 503) `
        -Detail (($releasePayloadS.environments | ForEach-Object { $_.variableGroups[0] }) -join ',')
    Add-Result -Name 'New-AdoReleaseDefinitionPayload: approvalRequired=false -> preDeployApprovals.isAutomated=true (sin gate)' `
        -Pass ($releasePayloadS.environments[0].preDeployApprovals.approvals[0].isAutomated -eq $true) `
        -Detail "isAutomated=$($releasePayloadS.environments[0].preDeployApprovals.approvals[0].isAutomated)"
    Add-Result -Name 'New-AdoReleaseDefinitionPayload: approvalRequired=true (Produccion) -> preDeployApprovals.isAutomated=false (gate humano)' `
        -Pass ($releasePayloadS.environments[2].preDeployApprovals.approvals[0].isAutomated -eq $false) `
        -Detail "isAutomated=$($releasePayloadS.environments[2].preDeployApprovals.approvals[0].isAutomated)"
    Add-Result -Name 'New-AdoReleaseDefinitionPayload: artifact filter branch por stage (conditions[1].value.sourceBranch)' `
        -Pass (($releasePayloadS.environments[0].conditions[1].value | ConvertFrom-Json).sourceBranch -eq 'development' -and ($releasePayloadS.environments[2].conditions[1].value | ConvertFrom-Json).sourceBranch -eq 'release') `
        -Detail 'OK'
    Add-Result -Name 'New-AdoReleaseDefinitionPayload: artifacts[0] referencia el Build YA EXISTENTE dado (id/name), nunca inventado' `
        -Pass ($releasePayloadS.artifacts[0].definitionReference.definition.id -eq '4242' -and $releasePayloadS.artifacts[0].definitionReference.definition.name -eq 'Build-S-Ficticio') `
        -Detail "$($releasePayloadS.artifacts[0].definitionReference.definition | ConvertTo-Json -Compress)"
    Add-Result -Name 'New-AdoReleaseDefinitionPayload: CD trigger siempre presente (triggerConditions vacio = incondicional)' `
        -Pass ($releasePayloadS.triggers[0].triggerType -eq 'artifactSource' -and @($releasePayloadS.triggers[0].triggerConditions).Count -eq 0) `
        -Detail ($releasePayloadS.triggers[0] | ConvertTo-Json -Compress)

    # ============================================================
    # Grupo S-batch: convencion org-wide de agrupacion de merges ("gana
    # el mas nuevo"), automatizada en New-AdoBuildDefinitionPayload /
    # New-AdoReleaseDefinitionPayload / Test-AdoClassicPlan.ps1 /
    # New-AdoClassicAksPlan.ps1 -- ver
    # references/ado-classic-payload-templates.md § "Convencion org-wide:
    # fases de agrupacion de merges" y § "Piezas equivalentes del lado
    # Release". Checklist de 8 piezas (Build) + 2 (Release, por ambiente).
    # ============================================================

    Add-Result -Name 'New-AdoBuildDefinitionPayload (sin mergeBatching): sigue con 1 sola fase (regresion)' `
        -Pass (@($buildPayloadS.process.phases).Count -eq 1 -and $buildPayloadS.process.phases[0].name -eq 'Agent job 1') `
        -Detail "phases=$(($buildPayloadS.process.phases | ForEach-Object { $_.name }) -join ', ')"
    Add-Result -Name 'New-AdoBuildDefinitionPayload (sin mergeBatching): maxConcurrentBuildsPerBranch=1, allowScriptsAuthAccessOption=false (regresion)' `
        -Pass ($buildPayloadS.triggers[0].maxConcurrentBuildsPerBranch -eq 1 -and $buildPayloadS.process.phases[0].target.allowScriptsAuthAccessOption -eq $false) `
        -Detail "maxConcurrentBuildsPerBranch=$($buildPayloadS.triggers[0].maxConcurrentBuildsPerBranch); allowScriptsAuthAccessOption=$($buildPayloadS.process.phases[0].target.allowScriptsAuthAccessOption)"
    Add-Result -Name 'New-AdoBuildDefinitionPayload (sin mergeBatching): sin Task group Gana-el-mas-nuevo ni Reportar-resultado-HU (regresion)' `
        -Pass (-not ($buildPayloadS.process.phases[0].steps | Where-Object { $_.displayName -match 'Gana-el-mas-nuevo|Reportar-resultado-HU' })) `
        -Detail (($buildPayloadS.process.phases[0].steps | ForEach-Object { $_.displayName }) -join ' | ')

    $fixturePlanBatch = [PSCustomObject]@{
        family   = 'aks'
        project  = 'DevOps'
        names    = [PSCustomObject]@{ build = 'Build-SBatch-Ficticio'; release = 'Deploy-SBatch-Ficticio'; folder = '\SBatch-Ficticio' }
        repo     = [PSCustomObject]@{ id = 'repo-sbatch-1'; name = 'repo-sbatch-ficticio'; project = 'Proyecto-App-SBatch'; prodBranch = 'release'; ciBranchFilters = @('development', 'uat', 'release'); ciBatchChangesEnabled = $false }
        buildVariables = [PSCustomObject]@{ conexcontainerregistries = 'ACR-SBatch-Ficticia'; rutadockerfile = './Dockerfile'; tag = '$(Build.BuildId)'; 'system.debug' = 'false'; image = 'sbatch-ficticio-web-'; servicesname = 'sbatch-ficticio-web' }
        dependencies = [PSCustomObject]@{
            buildTaskGroup = [PSCustomObject]@{ name = 'Build-MultiStage'; id = 'tg-build-sbatch'; revision = 7 }
            agentPool = $null
            evaluarVentanaTaskGroup = [PSCustomObject]@{ name = 'Evaluar-ventana-agrupacion'; id = 'tg-evaluar-sbatch'; revision = 2 }
            ganaElMasNuevoTaskGroup = [PSCustomObject]@{ name = 'Gana-el-mas-nuevo'; id = 'tg-gana-sbatch'; revision = 2 }
            reportarResultadoTaskGroup = [PSCustomObject]@{ name = 'Reportar-resultado-HU'; id = 'tg-reportar-sbatch'; revision = 1 }
        }
        variableGroup = [PSCustomObject]@{ name = 'Desarrollo-SBatch-Ficticio'; keys = [PSCustomObject]@{ ambiente = 'dev'; servicesname = 'sbatch-ficticio-web'; namespace = 'desarrollo'; tag = '$(Build.BuildId)' } }
        mergeBatching = [PSCustomObject]@{ enabled = $true; windowMinutes = '5' }
    }

    $buildPayloadBatch = New-AdoBuildDefinitionPayload -Plan $fixturePlanBatch -DeploymentManifests $manifestsS
    Add-Result -Name 'New-AdoBuildDefinitionPayload (mergeBatching): 3 fases en el orden correcto' `
        -Pass ((($buildPayloadBatch.process.phases | ForEach-Object { $_.name }) -join '|') -eq 'Evaluar ventana|Ventana de agrupacion|Agent job 1') `
        -Detail (($buildPayloadBatch.process.phases | ForEach-Object { $_.name }) -join ' | ')
    Add-Result -Name 'New-AdoBuildDefinitionPayload (mergeBatching): Gana-el-mas-nuevo es el PRIMER step de Agent job 1' `
        -Pass ($buildPayloadBatch.process.phases[2].steps[0].displayName -eq 'Task group: Gana-el-mas-nuevo' -and $buildPayloadBatch.process.phases[2].steps[0].task.id -eq 'tg-gana-sbatch') `
        -Detail "steps[0]=$($buildPayloadBatch.process.phases[2].steps[0].displayName); task.id=$($buildPayloadBatch.process.phases[2].steps[0].task.id)"
    $repHuStepBatch = $buildPayloadBatch.process.phases[2].steps | Where-Object { $_.displayName -eq 'Task group: Reportar-resultado-HU' }
    Add-Result -Name 'New-AdoBuildDefinitionPayload (mergeBatching): Reportar-resultado-HU al final, condition=and(always(), not(canceled())), task.id resuelto' `
        -Pass ($repHuStepBatch.condition -eq 'and(always(), not(canceled()))' -and $repHuStepBatch.task.id -eq 'tg-reportar-sbatch' -and $buildPayloadBatch.process.phases[2].steps[-1].displayName -eq 'Task group: Reportar-resultado-HU') `
        -Detail "condition=$($repHuStepBatch.condition); task.id=$($repHuStepBatch.task.id)"
    Add-Result -Name 'New-AdoBuildDefinitionPayload (mergeBatching): Reportar-resultado-HU alwaysRun=false (confirmado 2026-08-25 via dry-run contra Build 552/622 reales, no true)' `
        -Pass ($repHuStepBatch.alwaysRun -eq $false) `
        -Detail "alwaysRun=$($repHuStepBatch.alwaysRun)"
    Add-Result -Name 'New-AdoBuildDefinitionPayload (mergeBatching): allowScriptsAuthAccessOption=true en fase 1 Y fase 3' `
        -Pass ($buildPayloadBatch.process.phases[0].target.allowScriptsAuthAccessOption -eq $true -and $buildPayloadBatch.process.phases[2].target.allowScriptsAuthAccessOption -eq $true) `
        -Detail "fase1=$($buildPayloadBatch.process.phases[0].target.allowScriptsAuthAccessOption); fase3=$($buildPayloadBatch.process.phases[2].target.allowScriptsAuthAccessOption)"
    Add-Result -Name 'New-AdoBuildDefinitionPayload (mergeBatching): fase 2 es agentless (target.type=2, sin allowScriptsAuthAccessOption)' `
        -Pass ($buildPayloadBatch.process.phases[1].target.type -eq 2 -and -not $buildPayloadBatch.process.phases[1].target.PSObject.Properties.Name.Contains('allowScriptsAuthAccessOption')) `
        -Detail ($buildPayloadBatch.process.phases[1].target | ConvertTo-Json -Compress)
    Add-Result -Name 'New-AdoBuildDefinitionPayload (mergeBatching): maxConcurrentBuildsPerBranch=5' `
        -Pass ($buildPayloadBatch.triggers[0].maxConcurrentBuildsPerBranch -eq 5) `
        -Detail "maxConcurrentBuildsPerBranch=$($buildPayloadBatch.triggers[0].maxConcurrentBuildsPerBranch)"
    Add-Result -Name 'New-AdoBuildDefinitionPayload (mergeBatching): las 4 variables de agrupacion presentes con los valores documentados' `
        -Pass ($buildPayloadBatch.variables.BATCH_WINDOW_MINUTES.value -eq '5' -and $buildPayloadBatch.variables.SUPERSEDE_REASONS.value -eq 'IndividualCI,BatchedCI' -and $buildPayloadBatch.variables.BATCH_WAIT_REASONS.value -eq 'IndividualCI,BatchedCI' -and $buildPayloadBatch.variables.BATCH_PR_TITLE_MARKER.value -eq '[AUTO]') `
        -Detail ($buildPayloadBatch.variables | ConvertTo-Json -Compress)
    Add-Result -Name 'New-AdoBuildDefinitionPayload (mergeBatching): fase 3 encadena a Batch_Window (dependencies + condition)' `
        -Pass ($buildPayloadBatch.process.phases[2].dependencies.scope -eq 'Batch_Window' -and $buildPayloadBatch.process.phases[2].condition -match 'Batch_Window\.result') `
        -Detail "dependencies=$($buildPayloadBatch.process.phases[2].dependencies | ConvertTo-Json -Compress); condition=$($buildPayloadBatch.process.phases[2].condition)"
    Add-Result -Name 'New-AdoBuildDefinitionPayload (mergeBatching): fase 2 encadena a Batch_Gate (dependencies + condition con shouldWait)' `
        -Pass ($buildPayloadBatch.process.phases[1].dependencies.scope -eq 'Batch_Gate' -and $buildPayloadBatch.process.phases[1].condition -match "gate\.shouldWait") `
        -Detail "dependencies=$($buildPayloadBatch.process.phases[1].dependencies | ConvertTo-Json -Compress); condition=$($buildPayloadBatch.process.phases[1].condition)"
    Add-Result -Name 'New-AdoBuildDefinitionPayload (mergeBatching): step puente tiene refName=gate y el script exacto' `
        -Pass ($buildPayloadBatch.process.phases[0].steps[1].refName -eq 'gate' -and $buildPayloadBatch.process.phases[0].steps[1].inputs.script -match 'shouldWait=\$v') `
        -Detail "refName=$($buildPayloadBatch.process.phases[0].steps[1].refName)"

    $fixturePlanBatchMissingDep = [PSCustomObject]@{
        family   = 'aks'
        project  = 'DevOps'
        names    = [PSCustomObject]@{ build = 'Build-SBatch2-Ficticio'; release = 'Deploy-SBatch2-Ficticio'; folder = '\SBatch2-Ficticio' }
        repo     = [PSCustomObject]@{ id = 'repo-sbatch2-1'; name = 'repo-sbatch2-ficticio'; project = 'Proyecto-App-SBatch2'; prodBranch = 'release'; ciBranchFilters = @('development', 'uat', 'release'); ciBatchChangesEnabled = $false }
        buildVariables = [PSCustomObject]@{ conexcontainerregistries = 'ACR-SBatch2-Ficticia'; rutadockerfile = './Dockerfile'; tag = '$(Build.BuildId)'; 'system.debug' = 'false'; servicesname = 'sbatch2-ficticio-web' }
        dependencies = [PSCustomObject]@{
            buildTaskGroup = [PSCustomObject]@{ name = 'Build'; id = 'tg-build-sbatch2'; revision = 7 }
            agentPool = $null
            evaluarVentanaTaskGroup = [PSCustomObject]@{ name = 'Evaluar-ventana-agrupacion'; id = 'tg-evaluar-sbatch2'; revision = 2 }
            ganaElMasNuevoTaskGroup = [PSCustomObject]@{ name = 'Gana-el-mas-nuevo'; id = $null; revision = $null }
        }
        variableGroup = [PSCustomObject]@{ name = 'Desarrollo-SBatch2-Ficticio'; keys = [PSCustomObject]@{ ambiente = 'dev'; servicesname = 'sbatch2-ficticio-web'; namespace = 'desarrollo'; tag = '$(Build.BuildId)' } }
        mergeBatching = [PSCustomObject]@{ enabled = $true }
    }
    Invoke-ExpectThrow -Name 'New-AdoBuildDefinitionPayload (mergeBatching): dependencia sin resolver -> rechazado, nunca inventa un id' `
        -ExpectedMessagePattern "ganaElMasNuevoTaskGroup\.id no esta resuelto" -Block {
        New-AdoBuildDefinitionPayload -Plan $fixturePlanBatchMissingDep -DeploymentManifests $manifestsS
    }

    # Release: environment SIN reportarResultadoTaskGroupId -> comportamiento
    # viejo intacto (regresion); CON el campo -> step + enableAccessToken=true.
    $envsSBatchNo = @(
        @{ stage = 'Desarrollo'; variableGroupId = 601; artifactFilterBranch = 'development'; deployTaskGroupId = 'tg-deploy-dev'; deployTaskGroupName = 'Deployment-MultiStage-Cluster-Desarrollo'; deployTaskGroupInputs = @{ ambiente = '$(ambiente)' }; approvalRequired = $false }
    )
    $releasePayloadBatchNo = New-AdoReleaseDefinitionPayload -Plan $fixturePlanBatch -Environments $envsSBatchNo -BuildDefinitionId 5252 -BuildDefinitionName 'Build-SBatch-Ficticio'
    Add-Result -Name 'New-AdoReleaseDefinitionPayload (sin reportarResultadoTaskGroupId): 1 solo workflowTask, enableAccessToken=false (regresion)' `
        -Pass (@($releasePayloadBatchNo.environments[0].deployPhases[0].workflowTasks).Count -eq 1 -and $releasePayloadBatchNo.environments[0].deployPhases[0].deploymentInput.enableAccessToken -eq $false) `
        -Detail "workflowTasks.Count=$(@($releasePayloadBatchNo.environments[0].deployPhases[0].workflowTasks).Count); enableAccessToken=$($releasePayloadBatchNo.environments[0].deployPhases[0].deploymentInput.enableAccessToken)"

    $envsSBatchYes = @(
        @{ stage = 'Desarrollo'; variableGroupId = 601; artifactFilterBranch = 'development'; deployTaskGroupId = 'tg-deploy-dev'; deployTaskGroupName = 'Deployment-MultiStage-Cluster-Desarrollo'; deployTaskGroupInputs = @{ ambiente = '$(ambiente)' }; approvalRequired = $false; reportarResultadoTaskGroupId = 'tg-reportar-sbatch' },
        @{ stage = 'UAT'; variableGroupId = 602; artifactFilterBranch = 'uat'; deployTaskGroupId = 'tg-deploy-dev'; deployTaskGroupName = 'Deployment-MultiStage-Cluster-Desarrollo'; deployTaskGroupInputs = @{ ambiente = '$(ambiente)' }; approvalRequired = $false; reportarResultadoTaskGroupId = 'tg-reportar-sbatch' }
    )
    $releasePayloadBatchYes = New-AdoReleaseDefinitionPayload -Plan $fixturePlanBatch -Environments $envsSBatchYes -BuildDefinitionId 5252 -BuildDefinitionName 'Build-SBatch-Ficticio'
    Add-Result -Name 'New-AdoReleaseDefinitionPayload (con reportarResultadoTaskGroupId): 2 workflowTasks, el 2do es Reportar-resultado-HU con condition=always()' `
        -Pass (@($releasePayloadBatchYes.environments[0].deployPhases[0].workflowTasks).Count -eq 2 -and $releasePayloadBatchYes.environments[0].deployPhases[0].workflowTasks[1].name -eq 'Task group: Reportar-resultado-HU' -and $releasePayloadBatchYes.environments[0].deployPhases[0].workflowTasks[1].condition -eq 'always()' -and $releasePayloadBatchYes.environments[0].deployPhases[0].workflowTasks[1].taskId -eq 'tg-reportar-sbatch') `
        -Detail ($releasePayloadBatchYes.environments[0].deployPhases[0].workflowTasks | ConvertTo-Json -Compress -Depth 5)
    Add-Result -Name 'New-AdoReleaseDefinitionPayload (con reportarResultadoTaskGroupId): enableAccessToken=true SOLO en ese ambiente, ambos ambientes lo tienen aca' `
        -Pass ($releasePayloadBatchYes.environments[0].deployPhases[0].deploymentInput.enableAccessToken -eq $true -and $releasePayloadBatchYes.environments[1].deployPhases[0].deploymentInput.enableAccessToken -eq $true) `
        -Detail "env0=$($releasePayloadBatchYes.environments[0].deployPhases[0].deploymentInput.enableAccessToken); env1=$($releasePayloadBatchYes.environments[1].deployPhases[0].deploymentInput.enableAccessToken)"
    Add-Result -Name 'New-AdoReleaseDefinitionPayload: deploy task group original conserva su condition succeededOrFailed() (no se pisa)' `
        -Pass ($releasePayloadBatchYes.environments[0].deployPhases[0].workflowTasks[0].condition -eq 'succeededOrFailed()') `
        -Detail "condition=$($releasePayloadBatchYes.environments[0].deployPhases[0].workflowTasks[0].condition)"

    # S-approved: New-AdoApprovedOperationEntry SIEMPRE calcula el hash
    # (nunca lo recibe como parametro) -- se confirma que coincide con
    # Get-AdoBodyCanonicalHash calculado por separado sobre el MISMO body.
    $approvedEntryS = New-AdoApprovedOperationEntry -OperationId 's-vg' -OperationType 'create-variable-group' -Uri $vgUri -Body $vgPayloadS
    Add-Result -Name 'New-AdoApprovedOperationEntry: bodyHash calculado automaticamente coincide con Get-AdoBodyCanonicalHash' `
        -Pass ($approvedEntryS.bodyHash -eq (Get-AdoBodyCanonicalHash -Body $vgPayloadS)) `
        -Detail "bodyHash=$($approvedEntryS.bodyHash)"
    Add-Result -Name 'New-AdoApprovedOperationEntry: method siempre POST' -Pass ($approvedEntryS.method -eq 'POST') -Detail "method=$($approvedEntryS.method)"

    # ============================================================
    # Grupo V: ConvertTo-AdoEnvClassification -- clasificacion de
    # variables .env/.env.example en buildTime/pipeline/secret/configMap
    # para el paso "Secret + ConfigMap" de la convencion de manifiestos
    # K8s. Puro parsing de texto, sin red.
    # ============================================================

    $envContentV = @'
# Build-time variables (VITE_* prefix required)
VITE_API_BASE_URL=""
VITE_ADO_ORG="Shared-Service-GM"

# Runtime variables
ADO_PAT=""                                     # Personal Access Token (sensitive)
ENVIRONMENT="production"
LOG_LEVEL="info"

# Docker build args
DOCKER_REGISTRY="your-registry.com"
DOCKER_TAG="latest"
'@
    $classV = ConvertTo-AdoEnvClassification -EnvFileContent $envContentV -IsExampleFile $true
    Add-Result -Name 'ConvertTo-AdoEnvClassification: prefijos VITE_ -> buildTimeVars, con su value de ejemplo' `
        -Pass (($classV.buildTimeVars | ForEach-Object { $_.name }) -join ',' -eq 'VITE_API_BASE_URL,VITE_ADO_ORG' -and ($classV.buildTimeVars | Where-Object { $_.name -eq 'VITE_ADO_ORG' }).value -eq 'Shared-Service-GM') `
        -Detail ($classV.buildTimeVars | ConvertTo-Json -Compress)
    Add-Result -Name 'ConvertTo-AdoEnvClassification: DOCKER_* -> pipelineVars, nunca ConfigMap/Secret' `
        -Pass (($classV.pipelineVars | ForEach-Object { $_.name }) -join ',' -eq 'DOCKER_REGISTRY,DOCKER_TAG' -and -not ($classV.configMapVars.name -contains 'DOCKER_REGISTRY')) `
        -Detail ($classV.pipelineVars | ConvertTo-Json -Compress)
    Add-Result -Name 'ConvertTo-AdoEnvClassification: ADO_PAT (nombre matchea *_PAT) -> secretVars, SIN value' `
        -Pass ($classV.secretVars.Count -eq 1 -and $classV.secretVars[0].name -eq 'ADO_PAT' -and -not $classV.secretVars[0].PSObject.Properties.Name.Contains('value')) `
        -Detail ($classV.secretVars | ConvertTo-Json -Compress)
    Add-Result -Name 'ConvertTo-AdoEnvClassification: ENVIRONMENT/LOG_LEVEL -> configMapVars con su value de ejemplo (IsExampleFile=true)' `
        -Pass ((($classV.configMapVars | ForEach-Object { $_.name }) -join ',') -eq 'ENVIRONMENT,LOG_LEVEL' -and ($classV.configMapVars | Where-Object { $_.name -eq 'ENVIRONMENT' }).value -eq 'production') `
        -Detail ($classV.configMapVars | ConvertTo-Json -Compress)
    Add-Result -Name 'ConvertTo-AdoEnvClassification: sin variables ambiguas en un .env.example limpio' `
        -Pass (@($classV.ambiguousVars).Count -eq 0) `
        -Detail ($classV.ambiguousVars | ConvertTo-Json -Compress)

    # V2: IsExampleFile=$false (archivo .env REAL, sin variante .example) --
    # ningun valor se copia jamas, todo configMapVar queda '' + ambiguo.
    $classV2 = ConvertTo-AdoEnvClassification -EnvFileContent 'PORT=3000' -IsExampleFile $false
    Add-Result -Name 'ConvertTo-AdoEnvClassification (.env REAL, IsExampleFile=false): value SIEMPRE vacio, nunca copia el real' `
        -Pass ($classV2.configMapVars.Count -eq 1 -and $classV2.configMapVars[0].value -eq '' -and $classV2.ambiguousVars.Count -eq 1) `
        -Detail "configMapVars=$($classV2.configMapVars | ConvertTo-Json -Compress); ambiguousVars=$($classV2.ambiguousVars | ConvertTo-Json -Compress)"

    # V3: nombre NO sugiere secreto pero el valor de ejemplo parece un
    # token real (heuristica de valor sospechoso) -> Secret + ambiguo.
    $classV3 = ConvertTo-AdoEnvClassification -EnvFileContent 'SOME_RANDOM_SETTING="aGVsbG93b3JsZHRoaXNsb29rc2xpa2VhdG9rZW4xMjM0"' -IsExampleFile $true
    Add-Result -Name 'ConvertTo-AdoEnvClassification: nombre no-secreto pero valor con forma de token -> Secret + flag ambiguo' `
        -Pass ($classV3.secretVars.Count -eq 1 -and $classV3.secretVars[0].name -eq 'SOME_RANDOM_SETTING' -and $classV3.ambiguousVars.Count -eq 1) `
        -Detail "secretVars=$($classV3.secretVars | ConvertTo-Json -Compress); ambiguousVars=$($classV3.ambiguousVars | ConvertTo-Json -Compress)"

    # V4: variable sin prefijo build-time conocido, pero dentro de una
    # seccion marcada "build-time" por comentario -> igual va a buildTimeVars.
    $envContentV4 = @'
# Build-time variables
CUSTOM_BUILD_FLAG="true"
'@
    $classV4 = ConvertTo-AdoEnvClassification -EnvFileContent $envContentV4 -IsExampleFile $true
    Add-Result -Name 'ConvertTo-AdoEnvClassification: seccion "build-time" por comentario clasifica aunque no tenga prefijo conocido' `
        -Pass ($classV4.buildTimeVars.Count -eq 1 -and $classV4.buildTimeVars[0].name -eq 'CUSTOM_BUILD_FLAG') `
        -Detail ($classV4.buildTimeVars | ConvertTo-Json -Compress)

    # V5: valores entre comillas con '#' adentro no se cortan; comentario
    # despues de un valor SIN comillas si se recorta.
    $classV5 = ConvertTo-AdoEnvClassification -EnvFileContent 'GREETING="hola #mundo"' -IsExampleFile $true
    Add-Result -Name 'ConvertTo-AdoEnvClassification: un # dentro de comillas no corta el valor' `
        -Pass ($classV5.configMapVars.Count -eq 1 -and $classV5.configMapVars[0].value -eq 'hola #mundo') `
        -Detail ($classV5.configMapVars | ConvertTo-Json -Compress)

    # V6: caso real encontrado 2026-08-25 con un .env real de otro repo --
    # 'DB_PASS' (abreviatura de password, sin 'password'/'passwd'/'pwd'
    # completo) debia clasificar como secreto y no lo hacia antes de este
    # fix. PASSWORD_BLUE (ya cubierto por 'password') no debe romperse.
    $classV6 = ConvertTo-AdoEnvClassification -EnvFileContent "DB_PASS='x'`nPASSWORD_BLUE='y'`nCOMPASS_DIRECTION='north'" -IsExampleFile $false
    Add-Result -Name 'ConvertTo-AdoEnvClassification: DB_PASS (abreviatura) -> secretVars (gap real encontrado y corregido 2026-08-25)' `
        -Pass (($classV6.secretVars | ForEach-Object { $_.name }) -contains 'DB_PASS') `
        -Detail ($classV6.secretVars | ConvertTo-Json -Compress)
    Add-Result -Name 'ConvertTo-AdoEnvClassification: PASSWORD_BLUE sigue detectado (no regresion)' `
        -Pass (($classV6.secretVars | ForEach-Object { $_.name }) -contains 'PASSWORD_BLUE') `
        -Detail ($classV6.secretVars | ConvertTo-Json -Compress)
    Add-Result -Name 'ConvertTo-AdoEnvClassification: COMPASS_DIRECTION (contiene "pass" sin limite de palabra) NO dispara falso positivo' `
        -Pass (-not (($classV6.secretVars | ForEach-Object { $_.name }) -contains 'COMPASS_DIRECTION')) `
        -Detail ($classV6.secretVars | ConvertTo-Json -Compress)

    # V7: -PopulateRealValues (autorizado explicitamente 2026-08-25 --
    # patron ya vigente en todos los pipelines de esta org, acceso al
    # proyecto DevOps restringido a ~3 personas de jefatura). Con el
    # switch, tanto configMapVars como secretVars llevan su value real;
    # sin el switch, sigue igual que antes (regresion).
    $envContentV7 = @'
DB_HOST='gmon-prod-mysql-eastus2-0001.mysql.database.azure.com'
DB_USER='usr_prov_jhernandez'
DB_PASS='valor-ficticio-de-prueba'
'@
    $classV7Default = ConvertTo-AdoEnvClassification -EnvFileContent $envContentV7 -IsExampleFile $false
    Add-Result -Name 'ConvertTo-AdoEnvClassification: SIN -PopulateRealValues sigue sin copiar nada (regresion)' `
        -Pass (($classV7Default.configMapVars | Where-Object { $_.name -eq 'DB_HOST' }).value -eq '' -and -not ($classV7Default.secretVars[0].PSObject.Properties.Name.Contains('value'))) `
        -Detail "configMapVars=$($classV7Default.configMapVars | ConvertTo-Json -Compress); secretVars=$($classV7Default.secretVars | ConvertTo-Json -Compress)"

    $classV7Real = ConvertTo-AdoEnvClassification -EnvFileContent $envContentV7 -PopulateRealValues
    $dbHostV7 = $classV7Real.configMapVars | Where-Object { $_.name -eq 'DB_HOST' }
    $dbUserV7 = $classV7Real.configMapVars | Where-Object { $_.name -eq 'DB_USER' }
    $dbPassV7 = $classV7Real.secretVars | Where-Object { $_.name -eq 'DB_PASS' }
    Add-Result -Name 'ConvertTo-AdoEnvClassification -PopulateRealValues: ConfigMap (DB_HOST/DB_USER) lleva el value real' `
        -Pass ($dbHostV7.value -eq 'gmon-prod-mysql-eastus2-0001.mysql.database.azure.com' -and $dbUserV7.value -eq 'usr_prov_jhernandez') `
        -Detail "DB_HOST=$($dbHostV7.value); DB_USER=$($dbUserV7.value)"
    Add-Result -Name 'ConvertTo-AdoEnvClassification -PopulateRealValues: Secret (DB_PASS) TAMBIEN lleva el value real' `
        -Pass ($dbPassV7.value -eq 'valor-ficticio-de-prueba') `
        -Detail "DB_PASS.value presente=$($dbPassV7.PSObject.Properties.Name.Contains('value')); DB_PASS=$($dbPassV7.value)"
    Add-Result -Name 'ConvertTo-AdoEnvClassification -PopulateRealValues: no genera ambiguousVars por "fuente no-example" (ya autorizado)' `
        -Pass (@($classV7Real.ambiguousVars | Where-Object { $_.reason -match 'nunca se copia un valor real' }).Count -eq 0) `
        -Detail ($classV7Real.ambiguousVars | ConvertTo-Json -Compress)

    # V8: entrypoint ejecutable. Debe escribir el JSON esperado sin imprimir
    # valores y conservar el comportamiento redactado por defecto.
    $envWrapperPath = Join-Path $scriptsRoot 'Convert-AdoEnvFileClassification.ps1'
    $envWrapperInput = Join-Path $testTempRoot 'wrapper.env'
    $envWrapperRedactedOutput = Join-Path $testTempRoot 'wrapper-redacted.json'
    $envWrapperRealOutput = Join-Path $testTempRoot 'wrapper-real.json'
    $envWrapperFakeValue = 'valor-ficticio-wrapper'
    Set-Content -LiteralPath $envWrapperInput -Value "DB_HOST=127.0.0.1`nDB_PASS=$envWrapperFakeValue" -Encoding UTF8

    $wrapperRedactedStdout = & powershell.exe -NoProfile -NonInteractive -File $envWrapperPath `
        -EnvPath $envWrapperInput -OutPath $envWrapperRedactedOutput 2>&1
    $wrapperRedactedExit = $LASTEXITCODE
    $wrapperRedactedJson = Get-Content -LiteralPath $envWrapperRedactedOutput -Raw | ConvertFrom-Json
    Add-Result -Name 'Convert-AdoEnvFileClassification: wrapper redactado ejecuta y nunca imprime/copia el valor real' `
        -Pass ($wrapperRedactedExit -eq 0 -and
            ($wrapperRedactedJson.configMapVars | Where-Object name -eq 'DB_HOST').value -eq '' -and
            -not ($wrapperRedactedJson.secretVars[0].PSObject.Properties.Name.Contains('value')) -and
            (($wrapperRedactedStdout | Out-String) -notmatch [regex]::Escape($envWrapperFakeValue))) `
        -Detail "exit=$wrapperRedactedExit stdout=$($wrapperRedactedStdout | Out-String)"

    $wrapperRealStdout = & powershell.exe -NoProfile -NonInteractive -File $envWrapperPath `
        -EnvPath $envWrapperInput -OutPath $envWrapperRealOutput -PopulateRealValues 2>&1
    $wrapperRealExit = $LASTEXITCODE
    $wrapperRealJson = Get-Content -LiteralPath $envWrapperRealOutput -Raw | ConvertFrom-Json
    Add-Result -Name 'Convert-AdoEnvFileClassification: -PopulateRealValues escribe el JSON completo pero mantiene stdout redactado' `
        -Pass ($wrapperRealExit -eq 0 -and
            ($wrapperRealJson.secretVars | Where-Object name -eq 'DB_PASS').value -eq $envWrapperFakeValue -and
            (($wrapperRealStdout | Out-String) -notmatch [regex]::Escape($envWrapperFakeValue))) `
        -Detail "exit=$wrapperRealExit stdout=$($wrapperRealStdout | Out-String)"

    # ============================================================
    # Grupo W: New-AdoReleaseEnvironmentEntry -- ensamblado de UNA entrada
    # del array -Environments de New-AdoReleaseDefinitionPayload, sin
    # tener que recordar a mano el contrato de deployTaskGroupInputs de
    # cada task group de deploy conocido.
    # ============================================================

    Invoke-ExpectThrow -Name 'New-AdoReleaseEnvironmentEntry: contrato desconocido sin -DeployTaskGroupInputsOverride -> rechazado' `
        -ExpectedMessagePattern "contrato de deployTaskGroupInputs desconocido" -Block {
        New-AdoReleaseEnvironmentEntry -Stage 'X' -VariableGroupId 1 -ArtifactFilterBranch 'x' -DeployTaskGroupName 'Deploy-Desconocido' -DeployTaskGroupId 'tg-x'
    }
    Invoke-ExpectThrow -Name 'New-AdoReleaseEnvironmentEntry: Deployment-Azur-Aks-v3 sin AksClusterName -> rechazado (nunca adivina)' `
        -ExpectedMessagePattern "falta -AksClusterName" -Block {
        New-AdoReleaseEnvironmentEntry -Stage 'Produccion' -VariableGroupId 411 -ArtifactFilterBranch 'release' -DeployTaskGroupName 'Deployment-Azur-Aks-v3' -DeployTaskGroupId 'tg-deploy-prod' -AksResourceGroup 'rg' -Ambiente 'prod' -Namespace 'apps-web' -Pipeline 'Build-W'
    }

    $entryDesarrolloW = New-AdoReleaseEnvironmentEntry -Stage 'Desarrollo' -VariableGroupId 409 -ArtifactFilterBranch 'development' -DeployTaskGroupName 'Deployment-MultiStage-Cluster-Desarrollo' -DeployTaskGroupId 'tg-deploy-dev-w' -Ambiente 'dev' -ContainerRegistries 'gmonhubacreastus20001.azurecr.io' -Image 'w-app-web-' -Namespace 'desarrollo' -Pipeline 'Build-W' -ServicesName 'w-app-web' -ReportarResultadoTaskGroupId 'tg-reportar-w'
    Add-Result -Name 'New-AdoReleaseEnvironmentEntry (Deployment-MultiStage-Cluster-Desarrollo): arma el contrato real completo' `
        -Pass ($entryDesarrolloW.deployTaskGroupInputs.ambiente -eq 'dev' -and $entryDesarrolloW.deployTaskGroupInputs.servicesname -eq 'w-app-web' -and $entryDesarrolloW.deployTaskGroupInputs.image -eq 'w-app-web-' -and $entryDesarrolloW.deployTaskGroupInputs.containerRegistryPassword -eq '' -and $entryDesarrolloW.reportarResultadoTaskGroupId -eq 'tg-reportar-w') `
        -Detail ($entryDesarrolloW | ConvertTo-Json -Compress -Depth 5)

    $entryProdW = New-AdoReleaseEnvironmentEntry -Stage 'Produccion' -VariableGroupId 411 -ArtifactFilterBranch 'release' -DeployTaskGroupName 'Deployment-Azur-Aks-v3' -DeployTaskGroupId 'tg-deploy-prod-w' -AksClusterName 'gmon-prod-aks-eastus2-0004' -AksResourceGroup 'gmon_prod_rg_eastus2_0001' -Ambiente 'prod' -Namespace 'apps-web' -Pipeline 'Build-W' -ApprovalRequired $true
    Add-Result -Name 'New-AdoReleaseEnvironmentEntry (Deployment-Azur-Aks-v3): arma el contrato real completo, sin campos del otro contrato' `
        -Pass ($entryProdW.deployTaskGroupInputs.aksClusterName -eq 'gmon-prod-aks-eastus2-0004' -and -not $entryProdW.deployTaskGroupInputs.Contains('servicesname') -and $entryProdW.approvalRequired -eq $true) `
        -Detail ($entryProdW | ConvertTo-Json -Compress -Depth 5)

    # W-ensamblado real: reconstruir los 3 ambientes de Administracion-de-proyectos
    # con esta funcion y comparar contra el contrato REAL confirmado hoy
    # (Release 381 real, ver GET de hoy mismo) -- prueba que el "pegamento"
    # nuevo reproduce exactamente lo que se armaba a mano.
    $envAdmProyW = @(
        (New-AdoReleaseEnvironmentEntry -Stage 'Desarrollo' -VariableGroupId 409 -ArtifactFilterBranch 'development' -DeployTaskGroupName 'Deployment-MultiStage-Cluster-Desarrollo' -DeployTaskGroupId 'fc4043e2-e239-4710-9d5a-2a92055ff1ea' -Ambiente '$(ambiente)' -ContainerRegistries '$(containerregistries)' -Image '$(image)' -Namespace '$(namespace)' -Pipeline '$(pipeline)' -ServicesName '$(servicesname)' -Tag '$(tag)' -ReportarResultadoTaskGroupId 'cefd6b95-eb0f-4a3f-b63e-a2d669a53e55'),
        (New-AdoReleaseEnvironmentEntry -Stage 'Produccion' -VariableGroupId 411 -ArtifactFilterBranch 'release' -DeployTaskGroupName 'Deployment-Azur-Aks-v3' -DeployTaskGroupId '1fdf52f7-9160-4049-bb78-c7bffadf022d' -AksClusterName '$(aksClusterName)' -AksResourceGroup '$(aksResourceGroup)' -Ambiente '$(ambiente)' -Namespace '$(namespace)' -Pipeline '$(pipeline)' -ApprovalRequired $true -ReportarResultadoTaskGroupId 'cefd6b95-eb0f-4a3f-b63e-a2d669a53e55')
    )
    $releasePayloadW = New-AdoReleaseDefinitionPayload -Plan $fixturePlan -Environments $envAdmProyW -BuildDefinitionId 622 -BuildDefinitionName 'Build-administracion-proyectos-web'
    Add-Result -Name 'New-AdoReleaseEnvironmentEntry + New-AdoReleaseDefinitionPayload: Desarrollo con Reportar-resultado-HU + enableAccessToken=true' `
        -Pass ($releasePayloadW.environments[0].deployPhases[0].deploymentInput.enableAccessToken -eq $true -and $releasePayloadW.environments[0].deployPhases[0].workflowTasks[1].name -eq 'Task group: Reportar-resultado-HU') `
        -Detail ($releasePayloadW.environments[0].deployPhases[0].deploymentInput | ConvertTo-Json -Compress)
    Add-Result -Name 'New-AdoReleaseEnvironmentEntry + New-AdoReleaseDefinitionPayload: Produccion con isAutomated=false (approvalRequired=true)' `
        -Pass ($releasePayloadW.environments[1].preDeployApprovals.approvals[0].isAutomated -eq $false) `
        -Detail "isAutomated=$($releasePayloadW.environments[1].preDeployApprovals.approvals[0].isAutomated)"

    # ============================================================
    # Grupo T: Test-AdoClassicResourceNameAlreadyExists -- chequeo de
    # duplicado en vivo, con paginacion (nunca red real).
    # ============================================================

    Reset-MockWebRequest
    Add-MockWebListResponse -Items @(@{ id = 1; name = 'Otro-Nombre' })
    Add-Result -Name 'Test-AdoClassicResourceNameAlreadyExists: nombre NO presente -> false' `
        -Pass ((Test-AdoClassicResourceNameAlreadyExists -Kind 'VariableGroup' -Name 'No-Existe-Ficticio') -eq $false) -Detail 'OK'

    Reset-MockWebRequest
    Add-MockWebListResponse -Items @(@{ id = 1; name = 'Nombre-Exacto-Ficticio' })
    Add-Result -Name 'Test-AdoClassicResourceNameAlreadyExists: nombre SI presente (coincidencia exacta) -> true' `
        -Pass ((Test-AdoClassicResourceNameAlreadyExists -Kind 'Build' -Name 'Nombre-Exacto-Ficticio') -eq $true) -Detail 'OK'

    # Paginado: el nombre buscado solo aparece en la pagina 2.
    function Add-MockWebListResponseWithToken {
        param([array]$Items, [string]$NextToken)
        $content = ([PSCustomObject]@{ value = $Items }) | ConvertTo-Json -Compress -Depth 10
        $script:mockWebResponseQueue.Enqueue([PSCustomObject]@{ Throw = $false; StatusCode = 200; Content = $content; NextToken = $NextToken })
    }
    # El mock de Invoke-WebRequest de este grupo no propaga headers de
    # continuacion (Group M no lo necesitaba) -- para probar paginacion
    # aca se usa temporalmente el mock de paginas de Grupo H, que si lo
    # hace, restaurando el de Grupo M despues.
    $originalInvokeWebRequestFn = (Get-Item function:Invoke-WebRequest).ScriptBlock
    function Invoke-AdoRest {
        param([string]$Method, [string]$Uri, $Body, [switch]$RequireApprovedPlan, [string]$PlanPath, [string]$OperationId)
        if ($script:mockCallIndex -ge $script:mockPages.Count) {
            throw "Mock: se pidieron mas paginas de las simuladas."
        }
        $page = $script:mockPages[$script:mockCallIndex]
        $script:mockCallIndex++
        $headers = @{}
        if ($page.NextToken) { $headers['x-ms-continuationtoken'] = $page.NextToken }
        return [PSCustomObject]@{ Body = [PSCustomObject]@{ value = $page.Items }; Headers = $headers; StatusCode = 200 }
    }
    Set-MockAdoPages -Pages @(
        @{ Items = @(@{ id = 1; name = 'Otra-Cosa' }); NextToken = 'tok-t1' },
        @{ Items = @(@{ id = 2; name = 'Solo-En-Pagina-2-Ficticio' }); NextToken = $null }
    )
    Add-Result -Name 'Test-AdoClassicResourceNameAlreadyExists: nombre que SOLO aparece en la pagina 2 -> true (no se corta en la 1ra)' `
        -Pass ((Test-AdoClassicResourceNameAlreadyExists -Kind 'Release' -Name 'Solo-En-Pagina-2-Ficticio') -eq $true) -Detail 'OK'
    # Restaurar Invoke-AdoRest real y el mock de Invoke-WebRequest de Grupo M para lo que sigue.
    . (Join-Path $scriptsRoot 'Invoke-AdoRest.ps1')
    Set-Item -Path function:Invoke-WebRequest -Value $originalInvokeWebRequestFn

    # ============================================================
    # Grupo U: extremo a extremo con Invoke-AdoApplyPhases -- creacion
    # simulada COMPLETA Variable Group -> Build -> Release, en 2 rondas
    # (la Release necesita el id REAL del Build/VG, que solo se conoce
    # despues de crearlos -- ver ado-classic-payload-templates.md
    # "Alcance de esta primera implementacion"). Cero llamadas de red
    # reales, cero Build encolado, cero instancia de Release creada,
    # cero despliegue -- no existe ningun codigo en Invoke-AdoApplyPhases
    # que llame a esos endpoints.
    # ============================================================

    $planURoundOnePath = New-FakePlanForApplyPhases -VgName 'U-E2E-Test' -ApprovedOperationTypes @('create-variable-group')
    # Agregar tambien create-build-definition a la ronda 1 (helper de
    # arriba solo arma VG; se completa el manifiesto a mano aca).
    $planURoundOneObj = Get-Content -LiteralPath $planURoundOnePath -Raw | ConvertFrom-Json
    $uManifests = @{ dev = 'contenido-dev-u'; uat = 'contenido-uat-u'; prod = 'contenido-prod-u' }
    $planURoundOneObj | Add-Member -NotePropertyName 'repo' -NotePropertyValue ([PSCustomObject]@{ id = 'repo-u'; name = 'repo-u-ficticio'; project = 'DevOps'; prodBranch = 'release'; ciBranchFilters = @('development', 'uat', 'release'); ciBatchChangesEnabled = $false }) -Force
    $planURoundOneObj | Add-Member -NotePropertyName 'buildVariables' -NotePropertyValue ([PSCustomObject]@{ conexcontainerregistries = 'ACR-U'; rutadockerfile = './Dockerfile'; tag = '$(Build.BuildId)'; 'system.debug' = 'false'; image = 'u-e2e-test-'; servicesname = 'u-e2e-test' }) -Force
    $planURoundOneObj | Add-Member -NotePropertyName 'dependencies' -NotePropertyValue ([PSCustomObject]@{ buildTaskGroup = [PSCustomObject]@{ name = 'Build-MultiStage'; id = 'tg-build-u'; revision = 1 } }) -Force
    $devYamlPathU = Join-Path $testTempRoot 'u-deployment-dev.yml'
    $uatYamlPathU = Join-Path $testTempRoot 'u-deployment-uat.yml'
    $prodYamlPathU = Join-Path $testTempRoot 'u-deployment-prod.yml'
    Set-Content -LiteralPath $devYamlPathU -Value $uManifests['dev'] -Encoding utf8 -NoNewline
    Set-Content -LiteralPath $uatYamlPathU -Value $uManifests['uat'] -Encoding utf8 -NoNewline
    Set-Content -LiteralPath $prodYamlPathU -Value $uManifests['prod'] -Encoding utf8 -NoNewline

    $uBuildBody = New-AdoBuildDefinitionPayload -Plan $planURoundOneObj -DeploymentManifests $uManifests
    $uBuildOp = New-AdoApprovedOperationEntry -OperationId 'u-build' -OperationType 'create-build-definition' -Uri $buildDefUri -Body $uBuildBody
    $planURoundOneObj.approvedOperations = @($planURoundOneObj.approvedOperations) + @($uBuildOp)
    $planURoundOneObj.validationHash = Get-AdoPlanCanonicalHash -Plan $planURoundOneObj
    $planURoundOneObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $planURoundOnePath -Encoding utf8
    $planURoundOne = Get-Content -LiteralPath $planURoundOnePath -Raw | ConvertFrom-Json

    Reset-MockWebRequest
    Add-MockWebListResponse -Items @()                        # GET duplicado VG -> no existe
    Add-MockWebSuccessResponse -ResultId 'u-vg-real-id-777'    # POST VG
    Add-MockWebListResponse -Items @()                        # GET duplicado Build -> no existe
    Add-MockWebSuccessResponse -ResultId 'u-build-real-id-888' # POST Build
    $createdListURound1 = [System.Collections.Generic.List[string]]::new()
    Invoke-ExpectNoThrow -Name 'E2E Invoke-AdoApplyPhases: Ronda 1 (VG + Build) se ejecuta con exito' -Block {
        Invoke-AdoApplyPhases -Plan $planURoundOne -PlanPath $planURoundOnePath -CreatedSoFar $createdListURound1 `
            -DeploymentDevYamlPath $devYamlPathU -DeploymentUatYamlPath $uatYamlPathU -DeploymentProdYamlPath $prodYamlPathU
    }
    Add-Result -Name 'E2E: Ronda 1 crea exactamente 2 recursos (VG + Build)' -Pass ($createdListURound1.Count -eq 2) -Detail ($createdListURound1 -join ' | ')
    Add-Result -Name 'E2E: Ronda 1 -> exactamente 4 llamadas HTTP (2 GET duplicado + 2 POST)' -Pass ($script:mockWebCallCount -eq 4) -Detail "mockWebCallCount=$($script:mockWebCallCount)"

    $journalURound1 = Get-Content -LiteralPath (Get-AdoExecutionJournalPath -PlanValidationHash $planURoundOne.validationHash) -Raw | ConvertFrom-Json
    Add-Result -Name 'E2E: Ronda 1 -> journal tiene VG y Build succeeded con resultId real capturado' `
        -Pass ($journalURound1.operations.'q-vg'.state -eq 'succeeded' -and $journalURound1.operations.'q-vg'.resultId -eq 'u-vg-real-id-777' -and $journalURound1.operations.'u-build'.state -eq 'succeeded' -and $journalURound1.operations.'u-build'.resultId -eq 'u-build-real-id-888') `
        -Detail ($journalURound1.operations | ConvertTo-Json -Compress)

    # Ronda 2: plan NUEVO (solo Release), referenciando los ids REALES
    # capturados en la Ronda 1 -- exactamente como se resolverian contra
    # un inventario fresco despues de que VG/Build ya existen de verdad.
    $envsU = @(
        @{ stage = 'Desarrollo'; variableGroupId = 90101; artifactFilterBranch = 'development'; deployTaskGroupId = 'tg-deploy-u'; deployTaskGroupName = 'Deployment-MultiStage-Cluster-Desarrollo'; deployTaskGroupInputs = @{ ambiente = '$(ambiente)' }; approvalRequired = $false }
    )
    $uReleaseEnvironmentsPath = Join-Path $testTempRoot 'u-release-environments.json'
    $envsU | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $uReleaseEnvironmentsPath -Encoding utf8

    $uReleasePlanObj = [PSCustomObject]@{
        family        = 'aks'
        organization  = 'Shared-Service-GM'
        project       = 'DevOps'
        names         = [PSCustomObject]@{ build = 'Build-U-E2E-Test'; release = 'Deploy-U-E2E-Test'; folder = '\U-E2E' }
        approvedOperations = @()
        validated     = $false
        validationHash = $null
    }
    $uReleaseEnvsForBody = @($envsU | ForEach-Object { @{ stage = $_.stage; variableGroupId = $_.variableGroupId; artifactFilterBranch = $_.artifactFilterBranch; deployTaskGroupId = $_.deployTaskGroupId; deployTaskGroupName = $_.deployTaskGroupName; deployTaskGroupInputs = $_.deployTaskGroupInputs; approvalRequired = $_.approvalRequired } })
    $uReleaseBody = New-AdoReleaseDefinitionPayload -Plan $uReleasePlanObj -Environments $uReleaseEnvsForBody -BuildDefinitionId 606 -BuildDefinitionName 'Build-U-E2E-Test'
    $uReleaseOp = New-AdoApprovedOperationEntry -OperationId 'u-release' -OperationType 'create-release-definition' -Uri $releaseDefUri -Body $uReleaseBody
    $uReleasePlanObj.approvedOperations = @($uReleaseOp)
    $uReleasePlanObj.validated = $true
    $uReleasePlanObj.validationHash = Get-AdoPlanCanonicalHash -Plan $uReleasePlanObj
    $uReleasePlanPath = Join-Path $testTempRoot 'u-release-plan.json'
    $uReleasePlanObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $uReleasePlanPath -Encoding utf8
    $uReleasePlan = Get-Content -LiteralPath $uReleasePlanPath -Raw | ConvertFrom-Json

    Reset-MockWebRequest
    Add-MockWebListResponse -Items @()                          # GET duplicado Release -> no existe
    Add-MockWebSuccessResponse -ResultId 'u-release-real-id-999' # POST Release
    $createdListURound2 = [System.Collections.Generic.List[string]]::new()
    Invoke-ExpectNoThrow -Name 'E2E Invoke-AdoApplyPhases: Ronda 2 (Release, referenciando ids reales de Ronda 1) se ejecuta con exito' -Block {
        Invoke-AdoApplyPhases -Plan $uReleasePlan -PlanPath $uReleasePlanPath -CreatedSoFar $createdListURound2 `
            -ReleaseEnvironmentsPath $uReleaseEnvironmentsPath -ExistingBuildDefinitionId 606 -BuildDefinitionName 'Build-U-E2E-Test'
    }
    Add-Result -Name 'E2E: Ronda 2 crea exactamente 1 recurso (Release)' -Pass ($createdListURound2.Count -eq 1) -Detail ($createdListURound2 -join ' | ')
    Add-Result -Name 'E2E: en total (Ronda 1 + Ronda 2) se crearon exactamente 3 recursos: Variable Group, Build, Release' `
        -Pass (($createdListURound1.Count + $createdListURound2.Count) -eq 3) `
        -Detail (($createdListURound1 + $createdListURound2) -join ' | ')
    Add-Result -Name 'E2E: ningun paso de Invoke-AdoApplyPhases encola un Build, crea una instancia de Release, ni despliega (verificacion estatica de codigo fuente)' `
        -Pass ((Get-Content -LiteralPath (Join-Path $scriptsRoot 'New-AdoClassicPayloads.ps1') -Raw) -notmatch '(?i)/build/builds\?|/release/releases\?') `
        -Detail 'Ningun endpoint de encolar Build o crear instancia de Release aparece en el codigo fuente.'

    # Regresion 2026-08-26 (bug real encontrado aplicando Administracion-de-
    # proyectos): -ReleaseEnvironmentsPath perdia silenciosamente
    # reportarResultadoTaskGroupId/stageVariables al reconstruir $environments
    # desde el JSON -- el body real armado en Apply quedaba sin Reportar-
    # resultado-HU/enableAccessToken aunque el body APROBADO (hasheado antes)
    # si los tuviera, lo que rompia el bodyHash de una operacion legitima.
    $envsV = @(
        @{ stage = 'Desarrollo'; variableGroupId = 90201; artifactFilterBranch = 'development'; deployTaskGroupId = 'tg-deploy-v'; deployTaskGroupName = 'Deployment-MultiStage-Cluster-Desarrollo'; deployTaskGroupInputs = @{ ambiente = '$(ambiente)' }; approvalRequired = $false; reportarResultadoTaskGroupId = 'tg-reportar-v' }
    )
    $vReleaseEnvironmentsPath = Join-Path $testTempRoot 'v-release-environments.json'
    $envsV | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $vReleaseEnvironmentsPath -Encoding utf8

    $vReleasePlanObj = [PSCustomObject]@{
        family        = 'aks'
        organization  = 'Shared-Service-GM'
        project       = 'DevOps'
        names         = [PSCustomObject]@{ build = 'Build-V-E2E-Test'; release = 'Deploy-V-E2E-Test'; folder = '\V-E2E' }
        approvedOperations = @()
        validated     = $false
        validationHash = $null
    }
    # El bodyHash aprobado SI incluye reportarResultadoTaskGroupId -- exactamente
    # lo que -ReleaseEnvironmentsPath debe reproducir tal cual al aplicar.
    $vReleaseEnvsForBody = @($envsV | ForEach-Object { @{ stage = $_.stage; variableGroupId = $_.variableGroupId; artifactFilterBranch = $_.artifactFilterBranch; deployTaskGroupId = $_.deployTaskGroupId; deployTaskGroupName = $_.deployTaskGroupName; deployTaskGroupInputs = $_.deployTaskGroupInputs; approvalRequired = $_.approvalRequired; reportarResultadoTaskGroupId = $_.reportarResultadoTaskGroupId } })
    $vReleaseBody = New-AdoReleaseDefinitionPayload -Plan $vReleasePlanObj -Environments $vReleaseEnvsForBody -BuildDefinitionId 607 -BuildDefinitionName 'Build-V-E2E-Test'
    $vReleaseOp = New-AdoApprovedOperationEntry -OperationId 'v-release' -OperationType 'create-release-definition' -Uri $releaseDefUri -Body $vReleaseBody
    $vReleasePlanObj.approvedOperations = @($vReleaseOp)
    $vReleasePlanObj.validated = $true
    $vReleasePlanObj.validationHash = Get-AdoPlanCanonicalHash -Plan $vReleasePlanObj
    $vReleasePlanPath = Join-Path $testTempRoot 'v-release-plan.json'
    $vReleasePlanObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $vReleasePlanPath -Encoding utf8
    $vReleasePlan = Get-Content -LiteralPath $vReleasePlanPath -Raw | ConvertFrom-Json

    Reset-MockWebRequest
    Add-MockWebListResponse -Items @()                          # GET duplicado Release -> no existe
    Add-MockWebSuccessResponse -ResultId 'v-release-real-id-111' # POST Release
    $createdListVRound2 = [System.Collections.Generic.List[string]]::new()
    Invoke-ExpectNoThrow -Name 'E2E Invoke-AdoApplyPhases (regresion reportarResultadoTaskGroupId): -ReleaseEnvironmentsPath con ese campo aplica sin error de bodyHash' -Block {
        Invoke-AdoApplyPhases -Plan $vReleasePlan -PlanPath $vReleasePlanPath -CreatedSoFar $createdListVRound2 `
            -ReleaseEnvironmentsPath $vReleaseEnvironmentsPath -ExistingBuildDefinitionId 607 -BuildDefinitionName 'Build-V-E2E-Test'
    }
    Add-Result -Name 'E2E (regresion reportarResultadoTaskGroupId): crea exactamente 1 recurso (Release)' -Pass ($createdListVRound2.Count -eq 1) -Detail ($createdListVRound2 -join ' | ')

    # ============================================================
    # Grupo U-UPDATE: Fases 4/5 de Invoke-AdoApplyPhases (update-build-
    # definition / update-release-definition, PUT, agregadas 2026-08-25).
    # A diferencia de las fases create-*, el body viene de un archivo ya
    # armado (-UpdateBuildBodyPath/-UpdateReleaseBodyPath), nunca
    # reconstruido desde $Plan.
    # ============================================================

    $updateBuildBodyPathTest = Join-Path $testTempRoot 'update-build-body.json'
    $updateBuildBodyTest = @{ id = 900001; revision = 3; name = 'Build-Update-Ficticio' }
    $updateBuildBodyTest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $updateBuildBodyPathTest -Encoding utf8

    $updateBuildUriTest = $buildDefUri -replace '/definitions\?', '/definitions/900001?'
    $updateBuildOpTest = New-AdoApprovedOperationEntry -OperationId 'ub-1' -OperationType 'update-build-definition' -Uri $updateBuildUriTest -Body $updateBuildBodyTest
    $updateBuildPlanObj = [PSCustomObject]@{
        family        = 'aks'
        organization  = 'Shared-Service-GM'
        project       = 'DevOps'
        names         = [PSCustomObject]@{ build = 'Build-Update-Ficticio'; release = 'Deploy-Update-Ficticio'; folder = 'FolderFicticio' }
        approvedOperations = @($updateBuildOpTest)
        validated     = $true
        validationHash = $null
    }
    $updateBuildPlanObj.validationHash = Get-AdoPlanCanonicalHash -Plan $updateBuildPlanObj
    $updateBuildPlanPath = Join-Path $testTempRoot 'update-build-plan.json'
    $updateBuildPlanObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $updateBuildPlanPath -Encoding utf8
    $updateBuildPlan = Get-Content -LiteralPath $updateBuildPlanPath -Raw | ConvertFrom-Json

    Reset-MockWebRequest
    Add-MockWebSuccessResponse -ResultId 900001
    $createdListUpdateBuild = [System.Collections.Generic.List[string]]::new()
    Invoke-ExpectNoThrow -Name 'Fase 4 (update-build-definition): PUT exitoso con -UpdateBuildBodyPath' -Block {
        Invoke-AdoApplyPhases -Plan $updateBuildPlan -PlanPath $updateBuildPlanPath -CreatedSoFar $createdListUpdateBuild -UpdateBuildBodyPath $updateBuildBodyPathTest
    }
    Add-Result -Name 'Fase 4: CreatedSoFar registra la actualizacion' -Pass ($createdListUpdateBuild.Count -eq 1) -Detail ($createdListUpdateBuild -join ' | ')
    Add-Result -Name 'Fase 4: exactamente 1 llamada HTTP (PUT, sin chequeo de duplicado -- no aplica a un update)' -Pass ($script:mockWebCallCount -eq 1) -Detail "mockWebCallCount=$($script:mockWebCallCount)"

    $journalUpdateBuild = Get-Content -LiteralPath (Get-AdoExecutionJournalPath -PlanValidationHash $updateBuildPlan.validationHash) -Raw | ConvertFrom-Json
    Add-Result -Name 'Fase 4: journal marca la operacion succeeded con resultId real' `
        -Pass ($journalUpdateBuild.operations.'ub-1'.state -eq 'succeeded' -and $journalUpdateBuild.operations.'ub-1'.resultId -eq '900001') `
        -Detail ($journalUpdateBuild.operations | ConvertTo-Json -Compress)

    # Segunda corrida sobre el MISMO plan (ya succeeded) -- debe omitirse,
    # cero llamadas HTTP nuevas.
    Reset-MockWebRequest
    $createdListUpdateBuild2 = [System.Collections.Generic.List[string]]::new()
    Invoke-ExpectNoThrow -Name 'Fase 4: segunda corrida sobre plan ya succeeded -> se omite, no reintenta' -Block {
        Invoke-AdoApplyPhases -Plan $updateBuildPlan -PlanPath $updateBuildPlanPath -CreatedSoFar $createdListUpdateBuild2 -UpdateBuildBodyPath $updateBuildBodyPathTest
    }
    Add-Result -Name 'Fase 4: segunda corrida -> cero llamadas HTTP' -Pass ($script:mockWebCallCount -eq 0) -Detail "mockWebCallCount=$($script:mockWebCallCount)"
    Add-Result -Name 'Fase 4: segunda corrida -> CreatedSoFar vacio' -Pass ($createdListUpdateBuild2.Count -eq 0) -Detail ($createdListUpdateBuild2 -join ' | ')

    # Falta -UpdateBuildBodyPath -> rechazado con mensaje explicito, cero
    # llamadas HTTP.
    $updateBuildOpTest2 = New-AdoApprovedOperationEntry -OperationId 'ub-2' -OperationType 'update-build-definition' -Uri ($buildDefUri -replace '/definitions\?', '/definitions/900002?') -Body @{ id = 900002 }
    $updateBuildPlanObj2 = [PSCustomObject]@{
        family = 'aks'; organization = 'Shared-Service-GM'; project = 'DevOps'
        names  = [PSCustomObject]@{ build = 'Build-Update-Ficticio-2'; release = 'Deploy-Update-Ficticio-2'; folder = 'FolderFicticio2' }
        approvedOperations = @($updateBuildOpTest2); validated = $true; validationHash = $null
    }
    $updateBuildPlanObj2.validationHash = Get-AdoPlanCanonicalHash -Plan $updateBuildPlanObj2
    $updateBuildPlanPath2 = Join-Path $testTempRoot 'update-build-plan-2.json'
    $updateBuildPlanObj2 | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $updateBuildPlanPath2 -Encoding utf8
    $updateBuildPlan2 = Get-Content -LiteralPath $updateBuildPlanPath2 -Raw | ConvertFrom-Json
    Reset-MockWebRequest
    Invoke-ExpectThrow -Name 'Fase 4: sin -UpdateBuildBodyPath -> rechazado antes de cualquier llamada HTTP' `
        -ExpectedMessagePattern 'falta -UpdateBuildBodyPath' -Block {
        Invoke-AdoApplyPhases -Plan $updateBuildPlan2 -PlanPath $updateBuildPlanPath2 -CreatedSoFar ([System.Collections.Generic.List[string]]::new())
    }
    Add-Result -Name 'Fase 4 (sin path): cero llamadas HTTP' -Pass ($script:mockWebCallCount -eq 0) -Detail "mockWebCallCount=$($script:mockWebCallCount)"

    # ============================================================
    # Grupo R-DELETE: Assert-AdoOperationRequestMatchesSpec /
    # operationTypes 'delete-variable-group', 'delete-build-definition',
    # 'delete-release-definition' (DELETE, agregadas 2026-08-26) -- mismo
    # nivel de rigor que el Grupo R-PUT para update-*.
    # ============================================================

    $deleteVgUri = "$vgUri" -replace '/variablegroups\?', '/variablegroups/412?'
    $deleteBuildUri = "$buildDefUri" -replace '/definitions\?', '/definitions/623?'
    $deleteReleaseUri = "$releaseDefUri" -replace '/definitions\?', '/definitions/382?'

    Add-Result -Name 'Assert-AdoOperationRequestMatchesSpec: delete-variable-group con id numerico -> valido' `
        -Pass ($null -ne (Assert-AdoOperationRequestMatchesSpec -OperationType 'delete-variable-group' -Method 'DELETE' -Uri $deleteVgUri -Label 'rdel1')) -Detail 'OK'
    Add-Result -Name 'Assert-AdoOperationRequestMatchesSpec: delete-build-definition con id numerico -> valido' `
        -Pass ($null -ne (Assert-AdoOperationRequestMatchesSpec -OperationType 'delete-build-definition' -Method 'DELETE' -Uri $deleteBuildUri -Label 'rdel2')) -Detail 'OK'
    Add-Result -Name 'Assert-AdoOperationRequestMatchesSpec: delete-release-definition con id numerico -> valido' `
        -Pass ($null -ne (Assert-AdoOperationRequestMatchesSpec -OperationType 'delete-release-definition' -Method 'DELETE' -Uri $deleteReleaseUri -Label 'rdel3')) -Detail 'OK'

    Invoke-ExpectThrow -Name 'Assert-AdoOperationRequestMatchesSpec: delete-variable-group SIN id de recurso -> rechazado' `
        -ExpectedMessagePattern 'id numerico' -Block {
        Assert-AdoOperationRequestMatchesSpec -OperationType 'delete-variable-group' -Method 'DELETE' -Uri $vgUri -Label 'rdel4'
    }
    Invoke-ExpectThrow -Name 'Assert-AdoOperationRequestMatchesSpec: delete-build-definition con metodo GET (en vez de DELETE) -> rechazado' `
        -ExpectedMessagePattern "method debe ser 'DELETE'" -Block {
        Assert-AdoOperationRequestMatchesSpec -OperationType 'delete-build-definition' -Method 'GET' -Uri $deleteBuildUri -Label 'rdel5'
    }
    Invoke-ExpectThrow -Name 'Assert-AdoOperationRequestMatchesSpec: delete-release-definition con host de Build (en vez de vsrm) -> rechazado' `
        -ExpectedMessagePattern 'debe usar el host' -Block {
        Assert-AdoOperationRequestMatchesSpec -OperationType 'delete-release-definition' -Method 'DELETE' -Uri $deleteBuildUri -Label 'rdel6'
    }

    $delOpEntry = New-AdoApprovedOperationEntry -OperationId 'rdel7' -OperationType 'delete-variable-group' -Uri $deleteVgUri -Body $null
    Add-Result -Name 'New-AdoApprovedOperationEntry: delete-variable-group deriva method=DELETE del spec (nunca hardcodeado)' `
        -Pass ($delOpEntry.method -eq 'DELETE') -Detail "method=$($delOpEntry.method)"
    Add-Result -Name 'New-AdoApprovedOperationEntry: bodyHash de un borrado (body nulo) es el mismo hash constante de {} que cualquier body vacio' `
        -Pass ($delOpEntry.bodyHash -eq (Get-AdoBodyCanonicalHash -Body $null)) -Detail "bodyHash=$($delOpEntry.bodyHash)"

    # ============================================================
    # Grupo X-DELETEPLAN: New-AdoClassicDeletePlan.ps1 +
    # Test-AdoClassicDeletePlan.ps1 (agregados 2026-08-26). Ejecutados
    # como scripts hijo (Invoke-ChildScript) igual que
    # New-AdoClassicAksPlan.ps1/Test-AdoClassicPlan.ps1 -- son de solo
    # lectura de archivos locales, no necesitan mock de red.
    # ============================================================

    $deleteInv = Copy-OrderedHash -Source $baseInventory
    $deleteInv.variableGroups = @(@{ id = 412; name = 'Desarrollo-Administracion-Proyectos-Web-Ficticio' })
    $deleteInv.buildDefinitions = @(@{ id = 623; name = 'Build-Administracion-Proyectos-Web-Ficticio'; path = '\Ficticio' })
    $deleteInv.releaseDefinitions = @(@{ id = 382; name = 'Deploy-Administracion-Proyectos-Web-Ficticio'; path = '\Ficticio' })
    $deleteInvPath = Join-Path $testTempRoot 'inventory-delete.json'
    [PSCustomObject]$deleteInv | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $deleteInvPath -Encoding utf8

    $deletePlanPathVg = Join-Path $testTempRoot 'delete-plan-vg.json'
    $genVgResult = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'New-AdoClassicDeletePlan.ps1') -ScriptArgs @(
        '-ResourceType', 'VariableGroup', '-ResourceName', 'Desarrollo-Administracion-Proyectos-Web-Ficticio',
        '-InventoryPath', $deleteInvPath, '-OutPath', $deletePlanPathVg
    )
    Add-Result -Name 'New-AdoClassicDeletePlan: genera el plan sin error (VariableGroup encontrado en inventario)' `
        -Pass ($genVgResult.ExitCode -eq 0 -and (Test-Path -LiteralPath $deletePlanPathVg)) -Detail $genVgResult.TextFlat

    $deletePlanVg = Get-Content -LiteralPath $deletePlanPathVg -Raw | ConvertFrom-Json
    Add-Result -Name 'New-AdoClassicDeletePlan: resourceId resuelto del inventario (412), nunca inventado' `
        -Pass ($deletePlanVg.resourceId -eq 412) -Detail "resourceId=$($deletePlanVg.resourceId)"
    Add-Result -Name 'New-AdoClassicDeletePlan: operationKind=delete, backupRequired=true fijo (no configurable)' `
        -Pass ($deletePlanVg.operationKind -eq 'delete' -and $deletePlanVg.backupRequired -eq $true) `
        -Detail "operationKind=$($deletePlanVg.operationKind); backupRequired=$($deletePlanVg.backupRequired)"
    Add-Result -Name 'New-AdoClassicDeletePlan: exactamente 1 approvedOperation de tipo delete-variable-group, method DELETE' `
        -Pass (@($deletePlanVg.approvedOperations).Count -eq 1 -and $deletePlanVg.approvedOperations[0].operationType -eq 'delete-variable-group' -and $deletePlanVg.approvedOperations[0].method -eq 'DELETE') `
        -Detail ($deletePlanVg.approvedOperations | ConvertTo-Json -Compress)
    Add-Result -Name 'New-AdoClassicDeletePlan: validated=false hasta pasar por Test-AdoClassicDeletePlan.ps1' `
        -Pass ($deletePlanVg.validated -eq $false) -Detail "validated=$($deletePlanVg.validated)"

    $genMissingResult = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'New-AdoClassicDeletePlan.ps1') -ScriptArgs @(
        '-ResourceType', 'BuildDefinition', '-ResourceName', 'Build-Que-No-Existe-Ficticio',
        '-InventoryPath', $deleteInvPath, '-OutPath', (Join-Path $testTempRoot 'delete-plan-missing.json')
    )
    Add-Result -Name 'New-AdoClassicDeletePlan: recurso inexistente en el inventario -> rechazado, nunca inventa un id' `
        -Pass ($genMissingResult.ExitCode -ne 0 -and $genMissingResult.TextFlat -match 'no se encontro ningun') -Detail $genMissingResult.TextFlat

    $deleteInvAmbiguous = Copy-OrderedHash -Source $baseInventory
    $deleteInvAmbiguous.variableGroups = @(
        @{ id = 412; name = 'VG-Duplicado-Ficticio' },
        @{ id = 999; name = 'VG-Duplicado-Ficticio' }
    )
    $deleteInvAmbiguousPath = Join-Path $testTempRoot 'inventory-delete-ambiguous.json'
    [PSCustomObject]$deleteInvAmbiguous | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $deleteInvAmbiguousPath -Encoding utf8
    $genAmbiguousResult = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'New-AdoClassicDeletePlan.ps1') -ScriptArgs @(
        '-ResourceType', 'VariableGroup', '-ResourceName', 'VG-Duplicado-Ficticio',
        '-InventoryPath', $deleteInvAmbiguousPath, '-OutPath', (Join-Path $testTempRoot 'delete-plan-ambiguous.json')
    )
    Add-Result -Name 'New-AdoClassicDeletePlan: nombre ambiguo (2 recursos con el mismo nombre) -> rechazado' `
        -Pass ($genAmbiguousResult.ExitCode -ne 0 -and $genAmbiguousResult.TextFlat -match 'ambiguo') -Detail $genAmbiguousResult.TextFlat

    # ---- Test-AdoClassicDeletePlan.ps1: validacion (recurso DEBE existir, al reves de "posible duplicado") ----
    $valVgResult = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'Test-AdoClassicDeletePlan.ps1') -ScriptArgs @(
        '-PlanPath', $deletePlanPathVg, '-InventoryPath', $deleteInvPath
    )
    $deletePlanVgValidated = Get-Content -LiteralPath $deletePlanPathVg -Raw | ConvertFrom-Json
    Add-Result -Name 'Test-AdoClassicDeletePlan: recurso existe con el mismo id -> validated=true, sin bloqueantes' `
        -Pass ($valVgResult.ExitCode -eq 0 -and $deletePlanVgValidated.validated -eq $true -and @($deletePlanVgValidated.validationBlockers).Count -eq 0) `
        -Detail "exit=$($valVgResult.ExitCode); validated=$($deletePlanVgValidated.validated); blockers=$($deletePlanVgValidated.validationBlockers -join ' | ')"
    Add-Result -Name 'Test-AdoClassicDeletePlan: validationHash/validationEvidence quedan poblados cuando validated=true' `
        -Pass (-not [string]::IsNullOrWhiteSpace([string]$deletePlanVgValidated.validationHash) -and $null -ne $deletePlanVgValidated.validationEvidence) `
        -Detail "validationHash=$($deletePlanVgValidated.validationHash)"

    # Recurso existe pero con id DISTINTO al que trae el plan -- bloqueante.
    $deletePlanIdMismatch = Join-Path $testTempRoot 'delete-plan-id-mismatch.json'
    Copy-Item $deletePlanPathVg $deletePlanIdMismatch -Force
    $planIdMismatchObj = Get-Content -LiteralPath $deletePlanIdMismatch -Raw | ConvertFrom-Json
    $planIdMismatchObj.resourceId = 999999
    $planIdMismatchObj.approvedOperations[0].uri = $planIdMismatchObj.approvedOperations[0].uri -replace '/412\?', '/999999?'
    $planIdMismatchObj | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $deletePlanIdMismatch -Encoding utf8
    $valMismatchResult = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'Test-AdoClassicDeletePlan.ps1') -ScriptArgs @(
        '-PlanPath', $deletePlanIdMismatch, '-InventoryPath', $deleteInvPath
    )
    $planIdMismatchValidated = Get-Content -LiteralPath $deletePlanIdMismatch -Raw | ConvertFrom-Json
    Add-Result -Name 'Test-AdoClassicDeletePlan: id del plan no coincide con el id en vivo -> bloqueante, validated=false' `
        -Pass ($planIdMismatchValidated.validated -eq $false -and (@($planIdMismatchValidated.validationBlockers) -match 'no coinciden')) `
        -Detail ($planIdMismatchValidated.validationBlockers -join ' | ')

    # Recurso ya no existe (fue borrado desde que se genero el plan) -- bloqueante.
    $deleteInvSinVg = Copy-OrderedHash -Source $baseInventory
    $deleteInvSinVg.variableGroups = @()
    $deleteInvSinVgPath = Join-Path $testTempRoot 'inventory-delete-sin-vg.json'
    [PSCustomObject]$deleteInvSinVg | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $deleteInvSinVgPath -Encoding utf8
    $deletePlanGoneVg = Join-Path $testTempRoot 'delete-plan-gone-vg.json'
    Copy-Item $deletePlanPathVg $deletePlanGoneVg -Force
    $valGoneResult = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'Test-AdoClassicDeletePlan.ps1') -ScriptArgs @(
        '-PlanPath', $deletePlanGoneVg, '-InventoryPath', $deleteInvSinVgPath
    )
    $planGoneValidated = Get-Content -LiteralPath $deletePlanGoneVg -Raw | ConvertFrom-Json
    Add-Result -Name 'Test-AdoClassicDeletePlan: el recurso ya no existe -> bloqueante ("no se puede borrar")' `
        -Pass ($planGoneValidated.validated -eq $false -and (@($planGoneValidated.validationBlockers) -match 'no se puede borrar')) `
        -Detail ($planGoneValidated.validationBlockers -join ' | ')

    # backupRequired=false -> bloqueante (nunca configurable a false)
    $deletePlanNoBackup = Join-Path $testTempRoot 'delete-plan-no-backup.json'
    Copy-Item $deletePlanPathVg $deletePlanNoBackup -Force
    $planNoBackupObj = Get-Content -LiteralPath $deletePlanNoBackup -Raw | ConvertFrom-Json
    $planNoBackupObj.backupRequired = $false
    $planNoBackupObj | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $deletePlanNoBackup -Encoding utf8
    $valNoBackupResult = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'Test-AdoClassicDeletePlan.ps1') -ScriptArgs @(
        '-PlanPath', $deletePlanNoBackup, '-InventoryPath', $deleteInvPath
    )
    $planNoBackupValidated = Get-Content -LiteralPath $deletePlanNoBackup -Raw | ConvertFrom-Json
    Add-Result -Name 'Test-AdoClassicDeletePlan: backupRequired=false -> siempre bloqueante' `
        -Pass ($planNoBackupValidated.validated -eq $false -and (@($planNoBackupValidated.validationBlockers) -match 'backupRequired debe ser true')) `
        -Detail ($planNoBackupValidated.validationBlockers -join ' | ')

    # approvedOperations con 2 entradas (en vez de exactamente 1) -> bloqueante
    $deletePlanTwoOps = Join-Path $testTempRoot 'delete-plan-two-ops.json'
    Copy-Item $deletePlanPathVg $deletePlanTwoOps -Force
    $planTwoOpsObj = Get-Content -LiteralPath $deletePlanTwoOps -Raw | ConvertFrom-Json
    $planTwoOpsObj.approvedOperations = @($planTwoOpsObj.approvedOperations[0], $planTwoOpsObj.approvedOperations[0])
    $planTwoOpsObj | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $deletePlanTwoOps -Encoding utf8
    $valTwoOpsResult = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'Test-AdoClassicDeletePlan.ps1') -ScriptArgs @(
        '-PlanPath', $deletePlanTwoOps, '-InventoryPath', $deleteInvPath
    )
    $planTwoOpsValidated = Get-Content -LiteralPath $deletePlanTwoOps -Raw | ConvertFrom-Json
    Add-Result -Name 'Test-AdoClassicDeletePlan: 2 entradas en approvedOperations (debe ser exactamente 1) -> bloqueante' `
        -Pass ($planTwoOpsValidated.validated -eq $false -and (@($planTwoOpsValidated.validationBlockers) -match 'EXACTAMENTE 1')) `
        -Detail ($planTwoOpsValidated.validationBlockers -join ' | ')

    # Inventario viejo (fuera de MaxInventoryAgeHours) -> bloqueante
    $staleDeleteInv = Copy-OrderedHash -Source $deleteInv
    $staleDeleteInv.generatedAtUtc = (Get-Date).ToUniversalTime().AddHours(-30).ToString('o')
    $staleDeleteInvPath = Join-Path $testTempRoot 'inventory-delete-stale.json'
    [PSCustomObject]$staleDeleteInv | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $staleDeleteInvPath -Encoding utf8
    $deletePlanStale = Join-Path $testTempRoot 'delete-plan-stale.json'
    Copy-Item $deletePlanPathVg $deletePlanStale -Force
    $valStaleResult = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'Test-AdoClassicDeletePlan.ps1') -ScriptArgs @(
        '-PlanPath', $deletePlanStale, '-InventoryPath', $staleDeleteInvPath, '-MaxInventoryAgeHours', '24'
    )
    $planStaleValidated = Get-Content -LiteralPath $deletePlanStale -Raw | ConvertFrom-Json
    Add-Result -Name 'Test-AdoClassicDeletePlan: inventario con mas antiguedad que MaxInventoryAgeHours -> bloqueante' `
        -Pass ($planStaleValidated.validated -eq $false -and (@($planStaleValidated.validationBlockers) -match 'antiguedad')) `
        -Detail ($planStaleValidated.validationBlockers -join ' | ')

    # ============================================================
    # Grupo Y-DELETEAPPLY: Fase 6 de Invoke-AdoApplyPhases (borrado real
    # con respaldo OBLIGATORIO). Se reusa el mock de Invoke-WebRequest del
    # Grupo M -- 2 llamadas por borrado exitoso (GET de respaldo, luego
    # DELETE).
    # ============================================================

    function Add-MockWebSuccessResponseWithBody {
        param([hashtable]$BodyObject)
        $content = ([PSCustomObject]$BodyObject) | ConvertTo-Json -Compress -Depth 10
        $script:mockWebResponseQueue.Enqueue([PSCustomObject]@{ Throw = $false; StatusCode = 200; Content = $content })
    }

    $deleteVgOpTest = New-AdoApprovedOperationEntry -OperationId 'ydel-1' -OperationType 'delete-variable-group' -Uri $deleteVgUri -Body $null
    $deleteVgPlanObj = [PSCustomObject]@{
        family        = 'aks'
        operationKind = 'delete'
        organization  = 'Shared-Service-GM'
        project       = 'DevOps'
        resourceType  = 'VariableGroup'
        resourceName  = 'Desarrollo-Administracion-Proyectos-Web-Ficticio'
        resourceId    = 412
        backupRequired = $true
        approvedOperations = @($deleteVgOpTest)
        validated     = $true
        validationHash = $null
    }
    $deleteVgPlanObj.validationHash = Get-AdoPlanCanonicalHash -Plan $deleteVgPlanObj
    $deleteVgPlanPath = Join-Path $testTempRoot 'delete-apply-plan-vg.json'
    $deleteVgPlanObj | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $deleteVgPlanPath -Encoding utf8
    $deleteVgPlan = Get-Content -LiteralPath $deleteVgPlanPath -Raw | ConvertFrom-Json

    $originalClaudeProjectDir = $env:REPO_ROOT
    $fakeProjectRoot = Join-Path $testTempRoot 'fake-project-root'
    New-Item -ItemType Directory -Force -Path $fakeProjectRoot | Out-Null
    $env:REPO_ROOT = $fakeProjectRoot

    try {
        Reset-MockWebRequest
        Add-MockWebSuccessResponseWithBody -BodyObject @{ id = 412; name = 'Desarrollo-Administracion-Proyectos-Web-Ficticio'; variables = @{ ambiente = @{ value = 'dev' } } }
        Add-MockWebSuccessResponse -ResultId 412
        $createdListDeleteVg = [System.Collections.Generic.List[string]]::new()
        Invoke-ExpectNoThrow -Name 'Fase 6 (borrar Variable Group): GET de respaldo + DELETE, ambos exitosos' -Block {
            Invoke-AdoApplyPhases -Plan $deleteVgPlan -PlanPath $deleteVgPlanPath -CreatedSoFar $createdListDeleteVg
        }
        Add-Result -Name 'Fase 6: exactamente 2 llamadas HTTP (GET de respaldo, luego DELETE)' -Pass ($script:mockWebCallCount -eq 2) -Detail "mockWebCallCount=$($script:mockWebCallCount)"
        Add-Result -Name 'Fase 6: CreatedSoFar registra el borrado' -Pass ($createdListDeleteVg.Count -eq 1 -and $createdListDeleteVg[0] -match 'BORRADO') -Detail ($createdListDeleteVg -join ' | ')

        $backupDir = Join-Path $fakeProjectRoot '.local\azure-devops\exports\pre-delete-backups'
        $backupFiles = @(Get-ChildItem -LiteralPath $backupDir -Filter 'VariableGroup-*.json' -ErrorAction SilentlyContinue)
        Add-Result -Name 'Fase 6: se escribio el archivo de respaldo obligatorio en .local/azure-devops/exports/pre-delete-backups/' `
            -Pass ($backupFiles.Count -eq 1) -Detail "backupDir=$backupDir; archivos=$($backupFiles.Name -join ', ')"

        if ($backupFiles.Count -eq 1) {
            $backupBytes = [System.IO.File]::ReadAllBytes($backupFiles[0].FullName)
            $hasBom = ($backupBytes.Length -ge 3 -and $backupBytes[0] -eq 0xEF -and $backupBytes[1] -eq 0xBB -and $backupBytes[2] -eq 0xBF)
            Add-Result -Name 'Fase 6: el respaldo se escribe SIN BOM (bug real de Set-Content -Encoding utf8 evitado a proposito)' `
                -Pass (-not $hasBom) -Detail "primeros bytes: $($backupBytes[0..([Math]::Min(2, $backupBytes.Length - 1))] -join ',')"

            $backupContent = Get-Content -LiteralPath $backupFiles[0].FullName -Raw | ConvertFrom-Json
            Add-Result -Name 'Fase 6: el respaldo contiene el recurso real devuelto por el GET (name/id)' `
                -Pass ($backupContent.name -eq 'Desarrollo-Administracion-Proyectos-Web-Ficticio' -and $backupContent.id -eq 412) `
                -Detail ($backupContent | ConvertTo-Json -Compress)
        }

        $journalDeleteVg = Get-Content -LiteralPath (Get-AdoExecutionJournalPath -PlanValidationHash $deleteVgPlan.validationHash) -Raw | ConvertFrom-Json
        Add-Result -Name 'Fase 6: journal marca la operacion de borrado succeeded' `
            -Pass ($journalDeleteVg.operations.'ydel-1'.state -eq 'succeeded') -Detail ($journalDeleteVg.operations | ConvertTo-Json -Compress)

        # Segunda corrida sobre el MISMO plan (ya succeeded) -- se omite, cero llamadas HTTP nuevas, cero respaldos nuevos.
        Reset-MockWebRequest
        $createdListDeleteVg2 = [System.Collections.Generic.List[string]]::new()
        Invoke-ExpectNoThrow -Name 'Fase 6: segunda corrida sobre plan de borrado ya succeeded -> se omite' -Block {
            Invoke-AdoApplyPhases -Plan $deleteVgPlan -PlanPath $deleteVgPlanPath -CreatedSoFar $createdListDeleteVg2
        }
        Add-Result -Name 'Fase 6: segunda corrida -> cero llamadas HTTP' -Pass ($script:mockWebCallCount -eq 0) -Detail "mockWebCallCount=$($script:mockWebCallCount)"
        $backupFilesAfterSecondRun = @(Get-ChildItem -LiteralPath $backupDir -Filter 'VariableGroup-*.json' -ErrorAction SilentlyContinue)
        Add-Result -Name 'Fase 6: segunda corrida -> no se escribe un respaldo nuevo' -Pass ($backupFilesAfterSecondRun.Count -eq 1) -Detail "archivos=$($backupFilesAfterSecondRun.Count)"

        # El GET de respaldo falla (recurso ilegible) -> se detiene ANTES del DELETE, cero borrados.
        $deleteBuildOpTest = New-AdoApprovedOperationEntry -OperationId 'ydel-2' -OperationType 'delete-build-definition' -Uri $deleteBuildUri -Body $null
        $deleteBuildPlanObj = [PSCustomObject]@{
            family = 'aks'; operationKind = 'delete'; organization = 'Shared-Service-GM'; project = 'DevOps'
            resourceType = 'BuildDefinition'; resourceName = 'Build-Administracion-Proyectos-Web-Ficticio'; resourceId = 623
            backupRequired = $true; approvedOperations = @($deleteBuildOpTest); validated = $true; validationHash = $null
        }
        $deleteBuildPlanObj.validationHash = Get-AdoPlanCanonicalHash -Plan $deleteBuildPlanObj
        $deleteBuildPlanPath = Join-Path $testTempRoot 'delete-apply-plan-build-failget.json'
        $deleteBuildPlanObj | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $deleteBuildPlanPath -Encoding utf8
        $deleteBuildPlan = Get-Content -LiteralPath $deleteBuildPlanPath -Raw | ConvertFrom-Json

        Reset-MockWebRequest
        Set-MockWebThrowNext -Message 'GET simulado fallido (recurso no disponible)'
        Invoke-ExpectThrow -Name 'Fase 6: GET de respaldo fallido -> rechazado ANTES de cualquier DELETE, respaldo obligatorio no negociable' `
            -ExpectedMessagePattern 'no se pudo leer' -Block {
            Invoke-AdoApplyPhases -Plan $deleteBuildPlan -PlanPath $deleteBuildPlanPath -CreatedSoFar ([System.Collections.Generic.List[string]]::new())
        }
        Add-Result -Name 'Fase 6 (GET de respaldo fallido): exactamente 1 llamada HTTP (el GET), nunca llega al DELETE' -Pass ($script:mockWebCallCount -eq 1) -Detail "mockWebCallCount=$($script:mockWebCallCount)"
        $buildBackupFiles = @(Get-ChildItem -LiteralPath $backupDir -Filter 'Build-*.json' -ErrorAction SilentlyContinue)
        Add-Result -Name 'Fase 6 (GET de respaldo fallido): no se escribio ningun archivo de respaldo' -Pass ($buildBackupFiles.Count -eq 0) -Detail "archivos=$($buildBackupFiles.Count)"
    }
    finally {
        if ([string]::IsNullOrWhiteSpace($originalClaudeProjectDir)) { Remove-Item Env:\REPO_ROOT -ErrorAction SilentlyContinue } else { $env:REPO_ROOT = $originalClaudeProjectDir }
    }

    # ============================================================
    # Grupo Z-DELETEREADBACK: rama de borrado de Test-AdoCreatedResources.ps1
    # (readback de AUSENCIA -- semantica opuesta al readback de creacion).
    # Se dot-sourcea el script (en vez de Invoke-ChildScript) para que el
    # mock de Invoke-WebRequest de este mismo proceso lo intercepte.
    # ============================================================

    $readbackDeletePlanPath = Join-Path $testTempRoot 'delete-readback-plan.json'
    ([PSCustomObject]@{ operationKind = 'delete'; project = 'DevOps'; resourceType = 'VariableGroup'; resourceName = 'VG-Ya-Borrado-Ficticio'; resourceId = 777 }) | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $readbackDeletePlanPath -Encoding utf8

    # IMPORTANTE: el dot-source va envuelto en "& { ... }" (scriptblock),
    # NUNCA suelto en este scope -- Test-AdoCreatedResources.ps1 declara su
    # PROPIA variable $results (sin prefijo $script:/$global:), y un
    # dot-source directo en este scope pisaria/reiniciaria el $results del
    # arnes completo, descartando en silencio TODOS los resultados
    # acumulados hasta ese punto (bug real encontrado 2026-08-26 escribiendo
    # esta misma prueba -- verificado con un repro aislado: "& { . script }"
    # crea un scope hijo que aisla esa reasignacion sin impedir que
    # 'exit' dentro del script siga terminando solo esa ejecucion, nunca
    # el proceso completo).
    Reset-MockWebRequest
    Add-MockWebSuccessResponseWithBody -BodyObject @{ value = @(); count = 0 }
    Invoke-ExpectNoThrow -Name 'Test-AdoCreatedResources (rama borrado): confirma ausencia -> Ok=true' -Block {
        & { . (Join-Path $scriptsRoot 'Test-AdoCreatedResources.ps1') -PlanPath $readbackDeletePlanPath }
    }
    Add-Result -Name 'Test-AdoCreatedResources (rama borrado): recurso ausente -> exit 0 (readback exitoso)' -Pass ($LASTEXITCODE -eq 0) -Detail "LASTEXITCODE=$LASTEXITCODE"

    Reset-MockWebRequest
    Add-MockWebSuccessResponseWithBody -BodyObject @{ value = @(@{ id = 777; name = 'VG-Ya-Borrado-Ficticio' }); count = 1 }
    & { . (Join-Path $scriptsRoot 'Test-AdoCreatedResources.ps1') -PlanPath $readbackDeletePlanPath }
    Add-Result -Name 'Test-AdoCreatedResources (rama borrado): recurso TODAVIA existe -> readback marca fallo (exit != 0)' `
        -Pass ($LASTEXITCODE -ne 0) -Detail "LASTEXITCODE=$LASTEXITCODE"

    # ============================================================
    # Grupo V: deteccion de secretos -- libreria compartida
    # (ado-secret-scan-lib.ps1) usada por ado-post-validate.ps1 (por
    # archivo, PostToolUse) Y ahora tambien por ado-stop-validate.ps1
    # (backstop de fin de sesion sobre TODOS los JSON del dominio,
    # incluidos los generados por Bash). Con datos 100% ficticios.
    # ============================================================

    $hooksRoot = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $scriptsRoot))) 'hooks\azure-devops-pipelines'
    . (Join-Path $hooksRoot 'ado-secret-scan-lib.ps1')

    $sensitiveFake = [PSCustomObject]@{ password = 'ValorRealFicticioNuncaDeberiaPasar123' }
    Add-Result -Name 'Find-AdoSensitiveJsonProperties: valor literal en propiedad sensible -> detectado' `
        -Pass ((Find-AdoSensitiveJsonProperties -Node $sensitiveFake).Count -eq 1) -Detail 'OK'

    $placeholderFake = [PSCustomObject]@{ password = '${DB_PASSWORD}' }
    Add-Result -Name 'Find-AdoSensitiveJsonProperties: placeholder ${VAR} -> permitido' `
        -Pass ((Find-AdoSensitiveJsonProperties -Node $placeholderFake).Count -eq 0) -Detail 'OK'

    $rawHits = Find-AdoRawTextSecretPatterns -RawText '{"pat": "abcdefghijklmnopqrstuvwx0123456789"}'
    Add-Result -Name 'Find-AdoRawTextSecretPatterns: PAT literal embebido -> detectado' -Pass ($rawHits.Count -gt 0) -Detail ($rawHits -join ', ')

    $rawHitsOk = Find-AdoRawTextSecretPatterns -RawText '{"note": "usar ${AZURE_DEVOPS_PAT}"}'
    Add-Result -Name 'Find-AdoRawTextSecretPatterns: placeholder ${AZURE_DEVOPS_PAT} -> permitido, sin falso positivo' -Pass ($rawHitsOk.Count -eq 0) -Detail 'OK'

    # V-hook: ado-stop-validate.ps1 end-to-end -- backstop sobre un JSON
    # "generado por Bash" (aca simulado con Set-Content directo, sin pasar
    # por el hook PostToolUse) bajo un REPO_ROOT ficticio propio,
    # nunca el proyecto real. Confirma que el hook lo atrapa (exit 2) y
    # que un archivo limpio no lo hace fallar (exit 0).
    $fakeProjectDir = Join-Path $testTempRoot 'fake-project-for-stop-hook'
    $fakeAdoLocalDir = Join-Path $fakeProjectDir '.local\azure-devops'
    New-Item -ItemType Directory -Force -Path $fakeAdoLocalDir | Out-Null

    $originalClaudeProjectDir = $env:REPO_ROOT
    $env:REPO_ROOT = $fakeProjectDir
    try {
        $badJsonPath = Join-Path $fakeAdoLocalDir 'plan-generado-por-bash-con-secreto.json'
        '{"password": "EsteEsUnSecretoRealFicticioNuncaDeberiaQuedar"}' | Set-Content -LiteralPath $badJsonPath -Encoding utf8

        function Invoke-StopHookWithEmptyStdin {
            # ado-stop-validate.ps1 lee [Console]::In.ReadToEnd() -- sin
            # pipear algo (aunque sea vacio), un powershell.exe hijo puede
            # quedar esperando stdin real. Se le pipea '' explicitamente
            # (a diferencia de Invoke-ChildScript, que no redirige stdin,
            # usado en otros grupos para scripts que no leen la consola).
            param([string]$ScriptPath)
            $stderrFile = Join-Path $testTempRoot ("stophook-stderr-{0}.txt" -f ([Guid]::NewGuid().ToString('N')))
            $prevEap = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $stdout = '' | & powershell -NoProfile -File $ScriptPath 2> $stderrFile
                $exitCode = $LASTEXITCODE
                $stderrText = if (Test-Path -LiteralPath $stderrFile) { Get-Content -LiteralPath $stderrFile -Raw } else { '' }
                $flat = ((($stdout | Out-String) + "`n" + $stderrText) -replace '\s+', ' ').Trim()
                return [PSCustomObject]@{ TextFlat = $flat; ExitCode = $exitCode }
            }
            finally {
                $ErrorActionPreference = $prevEap
                Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
            }
        }

        $stopHookResult = Invoke-StopHookWithEmptyStdin -ScriptPath (Join-Path $hooksRoot 'ado-stop-validate.ps1')
        Add-Result -Name 'ado-stop-validate.ps1: backstop atrapa un secreto en JSON "generado por Bash" (no via hook PostToolUse) -> falla' `
            -Pass ($stopHookResult.ExitCode -ne 0 -and $stopHookResult.TextFlat -match 'propiedades sensibles') `
            -Detail "exit=$($stopHookResult.ExitCode); texto=$($stopHookResult.TextFlat.Substring(0, [Math]::Min(200, $stopHookResult.TextFlat.Length)))"

        Remove-Item -LiteralPath $badJsonPath -Force
        $cleanJsonPath = Join-Path $fakeAdoLocalDir 'plan-limpio.json'
        '{"password": "${DB_PASSWORD}", "namespace": "desarrollo"}' | Set-Content -LiteralPath $cleanJsonPath -Encoding utf8

        $stopHookResultClean = Invoke-StopHookWithEmptyStdin -ScriptPath (Join-Path $hooksRoot 'ado-stop-validate.ps1')
        Add-Result -Name 'ado-stop-validate.ps1: JSON limpio (placeholder, sin secretos) -> no falla por deteccion de secretos' `
            -Pass ($stopHookResultClean.TextFlat -notmatch 'propiedades sensibles' -and $stopHookResultClean.TextFlat -notmatch 'secreto embebido') `
            -Detail "exit=$($stopHookResultClean.ExitCode)"
    }
    finally {
        if ($null -eq $originalClaudeProjectDir) { Remove-Item Env:\REPO_ROOT -ErrorAction SilentlyContinue } else { $env:REPO_ROOT = $originalClaudeProjectDir }
    }

    # ============================================================
    # Grupo W: referencias de secretos controladas (${ADO_SECRET_*}) --
    # el mecanismo NUNCA usa un secreto real: se define una variable de
    # entorno FICTICIA solo para estas pruebas, con un valor que no es un
    # secreto de nadie, y se confirma que nunca aparece en plan, journal,
    # logs (Write-Host capturado) ni mensajes de error.
    # ============================================================

    $fakeSecretEnvName = 'ADO_SECRET_TEST_FAKE_PASSWORD'
    $fakeSecretValue = 'ValorFicticioDePruebaNuncaRealXYZ999'
    $originalFakeSecretEnv = [Environment]::GetEnvironmentVariable($fakeSecretEnvName, 'Process')
    [Environment]::SetEnvironmentVariable($fakeSecretEnvName, $fakeSecretValue, 'Process')

    try {
        # W1: placeholder ${ADO_SECRET_...} permitido por el detector de
        # secretos (mismo patron generico ${VAR} ya soportado -- se
        # reconfirma explicitamente con el nombre real del mecanismo).
        $adoSecretPlaceholderFake = [PSCustomObject]@{ containerRegistryPassword = '${ADO_SECRET_CONTAINER_REGISTRY_PASSWORD}' }
        Add-Result -Name 'Referencias de secretos: placeholder ${ADO_SECRET_CONTAINER_REGISTRY_PASSWORD} -> permitido por el detector' `
            -Pass ((Find-AdoSensitiveJsonProperties -Node $adoSecretPlaceholderFake).Count -eq 0) -Detail 'OK'

        # W2: Resolve-AdoSecretEnvValue rechaza nombres que no tengan la forma ADO_SECRET_<NOMBRE>
        Invoke-ExpectThrow -Name 'Referencias de secretos: Resolve-AdoSecretEnvValue rechaza un nombre que no empieza con ADO_SECRET_' `
            -ExpectedMessagePattern 'no tiene la forma ADO_SECRET_' -Block {
            Resolve-AdoSecretEnvValue -EnvVarName 'OTRA_COSA_CUALQUIERA'
        }

        # W3: Resolve-AdoSecretEnvValue rechaza una variable de entorno inexistente/vacia
        Invoke-ExpectThrow -Name 'Referencias de secretos: variable de entorno ADO_SECRET_* no configurada -> rechazado' `
            -ExpectedMessagePattern 'no esta configurada o esta vacia' -Block {
            Resolve-AdoSecretEnvValue -EnvVarName 'ADO_SECRET_QUE_NO_EXISTE_PARA_ESTE_TEST'
        }

        # W4: Resolve-AdoSecretEnvValue con la variable ficticia SI configurada -> devuelve el valor
        $resolvedFake = Resolve-AdoSecretEnvValue -EnvVarName $fakeSecretEnvName
        Add-Result -Name 'Referencias de secretos: Resolve-AdoSecretEnvValue devuelve el valor real cuando la variable existe' `
            -Pass ($resolvedFake -eq $fakeSecretValue) -Detail 'OK (valor ficticio de prueba, nunca un secreto real)'

        # W5: New-AdoBodyWithResolvedSecrets -- happy path (isSecret=true, placeholder exacto) -> sustituye
        $bodyWithPlaceholder = [PSCustomObject]@{
            variables = [PSCustomObject]@{
                containerRegistryPassword = [PSCustomObject]@{ value = "`${$fakeSecretEnvName}"; isSecret = $true }
                containerRegistryUsername = [PSCustomObject]@{ value = 'gmonhubacreastus20001' }
            }
        }
        $secretRefsW = @(@{ Path = 'variables.containerRegistryPassword.value'; EnvVarName = $fakeSecretEnvName })
        $resolvedBodyW = New-AdoBodyWithResolvedSecrets -Body $bodyWithPlaceholder -SecretReferences $secretRefsW
        Add-Result -Name 'Referencias de secretos: isSecret=true + placeholder exacto -> sustituido correctamente' `
            -Pass ($resolvedBodyW.variables.containerRegistryPassword.value -eq $fakeSecretValue) -Detail 'OK'
        Add-Result -Name 'Referencias de secretos: el body ORIGINAL (con placeholder) nunca se muta' `
            -Pass ($bodyWithPlaceholder.variables.containerRegistryPassword.value -eq "`${$fakeSecretEnvName}") -Detail 'OK'
        Add-Result -Name 'Referencias de secretos: otros campos del body (no listados en SecretReferences) quedan intactos' `
            -Pass ($resolvedBodyW.variables.containerRegistryUsername.value -eq 'gmonhubacreastus20001') -Detail 'OK'

        # W6: isSecret=false bloqueado (item obligatorio de la lista de pruebas)
        $bodyIsSecretFalse = [PSCustomObject]@{
            variables = [PSCustomObject]@{
                containerRegistryPassword = [PSCustomObject]@{ value = "`${$fakeSecretEnvName}"; isSecret = $false }
            }
        }
        Invoke-ExpectThrow -Name 'Referencias de secretos: isSecret=false -> rechazado, nunca se resuelve' `
            -ExpectedMessagePattern 'no es isSecret=true' -Block {
            New-AdoBodyWithResolvedSecrets -Body $bodyIsSecretFalse -SecretReferences @(@{ Path = 'variables.containerRegistryPassword.value'; EnvVarName = $fakeSecretEnvName })
        }

        # W6b: isSecret ausente por completo -> tambien rechazado (no solo =false explicito)
        $bodyIsSecretMissing = [PSCustomObject]@{ variables = [PSCustomObject]@{ containerRegistryPassword = [PSCustomObject]@{ value = "`${$fakeSecretEnvName}" } } }
        Invoke-ExpectThrow -Name 'Referencias de secretos: isSecret ausente -> rechazado' `
            -ExpectedMessagePattern 'no es isSecret=true' -Block {
            New-AdoBodyWithResolvedSecrets -Body $bodyIsSecretMissing -SecretReferences @(@{ Path = 'variables.containerRegistryPassword.value'; EnvVarName = $fakeSecretEnvName })
        }

        # W7: secreto LITERAL en vez del placeholder esperado -> rechazado (destino no validado,
        # item obligatorio "secreto literal en plan bloqueado" -- aca a nivel del body real).
        $bodyLiteralSecret = [PSCustomObject]@{
            variables = [PSCustomObject]@{
                containerRegistryPassword = [PSCustomObject]@{ value = 'UnValorLiteralQueNoEsElPlaceholderEsperado'; isSecret = $true }
            }
        }
        Invoke-ExpectThrow -Name 'Referencias de secretos: valor literal (no placeholder) en el path -> rechazado' `
            -ExpectedMessagePattern 'no contiene el placeholder esperado' -Block {
            New-AdoBodyWithResolvedSecrets -Body $bodyLiteralSecret -SecretReferences @(@{ Path = 'variables.containerRegistryPassword.value'; EnvVarName = $fakeSecretEnvName })
        }

        # W8: placeholder de OTRA variable en el path -> rechazado (no se sustituye "lo que sea
        # que parezca placeholder", solo el EXACTO esperado para ese path -- item 8 de la politica).
        $bodyWrongPlaceholder = [PSCustomObject]@{
            variables = [PSCustomObject]@{
                containerRegistryPassword = [PSCustomObject]@{ value = '${ADO_SECRET_OTRA_VARIABLE_DISTINTA}'; isSecret = $true }
            }
        }
        Invoke-ExpectThrow -Name 'Referencias de secretos: placeholder de OTRA variable en el path -> rechazado' `
            -ExpectedMessagePattern 'no contiene el placeholder esperado' -Block {
            New-AdoBodyWithResolvedSecrets -Body $bodyWrongPlaceholder -SecretReferences @(@{ Path = 'variables.containerRegistryPassword.value'; EnvVarName = $fakeSecretEnvName })
        }

        # W9: New-AdoReleaseDefinitionPayload rechaza una stageVariable marcada
        # isSecret=true cuyo value NO es un placeholder ${ADO_SECRET_...}
        # (nunca acepta un literal aca, ni siquiera antes de resolver nada).
        $envsW9 = @(@{ stage = 'Desarrollo'; variableGroupId = 1; artifactFilterBranch = 'development'; deployTaskGroupId = 'tg-x'; deployTaskGroupName = 'Deployment-MultiStage-Cluster-Desarrollo'; deployTaskGroupInputs = @{}; stageVariables = @{ containerRegistryPassword = @{ value = 'LiteralNoPermitido123'; isSecret = $true } } })
        Invoke-ExpectThrow -Name 'New-AdoReleaseDefinitionPayload: stageVariable isSecret=true con valor literal -> rechazado' `
            -ExpectedMessagePattern 'nunca se acepta un valor literal' -Block {
            New-AdoReleaseDefinitionPayload -Plan $fixturePlan -Environments $envsW9 -BuildDefinitionId 1 -BuildDefinitionName 'Build-W9'
        }

        # W10: happy path completo -- New-AdoReleaseDefinitionPayload con
        # stageVariables reales (username no-secreto + password como
        # referencia ADO_SECRET_) produce el body aprobable (con
        # placeholder), y ESE es el que se hashea/aprueba.
        $envsW10 = @(@{ stage = 'Desarrollo'; variableGroupId = 701; artifactFilterBranch = 'development'; deployTaskGroupId = 'tg-deploy-w10'; deployTaskGroupName = 'Deployment-MultiStage-Cluster-Desarrollo'; deployTaskGroupInputs = @{ ambiente = '$(ambiente)' }; stageVariables = @{
            containerRegistryUsername = @{ value = 'gmonhubacreastus20001'; isSecret = $false }
            containerRegistryPassword = @{ value = "`${$fakeSecretEnvName}"; isSecret = $true }
        } })
        $releasePayloadW10 = New-AdoReleaseDefinitionPayload -Plan $fixturePlan -Environments $envsW10 -BuildDefinitionId 707 -BuildDefinitionName 'Build-W10'
        Add-Result -Name 'New-AdoReleaseDefinitionPayload: stageVariables con placeholder ADO_SECRET_ -> queda en el body APROBABLE tal cual (nunca resuelto aca)' `
            -Pass ($releasePayloadW10.environments[0].variables.containerRegistryPassword.value -eq "`${$fakeSecretEnvName}" -and $releasePayloadW10.environments[0].variables.containerRegistryPassword.isSecret -eq $true) `
            -Detail 'OK'
        $w10ApprovedBodyHash = Get-AdoBodyCanonicalHash -Body $releasePayloadW10
        Add-Result -Name 'New-AdoReleaseDefinitionPayload: bodyHash del payload con placeholder es reproducible (nunca depende del secreto real)' `
            -Pass ($w10ApprovedBodyHash -eq (Get-AdoBodyCanonicalHash -Body $releasePayloadW10)) -Detail "hash=$w10ApprovedBodyHash"

        # W11-E2E: flujo completo Invoke-AdoRest con -SecretReferences --
        # aprobar el body CON PLACEHOLDER, invocar con ese mismo body +
        # -SecretReferences, confirmar que Invoke-WebRequest (mockeado)
        # SI recibio el valor real (para que Azure DevOps pueda guardarlo),
        # pero que NADA de lo que queda en disco (plan, journal) ni en la
        # salida capturada (logs) contiene el valor ficticio.
        $w11Op = @{ operationId = 'w11-release'; operationType = 'create-release-definition'; method = 'POST'; uri = $releaseDefUri; bodyHash = $w10ApprovedBodyHash }
        $planW11 = New-FakeApprovedPlan -ApprovedOperations @($w11Op)
        $planW11BytesBefore = [System.IO.File]::ReadAllBytes($planW11)

        Reset-MockWebRequest
        Add-MockWebSuccessResponse -ResultId 'w11-release-real-id'
        $capturedOutputW11 = $null
        Invoke-ExpectNoThrow -Name 'Referencias de secretos E2E: Invoke-AdoRest con -SecretReferences resuelve y envia el valor real, sin lanzar' -Block {
            $script:capturedOutputW11 = Invoke-AdoRest -Method POST -Uri $releaseDefUri -Body $releasePayloadW10 -RequireApprovedPlan -PlanPath $planW11 -OperationId 'w11-release' `
                -SecretReferences @(@{ Path = 'environments[0].variables.containerRegistryPassword.value'; EnvVarName = $fakeSecretEnvName }) -JournalLockTimeoutMs 2000 | Out-String
        }
        Add-Result -Name 'Referencias de secretos E2E: plan.json permanece BYTE A BYTE identico (solo tenia el placeholder, nunca cambia)' `
            -Pass (Test-PlanFileBytesUnchanged -PlanPath $planW11 -BaselineBytes $planW11BytesBefore) -Detail 'OK'

        $journalW11 = Get-Content -LiteralPath (Get-AdoExecutionJournalPath -PlanValidationHash (Get-Content -LiteralPath $planW11 -Raw | ConvertFrom-Json).validationHash) -Raw
        Add-Result -Name 'Referencias de secretos E2E: el journal NUNCA contiene el valor real del secreto' `
            -Pass ($journalW11 -notmatch [regex]::Escape($fakeSecretValue)) -Detail 'OK'
        Add-Result -Name 'Referencias de secretos E2E: la salida capturada (stdout/objeto devuelto) NUNCA contiene el valor real' `
            -Pass ($capturedOutputW11 -notmatch [regex]::Escape($fakeSecretValue)) -Detail 'OK'

        # W12: mensaje de error de una escritura fallida NUNCA contiene el secreto real
        $w12Op = @{ operationId = 'w12-release'; operationType = 'create-release-definition'; method = 'POST'; uri = $releaseDefUri; bodyHash = $w10ApprovedBodyHash }
        $planW12 = New-FakeApprovedPlan -ApprovedOperations @($w12Op)
        Reset-MockWebRequest
        Set-MockWebThrowNext -Message 'Fallo de red simulado (nunca debe filtrar el body)'
        $w12ExceptionMessage = $null
        try {
            Invoke-AdoRest -Method POST -Uri $releaseDefUri -Body $releasePayloadW10 -RequireApprovedPlan -PlanPath $planW12 -OperationId 'w12-release' `
                -SecretReferences @(@{ Path = 'environments[0].variables.containerRegistryPassword.value'; EnvVarName = $fakeSecretEnvName }) -JournalLockTimeoutMs 2000
        }
        catch { $w12ExceptionMessage = $_.Exception.Message }
        Add-Result -Name 'Referencias de secretos: fallo de red -> el mensaje de error NUNCA contiene el valor real del secreto' `
            -Pass ($null -ne $w12ExceptionMessage -and $w12ExceptionMessage -notmatch [regex]::Escape($fakeSecretValue)) `
            -Detail "mensaje=$w12ExceptionMessage"

        # W13: readback -- Azure DevOps enmascara/null-ea valores isSecret=true
        # en el body de RESPUESTA de un GET/POST; se simula esa forma real y
        # se confirma que el manejo de la respuesta (extraccion de resultId)
        # no falla ni intenta usar ese valor.
        $w13Op = @{ operationId = 'w13-release'; operationType = 'create-release-definition'; method = 'POST'; uri = $releaseDefUri; bodyHash = $w10ApprovedBodyHash }
        $planW13 = New-FakeApprovedPlan -ApprovedOperations @($w13Op)
        Reset-MockWebRequest
        $maskedResponseContent = [PSCustomObject]@{
            id        = 'w13-release-real-id'
            environments = @(@{ variables = @{ containerRegistryPassword = @{ isSecret = $true; value = $null } } })
        } | ConvertTo-Json -Depth 10 -Compress
        $script:mockWebResponseQueue.Enqueue([PSCustomObject]@{ Throw = $false; StatusCode = 200; Content = $maskedResponseContent })
        $w13Result = $null
        Invoke-ExpectNoThrow -Name 'Referencias de secretos: readback con variable secreta enmascarada (value=null) -> no falla, no la usa' -Block {
            $script:w13Result = Invoke-AdoRest -Method POST -Uri $releaseDefUri -Body $releasePayloadW10 -RequireApprovedPlan -PlanPath $planW13 -OperationId 'w13-release' `
                -SecretReferences @(@{ Path = 'environments[0].variables.containerRegistryPassword.value'; EnvVarName = $fakeSecretEnvName }) -JournalLockTimeoutMs 2000
        }
        Add-Result -Name 'Referencias de secretos: resultId se extrae igual aunque la respuesta traiga un secreto enmascarado' `
            -Pass ($w13Result.Body.id -eq 'w13-release-real-id') -Detail 'OK'

        # W14: cero llamadas HTTP "de mas" en todo el grupo -- cada Invoke-AdoRest
        # de este grupo (W11, W12, W13) hizo EXACTAMENTE 1 llamada real
        # (mockeada) cada uno, nunca alguna extra por resolver el secreto.
        Add-Result -Name 'Referencias de secretos: resolver y sustituir un secreto nunca agrega llamadas HTTP extra' `
            -Pass ($script:mockWebCallCount -eq 1) -Detail "ultima llamada del grupo: mockWebCallCount=$($script:mockWebCallCount) (se espera 1, la de W13)"
    }
    finally {
        if ($null -eq $originalFakeSecretEnv) {
            [Environment]::SetEnvironmentVariable($fakeSecretEnvName, $null, 'Process')
        }
        else {
            [Environment]::SetEnvironmentVariable($fakeSecretEnvName, $originalFakeSecretEnv, 'Process')
        }
    }

    # ============================================================
    # Grupo AA: New-AdoClassicUpdatePayload.ps1 -- construccion del body
    # PUT de update-build-definition/update-release-definition a partir de
    # un GET real (field-stripping) + splices composables. Cierra la
    # brecha que hasta 2026-08-27 se resolvia con scripts de scratch ad
    # hoc, distinto por cada microservicio Buklo. Fixtures SINTETICAS
    # (nunca datos reales) que replican el shape confirmado contra GETs
    # reales (Release 373 / Build 591, Buklo Microservice EMR, y el
    # approver real de Administracion-de-proyectos) documentado en el
    # header del propio script.
    # ============================================================

    . (Join-Path $scriptsRoot 'New-AdoClassicUpdatePayload.ps1')

    function New-FakeBuildGetFixtureAA {
        param([switch]$DuplicateFileCreator)
        $secondStep = if ($DuplicateFileCreator) {
            ',{"displayName":"File Creator deployment-dev.yml","enabled":true,"task":{"id":"1f81a8be-d8ce-497d-9791-190126f661e7","versionSpec":"6.*"},"inputs":{"filepath":"deployment-dev-2.yml","filecontent":"DUPLICADO"}}'
        } else { '' }
        $json = @"
{
  "id": 900100, "revision": 4, "name": "Build-AA-Ficticio",
  "url": "https://dev.azure.com/x/y/_apis/build/Definitions/900100?revision=4",
  "uri": "vstfs:///Build/Definition/900100",
  "createdDate": "2026-08-01T00:00:00Z",
  "authoredBy": { "id": "aaaa", "displayName": "Alguien" },
  "drafts": [],
  "_links": { "self": { "href": "https://x" } },
  "project": { "id": "proj-id", "name": "DevOps" },
  "queue": { "id": 127, "pool": { "id": 9, "name": "Azure Pipelines" }, "_links": { "self": { "href": "https://x" } } },
  "triggers": [ { "triggerType": "continuousIntegration", "branchFilters": ["+refs/heads/development"], "batchChanges": false } ],
  "variables": { "ambiente": { "value": "dev" } },
  "process": { "type": 1, "phases": [
      { "name": "Agent job 1", "refName": "Job_1", "condition": "succeeded()",
        "target": { "executionOptions": { "type": 0 }, "type": 1 },
        "steps": [
          { "displayName": "File Creator deployment-dev.yml", "enabled": true,
            "task": { "id": "1f81a8be-d8ce-497d-9791-190126f661e7", "versionSpec": "6.*" },
            "inputs": { "filepath": "deployment-dev.yml", "filecontent": "CONTENIDO-VIEJO" } }$secondStep
        ] } ] }
}
"@
        return ($json | ConvertFrom-Json)
    }

    function New-FakeReleaseGetFixtureAA {
        $json = @'
{
  "id": 900200, "revision": 7, "name": "Deploy-AA-Ficticio",
  "url": "https://vsrm.dev.azure.com/x/y/_apis/release/definitions/900200",
  "_links": { "self": { "href": "https://x" } },
  "createdBy": { "id": "u1" }, "createdOn": "2026-08-01T00:00:00Z",
  "modifiedBy": { "id": "u1" }, "modifiedOn": "2026-08-02T00:00:00Z",
  "projectReference": { "id": "proj-id" }, "source": "userInterface",
  "description": "", "isDeleted": false, "isDisabled": false,
  "environments": [
    {
      "id": 471, "name": "Desarrollo", "rank": 1,
      "owner": { "id": "u1", "displayName": "Alguien" },
      "deployStep": { "id": 1000 }, "badgeUrl": "https://x/badge/1",
      "currentRelease": { "id": 0, "url": "https://x/0" },
      "variableGroups": [ 100 ],
      "properties": { "BoardsEnvironmentType": { "$type": "System.String", "$value": "unmapped" }, "LinkBoardsWorkItems": { "$type": "System.String", "$value": "False" } },
      "preDeployApprovals": { "approvals": [ { "id": 5001, "rank": 1, "isAutomated": true, "isNotificationOn": false } ] },
      "postDeployApprovals": { "approvals": [ { "id": 5002, "rank": 1, "isAutomated": true, "isNotificationOn": false } ] },
      "conditions": [ { "name": "ReleaseStarted", "conditionType": "event", "value": "" } ],
      "deployPhases": [ { "deploymentInput": { "enableAccessToken": false }, "workflowTasks": [ { "taskId": "tg-deploy", "version": "1.*", "name": "Task group: Deploy" } ] } ]
    },
    {
      "id": 473, "name": "Produccion", "rank": 2,
      "owner": { "id": "u1", "displayName": "Alguien" },
      "deployStep": { "id": 1006 }, "badgeUrl": "https://x/badge/3",
      "currentRelease": { "id": 6712, "url": "https://x/6712" },
      "variableGroups": [ 102 ],
      "properties": { "BoardsEnvironmentType": { "$type": "System.String", "$value": "unmapped" }, "LinkBoardsWorkItems": { "$type": "System.String", "$value": "False" } },
      "preDeployApprovals": { "approvals": [ { "id": 5005, "rank": 1, "isAutomated": false, "isNotificationOn": false,
          "approver": { "displayName": "[Shared-Service-GM]\\Release Executers", "url": "https://x/identities/rel-exec", "id": "397ddbfe-1d60-4533-a4c9-b099f80ac154", "uniqueName": "" } } ] },
      "postDeployApprovals": { "approvals": [ { "id": 5006, "rank": 1, "isAutomated": true, "isNotificationOn": false } ] },
      "conditions": [ { "name": "ReleaseStarted", "conditionType": "event", "value": "" }, { "name": "_Build-Old", "conditionType": "artifact", "value": "{\"sourceBranch\":\"development\"}" } ],
      "deployPhases": [ { "deploymentInput": { "enableAccessToken": false }, "workflowTasks": [ { "taskId": "tg-deploy-prod", "version": "1.*", "name": "Task group: Deployment-Azur-Aks-v3" } ] } ]
    }
  ]
}
'@
        return ($json | ConvertFrom-Json)
    }

    # ---- ConvertTo-AdoUpdateBuildBody ----

    Invoke-ExpectThrow -Name 'AA: ConvertTo-AdoUpdateBuildBody rechaza un objeto sin id/revision' `
        -ExpectedMessagePattern "no tiene 'id'/'revision'" -Block {
        ConvertTo-AdoUpdateBuildBody -Build ([PSCustomObject]@{ name = 'x' })
    }

    $buildFixtureAA = New-FakeBuildGetFixtureAA
    $strippedBuildAA = ConvertTo-AdoUpdateBuildBody -Build $buildFixtureAA
    Add-Result -Name 'AA: ConvertTo-AdoUpdateBuildBody conserva id/revision' `
        -Pass ($strippedBuildAA.id -eq 900100 -and $strippedBuildAA.revision -eq 4) -Detail "id=$($strippedBuildAA.id) revision=$($strippedBuildAA.revision)"
    Add-Result -Name 'AA: ConvertTo-AdoUpdateBuildBody quita _links/authoredBy/createdDate/drafts/uri/url/project' `
        -Pass (-not $strippedBuildAA.PSObject.Properties['_links'] -and -not $strippedBuildAA.PSObject.Properties['authoredBy'] -and -not $strippedBuildAA.PSObject.Properties['createdDate'] -and -not $strippedBuildAA.PSObject.Properties['drafts'] -and -not $strippedBuildAA.PSObject.Properties['uri'] -and -not $strippedBuildAA.PSObject.Properties['url'] -and -not $strippedBuildAA.PSObject.Properties['project']) -Detail 'OK'
    Add-Result -Name 'AA: ConvertTo-AdoUpdateBuildBody quita queue._links pero conserva queue.id/pool' `
        -Pass (-not $strippedBuildAA.queue.PSObject.Properties['_links'] -and $strippedBuildAA.queue.id -eq 127 -and $strippedBuildAA.queue.pool.id -eq 9) -Detail 'OK'
    Add-Result -Name 'AA: ConvertTo-AdoUpdateBuildBody NUNCA muta el objeto original' `
        -Pass ($buildFixtureAA.PSObject.Properties['createdDate'] -ne $null -and $buildFixtureAA.PSObject.Properties['_links'] -ne $null) -Detail 'OK'

    # ---- Set-AdoFileCreatorContent ----

    $strippedBuildAA2 = ConvertTo-AdoUpdateBuildBody -Build (New-FakeBuildGetFixtureAA)
    Set-AdoFileCreatorContent -Build $strippedBuildAA2 -DisplayName 'File Creator deployment-dev.yml' -FileContent 'CONTENIDO-NUEVO' -Enabled $true | Out-Null
    Add-Result -Name 'AA: Set-AdoFileCreatorContent reemplaza filecontent del step encontrado' `
        -Pass ($strippedBuildAA2.process.phases[0].steps[0].inputs.filecontent -eq 'CONTENIDO-NUEVO') -Detail 'OK'

    Invoke-ExpectThrow -Name 'AA: Set-AdoFileCreatorContent lanza si no encuentra el displayName' `
        -ExpectedMessagePattern 'no se encontro ningun step File Creator' -Block {
        Set-AdoFileCreatorContent -Build (ConvertTo-AdoUpdateBuildBody -Build (New-FakeBuildGetFixtureAA)) -DisplayName 'No Existe' -FileContent 'x'
    }
    Invoke-ExpectThrow -Name 'AA: Set-AdoFileCreatorContent lanza si hay mas de un match (ambiguo)' `
        -ExpectedMessagePattern 'se encontraron 2 steps File Creator' -Block {
        Set-AdoFileCreatorContent -Build (ConvertTo-AdoUpdateBuildBody -Build (New-FakeBuildGetFixtureAA -DuplicateFileCreator)) -DisplayName 'File Creator deployment-dev.yml' -FileContent 'x'
    }

    # ---- Add-AdoBuildPhase / Add-AdoBuildStepToPhase ----

    $buildForPhaseAA = ConvertTo-AdoUpdateBuildBody -Build (New-FakeBuildGetFixtureAA)
    Add-AdoBuildPhase -Build $buildForPhaseAA -Phase ([PSCustomObject]@{ name = 'Nueva'; refName = 'Nueva_Ref' }) -Position 'Prepend' | Out-Null
    Add-Result -Name 'AA: Add-AdoBuildPhase -Position Prepend inserta al principio' `
        -Pass ($buildForPhaseAA.process.phases[0].refName -eq 'Nueva_Ref' -and $buildForPhaseAA.process.phases[1].refName -eq 'Job_1') -Detail ($buildForPhaseAA.process.phases | ForEach-Object { $_.refName }) -join ','

    $buildForStepAA = ConvertTo-AdoUpdateBuildBody -Build (New-FakeBuildGetFixtureAA)
    Add-AdoBuildStepToPhase -Build $buildForStepAA -PhaseRefName 'Job_1' -Step ([PSCustomObject]@{ displayName = 'Primero' }) -Position 'Prepend' | Out-Null
    Add-Result -Name 'AA: Add-AdoBuildStepToPhase -Position Prepend inserta al principio de la fase' `
        -Pass ($buildForStepAA.process.phases[0].steps[0].displayName -eq 'Primero' -and $buildForStepAA.process.phases[0].steps.Count -eq 2) -Detail 'OK'

    # ---- Set-AdoBuildTriggerMaxConcurrentBuilds / Add-AdoBuildVariables ----

    $buildForTriggerAA = ConvertTo-AdoUpdateBuildBody -Build (New-FakeBuildGetFixtureAA)
    Set-AdoBuildTriggerMaxConcurrentBuilds -Build $buildForTriggerAA -MaxConcurrentBuildsPerBranch 5 | Out-Null
    Add-Result -Name 'AA: Set-AdoBuildTriggerMaxConcurrentBuilds fija el campo en triggers[0]' `
        -Pass ($buildForTriggerAA.triggers[0].maxConcurrentBuildsPerBranch -eq 5) -Detail 'OK'
    Invoke-ExpectThrow -Name 'AA: Set-AdoBuildTriggerMaxConcurrentBuilds lanza sin triggers[0]' `
        -ExpectedMessagePattern 'no tiene triggers\[0\]' -Block {
        Set-AdoBuildTriggerMaxConcurrentBuilds -Build ([PSCustomObject]@{ triggers = @() }) -MaxConcurrentBuildsPerBranch 5
    }

    $buildForVarsAA = ConvertTo-AdoUpdateBuildBody -Build (New-FakeBuildGetFixtureAA)
    Add-AdoBuildVariables -Build $buildForVarsAA -Variables @{ ambiente = @{ value = 'uat' }; NUEVA = @{ value = 'x' } } | Out-Null
    Add-Result -Name 'AA: Add-AdoBuildVariables sobreescribe una existente y agrega una nueva' `
        -Pass ($buildForVarsAA.variables.ambiente.value -eq 'uat' -and $buildForVarsAA.variables.NUEVA.value -eq 'x') -Detail 'OK'
    Invoke-ExpectThrow -Name 'AA: Add-AdoBuildVariables rechaza isSecret=true con un valor literal' `
        -ExpectedMessagePattern 'nunca un literal' -Block {
        Add-AdoBuildVariables -Build (ConvertTo-AdoUpdateBuildBody -Build (New-FakeBuildGetFixtureAA)) -Variables @{ SECRETA = @{ value = 'literal123'; isSecret = $true } }
    }
    $buildForSecretVarAA = ConvertTo-AdoUpdateBuildBody -Build (New-FakeBuildGetFixtureAA)
    Add-AdoBuildVariables -Build $buildForSecretVarAA -Variables @{ SECRETA = @{ value = '${ADO_SECRET_ALGO}'; isSecret = $true } } | Out-Null
    Add-Result -Name 'AA: Add-AdoBuildVariables acepta isSecret=true con placeholder ADO_SECRET_' `
        -Pass ($buildForSecretVarAA.variables.SECRETA.value -eq '${ADO_SECRET_ALGO}' -and $buildForSecretVarAA.variables.SECRETA.isSecret -eq $true) -Detail 'OK'

    # ---- Add-AdoBuildMergeBatchingSplice ----

    $buildForBatchAA = ConvertTo-AdoUpdateBuildBody -Build (New-FakeBuildGetFixtureAA)
    Add-AdoBuildMergeBatchingSplice -Build $buildForBatchAA -EvaluarVentanaTaskGroupId 'tg-eval' -GanaElMasNuevoTaskGroupId 'tg-gana' -ReportarResultadoTaskGroupId 'tg-reportar' -MainPhaseRefName 'Job_1' | Out-Null
    $phaseRefNamesAA = @($buildForBatchAA.process.phases | ForEach-Object { $_.refName })
    Add-Result -Name 'AA: Add-AdoBuildMergeBatchingSplice inserta las 2 fases en orden ANTES de la principal' `
        -Pass (($phaseRefNamesAA -join ',') -eq 'Batch_Gate,Batch_Window,Job_1') -Detail ($phaseRefNamesAA -join ',')
    $mainPhaseAfterBatchAA = $buildForBatchAA.process.phases | Where-Object { $_.refName -eq 'Job_1' }
    $stepDisplayNamesAA = @($mainPhaseAfterBatchAA.steps | ForEach-Object { $_.displayName })
    Add-Result -Name 'AA: Add-AdoBuildMergeBatchingSplice agrega Gana-el-mas-nuevo PRIMERO y Reportar-resultado-HU AL FINAL' `
        -Pass ($stepDisplayNamesAA[0] -eq 'Task group: Gana-el-mas-nuevo' -and $stepDisplayNamesAA[-1] -eq 'Task group: Reportar-resultado-HU' -and $stepDisplayNamesAA.Count -eq 3) -Detail ($stepDisplayNamesAA -join ' | ')
    Add-Result -Name 'AA: Add-AdoBuildMergeBatchingSplice fija dependencies/condition/allowScriptsAuthAccessOption de la fase principal' `
        -Pass ($mainPhaseAfterBatchAA.dependencies[0].scope -eq 'Batch_Window' -and $mainPhaseAfterBatchAA.condition -match 'Batch_Window' -and $mainPhaseAfterBatchAA.target.allowScriptsAuthAccessOption -eq $true) -Detail 'OK'
    Add-Result -Name 'AA: Add-AdoBuildMergeBatchingSplice fija maxConcurrentBuildsPerBranch=5 y las 4 variables del mecanismo' `
        -Pass ($buildForBatchAA.triggers[0].maxConcurrentBuildsPerBranch -eq 5 -and $buildForBatchAA.variables.BATCH_WINDOW_MINUTES.value -eq '5' -and $buildForBatchAA.variables.SUPERSEDE_REASONS.value -eq 'IndividualCI,BatchedCI' -and $buildForBatchAA.variables.BATCH_WAIT_REASONS.value -eq 'IndividualCI,BatchedCI' -and $buildForBatchAA.variables.BATCH_PR_TITLE_MARKER.value -eq '[AUTO]') -Detail 'OK'
    Invoke-ExpectThrow -Name 'AA: Add-AdoBuildMergeBatchingSplice rechaza duplicar el mecanismo si Batch_Gate ya existe' `
        -ExpectedMessagePattern 'YA tiene una fase' -Block {
        Add-AdoBuildMergeBatchingSplice -Build $buildForBatchAA -EvaluarVentanaTaskGroupId 'tg-eval' -GanaElMasNuevoTaskGroupId 'tg-gana' -ReportarResultadoTaskGroupId 'tg-reportar' -MainPhaseRefName 'Job_1'
    }

    # ---- ConvertTo-AdoUpdateReleaseBody ----

    Invoke-ExpectThrow -Name 'AA: ConvertTo-AdoUpdateReleaseBody rechaza un objeto sin id/revision' `
        -ExpectedMessagePattern "no tiene 'id'/'revision'" -Block {
        ConvertTo-AdoUpdateReleaseBody -Release ([PSCustomObject]@{ name = 'x' })
    }

    $releaseFixtureAA = New-FakeReleaseGetFixtureAA
    $strippedReleaseAA = ConvertTo-AdoUpdateReleaseBody -Release $releaseFixtureAA
    Add-Result -Name 'AA: ConvertTo-AdoUpdateReleaseBody conserva id/revision' `
        -Pass ($strippedReleaseAA.id -eq 900200 -and $strippedReleaseAA.revision -eq 7) -Detail 'OK'
    Add-Result -Name 'AA: ConvertTo-AdoUpdateReleaseBody quita _links/createdBy/createdOn/modifiedBy/modifiedOn/url/projectReference/source/description/isDeleted/isDisabled' `
        -Pass (-not $strippedReleaseAA.PSObject.Properties['_links'] -and -not $strippedReleaseAA.PSObject.Properties['createdBy'] -and -not $strippedReleaseAA.PSObject.Properties['createdOn'] -and -not $strippedReleaseAA.PSObject.Properties['modifiedBy'] -and -not $strippedReleaseAA.PSObject.Properties['modifiedOn'] -and -not $strippedReleaseAA.PSObject.Properties['url'] -and -not $strippedReleaseAA.PSObject.Properties['projectReference'] -and -not $strippedReleaseAA.PSObject.Properties['source'] -and -not $strippedReleaseAA.PSObject.Properties['description'] -and -not $strippedReleaseAA.PSObject.Properties['isDeleted'] -and -not $strippedReleaseAA.PSObject.Properties['isDisabled']) -Detail 'OK'

    $devEnvAA = $strippedReleaseAA.environments | Where-Object { $_.name -eq 'Desarrollo' }
    $prodEnvAA = $strippedReleaseAA.environments | Where-Object { $_.name -eq 'Produccion' }
    Add-Result -Name 'AA: ConvertTo-AdoUpdateReleaseBody quita deployStep/badgeUrl/currentRelease de cada environment, PRESERVA id y owner (bugfix 2026-09-04, Release 388)' `
        -Pass ($devEnvAA.PSObject.Properties['owner'] -ne $null -and $devEnvAA.owner.displayName -eq 'Alguien' -and -not $devEnvAA.PSObject.Properties['deployStep'] -and -not $devEnvAA.PSObject.Properties['badgeUrl'] -and -not $devEnvAA.PSObject.Properties['currentRelease'] -and $devEnvAA.PSObject.Properties['id'] -ne $null) -Detail 'OK'
    Add-Result -Name 'AA (contradiccion resuelta #1): ConvertTo-AdoUpdateReleaseBody PRESERVA properties con su contenido real' `
        -Pass ($devEnvAA.PSObject.Properties['properties'] -ne $null -and $devEnvAA.properties.BoardsEnvironmentType.'$value' -eq 'unmapped' -and $prodEnvAA.properties.BoardsEnvironmentType.'$value' -eq 'unmapped') -Detail 'OK'
    $prodApprovalAA = $prodEnvAA.preDeployApprovals.approvals[0]
    Add-Result -Name 'AA (contradiccion resuelta #2): ConvertTo-AdoUpdateReleaseBody quita SOLO el id de cada approval, preserva approver/isAutomated/rank real' `
        -Pass (-not $prodApprovalAA.PSObject.Properties['id'] -and $prodApprovalAA.isAutomated -eq $false -and $prodApprovalAA.rank -eq 1 -and $prodApprovalAA.approver.id -eq '397ddbfe-1d60-4533-a4c9-b099f80ac154') -Detail 'OK'
    Add-Result -Name 'AA: ConvertTo-AdoUpdateReleaseBody NUNCA muta el objeto original' `
        -Pass ($releaseFixtureAA.PSObject.Properties['_links'] -ne $null -and $releaseFixtureAA.environments[1].preDeployApprovals.approvals[0].PSObject.Properties['id'] -ne $null) -Detail 'OK'

    # ---- Set-AdoReleaseEnvironmentVariableGroups ----

    $releaseForVgAA = ConvertTo-AdoUpdateReleaseBody -Release (New-FakeReleaseGetFixtureAA)
    Set-AdoReleaseEnvironmentVariableGroups -Release $releaseForVgAA -Stage 'Desarrollo' -VariableGroupIds @(555) | Out-Null
    Add-Result -Name 'AA: Set-AdoReleaseEnvironmentVariableGroups relinkea el VG del stage indicado' `
        -Pass ((($releaseForVgAA.environments | Where-Object { $_.name -eq 'Desarrollo' }).variableGroups -join ',') -eq '555') -Detail 'OK'
    Invoke-ExpectThrow -Name 'AA: Set-AdoReleaseEnvironmentVariableGroups lanza si el stage no existe' `
        -ExpectedMessagePattern 'no existe ningun environment' -Block {
        Set-AdoReleaseEnvironmentVariableGroups -Release (ConvertTo-AdoUpdateReleaseBody -Release (New-FakeReleaseGetFixtureAA)) -Stage 'NoExiste' -VariableGroupIds @(1)
    }

    # ---- Add-AdoReleaseEnvironmentCdTrigger ----

    $releaseForCdAA = ConvertTo-AdoUpdateReleaseBody -Release (New-FakeReleaseGetFixtureAA)
    Add-AdoReleaseEnvironmentCdTrigger -Release $releaseForCdAA -Stage 'Desarrollo' -ArtifactAlias '_Build-Nuevo' -SourceBranch 'development' | Out-Null
    $devConditionsAA = ($releaseForCdAA.environments | Where-Object { $_.name -eq 'Desarrollo' }).conditions
    Add-Result -Name 'AA: Add-AdoReleaseEnvironmentCdTrigger agrega ReleaseStarted + condicion de artifact cuando no habia ninguna de artifact' `
        -Pass (@($devConditionsAA | Where-Object { $_.conditionType -eq 'event' -and $_.name -eq 'ReleaseStarted' }).Count -eq 1 -and @($devConditionsAA | Where-Object { $_.conditionType -eq 'artifact' -and $_.name -eq '_Build-Nuevo' }).Count -eq 1) -Detail 'OK'

    $releaseForCdReplaceAA = ConvertTo-AdoUpdateReleaseBody -Release (New-FakeReleaseGetFixtureAA)
    Add-AdoReleaseEnvironmentCdTrigger -Release $releaseForCdReplaceAA -Stage 'Produccion' -ArtifactAlias '_Build-Reemplazo' -SourceBranch 'release' | Out-Null
    $prodConditionsAA = ($releaseForCdReplaceAA.environments | Where-Object { $_.name -eq 'Produccion' }).conditions
    Add-Result -Name 'AA: Add-AdoReleaseEnvironmentCdTrigger reemplaza la condicion de artifact existente (no duplica) y preserva ReleaseStarted' `
        -Pass (@($prodConditionsAA | Where-Object { $_.conditionType -eq 'artifact' }).Count -eq 1 -and @($prodConditionsAA | Where-Object { $_.conditionType -eq 'artifact' })[0].name -eq '_Build-Reemplazo' -and @($prodConditionsAA | Where-Object { $_.conditionType -eq 'event' }).Count -eq 1) -Detail ($prodConditionsAA | ConvertTo-Json -Compress)

    # ---- Set-AdoReleaseProductionApprovalGate ----

    Invoke-ExpectThrow -Name 'AA: Set-AdoReleaseProductionApprovalGate exige -ApproverId cuando -IsAutomated $false' `
        -ExpectedMessagePattern 'requiere -ApproverId' -Block {
        Set-AdoReleaseProductionApprovalGate -Release (ConvertTo-AdoUpdateReleaseBody -Release (New-FakeReleaseGetFixtureAA)) -Stage 'Desarrollo' -IsAutomated $false
    }

    $releaseForGateAA = ConvertTo-AdoUpdateReleaseBody -Release (New-FakeReleaseGetFixtureAA)
    Set-AdoReleaseProductionApprovalGate -Release $releaseForGateAA -Stage 'Desarrollo' -IsAutomated $false -ApproverId 'grupo-real-guid-123' | Out-Null
    $devApprovalAfterGateAA = ($releaseForGateAA.environments | Where-Object { $_.name -eq 'Desarrollo' }).preDeployApprovals.approvals[0]
    Add-Result -Name 'AA: Set-AdoReleaseProductionApprovalGate fija isAutomated=false + approver.id real' `
        -Pass ($devApprovalAfterGateAA.isAutomated -eq $false -and $devApprovalAfterGateAA.approver.id -eq 'grupo-real-guid-123') -Detail 'OK'

    $releaseForGateBackAA = ConvertTo-AdoUpdateReleaseBody -Release (New-FakeReleaseGetFixtureAA)
    Set-AdoReleaseProductionApprovalGate -Release $releaseForGateBackAA -Stage 'Produccion' -IsAutomated $true | Out-Null
    $prodApprovalAfterGateBackAA = ($releaseForGateBackAA.environments | Where-Object { $_.name -eq 'Produccion' }).preDeployApprovals.approvals[0]
    Add-Result -Name 'AA: Set-AdoReleaseProductionApprovalGate -IsAutomated $true quita el approver' `
        -Pass ($prodApprovalAfterGateBackAA.isAutomated -eq $true -and -not $prodApprovalAfterGateBackAA.PSObject.Properties['approver']) -Detail 'OK'

    Invoke-ExpectThrow -Name 'AA: Set-AdoReleaseProductionApprovalGate lanza si el stage no tiene approvals' `
        -ExpectedMessagePattern 'no tiene' -Block {
        $releaseSinApprovalsAA = ConvertTo-AdoUpdateReleaseBody -Release (New-FakeReleaseGetFixtureAA)
        ($releaseSinApprovalsAA.environments | Where-Object { $_.name -eq 'Desarrollo' }).PSObject.Properties.Remove('preDeployApprovals')
        Set-AdoReleaseProductionApprovalGate -Release $releaseSinApprovalsAA -Stage 'Desarrollo' -IsAutomated $true
    }

    # ---- Add-AdoReleaseEnvironmentReportarResultadoHu ----

    $releaseForReportarAA = ConvertTo-AdoUpdateReleaseBody -Release (New-FakeReleaseGetFixtureAA)
    Add-AdoReleaseEnvironmentReportarResultadoHu -Release $releaseForReportarAA -Stage 'Desarrollo' -TaskGroupId 'tg-reportar-release' | Out-Null
    $devPhaseAfterReportarAA = ($releaseForReportarAA.environments | Where-Object { $_.name -eq 'Desarrollo' }).deployPhases[0]
    Add-Result -Name 'AA: Add-AdoReleaseEnvironmentReportarResultadoHu agrega el workflowTask y fuerza enableAccessToken=true' `
        -Pass ($devPhaseAfterReportarAA.workflowTasks.Count -eq 2 -and $devPhaseAfterReportarAA.workflowTasks[1].name -eq 'Task group: Reportar-resultado-HU' -and $devPhaseAfterReportarAA.deploymentInput.enableAccessToken -eq $true) -Detail 'OK'
    Invoke-ExpectThrow -Name 'AA: Add-AdoReleaseEnvironmentReportarResultadoHu rechaza duplicar el workflowTask' `
        -ExpectedMessagePattern 'YA tiene un workflowTask' -Block {
        Add-AdoReleaseEnvironmentReportarResultadoHu -Release $releaseForReportarAA -Stage 'Desarrollo' -TaskGroupId 'tg-reportar-release'
    }

    # ---- New-AdoClassicUpdateOperationUri / New-AdoClassicUpdateApprovedOperation ----

    Add-Result -Name 'AA: New-AdoClassicUpdateOperationUri arma la URI real de Build' `
        -Pass ((New-AdoClassicUpdateOperationUri -Kind Build -DefinitionId 900100) -eq 'https://dev.azure.com/Shared-Service-GM/DevOps/_apis/build/definitions/900100?api-version=7.1') -Detail (New-AdoClassicUpdateOperationUri -Kind Build -DefinitionId 900100)
    Add-Result -Name 'AA: New-AdoClassicUpdateOperationUri arma la URI real de Release' `
        -Pass ((New-AdoClassicUpdateOperationUri -Kind Release -DefinitionId 900200) -eq 'https://vsrm.dev.azure.com/Shared-Service-GM/DevOps/_apis/release/definitions/900200?api-version=7.1') -Detail (New-AdoClassicUpdateOperationUri -Kind Release -DefinitionId 900200)

    $updateOpResultAA = New-AdoClassicUpdateApprovedOperation -Kind Build -DefinitionId 900100 -Body $strippedBuildAA -OperationId 'aa-update-build-1'
    Add-Result -Name 'AA: New-AdoClassicUpdateApprovedOperation arma operationType/method/bodyHash correctos' `
        -Pass ($updateOpResultAA.approvedOperation.operationType -eq 'update-build-definition' -and $updateOpResultAA.approvedOperation.method -eq 'PUT' -and $updateOpResultAA.approvedOperation.bodyHash -eq (Get-AdoBodyCanonicalHash -Body $strippedBuildAA)) -Detail 'OK'

    # ---- AA-E2E: flujo completo (stripping + splice + approvedOperations)
    # contra Invoke-AdoApplyPhases MOCKEADO -- confirma que el body que
    # arma este script es aceptado tal cual por el mismo mecanismo de
    # Apply que ya usa update-build-definition/update-release-definition
    # hoy, sin ningun ajuste manual adicional.
    # ============================================================

    $e2eReleaseAA = ConvertTo-AdoUpdateReleaseBody -Release (New-FakeReleaseGetFixtureAA)
    Add-AdoReleaseEnvironmentReportarResultadoHu -Release $e2eReleaseAA -Stage 'Desarrollo' -TaskGroupId 'tg-reportar-e2e' | Out-Null
    $e2eResultAA = New-AdoClassicUpdateApprovedOperation -Kind Release -DefinitionId 900200 -Body $e2eReleaseAA -OperationId 'aa-e2e-release'

    $e2eBodyPathAA = Join-Path $testTempRoot 'aa-e2e-release-body.json'
    $e2eResultAA.body | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath $e2eBodyPathAA -Encoding utf8

    $e2ePlanObjAA = [PSCustomObject]@{
        family = 'aks'; organization = 'Shared-Service-GM'; project = 'DevOps'
        names  = [PSCustomObject]@{ build = 'Build-AA-E2E'; release = 'Deploy-AA-E2E'; folder = 'FolderAA' }
        approvedOperations = @($e2eResultAA.approvedOperation); validated = $true; validationHash = $null
    }
    $e2ePlanObjAA.validationHash = Get-AdoPlanCanonicalHash -Plan $e2ePlanObjAA
    $e2ePlanPathAA = Join-Path $testTempRoot 'aa-e2e-release-plan.json'
    $e2ePlanObjAA | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $e2ePlanPathAA -Encoding utf8
    $e2ePlanAA = Get-Content -LiteralPath $e2ePlanPathAA -Raw | ConvertFrom-Json

    Reset-MockWebRequest
    Add-MockWebSuccessResponse -ResultId '900200'
    $e2eCreatedAA = [System.Collections.Generic.List[string]]::new()
    Invoke-ExpectNoThrow -Name 'AA-E2E: el body compuesto por este script es aceptado sin cambios por Invoke-AdoApplyPhases (Fase 5, PUT)' -Block {
        Invoke-AdoApplyPhases -Plan $e2ePlanAA -PlanPath $e2ePlanPathAA -CreatedSoFar $e2eCreatedAA -UpdateReleaseBodyPath $e2eBodyPathAA
    }
    Add-Result -Name 'AA-E2E: exactamente 1 llamada HTTP (PUT)' -Pass ($script:mockWebCallCount -eq 1) -Detail "mockWebCallCount=$($script:mockWebCallCount)"
    $e2eJournalAA = Get-Content -LiteralPath (Get-AdoExecutionJournalPath -PlanValidationHash $e2ePlanAA.validationHash) -Raw | ConvertFrom-Json
    Add-Result -Name 'AA-E2E: journal marca la operacion succeeded con resultId real' `
        -Pass ($e2eJournalAA.operations.'aa-e2e-release'.state -eq 'succeeded' -and $e2eJournalAA.operations.'aa-e2e-release'.resultId -eq '900200') -Detail ($e2eJournalAA.operations | ConvertTo-Json -Compress)

    # ============================================================
    # Grupo AB: New-AdoClassicUpdatePlan.ps1 -- runner que cierra el 2do
    # gap (ver ado-emr-scratch-script-authorization-declined-2026-08-27).
    # Se prueba la funcion Invoke-AdoClassicUpdatePlanGeneration (ya
    # dot-sourceada via New-AdoClassicUpdatePayload.ps1 en el Grupo AA)
    # directamente -- el archivo .ps1 wrapper en si NUNCA se dot-sourcea
    # (tiene un bloque param() + ejecucion de nivel superior real, a
    # diferencia de los archivos -Payload.ps1 que son solo funciones).
    # ============================================================

    # ---- Seguridad del dispatch: mapa cerrado, nunca reflexion abierta ----

    Invoke-ExpectThrow -Name 'AB: Invoke-AdoUpdateSplice rechaza una funcion fuera del mapa cerrado' `
        -ExpectedMessagePattern 'no esta en el mapa cerrado' -Block {
        Invoke-AdoUpdateSplice -Target ([PSCustomObject]@{}) -Kind Build -FunctionName 'Invoke-Expression' -Params ([ordered]@{})
    }
    Invoke-ExpectThrow -Name 'AB: Invoke-AdoUpdateSplice rechaza intentar ejecutar un cmdlet real ajeno al mapa (Remove-Item)' `
        -ExpectedMessagePattern 'no esta en el mapa cerrado' -Block {
        Invoke-AdoUpdateSplice -Target ([PSCustomObject]@{}) -Kind Build -FunctionName 'Remove-Item' -Params ([ordered]@{ Path = 'C:\no-existe' })
    }
    Invoke-ExpectThrow -Name 'AB: Invoke-AdoUpdateSplice rechaza una funcion de Release cuando Kind=Build' `
        -ExpectedMessagePattern 'solo aplica a -Kind Release' -Block {
        Invoke-AdoUpdateSplice -Target (ConvertTo-AdoUpdateBuildBody -Build (New-FakeBuildGetFixtureAA)) -Kind Build -FunctionName 'Set-AdoReleaseEnvironmentVariableGroups' -Params ([ordered]@{ Stage = 'Desarrollo'; VariableGroupIds = @(1) })
    }
    Invoke-ExpectThrow -Name 'AB: Invoke-AdoUpdateSplice rechaza una funcion de Build cuando Kind=Release' `
        -ExpectedMessagePattern 'solo aplica a -Kind Build' -Block {
        Invoke-AdoUpdateSplice -Target (ConvertTo-AdoUpdateReleaseBody -Release (New-FakeReleaseGetFixtureAA)) -Kind Release -FunctionName 'Set-AdoFileCreatorContent' -Params ([ordered]@{ DisplayName = 'x'; FileContent = 'y' })
    }

    # ---- ConvertTo-AdoHashtableDeep ----

    $deepConvertSourceAB = (@'
{ "a": 1, "b": { "c": "x", "d": [1, 2, { "e": true }] }, "f": null }
'@ | ConvertFrom-Json)
    $deepConvertedAB = ConvertTo-AdoHashtableDeep -InputObject $deepConvertSourceAB
    Add-Result -Name 'AB: ConvertTo-AdoHashtableDeep convierte objetos anidados a hashtable splateable' `
        -Pass ($deepConvertedAB -is [System.Collections.IDictionary] -and $deepConvertedAB['a'] -eq 1 -and $deepConvertedAB['b']['c'] -eq 'x' -and $deepConvertedAB['b']['d'][2]['e'] -eq $true -and $null -eq $deepConvertedAB['f']) `
        -Detail ($deepConvertedAB | ConvertTo-Json -Compress -Depth 10)

    # ---- Rutas de rechazo de la funcion de orquestacion completa ----

    $abTempDir = Join-Path $testTempRoot 'ab'
    New-Item -ItemType Directory -Force -Path $abTempDir | Out-Null

    $abEmptySplicePath = Join-Path $abTempDir 'splices-empty.json'
    Set-Content -LiteralPath $abEmptySplicePath -Value '[]' -Encoding utf8

    Invoke-ExpectThrow -Name 'AB: Invoke-AdoClassicUpdatePlanGeneration rechaza otra organizacion' `
        -ExpectedMessagePattern "Shared-Service-GM" -Block {
        Invoke-AdoClassicUpdatePlanGeneration -Kind Build -DefinitionId 900100 -Organization 'Otra-Org' `
            -SpliceSpecPath $abEmptySplicePath -OperationId 'ab-x' `
            -OutBodyPath (Join-Path $abTempDir 'x-body.json') -OutPlanPath (Join-Path $abTempDir 'x-plan.json') `
            -BuildName 'x' -ReleaseName 'y' -ServiceConnectionAcrName 'z' -ArtifactFilterBranch 'release'
    }

    $abBuildFuncSplicePath = Join-Path $abTempDir 'splices-buildkey.json'
    Set-Content -LiteralPath $abBuildFuncSplicePath -Value '[{"function":"Set-AdoFileCreatorContent","displayName":"File Creator deployment-dev.yml","fileContent":"x","build":"no-permitido"}]' -Encoding utf8
    Reset-MockWebRequest

    function Add-MockWebSuccessResponseFromObjectAB {
        param($SourceObject)
        $content = $SourceObject | ConvertTo-Json -Depth 40 -Compress
        $script:mockWebResponseQueue.Enqueue([PSCustomObject]@{ Throw = $false; StatusCode = 200; Content = $content })
    }

    Add-MockWebSuccessResponseFromObjectAB -SourceObject (New-FakeBuildGetFixtureAA)
    Invoke-ExpectThrow -Name 'AB: Invoke-AdoClassicUpdatePlanGeneration rechaza una clave build/release dentro de la especificacion de splice' `
        -ExpectedMessagePattern "no puede traer una clave 'build'" -Block {
        Invoke-AdoClassicUpdatePlanGeneration -Kind Build -DefinitionId 900100 `
            -SpliceSpecPath $abBuildFuncSplicePath -OperationId 'ab-buildkey' `
            -OutBodyPath (Join-Path $abTempDir 'buildkey-body.json') -OutPlanPath (Join-Path $abTempDir 'buildkey-plan.json') `
            -BuildName 'x' -ReleaseName 'y' -ServiceConnectionAcrName 'z' -ArtifactFilterBranch 'release'
    }

    $abAmbiguousSplicePath = Join-Path $abTempDir 'splices-ambiguous.json'
    Set-Content -LiteralPath $abAmbiguousSplicePath -Value '[{"function":"Set-AdoFileCreatorContent","displayName":"File Creator deployment-dev.yml","fileContent":"x","fileContentPath":"C:\\no-existe.yml"}]' -Encoding utf8
    Add-MockWebSuccessResponseFromObjectAB -SourceObject (New-FakeBuildGetFixtureAA)
    Invoke-ExpectThrow -Name 'AB: Invoke-AdoClassicUpdatePlanGeneration rechaza fileContent + fileContentPath a la vez (ambiguo)' `
        -ExpectedMessagePattern 'ambiguo' -Block {
        Invoke-AdoClassicUpdatePlanGeneration -Kind Build -DefinitionId 900100 `
            -SpliceSpecPath $abAmbiguousSplicePath -OperationId 'ab-ambiguous' `
            -OutBodyPath (Join-Path $abTempDir 'ambiguous-body.json') -OutPlanPath (Join-Path $abTempDir 'ambiguous-plan.json') `
            -BuildName 'x' -ReleaseName 'y' -ServiceConnectionAcrName 'z' -ArtifactFilterBranch 'release'
    }

    Add-MockWebSuccessResponseFromObjectAB -SourceObject (New-FakeBuildGetFixtureAA)
    Invoke-ExpectThrow -Name 'AB: Invoke-AdoClassicUpdatePlanGeneration -- esqueleto nuevo rechaza sin -ArtifactFilterBranch (y lista TODOS los campos faltantes)' `
        -ExpectedMessagePattern '-ServiceConnectionAcrName, -ArtifactFilterBranch' -Block {
        Invoke-AdoClassicUpdatePlanGeneration -Kind Build -DefinitionId 900100 `
            -SpliceSpecPath $abEmptySplicePath -OperationId 'ab-missing' `
            -OutBodyPath (Join-Path $abTempDir 'missing-body.json') -OutPlanPath (Join-Path $abTempDir 'missing-plan.json') `
            -BuildName 'x' -ReleaseName 'y'
    }

    Add-MockWebSuccessResponseFromObjectAB -SourceObject (New-FakeBuildGetFixtureAA)
    Invoke-ExpectThrow -Name 'AB: Invoke-AdoClassicUpdatePlanGeneration rechaza si el GET devuelve un id distinto al pedido' `
        -ExpectedMessagePattern 'distinto de -DefinitionId' -Block {
        Invoke-AdoClassicUpdatePlanGeneration -Kind Build -DefinitionId 999999 `
            -SpliceSpecPath $abEmptySplicePath -OperationId 'ab-wrongid' `
            -OutBodyPath (Join-Path $abTempDir 'wrongid-body.json') -OutPlanPath (Join-Path $abTempDir 'wrongid-plan.json') `
            -BuildName 'x' -ReleaseName 'y' -ServiceConnectionAcrName 'z' -ArtifactFilterBranch 'release'
    }

    # ---- Camino feliz: esqueleto nuevo, Kind=Build, 1 splice real via fileContentPath ----

    $abNewContentPath = Join-Path $abTempDir 'emr-591-dev-NEW.yml'
    Set-Content -LiteralPath $abNewContentPath -Value 'CONTENIDO-NUEVO-DESDE-ARCHIVO' -Encoding utf8 -NoNewline

    $abHappySpliceSpecPath = Join-Path $abTempDir 'splices-happy.json'
    (@(
        [ordered]@{ function = 'Set-AdoFileCreatorContent'; displayName = 'File Creator deployment-dev.yml'; fileContentPath = $abNewContentPath; enabled = $true }
    ) | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $abHappySpliceSpecPath -Encoding utf8

    $abHappyBodyPath = Join-Path $abTempDir 'happy-build-body.json'
    $abHappyPlanPath = Join-Path $abTempDir 'happy-build-plan.json'

    Reset-MockWebRequest
    Add-MockWebSuccessResponseFromObjectAB -SourceObject (New-FakeBuildGetFixtureAA)
    $abHappyResult = $null
    Invoke-ExpectNoThrow -Name 'AB: Invoke-AdoClassicUpdatePlanGeneration -- camino feliz completo (esqueleto nuevo, Kind=Build)' -Block {
        $script:abHappyResult = Invoke-AdoClassicUpdatePlanGeneration -Kind Build -DefinitionId 900100 `
            -SpliceSpecPath $abHappySpliceSpecPath -OperationId 'ab-happy-build' `
            -OutBodyPath $abHappyBodyPath -OutPlanPath $abHappyPlanPath `
            -BuildName 'Build-AB-Happy' -ReleaseName 'Deploy-AB-Happy' `
            -ServiceConnectionAcrName 'ACR AB Test' -ArtifactFilterBranch 'release'
    }
    Add-Result -Name 'AB: camino feliz -- exactamente 1 llamada HTTP (el GET, ninguna escritura real)' `
        -Pass ($script:mockWebCallCount -eq 1) -Detail "mockWebCallCount=$($script:mockWebCallCount)"
    Add-Result -Name 'AB: camino feliz -- resultado reporta operationType/paths correctos' `
        -Pass ($script:abHappyResult.OperationType -eq 'update-build-definition' -and $script:abHappyResult.BodyPath -eq $abHappyBodyPath -and $script:abHappyResult.PlanPath -eq $abHappyPlanPath -and (@($script:abHappyResult.AppliedFunctionNames) -join ',') -eq 'Set-AdoFileCreatorContent') `
        -Detail ($script:abHappyResult | ConvertTo-Json -Compress)

    $abHappyBodyOnDisk = Get-Content -LiteralPath $abHappyBodyPath -Raw | ConvertFrom-Json
    Add-Result -Name 'AB: camino feliz -- el body escrito a disco tiene el splice aplicado' `
        -Pass ($abHappyBodyOnDisk.process.phases[0].steps[0].inputs.filecontent -eq 'CONTENIDO-NUEVO-DESDE-ARCHIVO') -Detail 'OK'
    Add-Result -Name 'AB: camino feliz -- el body escrito a disco NUNCA trae los campos de solo-GET' `
        -Pass (-not $abHappyBodyOnDisk.PSObject.Properties['_links'] -and -not $abHappyBodyOnDisk.PSObject.Properties['authoredBy']) -Detail 'OK'

    $abHappyPlanOnDisk = Get-Content -LiteralPath $abHappyPlanPath -Raw | ConvertFrom-Json
    Add-Result -Name 'AB: camino feliz -- el plan escrito tiene family=aks, validated=false, y 1 sola approvedOperations' `
        -Pass ($abHappyPlanOnDisk.family -eq 'aks' -and $abHappyPlanOnDisk.validated -eq $false -and @($abHappyPlanOnDisk.approvedOperations).Count -eq 1 -and $abHappyPlanOnDisk.approvedOperations[0].operationType -eq 'update-build-definition') -Detail 'OK'
    Add-Result -Name 'AB: camino feliz -- el plan NUNCA trae ninguna operationType create-* (nunca crea nada nuevo)' `
        -Pass (@($abHappyPlanOnDisk.approvedOperations | Where-Object { [string]$_.operationType -like 'create-*' }).Count -eq 0) -Detail 'OK'
    Add-Result -Name 'AB: camino feliz -- bodyHash aprobado coincide EXACTO con el hash real del body escrito a disco' `
        -Pass ($abHappyPlanOnDisk.approvedOperations[0].bodyHash -eq (Get-AdoBodyCanonicalHash -Body $abHappyBodyOnDisk)) -Detail 'OK'
    Add-Result -Name 'AB: camino feliz -- dependencies.buildTaskGroup/deployTaskGroup usan los defaults reales de la org' `
        -Pass ($abHappyPlanOnDisk.dependencies.buildTaskGroup.name -eq 'Build-MultiStage' -and $abHappyPlanOnDisk.dependencies.deployTaskGroup.name -eq 'Deployment-Azur-Aks-v3') -Detail 'OK'

    # ---- 'contentPath' (alias de 'fileContentPath') tambien funciona ----

    $abAliasSplicePath = Join-Path $abTempDir 'splices-alias.json'
    (@(
        [ordered]@{ function = 'Set-AdoFileCreatorContent'; displayName = 'File Creator deployment-dev.yml'; contentPath = $abNewContentPath }
    ) | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $abAliasSplicePath -Encoding utf8
    Add-MockWebSuccessResponseFromObjectAB -SourceObject (New-FakeBuildGetFixtureAA)
    Invoke-ExpectNoThrow -Name "AB: 'contentPath' funciona como alias de 'fileContentPath'" -Block {
        Invoke-AdoClassicUpdatePlanGeneration -Kind Build -DefinitionId 900100 `
            -SpliceSpecPath $abAliasSplicePath -OperationId 'ab-alias' `
            -OutBodyPath (Join-Path $abTempDir 'alias-body.json') -OutPlanPath (Join-Path $abTempDir 'alias-plan.json') `
            -BuildName 'x' -ReleaseName 'y' -ServiceConnectionAcrName 'z' -ArtifactFilterBranch 'release'
    }

    # ---- Modo 2 (merge sobre -ExistingPlanPath) + rechazo de operationType duplicado ----

    $abBasePlanObj = [PSCustomObject]@{
        family = 'aks'; organization = 'Shared-Service-GM'; project = 'DevOps'; validated = $true; validationHash = 'stale-no-importa'
        names  = [PSCustomObject]@{ build = 'Build-AB-Merge'; release = 'Deploy-AB-Merge' }
        approvedOperations = @()
    }
    $abBasePlanPath = Join-Path $abTempDir 'base-plan-for-merge.json'
    $abBasePlanObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $abBasePlanPath -Encoding utf8

    $abMergedPlanPath = Join-Path $abTempDir 'merged-plan.json'
    Add-MockWebSuccessResponseFromObjectAB -SourceObject (New-FakeReleaseGetFixtureAA)
    Invoke-ExpectNoThrow -Name 'AB: modo merge -- agrega la operacion sobre un plan ya existente' -Block {
        Invoke-AdoClassicUpdatePlanGeneration -Kind Release -DefinitionId 900200 `
            -SpliceSpecPath $abEmptySplicePath -OperationId 'ab-merge-release' `
            -OutBodyPath (Join-Path $abTempDir 'merge-body.json') -OutPlanPath $abMergedPlanPath `
            -ExistingPlanPath $abBasePlanPath
    }
    $abMergedPlanOnDisk = Get-Content -LiteralPath $abMergedPlanPath -Raw | ConvertFrom-Json
    Add-Result -Name 'AB: modo merge -- preserva names.build/release del plan original y agrega la operacion' `
        -Pass ($abMergedPlanOnDisk.names.build -eq 'Build-AB-Merge' -and @($abMergedPlanOnDisk.approvedOperations).Count -eq 1 -and $abMergedPlanOnDisk.approvedOperations[0].operationType -eq 'update-release-definition') -Detail 'OK'
    Add-Result -Name 'AB: modo merge -- fuerza validated=false y limpia validationHash aunque el plan de origen ya estuviera validado' `
        -Pass ($abMergedPlanOnDisk.validated -eq $false -and $null -eq $abMergedPlanOnDisk.validationHash) -Detail 'OK'

    Add-MockWebSuccessResponseFromObjectAB -SourceObject (New-FakeReleaseGetFixtureAA)
    Invoke-ExpectThrow -Name 'AB: modo merge -- rechaza agregar 2 operaciones del mismo operationType sobre el plan ya mergeado' `
        -ExpectedMessagePattern 'ya tiene una operacion de tipo' -Block {
        Invoke-AdoClassicUpdatePlanGeneration -Kind Release -DefinitionId 900200 `
            -SpliceSpecPath $abEmptySplicePath -OperationId 'ab-merge-release-2' `
            -OutBodyPath (Join-Path $abTempDir 'merge-body-2.json') -OutPlanPath (Join-Path $abTempDir 'merge-plan-2.json') `
            -ExistingPlanPath $abMergedPlanPath
    }

    # ---- E2E real: el body+approvedOperations que arma este runner es
    # aceptado sin cambios por Invoke-AdoApplyPhases (Fase 4, PUT) --
    # confirma que Apply-AdoClassicPlan.ps1 puede consumir la salida de
    # este runner tal cual, sin ningun ajuste manual. ----

    $abE2ePlanObj = [PSCustomObject]@{
        family = 'aks'; organization = 'Shared-Service-GM'; project = 'DevOps'
        names  = [PSCustomObject]@{ build = 'Build-AB-E2E'; release = 'Deploy-AB-E2E' }
        approvedOperations = @($script:abHappyResult.ApprovedOperation); validated = $true; validationHash = $null
    }
    $abE2ePlanObj.validationHash = Get-AdoPlanCanonicalHash -Plan $abE2ePlanObj
    $abE2ePlanPath = Join-Path $abTempDir 'e2e-plan.json'
    $abE2ePlanObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $abE2ePlanPath -Encoding utf8
    $abE2ePlanFromDisk = Get-Content -LiteralPath $abE2ePlanPath -Raw | ConvertFrom-Json

    Reset-MockWebRequest
    Add-MockWebSuccessResponse -ResultId '900100'
    $abE2eCreated = [System.Collections.Generic.List[string]]::new()
    Invoke-ExpectNoThrow -Name 'AB-E2E: el body armado por New-AdoClassicUpdatePlan.ps1 es aceptado sin cambios por Invoke-AdoApplyPhases (Fase 4, PUT)' -Block {
        Invoke-AdoApplyPhases -Plan $abE2ePlanFromDisk -PlanPath $abE2ePlanPath -CreatedSoFar $abE2eCreated -UpdateBuildBodyPath $abHappyBodyPath
    }
    Add-Result -Name 'AB-E2E: exactamente 1 llamada HTTP (PUT)' -Pass ($script:mockWebCallCount -eq 1) -Detail "mockWebCallCount=$($script:mockWebCallCount)"

    # ---- Integracion real con Test-AdoClassicPlan.ps1 (proceso hijo, sin
    # red): confirma que el plan que este runner escribe es reconocido
    # como un plan solo-actualizacion valido (sin bloqueantes estructurales
    # -- family/names/dependencies -- solo bloqueantes de NOT_VERIFIED por
    # falta de -InventoryPath, que es el resultado esperado sin inventario). ----

    $abValidateResult = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -ScriptArgs @('-PlanPath', $abHappyPlanPath)
    Add-Result -Name 'AB: Test-AdoClassicPlan.ps1 reconoce el plan del runner (dependencies.buildTaskGroup fluyo correctamente)' `
        -Pass ($abValidateResult.TextFlat -match "NOT_VERIFIED: task group 'Build-MultiStage'") -Detail $abValidateResult.TextFlat
    Add-Result -Name 'AB: Test-AdoClassicPlan.ps1 NO reporta bloqueante estructural de family/names sobre el plan del runner' `
        -Pass ($abValidateResult.TextFlat -notmatch "family debe ser" -and $abValidateResult.TextFlat -notmatch "Faltan nombres de build/release") -Detail $abValidateResult.TextFlat

    # ---- Grupo AC: runner versionado de create-* (sin red). ----
    $acInputPlanPath = Join-Path $testTempRoot 'ac-create-input.json'
    $acOutPlanPath = Join-Path $testTempRoot 'ac-create-output.json'
    $acInputPlan = [ordered]@{
        family = 'aks'; organization = 'Shared-Service-GM'; project = 'DevOps'
        variableGroup = [ordered]@{
            name = 'Desarrollo-AC-Test'
            keys = [ordered]@{ ambiente = 'dev'; namespace = 'desarrollo' }
        }
        approvedOperations = @()
        validated = $true
        validationHash = 'stale-before-create'
        validationEvidence = [ordered]@{ inventoryHash = 'stale' }
    }
    [IO.File]::WriteAllText($acInputPlanPath, ($acInputPlan | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    $acResult = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'New-AdoClassicCreatePlan.ps1') -ScriptArgs @(
        '-Kind', 'VariableGroup', '-InputPlanPath', $acInputPlanPath,
        '-OutPlanPath', $acOutPlanPath, '-OperationId', 'create-vg-ac-test'
    )
    Add-Result -Name 'AC: New-AdoClassicCreatePlan.ps1 VariableGroup termina sin error y sin red' `
        -Pass ($acResult.ExitCode -eq 0 -and (Test-Path -LiteralPath $acOutPlanPath)) -Detail $acResult.TextFlat
    $acOutputPlan = Get-Content -LiteralPath $acOutPlanPath -Raw | ConvertFrom-Json
    Add-Result -Name 'AC: agrega exactamente create-variable-group con POST/URI/bodyHash derivados' `
        -Pass (@($acOutputPlan.approvedOperations).Count -eq 1 -and $acOutputPlan.approvedOperations[0].operationType -eq 'create-variable-group' -and $acOutputPlan.approvedOperations[0].method -eq 'POST' -and $acOutputPlan.approvedOperations[0].uri -match '/distributedtask/variablegroups\?') `
        -Detail ($acOutputPlan.approvedOperations | ConvertTo-Json -Compress)
    Add-Result -Name 'AC: invalida validationHash/evidence para exigir Test-AdoClassicPlan posterior' `
        -Pass ($acOutputPlan.validated -eq $false -and $null -eq $acOutputPlan.validationHash -and $null -eq $acOutputPlan.validationEvidence) `
        -Detail "validated=$($acOutputPlan.validated)"
    $acInputAfter = Get-Content -LiteralPath $acInputPlanPath -Raw | ConvertFrom-Json
    Add-Result -Name 'AC: nunca modifica el plan de origen' `
        -Pass ($acInputAfter.validated -eq $true -and @($acInputAfter.approvedOperations).Count -eq 0) -Detail $acInputPlanPath

    $acSamePathResult = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'New-AdoClassicCreatePlan.ps1') -ScriptArgs @(
        '-Kind', 'VariableGroup', '-InputPlanPath', $acInputPlanPath,
        '-OutPlanPath', $acInputPlanPath, '-OperationId', 'create-vg-ac-test-2'
    )
    Add-Result -Name 'AC: rechaza sobrescribir el plan de origen' `
        -Pass ($acSamePathResult.ExitCode -ne 0 -and $acSamePathResult.TextFlat -match 'deben ser distintos') -Detail $acSamePathResult.TextFlat

    $acReleaseResult = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'New-AdoClassicCreatePlan.ps1') -ScriptArgs @(
        '-Kind', 'Release', '-InputPlanPath', $acInputPlanPath,
        '-OutPlanPath', (Join-Path $testTempRoot 'ac-release-output.json'), '-OperationId', 'create-release-ac-test'
    )
    Add-Result -Name 'AC: Release sin Build id real se rechaza; nunca inventa dependencias futuras' `
        -Pass ($acReleaseResult.ExitCode -ne 0 -and $acReleaseResult.TextFlat -match 'ExistingBuildDefinitionId') -Detail $acReleaseResult.TextFlat

    # AC (regresion, bug real encontrado 2026-08-27 armando el Grupo SC):
    # Kind=Release con 2+ environments -- antes de este fix, $rawEnvironments
    # quedaba como un array ANIDADO de 1 elemento (nunca detectado porque
    # todas las pruebas previas de este Kind usaban 1 solo environment), y
    # el body armado terminaba corrupto (1 "environment" con propiedades
    # auto-enumeradas en array) en vez de reflejar los 2 stages reales.
    $acRelMultiEnvPlan = [ordered]@{
        family = 'aks'; organization = 'Shared-Service-GM'; project = 'DevOps'
        names  = [ordered]@{ build = 'Build-AC-MultiEnv'; release = 'Deploy-AC-MultiEnv'; folder = '\\' }
        approvedOperations = @()
        validated = $true
        validationHash = 'stale-before-create'
    }
    $acRelMultiEnvPlanPath = Join-Path $testTempRoot 'ac-release-multienv-input.json'
    [IO.File]::WriteAllText($acRelMultiEnvPlanPath, ($acRelMultiEnvPlan | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))

    $acRelEnvironments = @(
        (New-AdoReleaseEnvironmentEntry -Stage 'Desarrollo' -VariableGroupId 90301 -ArtifactFilterBranch 'development' -DeployTaskGroupName 'Deployment-MultiStage-Cluster-Desarrollo' -DeployTaskGroupId 'tg-deploy-multienv' -Ambiente 'dev' -ContainerRegistries 'ACR-Example' -Image 'ac-multienv-' -Namespace 'desarrollo' -Pipeline 'Build-AC-MultiEnv' -ServicesName 'ac-multienv'),
        (New-AdoReleaseEnvironmentEntry -Stage 'UAT' -VariableGroupId 90302 -ArtifactFilterBranch 'uat' -DeployTaskGroupName 'Deployment-MultiStage-Cluster-Desarrollo' -DeployTaskGroupId 'tg-deploy-multienv' -Ambiente 'uat' -ContainerRegistries 'ACR-Example' -Image 'ac-multienv-' -Namespace 'uat' -Pipeline 'Build-AC-MultiEnv' -ServicesName 'ac-multienv')
    )
    $acRelEnvironmentsPath = Join-Path $testTempRoot 'ac-release-multienv-environments.json'
    $acRelEnvironments | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $acRelEnvironmentsPath -Encoding utf8

    $acRelMultiEnvOutPath = Join-Path $testTempRoot 'ac-release-multienv-output.json'
    $acRelMultiEnvResult = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'New-AdoClassicCreatePlan.ps1') -ScriptArgs @(
        '-Kind', 'Release', '-InputPlanPath', $acRelMultiEnvPlanPath, '-OutPlanPath', $acRelMultiEnvOutPath, '-OperationId', 'create-release-multienv-test',
        '-ReleaseEnvironmentsPath', $acRelEnvironmentsPath, '-ExistingBuildDefinitionId', '900555', '-BuildDefinitionName', 'Build-AC-MultiEnv'
    )
    Add-Result -Name 'AC (regresion bug real 2026-08-27): Kind=Release con 2 environments termina sin error' `
        -Pass ($acRelMultiEnvResult.ExitCode -eq 0 -and (Test-Path -LiteralPath $acRelMultiEnvOutPath)) -Detail $acRelMultiEnvResult.TextFlat

    if (Test-Path -LiteralPath $acRelMultiEnvOutPath) {
        $acRelMultiEnvOutputPlan = Get-Content -LiteralPath $acRelMultiEnvOutPath -Raw | ConvertFrom-Json
        # Reconstruye el body ESPERADO en este mismo proceso (misma
        # funcion, mismos 2 environments) y confirma que el bodyHash
        # coincide EXACTO -- si el bug de array anidado siguiera presente,
        # el runner habria armado el body con 1 environment corrupto y
        # este hash NO coincidiria.
        $acRelExpectedBody = New-AdoReleaseDefinitionPayload -Plan $acRelMultiEnvPlan -Environments $acRelEnvironments -BuildDefinitionId 900555 -BuildDefinitionName 'Build-AC-MultiEnv'
        $acRelExpectedHash = Get-AdoBodyCanonicalHash -Body $acRelExpectedBody
        Add-Result -Name 'AC (regresion bug real 2026-08-27): bodyHash de Kind=Release con 2 environments coincide EXACTO con el body real de 2 environments (nunca el array anidado/corrupto de 1)' `
            -Pass ($acRelMultiEnvOutputPlan.approvedOperations[0].bodyHash -eq $acRelExpectedHash) `
            -Detail "esperado=$acRelExpectedHash; obtenido=$($acRelMultiEnvOutputPlan.approvedOperations[0].bodyHash)"
    }

    # M10: el journal NUNCA contiene el body de la solicitud, el PAT, ni un header Authorization
    $journalM1RawText = Get-Content -LiteralPath $journalPathM -Raw
    $noBodyFields = ($journalM1RawText -notmatch 'Produccion-Simulado-E2E') -and ($journalM1RawText -notmatch 'Build-Simulado-E2E') -and ($journalM1RawText -notmatch 'Release-Simulado-E2E')
    $noPatOrAuth = ($journalM1RawText -notmatch 'FICTICIO-NUNCA-REAL-TEST') -and ($journalM1RawText -notmatch '(?i)authorization') -and ($journalM1RawText -notmatch '(?i)basic\s')
    Add-Result -Name 'Journal: el archivo NUNCA contiene el body de la solicitud (nombres de VG/Build/Release)' `
        -Pass $noBodyFields -Detail 'Verificacion de texto crudo del journal.'
    Add-Result -Name 'Journal: el archivo NUNCA contiene el PAT ni un header Authorization' `
        -Pass $noPatOrAuth -Detail 'Verificacion de texto crudo del journal.'

    # M11: sin ADO_TEST_EXECUTIONS_ROOT, Get-AdoExecutionsDir devuelve la
    # ruta FIJA de produccion -- ningun llamador de produccion puede
    # cambiarla (item 3 del Paso 1: "un llamador de produccion no debe
    # poder cambiar ProjectRoot para obtener un journal nuevo").
    $savedTestRoot = $env:ADO_TEST_EXECUTIONS_ROOT
    Remove-Item Env:\ADO_TEST_EXECUTIONS_ROOT -ErrorAction SilentlyContinue
    Add-Result -Name 'Journal: sin ADO_TEST_EXECUTIONS_ROOT, Get-AdoExecutionsDir devuelve la ruta fija de produccion' `
        -Pass ((Get-AdoExecutionsDir) -eq $script:AdoProductionExecutionsDir) `
        -Detail "Get-AdoExecutionsDir()='$(Get-AdoExecutionsDir)' vs produccion='$($script:AdoProductionExecutionsDir)'"
    Add-Result -Name 'Journal: Get-AdoExecutionJournalPath ya no acepta -ProjectRoot (parametro eliminado)' `
        -Pass ((Get-Command Get-AdoExecutionJournalPath).Parameters.Keys -notcontains 'ProjectRoot') `
        -Detail "parametros: $((Get-Command Get-AdoExecutionJournalPath).Parameters.Keys -join ', ')"
    Add-Result -Name 'Journal: Invoke-AdoRest ya no acepta -ProjectRoot (parametro eliminado)' `
        -Pass ((Get-Command Invoke-AdoRest).Parameters.Keys -notcontains 'ProjectRoot') `
        -Detail "parametros: $((Get-Command Invoke-AdoRest).Parameters.Keys -join ', ')"
    $env:ADO_TEST_EXECUTIONS_ROOT = $savedTestRoot

    # ============================================================
    # Grupo SB: capacidad nueva 2026-08-27 -- Build clasico STANDALONE
    # (sin AKS/DACPAC, sin Release, sin Variable Group). Ver memoria de
    # agente ado-pipeline-builder, "Gap real de capacidad", y
    # New-AdoStandaloneBuildDefinitionPayload / New-AdoPowerShellTaskStep
    # en New-AdoClassicPayloads.ps1.
    # ============================================================

    Invoke-ExpectThrow -Name 'SB: New-AdoPowerShellTaskStep inline sin -Script -> rechazado' `
        -ExpectedMessagePattern "exige -Script no vacio" -Block {
        New-AdoPowerShellTaskStep -DisplayName 'x' -TargetType 'inline'
    }
    Invoke-ExpectThrow -Name 'SB: New-AdoPowerShellTaskStep filePath sin -FilePath -> rechazado' `
        -ExpectedMessagePattern "exige -FilePath no vacio" -Block {
        New-AdoPowerShellTaskStep -DisplayName 'x' -TargetType 'filePath'
    }

    $sbInlineStep = New-AdoPowerShellTaskStep -DisplayName 'Publicar shouldWait' -TargetType 'inline' -Script 'Write-Host hola'
    Add-Result -Name 'SB: New-AdoPowerShellTaskStep task.id/versionSpec/definitionType fijos (contrato PowerShell@2 confirmado contra Build 584 real)' `
        -Pass ($sbInlineStep.task.id -eq 'e213ff0f-5d5c-4791-802d-52ea3e7be1f1' -and $sbInlineStep.task.versionSpec -eq '2.*' -and $sbInlineStep.task.definitionType -eq 'task') `
        -Detail ($sbInlineStep.task | ConvertTo-Json -Compress)
    Add-Result -Name 'SB: New-AdoPowerShellTaskStep (inline) targetType=inline, filePath vacio, script poblado' `
        -Pass ($sbInlineStep.inputs.targetType -eq 'inline' -and $sbInlineStep.inputs.filePath -eq '' -and $sbInlineStep.inputs.script -eq 'Write-Host hola') `
        -Detail ($sbInlineStep.inputs | ConvertTo-Json -Compress)
    Add-Result -Name 'SB: New-AdoPowerShellTaskStep defaults (errorActionPreference=stop, ignoreLASTEXITCODE=false, pwsh=false, todos como string)' `
        -Pass ($sbInlineStep.inputs.errorActionPreference -eq 'stop' -and $sbInlineStep.inputs.ignoreLASTEXITCODE -eq 'false' -and $sbInlineStep.inputs.pwsh -eq 'false') `
        -Detail ($sbInlineStep.inputs | ConvertTo-Json -Compress)

    $sbFileStep = New-AdoPowerShellTaskStep -DisplayName 'Ejecutar detect-and-build.ps1' -TargetType 'filePath' -FilePath 'detect-and-build.ps1' -Pwsh $true
    Add-Result -Name 'SB: New-AdoPowerShellTaskStep (filePath) targetType=filePath, filePath poblado, script vacio' `
        -Pass ($sbFileStep.inputs.targetType -eq 'filePath' -and $sbFileStep.inputs.filePath -eq 'detect-and-build.ps1' -and $sbFileStep.inputs.script -eq '') `
        -Detail ($sbFileStep.inputs | ConvertTo-Json -Compress)
    Add-Result -Name 'SB: New-AdoPowerShellTaskStep -Pwsh $true serializa a string "true" (nunca booleano nativo en el body)' `
        -Pass ($sbFileStep.inputs.pwsh -eq 'true' -and $sbFileStep.inputs.pwsh -is [string]) `
        -Detail "pwsh=$($sbFileStep.inputs.pwsh) tipo=$($sbFileStep.inputs.pwsh.GetType().Name)"

    Invoke-ExpectThrow -Name 'SB: New-AdoStandaloneBuildDefinitionPayload -Steps vacio -> rechazado' `
        -ExpectedMessagePattern 'Steps no puede estar vacio' -Block {
        New-AdoStandaloneBuildDefinitionPayload -Project 'Buklo' -Name 'Build-Validation-x' -RepoId 'repo-1' -RepoName 'buklo-backend' -DefaultBranch 'development' -Steps @()
    }

    $sbFileCreatorStep = New-AdoFileCreatorStep -DisplayName 'File Creator detect-and-build.ps1' -FilePath 'detect-and-build.ps1' -FileContent "`$ErrorActionPreference = 'Stop'" -Enabled $true
    $sbBody = New-AdoStandaloneBuildDefinitionPayload -Project 'Buklo' -Name 'Build-Validation-buklo-backend' `
        -RepoId 'repo-guid-1' -RepoName 'buklo-backend' -DefaultBranch 'development' -Steps @($sbFileCreatorStep, $sbFileStep) -FetchDepth '0'

    Add-Result -Name 'SB: New-AdoStandaloneBuildDefinitionPayload respeta los steps provistos, tal cual, en orden (sin Docker/manifiestos K8s agregados)' `
        -Pass (@($sbBody.process.phases[0].steps).Count -eq 2 -and $sbBody.process.phases[0].steps[0].displayName -eq 'File Creator detect-and-build.ps1' -and $sbBody.process.phases[0].steps[1].displayName -eq 'Ejecutar detect-and-build.ps1') `
        -Detail (($sbBody.process.phases[0].steps | ForEach-Object { $_.displayName }) -join ' | ')
    Add-Result -Name 'SB: New-AdoStandaloneBuildDefinitionPayload sin -CiBranchFilters -> triggers vacio (sin trigger CI)' `
        -Pass (@($sbBody.triggers).Count -eq 0) -Detail "triggers.Count=$(@($sbBody.triggers).Count)"
    Add-Result -Name 'SB: New-AdoStandaloneBuildDefinitionPayload fetchDepth=0 se propaga a repository.properties.fetchDepth' `
        -Pass ($sbBody.repository.properties.fetchDepth -eq '0') -Detail "fetchDepth=$($sbBody.repository.properties.fetchDepth)"
    Add-Result -Name 'SB: New-AdoStandaloneBuildDefinitionPayload repository.defaultBranch = refs/heads/<DefaultBranch>' `
        -Pass ($sbBody.repository.defaultBranch -eq 'refs/heads/development') -Detail "defaultBranch=$($sbBody.repository.defaultBranch)"
    Add-Result -Name 'SB: New-AdoStandaloneBuildDefinitionPayload repository.url usa el proyecto REAL (Buklo, nunca DevOps hardcodeado)' `
        -Pass ($sbBody.repository.url -eq 'https://dev.azure.com/Shared-Service-GM/Buklo/_git/buklo-backend') -Detail "url=$($sbBody.repository.url)"
    Add-Result -Name 'SB: New-AdoStandaloneBuildDefinitionPayload sin -QueueId, queue omite la clave id (nunca asume el id de otro proyecto)' `
        -Pass (-not $sbBody.queue.PSObject.Properties.Name.Contains('id') -and $sbBody.queue.pool.id -eq 9 -and $sbBody.queue.pool.name -eq 'Azure Pipelines') `
        -Detail ($sbBody.queue | ConvertTo-Json -Compress)
    Add-Result -Name 'SB: New-AdoStandaloneBuildDefinitionPayload agentSpecification.identifier default confirmado (referencia real: ''ubuntu latest'', con espacio)' `
        -Pass ($sbBody.process.target.agentSpecification.identifier -eq 'ubuntu latest') -Detail "identifier=$($sbBody.process.target.agentSpecification.identifier)"
    Add-Result -Name 'SB: New-AdoStandaloneBuildDefinitionPayload payload minimo: exactamente 1 phase (sin fases de agrupacion de merges)' `
        -Pass (@($sbBody.process.phases).Count -eq 1) -Detail "phases.Count=$(@($sbBody.process.phases).Count)"

    $sbBodyWithCi = New-AdoStandaloneBuildDefinitionPayload -Project 'Buklo' -Name 'Build-Validation-buklo-backend-ci' `
        -RepoId 'repo-guid-1' -RepoName 'buklo-backend' -DefaultBranch 'development' -Steps @($sbFileStep) -CiBranchFilters @('development')
    Add-Result -Name 'SB: New-AdoStandaloneBuildDefinitionPayload -CiBranchFilters puebla un trigger continuousIntegration (opcional, no default)' `
        -Pass (@($sbBodyWithCi.triggers).Count -eq 1 -and $sbBodyWithCi.triggers[0].triggerType -eq 'continuousIntegration' -and (@($sbBodyWithCi.triggers[0].branchFilters) -contains '+refs/heads/development')) `
        -Detail ($sbBodyWithCi.triggers | ConvertTo-Json -Compress -Depth 5)

    $sbBodyWithQueueId = New-AdoStandaloneBuildDefinitionPayload -Project 'DevOps' -Name 'Build-Validation-x2' -RepoId 'r2' -RepoName 'repo2' -DefaultBranch 'main' -Steps @($sbFileStep) -QueueId 127
    Add-Result -Name 'SB: New-AdoStandaloneBuildDefinitionPayload -QueueId explicito se usa tal cual (nunca reinventado)' `
        -Pass ($sbBodyWithQueueId.queue.id -eq 127) -Detail "queue.id=$($sbBodyWithQueueId.queue.id)"

    # ---- Grupo SC: New-AdoClassicStandaloneBuildPlan.ps1 + New-AdoClassicCreatePlan.ps1 -Kind StandaloneBuild (procesos hijo, sin red) ----

    $scPlanPath = Join-Path $testTempRoot 'sc-standalone-plan-input.json'
    & powershell -NoProfile -File (Join-Path $scriptsRoot 'New-AdoClassicStandaloneBuildPlan.ps1') `
        -Project 'Buklo' -BuildName 'Build-Validation-buklo-backend' -RepoName 'buklo-backend' -DefaultBranch 'development' -OutDir $testTempRoot | Out-Null
    $scGenerated = Get-ChildItem $testTempRoot -Filter 'standalone-build-buklo-*.json' | Select-Object -Last 1
    if ($scGenerated) { Copy-Item $scGenerated.FullName $scPlanPath -Force }

    if (Test-Path -LiteralPath $scPlanPath) {
        $scPlanObj = Get-Content -LiteralPath $scPlanPath -Raw | ConvertFrom-Json
        Add-Result -Name 'SC: New-AdoClassicStandaloneBuildPlan.ps1 genera family=standalone-build, sin release/variableGroup' `
            -Pass ($scPlanObj.family -eq 'standalone-build' -and $scPlanObj.project -eq 'Buklo' -and $scPlanObj.repo.name -eq 'buklo-backend' -and $scPlanObj.repo.prodBranch -eq 'development' -and -not $scPlanObj.PSObject.Properties.Name.Contains('release')) `
            -Detail ($scPlanObj | ConvertTo-Json -Compress -Depth 5)

        # fileContentPath (en vez de fileContent inline) -- evita escapar a
        # mano un script multilinea con comillas dentro de JSON. Se prueba
        # este modo, no el inline, porque es el que usa el caso real
        # (Build-Validation-buklo-backend).
        $scFileContentPath = Join-Path $testTempRoot 'sc-detect-and-build.ps1'
        $scFileContentLines = @(
            '$ErrorActionPreference = ''Stop''',
            'Write-Host "hola con comillas"',
            'exit 0'
        )
        Set-Content -LiteralPath $scFileContentPath -Value $scFileContentLines -Encoding utf8
        $scStepsSpecPath = Join-Path $testTempRoot 'sc-steps-spec.json'
        $scStepsSpec = @(
            [ordered]@{ kind = 'FileCreator'; displayName = 'File Creator detect-and-build.ps1'; filePath = 'detect-and-build.ps1'; fileContentPath = $scFileContentPath; enabled = $true },
            [ordered]@{ kind = 'PowerShellTask'; displayName = 'Ejecutar detect-and-build.ps1'; targetType = 'filePath'; filePath = 'detect-and-build.ps1'; pwsh = $true; errorActionPreference = 'stop'; ignoreLASTEXITCODE = $false }
        )
        [IO.File]::WriteAllText($scStepsSpecPath, ($scStepsSpec | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))

        # Regresion del bug real encontrado 2026-08-27 (ver comentario en
        # New-AdoClassicCreatePlan.ps1 junto a $stepsSpecParsed): confirma
        # que un archivo de 2 steps se parsea como array PLANO de 2, no
        # anidado de 1 -- prueba directa de la MISMA expresion que usa el
        # script real, para que un futuro cambio que reintroduzca @(...)
        # alrededor del pipeline completo lo vuelva a romper en rojo aca.
        $scStepsSpecParsedCheck = Get-Content -LiteralPath $scStepsSpecPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $scStepsSpecFlatCheck = @($scStepsSpecParsedCheck)
        Add-Result -Name 'SC (regresion): -StepsSpecPath de 2 entradas se parsea como array PLANO de 2 (nunca anidado de 1)' `
            -Pass ($scStepsSpecFlatCheck.Count -eq 2 -and [string]$scStepsSpecFlatCheck[0].kind -eq 'FileCreator' -and [string]$scStepsSpecFlatCheck[1].kind -eq 'PowerShellTask') `
            -Detail "Count=$($scStepsSpecFlatCheck.Count); kinds=$((@($scStepsSpecFlatCheck | ForEach-Object { $_.kind })) -join '|')"

        # SC-mismatch: sin plan.repo.id resuelto (Test-AdoClassicPlan.ps1 no
        # corrio todavia) -> rechazado, nunca arma el body igual.
        $scOutMissingRepoId = Join-Path $testTempRoot 'sc-output-missing-repoid.json'
        $scResultMissingRepoId = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'New-AdoClassicCreatePlan.ps1') -ScriptArgs @(
            '-Kind', 'StandaloneBuild', '-InputPlanPath', $scPlanPath, '-OutPlanPath', $scOutMissingRepoId, '-OperationId', 'create-build-sb-1',
            '-StepsSpecPath', $scStepsSpecPath
        )
        Add-Result -Name 'SC: Kind=StandaloneBuild sin plan.repo.id resuelto -> rechazado (nunca inventa el id del repo)' `
            -Pass ($scResultMissingRepoId.ExitCode -ne 0 -and $scResultMissingRepoId.TextFlat -match 'plan\.repo\.id/name/prodBranch ya resueltos') -Detail $scResultMissingRepoId.TextFlat

        # Simula el repo.id ya resuelto por Test-AdoClassicPlan.ps1 (id
        # confirmado contra inventario real: repo 'buklo-backend').
        $scPlanObj.repo | Add-Member -NotePropertyName 'id' -NotePropertyValue '0550ab98-7959-45ee-8361-18b8e4df22a3' -Force
        $scPlanResolvedPath = Join-Path $testTempRoot 'sc-standalone-plan-resolved.json'
        [IO.File]::WriteAllText($scPlanResolvedPath, ($scPlanObj | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))

        $scOutPath = Join-Path $testTempRoot 'sc-output.json'
        $scResult = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'New-AdoClassicCreatePlan.ps1') -ScriptArgs @(
            '-Kind', 'StandaloneBuild', '-InputPlanPath', $scPlanResolvedPath, '-OutPlanPath', $scOutPath, '-OperationId', 'create-build-sb-2',
            '-StepsSpecPath', $scStepsSpecPath
        )
        Add-Result -Name 'SC: Kind=StandaloneBuild (con repo.id resuelto) termina sin error y sin red' `
            -Pass ($scResult.ExitCode -eq 0 -and (Test-Path -LiteralPath $scOutPath)) -Detail $scResult.TextFlat
        if (Test-Path -LiteralPath $scOutPath) {
            $scOutputPlan = Get-Content -LiteralPath $scOutPath -Raw | ConvertFrom-Json
            Add-Result -Name 'SC: agrega exactamente create-build-definition (MISMO operationType que Kind=Build, sin tipo nuevo en el allowlist)' `
                -Pass (@($scOutputPlan.approvedOperations).Count -eq 1 -and $scOutputPlan.approvedOperations[0].operationType -eq 'create-build-definition' -and $scOutputPlan.approvedOperations[0].method -eq 'POST' -and $scOutputPlan.approvedOperations[0].uri -match '/Buklo/_apis/build/definitions\?') `
                -Detail ($scOutputPlan.approvedOperations | ConvertTo-Json -Compress)

            # fileContentPath: el bodyHash real debe coincidir EXACTO con
            # un body armado a mano leyendo el MISMO archivo (comillas
            # incluidas) -- confirma que se leyo tal cual, sin re-escapar
            # ni truncar.
            $scFileStepExpected = New-AdoFileCreatorStep -DisplayName 'File Creator detect-and-build.ps1' -FilePath 'detect-and-build.ps1' -FileContent (Get-Content -LiteralPath $scFileContentPath -Raw -Encoding UTF8) -Enabled $true
            $scPsStepExpected = New-AdoPowerShellTaskStep -DisplayName 'Ejecutar detect-and-build.ps1' -TargetType 'filePath' -FilePath 'detect-and-build.ps1' -Pwsh $true -ErrorActionPreference 'stop' -IgnoreLASTEXITCODE $false
            $scExpectedBody = New-AdoStandaloneBuildDefinitionPayload -Project 'Buklo' -Name 'Build-Validation-buklo-backend' `
                -RepoId '0550ab98-7959-45ee-8361-18b8e4df22a3' -RepoName 'buklo-backend' -DefaultBranch 'development' -Steps @($scFileStepExpected, $scPsStepExpected)
            $scExpectedHash = Get-AdoBodyCanonicalHash -Body $scExpectedBody
            Add-Result -Name 'SC: bodyHash coincide EXACTO con fileContentPath leido tal cual (comillas incluidas, sin re-escapar)' `
                -Pass ($scOutputPlan.approvedOperations[0].bodyHash -eq $scExpectedHash) `
                -Detail "esperado=$scExpectedHash; obtenido=$($scOutputPlan.approvedOperations[0].bodyHash)"
        }

        # SC-badkind: kind desconocido en el spec de steps -> rechazado.
        $scStepsSpecBadPath = Join-Path $testTempRoot 'sc-steps-spec-bad.json'
        [IO.File]::WriteAllText($scStepsSpecBadPath, (@([ordered]@{ kind = 'Bogus'; displayName = 'x' }) | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
        $scResultBadKind = Invoke-ChildScript -ScriptPath (Join-Path $scriptsRoot 'New-AdoClassicCreatePlan.ps1') -ScriptArgs @(
            '-Kind', 'StandaloneBuild', '-InputPlanPath', $scPlanResolvedPath, '-OutPlanPath', (Join-Path $testTempRoot 'sc-output-badkind.json'), '-OperationId', 'create-build-sb-3',
            '-StepsSpecPath', $scStepsSpecBadPath
        )
        Add-Result -Name 'SC: kind desconocido en -StepsSpecPath -> rechazado, nunca lo ignora en silencio' `
            -Pass ($scResultBadKind.ExitCode -ne 0 -and $scResultBadKind.TextFlat -match "kind='Bogus' desconocido") -Detail $scResultBadKind.TextFlat

        # ---- Integracion real con Test-AdoClassicPlan.ps1 (proceso hijo, sin red) ----

        # SD1: sin inventario -> NOT_VERIFIED/validated=false, pero SIN los
        # bloqueantes estructurales que existian antes de este cambio
        # (family invalida, falta names.release, falta release.cdTriggerEnabled).
        $sdPlanD1 = Join-Path $testTempRoot 'sd-plan-d1.json'
        Copy-Item $scPlanResolvedPath $sdPlanD1 -Force
        & powershell -NoProfile -File (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -PlanPath $sdPlanD1 | Out-Null
        $sdResultD1 = Get-Content -LiteralPath $sdPlanD1 -Raw | ConvertFrom-Json
        $sdD1BlockersFlat = (@($sdResultD1.validationBlockers) -join ' | ')
        Add-Result -Name 'SD: Test-AdoClassicPlan.ps1 reconoce family=standalone-build (sin bloqueante de family)' `
            -Pass ($sdD1BlockersFlat -notmatch "family debe ser") -Detail $sdD1BlockersFlat
        Add-Result -Name 'SD: Test-AdoClassicPlan.ps1 NO exige names.release para standalone-build' `
            -Pass ($sdD1BlockersFlat -notmatch "Faltan nombres de build/release") -Detail $sdD1BlockersFlat
        Add-Result -Name 'SD: Test-AdoClassicPlan.ps1 NO exige release.cdTriggerEnabled para standalone-build' `
            -Pass ($sdD1BlockersFlat -notmatch "cdTriggerEnabled") -Detail $sdD1BlockersFlat

        # SD2: inventario COMPLETO, fresco, del proyecto 'Buklo'. Actualizado
        # 2026-09-01: $script:AdoAllowedProjects (Invoke-AdoRest.ps1) paso de
        # ['DevOps'] a ['DevOps','Buklo'] -- cambio de seguridad aprobado
        # explicitamente por el usuario humano en el transcript de la sesion
        # principal (nunca via relay de un subagente, ver
        # .cursor/memories/ado-pipeline-builder/ado-emr-scratch-script-authorization-declined-2026-08-27.md
        # "Recurrencia 2026-09-01"), para poder crear
        # Build-Validation-buklo-backend en el proyecto Buklo. El plan de
        # arriba (project='Buklo') ahora SI debe poder validar limpio contra
        # un inventario Buklo completo -- ya no bloqueado por
        # 'plan.project debe ser...'.
        $sdInventory = [ordered]@{
            generatedAtUtc     = (Get-Date).ToUniversalTime().ToString('o')
            organization       = 'Shared-Service-GM'
            project            = 'Buklo'
            paginationComplete = $true
            projects           = @(@{ id = 'proj-buklo'; name = 'Buklo' }, @{ id = 'proj-devops'; name = 'DevOps' })
            buildDefinitions   = @()
            releaseDefinitions = @()
            variableGroups     = @()
            taskGroups         = @()
            serviceConnections = @()
            agentPools         = @(@{ id = 9; name = 'Azure Pipelines'; isHosted = $true })
            repositories       = @(@{ id = '0550ab98-7959-45ee-8361-18b8e4df22a3'; name = 'buklo-backend'; defaultBranch = 'development'; branches = @('development') })
        }
        $sdInventoryPath = Join-Path $testTempRoot 'sd-inventory-buklo.json'
        [PSCustomObject]$sdInventory | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $sdInventoryPath -Encoding utf8

        $sdPlanD2 = Join-Path $testTempRoot 'sd-plan-d2.json'
        Copy-Item $scPlanResolvedPath $sdPlanD2 -Force
        & powershell -NoProfile -File (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -PlanPath $sdPlanD2 -InventoryPath $sdInventoryPath | Out-Null
        $sdResultD2 = Get-Content -LiteralPath $sdPlanD2 -Raw | ConvertFrom-Json
        $sdD2BlockersFlat = (@($sdResultD2.validationBlockers) -join ' | ')
        Add-Result -Name 'SD2 (limite de seguridad ampliado 2026-09-01): plan.project=Buklo con inventario Buklo completo -> validated=true, validationHash calculado' `
            -Pass ($sdResultD2.validated -eq $true -and -not [string]::IsNullOrEmpty($sdResultD2.validationHash) -and $sdD2BlockersFlat -notmatch "plan\.project debe ser") `
            -Detail "validated=$($sdResultD2.validated); blockers=$sdD2BlockersFlat"

        # SD2b: un proyecto NO listado (ni DevOps ni Buklo) sigue bloqueado
        # -- ampliar la lista a Buklo no la convirtio en texto libre.
        $scPlanObjOtroProyecto = $scPlanObj | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $scPlanObjOtroProyecto.project = 'OtroProyectoNoPermitido'
        $sdPlanD2b = Join-Path $testTempRoot 'sd-plan-d2b.json'
        [IO.File]::WriteAllText($sdPlanD2b, ($scPlanObjOtroProyecto | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        & powershell -NoProfile -File (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -PlanPath $sdPlanD2b | Out-Null
        $sdResultD2b = Get-Content -LiteralPath $sdPlanD2b -Raw | ConvertFrom-Json
        $sdD2bBlockersFlat = (@($sdResultD2b.validationBlockers) -join ' | ')
        Add-Result -Name 'SD2b: plan.project fuera de la lista permitida (ni DevOps ni Buklo) sigue bloqueado' `
            -Pass ($sdResultD2b.validated -eq $false -and $sdD2bBlockersFlat -match "plan\.project debe ser uno de: DevOps, Buklo") `
            -Detail $sdD2bBlockersFlat

        # SD3: mismo plan/steps, pero project='DevOps' (dentro del limite
        # actual) con inventario COMPLETO y fresco de 'DevOps' -> valida
        # limpio (validated=true), demostrando que la capacidad en si
        # funciona de punta a punta para el unico proyecto hoy autorizado.
        $scPlanObjDevOps = $scPlanObj | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $scPlanObjDevOps.project = 'DevOps'
        $scPlanObjDevOps.approvedOperations = @()
        $sdPlanD3 = Join-Path $testTempRoot 'sd-plan-d3.json'
        [IO.File]::WriteAllText($sdPlanD3, ($scPlanObjDevOps | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))

        $sdInventoryDevOps = [ordered]@{
            generatedAtUtc     = (Get-Date).ToUniversalTime().ToString('o')
            organization       = 'Shared-Service-GM'
            project            = 'DevOps'
            paginationComplete = $true
            projects           = @(@{ id = 'proj-devops'; name = 'DevOps' })
            buildDefinitions   = @()
            releaseDefinitions = @()
            variableGroups     = @()
            taskGroups         = @()
            serviceConnections = @()
            agentPools         = @(@{ id = 9; name = 'Azure Pipelines'; isHosted = $true })
            repositories       = @(@{ id = '0550ab98-7959-45ee-8361-18b8e4df22a3'; name = 'buklo-backend'; defaultBranch = 'development'; branches = @('development') })
        }
        $sdInventoryDevOpsPath = Join-Path $testTempRoot 'sd-inventory-devops.json'
        [PSCustomObject]$sdInventoryDevOps | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $sdInventoryDevOpsPath -Encoding utf8

        & powershell -NoProfile -File (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -PlanPath $sdPlanD3 -InventoryPath $sdInventoryDevOpsPath | Out-Null
        $sdResultD3 = Get-Content -LiteralPath $sdPlanD3 -Raw | ConvertFrom-Json
        Add-Result -Name 'SD3: plan standalone-build en project=DevOps + inventario completo/fresco -> validated=true, validationHash calculado' `
            -Pass ($sdResultD3.validated -eq $true -and -not [string]::IsNullOrEmpty($sdResultD3.validationHash)) `
            -Detail "validated=$($sdResultD3.validated); blockers=$($sdResultD3.validationBlockers -join ' | ')"

        # ============================================================
        # Grupo SE: gap real 2026-09-01 -- Invoke-AdoApplyPhases (Fase 2)
        # no tenia ninguna rama para family='standalone-build' (siempre
        # exigia los 3 manifiestos K8s de AKS). Cubre: ConvertFrom-
        # AdoStepsSpecFile factorizada (regresion), plan.dependencies.
        # standaloneBuild persistido y validado (allowlist DevOps/Buklo ya
        # ampliado por el coordinador en la sesion principal, confirmado
        # en vivo arriba en el archivo con AdoAllowedProjects), y Fase 2
        # reconstruyendo el body EXACTO (mismo bodyHash) sin pedir
        # -DeploymentDevYamlPath/etc. para esta familia.
        # ============================================================

        $sbConvertedSteps = ConvertFrom-AdoStepsSpecFile -StepsSpecPath $scStepsSpecPath
        Add-Result -Name 'SE: ConvertFrom-AdoStepsSpecFile (factorizada) produce los mismos 2 steps que antes (regresion, sin duplicar logica)' `
            -Pass (@($sbConvertedSteps).Count -eq 2 -and $sbConvertedSteps[0].displayName -eq 'File Creator detect-and-build.ps1' -and $sbConvertedSteps[0].task.id -eq '1f81a8be-d8ce-497d-9791-190126f661e7' -and $sbConvertedSteps[1].displayName -eq 'Ejecutar detect-and-build.ps1' -and $sbConvertedSteps[1].task.id -eq 'e213ff0f-5d5c-4791-802d-52ea3e7be1f1') `
            -Detail (($sbConvertedSteps | ForEach-Object { $_.displayName }) -join ' | ')

        Add-Result -Name 'SE: plan.dependencies.standaloneBuild.steps quedo persistido por New-AdoClassicCreatePlan.ps1 (Count=2, mismos task.id)' `
            -Pass (@($scOutputPlan.dependencies.standaloneBuild.steps).Count -eq 2 -and $scOutputPlan.dependencies.standaloneBuild.steps[0].task.id -eq '1f81a8be-d8ce-497d-9791-190126f661e7' -and $scOutputPlan.dependencies.standaloneBuild.steps[1].task.id -eq 'e213ff0f-5d5c-4791-802d-52ea3e7be1f1') `
            -Detail ($scOutputPlan.dependencies.standaloneBuild | ConvertTo-Json -Compress -Depth 6)
        Add-Result -Name 'SE: plan.dependencies.standaloneBuild retiene fetchDepth/agentPool/queueId para reconstruccion determinista en Apply' `
            -Pass ([string]$scOutputPlan.dependencies.standaloneBuild.fetchDepth -eq '0' -and [int]$scOutputPlan.dependencies.standaloneBuild.agentPoolId -eq 9 -and [string]$scOutputPlan.dependencies.standaloneBuild.agentPoolName -eq 'Azure Pipelines' -and $null -eq $scOutputPlan.dependencies.standaloneBuild.queueId) `
            -Detail ($scOutputPlan.dependencies.standaloneBuild | ConvertTo-Json -Compress -Depth 6)

        $sePlanPath = Join-Path $testTempRoot 'se-standalone-plan-buklo.json'
        Copy-Item $scOutPath $sePlanPath -Force

        $seInventoryBuklo = [ordered]@{
            generatedAtUtc     = (Get-Date).ToUniversalTime().ToString('o')
            organization       = 'Shared-Service-GM'
            project            = 'Buklo'
            paginationComplete = $true
            projects           = @(@{ id = 'proj-buklo'; name = 'Buklo' })
            buildDefinitions   = @()
            releaseDefinitions = @()
            variableGroups     = @()
            taskGroups         = @()
            serviceConnections = @()
            agentPools         = @(@{ id = 9; name = 'Azure Pipelines'; isHosted = $true })
            repositories       = @(@{ id = '0550ab98-7959-45ee-8361-18b8e4df22a3'; name = 'buklo-backend'; defaultBranch = 'development'; branches = @('development') })
        }
        $seInventoryBukloPath = Join-Path $testTempRoot 'se-inventory-buklo.json'
        [PSCustomObject]$seInventoryBuklo | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $seInventoryBukloPath -Encoding utf8

        & powershell -NoProfile -File (Join-Path $scriptsRoot 'Test-AdoClassicPlan.ps1') -PlanPath $sePlanPath -InventoryPath $seInventoryBukloPath | Out-Null
        $seValidatedPlan = Get-Content -LiteralPath $sePlanPath -Raw | ConvertFrom-Json
        Add-Result -Name 'SE: plan standalone-build en project=Buklo + inventario Buklo completo/fresco -> validated=true' `
            -Pass ($seValidatedPlan.validated -eq $true -and -not [string]::IsNullOrEmpty($seValidatedPlan.validationHash)) `
            -Detail "validated=$($seValidatedPlan.validated); blockers=$($seValidatedPlan.validationBlockers -join ' | ')"

        if ($seValidatedPlan.validated -eq $true) {
            Reset-MockWebRequest
            Add-MockWebListResponse -Items @()
            Add-MockWebSuccessResponse -ResultId '900700'
            $seCreated = [System.Collections.Generic.List[string]]::new()
            Invoke-ExpectNoThrow -Name 'SE: Invoke-AdoApplyPhases (Fase 2, family=standalone-build) reconstruye el body EXACTO (bodyHash coincide via Invoke-AdoRest) SIN exigir manifiestos K8s' -Block {
                Invoke-AdoApplyPhases -Plan $seValidatedPlan -PlanPath $sePlanPath -CreatedSoFar $seCreated
            }
            Add-Result -Name 'SE: exactamente 2 llamadas HTTP (GET duplicado + POST creacion), nunca mas' `
                -Pass ($script:mockWebCallCount -eq 2) -Detail "mockWebCallCount=$($script:mockWebCallCount)"
            $seCreatedFlat = (@($seCreated) -join ' | ')
            Add-Result -Name 'SE: Build creado registrado en CreatedSoFar con el id devuelto por el mock' `
                -Pass ($seCreatedFlat -match 'id 900700') -Detail $seCreatedFlat
        }
    }
    else {
        Add-Result -Name 'SC: generacion de plan standalone-build' -Pass $false -Detail 'No se genero el archivo de plan.'
    }

    Remove-Item Env:\AZURE_DEVOPS_PAT -ErrorAction SilentlyContinue
    if ($null -eq $originalAdoTestExecutionsRoot) { Remove-Item Env:\ADO_TEST_EXECUTIONS_ROOT -ErrorAction SilentlyContinue } else { $env:ADO_TEST_EXECUTIONS_ROOT = $originalAdoTestExecutionsRoot }
}
finally {
    if ($originalPat) { $env:AZURE_DEVOPS_PAT = $originalPat }
    Remove-Item Env:\ADO_TEST_EXECUTIONS_ROOT -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testTempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ---- Reporte ----

$results | Format-Table -Property Name, Status -AutoSize

# @() fuerza semantica de coleccion: sin esto, Where-Object con
# exactamente 1 coincidencia devuelve un escalar (no un array), y
# $escalar.Count es $null (no 1) en Windows PowerShell 5.1 -- eso
# esconde fallos reales detras de un "FAIL: " en blanco y exit 0.
$failed = @($results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ""
Write-Host "Total: $($results.Count) - PASS: $($results.Count - $failed.Count) - FAIL: $($failed.Count)" -ForegroundColor $(if ($failed.Count -eq 0) { 'Green' } else { 'Red' })

if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host "Casos fallidos:" -ForegroundColor Red
    foreach ($f in $failed) {
        Write-Host "- $($f.Name)" -ForegroundColor Red
        Write-Host "  $($f.Detail)" -ForegroundColor Red
    }
    exit 1
}

exit 0
