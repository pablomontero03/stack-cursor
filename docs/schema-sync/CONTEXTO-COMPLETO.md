# Contexto completo — Schema Sync BD → Repo SSDT

Documento de contexto histórico y operativo del trabajo en `C:\code\BaseDatos` (proyecto Azure DevOps **Database-Administration-and-Monitoring**).  
Actualizado: **2026-08-14**.

Relacionado: operación día a día en [`README.md`](README.md). Este archivo es el **mapa de todo lo hecho**, no solo el how-to.

---

## 1. Objetivo

Automatizar que el **esquema real de Azure SQL Managed Instance** sea la fuente de verdad hacia los repos SSDT en Azure Repos:

1. Extraer esquema (solo lectura) con SqlPackage `/Action:Extract`
2. Comparar vs proyecto SSDT
3. Si hay drift → actualizar archivos → **push a `main`**
4. Abrir/reutilizar **PR `main` → `release` sin autocomplete**
5. Validar (build DACPAC / modelo DacFx)
6. Notificar a Teams vía Power Automate

**Regla de oro:** nunca escribir en SQL (ni Publish, Deploy, DDL, DML). Solo `ApplicationIntent=ReadOnly` + Extract.

---

## 2. Infraestructura

| Pieza | Detalle |
|-------|---------|
| SQL MI (prod) | `gmon-prod-sqlmi-eastus2-0001.15c9ad07b4c3.database.windows.net` |
| Usuario sync | `usr_repo_sync` (solo lectura) |
| Host n8n / tool | `172.16.2.60` (`soporte`) |
| Path host | `/home/soporte/schema-sync/` → contenedores `/data/schema-sync` |
| Binario | `/home/soporte/schema-sync/publish/SchemaSyncTool` |
| Results | `/home/soporte/schema-sync/results/<database>.json` |
| Work clones | `/home/soporte/schema-sync/work/<repoName>/` |
| Org/Proyecto ADO | `Shared-Service-GM` / `Database-Administration-and-Monitoring` |
| Notify Teams | webhook Power Automate **Notificaciones-DevOps** |
| Horario típico | Dom–Vie 19:00 America/Costa_Rica (por workflow) |
| Orquestador multi-BD | `ScHmSyNcOrCh0001` — **inactivo** (`do_not_auto_run=true`) |

Otro SQL on-prem / lab usado en VS (no es el MI de sync):

| Servidor | Uso |
|----------|-----|
| `172.16.2.34` | Schema Compare manual histórico (ej. buklo_lab con `usr_application_db`) |
| `172.16.2.26` | BD **SOFTLAND** / **SOFTLAND_BK** (ERP; no está en el MI) |

---

## 3. Línea de tiempo (desde el comienzo)

### Fase A — Setup de repos SSDT
- Clone masivo de repos del proyecto ADO en `C:\code\BaseDatos`.
- **US 18614 / Task 21619:** cascarones SSDT a partir de plantilla `project_sqldb_core_arthur` en repos que solo tenían README (~39): `.sqlproj`, `.slnx`, `build-dacpac.ps1`, scripts placeholder `None`.
- Importaciones manuales en Visual Studio de varias BD; quedaban repos solo-scaffold.

### Fase B — Diseño Schema Sync (piloto)
- Decisión: sync BD→repo, push `main`, PR a `release` sin autocomplete, notify Power Automate.
- Piloto: **OpsObservability**.
- Se añadió `build-dacpac.ps1` donde faltaba.
- Implementación: script PowerShell + tool .NET **SchemaSyncTool** (DacFx) para Linux/n8n (el worker Windows no estaba en la red de n8n).

### Fase C — Piloto E2E OpsObservability
- Workflow n8n `ScHmSyNcOpS0bs01` (**Schema Sync OpsObservability**).
- Validado: extract, drift, push, PR, build, notify.
- Endurecimiento: retries de Extract, timeouts, mensajes claros a Teams, lock de corridas.

### Fase D — Tooling global (un solo binario)
Fixes compartidos en SchemaSyncTool (no por repo):

- Refresh de módulos desde `OBJECT_DEFINITION` (`RefreshAllModulesFromDb`) para headers/cuerpos que DacFx no sincroniza bien
- Normalización `WITHOUT LOGIN` en users
- PKs / constraints faltantes tras PublishChangesToProject
- Stubs encrypted en español
- Drop de huérfanos / carpetas leftover `*_`
- Ignore users / permissions / roles / DatabaseOptions en assert
- PR `main`→`release`
- Validación Linux con `TSqlModel.Validate()` (errores tipo SQL71501)
- Push/PR aunque el build falle → `status=error`, `buildOk=false`, notify
- Self-tests: `--self-test-sqlcmd`, `--self-test-model`, `--list-databases`

### Fase E — Expansión multi-BD (una a una)
- Catálogo `databases.json` (~49 entradas).
- Workflows n8n individuales por BD (IDs `ScHmSyNc…`).
- Orquestador multi-BD montado pero **no** auto-ejecuta.
- Bundle especial `core-workflow-global` (dos proyectos SSDT + SQLCMD `[$(sqldb_core_global)]`).
- Corridas controladas BD por BD (sin batch salvo pedido).

### Fase F — Softland (2026-08-14)
- Repo nuevo `project_sqldb_SOFTLAND`: cascarón vacío, push `039e3aa`.
- Import/Compare VS vs BD live: **timeout ~10 min en PKs** (`SqlPrimaryKeyConstraint`).
- Motivo: BD enorme (~12 041 tablas, ~10 815 PKs).
- `SOFTLAND` **no** está en el MI de Azure; vive en **`172.16.2.26`**.
- Extract local SqlPackage (solo lectura, `CommandTimeout=7200`) →  
  `project_sqldb_SOFTLAND/out/SOFTLAND.dacpac` (~9.6 MB).
- Camino recomendado: Schema Compare **Source = dacpac**, Target = proyecto (evita re-ingeniería inversa).
- **No** se montó n8n ni se habilitó Softland en `databases.json` (aún).

### Fase G — Bug headers Buklo (2026-08-14)
- Re-sync `buklo_lab` falló post-assert: “Add” de 3 TVFs `utility.fn_con_cat_*`.
- Causa: `ModuleScriptFromDb` usaba comentarios de bloque **no-golosos**; headers Buklo con `/*@p_param */` truncaban el archivo y lo corrompían.
- Fix: regex goloso + strip solo si el resto empieza en `CREATE|ALTER`.
- Redeploy DLL + re-corrida → **success**, commit `dc11141`, PR [13404](https://dev.azure.com/Shared-Service-GM/Database-Administration-and-Monitoring/_git/project_sqldb_buklo_lab/pullrequest/13404), build OK.

---

## 4. Arquitectura del flujo

```
BD (SQL MI, ReadOnly)
    → SqlPackage Extract (.dacpac)
    → Schema Compare vs SSDT project
    → PublishChangesToProject (archivos Git, no BD)
    → Sanitize (users WITHOUT LOGIN, sqlproj, orphans, leftover *_/)
    → RefreshAllModulesFromDb (OBJECT_DEFINITION)
    → Assert tablas/PK + re-compare (sin users/perms)
    → git push main
    → PR main → release (sin autocomplete)
    → Validate build/model
    → JSON result + Teams (OK / ERROR)
```

Garantías de solo lectura:
- Connection string con `ApplicationIntent=ReadOnly`
- Tooling rechaza Publish/Deploy/TargetConnectionString
- Script DBA opcional: `sql/harden-usr_repo_sync-readonly.sql`

---

## 5. Componentes en disco

| Pieza | Ruta |
|-------|------|
| Tool .NET | `automation/schema-sync/SchemaSyncTool/` |
| README operativo | `automation/schema-sync/README.md` |
| Este contexto | `automation/schema-sync/CONTEXTO-COMPLETO.md` |
| Catálogo | `databases.json`, `set-params.databases.json` |
| Runner Linux | `run-sync.sh` |
| Runner Windows | `run-sync.ps1` |
| Batch (dry-run) | `run-batch.sh` |
| Bundle core | `bundles/core-workflow-global.json` |
| Workflows n8n | `n8n-workflow-schema-sync-*.json` (+ `.import.json`) |

Workspace local de repos: `C:\code\BaseDatos\project_*`.

---

## 6. Catálogo — BD habilitadas (`enabled: true`)

Al 2026-08-14 hay **20** enabled de ~49 en `databases.json`:

| database (MI) | projectName / repo |
|---------------|--------------------|
| OpsObservability | project_OpsObservability |
| sqldb_app_datalab | project_sqldb_app_datalab |
| buklo_lab | project_sqldb_buklo_lab (`sqldb_buklo_lab`) |
| sqldb_core | project_sqldb_core |
| sqldb_core_arthur | project_sqldb_core_arthur |
| sqldb_core_config | project_sqldb_core_config |
| sqldb_core_demographic | project_sqldb_core_demographic |
| sqldb_core_file | project_sqldb_core_file |
| sqldb_core_historical | project_sqldb_core_historical |
| sqldb_core_job_schedule | project_sqldb_core_job_schedule |
| sqldb_core_log | project_sqldb_core_log |
| sqldb_core_module | project_sqldb_core_module |
| sqldb_core_schedule | project_sqldb_core_schedule |
| sqldb_core_trace | project_sqldb_core_trace |
| sqldb_da_core_cfg | project_sqldb_da_core_cfg |
| sqldb_da_core_log | project_sqldb_da_core_log |
| sqldb_da_core_sec | project_sqldb_da_core_sec |
| sqldb_da_core_tmp | project_sqldb_da_core_tmp |
| sqldb_sds_blue | project_sqldb_sds_blue |
| sqldb_stg_blue | project_sqldb_stg_blue |

**Nota de nombres:** a veces el nombre real en MI ≠ nombre del sqlproj/repo (ej. `buklo_lab` vs `sqldb_buklo_lab`). El workflow debe usar el **nombre real de la BD** en `DATABASE=`.

**Bundle habilitado 2026-09-30:** `core-workflow-global` (`sqldb_core_global` + `sqldb_core_workflow`) en repo `project-qldb_core_workflow-sqldb_core_global`. Primer sync exitoso: ejecución `2537744`, `main` en `070ec23`. Ver §16 para el hallazgo de errores y correcciones al tool.

Pendientes típicos del catálogo (aún no enabled / sin workflow dedicado en esta tanda):  
`sqldb_da_global`, `gm_*`, más `stg_*`, `sds_*`, ecommerce, int_*, etc.

---

## 7. Workflows n8n

| Workflow ID | Nombre |
|-------------|--------|
| `ScHmSyNcOpS0bs01` | Schema Sync OpsObservability |
| `ScHmSyNcDtaLab01` | Schema Sync sqldb_app_datalab |
| `ScHmSyNcBklLab01` | Schema Sync sqldb_buklo_lab |
| `ScHmSyNcSqlCor01` | Schema Sync sqldb_core |
| `ScHmSyNcCorArt01` | Schema Sync sqldb_core_arthur |
| `ScHmSyNcCorCfg01` | Schema Sync sqldb_core_config |
| `ScHmSyNcCorDem01` | Schema Sync sqldb_core_demographic |
| `ScHmSyNcCorFil01` | Schema Sync sqldb_core_file |
| `ScHmSyNcCorHis01` | Schema Sync sqldb_core_historical |
| `ScHmSyNcCorJob01` | Schema Sync sqldb_core_job_schedule |
| `ScHmSyNcCorLog01` | Schema Sync sqldb_core_log |
| `ScHmSyNcCorMod01` | Schema Sync sqldb_core_module |
| `ScHmSyNcCorSch01` | Schema Sync sqldb_core_schedule |
| `ScHmSyNcCorTrc01` | Schema Sync sqldb_core_trace |
| `ScHmSyNcDaCfg001` | Schema Sync sqldb_da_core_cfg |
| `ScHmSyNcDaLog001` | Schema Sync sqldb_da_core_log |
| `ScHmSyNcDaSec001` | Schema Sync sqldb_da_core_sec |
| `ScHmSyNcDaTmp001` | Schema Sync sqldb_da_core_tmp |
| `ScHmSyNcSdsBlu01` | Schema Sync sqldb_sds_blue |
| `ScHmSyNcStgBlu01` | Schema Sync sqldb_stg_blue |
| `ScHmSyNcOrCh0001` | Schema Sync Multi-BD (orquestador) — **inactivo** |

UI: http://172.16.2.60:5678/

Ejecutar uno:

```bash
docker exec n8n-n8n_main-1 n8n execute --id=ScHmSyNcBklLab01
```

Resultado: `/home/soporte/schema-sync/results/<database>.json`  
(usar el nombre de `DATABASE`, ej. `buklo_lab.json`, no siempre el del sqlproj).

---

## 8. Softland — estado detallado

| Ítem | Estado |
|------|--------|
| Repo | `project_sqldb_SOFTLAND` |
| Local | `C:\code\BaseDatos\project_sqldb_SOFTLAND` |
| Cascarón | Sí (commit `039e3aa` en `main`) |
| BD real | `SOFTLAND` en `172.16.2.26` (también existe `SOFTLAND_BK`) |
| En MI Azure | **No** |
| n8n / databases.json | **No** habilitado |
| Import VS | Falló: timeout PKs ~10 min |
| Schema Compare live | Mismo problema |
| Dacpac extract | OK → `out/SOFTLAND.dacpac` (gitignore `/out/`) |
| Cómo importar | Compare Source=dacpac → Target=`sqldb_SOFTLAND` → Update |

Tamaño aproximado: ~12k tablas / ~11k PKs → VS UI no aguanta el reverse-engineer con timeout default; SqlPackage con timeout alto sí.

---

## 9. Incidentes y lecciones

### 9.1 Headers `/*@p_param */` (buklo_lab, 2026-08-14)
- **Síntoma:** post-sync assert “Add TableValuedFunction utility.fn_con_cat_*”.
- **Causa:** strip/extract de header no-goloso cortaba en el primer `*/` interno del template Buklo.
- **Fix:** `ModuleScriptFromDb.cs` — comentarios golosos + strip solo si sigue `CREATE|ALTER`.
- **Acción operativa:** republish `SchemaSyncTool.dll` al host `172.16.2.60` tras cambiar el tool.

### 9.2 Timeout PKs en VS (SOFTLAND)
- No es fallo del cascarón; es tamaño de esquema.
- Workaround: dacpac + Compare contra archivo.

### 9.3 Nombre de BD ≠ nombre de repo
- Extract con nombre incorrecto → “Cannot open database / Login failed”.
- Usar `--list-databases` / Azure `az sql midb list` / confirmar en VS.

### 9.4 SQL71501 en SSDT vs SQL Server
- SQL Server puede crear un SP que referencia columnas inexistentes; SSDT no.
- Ejemplo visto: `core_trace` / `notification.pa_con_email_message` (`sender_email`).
- El sync copia fielmente la BD; el arreglo real es en BD (o aceptar `buildOk=false` con push/PR).

### 9.5 Ruido que el sync ignora a propósito
- Users, permissions, role memberships, DatabaseOptions, comentarios whitespace.
- Spurious “Eliminar” por leftover `schema_/` → el tool limpia.

---

## 10. Decisiones de producto (acordadas)

| Tema | Decisión |
|------|---------|
| Rama de sync | Solo `main` |
| PR | `main` → `release`, sin autocomplete |
| Notify | Power Automate → canal Teams |
| Multi-BD batch | No, salvo pedido explícito |
| Orquestador | Montado, inactivo |
| Escritura SQL | Prohibida |
| Softland en n8n | Aún no (hasta import/compare estable) |

---

## 11. Cuándo y cómo crear un cascarón SSDT nuevo

### Cuándo hace falta

Crear un **cascarón** (scaffold vacío) cuando:

1. Existe (o se va a crear) un repo ADO tipo `project_<nombre>` y **solo tiene README** (o está vacío).
2. Aún **no** hay `.sqlproj` / `.slnx` / `build-dacpac.ps1`.
3. Quieres poder abrir el proyecto en VS e **importar** el esquema (Import Database / Schema Compare) **antes** de cablear n8n.
4. Ejemplo reciente: `project_sqldb_SOFTLAND` (cascarón → luego dacpac/compare; **sin** n8n hasta que el import funcione).

**No** hace falta cascarón si el repo ya tiene proyecto SSDT con objetos (aunque estén desactualizados): ahí va directo el Schema Sync.

**Orden recomendado BD nueva:**

```
1) Repo ADO existe
2) Cascarón SSDT + push main
3) Importar esquema (VS o dacpac+Compare)  ← Softland grande: preferir dacpac
4) Confirmar nombre real de la BD
5) Habilitar catálogo + workflow n8n + corrida piloto
```

No montar n8n / `enabled: true` hasta que el proyecto compile y el esquema esté (o esté claro el camino de import).

### Plantilla

Usar como referencia:

- Histórica masiva: `project_sqldb_core_arthur` (Task **21619** / US **18614**)
- Ejemplo limpio reciente: `project_sqldb_SOFTLAND`

### Estructura mínima a crear

```
project_<Nombre>/
  .gitignore
  README.md                    (si ya existe, no pisar sin necesidad)
  build-dacpac.ps1             ($projectName = "<NombreProyecto>")
  <NombreProyecto>.slnx
  databases/<NombreProyecto>/
    <NombreProyecto>.sqlproj
    Properties/                (carpeta vacía ok)
    scripts/data/application/TKS-XXX/   (placeholder None)
    scripts/data/rollback/TKS-XXX/      (placeholder None)
```

Convención de nombres:

| Pieza | Ejemplo Softland |
|-------|------------------|
| Repo ADO | `project_sqldb_SOFTLAND` |
| Proyecto SSDT / carpeta | `sqldb_SOFTLAND` |
| `.slnx` | `sqldb_SOFTLAND.slnx` |
| BD real en servidor | puede diferir (`SOFTLAND` en `172.16.2.26`) |

### Checklist del `.sqlproj`

- `DSP`: `Microsoft.Data.Tools.Schema.Sql.Sql170DatabaseSchemaProvider` (salvo que el estándar del repo diga otro)
- `ProjectGuid`: **GUID nuevo** (no copiar el de arthur/Softland)
- `Name` / `RootNamespace` / `AssemblyName` = nombre del proyecto
- `DefaultFileStructure`: `BySchemaAndSchemaType`
- Scripts bajo `scripts\data\...` como `<None Include="...">` (no van al DACPAC)
- Sin objetos de esquema todavía (cascarón vacío)

### `.gitignore` mínimo

```
/.vs
**/bin/
**/obj/
**/*.user
**/*.dbmdl
**/*.jfm
msbuild.log
```

Si vas a generar dacpac local de extract (caso Softland), añadir también:

```
/out/
**/*.dacpac
```

### `build-dacpac.ps1`

Copiar de otro repo (arthur / Softland / core_file) y cambiar solo:

```powershell
$projectName = "<NombreProyecto>"
```

### Pasos operativos

1. Crear o clonar el repo en `C:\code\BaseDatos\project_<Nombre>`.
2. Generar estructura + `.sqlproj` (GUID nuevo) + `.slnx` + `build-dacpac.ps1` + `.gitignore`.
3. Compilar local: `.\build-dacpac.ps1` → debe pasar con 0 errores (proyecto vacío).
4. Commit + push a `main` (mensaje tipo: `chore: add empty SSDT shell for <NombreProyecto>`).
5. Abrir `.slnx` en VS e importar / Schema Compare (o extract SqlPackage si la BD es muy grande).
6. **Después** del import estable: catálogo `databases.json`, workflow n8n, corrida sync.

### Import cuando la BD es enorme (lección Softland)

- Import / Compare **live** puede morir en PKs (~10 min timeout).
- Extraer `.dacpac` con SqlPackage (`CommandTimeout` alto, solo lectura).
- Schema Compare: **Source = dacpac**, Target = proyecto vacío → Update.

### Qué no hacer en el cascarón

- No habilitar n8n ni `databases.json` todavía.
- No escribir en la BD.
- No reutilizar `ProjectGuid` de otro repo.
- No meter `bin/` / `obj/` / `.dacpac` de extract al Git.

---

## 12. Cómo operar (resumen)

**Una BD ya wired (ej. buklo):**

```bash
# En 172.16.2.60
docker exec n8n-n8n_main-1 n8n execute --id=ScHmSyNcBklLab01
cat /home/soporte/schema-sync/results/buklo_lab.json
```

**Publicar cambios del tool:**

```powershell
cd C:\code\BaseDatos\automation\schema-sync\SchemaSyncTool
dotnet publish -c Release -r linux-x64 --self-contained true -o ..\publish\linux-x64-sc
# pscp SchemaSyncTool.dll → soporte@172.16.2.60:/home/soporte/schema-sync/publish/
```

**Habilitar una BD nueva (después del cascarón + import):**
1. Confirmar nombre real de la BD (MI u otro servidor)
2. Repo SSDT ya con cascarón (o proyecto) + `build-dacpac.ps1` — ver §11
3. `enabled: true` en `databases.json` / Set-Params
4. Crear/importar workflow n8n (copiar plantilla)
5. Ejecutar una vez manual y revisar result JSON + Teams
6. Activar schedule Dom–Vie 19:00 si aplica

---

## 13. Pendientes / siguiente

- [ ] **URGENTE (2026-09-30):** Orquestador reducido a solo `core-workflow-global`. Restaurar las demás BDs en el nodo `Set - Params` del orquestador n8n.
- [ ] **URGENTE (2026-09-30):** PR [#13986](https://dev.azure.com/Shared-Service-GM/Database-Administration-and-Monitoring/_git/project-qldb_core_workflow-sqldb_core_global/pullrequest/13986) en `project-qldb_core_workflow-sqldb_core_global` pendiente de revisión y merge a `release`.
- [ ] Commitear y publicar el `SchemaSyncTool` con los fixes de CLR/SQLCMD/bundle al repo fuente (hoy solo se desplegó el binario al `.60`).
- [ ] `buklo_lab` — equipo PACE debe hacer `ALTER FUNCTION [pace].[fn_facility_occupancy_stats]` con nombres de columna correctos (ver §15).
- [ ] Softland: Compare dacpac→proyecto, decidir si entra a sync automatizado.
- [ ] Actualizar README operativo (catálogo enabled real; fila troubleshooting headers).
- [ ] Resto del catálogo disabled (da_global, gm_*, más stg/sds/int/ecommerce, …) — solo bajo pedido.

---

## 14. Referencias rápidas

- Chat / trabajo reciente: sync multi-BD, Softland, bug headers Buklo (2026-08).
- ADO Task scaffolding: **21619** (US 18614).
- PR ejemplo Buklo post-fix: [13404](https://dev.azure.com/Shared-Service-GM/Database-Administration-and-Monitoring/_git/project_sqldb_buklo_lab/pullrequest/13404).
- Código crítico headers: `SchemaSyncTool/ModuleScriptFromDb.cs`.
- Softland dacpac (local, no git): `project_sqldb_SOFTLAND/out/SOFTLAND.dacpac`.
- Cascarón nuevo: **§11** de este documento; plantillas `project_sqldb_core_arthur` / `project_sqldb_SOFTLAND`.

---

---

## 15. Hallazgo 2026-09-29 — buklo_lab dejó de compilar después del Schema Sync

**Repositorio:** `project_sqldb_buklo_lab` · **Base:** `buklo_lab` en `gmon-prod-sqlmi-eastus2-0001`  
**Flujo:** orquestador `ScHmSyNcOrCh0001` · **Build ADO:** 647 `Build_Base_Datos_sqldb_buklo_lab` · **Release ADO:** def 403

### Causa raíz

El PR **13925 (TKS-39832, 28-sep)** hizo una "limpieza del esquema pace en release previo a reestructuración" y sacó del `.sqlproj` los `<Build Include>` de dos objetos:

- `pace/Functions/fn_facility_occupancy_stats.sql`
- `pace/Tables/cat_pace_forecast.sql`

Los archivos `.sql` quedaron en el repo pero fuera del build. Como el Release usa `DropObjectsNotInSource=False`, el publish del PR **13944 (BUG-19474, 29-sep 11:56)** no eliminó esos objetos de `buklo_lab` — los dejó intactos en la instancia.

El sync del 29-sep detectó que esos dos objetos existen en la BD pero no están en el `.sqlproj` y los volvió a registrar como `<Build Include>` en el commit `32b461ad`. A partir de ese commit SSDT sí compila la función y falla con `SQL71501` porque el cuerpo usa nombres de columna del esquema anterior a **TKS-21827 (28-jul-2026)**:

| La función usa | La tabla tiene |
|---|---|
| `pace.cat_provider.blue_id` | `id_blue` |
| `pace.cat_provider.cat_provider_id` | `id` |
| `pace.cat_provider.cat_company_id` | `id_cat_company` |
| `pace.cat_scope_by_capacity_type.cat_facility_id` | `id_cat_facility` |
| `pace.cat_scope_by_capacity_type.cat_provider_id` | `id_cat_provider` |

El error no es introducido por el sync — existía desde julio 2026 y estaba oculto porque el `Build Include` estaba ausente.

### Cronología de commits relevantes

| Commit | Fecha | Autor | Include de los dos objetos |
|---|---|---|---|
| `dc899e2f` | 28-sep | — | Sí estaban |
| `3a608ba4` | 28-sep 16:17 | TKS-39832 | **Se quitaron** |
| `bf8af4f4` | 28-sep | PR 13925 merge | Siguen fuera |
| `311ac2dd` | 28-sep 18:13 | TKS-39918 | Siguen fuera |
| `d2b24da6` | 29-sep 11:56 | BUG-19474 | Siguen fuera — **compila OK** |
| `32b461ad` | 29-sep 16:42 | schema-sync-bot | **Se volvieron a agregar — rompe compilación** |
| `941fc98a` | 29-sep 16:48 | schema-sync-bot | Sin cambio en .sqlproj — solo reformatea tra_price_list* |

### Por qué el Release no eliminó los objetos de la BD

El TG `Deployment-DataBases` publica con `/p:DropObjectsNotInSource=False` (explícito en el release, no solo el default de la herramienta). Un objeto que sale del DACPAC por falta de `Build Include` no genera `DROP` en el publish — simplemente el dacpac no dice nada sobre él.

### Estado al cerrar el hallazgo (30-sep 02:00 CR)

- `main` y `release` tienen los dos objetos con `Build Include`. El proyecto no compila.
- La función `fn_facility_occupancy_stats` tiene el cuerpo desactualizado en la BD también (SQL Server no la valida en runtime sin `SCHEMABINDING`).
- La BD `buklo_lab` sigue teniendo ambos objetos.
- El sync, en la próxima corrida, seguirá viéndolos en la instancia.

### Opciones de resolución (pendiente equipo PACE)

**Ruta A — corregir la función (recomendada):** `ALTER FUNCTION [pace].[fn_facility_occupancy_stats]` con los nombres de columna actuales → sync captura la versión corregida → proyecto compila limpio.

**Ruta B — eliminar los objetos si ya no tienen uso:** `DROP FUNCTION [pace].[fn_facility_occupancy_stats]` + `DROP TABLE [pace].[cat_pace_forecast]` → sync los quita del repo en la próxima corrida → `.sqlproj` vuelve a compilar.

### Lección de proceso

Cuando se saca un `<Build Include>` de un `.sqlproj` sin eliminar el objeto de la BD, el sync lo va a volver a incluir en la próxima corrida — es el comportamiento correcto. Antes de hacer una "limpieza" de objetos en el `.sqlproj`, decidir explícitamente si el objeto también se elimina de la instancia. Si no se elimina, el sync lo reintegra.

---

*Este documento es el contexto acumulado del trabajo de schema-sync y repos SSDT. Para comandos cortos del día a día, ver `README.md`.*

## 16. Hallazgo 2026-09-30 — sqldb_core_global y sqldb_core_workflow dejaron de compilar después del Schema Sync

**Repositorio:** `project-qldb_core_workflow-sqldb_core_global` · **Bases:** `sqldb_core_global` + `sqldb_core_workflow` en `gmon-prod-sqlmi-eastus2-0001`  
**Flujo:** orquestador `ScHmSyNcOrCh0001` · **Bundle:** `core-workflow-global`  
**Archivo completo:** `docs/schema-sync/HALLAZGO-CORE-WORKFLOW-GLOBAL-SQLPROJ-2026-09-30.md`

### Causa raíz

El primer sync del bundle (habilitado 2026-09-30) generó dos commits en `main` que rompieron la compilación de ambas bases:

| Commit | Base | Error principal |
|---|---|---|
| `370143fc` | `sqldb_core_global` | `SQL71508` ensamblado `RegExValidator` duplicado (DLL + script `CREATE ASSEMBLY` incluido al build) |
| `753d007` | `sqldb_core_workflow` | `SQL71508` esquemas `external`/`aseguradora` duplicados + **346 `SQL71561`** por `[$(sqldb_core_global)]` → `[sqldb_core_global]` literal |

El commit `753d007` también commiteó con título `OpsObservability` por defecto porque `DATABASE` no estaba seteada en modo bundle al salir con error.

### Los tres problemas y sus correcciones en el SchemaSyncTool

**1. Ensamblados CLR en `sqldb_core_global`**  
El project tiene `<Reference>` a tres DLL (`Proy_RegExValidator`, `CLRSQLRegexLibrary`, `sql.common`) con `GenerateSqlClrDdl=False`. El sync incluía al build los scripts `CREATE ASSEMBLY` sueltos que extrajo del DACPAC, duplicando lo que el compilador ya emite desde el DLL.  
→ Fix: `skipClrAssemblies` en el JSON del bundle. Si el `.sqlproj` tiene `GenerateSqlClrDdl=False` para ese ensamblado, el script `CREATE ASSEMBLY` se excluye del build y del compare.

**2. Esquemas duplicados en `sqldb_core_workflow`**  
`Security\external.sql` y `Security\aseguradora.sql` crean los mismos esquemas que `Security\external_1.sql` y `Security\aseguradora_1.sql`. Estaban en `<None Include>`; el sync los pasó a `<Build Include>`.  
→ Fix: `keepAsNone` en el JSON del bundle. Esos dos archivos se mantienen en `<None Include>` y fuera del compare.

**3. Variable SQLCMD `[$(sqldb_core_global)]` reemplazada por nombre literal**  
El `preserveSqlCmdRefs` del JSON del bundle existía como configuración pero no estaba implementado en el tool. El DACPAC guarda el nombre literal de la BD; al escribir los `.sql` el sync lo dejaba literal en lugar de restaurar la variable.  
→ Fix implementado: `SqlCmdPreserve` restaura `[sqldb_core_global]` y `sqldb_core_global.` → `[$(sqldb_core_global)]` después del refresco, antes de cualquier comparación. Afecta 7 archivos (57 referencias en total, solo en `sqldb_core_workflow`).

**4. Bug secundario: borrado incorrecto de `tra_workflow.sql` por sus triggers inline**  
Los triggers `tr_ai_tra_workflow` y `tr_au_tra_workflow` viven dentro de `workflow\Tables\tra_workflow.sql` (después de un `GO`). El sync detectaba `CREATE TRIGGER` en ese archivo y lo borraba al encontrar archivos sueltos de trigger. Los archivos sueltos no estaban en git.  
→ Fix: si otro archivo contiene un `CREATE TABLE` para la misma tabla, se borra el trigger suelto y se conserva el script de la tabla.

**5. `accept-dacfx-incongruence.py` aceptaba cualquier incongruencia y commiteaba como `OpsObservability`**  
El script aceptaba cualquier mensaje que contuviera "incongruencia" aunque la base fuera distinta a `pace`. El commit title usaba el default `OpsObservability` cuando `DATABASE` no estaba seteada.  
→ Fix: solo acepta incongruencias del esquema `pace` (caso conocido de FK circular). El título del commit usa el database del resultado; en bundle usa el nombre del bundle.

### Corridas de prueba y estado final

| Ejecución | Resultado |
|---|---|
| `2536884`–`2537319` | Iteraciones de debug — varios fallos intermedios |
| `2537421` (13:55–13:57) | Commit `22a7603` — volvieron los objetos de factura, variable restaurada. PR 13986. Aún fallaba `SQL71501` de esquema `external`. |
| `2537584` (14:09–14:12) | Commit `070ec23` — esquema `external` resuelto. |
| `2537744` (14:23–14:25) | **`buildOk=true`, sin drift**. `main` queda en `070ec23`. ✅ |

### Qué se dejó pendiente

- 3 tablas de respaldo de `replicator` siguen en `<Build Include>` (no causaron errores).
- Los usuarios y `RoleMemberships` pasados de `None` a `Build` no se revirtieron (sin errores).
- El orquestador sigue con solo el bundle `core-workflow-global` activo al cerrar. Restaurar las demás BDs.
- El tool de la herramienta no se commiteó al repo de desarrollo.
- `prUrl: null` bug en resultados de bundle → workaround: `open-pr-if-missing.py` en el `.60`.

### Lección de proceso

Un bundle de SSDT con referencias CLR (DLL + `GenerateSqlClrDdl=False`) y variables SQLCMD cross-DB requiere configuración explícita en el JSON del bundle (`skipClrAssemblies`, `keepAsNone`, `preserveSqlCmdRefs`) para que el sync no rompa la compilación. Validar siempre con dry-run antes de habilitar un bundle nuevo.

---


---

## Nota de estado 2026-11-09 — dos orquestadores activos

Esta nota se agrega sin modificar lo anterior. Donde el texto histórico dice que el orquestador está "inactivo" o con `do_not_auto_run=true`, prevalece lo siguiente (verificado en vivo en `n8n-interno`):

- `ScHmSyNcOrCh0001` (núcleo): activo, `do_not_auto_run=false`, Dom–Vie 19:00 CR, 21 de 22 bases enabled (falta `sqldb_da_global`).
- `F9RXPgIJQ7QzZ15q` (negocio + staging, "orquestador 2"): creado el 2026-11-04 como clon del 0001, activado el 2026-11-09, `do_not_auto_run=false`, Dom–Vie 20:30 CR, 18 de 28 bases enabled.
- Ambos deben mantenerse en espejo: todo cambio de grafo o lógica va a los dos, con respaldo previo en `.local/schema-sync/backups/`.
- Pilotos del 2026-11-04 (flujo 2): 27 repos verificados con `.sqlproj`; 18 pasaron con `status=success` y `buildOk=true`.
- Fallos pendientes (enabled=false): build SSDT en `int_medica`, `int_nomedica`, `stg_iolab`; drift BD↔repo en `database_maintenance`, `gm_cotizadores`, `pre_stage`, `sds_salesforce`.
- Bases heavy inactivas: `stg_hana`, `stg_hana_nomed`, `SOFTLAND`. El Compare live tarda más de 40 min por base y el wrapper CLI de n8n crasheó (~65 min) abortando la cola; requieren vía DACPAC con CommandTimeout alto.
- Repos sin proyecto SSDT, fuera del catálogo: `dw_eflow`, `eflow_sislocar`, `rj_coyol`.
- `schema-sync/databases.json` no existe en el checkout; hoy la fuente efectiva del catálogo es el nodo `Set - Params` de cada workflow.
- Procedimiento vigente: `schema-sync/README.md`, sección "Orquestador multi-BD".
