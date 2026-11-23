# Aplicación, readback y rollback

Cargar al aplicar un plan ya aprobado, hacer el readback posterior, o
preparar un rollback.

## Fase 1 — aplicación no destructiva (`Apply-AzureChangePlan.ps1`)

Único script que ejecuta `create`/`update`/`action` reales. Exige, en
orden, o rechaza sin tocar Azure:

1. `plan.validated == true` (escrito por `Test-AzureChangePlan.ps1`).
2. `validationHash` coincide con el contenido actual del plan.
3. `tenantId` de la sesión activa de `az` coincide con el del plan.
4. Ningún inventario referenciado cambió desde la validación (drift).

Cada operación se ejecuta únicamente vía el `executor` declarado
(`azureCli`/`armDeployment`/`armRest`) usando `argv` tokenizado. Se
registra en el journal (`.local/azure/executions/<validationHash>.json`)
bajo lock exclusivo — una operación `succeeded` nunca se reintenta
automáticamente. Sin rollback automático: si una operación falla, el
script se detiene y reporta exactamente qué se aplicó hasta ahí.

**Nunca ejecuta `pendingDeleteOperations`** — si el plan tiene
eliminaciones pendientes, solo lo reporta como nota informativa.

## Fase 2 — aprobación destructiva (siempre separada)

Ver `.claude/rules/azure/authorization.md` § Aprobación de eliminaciones.
Antes de `Apply-AzureDeletePlan.ps1`: revalidar inventario/locks/
dependencias, mostrar el lote destructivo exacto (resource IDs, no solo
conteo), pedir la aprobación destructiva correspondiente.

## Fase 3 — aplicación destructiva (`Apply-AzureDeletePlan.ps1`)

Único script que ejecuta `delete` reales. Exige, además de lo de la Fase
1: `-OperationIds` debe enumerar **exactamente** el mismo conjunto de
`operationId` de `pendingDeleteOperations` que se va a ejecutar — ni un
subconjunto distinto al aprobado, ni un id adicional (rechaza si falta o
sobra alguno). Un Resource Group completo nunca comparte lote con otra
eliminación, revalidado aquí incluso si el plan se armó a mano.

Antes de cada DELETE real: escribe un respaldo de solo lectura
(`az resource show --ids <id>`) en `.local/azure/backups/` — un respaldo
fallido o vacío detiene ESA operación sin borrar nada.

## Readback (`Test-AzurePostChange.ps1`)

Se corre después de cualquier Apply (no destructivo o destructivo) — no
requiere aprobación nueva (ya cubierta por la del plan). Vuelve a
consultar (`az resource show`) cada `resourceId` del plan y compara
`existsNow` contra lo esperado (`destructive` invertido) — reporta
`mismatchCount`/`allMatch`. Un mismatch no se "arregla" automáticamente:
se reporta al usuario y, si hace falta una corrección, es un plan nuevo.

## Rollback (`New-AzureRollbackPlan.ps1`)

**Nunca automático** — un rollback también puede tener impacto real. Este
script solo prepara y MUESTRA una propuesta:

- `create` → inverso sugerido: `delete` (con su propio respaldo
  automático al aplicarse).
- `update` → inverso sugerido: `update` restaurando `currentState`
  original — el `argv` real queda marcado `__PENDIENTE__` porque el
  script no puede inferir el comando exacto de restauración; hay que
  completarlo a mano antes de validar.
- `action` (ej. reiniciar un recurso) → sin inverso automático seguro,
  queda listado en `noAutomaticInverse` para resolución manual.

El borrador de rollback tiene `inventoryHashes` vacío a propósito — antes
de poder validarlo hace falta capturar inventario fresco
(`Get-AzureInventory.ps1`), completar cualquier `argv` `__PENDIENTE__`,
correr `Test-AzureChangePlan.ps1`, y pedir una aprobación **nueva y
separada** de la del plan original — nunca se reutiliza la aprobación que
cubrió el cambio que se está revirtiendo.

## Estados del journal

`pending`, `in-progress`, `succeeded`, `failed-before-write`,
`failed-after-write`, `ambiguous`, `skipped-already-desired`,
`blocked-drift`, `blocked-deviation`. `failed-before-write` puede
reintentarse si `retryPolicy` lo permite; `failed-after-write` y
`ambiguous` exigen readback antes de decidir cualquier cosa; un DELETE
`ambiguous` nunca se reemite automáticamente.
