# Debugging — aks-operator

Sin entradas todavía. Registrar aquí, cuando ocurran, síntoma observado,
causa raíz confirmada, evidencia usada, solución validada, comprobación
segura, y falsos positivos o intentos que no funcionaron — solo
aprendizajes reutilizables, nunca incidentes transitorios sin valor
futuro. Nunca guardar kubeconfigs, secretos ni salidas sensibles sin
sanitizar.

## Clúster k3s dev (`srv-desarrollo-5`) — límite de 110 pods por nodo bloquea rollouts

Confirmado 2026-09-07 verificando `directory-web` (buklo-web) en namespace
`uat` de este mismo clúster de un solo nodo. Síntoma: Deployment recién
desplegado por el pipeline (Build 634/Release 389) quedó con
`READY 1/1` engañoso en `kubectl get deploy` en un momento dado, pero
`status.replicas` (2) no coincidía con `spec.replicas` (1) y había un pod
nuevo `Pending` (`0/1`) sin nodo asignado mientras el pod de la revisión
anterior seguía `Running` (la estrategia `RollingUpdate` con
`maxUnavailable: 0` no libera el pod viejo hasta que el nuevo esté Ready).

Causa raíz: `kubectl describe pod <pod-nuevo>` mostró el evento
`FailedScheduling — 0/1 nodes are available: 1 Too many pods`.
`kubectl describe node srv-desarrollo-5` confirmó `Allocatable.pods: 110`
(límite default de kubelet, no ajustado en este nodo) con exactamente 110
pods no-terminados ya corriendo en el momento del intento de scheduling —
el clúster de un solo nodo estaba en el tope de su capacidad de pods (no
de CPU/memoria, que sí tenían margen).

Evidencia: `kubectl get pods -n <ns> -l app=<app> -o wide` (pod Pending
sin IP/nodo) + `kubectl describe pod` (evento FailedScheduling) +
`kubectl describe node <nodo>` (línea `pods:` en Capacity/Allocatable +
conteo de "Non-terminated Pods (N in total)").

Impacto: esto **no es específico de `directory-web`** — cualquier
Deployment nuevo o rollout (`RollingUpdate` con `maxSurge>=1`) en este
clúster puede quedar atascado de la misma forma si el conteo total de
pods del clúster ya está cerca de 110, independientemente del namespace o
la app. Antes de diagnosticar "por qué mi rollout no completa" en este
clúster, verificar primero capacidad de pods del nodo, no solo
CPU/memoria/imagen/probes.

Solución: no aplicada por esta memoria (tarea era de solo lectura, sin
aprobación para cambios). Opciones típicas para una sesión futura con
aprobación: reducir `maxSurge` a 0 con `maxUnavailable: 1` para este tipo
de rollout en un clúster de un solo nodo, limpiar pods completados/
obsoletos que no aporten, o (cambio de infraestructura, otro dominio)
aumentar `--max-pods` del kubelet si el nodo tiene margen real de CPU/
memoria para más pods.

**Actualización 2026-09-07 (mismo día, más tarde):** verificado en vivo
de nuevo (`kubectl describe node srv-desarrollo-5`) al preparar el ciclo
de `app-sso`: `Allocatable.pods` ahora es **200** (no 110), con 96
pods no-terminados → 104 slots libres. El límite de kubelet fue
levantado (o el conteo bajó) después del incidente de arriba — **no
asumir "110" como vigente sin volver a verificar `kubectl describe
node`**; este nodo cambia de configuración entre sesiones. La causa raíz
y el patrón de diagnóstico (revisar capacidad de pods antes que CPU/
memoria/imagen/probes en este clúster de un solo nodo) siguen siendo
válidos como conocimiento reutilizable.

Comprobación segura: `kubectl describe node <nodo> | Select-String
"pods:","Non-terminated"` y `kubectl get pods -n <ns> -o wide` para ver
si el pod nuevo sigue `Pending` — ambos de solo lectura, sin riesgo.
