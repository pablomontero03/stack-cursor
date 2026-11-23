# Validación de capacidad antes de un rollout

Cargar en modo `change` cuando el cambio es un despliegue/rollout (no para
un `patch`/`scale` puntual sin nueva imagen). Usado por
`orchestrate-application-pipeline-cycle` y por cualquier despliegue directo
de este dominio que necesite confirmar margen antes de escribir.

## Modos de descubrimiento previo al plan

Interpretación de `cluster_validation_before_plan` (nombre usado por la
skill coordinadora en su `INPUT.discovery`):

| Valor | Comportamiento antes de presentar el plan |
|---|---|
| `preguntar` | Una sola pregunta al inicio para elegir `completa`, `minima` u `omitir`. Las demás consultas de solo lectura continúan mientras se espera la respuesta. |
| `completa` | Consultar en vivo clústeres, contextos, namespaces, ingress IPs, node pools, labels, capacidad y recursos comparables. |
| `minima` | **Default recomendado.** Consultar únicamente los destinos declarados, namespaces, ingress IPs, node pools/selectors y la capacidad inmediata necesaria para completar el rollout. |
| `omitir` | No consultar clústeres durante la preparación del plan; marcar la sección AKS como `Pendiente de validación previa al despliegue`. Nunca bloquea las secciones de Azure DevOps, Cloudflare o código. |

Esta elección afecta solo el descubrimiento **previo al plan**.
Inmediatamente antes de cualquier despliegue real, sin importar el modo
elegido, siempre se ejecuta una verificación mínima de solo lectura y sin
aprobación adicional — es la que implementa este documento y el script
`Test-AksDeploymentCapacity.ps1`.

## Qué confirma la verificación mínima previa a cada despliegue

- Suscripción, clúster y contexto objetivo (contra el plan aprobado).
- Namespace objetivo.
- IP o ingress objetivo, cuando aplique.
- Existencia y compatibilidad del node pool/selector declarado.
- Capacidad de pods por nodo elegible: `allocatable.pods`/`maxPods` menos
  pods no terminales ya asignados = margen libre.
- Capacidad temporal requerida por la estrategia de rollout: `replicas`,
  `maxSurge` y `maxUnavailable`. Con `maxUnavailable: 0`, el/los pod(s)
  nuevo(s) deben poder programarse **antes** de retirar cualquier pod
  anterior.
- Pods `Pending` y eventos recientes de scheduling (`Too many pods`,
  recursos insuficientes, taints o afinidad incompatible).
- CPU y memoria solicitadas frente a capacidad asignable, cuando el dato
  esté disponible.
- Permisos efectivos (`kubectl auth can-i`) para las operaciones del plan.
- Que el destino no cambió respecto del plan aprobado.

## Antigüedad máxima de la comprobación

Nunca reutilizar como vigente una comprobación de capacidad dinámica. Debe
tener una antigüedad máxima configurable (el coordinador la expone como
`INPUT.execution.aks_capacity_validation_max_age_seconds`); si es más
antigua, refrescarla antes de escribir. Esto aplica incluso dentro de un
plan ya aprobado — refrescar la capacidad no es una operación nueva que
requiera aprobación, es parte de la verificación mínima obligatoria.

## Fórmula de `Get-AksCapacityAssessment` (`Aks-Common.ps1`)

Función pura, sin llamadas de red, para que sea 100% mockeable en
pruebas:

1. Resolver `maxSurge`/`maxUnavailable` desde
   `deployment.spec.strategy.rollingUpdate` (default Kubernetes `25%`
   cada uno si el Deployment no los declara); un valor `NN%` se redondea
   hacia arriba para `maxSurge` y hacia abajo para `maxUnavailable`
   (`ConvertTo-AksIntOrPercent`). Si ambos redondean a `0`, `maxSurge` se
   fuerza a `1` (mismo comportamiento que el controller de Kubernetes).
2. Filtrar nodos elegibles: `Ready=True`, coinciden con el
   `nodeSelector` del template, y no tienen un taint `NoSchedule`/
   `NoExecute` sin `toleration` correspondiente en el template.
3. Por cada nodo elegible: `freeSlots = allocatable.pods − pods no
   terminales asignados a ese nodo` (fase distinta de `Succeeded`/
   `Failed`).
4. `requiredExtraPods = maxSurge`. `capacityOk = true` únicamente si hay
   al menos 1 nodo elegible **y** la suma de `freeSlots` ≥
   `requiredExtraPods`.
5. Si `maxUnavailable = 0`, se agrega una advertencia explícita: los pods
   nuevos deben poder programarse antes de retirar cualquier pod
   anterior — no basta con `capacityOk = true` genérico, revisar también
   `perNode` para confirmar dónde exactamente hay margen.

`Test-AksDeploymentCapacity.ps1` envuelve esta función: en modo `-Live`
obtiene nodos/pods/Deployment vía `kubectl get ... -o json`; en modo
fixture (`-NodesJsonPath`/`-PodsJsonPath`/`-DeploymentJsonPath`) usa JSON
ya obtenido — es el modo que usan las pruebas offline
(`scripts/tests/run-capacity-tests.ps1`), sin cluster real.

## Clasificación del resultado del rollout

`Get-AksRolloutClassification` (`Aks-Common.ps1`) clasifica un readback ya
obtenido (réplicas `desired`/`updated`/`ready`/`available`, imagen
esperada vs. imágenes reales de los pods nuevos, pods `Pending`, timeout)
en uno de los 3 estados AKS de la tabla completa de
`orchestrate-application-pipeline-cycle/references/status-timing-and-memory.md`:
`Despliegue completado`, `Despliegue incompleto`, `Despliegue fallido` —
más el flag independiente `previousVersionServing` (la versión anterior
sigue respondiendo). Un pod `Pending` por `Too many pods` mientras la
versión anterior sigue sirviendo tráfico clasifica siempre como
`Despliegue incompleto` con `previousVersionServing = true`, nunca como
éxito.
