# Ciclo de pipeline — inventario-jobs (optica-ecosystem)

Instancia del ciclo para `Inventario.Jobs` (Azure Functions Worker .NET 9
isolated: TimerTriggers + Durable Task + HttpTriggers admin).

**No es CronJob de Kubernetes.** El host Functions debe correr always-on
como Deployment (réplicas=1) para que los TimerTriggers y el hub Durable
funcionen. Ingress DNS: no aplica (ClusterIP para HttpTriggers internos).

Rama de trabajo de código: `feature/migracion` → PR a `development`.
Producción del Release usa `main` de momento; migrará a `release` cuando
exista esa rama (hoy no hay `refs/heads/release`).

```yaml
INPUT:
  application:
    id: inventario-jobs
    type: api

  repository:
    organization: Shared-Service-GM
    project: Dr.Max-Project
    name: optica-ecosystem
    url: 'https://dev.azure.com/Shared-Service-GM/Dr.Max-Project/_git/optica-ecosystem?version=GBdevelopment&path=/services/inventario/Inventario.Jobs'
    path: /services/inventario/Inventario.Jobs
    branches:
      development: development   # intake decía develop; PR y CI Optica usan development
      uat: uat
      production: main           # temporal; objetivo futuro: release

  azure_devops:
    project: DevOps
    pipeline_folder: '\Optica-Ecosystem'
    pipeline_folder_url: 'https://dev.azure.com/Shared-Service-GM/DevOps/_build?definitionScope=%5COptica-Ecosystem'
    canonical_exports_directory: '/home/cursor/stack-cursor/docs/azure-devops'
    build_export_candidates:
      - Build-modelo-backend.json
    release_export: Release-modelo-backend.json
    secret_sources:
      container_registry_password:
        environment_variable: ADO_SECRET_CONTAINERREGISTRYPASSWORD
        target_name: resolve_from_canonical_model

  application_variables:
    image: inventario-jobs-
    appname_candidate: inventario-jobs

  manifests:
    development: ./deployment-dev.yml
    uat: ./deployment-uat.yml
    production: ./deployment-prod.yml

  environments:
    development:
      namespace: Desarrollo
      dns:
        fqdn: no-aplica
        type: A
        ip: n/a
        proxied: false
        ttl: auto
      cluster_candidate: k3s-dev
      node_selector: inherit

    uat:
      namespace: uat
      dns:
        fqdn: no-aplica
        type: A
        ip: n/a
        proxied: false
        ttl: auto
      cluster_candidate: k3s-uat
      node_selector: inherit

    production:
      namespace: application-services
      dns:
        fqdn: no-aplica
        type: A
        ip: n/a
        proxied: false
        ttl: auto
      cluster_candidate: gmon-prod-aks-eastus2-0004
      node_selector: inherit

  discovery:
    cluster_validation_before_plan: minima

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
    allow_application_code_changes: true   # Dockerfile + manifests en feature/migracion
    allow_deletions: false
    agentic_mode: "on"
```

## Notas (validado en fuente)

| Campo | Valor derivado | Evidencia |
|---|---|---|
| Tecnología | Azure Functions Worker .NET 9 isolated (`AzureFunctionsVersion=v4`) | `Inventario.Jobs.csproj` |
| Archivo proyecto | `Inventario.Jobs.csproj` | repo `feature/migracion` |
| Descripción | Jobs de reposición inventario (corrida nocturna, aviso borradores, limpieza historial, replicar sedes) | `Program.cs` + `Functions/*` |
| Puerto contenedor | 80 (imagen `azure-functions/dotnet-isolated`) | Dockerfile |
| Health HTTP | no; probes `tcpSocket` | HttpTriggers con Function key |
| Ingress | no aplica | intake + ClusterIP para admin HTTP |
| Schedules | Timer `0 */15 * * * *` (chequeo) + `0 30 3 * * *` (limpieza); ventana real desde BD | `CorridaNocturnaTrigger`, `LimpiezaHistorialEjecucionTrigger` |
| Durable hub | `InventarioReposicionHub` | `host.json` |
| Env requeridos | `AzureWebJobsStorage`, `FUNCTIONS_WORKER_RUNTIME`, `ConnectionStrings:InventarioDB`, `AuthApi/VentasApi/LaboratorioApi:BaseUrl`, `ServicioInventario:*` | `local.settings.example.json` |
| Replicas | 1 (obligatorio: no duplicar TimerTriggers) | intake + diseño Functions |

## Pendientes de secreto (placeholders en manifests)

- `AzureWebJobsStorage` — connection string real de Storage (Durable + timers)
- `ConnectionStrings__InventarioDB`
- `ServicioInventario__Usuario` / `ServicioInventario__Password`

## Artefactos de código

- Dockerfile + `deployment-{dev,uat,prod}.yml` en
  `services/inventario/Inventario.Jobs/` (rama `feature/migracion`)
- Copia local de manifests también bajo
  `.local/azure-devops/manifests/optica-ecosystem-inventario-jobs/` para File Creator
