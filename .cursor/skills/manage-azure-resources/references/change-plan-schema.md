# Esquema del plan de cambio

Cargar al armar (`New-AzureChangePlan.ps1`) o revisar un plan antes de
validarlo. Esquema exacto — no se simplifica ni se le quitan campos (ver
`INSTRUCCIONES-AUTOMATIZACION-AZURE.md` § Esquema del plan Azure, la
fuente original).

## Plan (nivel raíz)

```json
{
  "schemaVersion": 1,
  "planId": "guid",
  "createdAtUtc": "iso8601",
  "ownerTranscriptId": "string|null",
  "tenantId": "string",
  "subscriptionId": "string",
  "inventoryHashes": [{ "path": "string", "hash": "sha256" }],
  "approvedOperations": [ /* operaciones no destructivas */ ],
  "pendingDeleteOperations": [ /* operaciones destructivas */ ],
  "impactAndCostAnalysis": "string",
  "validated": false,
  "validationHash": null,
  "validationEvidence": null,
  "reviewStatus": "not-reviewed"
}
```

## Operación (cada elemento de `approvedOperations` / `pendingDeleteOperations`)

23 campos obligatorios — `New-AzureChangePlan.ps1` rechaza cualquier
operación a la que le falte alguno:

```json
{
  "operationId": "string",
  "phase": "nonDestructive|destructive",
  "action": "create|update|action|delete",
  "tenantId": "string",
  "subscriptionId": "string",
  "resourceGroup": "string|null",
  "resourceId": "string",
  "resourceType": "string",
  "apiVersion": "string|null",
  "executor": "azureCli|armDeployment|armRest",
  "argv": [],
  "bodyHash": "string|null",
  "preconditionHash": "string",
  "currentState": {},
  "desiredState": {},
  "dependencies": [],
  "destructive": false,
  "reversible": true,
  "backupStrategy": "string",
  "rollbackStrategy": "string",
  "verification": [],
  "retryPolicy": { "maxAttempts": 1, "retryableCodes": [], "delaySeconds": 0 },
  "timeoutSeconds": 600,
  "expectedFinalState": "string"
}
```

- `argv`: SIEMPRE un array tokenizado (ej. `["storage","account","create",
  "-n","st1","-g","rg1"]`) — nunca un string de shell crudo. Esto evita
  sustituciones, pipes, redirecciones o inyección de comandos no aprobada.
  `Test-AzureChangePlan.ps1` bloquea cualquier `argv` que no sea array.
- `executor`: `azureCli` (comando `az` directo), `armDeployment` (`az
  deployment ... create`), o `armRest` (`az rest ...` — `argv[0]` debe ser
  literalmente `'rest'`).
- `destructive`: debe coincidir con dónde vive la operación —
  `approvedOperations` nunca contiene `destructive: true`
  (`New-AzureChangePlan.ps1` y `Apply-AzureChangePlan.ps1` lo rechazan);
  `pendingDeleteOperations` siempre lo requiere `true`.
- Un Resource Group completo (`resourceType =
  'Microsoft.Resources/resourceGroups'`, `action = 'delete'`) nunca puede
  compartir `pendingDeleteOperations` con otra eliminación — enforced en 3
  capas (ver `.cursor/rules/azure.mdc`).

## `New-AzureChangePlan.ps1`

- `-Operations` (no destructivas) y `-PendingDeleteOperations`
  (destructivas) son ambos opcionales (default `@()`) — un plan puede ser
  puramente de eliminaciones, puramente de creación/actualización, o
  mixto. `Test-AzureChangePlan.ps1` bloquea un plan sin ninguna operación
  en absoluto.
- `-InventoryPaths` obligatorio: al menos un inventario ya capturado con
  `Get-AzureInventory.ps1`, cuyo hash queda registrado en
  `inventoryHashes`.
- No valida (eso es `Test-AzureChangePlan.ps1`) — solo arma el JSON con la
  forma correcta y rechaza duplicados de `operationId` o inconsistencias
  obvias (RG completo mezclado con otra eliminación, `destructive`
  desalineado con dónde vive la operación).

## `Test-AzureChangePlan.ps1` — bloqueantes

1. Secretos: `Find-AzureSensitiveJsonProperties` (por nombre de propiedad)
   + `Find-AzureSensitiveRawText` (regex sobre el texto crudo del
   archivo) — cualquier hallazgo bloquea. Ver
   `references/secrets-rbac-locks.md`.
2. Forma: los 23 campos obligatorios de cada operación, `argv` como
   array, `tenantId`/`subscriptionId` de cada operación coincidiendo con
   los del plan.
3. Aislamiento de Resource Group completo en `pendingDeleteOperations`.
4. Drift de inventario: cada `inventoryHashes[].hash` debe coincidir con
   el hash actual del archivo en disco.

Si pasa sin bloqueantes, marca `validated = true` y calcula
`validationHash` (SHA-256 canónico, excluyendo
`validated`/`validationHash`/`validationEvidence`/`reviewStatus`) —
cualquier edición posterior del plan invalida ese hash.

## Impacto y costo

`-ImpactAndCostAnalysis` (texto libre) documenta, antes de pedir
aprobación: qué cambia, qué no cambia, posible indisponibilidad, efecto
estimado en costo, y evidencia de what-if/diff
(`Invoke-AzureWhatIf.ps1`) — la tarjeta de aprobación de
`ExitPlanMode` debe incluir este resumen, no solo los comandos exactos.
