<#
Pruebas offline de Get-AdoClassicVariables.ps1. Usa credenciales ficticias
en un directorio temporal y nunca realiza llamadas de red.
#>

$ErrorActionPreference = 'Stop'
$scriptsRoot = Split-Path -Parent $PSScriptRoot
$readerPath = Join-Path $scriptsRoot 'Get-AdoClassicVariables.ps1'
$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ado-variable-reader-tests-{0}" -f ([Guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null

$results = [System.Collections.Generic.List[object]]::new()
function Add-TestResult {
    param([string]$Name, [bool]$Pass, [string]$Detail)
    $results.Add([PSCustomObject]@{ Name = $Name; Status = $(if ($Pass) { 'PASS' } else { 'FAIL' }); Detail = $Detail })
}

$fakeToken = 'FAKE_TEST_PAT_NEVER_REAL_123456789'
$fakePassword = 'FAKE_TEST_REGISTRY_PASSWORD_987654321'
$fakeCredentialFile = Join-Path $tmpRoot 'credentials.txt'

try {
    @(
        "token: $fakeToken"
        'containerRegistryUsername: fake-registry-user'
        "containerRegistryPassword: $fakePassword"
    ) | Set-Content -LiteralPath $fakeCredentialFile -Encoding UTF8

    $env:ADO_VARIABLE_READER_TEST_MODE = '1'
    . $readerPath
    Remove-Item Env:\ADO_VARIABLE_READER_TEST_MODE -ErrorAction SilentlyContinue

    $credentials = Read-AdoLocalCredentialMap -Path $fakeCredentialFile
    Add-TestResult -Name 'Parser: reconoce token, username y password sin imprimir valores' `
        -Pass ($credentials.Count -eq 3 -and $credentials.ContainsKey('token') -and $credentials.ContainsKey('containerRegistryPassword')) `
        -Detail '3 claves reconocidas'

    $fakeVariables = [PSCustomObject]@{
        appName                   = [PSCustomObject]@{ value = 'demo-api'; isSecret = $false }
        containerRegistryPassword = [PSCustomObject]@{ value = $null; isSecret = $true }
        token                     = [PSCustomObject]@{ value = $null; isSecret = $true }
    }

    $normalRows = @(ConvertTo-AdoVariableRows -Variables $fakeVariables -Scope 'build:1' -SourceKind 'Build' -LocalCredentials $credentials)
    $normalPlain = $normalRows | Where-Object name -eq 'appName'
    $normalSecret = $normalRows | Where-Object name -eq 'containerRegistryPassword'
    Add-TestResult -Name 'Lectura normal: conserva valor no secreto de Azure' `
        -Pass ($normalPlain.value -eq 'demo-api' -and -not $normalPlain.isSecret) `
        -Detail 'valor no secreto disponible'
    Add-TestResult -Name 'Lectura normal: secreto de Azure permanece nulo' `
        -Pass ($null -eq $normalSecret.value -and $normalSecret.valueStatus -eq 'secret-not-returned-by-azure-devops') `
        -Detail 'secreto enmascarado'

    $revealedRows = @(ConvertTo-AdoVariableRows -Variables $fakeVariables -Scope 'release:2' -SourceKind 'Release' -LocalCredentials $credentials -RevealSecrets)
    $revealedSecret = $revealedRows | Where-Object name -eq 'containerRegistryPassword'
    $protectedToken = $revealedRows | Where-Object name -eq 'token'
    Add-TestResult -Name 'Reveal: completa secreto por coincidencia exacta desde archivo local' `
        -Pass ($revealedSecret.value -eq $fakePassword -and $revealedSecret.valueStatus -eq 'resolved-from-local-file') `
        -Detail 'coincidencia exacta resuelta'
    Add-TestResult -Name 'Reveal: nunca revela la clave token' `
        -Pass ($null -eq $protectedToken.value -and $protectedToken.valueStatus -eq 'secret-not-returned-by-azure-devops') `
        -Detail 'token protegido'

    $localRows = @(ConvertTo-AdoLocalFileRows -LocalCredentials $credentials -RevealSecrets)
    $localToken = $localRows | Where-Object name -eq 'token'
    $localPassword = $localRows | Where-Object name -eq 'containerRegistryPassword'
    Add-TestResult -Name 'LocalFile: revela credencial solicitada pero nunca el token de autenticacion' `
        -Pass ($localPassword.value -eq $fakePassword -and $null -eq $localToken.value) `
        -Detail 'password ficticio visible; token ficticio oculto'

    $definitionWithGroups = [PSCustomObject]@{
        variableGroups = @(12, [PSCustomObject]@{ id = 13 })
        environments = @(
            [PSCustomObject]@{ variableGroups = @(13, 14) }
        )
    }
    $groupIds = @(Get-AdoReferencedVariableGroupIds -DefinitionBody $definitionWithGroups)
    Add-TestResult -Name 'Variable Groups referenciados: extrae ids y elimina duplicados' `
        -Pass (($groupIds -join ',') -eq '12,13,14') `
        -Detail ($groupIds -join ',')

    $normalOutput = & pwsh -NoProfile -File $readerPath -Kind LocalFile -CredentialFile $fakeCredentialFile 2>&1 | Out-String
    Add-TestResult -Name 'E2E LocalFile normal: la salida no contiene ningun valor ficticio' `
        -Pass ($normalOutput -notmatch [regex]::Escape($fakeToken) -and $normalOutput -notmatch [regex]::Escape($fakePassword)) `
        -Detail 'sin valores en stdout'

    $revealOutput = & pwsh -NoProfile -File $readerPath -Kind LocalFile -CredentialFile $fakeCredentialFile -RevealLocalSecrets 2>&1 | Out-String
    Add-TestResult -Name 'E2E LocalFile reveal: muestra password ficticio y sigue ocultando token ficticio' `
        -Pass ($revealOutput -match [regex]::Escape($fakePassword) -and $revealOutput -notmatch [regex]::Escape($fakeToken)) `
        -Detail 'revelacion selectiva correcta'
}
finally {
    Remove-Item Env:\ADO_VARIABLE_READER_TEST_MODE -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tmpRoot) {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force
    }
}

$results | Format-Table Name, Status, Detail -AutoSize
$failed = @($results | Where-Object Status -eq 'FAIL')
Write-Host "`nTotal: $($results.Count) - PASS: $($results.Count - $failed.Count) - FAIL: $($failed.Count)"
if ($failed.Count -gt 0) { exit 1 }
exit 0
