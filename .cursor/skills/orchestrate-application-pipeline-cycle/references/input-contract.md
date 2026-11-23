# Contrato de `INPUT`

Esquema del bloque `INPUT` de la plantilla ligera
(`docs/PLANTILLA-CICLO-CREACION-PIPELINE-APLICACION-LIGERA.md`). Este
documento reemplaza, para uso del coordinador, las secciones "Cómo
interpretar esta solicitud" y "Uso de los datos explícitos" de la
plantilla completa histórica — el contenido es el mismo, movido aquí para
no repetirse en cada plantilla nueva.

## Principio: manifiesto de sobrescrituras, no definición completa

`INPUT` es un **manifiesto de sobrescrituras** sobre los exports
canónicos de Azure DevOps, no una definición completa del pipeline.

> Cambiar únicamente los valores declarados explícitamente en `INPUT`, o
> aquellos que deban adaptarse como consecuencia demostrable del código,
> del repositorio o del ambiente. Todo lo demás se hereda y conserva de
> los exports canónicos indicados en `INPUT.azure_devops`.

Nunca reducir una definición existente únicamente a los campos presentes
en `INPUT`. Nunca eliminar tareas, variables, triggers, artifacts,
Variable Groups, Service Connections, Task Groups, aprobaciones,
retención, demands, pools o configuraciones que `INPUT` no mencione.

## Clasificación obligatoria de cada dato

| Clasificación | Tratamiento |
|---|---|
| Explícito | Valor indicado en `INPUT`; se aplica siempre. Tiene prioridad sobre exports canónicos. |
| Heredado | Se conserva exactamente del export canónico de Build/Release, salvo incompatibilidad demostrada. Debe indicar archivo y campo de origen. |
| Derivado | Se obtiene del código, manifiestos, clúster o configuración real. Debe presentar evidencia. |
| Protegido | No se elimina, cambia ni inventa sin necesidad confirmada y su aprobación correspondiente. |
| Pendiente | No puede inferirse con seguridad; debe aparecer explícitamente en el plan, nunca inventarse. |

Cuando un nombre derivado (código, convención, export) difiere del valor
declarado en `INPUT`, nunca sustituirlo en silencio. El plan debe incluir
una fila de trazabilidad:

| Concepto | Valor solicitado en `INPUT` | Valor propuesto | Evidencia | Acción |
|---|---|---|---|---|

El valor propuesto solo puede usarse si aparece en el plan **aprobado**.
Después de la aprobación, cualquier cambio adicional de FQDN, IP, imagen,
nombre de aplicación, repositorio, rama, clúster, namespace o node pool
queda fuera del plan y exige replanificación (ver `orchestration-flow.md`
§ Envolvente de corrección).

## Validación en una sola pasada

Al iniciar, validar en una sola pasada:

- Presencia de todos los campos obligatorios (ver esquema abajo).
- Coherencia interna (p. ej. `application.type` compatible con evidencia
  de código cuando no es `auto`).
- Que `discovery.cluster_validation_before_plan` sea uno de
  `preguntar|completa|minima|omitir` (si no, tratar como `preguntar` y
  hacer una única pregunta agrupada al inicio).

Si falta un dato imprescindible, agrupar **todos** los faltantes en una
sola pregunta — nunca preguntar campo por campo.
`Test-ApplicationCycleInput.ps1` implementa esta validación de forma
determinista y sin red (ver su propio comentario de cabecera para el
esquema exacto que exige).

## Esquema de `INPUT` (resumen)

```yaml
INPUT:
  application: { id, type }                       # type: auto|api|web|database
  repository: { organization, project, name, url, path, branches: { development, uat, production } }
  azure_devops:
    project, pipeline_folder, pipeline_folder_url, canonical_exports_directory
    build_export_candidates: [ ... ]               # orden de resolución
    release_export
    canonical_model_live_reference                 # alternativa a lo anterior, ver abajo
    secret_sources:
      container_registry_password: { environment_variable, target_name }
  application_variables: { image, appname_candidate }
  manifests: { development, uat, production }
  environments:
    <development|uat|production>:
      namespace, dns: { fqdn, type, ip, proxied, ttl }, cluster_candidate, node_selector
  discovery: { cluster_validation_before_plan }    # preguntar|completa|minima|omitir
  execution:
    max_automatic_configuration_retries_per_environment
    status_poll_interval_seconds
    build_wait_timeout_minutes
    release_wait_timeout_minutes
    rollout_wait_timeout_minutes
    aks_capacity_validation_max_age_seconds
    record_phase_timings
    run_development_after_plan_approval
    run_uat_after_development_success
    prepare_production
    production_requires_separate_approval
    allow_application_code_changes
    allow_deletions
```

## Modelo canónico sin export sanitizado todavía

El caso normal es `build_export_candidates` + `release_export` (export
local ya sanitizado). Cuando esa familia de app todavía no tiene un
export sanitizado, se acepta `canonical_model_live_reference` — la URL de
un Build real ya confirmado estructuralmente como el patrón correcto para
esta familia (ej. un Build hermano de la misma app-family, construido
recientemente). Es una advertencia, no un error: el ciclo puede
continuar resolviendo el modelo en vivo contra ese Build/su Release, pero
debe quedar registrado como pendiente crear el export estático
sanitizado para esa familia antes de que deje de depender de una
consulta en vivo cada vez.

**Estado actual por familia (`docs/azure-devops/`):**

- `backend` — `Build-modelo-backend.json`/`Release-modelo-backend.json`
  (Build 584, `buklo-microservice-gateway`, NestJS).
- `web` — `Build-modelo-web.json`/`Release-modelo-web.json` (agregado
  2026-09-08; Build 579/Release 361, app `shell` de `buklo-web`). Antes
  de este export, `app-directory`/`app-sso` se construyeron con
  `canonical_model_live_reference` en vivo (Build 633/634) porque este
  export todavía no existía — eso fue correcto en su momento y no
  necesita reconstruirse retroactivamente. Una app `web` nueva de aquí en
  adelante puede usar `build_export_candidates`/`release_export`
  directamente contra estos 2 archivos. Ver
  `docs/azure-devops/NOTAS-modelo-web.md` para 4 diferencias puntuales de
  la app `shell` (Ingress hardcodeado, dominio Grupo B, HPA sin rango
  útil, tasks de NSG deshabilitadas) que no deben copiarse ciegamente al
  adaptar el modelo a una app nueva.

## Clasificación obligatoria del tipo de aplicación

Si `application.type` es `auto`, clasificar el contenido de
`repository.path` como exactamente uno de:

| Tipo | Estado | Tratamiento |
|---|---|---|
| `api` | Soportado | Adaptar los modelos canónicos a una API, conservando toda la estructura compatible. |
| `web` | Soportado | Adaptar los mismos modelos a un sitio web/frontend; retirar solo elementos exclusivos de API con incompatibilidad demostrada. |
| `database` | No soportado todavía | Detenerse: no reutilizar modelos de aplicación; esperar exports específicos de base de datos. |
| `unknown` | No soportado | Presentar evidencia y pedir aclaración antes del plan. |

Evidencia combinada, nunca solo el nombre del repo/carpeta:
`package.json`/proyectos/frameworks/scripts, Dockerfile y comando de
arranque/puertos, presencia de frontend compilado vs. servidor
API/controladores, configuración de ingress/rutas, aplicaciones
comparables del mismo monorepo.

## Preflight obligatorio de ramas (previo al plan)

Validar en paralelo, sin modificar nada, las 3 ramas declaradas en
`repository.branches`:

- La rama existe; resolver su commit actual.
- Existe `repository.path` en ese commit.
- Existen Dockerfile, archivos de proyecto, lockfile y los archivos que
  las tareas del modelo consumen.
- Los scripts de build/start referenciados existen.
- Las rutas usadas por File Creator/reemplazo de tokens corresponden al
  contenido real de esa rama.

Registrar el commit validado por ambiente en el snapshot
(`New-ApplicationCycleSnapshot.ps1`). Inmediatamente antes de ejecutar el
Build de un ambiente, confirmar que la rama sigue apuntando al mismo
commit; si cambió, repetir solo esa validación. Código o ruta ausente en
`uat`/producción se clasifica como problema de rama/código — nunca crear
un PR ni modificar código automáticamente, nunca consumir una ejecución
que ya se sabe inviable.

## Preflight obligatorio de variables y secretos

Construir una sola matriz consolidada:

| Nombre lógico | Nombre real | Consumidor | Ambiente | Secreto | Fuente | Estado |
|---|---|---|---|---:|---|---|

- Confirmar que toda variable consumida esté definida o derivada con
  evidencia.
- Confirmar por nombre y referencia cada secreto obligatorio, sin leer ni
  mostrar su valor.
- La contraseña del Container Registry usa la fuente fijada en
  `manage-azure-devops-pipelines/references/container-registry-secret-source.md`
  (`ADO_SECRET_CONTAINERREGISTRYPASSWORD`) — comprobar solo presencia, no
  pedir el valor cuando la variable exista.
- Reutilizar Variable Groups/Key Vault/Service Connections aprobados
  antes de pedir un secreto nuevo.
- Agrupar todos los faltantes en una sola presentación antes del Apply.
  No iniciar Apply ni Build si falta una variable/referencia
  imprescindible conocida.
