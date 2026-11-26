# Matriz de aprobación — Azure DevOps Pipelines

Resumen operativo del dominio de autorización de Azure DevOps Pipelines.
Ante cualquier ambigüedad, la fuente de verdad es `.cursor/rules/azure-devops.mdc`.
Esta tabla es solo una referencia rápida para el modo `run-monitor`/`classic-*`.

**"Release" es ambiguo** — ver "Terminología" en `.cursor/rules/azure-devops.mdc`. En
esta tabla, "Release" dentro de "Preguntar una vez" significa siempre la
**definición** (objeto de configuración); "Release" dentro de "Aprobación
separada" significa siempre una **instancia real** (ejecución/despliegue).

## Permitido sin pregunta adicional

- Consultar proyectos, repositorios, ramas y definiciones (Build/Release).
- Leer builds, releases, logs y artefactos.
- Consultar nombres/metadatos de Variable Groups, task groups, pools y
  service connections — nunca sus valores secretos.
- Generar inventarios, planes, exports sanitizados, diffs y dry-runs.
- Consultar por MCP o `Get-AdoClassicVariables.ps1` nombres y valores no
  secretos de Builds, Releases y Variable Groups.
- Validar archivos locales y ejecutar pruebas de hooks/scripts.
- `npm view @azure-devops/mcp version` y operaciones equivalentes de solo
  consulta de versión del paquete.

## Preguntar una vez por operación atómica

Cubre la creación o actualización configuracional completa de un pipeline
(Variable Groups/Libraries + definiciones Build/Release) cuando el plan
presentado enumeró: organización/proyecto, familia (AKS o DACPAC),
aplicación/base y ambientes, recursos a crear o actualizar, ids/revisiones de
las definiciones existentes, repo/branch/path filters/pool, task groups y
service connections referenciados, triggers/filtros/aprobadores, cuerpos
exactos y efectos + plan de verificación esperados.

**Actualizado 2026-09-08**: si el plan enumeró explícitamente que va a
encolar el Build y ejecutar/crear la primera instancia de Release real
para **Desarrollo y UAT**, esa misma aprobación también cubre esas 2
ejecuciones — no hace falta una tarjeta aparte para cada una. Producción
queda siempre excluida de esta ampliación (ver abajo).

El `ado-pipeline-builder` prepara y valida sin escrituras y entrega los
artefactos a la sesión principal. El transcript principal presenta mediante
`ExitPlanMode` el plan validado, todos los comandos exactos de
`Apply-AdoClassicPlan.ps1` y los SHA-256 de cada plan/inventario dentro de un
bloque visible `ado-apply-authorization`. Esa aprobación permite cada comando
enumerado durante 24 horas sin una segunda tarjeta. Un reintento local sigue
cubierto solamente si el journal confirma que ninguna operación remota salió
de `pending`; si existe estado `in-progress`, `succeeded` o `ambiguous`, se
detiene para readback y nueva aprobación. Cada `apply` puede correr todas las
escrituras internas de su manifiesto sin preguntar por cada llamada. Cualquier
desviación, transcript distinto o vencimiento mantiene `ask`; no se reutiliza
para otra base/app, ambiente no listado o pipeline.

## Actualizar Variable Groups existentes (update-variable-group)

**Agregado 2026-10-14.** Capacidad para editar variables en un Variable Group
existente sin recrearlo. A diferencia de `create-variable-group` (que crea
desde cero), `update-variable-group` hace un PUT que **preserva** todas las
variables no mencionadas en el plan y la estructura del VG (`name`, `type`,
`variableGroupProjectReferences`).

### Flujo

1. **GET previo obligatorio**: antes del Apply, obtener el body actual del VG
   con MCP (`wit_work_item` no aplica — usar REST directo o
   `Get-AdoClassicVariables.ps1 -VariableGroupId <id> -Raw`).
2. **Plan**: incluir `variableGroupUpdate: { id: <int>, variables: { <key>: "<value>", ... } }`.
   Solo las claves listadas se mutan; las demás se preservan.
3. **Apply**: pasar el body del GET como `-CurrentVariableGroupJson "<json>"`.

### Ejemplo de plan

```json
{
  "project": "DevOps",
  "variableGroupUpdate": {
    "id": 507,
    "variables": {
      "reqcpu": "500",
      "limcpu": "1000"
    }
  },
  "approvedOperations": [
    {
      "operationId": "vg-update-507",
      "operationType": "update-variable-group",
      "method": "PUT",
      "uri": "https://dev.azure.com/Shared-Service-GM/DevOps/_apis/distributedtask/variablegroups/507?api-version=7.1"
    }
  ]
}
```

### Ejemplo de Apply

```powershell
# 1. Obtener el VG actual
$currentVG = curl -s -u ":$env:AZURE_DEVOPS_PAT" \
  "https://dev.azure.com/Shared-Service-GM/DevOps/_apis/distributedtask/variablegroups/507?api-version=7.1"

# 2. Aplicar el plan
& './Apply-AdoClassicPlan.ps1' `
  -PlanPath '/path/to/plan.json' `
  -InventoryPath '/path/to/inventory.json' `
  -CurrentVariableGroupJson $currentVG
```

### Seguridad

- `New-AdoVariableGroupUpdatePayload` valida que el `id` del plan coincida con
  el del VG actual — rechaza si hay mismatch (protección contra aplicar un
  plan a un VG equivocado).
- Las variables con `isSecret: true` preservan ese flag al mutar su valor.
- El VG debe existir; un id inexistente falla en el PUT con 404.

### Aprobación

Sigue la regla de "Preguntar una vez": si el plan enumeró el update en
`approvedOperations` con operationType `update-variable-group`, el Apply
queda cubierto por esa aprobación. No se agrupa con creates ni deletes.

---

## Aprobación separada obligatoria (nunca agrupable)

- Encolar un Build o crear/ejecutar un Release real **no enumerado**
  previamente en el plan de la aprobación atómica (Desarrollo/UAT sí
  pueden quedar cubiertos, ver arriba).
- Ejecutar o reintentar un pipeline fuera de la envolvente ya aprobada.
- Crear o desplegar un Release real para **Producción** — siempre, sin
  excepción.
- Desplegar a Producción.
- Ejecutar DACPAC en modo `Apply`.
- Usar `Get-AdoClassicVariables.ps1 -RevealLocalSecrets`: una tarjeta por
  consulta exacta; el PAT permanece oculto siempre.
- Aprobar un stage.
- Activar CD automático si puede desplegar de inmediato.
- Eliminar una definición existente (cada borrado usa un plan individual).
- Modificar task groups, service connections o pools compartidos.
- Cambiar permisos, ACL o membresías de grupos. La configuración exacta de
  aprobadores dentro de la definición de Release sí puede incluirse en el plan
  atómico de creación/actualización.
- Eliminar recursos parciales como rollback de una operación fallida.

## Prohibido permanentemente

Ver `.cursor/rules/azure-devops.mdc` (sección prohibiciones permanentes). Ningún nivel de
aprobación habilita esas acciones.
