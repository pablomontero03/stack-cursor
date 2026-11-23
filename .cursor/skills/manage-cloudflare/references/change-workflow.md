# Flujo de cambio (creación y modificación)

Cargar en modo `plan`/`apply`. Delegar la preparación a `cloudflare-operator`
y la revisión a `cloudflare-reviewer` antes de pedir aprobación al usuario.

## Esquema del plan

Nivel raíz (`New-CloudflareChangePlan.ps1`, `[ordered]@{}`):

```json
{
  "schemaVersion": 1,
  "planId": "guid",
  "createdAtUtc": "iso8601",
  "expiresAtUtc": "iso8601",
  "ownerTranscriptId": "string|null",
  "connectionMode": "rest|mcp|terraform|wrangler|mixed",
  "accountId": "string",
  "zoneIds": ["string"],
  "objective": "string",
  "inventoryHashes": [{ "path": "string", "hash": "sha256" }],
  "preStateHash": "sha256",
  "approvedOperations": [ /* no destructivas */ ],
  "pendingDeleteOperations": [ /* destructivas — normalmente vacío aquí, ver deletion-workflow.md */ ],
  "riskAndImpactAnalysis": "string",
  "backupStrategy": "string",
  "verificationPlan": "string",
  "rollbackStrategy": "string",
  "validated": false,
  "validationHash": null,
  "validationEvidence": null,
  "reviewStatus": "not-reviewed"
}
```

Cada operación — 27 campos obligatorios, `New-CloudflareChangePlan.ps1`
rechaza cualquiera al que le falte alguno:

```json
{
  "operationId": "string",
  "phase": "nonDestructive|destructive",
  "action": "create|update|action|delete",
  "accountId": "string",
  "zoneId": "string|null",
  "resourceType": "string",
  "resourceId": "string",
  "resourceName": "string",
  "executor": "cloudflareRest|cloudflareGraphQL|terraform|wrangler",
  "method": "string|null",
  "uri": "string|null",
  "argv": [],
  "body": {},
  "bodyHash": "string|null",
  "preconditionHash": "string",
  "currentState": {},
  "desiredState": {},
  "dependencies": [],
  "isDestructive": false,
  "reversible": true,
  "backupStrategy": "string",
  "rollbackStrategy": "string",
  "verification": [],
  "retryPolicy": { "maxAttempts": 1, "retryableCodes": [], "delaySeconds": 0 },
  "timeoutSeconds": 600,
  "expectedFinalState": "string",
  "expectedReadback": "string"
}
```

- `argv`: SIEMPRE un array tokenizado, y solo se usa si `executor` es
  `terraform`/`wrangler` — nunca un string de shell crudo.
- `executor=cloudflareGraphQL`: `method` debe ser `"POST"`; `body.query`
  nunca puede contener la palabra `mutation` (bloqueado en
  `Test-CloudflareChangePlan.ps1` y de nuevo en runtime por
  `Apply-CloudflareChangePlan.ps1`).
- `isDestructive` debe coincidir con dónde vive la operación:
  `approvedOperations` nunca contiene `isDestructive: true`.

## Flujo paso a paso

1. Confirmar cuenta y zona(s) — nunca asumir "la última usada" sin
   confirmarla.
2. Inventario de lectura: `Get-CloudflareInventory.ps1`.
3. Consultar documentación y esquema actuales del endpoint (MCP `docs`/
   `search`, o la documentación oficial).
4. Verificar permisos del token sin exponer su valor — si falta un
   permiso, reportarlo exacto y detenerse (no ampliar el token).
5. Guardar respaldo sanitizado del estado actual (parte del inventario).
6. Calcular `preStateHash` (lo hace `New-CloudflareChangePlan.ps1`).
7. Preparar el cambio y sus dependencias.
8. `terraform plan`/`validate` si corresponde — adjuntar evidencia al
   plan.
9. `New-CloudflareChangePlan.ps1` — genera el plan inmutable.
10. `Test-CloudflareChangePlan.ps1` — si hay bloqueantes (secretos,
    forma inválida, drift, GraphQL con `mutation`, `resourceType`
    potencialmente destructivo fuera de `pendingDeleteOperations`),
    reportarlos y detenerse — no resolverlos adivinando.
11. Pasar el plan a `cloudflare-reviewer`.
12. Presentar una sola aprobación con resumen completo (cuenta, zona(s),
    qué cambia, qué no cambia, dependencias, posible indisponibilidad,
    estrategia de respaldo, verificación, rollback) e invocar
    `Apply-CloudflareChangePlan.ps1` en el mismo turno — la tarjeta
    nativa (o el bloque visible ```cloudflare-apply-authorization``` de
    un `ExitPlanMode` aprobado) es la única solicitud de aprobación.
13. `Apply-CloudflareChangePlan.ps1` ejecuta únicamente las
    `approvedOperations` de ESE plan. Si una operación falla, detenerse y
    reportar exactamente qué se aplicó — sin rollback automático ni
    reintento sin nueva aprobación.
14. `Test-CloudflarePostChange.ps1` — releer cada recurso y comparar
    contra `expectedFinalState`/`expectedReadback`.
15. Reporte: qué se planeó, qué bloqueantes hubo, qué se aplicó
    realmente, qué queda pendiente de verificar.

Si existe drift (inventario re-hasheado no coincide) en cualquier punto
antes de aplicar: no sobrescribir. Regenerar inventario, diff y plan;
pedir una aprobación nueva.
