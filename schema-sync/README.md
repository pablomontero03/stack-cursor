# Schema Sync BD → Repos SSDT

Automatización de sincronización del esquema real de bases de datos hacia proyectos SSDT almacenados en Azure Repos.

La operación es de solo lectura contra SQL. El sistema extrae el esquema, compara contra el proyecto SSDT, actualiza archivos del repositorio cuando detecta drift, crea o reutiliza un PR y notifica el resultado.

Contexto histórico completo:

    ./CONTEXTO-COMPLETO.md

Catálogo y fuente de verdad actual:

    ./databases.json

Este README contiene solamente el procedimiento operativo. No utilizar cantidades de bases, estados enabled ni mappings copiados en otros documentos como fuente actual; consultar siempre databases.json y los workflows existentes.


## Regla de seguridad principal

Nunca escribir en ninguna base de datos.

Operaciones permitidas:

- SqlPackage /Action:Extract.
- Consultas de metadatos de solo lectura.
- ApplicationIntent=ReadOnly.
- Comparación de esquema.
- Modificación de archivos SSDT en disco y Git.
- Validación del proyecto o modelo DacFx.

Operaciones prohibidas:

- SqlPackage /Action:Publish.
- SqlPackage /Action:Deploy.
- TargetConnectionString.
- INSERT, UPDATE, DELETE o MERGE.
- CREATE, ALTER, DROP o TRUNCATE contra la BD.
- GRANT, REVOKE o cambios de roles/permisos.

PublishChangesToProject actualiza archivos SSDT en disco. No publica cambios en SQL.


## Flujo general

1. Extraer la BD con SqlPackage y ApplicationIntent=ReadOnly.
2. Generar el DACPAC de origen.
3. Comparar el DACPAC contra el proyecto SSDT.
4. Aplicar cambios únicamente al proyecto en disco.
5. Sanear users, sqlproj, objetos huérfanos y carpetas residuales.
6. Refrescar módulos desde OBJECT_DEFINITION cuando corresponda.
7. Auditar tablas, PK y constraints.
8. Repetir la comparación ignorando users, permisos, roles y DatabaseOptions.
9. Si existe drift real, hacer push automatizado a main.
10. Crear o reutilizar PR main → release, sin autocomplete.
11. Validar el DACPAC o el modelo DacFx.
12. Escribir el resultado JSON.
13. Notificar éxito o error mediante Power Automate hacia Teams.

El push y el PR pueden existir aunque buildOk sea false. En ese caso el resultado debe reportar status=error y el PR no debe completarse automáticamente.


## Garantías de solo lectura

- Usuario SQL de sincronización: usr_repo_sync.
- Sin roles db_owner, db_datawriter ni db_ddladmin.
- Connection string con ApplicationIntent=ReadOnly.
- SqlPackage limitado a /Action:Extract.
- SchemaSyncTool rechaza Publish, Deploy y TargetConnectionString.
- PAT de Azure DevOps con los scopes mínimos requeridos para Code y PR.
- Secretos únicamente en .env o credenciales seguras de n8n.
- Nunca incluir passwords, PAT, P8, tokens o connection strings completas en Git, workflows exportados, documentación o logs.

Existe un script DBA opcional:

    sql/harden-usr_repo_sync-readonly.sql

Ese script no forma parte de la ejecución automática de Schema Sync. Debe ejecutarlo un DBA mediante el proceso autorizado correspondiente.


## Infraestructura principal

SQL MI de producción:

    gmon-prod-sqlmi-eastus2-0001.15c9ad07b4c3.database.windows.net

Usuario de sincronización:

    usr_repo_sync

Host n8n y SchemaSyncTool:

    172.16.2.60

Ruta en el host:

    /home/soporte/schema-sync/

Ruta dentro de contenedores:

    /data/schema-sync

Ejecutable publicado:

    /home/soporte/schema-sync/publish/SchemaSyncTool

Resultados por base:

    /home/soporte/schema-sync/results/<database>.json

Clones de trabajo:

    /home/soporte/schema-sync/work/<repoName>/

Azure DevOps:

    Organización: Shared-Service-GM
    Proyecto: Database-Administration-and-Monitoring

Notificaciones:

    Power Automate: Notificaciones-DevOps


## Componentes del repositorio

Tool .NET:

    ./SchemaSyncTool/

Runner Linux y n8n:

    ./run-sync.sh

Runner Windows:

    ./run-sync.ps1

Runner PowerShell adicional:

    ./sync-schema-from-db.ps1

Catálogo:

    ./databases.json
    ./set-params.databases.json          (local, no versionado — ver "Configuración local")
    ./set-params.databases.example.json  (plantilla versionada)

Helper batch, dry-run por defecto:

    ./run-batch.sh

Bundles especiales:

    ./bundles/

Workflows n8n:

    ./n8n-workflow-schema-sync-*.json
    ./n8n-workflow-schema-sync-*.import.json

Contexto histórico:

    ./CONTEXTO-COMPLETO.md


## Configuración local (set-params)

`set-params.databases.example.json` es la plantilla versionada. Documenta la
forma esperada del archivo de parámetros (flags de ejecución, catálogo de
bases, estructura de bundle) con valores de ejemplo y placeholders del tipo
`${SCHEMA_SYNC_NOTIFY_WEBHOOK}`.

`set-params.databases.json` es la configuración local u operativa real.
Nunca se versiona. Vive únicamente en el entorno donde se ejecuta Schema
Sync (host n8n o equipo autorizado).

Reglas:

- El webhook de notificación debe provenir de las credenciales seguras de
  n8n o de una variable de entorno, nunca de un valor hardcodeado en el
  repositorio.
- Nunca copiar un webhook, token, contraseña o connection string real dentro
  del repositorio, ni siquiera temporalmente.
- Si se necesita documentar un cambio de forma del archivo, actualizar
  primero `set-params.databases.example.json` con placeholders.


## Fuente de verdad y nombres

Antes de operar una base:

1. Leer databases.json.
2. Confirmar enabled.
3. Confirmar el nombre real de la BD.
4. Confirmar repoName, repoUrl, sqlServer, projectName y workflow.
5. No asumir que el nombre de la BD es igual al repo o al sqlproj.

Ejemplo conocido:

    BD real: buklo_lab
    Repo/proyecto: project_sqldb_buklo_lab / sqldb_buklo_lab

El parámetro DATABASE y el archivo de resultado deben utilizar el nombre real de la BD:

    /home/soporte/schema-sync/results/buklo_lab.json

Para confirmar nombres se puede utilizar, según el ambiente:

    SchemaSyncTool --list-databases
    az sql midb list
    Visual Studio / SSMS con una conexión autorizada de solo lectura


## Operación segura de una sola base

La práctica normal es ejecutar una sola BD por vez.

Antes de ejecutar:

1. Confirmar nombre real de la BD.
2. Confirmar que enabled=true.
3. Confirmar el workflow individual correcto.
4. Verificar que el workflow no sea ScHmSyNcOrCh0001.
5. Confirmar que no se utilizará run-batch.sh --execute.
6. Informar que la corrida puede actualizar Git, hacer push a main, crear/reutilizar un PR y notificar a Teams.

Ejemplo para buklo_lab:

    docker exec n8n-n8n_main-1 n8n execute --id=ScHmSyNcBklLab01

Consultar el resultado:

    cat /home/soporte/schema-sync/results/buklo_lab.json

Validar después de la corrida:

- status.
- database.
- repo.
- synced.
- hadDrift.
- commitSha.
- prUrl.
- buildOk.
- message.
- timestamp.

No completar el PR automáticamente.


## Ejecución manual desde el host

Utilizar variables de ambiente o configuración segura para la BD exacta. No imprimir secretos.

Ejemplo general:

    sh /home/soporte/schema-sync/run-sync.sh

Desde un worker n8n:

    docker exec n8n-n8n_worker-1 sh /data/schema-sync/run-sync.sh

No ejecutar el runner sin confirmar previamente qué base y repo resolverá la configuración.


## Ejecución manual desde Windows

Ejemplo con placeholders:

    $env:SQL_USER = 'usr_repo_sync'
    $env:SQL_PASSWORD = '<secret>'
    $env:AZDO_PAT = '<secret>'
    Set-Location D:\Proyectos\automation\schema-sync
    .\run-sync.ps1

No guardar los valores reales en scripts, historial, documentación ni commits.


## Workflows individuales n8n

Cada base habilitada debe disponer de un workflow individual aprobado.

Flujo típico:

    Manual Trigger o Schedule
        → parámetros de una sola BD
        → Run Schema Sync
        → parsear resultado JSON
        → notificar OK o ERROR

El nodo de ejecución debe utilizar:

    sh /data/schema-sync/run-sync.sh

La imagen del worker puede ser Alpine; no asumir que bash está disponible.

El horario típico es Dom–Vie 19:00 America/Costa_Rica, pero el schedule real debe confirmarse en cada workflow antes de modificarlo o activarlo.


## Orquestador multi-BD

Workflow:

    ScHmSyNcOrCh0001
    Schema Sync Multi-BD (orquestador)

Estado requerido:

    Inactivo
    do_not_auto_run=true

El orquestador permanece montado para gate y preview. No debe ejecutar sincronizaciones automáticamente.

Reglas:

- No ejecutar el orquestador salvo solicitud explícita.
- No cambiar do_not_auto_run a false automáticamente.
- No conectar un nodo Run Sync automáticamente.
- No activar el workflow automáticamente.
- No ejecutar batch por inferencia.

El helper batch es dry-run por defecto:

    sh /home/soporte/schema-sync/run-batch.sh --dry-run

La ejecución real requiere una decisión explícita y controles adicionales:

    ALLOW_BATCH_RUN=1 sh /home/soporte/schema-sync/run-batch.sh --execute


## Bundle core-workflow-global

El repo project-qldb_core_workflow-sqldb_core_global contiene dos proyectos SSDT ordenados:

1. sqldb_core_global.
2. sqldb_core_workflow.

La especificación se encuentra en:

    ./bundles/core-workflow-global.json

Reglas:

- Tratarlo como una única entrada kind=solution-bundle.
- Sincronizar global antes de workflow.
- Preservar [$(sqldb_core_global)].
- Fallar si queda [sqldb_core_global]. sin variable SQLCMD.
- Generar un solo commit y un solo PR para ambos proyectos.
- Utilizar un solo lock y work-root.

Self-test autorizado, sin escribir en SQL:

    /data/schema-sync/publish/SchemaSyncTool --self-test-sqlcmd


## Crear un cascarón SSDT nuevo

Crear un cascarón solamente cuando el repo ADO está vacío o contiene solo un
README y todavía no existen .sqlproj, .slnx ni build-dacpac.ps1.

No crear otro cascarón si el repo ya tiene un proyecto SSDT, aunque esté
desactualizado. En ese caso se debe revisar el proyecto existente.

Orden obligatorio para una base nueva:

1. Confirmar que el repo ADO existe.
2. Evaluar si el repo necesita cascarón.
3. Crear el cascarón SSDT localmente.
4. Compilar el proyecto vacío con cero errores.
5. Revisar el diff y, con autorización, hacer push a main.
6. Importar el esquema mediante Visual Studio o DACPAC + Schema Compare.
7. Confirmar el nombre real de la BD.
8. Solamente después preparar databases.json y el workflow n8n.
9. Ejecutar una corrida piloto antes de activar el schedule.

No añadir enabled=true ni montar n8n hasta que el proyecto compile y el
esquema se haya importado o exista un camino de importación validado.

Referencias aprobadas:

- Histórica: project_sqldb_core_arthur, Task 21619 / US 18614.
- Otra plantilla equivalente puede aprobarse según el estándar vigente del equipo.

Estructura mínima:

    project_<Nombre>/
      .gitignore
      README.md
      build-dacpac.ps1
      <NombreProyecto>.slnx
      databases/<NombreProyecto>/
        <NombreProyecto>.sqlproj
        Properties/
        scripts/data/application/TKS-XXX/
        scripts/data/rollback/TKS-XXX/

Reglas del sqlproj:

- Utilizar Microsoft.Data.Tools.Schema.Sql.Sql170DatabaseSchemaProvider,
  salvo que el estándar vigente del repo indique otro DSP.
- Generar un ProjectGuid nuevo; nunca copiar el GUID de una plantilla.
- Name, RootNamespace y AssemblyName deben coincidir con el proyecto.
- Utilizar DefaultFileStructure=BySchemaAndSchemaType.
- Declarar scripts de datos como None para que no entren al DACPAC.
- Mantener el cascarón sin objetos de esquema hasta realizar el import.

El .gitignore debe excluir al menos .vs, bin, obj, archivos user, dbmdl, jfm
y msbuild.log. Si se genera un DACPAC local, excluir también out y *.dacpac.

Pasos operativos:

1. Crear o clonar el repo en C:\code\BaseDatos\project_<Nombre>.
2. Crear la estructura mínima sin sobrescribir un README existente.
3. Generar un ProjectGuid nuevo.
4. Ajustar $projectName dentro de build-dacpac.ps1.
5. Ejecutar .\build-dacpac.ps1 y exigir cero errores.
6. Revisar que bin, obj, out y DACPAC no queden staged.
7. Después de revisar el diff y con autorización, hacer commit y push a main
   con un mensaje de cascarón SSDT.
8. Importar el esquema.
9. Compilar nuevamente antes del onboarding de Schema Sync.

Para una BD muy grande, evitar un Compare live si existe riesgo de timeout.
Extraer el DACPAC con CommandTimeout alto y conexión de solo lectura; luego
utilizar Source=DACPAC y Target=proyecto vacío. Este es el camino recomendado
para cualquier base con un esquema demasiado grande para un Compare live.

El cascarón nunca autoriza escribir en la BD, habilitar n8n, modificar
databases.json o versionar un DACPAC.


## Incorporar una base nueva

Preparar primero la incorporación con enabled=false.

Pasos:

1. Confirmar el nombre real de la BD.
2. Confirmar servidor y si es Azure MI u on-prem.
3. Confirmar usuario de solo lectura y conectividad.
4. Determinar si el repo requiere un cascarón SSDT.
5. Si lo requiere, crear el cascarón, compilarlo e importar el esquema antes
   de continuar.
6. Confirmar repo SSDT, sqlproj, solución y build-dacpac.ps1 compilables.
7. Añadir la entrada a databases.json con enabled=false.
8. Actualizar Set-Params sin activar ejecución.
9. Crear el workflow individual desde la plantilla aprobada.
10. Validar JSON y parámetros.
11. Ejecutar un dry-run.
12. Revisar el resultado antes de importar el workflow o activar.
13. Habilitar enabled=true solamente con aprobación explícita.
14. Ejecutar una vez manualmente.
15. Revisar result JSON, Git, PR, build y Teams.
16. Activar schedule solamente si fue solicitado.


## Bases con esquema muy grande

Algunas bases pueden tener un esquema demasiado grande para que Visual
Studio complete un Import o Schema Compare en vivo sin timeout.

Camino recomendado para ese caso:

1. Extraer un DACPAC local con SqlPackage, `CommandTimeout` alto y conexión
   de solo lectura.
2. Usar ese DACPAC como Source y el proyecto SSDT vacío como Target.
3. Ejecutar Compare contra el archivo, no contra la BD en vivo.
4. Revisar los objetos antes de Update.
5. No versionar el directorio de salida del DACPAC ni el archivo `.dacpac`.
6. No habilitar la base en n8n o databases.json hasta validar import y
   compare.


## Compilar y validar SchemaSyncTool

Desde Windows:

    Set-Location D:\Proyectos\automation\schema-sync\SchemaSyncTool
    dotnet build -c Release
    dotnet test -c Release

Publicación Linux self-contained:

    dotnet publish -c Release -r linux-x64 --self-contained true -o ..\publish\linux-x64-sc

Antes de desplegar:

1. Revisar el diff.
2. Ejecutar build y pruebas.
3. Ejecutar self-tests seguros.
4. No ejecutar ninguna sincronización como parte del build.
5. Copiar el conjunto de artefactos aprobado al directorio publish del host.
6. Validar permisos y versión.
7. Ejecutar primero una BD piloto de forma manual y controlada.

Self-tests disponibles:

    SchemaSyncTool --self-test-sqlcmd
    SchemaSyncTool --self-test-model
    SchemaSyncTool --list-databases


## Resultado JSON

Archivo por base:

    /home/soporte/schema-sync/results/<database>.json

Campos principales:

- status.
- database.
- repo.
- synced.
- hadDrift.
- commitSha.
- prUrl.
- buildOk.
- message.
- timestamp.

Interpretación:

- status=success y buildOk=true: corrida correcta.
- status=success y hadDrift=false: no hubo cambios.
- status=error y commitSha/prUrl presentes: Git/PR se crearon, pero falló la validación posterior.
- buildOk=false: revisar el modelo DacFx o build DACPAC antes de completar el PR.

Código de salida del runner:

- 0: ejecución técnica completada; leer siempre status del JSON.
- Distinto de 0: fallo de ejecución como conexión, timeout, Git o error no controlado.


## Controles posteriores a DacFx

Después de cada sync, SchemaSyncTool debe:

1. Reaplicar PK, DEFAULT y FK si PublishChangesToProject los omitió.
2. Reubicar objetos desde carpetas residuales entity_/schema_ hacia su carpeta correcta.
3. Eliminar scripts huérfanos que ya no existen en la BD.
4. Refrescar módulos desde OBJECT_DEFINITION cuando corresponda.
5. Auditar tablas y PK del DACPAC contra el proyecto.
6. Comprobar que no queden carpetas terminadas en _.
7. Repetir la comparación ignorando users, permisos, roles, DatabaseOptions y ruido aceptado.
8. Fallar si permanece drift real de esquema.


## Troubleshooting

Extract falla con login:

- Confirmar el nombre real de la BD.
- Revisar SQL_USER y SQL_PASSWORD en el almacén seguro.
- Si se utiliza .env, proteger valores con caracteres especiales.
- No imprimir la contraseña durante el diagnóstico.

bash no existe en el worker:

- Utilizar sh /data/schema-sync/run-sync.sh.

/data/schema-sync no existe:

- Revisar el mount en docker-compose.yaml.
- Recrear solamente los servicios necesarios mediante el procedimiento autorizado.

Push rejected:

- Verificar scope Code Write del PAT.
- Revisar políticas de main y permisos de la identidad del tool.

PR no se crea:

- Confirmar que existe release.
- Revisar si ya existe un PR abierto main → release.
- No habilitar autocomplete.

Build o validación falla:

- En Linux revisar mensajes de DacFx y TSqlModel.Validate.
- En Windows revisar msbuild.log.
- Recordar que el push/PR puede haberse creado antes del build.

SQL71501:

- Determinar si la BD ya contiene una referencia inválida que SQL Server tolera pero SSDT no.
- No modificar la BD desde Schema Sync.
- Mantener buildOk=false y escalar la corrección al proceso DBA cuando corresponda.

Falso sin drift:

- Confirmar que el tool realiza git add -A después de actualizar el proyecto.

Notificación vacía:

- Confirmar que stdout incluye la línea JSON final.
- El parser debe utilizar la última línea válida con status.

VS muestra users, permisos o DatabaseOptions:

- Es ruido ignorado intencionalmente por el sync.

Comentario de objeto WITH ENCRYPTION:

- DacFx no puede leer el cuerpo.
- El placeholder debe normalizarse según el comportamiento actual del tool.

VS quiere eliminar objetos que todavía existen:

- Revisar carpetas residuales schema_/entity_.
- El tool debe reubicar los scripts y eliminar las carpetas sobrantes.

VS quiere agregar tabla o falta PK:

- Revisar el control anti-hueco DacFx.
- La auditoría debe fallar en lugar de reportar éxito silencioso.

Funciones o módulos truncados con headers /*@p_param */:

- Revisar SchemaSyncTool/ModuleScriptFromDb.cs.
- Confirmar que la lógica de comentarios de bloque no corte en el primer */ interno.
- El strip debe aplicarse solamente cuando el contenido restante inicia con CREATE o ALTER.
- Después del fix, publicar el tool y repetir una sola BD controlada.


## Checklist antes de ejecutar una BD

- [ ] Nombre real de la BD confirmado.
- [ ] Entrada enabled confirmada en databases.json.
- [ ] Repo y sqlproj confirmados.
- [ ] Workflow individual confirmado.
- [ ] No se utilizará el orquestador.
- [ ] No se utilizará batch.
- [ ] Conexión configurada con ApplicationIntent=ReadOnly.
- [ ] No hay secretos impresos o hardcodeados.
- [ ] Se entiende que puede existir push a main y PR.


## Checklist después de ejecutar

- [ ] Result JSON leído.
- [ ] status revisado.
- [ ] hadDrift revisado.
- [ ] commitSha revisado.
- [ ] prUrl revisado.
- [ ] buildOk revisado.
- [ ] Notificación de Teams revisada.
- [ ] PR no completado automáticamente.
- [ ] No se realizó ninguna escritura en SQL.


## Decisiones vigentes

- La BD es la fuente de verdad del esquema.
- La sincronización opera contra una sola BD por vez.
- El branch de sincronización es main.
- El PR es main → release.
- El PR no utiliza autocomplete.
- Las notificaciones se envían a Teams mediante Power Automate.
- El orquestador multi-BD permanece inactivo.
- La escritura SQL está prohibida.
