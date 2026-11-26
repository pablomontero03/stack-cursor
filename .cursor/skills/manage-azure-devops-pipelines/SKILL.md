---
name: manage-azure-devops-pipelines
description: Gestiona, crea, revisa y diagnostica pipelines de Azure DevOps para Shared-Service-GM mediante el MCP oficial y APIs REST: pipelines clasicos o YAML, Builds, Releases, Variable Groups, task groups, despliegues AKS o DACPAC.
triggers: [pipeline, ado, azure devops, build, release, dacpac, ssdt, deployment, devops]
always: false
---

# Manage Azure DevOps Pipelines

Organización: `Shared-Service-GM`. Proyecto de pipelines: `DevOps`.

## ⚠️ LEER PRIMERO (OBLIGATORIO)

Antes de crear cualquier pipeline CLASSIC, **LEER EN ESTE ORDEN**:

1. **`.cursor/memories/ado-pipeline-builder/plantilla-intake-api.md`**  
   Plantilla genérica de intake para modo agéntico end-to-end. Usar esta plantilla para **NO preguntar** y ejecutar el flujo completo automáticamente.

2. **`.cursor/memories/ado-pipeline-builder/errores-comunes.md`**  
   Documenta 9 errores que pueden desperdiciar ~1.5 horas. Leer toma 5 minutos y evita el 85% de los fallos.

**Modo agéntico**: Si el usuario proporciona un intake completo siguiendo la plantilla, ejecutar TODOS los pasos sin preguntas adicionales.

## Cargar solamente el contexto necesario

No cargar las tres guías completas de entrada. Cargar según el modo (tabla
abajo). Nunca duplicar su contenido en este archivo ni en la respuesta al
usuario — referenciarlas por ruta.

## Enrutamiento de modos

| Modo | Cuándo | Referencia a cargar |
|------|--------|----------------------|
| `inspect` | Inventario y consultas de solo lectura (proyectos, repos, builds, releases, VGs, task groups, service connections) | `references/ado-api-map.md` |
| `classic-aks` | Library + Build clásico + Release clásico hacia AKS (App → Docker → AKS) | **Primero** `references/ado-new-pipeline-intake-template.md` (qué datos pedir/confirmar) y `references/ado-classic-payload-templates.md` (generador real: `New-AdoClassicAksPlan.ps1`, agrupación de merges, manifiestos K8s, `.env`); `ado-classic-from-scratch.md` §1–7 y `ado-classic-playbook-any-project.md` quedan como referencia del flujo manual anterior y errores frecuentes, no como plantilla de datos; si se está comparando contra pipelines existentes como fuente, también `references/variable-classification.md` |
| `classic-dacpac` | Build y Release clásicos de base de datos (DACPAC/SSDT) | `references/ado-classic-from-scratch.md` §8 |
| `yaml` | Pipelines YAML mediante capacidades reales del MCP oficial | Toolset del MCP conectado (`azure-devops`); no hay guía clásica aplicable |
| `run-monitor` | Ejecución, seguimiento y diagnóstico de builds/releases existentes | `references/approval-matrix.md`; monitoreo activo con `scripts/Wait-AdoClassicRun.ps1` (consulta inmediata + cada intervalo hasta terminal/timeout; usado también por `orchestrate-application-pipeline-cycle`) |

La fuente canónica de la contraseña del Container Registry
(`ADO_SECRET_CONTAINERREGISTRYPASSWORD`) está fijada en
`references/container-registry-secret-source.md` — no pedir su valor al
usuario cuando la variable de entorno exista.

Datos específicos de Buklo (ids, puertos, DB) viven en
`references/devops-guide.md` — cargar solo si el pipeline en cuestión es
del monorepo Buklo o se necesita un ejemplo concreto ya validado.

## Prioridad al resolver una operación: MCP primero, REST solo para brechas clásicas

1. Usar el MCP oficial `azure-devops` (`@azure-devops/mcp`) como primera
   opción para inventario, consultas, builds, logs, artefactos y toda
   operación que exponga realmente.
2. Para leer variables clásicas, intentar MCP primero. Si esa capacidad no
   existe, falla o devuelve datos incompletos, usar
   `scripts/Get-AdoClassicVariables.ps1`: es un fallback GET-only que toma
   el PAT de `$env:AZURE_DEVOPS_PAT` o, si falta, la clave `token` de
   `env/Azure-DevOps.txt` sin imprimirla.
3. El MCP oficial no cubre crear de punta a punta un pipeline clásico
   (Variable Group + Build clásico + Release clásico). Para esa brecha,
   usar exclusivamente los scripts de `scripts/` (que llaman las APIs REST
   documentadas en `references/ado-api-map.md`).
4. El fallback por PAT solo puede reemplazar una consulta MCP de lectura.
   Nunca convertir una escritura MCP rechazada o denegada en REST.
5. Toda escritura REST pasa por un plan validado (`Test-AdoClassicPlan.ps1`),
   una entrada exacta de `plan.approvedOperations` (operationType uno de
   los 3 tipos POST permitidos + method+uri+bodyHash; el estado de
   "ya se intento" vive en un journal de ejecucion separado, nunca
   reescribiendo el plan), evidencia de inventario fresca en el momento de
   aplicar (`validationEvidence` + `-InventoryPath`, acotada a un tope
   absoluto de 24h), y una aprobación
   explícita. `Invoke-AdoClassicPlan.ps1` es dry-run **exclusivo** (nunca
   escribe, no acepta ningún parámetro de aplicación) y **nunca invoca ni
   carga `Invoke-AdoRest.ps1` directo desde Bash o PowerShell — para ningún método**;
    la aplicación real vive en un script separado, `Apply-AdoClassicPlan.ps1`,
    precisamente para que el hook de seguridad pueda reconocerla por el
    **nombre** del script y contrastarla con el alcance exacto aprobado
    (ver `references/approval-matrix.md`).

## Enrutamiento de herramientas y permisos

Para que las operaciones locales permitidas no generen una tarjeta por cada
comando sin ampliar el permiso a PowerShell arbitrario:

1. Ejecutar los scripts versionados de `scripts/` directamente con la
   herramienta `PowerShell`, mediante una única invocación literal
   `& '<ruta absoluta del script>' <argumentos>` por tool use. No iniciar un
   segundo `powershell`/`pwsh`, no envolverlos en `Bash(powershell ...)` y no
   anteponer asignaciones ni agrupar `;`, pipelines, bucles o comandos
   auxiliares en la misma llamada.
2. No usar `powershell -Command`, `pwsh -Command`, `-EncodedCommand` ni
   one-liners equivalentes para inspeccionar o editar JSON/YAML. Usar
   `Read`/`Grep` para lectura y `Edit`/`Write` para archivos locales.
3. Para variables clásicas usar `Get-AdoClassicVariables.ps1`; no combinar
   `Get-AdoClassicDefinitionTemplate.ps1` con un segundo comando inline que
   recorra el JSON. `-RevealLocalSecrets` sigue requiriendo su aprobación
   puntual mediante el hook.
4. La autorización automática solo incluye inventario, lectura, generación de
   planes, validación y readback mediante entrypoints versionados. Las reglas
   `PowerShell(...)` documentan ese alcance, pero en Windows el matcher puede
   no reconocer rutas con `\`; si Kiro Crew va a mostrar la tarjeta, el hook
   `PermissionRequest` vuelve a analizar el AST y solo la responde cuando es
   una invocación literal, directa, individual y ubicada en `scripts/`.
   Para `Apply-AdoClassicPlan.ps1`, `PermissionRequest` solo actúa como
   respaldo si el mismo validador compartido vuelve a demostrar comando,
   hashes, transcript y plan aprobados; nunca autoriza un Apply nuevo.
   Nunca incluye REST directo ni un permiso global
   `PowerShell(*)`/`Bash(*)`.
   Para poblar `approvedOperations` de creación usar el runner versionado
   `New-AdoClassicCreatePlan.ps1`; para updates usar
   `New-AdoClassicUpdatePlan.ps1`. Ambos solo preparan archivos locales.
5. No crear ni ejecutar helpers temporales (`.ps1`, `.cmd`, `.bat`, Python u
   otros) en el scratchpad. Si falta una capacidad, detenerse e identificar
   el helper versionado/auditado que hace falta; no sustituirlo por permisos
   repetidos para código efímero.
   Para clasificar `.env`, usar el wrapper versionado
   `Convert-AdoEnvFileClassification.ps1`; `-PopulateRealValues` conserva
   una aprobación puntual porque puede materializar secretos en el archivo
   de salida, aunque el resumen siempre se imprime redactado.
6. Completar cualquier edición de plan, inventario y cuerpos PUT/POST antes de
   `ExitPlanMode`. Después de la aprobación, los únicos comandos de escritura
   cubiertos son los `Apply-AdoClassicPlan.ps1` exactos incluidos en
   `ado-apply-authorization`; cualquier desviación conserva la pregunta.

### Propietario único de la aprobación

El `ado-pipeline-builder` es exclusivamente preparatorio y puede ejecutarse en
segundo plano: produce planes, bodies, hashes, comandos Apply y comandos de
readback, pero nunca usa Plan Mode ni ejecuta escrituras. Los subagentes no
disponen de `EnterPlanMode`, y foreground no cambia esa limitación.

La sesión principal recibe los artefactos finales y es la única que entra a
Plan Mode, presenta `ExitPlanMode`, ejecuta los Apply exactos y hace readback.
El hook solo lee el `transcript_path` de la sesión que intenta el Apply; por
eso la aprobación y los Apply deben ocurrir en el transcript principal y no
se intenta heredar autorización desde o hacia un subagente.

## Flujo obligatorio

```text
intake → inventario (MCP; variables clásicas por Get-AdoClassicVariables.ps1 si hace falta) → plan (scripts/New-*)
  → builder prepara y valida todos los artefactos sin escrituras
  → builder entrega a la sesión principal el plan y bloque ado-apply-authorization exacto
  → la sesión principal presenta ExitPlanMode
  → la sesión principal aplica cada comando enumerado (sin otra tarjeta mientras comando, hashes y journal sigan dentro del alcance aprobado)
  → la sesión principal hace readback (MCP/REST de solo lectura)
  → reporte al usuario
  → memoria del agente (solo si hay aprendizaje reutilizable)
```

No saltear pasos. No ejecutar `apply` sin que exista un plan que ya pasó
`Test-AdoClassicPlan.ps1` sin bloqueantes.

**Borrar un Build/Release/Variable Group existente** (agregado 2026-08-26)
sigue el mismo flujo, con 2 diferencias: el plan se genera con
`New-AdoClassicDeletePlan.ps1` (no `New-AdoClassicAksPlan.ps1`/
`New-AdoClassicDatabasePlan.ps1`) y se valida con
`Test-AdoClassicDeletePlan.ps1` (no `Test-AdoClassicPlan.ps1` — la
validación es la opuesta: el recurso DEBE existir con el mismo id, en vez
de no ser un duplicado). `Apply-AdoClassicPlan.ps1` escribe siempre un
respaldo de solo lectura del recurso completo antes del `DELETE` real
(obligatorio, no configurable). Detalle técnico completo en
`security.md` y `authorization.md`.

La aprobación de `ExitPlanMode` autoriza **cada**
`Apply-AdoClassicPlan.ps1` enumerado únicamente cuando el plan ya fue
validado, la aprobación y los Apply ocurren en el mismo transcript principal,
y el texto presentado contiene exactamente un bloque visible con este esquema:

```ado-apply-authorization
{
  "version": 1,
  "commands": [
    {
      "command": "<comando PowerShell completo, exacto y en una sola línea>",
      "planSha256": "<SHA-256 del archivo indicado por -PlanPath>",
      "inventorySha256": "<SHA-256 del archivo indicado por -InventoryPath>"
    }
  ]
}
```

Calcular ambos hashes sobre los bytes actuales con `Get-FileHash -Algorithm
SHA256`; no inventarlos. Para la herramienta `PowerShell`, el comando debe ser
una invocación directa `&` en una sola línea, con `-PlanPath` e
`-InventoryPath` completos, rutas literales y el script oficial de esta skill.
Después de que el usuario apruebe el plan, copiar cada comando sin ninguna
variación. El hook devuelve `allow` para cada comando enumerado dentro de las
24 horas siguientes y mientras ambos archivos conserven sus hashes. Un
reintento local del mismo comando también queda cubierto solamente cuando el
journal confirma que ninguna operación remota salió de `pending`; cualquier
estado `in-progress`, `succeeded` o `ambiguous` exige readback y nueva
aprobación. Ausencia o duplicación del bloque, cambio de argumentos/archivos,
comandos compuestos, vencimiento o transcript distinto mantienen la tarjeta
nativa `ask`. No pedir además un "sí" textual en el chat.

## Separación estricta AKS / DACPAC

Nunca mezclar task groups, variables ni Variable Groups de las dos
familias. AKS usa `Deployment-Azur-Aks-v3` + Library **por app**
(`Produccion-<Producto>-<App>`). DACPAC usa `Deployment-DataBases` + una
única Library compartida (`Bases Datos SQL`, id 181 en el inventario
documentado — confirmar en vivo, no asumir el id). Ver
`references/ado-classic-from-scratch.md` §8.7.

## Regla de no asumir identificadores

Nunca dar por vigente un id, nombre de repo, branch, pool, service
connection, task group, cluster o namespace que aparezca en las
referencias. Son ejemplos históricos (Buklo). Confirmar todo contra el
inventario en vivo (MCP/REST de solo lectura) antes de armar un plan, y
pedir confirmación al usuario si hay discrepancia — en especial entre
`gmon-prod-aks-eastus2-0001` y `gmon-prod-aks-eastus2-0004`, que aparecen
ambos en las guías para clusters distintos.

## Regla de no guardar secretos

Nunca mostrar, loggear ni guardar el PAT. Los valores no secretos obtenidos
por MCP o `Get-AdoClassicVariables.ps1` pueden presentarse en la respuesta,
pero no se agregan al inventario general. Azure DevOps nunca devuelve el
valor de `isSecret=true`; `-RevealLocalSecrets` puede completarlo únicamente
por coincidencia exacta desde `env/Azure-DevOps.txt`, después de una tarjeta
nativa puntual, y sin persistirlo. Los planes y exports
(`.local/azure-devops/`) deben seguir sanitizados. Ver
`.cursor/rules/azure-devops-pipelines/security.md`.

## Política de aprobación por operación atómica

Ver `references/approval-matrix.md` y
`.cursor/rules/azure-devops-pipelines/authorization.md`. En resumen: lectura
e inventario sin aprobación; crear o actualizar la configuración completa de
un pipeline (Variable Groups + definiciones Build/Release, incluidos triggers
y aprobadores de esa definición) con una sola aprobación si el plan enumeró
todos sus efectos y comandos exactos. **Actualizado 2026-09-08**: esa misma
aprobación también puede cubrir encolar el Build y ejecutar/crear la primera
instancia de Release real para **Desarrollo y UAT**, si el plan ya lo
enumeró explícitamente — nunca para Producción. Ejecutar/reintentar fuera de
lo enumerado, crear o desplegar una instancia de Release real para
Producción, desplegar a Producción, aplicar DACPAC, aprobar un stage, borrar
recursos o modificar recursos compartidos/permisos exigen siempre una
aprobación separada y específica.

### Script allowlisted para encolar builds

`scripts/Invoke-AdoQueueBuild.ps1` — entrypoint versionado para el ciclo
agéntico BD y AKS. Encola un build de prueba desde una rama autorizada
(`development`, `uat`, `release`). No aprueba stages, no crea releases, no
modifica definiciones. Uso:

```powershell
& '<ruta>/Invoke-AdoQueueBuild.ps1' -BuildDefinitionId <id> -SourceBranch 'refs/heads/uat'
```

La aprobación atómica del plan cubre este script cuando el plan enumeró
explícitamente el encolar del Build para Desarrollo/UAT.

## Estado de esta tarea

Esta skill se preparó como estructura local y validación de conexión
(inventario de solo lectura). Ningún recurso real de Azure DevOps fue
creado, modificado, ejecutado ni eliminado por esta skill hasta que el
usuario apruebe explícitamente un plan concreto.

## Actualizar Variable Groups existentes (update-variable-group)

**Agregado 2026-10-14.** Permite editar variables específicas de un Variable
Group existente sin recrearlo ni perder las variables no mencionadas.

### Cuándo usar

- Cambiar valores de configuración (CPU, memoria, feature flags) sin tocar
  otras variables del mismo VG.
- Actualizar múltiples VGs de diferentes ambientes (dev/uat/prod) con el mismo
  cambio.

### Flujo simplificado

```text
1. GET del VG actual (MCP o curl)
2. Crear plan con variableGroupUpdate: { id, variables: { ... } }
3. Validar con Test-AdoClassicPlan.ps1
4. Apply con -CurrentVariableGroupJson "<json del GET>"
```

### Referencia completa

Ver `references/approval-matrix.md` sección "Actualizar Variable Groups
existentes" para ejemplos de plan, comando Apply y consideraciones de
seguridad.

### Scripts involucrados

| Script | Rol |
|--------|-----|
| `New-AdoVariableGroupUpdatePayload` | Genera el body PUT preservando variables existentes |
| `Apply-AdoClassicPlan.ps1` | Ejecuta el PUT (requiere `-CurrentVariableGroupJson`) |
| `Test-AdoClassicPlan.ps1` | Valida el plan (usa lógica genérica de `requiresIdSuffix`) |
| `Invoke-AdoRest.ps1` | Allowlist con entrada `update-variable-group` (PUT) |

## Errores comunes y soluciones

**Agregado 2026-11-24.** Errores frecuentes al crear pipelines CLASSIC y cómo
   290|prevenirlos.

### Error 1: Intentar crear pipeline YAML cuando el dominio usa CLASSIC

**Síntoma**: Crear archivo `azure-pipelines.yml` y usarlo en lugar de los
scripts del dominio.

**Causa**: No leer los skills/documentación antes de actuar.

**Solución**: Este dominio usa **pipelines CLASSIC (JSON)** exclusivamente.
Nunca crear archivos YAML. Usar siempre:
   300|```
New-AdoClassicAksPlan.ps1 → Test-AdoClassicPlan.ps1 → Apply-AdoClassicPlan.ps1
```

**Prevención**: Leer SKILL.md, references y memorias ANTES de ejecutar
cualquier acción.

### Error 2: Apply-AdoClassicPlan.ps1 falla con "falta -DeploymentDevYamlPath"

**Síntoma**: Variable Group se crea correctamente pero Build falla con:
   310|```
Apply-AdoClassicPlan rechazado: el plan tiene aprobada la creacion del Build 
('create-build-definition') pero falta -DeploymentDevYamlPath.
```

**Causa**: El Build necesita los 3 manifests K8s para los File Creator tasks.

**Solución**: Cuando el plan incluye `create-build-definition`, SIEMPRE pasar:
```powershell
Apply-AdoClassicPlan.ps1 `
  -PlanPath '...' -InventoryPath '...' `
   320|  -DeploymentDevYamlPath '/ruta/deployment-dev.yml' `
  -DeploymentUatYamlPath '/ruta/deployment-uat.yml' `
  -DeploymentProdYamlPath '/ruta/deployment-prod.yml'
```

**Prevención**: Recordar que Build embebe contenido completo de manifests.

### Error 3: Apply falla con "ya existe un Variable Group llamado..."

**Síntoma**: Intentar crear Release pero falla porque el plan tiene operación
de Variable Group ya ejecutada.
   330|
**Causa**: Reutilizar un plan que contiene `create-variable-group` previo.

**Solución**: Para el Release, crear plan base LIMPIO:
```bash
cat plan-prod.json | jq 'del(.approvedOperations) | .approvedOperations = []' > plan-base.json
```
Luego generar solo la operación del Release sobre ese plan base.

**Prevención**: Release siempre desde plan base sin operaciones previas.
   340|
### Error 4: Release falla con "empty approver" (VS402896)

**Síntoma**: Azure DevOps rechaza con error 400:
```
VS402896: One or more pre-approvals in stage 'Produccion' has an empty approver.
```

**Causa**: Configurar `approvalRequired: true` sin especificar `approverId`.

**Solución**: Dos opciones:
   350|
**A)** Especificar approver:
```json
{
  "stage": "Produccion",
  "approvalRequired": true,
  "approverId": "d88a393b-01ed-6276-89a2-e67efeb88f92",
  "releaseCreatorCanBeApprover": false
}
```

**B)** Crear sin approval (configurar después en UI):
   360|```json
{
  "stage": "Produccion",
  "approvalRequired": false
}
```

**Prevención**: Nunca usar `approvalRequired: true` sin `approverId`.

### Error 5: Journal marca operación como "ambiguous"

**Síntoma**: Apply rechaza con:
   370|```
Operacion REST rechazada: la operacion 'release-def' ya tiene estado 'ambiguous' 
en el journal de ejecucion.
```

**Causa**: Operación falló después de enviar HTTP request pero antes de
confirmar resultado. El journal la marca "ambiguous" por seguridad.

**Solución**:
1. **Readback manual** via API:
   380|   ```bash
   curl -s -u ":${AZURE_DEVOPS_PAT}" \
     "https://vsrm.dev.azure.com/Shared-Service-GM/DevOps/_apis/release/definitions?api-version=7.1" | \
     jq '.value[] | select(.name == "Deploy-Desarrollo-UAT-Produccion-<APP>") | {id, name}'
   ```
2. Si devuelve **vacío** (no existe): seguro limpiar journal y reintentar
3. Si devuelve **objeto** (existe): actualizar journal con ese ID real

**Prevención**: Estado "ambiguous" protege contra duplicados. SIEMPRE
verificar antes de limpiar journal.
   390|
**Referencia completa**: Ver memoria
`ado-pipeline-builder/lecciones-aprendidas-auth-api-pipeline.md` para
detalles y scripts de readback.
