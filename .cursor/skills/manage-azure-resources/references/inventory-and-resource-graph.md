# Inventario y Azure Resource Graph

Cargar al inventariar recursos antes de planificar un cambio, o al
diagnosticar el estado actual de una suscripción/Resource Group.

## Orden de prioridad (ver también `INSTRUCCIONES-AUTOMATIZACION-AZURE.md`
§ Prioridad entre MCP y Azure CLI)

1. MCP oficial `azure` para inventario/consultas — **diferido, no
   disponible hoy** (ver `authentication-and-context.md`).
2. Azure CLI para lecturas puntuales no cubiertas por Graph
   (`Invoke-AzureRead.ps1`).
3. **Azure Resource Graph** (`az graph query`) para inventarios amplios —
   vía `Get-AzureInventory.ps1`, la vía preferida de este dominio.
4. API directa del Resource Provider (`az rest --method get` /
   `az <provider> show`) como fuente final antes de modificar un recurso
   puntual — para confirmar el estado exacto justo antes de planificar.

## `Get-AzureInventory.ps1`

- `-SubscriptionId` obligatorio; `-ResourceGroup` opcional (sin él,
  inventaría toda la suscripción — usar con cuidado en suscripciones
  grandes).
- Query KQL por defecto: proyecta `id, name, type, resourceGroup,
  location, tags` (y `properties` si se filtra por Resource Group). Se
  puede pasar `-Query` con una KQL propia para necesidades puntuales.
- `-IncludeLocks` / `-IncludeActivityLog` agregan `az lock list` / `az
  monitor activity-log list --offset 24h` al snapshot.
- Si `az graph query` falla (extensión `resource-graph` no instalada, o
  falla la consulta), cae automáticamente a `az resource list` — el
  snapshot registra `source` (`resource-graph` o `az-resource-list`) para
  que quede claro cuál se usó.
- Escribe el snapshot completo en `.local/azure/inventory/inv-<sub>-<rg>-
  <timestamp>.json` y devuelve su ruta + hash SHA-256 — ese hash es lo que
  `New-AzureChangePlan.ps1` referencia en `inventoryHashes` y lo que
  `Test-AzureChangePlan.ps1`/`Apply-AzureChangePlan.ps1` revalidan para
  detectar drift.

## Cuándo volver a capturar inventario

- Antes de generar cualquier plan de cambio nuevo (nunca reutilizar un
  inventario de una sesión anterior sin revalidar que sigue vigente).
- Si `Test-AzureChangePlan.ps1` reporta drift (el archivo de inventario
  cambió desde que se generó el plan) — capturar de nuevo y regenerar el
  plan completo, nunca "parchear" el plan existente.
- Antes de un rollback (`New-AzureRollbackPlan.ps1` deja `inventoryHashes`
  vacío a propósito — el inventario fresco es un paso manual obligatorio
  antes de validar ese plan).

## Extensión `resource-graph`

Si `az graph query` falla porque la extensión no está instalada, se
reporta al usuario (`az extension add --name resource-graph`) — instalar
una extensión de Azure CLI no es una operación de este dominio en sí
(cae bajo "Instalar, configurar o iniciar" herramientas, categoría B de
`CLAUDE.md`) y no se hace automáticamente sin aprobación.

## Diagnóstico (`azure-diagnoser`)

Combina `Get-AzureInventory.ps1` (con `-IncludeActivityLog`) +
`Invoke-AzureRead.ps1` para consultas puntuales (`az <provider> show` de
un recurso específico) + Activity Log filtrado por el resource ID en
cuestión para encontrar la causa raíz de un fallo — todo de solo lectura,
nunca propone un cambio real por sí mismo (deriva cualquier corrección al
flujo de `change-plan-schema.md`).
