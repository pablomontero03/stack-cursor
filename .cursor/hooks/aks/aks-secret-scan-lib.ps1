<#
Biblioteca de escaneo de secretos para planes de AKS.
Referenciada por Test-AksChangePlan.ps1 para detectar secretos
literales o kubeconfigs embebidos en un plan antes de validarlo.

Funciones exportadas:
  Find-AksSensitiveJsonProperties  - escanea propiedades sensibles por nombre
  Find-AksRawTextSecretPatterns    - escanea texto crudo por patrones regex

Patron tomado de Azure-Common.ps1 (dominio manage-azure-resources),
adaptado para incluir kubeconfig y credenciales especificas de AKS.
Creado 2026-09-11 para resolver referencia fantasma de la era Claude.
#>

function Find-AksSensitiveJsonProperties {
    <#
    Escanea recursivamente un objeto ya parseado (de un plan) por
    NOMBRE de propiedad sensible con un valor literal no-placeholder.
    Placeholder permitido: cualquier valor que contenga '${...}' o sea
    exactamente '***REDACTED***' o $null.
    'resourceId', 'id', 'namespace', 'cluster', 'context' nunca se
    tratan como secretos aunque contengan texto largo.
    #>
    param([Parameter(Mandatory)] $Node, [string]$Path = '$')

    $sensitiveNames = @(
        'password', 'passwd', 'pwd', 'token', 'accesstoken',
        'kubeconfig', 'clientcertificatedata', 'clientkeydata',
        'certificateauthoritydata', 'clientsecret', 'secret',
        'apikey', 'privatekey', 'authorization', 'bearertoken',
        'serviceaccounttoken', 'registrypassword', 'dockerpassword'
    )
    $ignoredNames = @('resourceid', 'id', 'namespace', 'cluster', 'context',
                      'clusterName', 'operationId', 'planId', 'kubeconfigpath')

    $findings = [System.Collections.Generic.List[object]]::new()

    function Test-AksPlaceholderValue {
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
                    if (-not (Test-AksPlaceholderValue -Value $prop.Value)) {
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

function Find-AksRawTextSecretPatterns {
    <#
    Defensa adicional: regex sobre el TEXTO crudo del archivo, por si un
    secreto aparece dentro de un argv o rawArgs que el scan por nombre de
    propiedad no cubre. Ignora placeholders ${VAR} y ***REDACTED***.
    Incluye patron de kubeconfig (certificateAuthorityData base64 largo).
    #>
    param([Parameter(Mandatory)] [string]$RawText)

    $patterns = @(
        '(?i)(password|passwd|pwd)\s*[:=]\s*"?[^"\s,${}]{4,}',
        '(?i)(client[_-]?secret)\s*[:=]\s*"?[^"\s,${}]{4,}',
        '(?i)(access[_-]?token|accesstoken|bearertoken)\s*[:=]\s*"?[^"\s,${}]{8,}',
        '(?i)(kubeconfig)\s*[:=]\s*"?[^"\s,${}]{8,}',
        '(?i)(certificate[_-]?authority[_-]?data|client[_-]?certificate[_-]?data|client[_-]?key[_-]?data)\s*[:=]\s*[A-Za-z0-9+/=]{20,}',
        'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}',
        '(?i)(registry[_-]?password|docker[_-]?password)\s*[:=]\s*"?[^"\s,${}]{4,}'
    )

    $findings = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $patterns) {
        if ([regex]::IsMatch($RawText, $p)) {
            $findings.Add($p)
        }
    }
    return @($findings)
}
