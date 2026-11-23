<#
Stub de `az` usado SOLO por run-script-tests.ps1 de analyze-azure-costs
(antepuesto al PATH del proceso de prueba via az.cmd en el mismo
directorio). Cero red, cero Azure real. Mismo patron que el stub de
manage-azure-resources, extendido con Cost Management/Monitor/Advisor.
#>

$argv = $args
$joined = ($argv -join ' ')

function Out-StubJson {
    param($Object)
    ($Object | ConvertTo-Json -Depth 20 -Compress) | Write-Output
    exit 0
}

if ($argv -contains '__FAIL__' -or $joined -match '__FAIL__' -or $joined -match 'fail429marker|fail401marker|fail403marker|fail5xxmarker') {
    [Console]::Error.WriteLine('az-stub: fallo forzado simulando 401/403/429/5xx (sin exponer headers reales).')
    exit 1
}

if ($argv[0] -eq 'version') {
    Out-StubJson @{ 'azure-cli' = '2.61.0'; 'azure-cli-core' = '2.61.0' }
}

if ($joined -match '^account show') {
    $subIdx = [array]::IndexOf($argv, '--subscription')
    $requestedSub = if ($subIdx -ge 0 -and ($subIdx + 1) -lt $argv.Count) { $argv[$subIdx + 1] } else { '69dc43ec-5f24-4203-9239-a8d0f8506d44' }
    $returnedId = if ($requestedSub -eq 'mismatch-test-sub') { 'different-sub-id-stub' } else { $requestedSub }
    Out-StubJson @{
        tenantId        = 'tenant-grupo-montecristo-stub'
        id              = $returnedId
        name            = 'Hospital Metropolitano (stub)'
        isDefault       = $true
        environmentName = 'AzureCloud'
        user            = @{ name = 'tester@example.com'; type = 'user' }
    }
}

if ($joined -match '^graph query') {
    Out-StubJson @{
        data = @(
            @{ id = '/subscriptions/69dc43ec-5f24-4203-9239-a8d0f8506d44/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm1'; name = 'vm1'; type = 'Microsoft.Compute/virtualMachines'; resourceGroup = 'rg1'; location = 'eastus'; tags = @{ env = 'prod' } }
        )
    }
}
if ($joined -match '^resource list') {
    Out-StubJson @(@{ id = '/subscriptions/69dc43ec-5f24-4203-9239-a8d0f8506d44/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm1'; name = 'vm1'; type = 'Microsoft.Compute/virtualMachines' })
}
if ($joined -match '^lock list') { Out-StubJson @() }
if ($joined -match '^monitor activity-log list') { Out-StubJson @() }
if ($joined -match '^role assignment list') { Out-StubJson @() }

if ($joined -match '^monitor metrics list') {
    Out-StubJson @{
        value = @(
            @{
                name       = @{ value = 'Percentage CPU' }
                unit       = 'Percent'
                timeseries = @(
                    @{ data = @(
                        @{ timeStamp = '2026-09-01T00:00:00Z'; Average = 12.5 }
                        @{ timeStamp = '2026-09-01T01:00:00Z'; Average = 18.2 }
                    ) }
                )
            }
        )
    }
}

if ($joined -match '^advisor recommendation list') {
    Out-StubJson @(
        @{
            resourceMetadata   = @{ resourceId = '/subscriptions/69dc43ec-5f24-4203-9239-a8d0f8506d44/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm1' }
            impact             = 'Medium'
            shortDescription   = @{ problem = 'VM sobredimensionada'; solution = 'Reducir SKU' }
            extendedProperties = @{ annualSavingsAmount = '1200'; currency = 'USD' }
        }
    )
}

if ($joined -match '^consumption reservation summary list') {
    [Console]::Error.WriteLine('az-stub: reservation-order-id placeholder no existe (fallo esperado por diseno).')
    exit 1
}

# ---- Cost Management (rest --method post|get) ----
if ($joined -match 'rest --method post' -and $joined -match 'costmanagement/(query|forecast)') {

    # NOTA: cada fila se antepone con el operador coma unario (,@(...)) --
    # sin el, PowerShell aplana un array-de-arrays al recolectarlo dentro
    # de @(), incluso con una sola fila (bug real encontrado y corregido
    # durante la construccion de este stub).
    if ($joined -match 'paginatemarker') {
        Out-StubJson @{
            properties = @{
                columns  = @(@{ name = 'ServiceName' }, @{ name = 'Cost' }, @{ name = 'Currency' })
                rows     = @(, @('Storage', 10.5, 'USD'))
                nextLink = 'https://management.azure.com/stub-nextpage-marker'
            }
        }
    }
    elseif ($joined -match 'multicurrencymarker') {
        Out-StubJson @{
            properties = @{
                columns = @(@{ name = 'ServiceName' }, @{ name = 'Cost' }, @{ name = 'Currency' })
                rows    = @(
                    , @('Storage', 10.5, 'USD')
                    , @('Compute', 20.0, 'EUR')
                )
            }
        }
    }
    elseif ($joined -match 'amortizedcost') {
        Out-StubJson @{
            properties = @{
                columns = @(@{ name = 'ServiceName' }, @{ name = 'Cost' }, @{ name = 'Currency' })
                rows    = @(, @('Reserved VM Instances', 300.0, 'USD'))
            }
        }
    }
    elseif ($joined -match 'test-resourceid-marker') {
        Out-StubJson @{
            properties = @{
                columns = @(@{ name = 'Cost' }, @{ name = 'Currency' })
                rows    = @(, @(137.11, 'USD'))
            }
        }
    }
    elseif ($joined -match 'costmanagement/forecast') {
        Out-StubJson @{
            properties = @{
                columns = @(@{ name = 'UsageDate' }, @{ name = 'Cost' }, @{ name = 'Currency' })
                rows    = @(, @(20260930, 150.0, 'USD'))
            }
        }
    }
    else {
        Out-StubJson @{
            properties = @{
                columns = @(@{ name = 'ServiceName' }, @{ name = 'Cost' }, @{ name = 'Currency' })
                rows    = @(
                    , @('Virtual Machines', 120.75, 'USD')
                    , @('Storage', 45.10, 'USD')
                    , @('Networking', 12.30, 'USD')
                )
            }
        }
    }
}

if ($joined -match 'rest --method get' -and $joined -match 'nextpage-marker') {
    Out-StubJson @{
        properties = @{
            rows     = @(, @('Networking', 5.25, 'USD'))
            nextLink = $null
        }
    }
}

# Default generico.
Out-StubJson @{}
