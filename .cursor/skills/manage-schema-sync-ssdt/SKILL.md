---
name: manage-schema-sync-ssdt
description: Opera, revisa y diagnostica la sincronizacion de esquemas SQL hacia repositorios SSDT mediante SchemaSyncTool, SqlPackage, Azure DevOps y n8n.
triggers: [schema sync, ssdt, dacpac, base de datos, schema, sincronizacion]
always: false
---

# Manage Schema Sync SSDT

> **Estado de madurez (Fase 3 — declarado 2026-09-11):** este dominio opera
> como **guía de análisis con herramientas externas** (SchemaSyncTool, SqlPackage,
> n8n-interno), no como dominio con maquinaria plan/apply/test automatizada propia.
> El orquestador de Schema Sync vive en n8n-interno; los scripts de aplicación son
> los de SqlPackage y SchemaSyncTool. No tiene `Apply-*.ps1` propios porque la
> escritura va siempre por herramientas externas ya aprobadas. Esta decisión es
> intencional y no es deuda técnica.

## Cargar solamente el contexto necesario

Leer siempre:

- `schema-sync/README.md` para el procedimiento operativo.
- `schema-sync/databases.json` para el catálogo actual, si existe.

Leer `schema-sync/CONTEXTO-COMPLETO.md` cuando la solicitud involucre:

- Arquitectura.
- Historia o decisiones anteriores.
- Incidentes conocidos.
- Headers de módulos.
- SQL71501.
- Tooling global.
- Bundle core-workflow-global.

Leer el código o workflow real antes de proponer cambios. No reconstruir configuraciones desde la documentación si existe una fuente ejecutable.

## Catálogo ausente

`schema-sync/databases.json` puede no existir todavía. Si no existe:

- No reconstruir su contenido desde la documentación.
- No crear un `databases.json` vacío ni de relleno.
- Bloquear únicamente los modos que dependen del catálogo (marcados como
  "requiere catálogo" en cada modo) y reportarlo como bloqueo, indicando que
  falta incorporar el catálogo desde la fuente operativa real.
- Permitir sin restricción los modos de revisión, diagnóstico documental,
  diseño y scaffolding seguro, que no dependen del catálogo.

## Invariantes

- No escribir en SQL.
- Permitir solamente Extract y consultas de metadatos de solo lectura.
- Exigir ApplicationIntent=ReadOnly.
- Rechazar Publish, Deploy y TargetConnectionString.
- No ejecutar DDL, DML ni cambios de seguridad.
- Operar una sola BD por vez.
- No ejecutar batch ni orquestador salvo solicitud explícita.
- No habilitar schedules automáticamente.
- No completar PR automáticamente.
- No exponer secretos.

Estas reglas no pueden omitirse aunque el usuario solicite rapidez. Si se requiere una escritura SQL, detener el flujo y entregar el cambio como recomendación para el proceso DBA autorizado.

## Clasificar la solicitud

Clasificarla en uno de estos modos:

1. Consultar estado. (requiere catálogo)
2. Diagnosticar un error.
3. Revisar configuración o cambios.
4. Ejecutar una BD. (requiere catálogo)
5. Crear o validar un cascarón SSDT.
6. Incorporar una BD nueva. (el paso de catálogo requiere catálogo)
7. Modificar SchemaSyncTool.
8. Publicar SchemaSyncTool en el host.
9. Trabajar con bundle core-workflow-global. (requiere catálogo)
10. Ejecutar múltiples bases. (requiere catálogo)

Aplicar solamente el procedimiento del modo seleccionado.

## Modo 1: consultar estado (requiere catálogo)

0. Si `schema-sync/databases.json` no existe, detener este modo y reportarlo
   como bloqueado. No continuar ni reconstruir el catálogo.
1. Leer databases.json.
2. Resolver por nombre real de BD y no solamente por nombre de repo.
3. Determinar enabled, server, repoName, projectName, bundle y workflow.
4. Localizar `schema-sync/results/<database>.json` si está disponible.
5. Leer status, hadDrift, commitSha, prUrl, buildOk, message y timestamp.
6. No ejecutar el workflow.
7. Reportar hechos, inconsistencias y pendientes.

## Modo 2: diagnosticar un error

Disponible aunque `schema-sync/databases.json` no exista.

1. Leer result JSON y logs proporcionados.
2. Identificar la primera operación que falló.
3. Clasificar el fallo en Extract, Compare, PublishChangesToProject, Sanitize, RefreshAllModulesFromDb, Assert, Git, PR, build/modelo o Teams.
4. Comparar con los incidentes documentados.
5. Determinar si el origen está en la BD, el tool, SSDT, configuración, red o credenciales.
6. Separar errores primarios de errores secundarios.
7. Proponer el cambio mínimo.
8. No volver a ejecutar ni modificar archivos salvo que el usuario lo solicite.
9. No modificar SQL.

## Modo 3: revisar configuración o cambios

Disponible aunque `schema-sync/databases.json` no exista.

1. Revisar únicamente los archivos afectados.
2. Comprobar garantías de solo lectura.
3. Verificar mapping database/repo/project.
4. Verificar main hacia release sin autocomplete.
5. Buscar secretos o conexiones completas.
6. Validar JSON, shell, PowerShell o .NET según corresponda.
7. Utilizar schema-sync-reviewer para una revisión independiente cuando el cambio sea significativo.
8. Presentar hallazgos antes de realizar una acción externa.

## Modo 4: ejecutar una BD (requiere catálogo)

0. Si `schema-sync/databases.json` no existe, detener este modo y reportarlo
   como bloqueado. No continuar ni reconstruir el catálogo.
1. Exigir una sola BD identificada de forma exacta.
2. Confirmar enabled=true en databases.json.
3. Confirmar el workflow individual.
4. Verificar que no sea ScHmSyNcOrCh0001.
5. Informar que la ejecución puede modificar Git, hacer push a main, crear/reutilizar un PR y notificar a Teams.
6. Ejecutar solamente si la petición autoriza explícitamente la corrida.
7. No ejecutar por el simple hecho de revisar estado o diagnosticar.
8. Esperar el resultado.
9. Leer `schema-sync/results/<database>.json`.
10. Verificar status, hadDrift, commitSha, prUrl y buildOk.
11. No completar el PR.
12. Detenerse si la BD resuelta no coincide con la solicitada.

## Modo 5: crear o validar un cascarón SSDT

Disponible aunque `schema-sync/databases.json` no exista: el cascarón es
siempre anterior al catálogo.

1. Confirmar que el repo ADO existe y revisar su contenido real.
2. Crear cascarón solo si está vacío o contiene únicamente README y no tiene
   .sqlproj, .slnx ni build-dacpac.ps1.
3. Preservar README y archivos existentes no relacionados.
4. Usar como referencia project_sqldb_core_arthur, sin copiar su ProjectGuid.
5. Crear .gitignore, build-dacpac.ps1, .slnx, .sqlproj, Properties y los
   placeholders de scripts de datos.
6. Usar Sql170DatabaseSchemaProvider salvo estándar diferente del repo.
7. Validar Name, RootNamespace, AssemblyName y BySchemaAndSchemaType.
8. Ejecutar build-dacpac.ps1 y exigir cero errores.
9. Confirmar que bin, obj, out y *.dacpac no entren a Git.
10. Para una BD grande, preparar import desde DACPAC en vez de Compare live.
11. No modificar databases.json, crear n8n ni habilitar schedule en este modo.
12. No escribir en SQL.
13. No hacer commit o push del cascarón sin autorización explícita.

## Modo 6: incorporar una BD nueva

Los pasos 1-5 y 7-10 están disponibles aunque `schema-sync/databases.json`
no exista. El paso 6 (añadir configuración al catálogo) requiere catálogo:
si el archivo no existe, detener ese paso específico y reportarlo como
bloqueado — no crear el archivo automáticamente ni con contenido vacío o
reconstruido.

1. Leer docs/specs/schema-sync-onboarding-template.md.
2. Confirmar nombre real, servidor, conectividad y tipo Azure MI/on-prem.
3. Confirmar identidad SQL de solo lectura.
4. Revisar si el repo requiere cascarón y aplicar el Modo 5 si corresponde.
5. Confirmar que repo, sqlproj, solución y build-dacpac.ps1 ya existen y
   compilan después del import.
6. Añadir configuración con enabled=false (requiere catálogo).
7. Preparar workflow individual sin activarlo.
8. Validar JSON y parámetros.
9. Ejecutar dry-run seguro.
10. Presentar cambios y riesgos.
11. No importar workflow, cambiar enabled, activar schedule ni ejecutar sync sin autorización explícita.

## Modo 7: modificar SchemaSyncTool

Disponible aunque `schema-sync/databases.json` no exista.

1. Localizar el código responsable.
2. Revisar tests y casos históricos relacionados.
3. Realizar el cambio mínimo.
4. Ejecutar dotnet build.
5. Ejecutar las pruebas disponibles.
6. Ejecutar únicamente self-tests que no conecten ni escriban en SQL.
7. Solicitar revisión independiente.
8. No desplegar automáticamente al host.
9. No ejecutar una BD automáticamente.

## Modo 8: publicar SchemaSyncTool

Disponible aunque `schema-sync/databases.json` no exista.

1. Requerir una solicitud explícita de despliegue.
2. Revisar que build y tests estén correctos.
3. Publicar para linux-x64 mediante el comando documentado.
4. Revisar el contenido de salida.
5. Copiar el conjunto aprobado al host mediante el procedimiento autorizado.
6. No imprimir credenciales.
7. Verificar la versión y self-tests seguros en el host.
8. Ejecutar una BD piloto solamente si fue solicitada explícitamente.

## Modo 9: bundle core-workflow-global (requiere catálogo)

0. Si `schema-sync/databases.json` no existe, detener este modo y
   reportarlo como bloqueado antes de tratar el bundle como entrada
   habilitable.
1. Leer `schema-sync/bundles/core-workflow-global.json`.
2. Tratar global y workflow como una única operación ordenada.
3. Ejecutar global antes de workflow.
4. Preservar [$(sqldb_core_global)].
5. Fallar si queda una referencia literal sin variable SQLCMD.
6. Utilizar un solo commit, PR, lock y work-root.
7. Ejecutar primero self-test-sqlcmd.

## Modo 10: múltiples bases (requiere catálogo)

0. Si `schema-sync/databases.json` no existe, detener este modo y
   reportarlo como bloqueado.
1. No inferir autorización batch a partir de una solicitud ambigua.
2. Exigir lista exacta de bases y confirmación explícita.
3. Presentar dry-run y orden de ejecución.
4. Tener presente que ScHmSyNcOrCh0001 (núcleo) y F9RXPgIJQ7QzZ15q (negocio+staging) están ACTIVOS con el gate abierto (estado 2026-11-09); cualquier cambio se aplica a los dos y se respalda antes.
5. No cambiar do_not_auto_run automáticamente.
6. Detenerse ante el primer fallo salvo instrucción diferente aprobada.
7. Consolidar resultados sin completar PR.

## Formato de entrega

Entregar siempre:

- Modo aplicado.
- Base o alcance resuelto.
- Fuentes consultadas.
- Acciones realizadas.
- Validaciones ejecutadas.
- Resultado JSON cuando exista.
- Commits y PR creados por el tool.
- buildOk.
- Riesgos o datos faltantes.
- Acciones externas no ejecutadas.
- Confirmación de que no se escribió en SQL.
