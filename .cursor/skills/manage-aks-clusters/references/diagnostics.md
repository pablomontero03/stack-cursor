# Diagnóstico — AKS

Guía operativa para `aks-diagnoser`. Modo de solo lectura siempre — una
corrección propuesta se deriva al flujo de `change-workflow.md`, nunca se
aplica desde aquí.

## Orden recomendado por tipo de síntoma

### Pod no arranca / `CrashLoopBackOff` / `ImagePullBackOff`

1. `kubectl describe pod` — eventos y estado de contenedores.
2. `kubectl logs` (y `--previous` si ya reinició).
3. Si `ImagePullBackOff`: revisar `imagePullSecrets`, nombre/tag de la
   imagen, y si el registry es accesible desde el node pool.
4. Si `CrashLoopBackOff`: separar la causa real (el proceso del
   contenedor falla) de los reinicios que genera después — el primer
   evento/log es la causa, el resto es efecto.

### Pod en `Pending`

1. `kubectl describe pod` — sección de eventos suele indicar la razón
   exacta (`FailedScheduling`).
2. Revisar `resources.requests` vs. capacidad disponible en los nodos
   (`kubectl top nodes`, `kubectl describe nodes`).
3. Revisar taints/tolerations y node affinity/anti-affinity.
4. Revisar `PodDisruptionBudget` si el pod es parte de un rolling update.
5. Si hay autoscaler configurado, revisar eventos de scale-up recientes
   (puede estar esperando un nodo nuevo).

### Deployment no progresa (`Progressing=False`)

1. `kubectl rollout status deployment/<nombre>`.
2. `kubectl describe deployment` — revisar `Conditions` y el ReplicaSet
   más reciente.
3. Comparar con la revisión anterior (`kubectl rollout history`) si el
   problema empezó con un despliegue reciente.

### Servicio no responde / conectividad

1. `kubectl get endpoints` — confirma si el Service tiene pods backend
   sanos.
2. Revisar `selector` del Service vs. `labels` de los pods.
3. `NetworkPolicy` aplicables al namespace/pod.
4. DNS interno: resolución del nombre del Service desde otro pod
   (`nslookup`/`getent hosts` vía `kubectl exec`, que requiere
   aprobación).
5. Si hay Cilium/Hubble disponible, revisar flujos denegados.

### Ingress no enruta

1. `kubectl describe ingress` — reglas, backend, certificado TLS.
2. Estado del Ingress Controller (pods, logs).
3. Certificado: vigencia, `secretName` referenciado existe.

### Almacenamiento

1. `kubectl get pvc` — estado `Bound`/`Pending`.
2. `kubectl describe pvc` — eventos de provisioning.
3. `StorageClass` referenciada existe y tiene un provisioner sano.

### Autoscaling (HPA/cluster autoscaler)

1. `kubectl describe hpa` — métricas actuales vs. objetivo.
2. Eventos del cluster autoscaler (namespace `kube-system`, si está
   expuesto) para ver por qué no escaló o por qué demoró.

### Nodos

1. `kubectl get nodes` — condiciones (`Ready`, `MemoryPressure`,
   `DiskPressure`, `PIDPressure`).
2. `kubectl describe node` — capacidad vs. allocatable vs. uso real.
3. Versión de kubelet vs. control plane (desalineación puede causar
   comportamiento inesperado).

## Reglas del agente

- Nunca ejecutar un comando de escritura, ni siquiera uno de bajo riesgo
  percibido (ej. un `rollout restart` "para probar").
- Separar siempre causa raíz de efectos secundarios en cascada.
- Si la evidencia disponible no alcanza para confirmar una causa raíz,
  decirlo explícitamente y proponer qué comando adicional (de solo
  lectura) ayudaría — no adivinar.
- Toda corrección propuesta queda marcada como pendiente de aprobación vía
  `aks-operator` / `change-workflow.md`.
