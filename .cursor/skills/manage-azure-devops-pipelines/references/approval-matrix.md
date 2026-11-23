# Matriz de aprobación — Azure DevOps Pipelines

Resumen operativo de `.claude/rules/azure-devops-pipelines/authorization.md`.
Ante cualquier ambigüedad, esa regla es la fuente de verdad; esta tabla es
solo una referencia rápida para el modo `run-monitor`/`classic-*`.

**"Release" es ambiguo** — ver "Terminología" en `authorization.md`. En
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

Ver `.claude/rules/azure-devops-pipelines/security.md`. Ningún nivel de
aprobación habilita esas acciones.
