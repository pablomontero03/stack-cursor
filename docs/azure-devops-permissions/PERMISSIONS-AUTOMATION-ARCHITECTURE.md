# Arquitectura — Azure DevOps Permissions Administration

Dominio separado de `manage-azure-devops-pipelines` (ver
`docs/azure-devops/PIPELINE-AUTOMATION-ARCHITECTURE.md` para el
equivalente de ese dominio). Administra grupos de seguridad de proyecto,
membresías y permisos Git en `Shared-Service-GM`, montado 2026-08-26.

## Componentes

```
.claude/skills/manage-azure-devops-permissions/
  scripts/Invoke-AdoPermissionsRest.ps1   -- foundation: hosts permitidos,
    tabla de operationTypes (create/update/add/set + delete-* separados),
    matrices (fuente única), catálogo de acciones del namespace, hash
    canónico, journal de ejecución, construcción/validación de tokens,
    Invoke-AdoPermissionsApplyPhases e Invoke-AdoPermissionsDeleteApplyPhase
    (fases de aplicación, testeables con red mockeada)
  scripts/Export-AdoPermissionsSecurityInventory.ps1  -- GET puro
  scripts/New-AdoPermissionsPlan.ps1      -- genera plan (validated=false)
  scripts/Test-AdoPermissionsPlan.ps1     -- valida, re-deriva blockers
  scripts/Apply-AdoPermissionsPlan.ps1    -- aplica (rechaza destructivo)
  scripts/Test-AdoPermissionsReadback.ps1 -- compara plan vs estado real
  scripts/New-/Test-/Apply-AdoPermissionsDeletePlan.ps1 -- trío de borrado
  scripts/tests/run-script-tests.ps1      -- arnés offline sin Pester

.claude/agents/azure-devops-permissions/  -- builder/reviewer/diagnoser
.claude/agent-memory/ado-permissions-*/   -- memoria independiente c/u
.claude/rules/azure-devops-permissions/   -- authorization.md, security.md
.claude/hooks/azure-devops-permissions/   -- gate, post-validate, stop-validate
```

## Por qué el plan guarda el `body` completo (no solo `bodyHash`)

A diferencia de Pipelines (donde `approvedOperations` solo guarda
`bodyHash`, y `Apply-AdoClassicPlan.ps1` reconstruye el body real en
memoria vía funciones compartidas de `New-AdoClassicPayloads.ps1`), acá
el documento fuente exige explícitamente `body sanitizado` + `bodyHash`
como campos separados del plan. Esto resuelve limpio un problema real de
este dominio: varias operaciones (agregar miembro a un grupo recién
creado, fijar ACE de un grupo recién creado) referencian un descriptor que
no existe hasta después de aplicar una operación ANTERIOR del mismo plan
— la única forma segura de manejar esto sin inventar un mecanismo de
sustitución post-hash (como `${ADO_SECRET_*}` en Pipelines, pensado para
secretos, no para ids dependientes) es **no incluir esas operaciones en el
mismo plan en absoluto** cuando el grupo es nuevo — quedan en
`deferredAfterCreation`, resueltas en un plan posterior una vez el grupo
existe de verdad.

## Por qué las matrices y la lógica de tokens viven en `Invoke-AdoPermissionsRest.ps1`

El árbol de archivos del documento fuente no incluye un archivo adicional
tipo `New-AdoClassicPayloads.ps1` de Pipelines. Para lograr "una sola
fuente de verdad, sin duplicaciones" sin agregar un archivo fuera del
árbol pedido, las matrices (`Get-AdoPermissionsMatrixDefinition`), el
catálogo de acciones (`Get-AdoPermissionsManagedActionCatalog`), la
construcción de tokens y las 2 fases de aplicación viven en el mismo
helper foundation que ya se dot-sourcea desde todos los demás scripts.

## Resolución de acciones por nombre estable, no por `displayName`

Confirmado en vivo (2026-08-26) contra la API real: al menos 2 etiquetas
de UI del documento fuente NO coinciden textualmente con el `displayName`
que devuelve hoy `GET _apis/securitynamespaces` para la misma acción
("Delete or disable repository" vs "Delete repository"; "Force push
(rewrite history, delete branches and tags)" vs "Force push (rewrite
history and delete branches)"). Resolver por `displayName` habría
producido falsos bloqueos permanentes. La resolución usa el campo `name`
(estable), con el bit real siempre tomado de la respuesta en vivo — ver
`references/permission-matrix.md`.

## Testing de las fases de aplicación — nunca contra la organización real

`$env:AZURE_DEVOPS_PAT` está configurada de forma persistente en este
entorno (compartida con Pipelines). Una invocación directa de
`Apply-AdoPermissionsPlan.ps1`/`Apply-AdoPermissionsDeletePlan.ps1`, aunque
sea con datos de prueba ficticios, llega a la organización real (se
confirmó esto durante la construcción: varias llamadas GET y un intento de
POST real llegaron a `Shared-Service-GM` antes de fallar por recursos
inexistentes). Por eso `Invoke-AdoPermissionsApplyPhases` e
`Invoke-AdoPermissionsDeleteApplyPhase` viven separadas de los scripts
ejecutables — se prueban dot-sourceando el foundation y reemplazando
`Invoke-AdoPermissionsRest` por una función mockeada antes de llamarlas,
nunca invocando los scripts `Apply-*.ps1` de punta a punta.

## Gotcha de codificación encontrado durante la construcción

`New-AdoPermissionsPlan.ps1` contiene literales en español con tildes
(las 2 descripciones estándar). Windows PowerShell 5.1 lee un `.ps1` sin
BOM UTF-8 usando la codepage ANSI del sistema — un archivo guardado como
UTF-8 sin BOM con esos caracteres se lee mal y corrompe el texto al
volcarlo a JSON (mojibake tipo "Ã­" en vez de "í"). El archivo se guardó
con BOM UTF-8 explícito para evitarlo; cualquier `.ps1` nuevo de este
dominio que incluya caracteres no-ASCII literales debe hacer lo mismo.
