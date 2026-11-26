# Flujo de eliminación

Cargar en modo `delete`. Siempre una aprobación SEPARADA de la del plan
principal de `change-workflow.md` — nunca se agrupan.

## Qué cuenta como eliminación

Ver `.cursor/rules/cloudflare.mdc` (sección Eliminación lógica) — incluye
cualquier `DELETE` HTTP, purga de cache, reemplazo de un Ruleset que
remueve reglas, eliminar zonas/DNS/Workers/Pages/KV/R2/D1/Queues/Tunnels/
certificados/load balancers, `terraform destroy`, `wrangler delete`,
desvincular un binding/custom domain/route, y revocar tokens/
certificados/accesos.

## Flujo paso a paso

1. Identificar exactamente cuenta, zona, tipo, nombre e ID del recurso —
   nunca un selector amplio ni un comodín.
2. Detectar dependencias y consumidores (¿qué más referencia este
   recurso?).
3. Determinar si contiene datos, configuración, tráfico o credenciales —
   y si existe backup real de esos datos.
4. `New-CloudflareDeletePlan.ps1` — SIEMPRE con `-InventoryPaths`
   apuntando a un inventario reciente que demuestre que el recurso existe
   tal cual se va a eliminar. Rechaza cualquier operación sin
   `resourceId` concreto o con un selector amplio detectable (`*`, o un
   URI sin ID específico al final).
5. `Test-CloudflareDeletePlan.ps1` — exige que TODAS las operaciones sean
   `isDestructive=true`, inventario no más viejo que
   `-MaxInventoryAgeHours` (default 24), y `resourceId` ya materializado
   en ese inventario (nunca obtenido por una consulta posterior a la
   aprobación).
6. Revisión independiente por `cloudflare-reviewer`.
7. Presentar una aprobación destructiva SEPARADA: tipo, ID, nombre,
   cuenta, zona, dependencias, impacto, indisponibilidad y recuperación
   real (existe backup o no) de cada elemento del lote.
8. `Apply-CloudflareDeletePlan.ps1` con `-OperationIds` enumerando
   EXACTAMENTE el lote aprobado (ni subconjunto ni elementos extra).
9. Antes de cada `DELETE` real: respaldo de solo lectura (GET del
   recurso completo) en `.local/cloudflare/backups/`. Un respaldo
   fallido o vacío detiene ESA eliminación puntual — nunca se borra sin
   poder respaldar primero.
10. `Test-CloudflarePostChange.ps1` — confirmar que el recurso ya no
    existe (o que quedó en el estado esperado).
11. Reporte: qué se eliminó, qué respaldo quedó disponible, y cómo
    recuperarlo si hiciera falta.

## Reglas duras

- Nunca selectores amplios, comodines, `all`, listas obtenidas después de
  la aprobación, ni paginación cuyo resultado no quedó materializado
  dentro del plan aprobado.
- No se permite agregar elementos al lote después de aprobado.
- Aprobar una eliminación nunca autoriza recrear el recurso — son dos
  aprobaciones independientes (la recreación pasa por
  `change-workflow.md`).
- Un reintento de una eliminación fallida requiere una aprobación nueva —
  el journal (`blocked-drift`/`ambiguous`) nunca se reintenta
  automáticamente.
