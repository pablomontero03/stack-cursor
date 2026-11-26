# Secretos, RBAC y locks

Cargar al planificar cualquier operación que toque un Key Vault,
credenciales, RBAC/Policy, o un resource lock.

## Secretos — nunca un valor literal en un plan

Placeholder obligatorio: `${AZURE_SECRET_NOMBRE}`. El valor real se
resuelve exclusivamente dentro de un `Apply-AzureChangePlan.ps1` ya
aprobado, leído desde una variable de entorno local (`$env:AZURE_SECRET_*`)
o un almacén seguro — nunca desde el chat, nunca impreso, nunca guardado
en el plan/journal/logs/memoria. Mismo mecanismo (adaptado) que
`${ADO_SECRET_*}` en Azure DevOps Pipelines — ver
Ver `.cursor/rules/azure-devops.mdc` (sección de secretos) para el detalle
completo del patrón si hace falta implementar la resolución real.

`Test-AzureChangePlan.ps1` bloquea cualquier valor literal en una
propiedad de nombre sensible (`password`, `token`, `accountKey`,
`connectionString`, `clientSecret`, `secret`, `apiKey`, `privateKey`,
`sasToken`, `certificate`, `primaryKey`/`secondaryKey`, `authorization`) y
además escanea el texto crudo del archivo por patrones sospechosos
(connection strings, JWT, `AccountKey=...`).

## Comandos que exponen secretos — siempre preguntar aunque "lean"

`az keyvault secret show/list`, `az keyvault key show/list`, `az storage
account keys list`, `az storage account show-connection-string`, `az acr
credential show`, `az ad sp credential`, `az webapp deployment
list-publishing-credentials`. `azure-security-gate.ps1` los clasifica
`ask` explícitamente, no `allow`, aunque el verbo sea `show`/`list`.

## Antes de crear un secreto nuevo — buscar la alternativa sin secreto

Igual criterio que Azure DevOps Pipelines: antes de proponer una Storage
Account key o un secret de Key Vault suelto, confirmar si ya existe una
alternativa más segura para el caso concreto:

- **Managed Identity** (system-assigned o user-assigned) en vez de una
  connection string o una credencial de service principal.
- **RBAC sobre el recurso** (ej. "Storage Blob Data Reader") en vez de una
  Storage Account key compartida.
- **Key Vault reference** desde App Service/Functions/Container Apps en
  vez de copiar el secreto a una variable de entorno plana.
- **Federated credential** (Workload Identity) en vez de un client
  secret de larga duración para una identidad de aplicación.

Si ninguna aplica, recién ahí se documenta la necesidad real de un
secreto nuevo y su alcance exacto.

## RBAC

- Este dominio hereda los permisos reales de la identidad activa (`az
  login` del usuario) — nunca crea automáticamente una asignación (`az
  role assignment create`) como efecto colateral de resolver un permiso
  faltante.
- Si una operación falla por falta de permisos, se reporta exactamente el
  permiso faltante y se detiene — cualquier cambio de RBAC para
  resolverlo cae en "Cambios de RBAC/gobernanza" (categoría B,
  `.cursor/rules/azure.mdc`) con su propia aprobación
  explícita, nunca se asume ni se aplica junto con otro cambio.
- `az role assignment/definition list` es lectura automática; `create/
  delete/update` siempre `ask`.

## Locks

- `az lock list` es lectura automática.
- `az lock create/delete/update` siempre `ask`.
- Si un plan necesita eliminar un lock existente para poder aplicar un
  cambio, esa eliminación de lock es su propia aprobación explícita,
  documentada en el plan (`dependencies`) pero nunca ejecutada como parte
  silenciosa de otra operación.

## Azure Policy

- Lectura (`list`) automática; crear/modificar/eliminar una asignación o
  definición de Policy siempre `ask` — cae en gobernanza sensible, mismo
  criterio que RBAC.

## Nunca

- Imprimir, loggear o guardar un access token, un valor de Key Vault, una
  Storage Account key, un SAS token, credenciales de ACR, o un
  certificado/clave privada — ver `.cursor/rules/azure.mdc` (sección
  Prohibido permanentemente).
- Reutilizar un secreto de una aplicación/ambiente en otro sin
  confirmación explícita del usuario.
