<#
Parsea el contenido de un archivo .env/.env.example de un repo de
aplicativo y clasifica cada variable en las categorias que necesita el
paso "Secret + ConfigMap" de la convencion de manifiestos K8s (ver
references/ado-classic-payload-templates.md § "Convencion org-wide:
plantilla de manifiestos K8s para File Creator"). Nunca hace ninguna
llamada de red ni toca Azure DevOps -- es puro parsing de texto, para
dot-sourcear desde donde se este armando el filecontent de un pipeline
nuevo.

No tiene bloque de ejecucion propio, solo definiciones de funcion (mismo
patron que New-AdoClassicPayloads.ps1).
#>

# Prefijos de build-time conocidos de los frameworks frontend mas comunes
# -- estas variables se hornean en el bundle via --build-arg del Docker
# build, NUNCA van en ConfigMap/Secret de K8s.
$script:AdoEnvBuildTimePrefixes = @('VITE_', 'REACT_APP_', 'NEXT_PUBLIC_', 'VUE_APP_', 'NG_APP_', 'GATSBY_', 'NUXT_PUBLIC_', 'PUBLIC_')

# Prefijo de variables que configuran el PIPELINE (registry/tag de Docker),
# no el runtime del aplicativo -- se excluyen de ConfigMap/Secret.
$script:AdoEnvPipelinePrefixes = @('DOCKER_')

# Nombre de variable que sugiere un valor sensible. Curado para juntar
# terminos reales vistos en .env.example de esta org (ADO_PAT, etc.) sin
# disparar con palabras comunes que solo contienen la subcadena (ej.
# 'update', 'compatible') -- 'pat'/'pass' exigen limite de palabra con
# guion bajo. 'pass' se agrego 2026-08-25 tras un caso real (DB_PASS) que
# 'password'/'passwd'/'pwd' no cubrian -- abreviatura comun en .env reales
# que 'password' completo no siempre captura.
$script:AdoEnvSecretNamePattern = '(?i)(password|passwd|pwd|(^|_)pass($|_)|secret|token|credential|connectionstring|conn_str|apikey|api_key|private_key|privatekey|(^|_)pat($|_)|certificate|cert_|client_secret|access_key|accesskey)'

# Un valor de EJEMPLO que de todas formas parece un token/credencial real
# (string larga, sin espacios, alfanumerica con +/=_-) se trata como
# sospechosa aunque el nombre de la variable no lo sugiera.
$script:AdoEnvSuspiciousValuePattern = '^[A-Za-z0-9+/_=-]{24,}$'

# Frases de comentario (ES/EN) que marcan el inicio de una seccion
# build-time dentro del archivo -- refuerza (nunca reemplaza) la deteccion
# por prefijo, para variables sin uno de los prefijos conocidos.
$script:AdoEnvBuildTimeSectionHintPattern = '(?i)(build-time|build time|compile-time|se bake-in|tiempo de build|tiempo de compilacion)'
$script:AdoEnvRuntimeSectionHintPattern = '(?i)(runtime variables|variables de runtime|docker build|build args)'

function Get-AdoEnvLineValue {
    <#
    Extrae el valor de un lado-derecho "VALUE" o "VALUE # comentario" de
    una linea KEY=VALUE, respetando comillas (un '#' dentro de comillas
    no corta el valor).
    #>
    param([Parameter(Mandatory)] [string]$RawValue)
    $v = $RawValue.Trim()
    if ($v.Length -ge 2 -and ($v[0] -eq '"' -or $v[0] -eq "'")) {
        $quoteChar = $v[0]
        $closeIdx = $v.IndexOf($quoteChar, 1)
        if ($closeIdx -gt 0) {
            return $v.Substring(1, $closeIdx - 1)
        }
        return $v.Trim($quoteChar)
    }
    $hashIdx = $v.IndexOf('#')
    if ($hashIdx -ge 0) { $v = $v.Substring(0, $hashIdx) }
    return $v.Trim()
}

function ConvertTo-AdoEnvClassification {
    <#
    $EnvFileContent: texto crudo de un .env/.env.example ya leido (esta
    funcion no lee archivos ni hace red).

    $IsExampleFile: SIEMPRE $true solo para una fuente confirmada
    NO-sensible (.env.example/.env.sample/.env.template, o equivalente).
    Con $false (ej. un .env real committeado por error, sin variante
    .example) y $PopulateRealValues=$false (default), esta funcion NUNCA
    copia ningun valor -- todo configMapVar queda con value='' y se
    agrega a ambiguousVars para completar a mano.

    $PopulateRealValues (default $false, switch explicito): cuando el
    usuario autoriza explicitamente usar los valores reales del .env real
    del propio repo del aplicativo -- confirmado 2026-08-25 como el
    patron YA vigente en TODOS los pipelines clasicos de esta org (mismo
    criterio que un pipeline YAML con el manifiesto en el repo: el valor
    real vive en el File Creator del Build), con acceso al proyecto
    DevOps restringido a ~3 personas de jefatura. Con este switch:
      - configMapVars SIEMPRE lleva el value real (ignora $IsExampleFile).
      - secretVars TAMBIEN lleva 'value' (real) -- unica combinacion en
        que esta funcion devuelve un value para un secreto. El llamador
        es responsable de no imprimir esos valores de vuelta en texto de
        chat/logs una vez los recibe (redactar en cualquier resumen que
        muestre al usuario; el archivo YAML generado si los lleva, que es
        exactamente lo que se pidio).
      - ambiguousVars solo sigue marcando el caso "nombre no-secreto con
        valor sospechoso" (para que se revise el nombre de esa variable
        puntual), nunca la ausencia generica de .example.
    Sin este switch, el comportamiento cauteloso original (nunca copiar
    de un .env real) sigue intacto -- esta funcion nunca asume
    autorizacion, siempre hay que pedirla explicita pasando el switch.

    Devuelve [ordered]@{ buildTimeVars; pipelineVars; secretVars;
    configMapVars; ambiguousVars }, cada uno un array de @{name;value}
    (salvo secretVars sin -PopulateRealValues, que solo trae 'name').

    Nunca lanza por una variable individual rara -- lo peor que hace es
    agregarla a ambiguousVars para que el llamador decida. Solo tiene
    sentido llamarla con contenido real de la app (nunca inventar
    variables que el archivo no tiene).
    #>
    param(
        [Parameter(Mandatory)] [string]$EnvFileContent,
        [bool]$IsExampleFile = $true,
        [switch]$PopulateRealValues
    )

    $buildTimeVars = [System.Collections.Generic.List[object]]::new()
    $pipelineVars  = [System.Collections.Generic.List[object]]::new()
    $secretVars    = [System.Collections.Generic.List[object]]::new()
    $configMapVars = [System.Collections.Generic.List[object]]::new()
    $ambiguousVars = [System.Collections.Generic.List[object]]::new()

    $inBuildTimeSection = $false
    $lines = $EnvFileContent -split "`r?`n"
    foreach ($rawLine in $lines) {
        $line = $rawLine.Trim()
        if ($line.Length -eq 0) { continue }

        if ($line.StartsWith('#')) {
            if ($line -match $script:AdoEnvBuildTimeSectionHintPattern) { $inBuildTimeSection = $true }
            elseif ($line -match $script:AdoEnvRuntimeSectionHintPattern) { $inBuildTimeSection = $false }
            continue
        }

        if ($line -notmatch '^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') { continue }
        $name = $Matches[1]
        $value = Get-AdoEnvLineValue -RawValue $Matches[2]

        $isBuildTimePrefix = $false
        foreach ($p in $script:AdoEnvBuildTimePrefixes) { if ($name.StartsWith($p)) { $isBuildTimePrefix = $true; break } }

        $isPipelinePrefix = $false
        foreach ($p in $script:AdoEnvPipelinePrefixes) { if ($name.StartsWith($p)) { $isPipelinePrefix = $true; break } }

        if ($isPipelinePrefix) {
            $pipelineVars.Add([ordered]@{ name = $name; value = $value })
            continue
        }
        if ($isBuildTimePrefix -or $inBuildTimeSection) {
            $buildTimeVars.Add([ordered]@{ name = $name; value = $value })
            continue
        }

        $looksSecretByName = $name -match $script:AdoEnvSecretNamePattern
        $looksSuspiciousValue = (-not [string]::IsNullOrWhiteSpace($value)) -and ($value -match $script:AdoEnvSuspiciousValuePattern)

        if ($looksSecretByName -or $looksSuspiciousValue) {
            if ($PopulateRealValues) {
                $secretVars.Add([ordered]@{ name = $name; value = $value })
            }
            else {
                $secretVars.Add([ordered]@{ name = $name })
            }
            if ($looksSuspiciousValue -and -not $looksSecretByName) {
                $ambiguousVars.Add([ordered]@{ name = $name; reason = 'Nombre no sugiere secreto pero el valor tiene forma de token/credencial -- clasificada como Secret por seguridad, confirmar si corresponde.' })
            }
            continue
        }

        if ($PopulateRealValues -or $IsExampleFile) {
            $configMapVars.Add([ordered]@{ name = $name; value = $value })
        }
        else {
            $configMapVars.Add([ordered]@{ name = $name; value = '' })
            $ambiguousVars.Add([ordered]@{ name = $name; reason = 'Valor tomado de un .env REAL (no .example) -- nunca se copia un valor real; queda vacio, completar a mano.' })
        }
    }

    return [ordered]@{
        buildTimeVars = @($buildTimeVars)
        pipelineVars  = @($pipelineVars)
        secretVars    = @($secretVars)
        configMapVars = @($configMapVars)
        ambiguousVars = @($ambiguousVars)
    }
}
