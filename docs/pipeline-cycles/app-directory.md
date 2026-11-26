# Ciclo de pipeline — app-directory (buklo-web)

## Uso

Este archivo es la instancia real (no una plantilla) del ciclo de creación
de pipeline para `app-directory` dentro de `buklo-web`. Contiene los datos
y decisiones de **esta aplicación puntual** — se archivó acá el
`2026-09-07` al convertir `docs/PLANTILLA-CICLO-CREACION-PIPELINE-APLICACION-LIGERA.md`
en una plantilla en blanco reutilizable.

Los procedimientos técnicos pertenecen a la skill
`orchestrate-application-pipeline-cycle` y a las skills de Azure DevOps,
Cloudflare y AKS — no se repiten en detalle acá.

Detalle procedimental completo:
`.claude/skills/orchestrate-application-pipeline-cycle/references/input-contract.md`
(esquema y clasificación explícito/heredado/derivado/protegido/pendiente),
`.../orchestration-flow.md` (ruta rápida, secuencia por etapas, envolvente
de corrección, tratamiento de errores), `.../approval-envelope.md`
(aprobaciones y por qué un solo `ExitPlanMode` alcanza para varios
dominios) y `.../status-timing-and-memory.md` (monitoreo, clasificación
del resultado, tiempos, routing de memorias).

## Datos del ciclo

```yaml
INPUT:
  application:
    id: app-directory
    type: auto                 # auto | api | web | database

  repository:
    organization: Shared-Service-GM
    project: Buklo
    name: buklo-web
    url: 'https://dev.azure.com/Shared-Service-GM/Buklo/_git/buklo-web?version=GBdevelopment&path=/apps/app-directory'
    path: /apps/app-directory
    branches:
      development: development
      uat: uat
      production: release

  azure_devops:
    project: DevOps
    pipeline_folder: '\buklo'
    pipeline_folder_url: 'https://dev.azure.com/Shared-Service-GM/DevOps/_build?definitionScope=%5Cbuklo'
    canonical_exports_directory: 'D:\Proyectos\automation\docs\azure-devops'
    # CORREGIDO (2026-09-07): esta app se construyo en la realidad usando
    # el patron real de buklo-web (Build 633/634), NUNCA
    # Build-modelo-backend.json/Release-modelo-backend.json (familia
    # backend/NestJS, sin relacion) -- este INPUT documentado tenia la
    # referencia equivocada desde el inicio; se corrige aqui para que
    # refleje lo que realmente se uso, sin necesidad de reconstruir nada.
    # ACTUALIZACION (2026-09-08): ya existe un export sanitizado propio de
    # la familia web (Build-modelo-web.json/Release-modelo-web.json, ver
    # input-contract.md y NOTAS-modelo-web.md) -- esta app ya construida
    # no se reconstruye, pero una app web nueva puede usar
    # build_export_candidates/release_export directo en vez de
    # canonical_model_live_reference.
    build_export_candidates: []
    release_export: null
    canonical_model_live_reference: 'https://dev.azure.com/Shared-Service-GM/DevOps/_build?definitionId=634'
    secret_sources:
      container_registry_password:
        environment_variable: ADO_SECRET_CONTAINERREGISTRYPASSWORD
        target_name: resolve_from_canonical_model

  application_variables:
    image: app-directory-web
    appname_candidate: app-directory

  manifests:
    development: ./deployment-dev.yml
    uat: ./deployment-uat.yml
    production: ./deployment-prod.yml

  environments:
    development:
      namespace: desarrollo
      dns:
        fqdn: app-directory-web-dev.gmontecristo.com
        type: A
        ip: 177.93.30.165
        proxied: false
        ttl: auto
      cluster_candidate: discover
      node_selector: inherit

    uat:
      namespace: uat
      dns:
        fqdn: app-directory-web-uat.gmontecristo.com
        type: A
        ip: 177.93.30.165
        proxied: false
        ttl: auto
      cluster_candidate: discover
      node_selector: inherit

    production:
      namespace: apps-web
      dns:
        fqdn: app-directory-web.grupomontecristo.com
        type: A
        ip: 20.161.149.127
        proxied: false
        ttl: auto
      cluster_candidate: gmon-prod-aks-eastus2-0004
      node_selector:
        agentpool: userpool03

  discovery:
    cluster_validation_before_plan: minima     # preguntar | completa | minima | omitir

  execution:
    max_automatic_configuration_retries_per_environment: 2
    status_poll_interval_seconds: 120
    build_wait_timeout_minutes: 60
    release_wait_timeout_minutes: 60
    rollout_wait_timeout_minutes: 20
    aks_capacity_validation_max_age_seconds: 300
    record_phase_timings: true
    run_development_after_plan_approval: true
    run_uat_after_development_success: true
    prepare_production: true
    production_requires_separate_approval: true
    allow_application_code_changes: false
    allow_deletions: false
```

## Interpretación de entradas

- `INPUT` es la fuente de verdad de esta ejecución.
- Validar todos los faltantes en una sola pasada y agrupar cualquier pregunta.
- Un valor explícito tiene prioridad sobre modelos históricos.
- Si un valor derivado difiere de `INPUT`, mostrar `valor solicitado → valor propuesto → evidencia` en el plan.
- No utilizar el valor derivado hasta que aparezca en el plan aprobado.
- Si `application.type` es `auto`, clasificar mediante evidencia del código.
- `database` requiere sus modelos específicos; no adaptar modelos de API/web.

## Plan consolidado

Antes de cualquier escritura presentar un único plan que incluya:

- Clasificación y evidencia de la aplicación.
- Exports canónicos y hashes.
- Build, Release, Task Groups y ubicación propuestos.
- Repositorio, ruta, ramas y commits validados.
- Matriz resumida de elementos conservados, adaptados y excluidos del modelo.
- Variables y secretos por nombre, consumidor y fuente, sin valores.
- DNS y estado actual por ambiente.
- Clúster/contexto/namespace como confirmado, candidato o pendiente.
- Manifiestos, puertos, sondas, volúmenes, RBAC, selectors y métricas.
- Capacidad mínima de AKS y margen para el rollout cuando corresponda.
- Secuencia, correcciones permitidas, readback y rollback.
- Operaciones exactas cubiertas por la aprobación.
- Confirmación de que Producción no se ejecutará todavía.
- Confirmación de que no se modificará código ni se eliminarán recursos.

## Aprobaciones

### Aprobación 1

Una sola aprobación cubre exactamente:

- Crear o reutilizar DNS sin conflicto.
- Crear configuraciones (Build/Release/Variable Group) aprobadas de
  Azure DevOps para los tres ambientes.
- Ejecutar y validar Desarrollo, y luego UAT, cuando este documento ya
  enumeró explícitamente que se van a ejecutar (regla del dominio ADO
  actualizada 2026-09-08 para permitir esto en una sola aprobación — ver
  `.cursor/rules/azure-devops.mdc` § "Preguntar
  una vez por operación atómica").
- Aplicar correcciones dentro de la envolvente y límite aprobado.

**No incluye Producción** — esa siempre exige la Aprobación 2 por
separado, sin excepción.
- Ejecutar polling, readback, journals y actualización de memorias correspondiente.

No pedir aprobación por cada variable, tarea, manifiesto, POST/PUT, Build, Release o consulta interna incluida.

### Aprobación 2

Producción requiere aprobación separada con commit, artifact, imagen/digest, DNS, clúster, namespace, node pool, diff, riesgo, rollback y resultados de Desarrollo/UAT.

### Eliminaciones y desviaciones

- Toda eliminación requiere aprobación separada.
- Cualquier operación fuera del plan requiere detenerse y replanificar.
- No utilizar una aprobación anterior para cambiar repositorio, rama, DNS, IP, clúster, namespace, node pool, permisos, secretos, conexiones o alcance.

## Secuencia

1. Validar `INPUT`, conexiones y snapshot.
2. Ejecutar descubrimientos y preflight en paralelo.
3. Generar y revisar el plan consolidado.
4. Solicitar Aprobación 1.
5. Aplicar DNS y Azure DevOps según dependencias (solo definiciones).
6. Ejecutar y monitorear Desarrollo (cubierto por la Aprobación 1).
7. Ejecutar y monitorear UAT únicamente si Desarrollo está estable (cubierto por la misma Aprobación 1).
8. Preparar Producción sin ejecutarla.
9. Entregar reporte no productivo.
10. Solicitar Aprobación 2 únicamente cuando el usuario decida continuar.

## Resultado por ambiente

Reportar separadamente:

| Estado | Significado |
|---|---|
| `Preparado` | Definiciones y configuración creadas, sin ejecución todavía. |
| `Build exitoso` | Artifact/imagen generados; no demuestra despliegue. |
| `Release ejecutado` | Release procesado; no demuestra disponibilidad del workload nuevo. |
| `Despliegue completado` | Rollout, pods nuevos, imagen y endpoint confirmados. |
| `Despliegue incompleto` | Rollout pendiente, bloqueado o agotó el timeout. |
| `Despliegue fallido` | Evidencia terminal de fallo. |
| `Versión anterior operativa` | El servicio responde con pods anteriores; nunca equivale al éxito de la versión nueva. |

No declarar éxito completo solamente porque el Build o Release aparezcan verdes.

## Errores, tiempos y memorias

- Registrar todos los errores en el journal.
- Guardar aprendizajes reutilizables únicamente en la memoria de su dominio.
- No duplicar el journal completo en todas las memorias.
- Registrar tiempo técnico, espera externa/usuario y tiempo total transcurrido.
- No almacenar secretos, tokens, kubeconfigs ni valores sensibles.

## Criterios de aceptación

El ciclo no productivo termina cuando:

- Las definiciones y DNS aprobados tienen readback correcto.
- Desarrollo está clasificado con evidencia.
- UAT está clasificado con evidencia; si queda incompleto, se informa la causa y el estado de la versión anterior.
- Producción permanece sin ejecución.
- No hubo eliminaciones ni cambios de código.
- El reporte incluye IDs, hashes, commits, tiempos, errores y memorias actualizadas.

Un bloqueo externo puede cerrar controladamente el ciclo sin declarar éxito del ambiente afectado.

## Texto para iniciar

> Ejecuta `docs/pipeline-cycles/app-directory.md` usando la skill `orchestrate-application-pipeline-cycle`. Toma los datos exclusivamente de `INPUT`, ejecuta en paralelo las consultas independientes y delega cada procedimiento a su skill de dominio. Preséntame un único plan no productivo y no escribas nada hasta que lo apruebe. Después de aprobar, no vuelvas a preguntar por operaciones incluidas en el plan. Producción y toda eliminación requieren aprobación separada. Monitorea Builds y Releases inmediatamente y cada intervalo configurado hasta estado terminal o timeout.
