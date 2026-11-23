<#
Valida, de solo lectura, si un Deployment tiene margen de capacidad para
completar un rollout antes de desplegar -- allocatable.pods/maxPods, pods
no terminales por nodo, y capacidad temporal requerida por
replicas/maxSurge/maxUnavailable (ver
references/capacity-validation.md). Nunca escribe nada.

Dos modos de entrada, mutuamente excluyentes:

  -Live: consulta nodos, pods y el Deployment en vivo via kubectl contra
  -Context/-Namespace/-DeploymentName (y opcionalmente -KubeconfigPath).

  -NodesJsonPath/-PodsJsonPath/-DeploymentJsonPath: usa JSON ya obtenido
  (fixtures de prueba, o una exportacion previa) -- cero llamadas de red.
  Este es el modo usado por las pruebas offline de este dominio.

Uso (fixtures, sin cluster real):
  powershell -File .\Test-AksDeploymentCapacity.ps1 -NodesJsonPath nodes.json -PodsJsonPath pods.json -DeploymentJsonPath deploy.json

Uso (en vivo, solo lectura):
  powershell -File .\Test-AksDeploymentCapacity.ps1 -Live -Context <ctx> -Namespace <ns> -DeploymentName <nombre> -KubeconfigPath <ruta>
#>

param(
    [switch]$Live,

    [string]$NodesJsonPath,
    [string]$PodsJsonPath,
    [string]$DeploymentJsonPath,

    [string]$Context,
    [string]$Namespace,
    [string]$DeploymentName,
    [string]$KubeconfigPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Aks-Common.ps1')

function Read-AksJsonInput {
    param([Parameter(Mandatory)] [string]$Path, [Parameter(Mandatory)] [string]$Label)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Test-AksDeploymentCapacity rechazado: no existe el archivo $Label indicado por '$Path'."
    }
    $raw = Get-Content -LiteralPath $Path -Raw
    try { return $raw | ConvertFrom-Json }
    catch { throw "Test-AksDeploymentCapacity rechazado: '$Path' ($Label) no es JSON valido." }
}

if ($Live) {
    if (-not $Context -or -not $Namespace -or -not $DeploymentName) {
        throw "Test-AksDeploymentCapacity rechazado: -Live exige -Context, -Namespace y -DeploymentName."
    }
    $connArgs = Get-AksKubectlConnectionArgs -Context $Context -KubeconfigPath $KubeconfigPath
    $nodesRaw = & kubectl get nodes -o json @connArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Test-AksDeploymentCapacity rechazado: 'kubectl get nodes' fallo: $nodesRaw" }
    $podsRaw = & kubectl get pods -n $Namespace -o json @connArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Test-AksDeploymentCapacity rechazado: 'kubectl get pods' fallo: $podsRaw" }
    $deploymentRaw = & kubectl get deployment $DeploymentName -n $Namespace -o json @connArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Test-AksDeploymentCapacity rechazado: 'kubectl get deployment' fallo: $deploymentRaw" }

    $nodes = ($nodesRaw | Out-String | ConvertFrom-Json).items
    $pods = ($podsRaw | Out-String | ConvertFrom-Json).items
    $deployment = $deploymentRaw | Out-String | ConvertFrom-Json
}
else {
    if (-not $NodesJsonPath -or -not $PodsJsonPath -or -not $DeploymentJsonPath) {
        throw "Test-AksDeploymentCapacity rechazado: sin -Live, son obligatorios -NodesJsonPath, -PodsJsonPath y -DeploymentJsonPath."
    }
    $nodesDoc = Read-AksJsonInput -Path $NodesJsonPath -Label 'de nodos'
    $podsDoc = Read-AksJsonInput -Path $PodsJsonPath -Label 'de pods'
    $deployment = Read-AksJsonInput -Path $DeploymentJsonPath -Label 'del Deployment'

    $nodes = if ($nodesDoc.items) { $nodesDoc.items } else { $nodesDoc }
    $pods = if ($podsDoc.items) { $podsDoc.items } else { $podsDoc }
}

$assessment = Get-AksCapacityAssessment -Nodes @($nodes) -Pods @($pods) -Deployment $deployment

$report = [PSCustomObject]@{
    generatedAtUtc     = (Get-Date).ToUniversalTime().ToString('o')
    source             = if ($Live) { 'live' } else { 'fixtures' }
    deploymentName     = if ($DeploymentName) { $DeploymentName } else { [string]$deployment.metadata.name }
    namespace          = if ($Namespace) { $Namespace } else { [string]$deployment.metadata.namespace }
    assessment         = $assessment
    classification     = if ($assessment.capacityOk) { 'capacidad-suficiente' } else { 'capacidad-insuficiente' }
}

$report | ConvertTo-Json -Depth 10
