# Flujo de cambio — AKS

Flujo obligatorio para cualquier modificación real de un clúster,
implementado por los scripts de `scripts/` y orquestado por
`aks-operator`.

## Flujo completo (lote atómico)

1. **Identificar alcance explícito**: suscripción, resource group,
   clúster, contexto, namespace, recurso(s) exacto(s). Confirmar el
   contexto real con `kubectl config current-context` — nunca asumirlo.
2. **Inventario de lectura**: `Get-AksInventory.ps1` sobre el contexto/
   namespace afectado.
3. **Verificar permisos**: `kubectl auth can-i <verbo> <recurso> -n
   <namespace>` para cada operación planeada. Si falta acceso, reportar
   exactamente el permiso faltante y detenerse — nunca proponer un cambio
   de RBAC como efecto colateral (eso es, en sí mismo, un cambio que
   requiere su propia aprobación).
4. **Respaldo previo sanitizado**: para toda eliminación (obligatorio,
   `Apply-AksChangePlan.ps1` lo hace automáticamente antes de cualquier
   `delete`) y recomendado para cualquier otro cambio destructivo, en
   `.local/aks/backups/`.
5. **Generar plan inmutable**: `New-AksChangePlan.ps1` — produce un JSON
   con `operations`/`approvedOperations` (el mismo lote completo, sin
   diferencias) y campos de impacto obligatorios (`whatChanges`,
   `whatDoesNotChange`, `dependencies`, `possibleDowntime`,
   `verificationStrategy`, `rollbackStrategy`).
6. **`kubectl diff` o `--dry-run=server`**: cuando la operación lo
   soporte, correrlo y pasar `-DiffPerformed`/`-DryRunPerformed` a
   `Test-AksChangePlan.ps1`. No es bloqueante si se omite, pero
   `Test-AksChangePlan.ps1` emite una advertencia — preferir siempre
   correrlo cuando sea posible.
7. **Validación independiente**: `Test-AksChangePlan.ps1` — rechaza el
   plan si tiene secretos embebidos, campos de impacto incompletos, una
   eliminación sin `requiresBackup=true`, `approvedOperations` distinto de
   `operations`, o evidencia de inventario vieja/faltante/de otro
   contexto. Si pasa, escribe `validated=true` + `validationHash`
   (SHA-256 canónico) + `validationEvidence` de vuelta al mismo archivo.
8. **Mostrar al usuario, antes de pedir aprobación**: qué cambia, qué no
   cambia, dependencias, posible indisponibilidad, alcance del impacto,
   estrategia de verificación, estrategia de rollback — todo ya está en
   `plan.impact`, solo hace falta presentarlo.
9. **Invocar `Apply-AksChangePlan.ps1`** en el mismo turno que se presenta
   el plan — la tarjeta nativa que el hook fuerza por el nombre del script
   es la única aprobación necesaria. No pedir un "sí" textual separado
   antes.
10. **El hook muestra una sola tarjeta para el lote completo** — no hay
    pregunta por cada operación individual dentro de ese mismo plan
    aprobado.
11. **Tras aprobar**: `Apply-AksChangePlan.ps1` reconfirma que el
    contexto actual coincide con `plan.cluster.context` (si cambió, se
    rechaza sin tocar nada), ejecuta únicamente las
    `approvedOperations` de ese plan, y registra cada una en el journal
    de `.local/aks/executions/<validationHash>.json` bajo lock exclusivo
    de archivo. Si una operación falla, se detiene ahí — nunca rollback
    automático ni reintento sin nueva aprobación.
12. **Readback**: `Test-AksPostChange.ps1` — `get`, `rollout status`
    cuando corresponde, eventos recientes, y (para una eliminación)
    confirmación de que el recurso ya no existe.
13. **Memoria**: actualizar `.claude/agent-memory/aks-operator/` solo si
    surgió un aprendizaje reutilizable (nunca solo porque el cambio
    ocurrió).

## Variante: cambio chico sin plan formal

Para un cambio pequeño y acotado, es válido saltear `New-`/
`Test-AksChangePlan.ps1` y ejecutar directo con kubectl/Helm/MCP, pero
igual:

- Pedir aprobación explícita antes de ejecutar.
- Mostrar contexto, namespace, comando y recurso exactos en esa
  solicitud.
- Hacer readback después (aunque sea un `kubectl get` puntual).
- No convertirse en una pregunta por cada comando interno de esa misma
  operación chica — una aprobación cubre el cambio completo si ya se
  enumeró.

## Eliminaciones

Nunca cubiertas por la aprobación de otro cambio, ni agrupadas entre sí
aunque sean del mismo tipo o mismo namespace. Antes de pedir la
aprobación, mostrar: contexto y clúster, namespace, tipo y nombre exacto,
selectores usados (si los hay), dependencias, política de propagación
(`--cascade=orphan|foreground|background`), volúmenes/datos persistentes
afectados, y la ruta del respaldo ya escrito. Comandos amplios (`--all`,
`--all-namespaces`, namespaces/CRDs/PV-PVC/operadores/webhooks/RBAC/
recursos de sistema) producen una advertencia reforzada en la tarjeta,
pero siguen resolviendo a aprobación — nunca a un bloqueo automático por
sí solos.

## Reintentos

Un reintento de una operación fallida exige una aprobación nueva — el
journal marca la operación fallida como `ambiguous`, nunca la reintenta
en silencio, y `Start-AksJournaledOperation` no vuelve a ejecutar algo que
ya esté en `succeeded`/`in-progress`/`ambiguous`.
