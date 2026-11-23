<#
Pruebas offline de Test-AksDeploymentCapacity.ps1 / Get-AksCapacityAssessment
/ Get-AksRolloutClassification (Aks-Common.ps1). Usa unicamente fixtures
JSON en un directorio temporal propio -- nunca kubectl real, nunca un
cluster real.

Uso:
  powershell -NoProfile -ExecutionPolicy Bypass -File .\run-capacity-tests.ps1
#>

$ErrorActionPreference = 'Stop'
$scriptsRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $scriptsRoot 'Aks-Common.ps1')
$capacityScript = Join-Path $scriptsRoot 'Test-AksDeploymentCapacity.ps1'

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("aks-capacity-tests-{0}" -f ([Guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null

$results = [System.Collections.Generic.List[object]]::new()
function Add-Result {
    param([string]$Name, [bool]$Pass, [string]$Detail = '')
    $results.Add([PSCustomObject]@{ Name = $Name; Status = $(if ($Pass) { 'PASS' } else { 'FAIL' }); Detail = $Detail })
}

function New-TestNode {
    param(
        [string]$Name,
        [int]$AllocatablePods = 30,
        [hashtable]$Labels = @{},
        [array]$Taints = @(),
        [bool]$Ready = $true
    )
    return [PSCustomObject]@{
        metadata = [PSCustomObject]@{ name = $Name; labels = [PSCustomObject]$Labels }
        spec     = [PSCustomObject]@{ taints = $Taints }
        status   = [PSCustomObject]@{
            allocatable = [PSCustomObject]@{ pods = $AllocatablePods }
            conditions  = @([PSCustomObject]@{ type = 'Ready'; status = $(if ($Ready) { 'True' } else { 'False' }) })
        }
    }
}

function New-TestPod {
    param([string]$NodeName, [string]$Phase = 'Running')
    return [PSCustomObject]@{
        spec   = [PSCustomObject]@{ nodeName = $NodeName }
        status = [PSCustomObject]@{ phase = $Phase }
    }
}

function New-TestDeployment {
    param(
        [int]$Replicas = 3,
        $MaxSurge = '25%',
        $MaxUnavailable = '25%',
        [hashtable]$NodeSelector = $null
    )
    $spec = [ordered]@{
        replicas = $Replicas
        strategy = [PSCustomObject]@{ type = 'RollingUpdate'; rollingUpdate = [PSCustomObject]@{ maxSurge = $MaxSurge; maxUnavailable = $MaxUnavailable } }
        template = [PSCustomObject]@{ spec = [PSCustomObject]@{ nodeSelector = $(if ($NodeSelector) { [PSCustomObject]$NodeSelector } else { $null }); tolerations = @() } }
    }
    return [PSCustomObject]@{ metadata = [PSCustomObject]@{ name = 'test-deploy'; namespace = 'test-ns' }; spec = [PSCustomObject]$spec }
}

function Write-FixtureJson {
    param([string]$Name, $Object)
    $path = Join-Path $tmpRoot $Name
    ($Object | ConvertTo-Json -Depth 15) | Set-Content -LiteralPath $path -Encoding utf8
    return $path
}

# --- Escenario 9: nodo sin margen de pods para maxUnavailable=0 ---
# 1 solo nodo elegible con allocatable.pods=10 y 9 pods no terminales ya
# asignados -> freeSlots=1. Deployment con maxSurge=1 (absoluto) y
# maxUnavailable=0 -> requiere 1 slot libre; hay exactamente 1, asi que es
# el caso limite. Bajamos freeSlots a 0 agregando un pod mas para forzar
# insuficiencia real.
$node9 = New-TestNode -Name 'node-a' -AllocatablePods 10
$pods9 = @(1..10 | ForEach-Object { New-TestPod -NodeName 'node-a' })
$deploy9 = New-TestDeployment -Replicas 3 -MaxSurge 1 -MaxUnavailable 0

$nodesPath9 = Write-FixtureJson -Name 'nodes9.json' -Object @{ items = @($node9) }
$podsPath9 = Write-FixtureJson -Name 'pods9.json' -Object @{ items = $pods9 }
$deployPath9 = Write-FixtureJson -Name 'deploy9.json' -Object $deploy9

$reportJson9 = & $capacityScript -NodesJsonPath $nodesPath9 -PodsJsonPath $podsPath9 -DeploymentJsonPath $deployPath9 | Out-String
$report9 = $reportJson9 | ConvertFrom-Json

Add-Result 'Escenario 9: nodo lleno (0 slots libres) con maxUnavailable=0 -> capacidad insuficiente' `
    (-not $report9.assessment.capacityOk) "freeSlots=$($report9.assessment.availableFreeSlots) requerido=$($report9.assessment.requiredExtraPods)"
Add-Result 'Escenario 9: classification = capacidad-insuficiente' `
    ($report9.classification -eq 'capacidad-insuficiente') $report9.classification
Add-Result 'Escenario 9: reasons menciona maxUnavailable=0' `
    (@($report9.assessment.reasons) -join ' ' -match 'maxUnavailable=0') (@($report9.assessment.reasons) -join ' | ')

# --- Caso positivo de control: mismo nodo con margen suficiente ---
$node9b = New-TestNode -Name 'node-b' -AllocatablePods 30
$pods9b = @(1..5 | ForEach-Object { New-TestPod -NodeName 'node-b' })
$deploy9b = New-TestDeployment -Replicas 3 -MaxSurge 1 -MaxUnavailable 0
$nodesPath9b = Write-FixtureJson -Name 'nodes9b.json' -Object @{ items = @($node9b) }
$podsPath9b = Write-FixtureJson -Name 'pods9b.json' -Object @{ items = $pods9b }
$deployPath9b = Write-FixtureJson -Name 'deploy9b.json' -Object $deploy9b
$report9b = (& $capacityScript -NodesJsonPath $nodesPath9b -PodsJsonPath $podsPath9b -DeploymentJsonPath $deployPath9b | Out-String) | ConvertFrom-Json
Add-Result 'Control: nodo con margen amplio -> capacidad suficiente' `
    ($report9b.assessment.capacityOk) "freeSlots=$($report9b.assessment.availableFreeSlots)"

# --- nodeSelector: nodo que NO matchea queda excluido de la evaluacion ---
$nodeOther = New-TestNode -Name 'node-other' -AllocatablePods 100 -Labels @{ agentpool = 'default' }
$deploySelector = New-TestDeployment -Replicas 2 -NodeSelector @{ agentpool = 'userpool03' }
$nodesPathSel = Write-FixtureJson -Name 'nodes-sel.json' -Object @{ items = @($nodeOther) }
$podsPathSel = Write-FixtureJson -Name 'pods-sel.json' -Object @{ items = @() }
$deployPathSel = Write-FixtureJson -Name 'deploy-sel.json' -Object $deploySelector
$reportSel = (& $capacityScript -NodesJsonPath $nodesPathSel -PodsJsonPath $podsPathSel -DeploymentJsonPath $deployPathSel | Out-String) | ConvertFrom-Json
Add-Result 'nodeSelector: nodo que no matchea el pool declarado queda excluido (0 nodos elegibles)' `
    ($reportSel.assessment.eligibleNodeCount -eq 0) "eligibleNodeCount=$($reportSel.assessment.eligibleNodeCount)"

# --- Escenario 10: Build/Release exitosos pero rollout incompleto ---
$classification10 = Get-AksRolloutClassification -DesiredReplicas 3 -UpdatedReplicas 3 -ReadyReplicas 2 -AvailableReplicas 2 -ExpectedImage 'acr.example.com/app:v2' -NewPodImages @('acr.example.com/app:v2', 'acr.example.com/app:v2') -PendingNewPods 1
Add-Result 'Escenario 10: rollout con 1 pod Pending clasifica Despliegue incompleto' `
    ($classification10.state -eq 'Despliegue incompleto') $classification10.state
Add-Result 'Escenario 10: version anterior sigue operativa (available>0, ready<updated)' `
    ($classification10.previousVersionServing) 'previousVersionServing'

$classificationOk = Get-AksRolloutClassification -DesiredReplicas 3 -UpdatedReplicas 3 -ReadyReplicas 3 -AvailableReplicas 3 -ExpectedImage 'acr.example.com/app:v2' -NewPodImages @('acr.example.com/app:v2', 'acr.example.com/app:v2', 'acr.example.com/app:v2') -PendingNewPods 0
Add-Result 'Control: rollout completo con todas las replicas Ready/Available clasifica Despliegue completado' `
    ($classificationOk.state -eq 'Despliegue completado') $classificationOk.state
Add-Result 'Control: rollout completo no marca version anterior como sirviendo trafico' `
    (-not $classificationOk.previousVersionServing) 'previousVersionServing'

$classificationFailed = Get-AksRolloutClassification -DesiredReplicas 3 -UpdatedReplicas 1 -ReadyReplicas 0 -AvailableReplicas 3 -ExpectedImage 'acr.example.com/app:v2' -NewPodImages @('acr.example.com/app:v1') -PendingNewPods 0
Add-Result 'Escenario: imagen nueva no coincide con la esperada -> no clasifica como completado' `
    ($classificationFailed.state -ne 'Despliegue completado') $classificationFailed.state

# =========================================================================
# Reporte final
# =========================================================================
$results | Format-Table -Property Name, Status -AutoSize | Out-String | Write-Host
$failed = @($results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ""
Write-Host "Total: $($results.Count) - PASS: $($results.Count - $failed.Count) - FAIL: $($failed.Count)" -ForegroundColor $(if ($failed.Count -eq 0) { 'Green' } else { 'Red' })
if ($failed.Count -gt 0) {
    foreach ($f in $failed) { Write-Host "- $($f.Name): $($f.Detail)" -ForegroundColor Red }
}

Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue

if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
