<#
.SYNOPSIS
Consulta variables de Build, Release o Variable Groups clasicos de Azure DevOps.

.DESCRIPTION
Lector de solo lectura para el flujo MCP-first/API-fallback. Usa GET exclusivamente.
Primero toma el PAT de $env:AZURE_DEVOPS_PAT; si no existe, lee internamente la clave
`token` de env/Azure-DevOps.txt. El PAT nunca se imprime ni forma parte del resultado.

Azure DevOps no devuelve el valor de variables isSecret=true. Con
-RevealLocalSecrets, y solo despues de la aprobacion nativa que fuerza el hook, el
script puede completar una variable secreta cuando existe una clave del mismo nombre
en env/Azure-DevOps.txt. La clave `token` nunca se revela, incluso con ese switch.

El resultado solo se escribe a stdout como JSON; no crea archivos ni modifica Azure.
#>

[CmdletBinding()]
param(
    [ValidateSet('Build', 'Release', 'VariableGroup', 'LocalFile')]
    [string]$Kind,

    [int]$DefinitionId = 0,

    [string]$Project = 'DevOps',

    [switch]$RevealLocalSecrets,

    [string]$CredentialFile
)

$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
$projectRoot = $env:REPO_ROOT
if ([string]::IsNullOrWhiteSpace($projectRoot)) {
    $projectRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $scriptRoot)))
}
if ([string]::IsNullOrWhiteSpace($CredentialFile)) {
    $CredentialFile = Join-Path $projectRoot 'env\Azure-DevOps.txt'
}

function Read-AdoLocalCredentialMap {
    param([Parameter(Mandatory)] [string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "No existe el archivo de credenciales de Azure DevOps: $Path"
    }

    $map = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $lineNumber = 0
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        $lineNumber++
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) { continue }

        if ($trimmed -notmatch '^([^:=]+?)\s*[:=]\s*(.*)$') {
            throw "Formato invalido en el archivo de credenciales, linea $lineNumber. Se esperaba nombre: valor o nombre=valor."
        }

        $name = $matches[1].Trim()
        $value = $matches[2].Trim()
        if ([string]::IsNullOrWhiteSpace($name)) {
            throw "Nombre de credencial vacio en la linea $lineNumber."
        }
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            if ($value.Length -ge 2) { $value = $value.Substring(1, $value.Length - 2) }
        }
        if ($map.ContainsKey($name)) {
            throw "La credencial '$name' esta duplicada en el archivo local."
        }
        $map.Add($name, $value)
    }

    return $map
}

function Get-AdoPropertyValue {
    param($Object, [Parameter(Mandatory)] [string]$Name)

    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function ConvertTo-AdoVariableRows {
    param(
        $Variables,
        [Parameter(Mandatory)] [string]$Scope,
        [Parameter(Mandatory)] [string]$SourceKind,
        [System.Collections.Generic.Dictionary[string, string]]$LocalCredentials,
        [switch]$RevealSecrets
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Variables) { return @($rows) }

    $properties = if ($Variables -is [System.Collections.IDictionary]) {
        @($Variables.Keys | ForEach-Object { [PSCustomObject]@{ Name = [string]$_; Value = $Variables[$_] } })
    }
    else {
        @($Variables.PSObject.Properties)
    }

    foreach ($property in $properties) {
        $name = [string]$property.Name
        $entry = $property.Value
        $isStructured = $entry -is [System.Collections.IDictionary] -or $null -ne $entry.PSObject.Properties['value'] -or $null -ne $entry.PSObject.Properties['isSecret']
        $isSecret = if ($isStructured) { [bool](Get-AdoPropertyValue -Object $entry -Name 'isSecret') } else { $false }
        $apiValue = if ($isStructured) { Get-AdoPropertyValue -Object $entry -Name 'value' } else { $entry }
        $value = $null
        $valueSource = 'azure-devops'
        $valueStatus = 'available-non-secret'

        if ($isSecret) {
            $valueStatus = 'secret-not-returned-by-azure-devops'
            if ($RevealSecrets -and $null -ne $LocalCredentials -and $name -ine 'token' -and $LocalCredentials.ContainsKey($name)) {
                $value = $LocalCredentials[$name]
                $valueSource = 'env/Azure-DevOps.txt'
                $valueStatus = 'resolved-from-local-file'
            }
        }
        else {
            $value = $apiValue
        }

        $rows.Add([PSCustomObject]@{
            name        = $name
            value       = $value
            isSecret    = $isSecret
            scope       = $Scope
            sourceKind  = $SourceKind
            valueSource = $valueSource
            valueStatus = $valueStatus
        })
    }

    return @($rows)
}

function ConvertTo-AdoLocalFileRows {
    param(
        [Parameter(Mandatory)] [System.Collections.Generic.Dictionary[string, string]]$LocalCredentials,
        [switch]$RevealSecrets
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($name in @($LocalCredentials.Keys | Sort-Object)) {
        $isAuthToken = $name -ieq 'token'
        $canReveal = $RevealSecrets -and -not $isAuthToken
        $rows.Add([PSCustomObject]@{
            name        = $name
            value       = $(if ($canReveal) { $LocalCredentials[$name] } else { $null })
            isSecret    = $true
            scope       = 'local-credential-file'
            sourceKind  = 'LocalFile'
            valueSource = 'env/Azure-DevOps.txt'
            valueStatus = $(if ($isAuthToken) { 'authentication-token-never-revealed' } elseif ($canReveal) { 'revealed-after-native-approval' } else { 'hidden-use-RevealLocalSecrets' })
        })
    }
    return @($rows)
}

function Get-AdoReferencedVariableGroupIds {
    param($DefinitionBody)

    $ids = [System.Collections.Generic.List[int]]::new()
    $containers = [System.Collections.Generic.List[object]]::new()
    $containers.Add((Get-AdoPropertyValue -Object $DefinitionBody -Name 'variableGroups'))
    foreach ($environment in @((Get-AdoPropertyValue -Object $DefinitionBody -Name 'environments'))) {
        $containers.Add((Get-AdoPropertyValue -Object $environment -Name 'variableGroups'))
    }

    foreach ($container in $containers) {
        foreach ($item in @($container)) {
            if ($null -eq $item) { continue }
            $rawId = if ($item -is [int] -or $item -is [long] -or $item -is [string]) { $item } else { Get-AdoPropertyValue -Object $item -Name 'id' }
            $parsedId = 0
            if ([int]::TryParse([string]$rawId, [ref]$parsedId) -and $parsedId -gt 0 -and -not $ids.Contains($parsedId)) {
                $ids.Add($parsedId)
            }
        }
    }
    return @($ids)
}

if ($env:ADO_VARIABLE_READER_TEST_MODE -eq '1') {
    return
}

if ([string]::IsNullOrWhiteSpace($Kind)) {
    throw 'Kind es obligatorio: Build, Release, VariableGroup o LocalFile.'
}
if ($Kind -ne 'LocalFile' -and $DefinitionId -le 0) {
    throw 'DefinitionId debe ser mayor que cero para Build, Release o VariableGroup.'
}

$localCredentials = $null
$originalPat = $env:AZURE_DEVOPS_PAT
$patSource = 'environment'

try {
    if ($RevealLocalSecrets -or $Kind -eq 'LocalFile' -or [string]::IsNullOrWhiteSpace($env:AZURE_DEVOPS_PAT)) {
        $localCredentials = Read-AdoLocalCredentialMap -Path $CredentialFile
    }

    if ($Kind -eq 'LocalFile') {
        $result = [PSCustomObject]@{
            project                    = $Project
            requestedKind              = $Kind
            definitionId              = $null
            operation                  = 'local-read-only'
            revealLocalSecretsApproved = [bool]$RevealLocalSecrets
            variables                  = @(ConvertTo-AdoLocalFileRows -LocalCredentials $localCredentials -RevealSecrets:$RevealLocalSecrets)
        }
        $result | ConvertTo-Json -Depth 12
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($env:AZURE_DEVOPS_PAT)) {
        if ($null -eq $localCredentials -or -not $localCredentials.ContainsKey('token') -or [string]::IsNullOrWhiteSpace($localCredentials['token'])) {
            throw 'No hay PAT disponible: configure AZURE_DEVOPS_PAT o la clave token en env/Azure-DevOps.txt.'
        }
        $env:AZURE_DEVOPS_PAT = $localCredentials['token']
        $patSource = 'env/Azure-DevOps.txt'
    }

    . (Join-Path $scriptRoot 'Invoke-AdoRest.ps1')

    if ($Kind -eq 'Build') {
        $uri = "$($script:AdoCoreBaseUrl)/$Project/_apis/build/definitions/$DefinitionId`?api-version=$($script:AdoApiVersion)"
    }
    elseif ($Kind -eq 'Release') {
        $uri = "$($script:AdoReleaseBaseUrl)/$Project/_apis/release/definitions/$DefinitionId`?api-version=$($script:AdoApiVersion)"
    }
    else {
        $uri = "$($script:AdoCoreBaseUrl)/$Project/_apis/distributedtask/variablegroups/$DefinitionId`?api-version=$($script:AdoApiVersion)"
    }

    $definition = (Invoke-AdoRest -Method GET -Uri $uri).Body
    $rows = [System.Collections.Generic.List[object]]::new()

    if ($Kind -eq 'VariableGroup') {
        $vgName = [string](Get-AdoPropertyValue -Object $definition -Name 'name')
        foreach ($row in @(ConvertTo-AdoVariableRows -Variables (Get-AdoPropertyValue -Object $definition -Name 'variables') -Scope "variable-group:${DefinitionId}:$vgName" -SourceKind 'VariableGroup' -LocalCredentials $localCredentials -RevealSecrets:$RevealLocalSecrets)) { $rows.Add($row) }
    }
    else {
        foreach ($row in @(ConvertTo-AdoVariableRows -Variables (Get-AdoPropertyValue -Object $definition -Name 'variables') -Scope "$($Kind.ToLowerInvariant()):$DefinitionId" -SourceKind $Kind -LocalCredentials $localCredentials -RevealSecrets:$RevealLocalSecrets)) { $rows.Add($row) }

        if ($Kind -eq 'Release') {
            foreach ($environment in @((Get-AdoPropertyValue -Object $definition -Name 'environments'))) {
                $environmentName = [string](Get-AdoPropertyValue -Object $environment -Name 'name')
                foreach ($row in @(ConvertTo-AdoVariableRows -Variables (Get-AdoPropertyValue -Object $environment -Name 'variables') -Scope "release:$DefinitionId/environment:$environmentName" -SourceKind 'ReleaseEnvironment' -LocalCredentials $localCredentials -RevealSecrets:$RevealLocalSecrets)) { $rows.Add($row) }
            }
        }

        foreach ($variableGroupId in @(Get-AdoReferencedVariableGroupIds -DefinitionBody $definition)) {
            $vgUri = "$($script:AdoCoreBaseUrl)/$Project/_apis/distributedtask/variablegroups/$variableGroupId`?api-version=$($script:AdoApiVersion)"
            $vg = (Invoke-AdoRest -Method GET -Uri $vgUri).Body
            $vgName = [string](Get-AdoPropertyValue -Object $vg -Name 'name')
            foreach ($row in @(ConvertTo-AdoVariableRows -Variables (Get-AdoPropertyValue -Object $vg -Name 'variables') -Scope "variable-group:${variableGroupId}:$vgName" -SourceKind 'ReferencedVariableGroup' -LocalCredentials $localCredentials -RevealSecrets:$RevealLocalSecrets)) { $rows.Add($row) }
        }
    }

    [PSCustomObject]@{
        project                     = $Project
        requestedKind               = $Kind
        definitionId               = $DefinitionId
        operation                   = 'azure-devops-get-only'
        authenticationSource        = $patSource
        revealLocalSecretsApproved  = [bool]$RevealLocalSecrets
        azureSecretValueLimitation  = 'Azure DevOps no devuelve valores isSecret=true; solo se completan por coincidencia exacta desde el archivo local cuando se aprobo -RevealLocalSecrets.'
        variables                   = @($rows)
    } | ConvertTo-Json -Depth 15
}
finally {
    if ([string]::IsNullOrWhiteSpace($originalPat)) {
        Remove-Item Env:\AZURE_DEVOPS_PAT -ErrorAction SilentlyContinue
    }
    else {
        $env:AZURE_DEVOPS_PAT = $originalPat
    }
}
