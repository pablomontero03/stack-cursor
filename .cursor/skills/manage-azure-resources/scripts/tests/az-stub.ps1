<#
Stub de `az` usado SOLO por run-script-tests.ps1 (antepuesto al PATH del
proceso de prueba via az.cmd en el mismo directorio). Cero red, cero Azure
real. Inspecciona los argumentos recibidos y devuelve JSON canned segun el
subcomando, para poder probar los scripts reales sin llamar a Azure.

Marcador especial: si algun argumento es literalmente '__FAIL__', termina
con exit 1 y un mensaje de error (simula un comando az real fallido).
#>

$argv = $args

if ($argv -contains '__FAIL__') {
    [Console]::Error.WriteLine('az-stub: fallo forzado por __FAIL__.')
    exit 1
}

function Out-StubJson {
    param($Object)
    ($Object | ConvertTo-Json -Depth 20 -Compress) | Write-Output
    exit 0
}

$joined = ($argv -join ' ')

if ($argv[0] -eq 'version') {
    Out-StubJson @{ 'azure-cli' = '2.61.0'; 'azure-cli-core' = '2.61.0' }
}

if ($joined -match '^account show') {
    Out-StubJson @{
        tenantId        = 'tenant-stub-0001'
        id              = 'sub-stub-0001'
        name            = 'Stub Subscription'
        isDefault       = $true
        environmentName = 'AzureCloud'
        user            = @{ name = 'tester@example.com'; type = 'user' }
    }
}

if ($joined -match '^graph query') {
    Out-StubJson @{
        data = @(
            @{ id = '/subscriptions/sub-stub-0001/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/st1'; name = 'st1'; type = 'Microsoft.Storage/storageAccounts'; resourceGroup = 'rg1'; location = 'eastus' }
        )
    }
}

if ($joined -match '^resource list') {
    Out-StubJson @(
        @{ id = '/subscriptions/sub-stub-0001/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/st1'; name = 'st1'; type = 'Microsoft.Storage/storageAccounts' }
    )
}

if ($joined -match '^lock list') { Out-StubJson @() }
if ($joined -match '^monitor activity-log list') { Out-StubJson @() }
if ($joined -match '^role assignment list') { Out-StubJson @() }

if ($joined -match '^resource show') {
    Out-StubJson @{
        id         = '/subscriptions/sub-stub-0001/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/st1'
        name       = 'st1'
        type       = 'Microsoft.Storage/storageAccounts'
        location   = 'eastus'
        properties = @{ provisioningState = 'Succeeded' }
    }
}

if ($joined -match '^resource delete') { Out-StubJson @{} }

if ($joined -match '^deployment group what-if') {
    Write-Output 'Resource and property changes are indicated with this symbol:\n  + Create\n\nScope: /subscriptions/sub-stub-0001/resourceGroups/rg1\n\n  + Microsoft.Storage/storageAccounts/st1 [2023-01-01]\n'
    exit 0
}

# Default generico: cualquier otro subcomando (create/update/etc. usado
# como executor azureCli en Apply-AzureChangePlan) responde exito vacio.
Out-StubJson @{}
