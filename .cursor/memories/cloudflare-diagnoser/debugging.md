# Debugging — cloudflare-diagnoser

## Invocación sin herramienta de ejecución (Bash/PowerShell/MCP) — 2026-09-07

**Síntoma**: en una invocación real de este agente (validación de 3
registros DNS candidatos para `app-directory` de `buklo-web`), el set de
tools disponible para la sesión no incluía `Bash` ni ninguna tool
`mcp__cloudflare-api__*` — solo `Read`/`Grep`/`Glob`/`Write`/`Edit`. Esto
impidió ejecutar `Get-CloudflareInventory.ps1`/`Invoke-CloudflareRead.ps1`
o cualquier consulta MCP real contra Cloudflare, aunque el token/MCP
estuvieran configurados (`.mcp.json` sí declara `cloudflare-api`).

**Causa**: configuración de permisos/tools de esa invocación puntual del
subagente, no un problema de credenciales ni del dominio Cloudflare en sí.

**Cómo se manejó (sin evidencia de lectura real de Cloudflare)**: se hizo
diagnóstico exclusivamente con evidencia local ya existente en el repo
(manifiestos K8s generados por el dominio de Azure DevOps Pipelines,
memoria cross-dominio de ese otro proyecto de agentes) y se reportó
explícitamente al usuario que la verificación contra el estado real de
Cloudflare (existencia/conflicto de los registros DNS, zonas exactas)
quedó pendiente por esta limitación de herramienta — nunca se afirmó
"existe" o "no existe" un registro sin haber podido consultarlo.

**Comprobación segura para la próxima invocación**: al empezar, confirmar
que `Bash`/`PowerShell` (o las tools `mcp__cloudflare-api__*`) están
realmente disponibles en el set de tools de la sesión antes de prometer
resultados de inventario en vivo — si no lo están, decirlo temprano y
explícito en vez de intentarlo silenciosamente y fallar más tarde.

**Recurrencia confirmada, mismo día**: la invocación siguiente de esta
misma fecha (2026-09-07, validación de 3 registros DNS para `app-sso`)
tuvo exactamente el mismo set de tools reducido (`Read`/`Grep`/`Glob`/
`Write`/`Edit`, sin `Bash` ni `mcp__cloudflare-api__*`) y sin ningún
archivo bajo `.local/cloudflare/` (ni siquiera un inventario viejo de una
sesión anterior con acceso real). Esto refuerza que es una limitación de
configuración de la sesión/lanzamiento del subagente, no un evento
aislado — vale la pena que quien invoque a este agente confirme
explícitamente disponibilidad de `Bash` antes de pedir una verificación
"contra el estado real" si el resultado esperado es una clasificación
`to_create`/`reuse`/`conflict` real y no solo un análisis de convención.
