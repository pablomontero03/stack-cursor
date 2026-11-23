<#
Valida el bloque INPUT de la plantilla ligera
(docs/PLANTILLA-CICLO-CREACION-PIPELINE-APLICACION-LIGERA.md) en una sola
pasada, de forma determinista y sin red -- ver
references/input-contract.md para el esquema completo. Nunca llama a
Azure DevOps, Cloudflare o AKS.

Acepta INPUT ya deserializado como Hashtable, OrderedDictionary o
PSCustomObject (compatibilidad probada explicitamente -- ver
scripts/tests/run-script-tests.ps1, escenario 6) para que el mismo
validador sirva sin importar si el llamador parseo YAML/JSON a mano o via
ConvertFrom-Json.

Uso:
  powershell -File .\Test-ApplicationCycleInput.ps1 -InputJsonPath .\input.json
#>

param(
    [string]$InputJsonPath,
    $InputObject
)

$ErrorActionPreference = 'Stop'

function Get-AppCycleProp {
    <#
    Acceso universal a una propiedad/clave sin asumir que el objeto tiene
    .ContainsKey() (OrderedDictionary/Hashtable difieren de PSCustomObject,
    y no todas las colecciones IDictionary exponen el mismo metodo -- usar
    IDictionary.Contains(), presente en ambas, en vez de .ContainsKey()).
    #>
    param($Obj, [Parameter(Mandatory)] [string]$Name)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) {
        if ($Obj.Contains($Name)) { return $Obj[$Name] } else { return $null }
    }
    $prop = $Obj.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Test-AppCycleValuePresent {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [string]) { return -not [string]::IsNullOrWhiteSpace($Value) }
    return $true
}

function Test-ApplicationCycleInputObject {
    <#
    Funcion pura: valida $InputObject.INPUT (o $InputObject si ya viene
    sin el nivel 'INPUT') contra el esquema de references/input-contract.md.
    Devuelve @{ ok; errors; warnings; normalized } -- nunca lanza por un
    dato de negocio invalido (solo por un tipo de $InputObject
    irreconocible), para que el llamador pueda agrupar TODOS los
    faltantes en una sola pregunta.
    #>
    param($InputObject)

    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    if ($null -eq $InputObject) {
        $errors.Add('INPUT esta vacio o no se pudo interpretar.')
        return [PSCustomObject]@{ ok = $false; errors = @($errors); warnings = @($warnings); normalized = $null }
    }

    $root = Get-AppCycleProp -Obj $InputObject -Name 'INPUT'
    if (-not (Test-AppCycleValuePresent $root)) { $root = $InputObject }

    $errorsRef = $errors
    $warningsRef = $warnings

    $application = Get-AppCycleProp -Obj $root -Name 'application'
    if (-not (Test-AppCycleValuePresent $application)) {
        $errorsRef.Add("Falta la seccion obligatoria 'INPUT.application'.")
    }
    else {
        $appId = Get-AppCycleProp -Obj $application -Name 'id'
        if (-not (Test-AppCycleValuePresent $appId)) { $errorsRef.Add("Falta 'INPUT.application.id'.") }
        $appType = Get-AppCycleProp -Obj $application -Name 'type'
        if (-not (Test-AppCycleValuePresent $appType)) { $appType = 'auto'; $warningsRef.Add("'INPUT.application.type' no declarado; se asume 'auto'.") }
        elseif ($appType -notin @('auto', 'api', 'web', 'database')) {
            $errorsRef.Add("'INPUT.application.type' invalido ('$appType'); debe ser auto|api|web|database.")
        }
        elseif ($appType -eq 'database') {
            $errorsRef.Add("'INPUT.application.type' = 'database' no esta soportado todavia -- no reutilizar modelos de aplicacion (ver input-contract.md).")
        }
    }

    $repository = Get-AppCycleProp -Obj $root -Name 'repository'
    if (-not (Test-AppCycleValuePresent $repository)) {
        $errorsRef.Add("Falta la seccion obligatoria 'INPUT.repository'.")
    }
    else {
        foreach ($field in @('organization', 'project', 'name', 'url', 'path')) {
            if (-not (Test-AppCycleValuePresent (Get-AppCycleProp -Obj $repository -Name $field))) {
                $errorsRef.Add("Falta 'INPUT.repository.$field'.")
            }
        }
        $branches = Get-AppCycleProp -Obj $repository -Name 'branches'
        if (-not (Test-AppCycleValuePresent $branches)) {
            $errorsRef.Add("Falta 'INPUT.repository.branches'.")
        }
        else {
            foreach ($env in @('development', 'uat', 'production')) {
                if (-not (Test-AppCycleValuePresent (Get-AppCycleProp -Obj $branches -Name $env))) {
                    $errorsRef.Add("Falta 'INPUT.repository.branches.$env'.")
                }
            }
        }
    }

    $adoSection = Get-AppCycleProp -Obj $root -Name 'azure_devops'
    if (-not (Test-AppCycleValuePresent $adoSection)) {
        $errorsRef.Add("Falta la seccion obligatoria 'INPUT.azure_devops'.")
    }
    else {
        foreach ($field in @('project', 'pipeline_folder', 'canonical_exports_directory')) {
            if (-not (Test-AppCycleValuePresent (Get-AppCycleProp -Obj $adoSection -Name $field))) {
                $errorsRef.Add("Falta 'INPUT.azure_devops.$field'.")
            }
        }
        # Normalmente el modelo canonico es un export local sanitizado
        # (build_export_candidates + release_export). Si todavia no existe
        # un export para esta familia de app, se acepta como alternativa
        # explicita 'canonical_model_live_reference' (URL de un Build real
        # ya confirmado como patron correcto) -- con advertencia, nunca
        # como error duro, porque es un estado interino real (ver
        # docs/pipeline-cycles/app-sso.md, 2026-09-07).
        $candidates = Get-AppCycleProp -Obj $adoSection -Name 'build_export_candidates'
        $releaseExport = Get-AppCycleProp -Obj $adoSection -Name 'release_export'
        $liveReference = Get-AppCycleProp -Obj $adoSection -Name 'canonical_model_live_reference'
        $hasStaticExport = (Test-AppCycleValuePresent $candidates) -and (@($candidates).Count -gt 0) -and (Test-AppCycleValuePresent $releaseExport)
        if (-not $hasStaticExport -and -not (Test-AppCycleValuePresent $liveReference)) {
            $errorsRef.Add("'INPUT.azure_devops' debe declarar 'build_export_candidates'+'release_export' (export sanitizado) o, si todavia no existe, 'canonical_model_live_reference' (URL de un Build real ya confirmado como patron correcto).")
        }
        elseif (-not $hasStaticExport -and (Test-AppCycleValuePresent $liveReference)) {
            $warningsRef.Add("Sin export sanitizado local: el modelo canonico se resuelve en vivo contra '$liveReference' -- crear el export estatico cuando este disponible.")
        }
        $secretSources = Get-AppCycleProp -Obj $adoSection -Name 'secret_sources'
        $crp = Get-AppCycleProp -Obj $secretSources -Name 'container_registry_password'
        $envVarName = Get-AppCycleProp -Obj $crp -Name 'environment_variable'
        if (-not (Test-AppCycleValuePresent $envVarName)) {
            $warningsRef.Add("'INPUT.azure_devops.secret_sources.container_registry_password.environment_variable' no declarado -- si el modelo canonico consume esta contraseña, sera un faltante pendiente.")
        }
    }

    $appVars = Get-AppCycleProp -Obj $root -Name 'application_variables'
    if (-not (Test-AppCycleValuePresent $appVars)) {
        $errorsRef.Add("Falta la seccion obligatoria 'INPUT.application_variables'.")
    }

    $manifests = Get-AppCycleProp -Obj $root -Name 'manifests'
    if (-not (Test-AppCycleValuePresent $manifests)) {
        $errorsRef.Add("Falta la seccion obligatoria 'INPUT.manifests'.")
    }
    else {
        foreach ($env in @('development', 'uat', 'production')) {
            if (-not (Test-AppCycleValuePresent (Get-AppCycleProp -Obj $manifests -Name $env))) {
                $errorsRef.Add("Falta 'INPUT.manifests.$env'.")
            }
        }
    }

    $environments = Get-AppCycleProp -Obj $root -Name 'environments'
    if (-not (Test-AppCycleValuePresent $environments)) {
        $errorsRef.Add("Falta la seccion obligatoria 'INPUT.environments'.")
    }
    else {
        foreach ($env in @('development', 'uat', 'production')) {
            $envSection = Get-AppCycleProp -Obj $environments -Name $env
            if (-not (Test-AppCycleValuePresent $envSection)) {
                $errorsRef.Add("Falta 'INPUT.environments.$env'.")
                continue
            }
            if (-not (Test-AppCycleValuePresent (Get-AppCycleProp -Obj $envSection -Name 'namespace'))) {
                $errorsRef.Add("Falta 'INPUT.environments.$env.namespace'.")
            }
            $dns = Get-AppCycleProp -Obj $envSection -Name 'dns'
            if (-not (Test-AppCycleValuePresent $dns)) {
                $errorsRef.Add("Falta 'INPUT.environments.$env.dns'.")
            }
            else {
                foreach ($dnsField in @('fqdn', 'type', 'ip')) {
                    if (-not (Test-AppCycleValuePresent (Get-AppCycleProp -Obj $dns -Name $dnsField))) {
                        $errorsRef.Add("Falta 'INPUT.environments.$env.dns.$dnsField'.")
                    }
                }
            }
        }
    }

    $discovery = Get-AppCycleProp -Obj $root -Name 'discovery'
    $validationMode = Get-AppCycleProp -Obj $discovery -Name 'cluster_validation_before_plan'
    if (-not (Test-AppCycleValuePresent $validationMode)) {
        $validationMode = 'preguntar'
        $warningsRef.Add("'INPUT.discovery.cluster_validation_before_plan' no declarado; se trata como 'preguntar' (una sola pregunta agrupada al inicio).")
    }
    elseif ($validationMode -notin @('preguntar', 'completa', 'minima', 'omitir')) {
        $warningsRef.Add("'INPUT.discovery.cluster_validation_before_plan' invalido ('$validationMode'); se trata como 'preguntar'.")
        $validationMode = 'preguntar'
    }

    $executionDefaults = [ordered]@{
        max_automatic_configuration_retries_per_environment = 2
        status_poll_interval_seconds                        = 120
        build_wait_timeout_minutes                          = 60
        release_wait_timeout_minutes                        = 60
        rollout_wait_timeout_minutes                         = 20
        aks_capacity_validation_max_age_seconds              = 300
        record_phase_timings                                 = $true
        run_development_after_plan_approval                  = $true
        run_uat_after_development_success                    = $true
        prepare_production                                   = $true
        production_requires_separate_approval                = $true
        allow_application_code_changes                       = $false
        allow_deletions                                       = $false
    }
    $execution = Get-AppCycleProp -Obj $root -Name 'execution'
    $normalizedExecution = [ordered]@{}
    foreach ($key in $executionDefaults.Keys) {
        $value = Get-AppCycleProp -Obj $execution -Name $key
        if (-not (Test-AppCycleValuePresent $value)) {
            $normalizedExecution[$key] = $executionDefaults[$key]
            $warningsRef.Add("'INPUT.execution.$key' no declarado; se usa el default $($executionDefaults[$key]).")
        }
        else {
            $normalizedExecution[$key] = $value
        }
    }
    if ([bool]$normalizedExecution['allow_application_code_changes']) {
        $errorsRef.Add("'INPUT.execution.allow_application_code_changes' = true no esta permitido por este ciclo -- un cambio de codigo siempre requiere solicitud explicita y plan nuevo, nunca una bandera de INPUT.")
    }

    $ok = ($errorsRef.Count -eq 0)
    return [PSCustomObject]@{
        ok         = $ok
        errors     = @($errorsRef)
        warnings   = @($warningsRef)
        normalized = [PSCustomObject]@{
            applicationType             = if ($application) { (Get-AppCycleProp -Obj $application -Name 'type') } else { $null }
            clusterValidationBeforePlan = $validationMode
            execution                   = [PSCustomObject]$normalizedExecution
        }
    }
}

function Test-ApplicationCycleSecretPresence {
    <#
    Comprueba SOLO presencia (nunca valor) de una variable de entorno que
    INPUT declara como fuente de un secreto (ej.
    ADO_SECRET_CONTAINERREGISTRYPASSWORD). No lanza si falta -- devuelve
    guia accionable, incluyendo el caso 'creada con setx pero el proceso
    actual todavia no la ve' (nunca se pide el valor por chat).
    #>
    param([Parameter(Mandatory)] [string]$EnvironmentVariableName)

    $present = [bool][Environment]::GetEnvironmentVariable($EnvironmentVariableName)
    if ($present) {
        return [PSCustomObject]@{ environmentVariableName = $EnvironmentVariableName; present = $true; guidance = 'Presente en el proceso actual; se usara internamente sin pedir el valor.' }
    }
    return [PSCustomObject]@{
        environmentVariableName = $EnvironmentVariableName
        present                 = $false
        guidance                = "No visible en el proceso actual. Si se creo con 'setx', solo aparece en procesos NUEVOS -- pedir reiniciar la terminal/sesion de Claude una vez y volver a comprobar. Nunca solicitar el valor por chat."
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $InputObject) {
        if (-not $InputJsonPath) {
            throw "Test-ApplicationCycleInput rechazado: indicar -InputJsonPath o -InputObject."
        }
        if (-not (Test-Path -LiteralPath $InputJsonPath)) {
            throw "Test-ApplicationCycleInput rechazado: no existe '$InputJsonPath'."
        }
        $InputObject = Get-Content -LiteralPath $InputJsonPath -Raw | ConvertFrom-Json
    }
    $result = Test-ApplicationCycleInputObject -InputObject $InputObject
    $result | ConvertTo-Json -Depth 10
}
