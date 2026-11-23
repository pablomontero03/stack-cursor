# Spec de incorporación a Schema Sync

## Solicitud

- Solicitante:
- Fecha:
- Motivo:
- Historia de usuario o tarea:

## Base de datos

- Nombre real de la BD:
- Servidor:
- Tipo: Azure SQL MI / SQL Server on-prem / otro
- Tamaño aproximado:
- Cantidad aproximada de tablas:
- Características especiales:
- Existe una BD con nombre parecido:

## Acceso

- Usuario de solo lectura:
- ApplicationIntent=ReadOnly verificado: sí/no
- VIEW DEFINITION verificado: sí/no
- SELECT requerido verificado: sí/no
- Sin db_owner/db_datawriter/db_ddladmin: sí/no
- Conectividad desde host 172.16.2.60: sí/no/no aplica

No escribir passwords, PAT o connection strings completas en esta spec.

## Azure DevOps y SSDT

- Organización:
- Proyecto:
- Repo:
- Repo URL:
- Branch de sync: main
- Branch PR: release
- Nombre del proyecto SSDT:
- Ruta del sqlproj:
- Ruta de la solución:
- build-dacpac.ps1 disponible: sí/no
- Proyecto nuevo o existente:

## Evaluación de cascarón SSDT

- Estado inicial del repo: vacío / solo README / proyecto SSDT existente
- Cascarón requerido: sí/no
- Plantilla de referencia: core_arthur / otra plantilla aprobada
- README existente preservado: sí/no/no aplica
- ProjectGuid nuevo generado: sí/no/no aplica
- DSP confirmado:
- DefaultFileStructure=BySchemaAndSchemaType: sí/no/no aplica
- Scripts de datos declarados como None: sí/no/no aplica
- .gitignore excluye .vs, bin, obj, out y *.dacpac: sí/no
- Build del cascarón con cero errores: sí/no/no aplica
- Método de import: VS / Compare live / DACPAC + Compare
- Import de esquema validado: sí/no/pendiente

## Configuración propuesta

- database:
- repoName:
- projectName:
- sqlServer:
- kind:
- heavy:
- bundle:
- workflow ID propuesto:
- workflow name propuesto:
- schedule solicitado:
- enabled inicial: false

## Excepciones

- Users/permisos a ignorar:
- DatabaseOptions a ignorar:
- SQLCMD variables:
- Referencias entre proyectos:
- Objetos WITH ENCRYPTION:
- Problemas SQL71501 conocidos:
- Timeouts o tamaño especial:

## Plan de validación

- [ ] Nombre real confirmado.
- [ ] Listado de bases consultado.
- [ ] Repo y sqlproj confirmados.
- [ ] Necesidad de cascarón evaluada.
- [ ] Cascarón compilado con cero errores, si aplica.
- [ ] ProjectGuid nuevo verificado, si aplica.
- [ ] Artefactos bin/obj/out/dacpac excluidos de Git.
- [ ] Método de import seleccionado según tamaño y timeout.
- [ ] Import de esquema validado antes de catálogo y n8n.
- [ ] Build local ejecutado.
- [ ] Configuración añadida con enabled=false.
- [ ] Workflow validado sin importar.
- [ ] Dry-run revisado.
- [ ] Extract de solo lectura validado.
- [ ] Compare validado.
- [ ] Assert de tablas y PK validado.
- [ ] Result JSON validado.
- [ ] Push/PR revisado.
- [ ] Teams revisado.
- [ ] Schedule autorizado.

## Aprobaciones requeridas

- Habilitar enabled=true:
- Importar workflow:
- Ejecutar primera corrida:
- Activar schedule:
- Incluir en batch/orquestador:

## Resultado

- Estado:
- Commit:
- PR:
- buildOk:
- Result JSON:
- Pendientes:
