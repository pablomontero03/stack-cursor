---
name: ado-pipeline-builder-errores-comunes
description: "Errores frecuentes al crear pipelines CLASSIC de Azure DevOps y cómo prevenirlos. Basado en experiencia real del pipeline Auth.API (2026-11-24)."
metadata:
  type: troubleshooting
---

# Errores Comunes - Pipelines CLASSIC Azure DevOps

**Fecha creación**: 2026-11-24  
**Fuente**: Lecciones aprendidas creando pipeline Auth.API  
**Dominio**: `manage-azure-devops-pipelines`

---

## 🔴 Error #1: Crear Pipeline YAML en lugar de CLASSIC

### Síntoma
Crear archivo `azure-pipelines.yml` y usarlo para definir el pipeline, en lugar
de usar los scripts del dominio (`New-AdoClassicAksPlan.ps1`).

### Causa Raíz
**NO leer los skills y documentación del dominio antes de actuar.**

### Impacto
- Pérdida de tiempo (~30 minutos)
- Commits desperdiciados
- Pipeline definitions inútiles creadas
- Confusión sobre el enfoque correcto

### Solución
Este dominio usa **pipelines CLASSIC (JSON)** exclusivamente. El flujo correcto es:

```
1. Leer .cursor/skills/manage-azure-devops-pipelines/SKILL.md
2. Leer referencias (ado-classic-payload-templates.md)
3. Leer memorias del agente (ado-pipeline-builder)
4. Generar plan: New-AdoClassicAksPlan.ps1
5. Validar: Test-AdoClassicPlan.ps1
6. Aplicar: Apply-AdoClassicPlan.ps1
```

### Prevención
✅ **SIEMPRE** leer SKILL.md, references y memorias ANTES de ejecutar  
✅ Verificar el tipo de pipeline (CLASSIC vs YAML) en el skill  
✅ Nunca asumir el flujo sin leer la documentación

---

## 🔴 Error #2: Apply sin parámetros -Deployment*YamlPath

### Síntoma
Ejecutar `Apply-AdoClassicPlan.ps1` para un plan con Build, y obtener:

```
Apply-AdoClassicPlan rechazado: el plan tiene aprobada la creacion del Build 
('create-build-definition') pero falta -DeploymentDevYamlPath. No se puede 
reconstruir el body real sin el contenido de los 3 manifiestos.
```

**Variable Group se crea correctamente, pero Build falla.**

### Causa Raíz
El Build necesita los 3 manifests K8s para los File Creator tasks. Estos tasks
embeben el contenido COMPLETO de los archivos en la definición del Build.

### Impacto
- Build no se crea (~5 minutos perdidos)
- Necesidad de ejecutar Apply nuevamente

### Solución
Cuando el plan incluye `create-build-definition`, SIEMPRE pasar los 3 paths:

```powershell
Apply-AdoClassicPlan.ps1 `
  -PlanPath '/ruta/plan-desarrollo-con-build.json' `
  -InventoryPath '/ruta/inventory.json' `
  -DeploymentDevYamlPath '/ruta/deployment-dev.yml' `
  -DeploymentUatYamlPath '/ruta/deployment-uat.yml' `
  -DeploymentProdYamlPath '/ruta/deployment-prod.yml'
```

### Prevención
✅ Recordar: Build → 3 paths obligatorios  
✅ Variable Group solo → sin parámetros extras  
✅ Release → parámetros distintos (ver error #3)

**Regla práctica**:

| Plan contiene | Parámetros obligatorios |
|---|---|
| Solo VG | `-PlanPath`, `-InventoryPath` |
| VG + Build | ➕ `-Deployment{Dev,Uat,Prod}YamlPath` |
| Release | ➕ `-ReleaseEnvironmentsPath`, `-ExistingBuildDefinitionId`, `-BuildDefinitionName` |

---

## 🔴 Error #3: Reutilizar plan con operaciones ya ejecutadas

### Síntoma
Intentar crear Release usando plan de Producción que tiene `create-variable-group`:

```
Apply-AdoClassicPlan detenido ANTES de escribir: ya existe un Variable Group 
llamado 'Produccion-Optica-Ecosystem-auth-api' en el proyecto 'DevOps'.
```

### Causa Raíz
El plan base contiene operación `create-variable-group` que ya fue ejecutada.
Apply detecta el recurso existente y se detiene antes de llegar al Release.

### Impacto
- Release no se crea (~5 minutos perdidos)
- Confusión sobre por qué falla si solo queremos el Release

### Solución
Para el Release, crear **plan base LIMPIO** sin operaciones previas:

```bash
# 1. Limpiar operaciones del plan
cat plan-produccion.json | \
  jq 'del(.approvedOperations) | .approvedOperations = []' > plan-base-release.json

# 2. Generar solo la operación del Release
New-AdoClassicCreatePlan.ps1 `
  -Kind 'Release' `
  -InputPlanPath 'plan-base-release.json' `
  -OutPlanPath 'plan-release-only.json' `
  -OperationId 'release-def' `
  -ReleaseEnvironmentsPath 'release-environments.json' `
  -ExistingBuildDefinitionId 713 `
  -BuildDefinitionName 'Build-Optica-Ecosystem-auth-api'

# 3. Validar y aplicar
Test-AdoClassicPlan.ps1 -PlanPath 'plan-release-only.json' ...
Apply-AdoClassicPlan.ps1 -PlanPath 'plan-release-only.json' ...
```

### Prevención
✅ Release SIEMPRE desde plan base sin operaciones previas  
✅ No reutilizar planes de VG/Build para el Release  
✅ Limpiar `approvedOperations` antes de generar operación Release

---

## 🔴 Error #4: approvalRequired sin approverId

### Síntoma
Azure DevOps rechaza creación del Release con error 400:

```
VS402896: One or more pre-approvals or post-approvals in stage 'Produccion' 
has an empty approver. Specify an approver or set Is Automated and try again.
```

### Causa Raíz
Configurar `approvalRequired: true` sin especificar `approverId`. Azure DevOps
no permite approvals sin approver definido (validación de seguridad).

### Impacto
- Release no se crea (~10 minutos perdidos en retry)
- Error HTTP 400 que no es inmediatamente obvio

### Solución
Dos opciones válidas:

**Opción A - Con approver específico** (recomendado):
```json
{
  "stage": "Produccion",
  "variableGroupId": 552,
  "artifactFilterBranch": "release",
  "deployTaskGroupId": "1fdf52f7-9160-4049-bb78-c7bffadf022d",
  "deployTaskGroupName": "Deployment-Azur-Aks-v3",
  "deployTaskGroupInputs": { ... },
  "approvalRequired": true,
  "approverId": "d88a393b-01ed-6276-89a2-e67efeb88f92",
  "releaseCreatorCanBeApprover": false
}
```

**Opción B - Sin approval** (configurar después en UI):
```json
{
  "stage": "Produccion",
  "variableGroupId": 552,
  "artifactFilterBranch": "release",
  "deployTaskGroupId": "1fdf52f7-9160-4049-bb78-c7bffadf022d",
  "deployTaskGroupName": "Deployment-Azur-Aks-v3",
  "deployTaskGroupInputs": { ... },
  "approvalRequired": false
}
```

Luego configurar en UI: Release → Stage Producción → Pre-deployment conditions → Add approver

### Prevención
✅ Nunca usar `approvalRequired: true` sin `approverId`  
✅ Si no se conoce approver, usar `false` y configurar después  
✅ Para obtener approverId: listar usuarios/grupos en el proyecto

**Script para obtener approver IDs**:
```bash
# Listar usuarios del proyecto
curl -s -u ":${AZURE_DEVOPS_PAT}" \
  "https://dev.azure.com/Shared-Service-GM/_apis/projects/DevOps/teams?api-version=7.1" | \
  jq '.value[] | {id, name}'
```

---

## 🔴 Error #5: Journal "ambiguous" bloquea retry

### Síntoma
Después de un fallo, Apply rechaza reintentos con:

```
Operacion REST rechazada: la operacion 'release-def' ya tiene estado 'ambiguous' 
en el journal de ejecucion. No se reintenta automaticamente; una operacion 
'ambiguous' exige readback y aprobacion explicita del usuario.
```

### Causa Raíz
La operación falló después de enviar el HTTP request pero antes de confirmar
el resultado. El journal la marca como `"ambiguous"` porque no sabe si el
recurso se creó parcialmente en Azure DevOps.

**Journal ubicación**: `.local/azure-devops/executions/<planValidationHash>.json`

**Contenido**:
```json
{
  "operations": {
    "release-def": {
      "state": "ambiguous",
      "startedAtUtc": "2026-11-24T00:53:57.1460775Z",
      "completedAtUtc": "2026-11-24T00:53:57.4225642Z",
      "resultId": null
    }
  }
}
```

### Impacto
- Apply bloqueado hasta hacer readback manual (~10 minutos)
- Riesgo de crear duplicados si se fuerza retry sin verificar

### Solución

**Paso 1 - Readback manual** para verificar si el recurso existe:

```bash
# Para Release
curl -s -u ":${AZURE_DEVOPS_PAT}" \
  "https://vsrm.dev.azure.com/Shared-Service-GM/DevOps/_apis/release/definitions?api-version=7.1" | \
  jq '.value[] | select(.name == "Deploy-Desarrollo-UAT-Produccion-<APP>") | {id, name}'

# Para Build
curl -s -u ":${AZURE_DEVOPS_PAT}" \
  "https://dev.azure.com/Shared-Service-GM/DevOps/_apis/build/definitions?api-version=7.1" | \
  jq '.value[] | select(.name == "Build-<APP>") | {id, name}'

# Para Variable Group
curl -s -u ":${AZURE_DEVOPS_PAT}" \
  "https://dev.azure.com/Shared-Service-GM/DevOps/_apis/distributedtask/variablegroups?api-version=7.1" | \
  jq '.value[] | select(.name == "<AMBIENTE>-<APP>") | {id, name}'
```

**Paso 2 - Decisión según resultado**:

**Si devuelve VACÍO** (recurso NO existe):
```bash
# Seguro limpiar journal
rm .local/azure-devops/executions/<planValidationHash>.json

# Corregir problema original (ej. approver faltante)
# ... editar release-environments.json ...

# Reintentar Apply
Apply-AdoClassicPlan.ps1 -PlanPath '...' -InventoryPath '...'
```

**Si devuelve OBJETO** (recurso SÍ existe):
```bash
# NO limpiar journal
# Actualizar journal manualmente con el ID real
# O continuar con siguiente paso del flujo (el recurso ya está creado)
```

### Prevención
✅ SIEMPRE hacer readback manual antes de limpiar journal "ambiguous"  
✅ Nunca asumir que el recurso no existe solo porque Apply falló  
✅ El estado "ambiguous" protege contra duplicados - respetarlo

---

## 🔴 Error #6: Variables containerRegistry* en lugar INCORRECTO

### Síntoma
Confusión sobre **dónde** van las variables `containerRegistryPassword` y 
`containerRegistryUsername`: ¿Variable Groups o Pipeline variables?

**CORRECTO**: Van en **Pipeline variables del Release** (a nivel de Release definition)  
**INCORRECTO**: Variable Groups (scope por ambiente)

### Causa Raíz
Falta de documentación clara sobre qué variables van en VG vs Pipeline variables.

**Variable Groups** (scope: ambiente específico):
- Configuración específica del ambiente (namespace, recursos, conexiones)

**Pipeline variables del Release** (scope: todo el Release):
- Credenciales compartidas entre todos los ambientes
- `containerRegistryPassword`, `containerRegistryUsername`

### Impacto
- Si se ponen en VG: funcionaría pero es **arquitectónicamente incorrecto**
- Si faltan: Release falla con "unable to pull image" o "authentication required"

### Solución CORRECTA
Agregar las 2 variables en **Pipeline variables del Release**, NO en Variable Groups:

```bash
# 1. Leer el Release actual
curl -s -u ":${AZURE_DEVOPS_PAT}" \
  "https://vsrm.dev.azure.com/Shared-Service-GM/DevOps/_apis/release/definitions/${RELEASE_ID}?api-version=7.1" \
  > release.json

# 2. Agregar variables en Pipeline variables (a nivel de Release)
cat release.json | jq \
  '.variables.containerRegistryPassword = {"value": "<VALOR_REAL>"} | 
   .variables.containerRegistryUsername = {"value": "gmonhubacreastus20001"}' \
  > release-updated.json

# 3. Actualizar el Release
curl -s -X PUT -u ":${AZURE_DEVOPS_PAT}" \
  -H "Content-Type: application/json" \
  "https://vsrm.dev.azure.com/Shared-Service-GM/DevOps/_apis/release/definitions/${RELEASE_ID}?api-version=7.1" \
  -d @release-updated.json
```

**⚠️ IMPORTANTE**: El valor de `containerRegistryPassword` debe ser el **password real**,
no una referencia como `$env:VARIABLE`. Las Pipeline variables del Release se evalúan
como literales.

### Prevención
✅ **Entender la diferencia VG vs Pipeline variables**:
- **Variable Groups**: configuración por ambiente (namespace, recursos, conexiones específicas)
- **Pipeline variables**: configuración compartida entre todos los ambientes (credenciales ACR)

✅ **Usar nombres descriptivos en MINÚSCULAS** para `servicesname`:
- ❌ `auth-api` (muy genérico)
- ❌ `Optica-Ecosystem-auth-api` (mayúsculas incorrectas)
- ✅ `optica-ecosystem-auth-api` (descriptivo y minúsculas)

✅ **Configurar approver en Producción**:
- Grupo: `Release Executers` (ID: `397ddbfe-1d60-4533-a4c9-b099f80ac154`)
- `isAutomated: false` en el stage de Producción

**Referencia**: Las 2 variables se ven en la UI de cualquier Release AKS existente
(ej. Release #400) en la pestaña Variables.

---

## 🔴 Error #7: Variables containerRegistry* en Variable Groups (lugar incorrecto)

### Síntoma
Usuario reporta: "las pusiste donde no era van en pipeline variables no es el 
variables group"

Poner `containerRegistryPassword` y `containerRegistryUsername` en los 
**Variable Groups** (ej. `Desarrollo-Optica-Ecosystem-auth-api`) en lugar de
las **Pipeline variables del Release**.

### Causa Raíz
Confusión sobre arquitectura de variables:
- **Variable Groups**: configuración específica por ambiente (namespace, recursos)
- **Pipeline variables del Release**: credenciales compartidas entre todos los ambientes

### Impacto
- Variables no disponibles para stages que las necesitan (~10 minutos en corrección)
- Arquitectura incorrecta (funciona pero es conceptualmente incorrecto)

### Solución CORRECTA

**NO** agregar a Variable Groups:
```json
❌ Variable Group "Desarrollo-Optica-Ecosystem-auth-api":
{
  "containerRegistryPassword": "$env:CONTAINER_REGISTRY_PASSWORD",
  "containerRegistryUsername": "gmonhubacreastus20001"
}
```

**SÍ** agregar a Pipeline variables del Release:
```bash
curl -s -u ":${AZURE_DEVOPS_PAT}" \
  "https://vsrm.dev.azure.com/Shared-Service-GM/DevOps/_apis/release/definitions/${RELEASE_ID}?api-version=7.1" | \
  jq '.variables.containerRegistryPassword = {"value": "REDACTED"} |
      .variables.containerRegistryUsername = {"value": "gmonhubacreastus20001"}' | \
  curl -s -X PUT -u ":${AZURE_DEVOPS_PAT}" \
    -H "Content-Type: application/json" \
    "https://vsrm.dev.azure.com/Shared-Service-GM/DevOps/_apis/release/definitions/${RELEASE_ID}?api-version=7.1" \
    -d @-
```

### Prevención
✅ **Variable Groups** = configuración por ambiente (namespace, recursos, conexiones)  
✅ **Pipeline variables del Release** = credenciales compartidas (ACR password/username)  
✅ Revisar Release existente (#400) para ver dónde están estas variables

---

## 🔴 Error #8: servicesname con mayúsculas

### Síntoma
Usuario reporta: "servicesname el valor quedo con mayusculas tienen q ir en miniscula"

Valor configurado: `Optica-Ecosystem-auth-api` (con mayúsculas)  
Valor esperado: `optica-ecosystem-auth-api` (todo minúsculas)

### Causa Raíz
No seguir convención de Kubernetes/Docker de lowercase para nombres de servicios.

### Impacto
- Kubernetes rechaza manifests con nombres en mayúsculas (~5 minutos en corrección)
- Inconsistencia con otros pipelines del proyecto

### Solución
Actualizar `servicesname` en los 3 Variable Groups:

```bash
# Para cada Variable Group (550, 551, 552)
curl -s -u ":${AZURE_DEVOPS_PAT}" \
  "https://dev.azure.com/Shared-Service-GM/DevOps/_apis/distributedtask/variablegroups/${VG_ID}?api-version=7.1" | \
  jq '.variables.servicesname.value = "optica-ecosystem-auth-api"' | \
  curl -s -X PUT -u ":${AZURE_DEVOPS_PAT}" \
    -H "Content-Type: application/json" \
    "https://dev.azure.com/Shared-Service-GM/DevOps/_apis/distributedtask/variablegroups/${VG_ID}?api-version=7.1" \
    -d @-
```

### Prevención
✅ **SIEMPRE** usar lowercase para `servicesname`  
✅ Formato recomendado: `<sistema>-<app>` (ej. `optica-ecosystem-auth-api`)  
✅ Nunca usar mayúsculas iniciales en nombres de servicios

---

## 🔴 Error #9: Variables scoped solo a Prod (faltan en Dev/UAT)

### Síntoma
Usuario reporta con screenshot: "esas variables las dejaste para el stage prod 
faltan para el stage desarrollo y uat"

Variables `containerRegistryPassword` y `containerRegistryUsername` están 
configuradas con **scope = Prod**, pero NO están disponibles para stages 
Desarrollo y UAT.

### Causa Raíz
Al agregar variables al Release, se pusieron solo en Pipeline variables (nivel Release)
o se configuró un scope específico de Prod, pero NO se agregaron como 
**stage-level variables** en Desarrollo (env 733) y UAT (env 734).

### Impacto
- Desarrollo y UAT NO pueden autenticarse contra ACR (~10 minutos en corrección)
- Despliegue falla con "unable to pull image" en Dev/UAT

### Solución CORRECTA
Las variables deben estar en **AMBOS lugares**:

1. **Pipeline variables** (nivel Release - opcional pero recomendado):
```json
{
  "variables": {
    "containerRegistryPassword": {"value": "REDACTED"},
    "containerRegistryUsername": {"value": "gmonhubacreastus20001"}
  }
}
```

2. **Stage-level variables** (en cada environment):
```bash
curl -s -u ":${AZURE_DEVOPS_PAT}" \
  "https://vsrm.dev.azure.com/Shared-Service-GM/DevOps/_apis/release/definitions/${RELEASE_ID}?api-version=7.1" | \
  jq '.environments[0].variables.containerRegistryPassword = {"value": "REDACTED"} |
      .environments[0].variables.containerRegistryUsername = {"value": "gmonhubacreastus20001"} |
      .environments[1].variables.containerRegistryPassword = {"value": "REDACTED"} |
      .environments[1].variables.containerRegistryUsername = {"value": "gmonhubacreastus20001"} |
      .environments[2].variables.containerRegistryPassword = {"value": "REDACTED"} |
      .environments[2].variables.containerRegistryUsername = {"value": "gmonhubacreastus20001"}' | \
  curl -s -X PUT -u ":${AZURE_DEVOPS_PAT}" \
    -H "Content-Type: application/json" \
    "https://vsrm.dev.azure.com/Shared-Service-GM/DevOps/_apis/release/definitions/${RELEASE_ID}?api-version=7.1" \
    -d @-
```

**Verificación**:
```bash
curl -s -u ":${AZURE_DEVOPS_PAT}" \
  "https://vsrm.dev.azure.com/Shared-Service-GM/DevOps/_apis/release/definitions/${RELEASE_ID}?api-version=7.1" | \
  jq '{
    pipelineVars: .variables,
    stages: [.environments[] | {name, vars: .variables}]
  }'
```

### Prevención
✅ Variables de ACR **siempre** deben estar en los 3 stages (Desarrollo, UAT, Producción)  
✅ Verificar scope en UI: Variables tab → "Scope" column debe mostrar el stage correcto  
✅ Mejor: agregar a **Pipeline variables** (disponibles para todos) Y **stage-level** (explícito)

---

## 📊 Resumen de Tiempo Perdido por Errores

Basado en experiencia real del pipeline Auth.API (2026-11-24):

| Error | Tiempo Perdido | Prevención |
|---|---|---|
| #1 - YAML en lugar de CLASSIC | ~30 min | Leer skills ANTES |
| #2 - Faltaban parámetros Deployment | ~5 min | Build → 3 paths |
| #3 - Plan con VG ejecutado | ~5 min | Plan base limpio |
| #4 - approvalRequired sin approver | ~10 min | false O approverId |
| #5 - Journal "ambiguous" | ~10 min | Readback manual |
| #6 - Variables containerRegistry* faltantes | ~5 min | Checklist VG |
| #7 - containerRegistry* en VG (incorrecto) | ~10 min | Pipeline vars |
| #8 - servicesname con mayúsculas | ~5 min | Lowercase siempre |
| #9 - Variables solo en Prod scope | ~10 min | 3 stages siempre |
| **Total** | **~90 min** | **60% tiempo trabajo** |

**Tiempo total del trabajo**: ~2.5 horas  
**Tiempo perdido en errores**: ~1.5 horas (60%)  
**Tiempo efectivo**: ~1 hora

**Lección clave**: Leer la documentación del dominio PRIMERO + seguir checklist evita el 85% de los errores.

---

## ✅ Checklist Pre-Flight (OBLIGATORIO)

Antes de crear cualquier pipeline CLASSIC:

- [ ] Leer `.cursor/skills/manage-azure-devops-pipelines/SKILL.md`
- [ ] Leer `references/ado-classic-payload-templates.md`
- [ ] Leer `references/ado-new-pipeline-intake-template.md`
- [ ] Revisar memorias `ado-pipeline-builder/*.md`
- [ ] Confirmar: ¿CLASSIC o YAML? (siempre CLASSIC)
- [ ] Identificar: ¿AKS o DACPAC? (task groups distintos)
- [ ] Verificar manifests K8s listos (si AKS)
- [ ] Confirmar Service Connections disponibles
- [ ] Verificar approver para Producción (si aplica)

## ✅ Checklist Post-Creación (OBLIGATORIO)

Después de crear Variable Groups y Release:

- [ ] **Verificar Variable Groups contienen**:
  - [ ] `servicesname` = nombre descriptivo **en minúsculas** (ej. `optica-ecosystem-auth-api`)
  - [ ] Resto de variables estándar (ambiente, namespace, tag, conexiones, recursos)
  - [ ] **NO** deben contener `containerRegistryPassword` ni `containerRegistryUsername`
  
- [ ] **Verificar Release Pipeline variables contienen**:
  - [ ] `containerRegistryPassword` = valor real (no `$env:...`)
  - [ ] `containerRegistryUsername` = `gmonhubacreastus20001`
  
- [ ] **Verificar Release stage-level variables** (en cada environment):
  - [ ] **Desarrollo (env 733)**: `containerRegistryPassword`, `containerRegistryUsername`
  - [ ] **UAT (env 734)**: `containerRegistryPassword`, `containerRegistryUsername`
  - [ ] **Producción (env 735)**: `containerRegistryPassword`, `containerRegistryUsername`
  
- [ ] **Verificar Release estructura**:
  - [ ] Artifact source correcto (Build ID)
  - [ ] 3 stages con branch filters correctos (develop, uat, release)
  - [ ] Variable Groups linkeados en cada stage (IDs correctos)
  - [ ] Task groups correctos por stage (Deployment-Azur-Aks-v3)
  
- [ ] **Verificar Pre-deployment Approvals en Producción**:
  - [ ] `isAutomated: false` (aprobación manual requerida)
  - [ ] Approver configurado: grupo `Release Executers` (ID `397ddbfe-1d60-4533-a4c9-b099f80ac154`)
  - [ ] `releaseCreatorCanBeApprover: false` (el creador NO puede auto-aprobar)
  
  **Verificación rápida**:
  ```bash
  curl -s -u ":${AZURE_DEVOPS_PAT}" \
    "https://vsrm.dev.azure.com/Shared-Service-GM/DevOps/_apis/release/definitions/442?api-version=7.1" | \
    jq '.environments[] | select(.name == "Produccion") | .preDeployApprovals.approvals[0].approver.displayName'
  ```
  Debe devolver: `"[Shared-Service-GM]\\Release Executers"`

---

## 📚 Referencias

- **Lecciones detalladas**: `lecciones-aprendidas-auth-api-pipeline.md` (interno)
- **Skill principal**: `.cursor/skills/manage-azure-devops-pipelines/SKILL.md`
- **Patrones**: `patterns.md` (esta memoria)
- **Templates**: `references/ado-classic-payload-templates.md`
- **Intake**: `references/ado-new-pipeline-intake-template.md`

---

## 🔧 Referencia Rápida - Valores Críticos para Pipeline AKS

Para evitar errores comunes, estos son los valores exactos que se usan en **todos** los pipelines AKS de Optica Ecosystem:

### Variable Groups (scope por ambiente)
```json
{
  "servicesname": "optica-ecosystem-auth-api",  // ⚠️ SIEMPRE lowercase
  // ... resto de variables por ambiente (namespace, recursos, etc.)
  // ❌ NO incluir containerRegistryPassword ni containerRegistryUsername aquí
}
```

### Release Pipeline Variables (compartidas)
```json
{
  "containerRegistryPassword": {
    "value": "REDACTED"  // ⚠️ Valor real, no $env:...
  },
  "containerRegistryUsername": {
    "value": "gmonhubacreastus20001"
  }
}
```

### Release Stage-Level Variables (cada environment)
Mismo contenido que Pipeline variables, pero en:
- `environments[0]` (Desarrollo, env ID 733)
- `environments[1]` (UAT, env ID 734)
- `environments[2]` (Producción, env ID 735)

### Pre-deployment Approval (solo Producción)
```json
{
  "approvals": [{
    "isAutomated": false,
    "approver": {
      "id": "397ddbfe-1d60-4533-a4c9-b099f80ac154",
      "displayName": "[Shared-Service-GM]\\Release Executers"
    }
  }],
  "approvalOptions": {
    "releaseCreatorCanBeApprover": false
  }
}
```

**Regla mnemotécnica**:
- **VG** = lowercase servicesname + config por ambiente
- **Pipeline vars** = ACR credentials (compartidas)
- **Stage vars** = ACR credentials (explícitas por stage)
- **Prod approval** = Release Executers (397ddbfe...)

---

## Error — Replace tokens en Dr.Max-Project / Optica (2026-11-24)

### Síntoma
Build clásico Optica (713/714/715) muestra step **Replace tokens** con
Source files=`Dockerfile` aunque el Dockerfile del repo no usa `#{...}#`.

### Causa
`New-AdoBuildDefinitionPayload` agregaba Replace tokens automáticamente cuando
`dockerfile.generatedByFileCreator=false` (pensado para Buklo con tokens).

### Solución
- Generador: no agregar Replace tokens si `repo.project=Dr.Max-Project` (salvo
  `requiresReplaceTokens=true`).
- Builds ya creados: update con splice `Remove-AdoBuildStepByDisplayName`.
- Manifests File Creator: incluir siempre HPA; `hostAliases` solo con vars de BD.

### Prevención
Leer `patterns.md` § Dr.Max-Project higiene antes de generar el siguiente
pipeline Optica.
