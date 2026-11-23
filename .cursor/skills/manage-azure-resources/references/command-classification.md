# Clasificación de comandos — automático vs. requiere aprobación

Cargar al decidir si un comando `az`/`azcopy`/`bicep` concreto, o una tool
MCP `azure` (cuando exista), es de solo lectura o requiere aprobación
explícita. Esta es la referencia legible para humanos; la implementación
ejecutable vive en `.claude/hooks/azure/azure-security-gate.ps1`
(`Test-AzureCliSegment`) — si hay discrepancia entre esta tabla y el hook,
el hook es lo que realmente se ejecuta; corregir el hook y esta tabla
juntos.

## Siempre automático (`allow`)

| Categoría | Ejemplos |
|---|---|
| Cuenta/sesión (lectura) | `az account show`, `az account list`, `az account list-locations` |
| Resource Graph | `az graph query` |
| Inventario genérico | `az resource list`, `az group list`, `az <provider> show/list/get/exists` |
| Activity Log | `az monitor activity-log list` |
| Locks (lectura) | `az lock list` |
| Policy (lectura) | `az policy assignment list`, `az policy definition list` |
| RBAC (lectura) | `az role assignment list`, `az role definition list` |
| Simulación | `az deployment group/sub/mg/tenant what-if`, `az deployment ... validate` |
| ARM REST de lectura | `az rest --method get ...` |
| Bicep | `bicep build`, `bicep lint`, `bicep decompile` |
| Metadatos | `az version`, `az <provider> wait`, `az <provider> check-name-availability` |

## Siempre requiere aprobación (`ask`)

| Categoría | Ejemplos |
|---|---|
| Sesión sensible | `az login`, `az logout`, `az account clear`, `az account get-access-token`, `az account set`, cualquier comando con `--debug` |
| Escritura real | Cualquier verbo `create\|update\|delete\|set\|add\|remove\|restart\|start\|stop\|deallocate\|reset\|rotate\|assign\|grant\|revoke\|purge\|deny\|enable\|disable\|move\|import\|export\|push\|upload\|restore\|failover` |
| Deployment real | `az deployment group/sub/mg/tenant create/delete` |
| ARM REST de escritura | `az rest --method post\|put\|patch\|delete ...` |
| Lectura de secretos | `az keyvault secret show/list`, `az keyvault key show/list`, `az storage account keys list`, `az storage account show-connection-string`, `az acr credential show`, `az ad sp credential`, `az webapp deployment list-publishing-credentials` |
| RBAC/gobernanza (escritura) | `az role assignment/definition create/delete/update`, `az policy assignment/definition create/delete/update` |
| Locks (escritura) | `az lock create/delete/update` |
| `azcopy` | Cualquier subcomando (transferencia real de datos) |
| Subcomando no reconocido | Cualquier `az <provider> <verbo>` que no matchee ninguna regla anterior — nunca se asume lectura |

## `Apply-AzureChangePlan.ps1` / `Apply-AzureDeletePlan.ps1`

`azure-security-gate.ps1` nunca decide sobre invocaciones de estos dos
scripts — las delega a `azure-plan-authorization.ps1` /
`azure-delete-authorization.ps1` (reuso de aprobación visible ≤24h, ver
`authorization.md`) o, si no aplica, a la confirmación nativa de Claude
Code por el nombre del script.

## Tools MCP `azure` (cuando exista)

Mientras `.mcp.json` no declare el servidor `azure`, cualquier tool
`mcp__azure__*` se trata siempre como no reconocida (`ask`) — nunca se
asume lectura. Cuando se instale, enumerar las tools reales (`claude mcp
get azure` + lista) y clasificarlas aquí una por una, con el mismo rigor
que `references/aks-mcp.md` del dominio AKS (inspeccionar el
`inputSchema` real de cada tool, no adivinar por el nombre).

## Deny absoluto (defensa en profundidad, solo lo detectable por texto)

- `bypassPermissions` / `--dangerously-skip-permissions` en cualquier
  forma.

Todo lo demás que no encaje arriba resuelve a `ask`, nunca a `deny`.
