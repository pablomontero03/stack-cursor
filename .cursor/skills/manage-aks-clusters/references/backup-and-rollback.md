# Respaldo y rollback — AKS

## Respaldo previo

- **Obligatorio** para toda eliminación real: `Apply-AksChangePlan.ps1`
  escribe siempre `kubectl get <kind> <name> -n <ns> -o yaml` a
  `.local/aks/backups/<validationHash>-<operationId>.yaml` **antes** del
  `delete`. Un respaldo fallido o vacío detiene esa operación sin borrar
  nada — no configurable, no hay forma de "saltear" el respaldo.
- Recomendado (no bloqueante por el sistema, pero sí exigido por
  `aks-reviewer` al revisar el plan) para cualquier otro cambio
  destructivo (`patch`, `scale` hacia abajo, `rollout undo`).
- Los respaldos son texto YAML sanitizado — nunca deben contener el valor
  de un `Secret` referenciado (el manifiesto de un `Secret` en sí, si es
  el recurso que se está respaldando, se guarda con sus `data` intactos
  porque **es** el objeto que se está preservando para poder restaurarlo;
  esto es aceptable porque `.local/aks/backups/` no se versiona ni sale
  del disco local — nunca se imprime su contenido en la conversación).

## Rollback — nunca automático

`Invoke-AksRollback.ps1` solo **prepara y muestra** una propuesta —
jamás ejecuta nada. Ejecutar un rollback real vuelve a pasar por el flujo
completo (`New-AksChangePlan.ps1` → `Test-AksChangePlan.ps1` →
`Apply-AksChangePlan.ps1`) con una aprobación **nueva y separada** de la
del cambio original.

Estrategia según el tipo de cambio original:

| Cambio original | Estrategia de rollback |
|---|---|
| `delete` | `kubectl apply` del respaldo pre-delete (recrea el recurso tal como estaba) |
| `apply` / `patch` / `scale` / `label` / `annotate` | `kubectl rollout undo` si el recurso lo soporta, o reaplicar la revisión anterior conocida |
| `rollout-restart` | No hay "deshacer" en el sentido tradicional — un restart no cambia el manifiesto. Si el restart causó un problema, diagnosticar con `aks-diagnoser` antes de proponer nada |
| Cualquier otro | Definir la estrategia con el usuario antes de generar un plan de rollback |

## Reintentos tras un fallo

Si `Apply-AksChangePlan.ps1` se detiene a mitad de un lote (una operación
falló), las operaciones ya `succeeded` quedan aplicadas y las restantes
nunca se ejecutaron — no hay rollback automático de lo ya aplicado. El
journal marca la operación fallida como `ambiguous`. Reintentar exige:

1. Revisar el estado real del clúster (no asumir a partir del journal).
2. Decidir con el usuario si conviene reintentar la operación fallida,
   hacer rollback de lo ya aplicado, o ambos.
3. Cualquiera de esas dos rutas exige una aprobación nueva — nunca se
   reutiliza la aprobación original.
