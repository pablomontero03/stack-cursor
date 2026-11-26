<#
Biblioteca de escaneo de secretos para planes de Azure DevOps Pipelines.
Referenciada por Test-AdoClassicPlan.ps1 y el harness de pruebas del
dominio para detectar secretos literales embebidos en un plan.

Funciones exportadas:
  Find-AdoSensitiveJsonProperties  - escanea propiedades sensibles por nombre
  Find-AdoRawTextSecretPatterns    - escanea texto crudo por patrones regex

Patron tomado de Azure-Common.ps1 (dominio manage-azure-resources),
adaptado para ADO: incluye PAT, ADO_SECRET_*, connection strings SQL.
Los placeholders ${ADO_SECRET_*} son siempre permitidos (mecanismo
oficial del dominio para referencias de secretos controladas).
Creado 2026-09-11 para resolver referencia fantasma de la era Claude.
#>

function Find-AdoSensitiveJsonProperties {
    <#
    Escanea recursivamente un objeto ya parseado (de un plan) por
    NOMBRE de propiedad sensible con un valor literal no-placeholder.
    Placeholder permitido: cualquier valor que contenga '${...}' o sea
    exactamente '***REDACTED***' o $null.
    Propiedades de identificacion (operationId, id, uri, method,
    name, displayName, type) nunca se tratan como secretos.
    #>
    param([Parameter(Mandatory)] $Node, [string]$Path = '$')

    $sensitiveNames = @(
        'password', 'passwd', 'pwd', 'pat', 'token', 'accesstoken',
        'personalAccessToken', 'clientsecret', 'secret', 'apikey',
        'privatekey', 'authorization', 'connectionstring',
        'registrypassword', 'dockerpassword', 'accountkey', 'sastoken'
    )
    $ignoredNames = @('operationid', 'id', 'uri', 'method', 'name',
                      'displayname', 'type', 'kind', 'refname',
                      'resourcetype', 'planid', 'bodypath')

    $findings = [System.Collections.Generic.List[object]]::new()

    function Test-AdoPlaceholderValue {
        param([string]$Value)
        if ($null -eq $Value) { return $true }
        if ($Value -eq '***REDACTED***') { return $true }
        if ($Value -match '\$\{[A-Za-z0-9_]+\}') { return $true }
        return $false
    }

    function Step {
        param($Obj, [string]$CurPath)
        if ($null -eq $Obj) { return }

        if ($Obj -is [System.Management.Automation.PSCustomObject]) {
            foreach ($prop in $Obj.PSObject.Properties) {
                $childPath = "$CurPath.$($prop.Name)"
                $lowerName = $prop.Name.ToLowerInvariant()
                if ($ignoredNames -contains $lowerName) {
                    Step -Obj $prop.Value -CurPath $childPath
                    continue
                }
                $isSensitiveName = $sensitiveNames | Where-Object { $lowerName -like "*$_*" }
                if ($isSensitiveName -and $prop.Value -is [string]) {
                    if (-not (Test-AdoPlaceholderValue -Value $prop.Value)) {
                        $findings.Add([PSCustomObject]@{ path = $childPath; property = $prop.Name })
                    }
                }
                Step -Obj $prop.Value -CurPath $childPath
            }
        }
        elseif ($Obj -is [System.Collections.IEnumerable] -and -not ($Obj -is [string])) {
            $i = 0
            foreach ($item in $Obj) {
                Step -Obj $item -CurPath "$CurPath[$i]"
                $i++
            }
        }
    }

    Step -Obj $Node -CurPath $Path
    return @($findings)
}

function Find-AdoRawTextSecretPatterns {
    <#
    Defensa adicional: regex sobre el TEXTO crudo del archivo, por si un
    secreto aparece dentro de un argv o rawArgs que el scan por nombre de
    propiedad no cubre. Ignora placeholders ${VAR} y ***REDACTED***.
    Incluye patrones especificos de ADO: PAT en formato base64 largo y
    connection strings SQL.
    #>
    param([Parameter(Mandatory)] [string]$RawText)

    $patterns = @(
        # PAT de Azure DevOps (base64, tipicamente 52 chars sin separadores)
        # Detecta pat/personalAccessToken seguido de = o : y un valor alfanumerico largo
        '(?i)(pat|personalAccessToken)\s*[":=]+\s*"?[A-Za-z0-9+/=]{30,}',
        # Secretos genericos
        '(?i)(password|passwd|pwd)\s*[:=]\s*"?[^"\s,${}]{4,}',
        '(?i)(client[_-]?secret)\s*[:=]\s*"?[^"\s,${}]{4,}',
        '(?i)(access[_-]?token|accesstoken)\s*[:=]\s*"?[^"\s,${}]{8,}',
        '(?i)(connection[_-]?string)\s*[:=]\s*"?[^"\s,${}]{8,}',
        # Connection strings SQL con password embebida
        'Password=[^;"\s]{4,}',
        # JWT
        'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
    )

    $findings = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $patterns) {
        if ([regex]::IsMatch($RawText, $p)) {
            $findings.Add($p)
        }
    }
    return @($findings)
}
