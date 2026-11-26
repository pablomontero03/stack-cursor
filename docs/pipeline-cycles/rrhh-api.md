# Ciclo de pipeline — rrhh-api (optica-ecosystem)

Instancia del ciclo para `RRHH.API` (.NET 9 Web API).

Rama de trabajo: `feature/migracion` → PR a `development`.
Producción del Release usa `main` (no existe `refs/heads/release`).
Higiene Dr.Max (2026-11-24): sin Replace tokens; HPA min/max=1; hostAliases
con DB (`RRHHDB`); probes HTTP `/health` puerto 8080; Ingress no aplica.
Namespace Dev = `desarrollo` (RFC 1123; intake "Desarrollo" inválido).

```yaml
INPUT:
  application:
    id: rrhh-api
    type: api

  repository:
    organization: Shared-Service-GM
    project: Dr.Max-Project
    name: optica-ecosystem
    url: 'https://dev.azure.com/Shared-Service-GM/Dr.Max-Project/_git/optica-ecosystem?version=GBdevelopment&path=/services/rrhh/RRHH.API'
    path: /services/rrhh/RRHH.API
    branches:
      development: development
      uat: uat
      production: main

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
    image: rrhh-api-
    # servicesname K8s = optica-ecosystem-rrhh-api (corregido 2026-11-24)
    appname_candidate: optica-ecosystem-rrhh-api
    servicesname: optica-ecosystem-rrhh-api

  manifests:
    development: ./deployment-dev.yml
    uat: ./deployment-uat.yml
    production: ./deployment-prod.yml

  environments:
    development:
      namespace: desarrollo
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
    allow_application_code_changes: true
    allow_deletions: false
    agentic_mode: "on"
```

## Validado en fuente

| Campo | Valor | Evidencia |
|---|---|---|
| Tecnología | .NET 9 Web API | `RRHH.API.csproj` |
| Archivo | `RRHH.API.csproj` | repo |
| Puerto contenedor | 8080 | Dockerfile (launchSettings local 5004) |
| Health | `/health` | `Program.cs` |
| DB | `ConnectionStrings:RRHHDB` | appsettings → hostAliases sí |
| ACR SC intake | no usar `SC-ACR-AZURE-GMON-DEV` | ACR Hub-2 |
| Pipeline previo | no existe | inventario `\\Optica-Ecosystem` |

## Resultado ciclo (2026-11-24, Aprobación 1 no-prod)

| Recurso | Id |
|---|---|
| VG Dev / UAT / Prod | **567** / **565** / **566** |
| Build / Release | **718** (rev 2, `rutabuildcontext`) / **447** |
| PRs | 16498 → development, 16499 → uat (merged) |
| Build+Dev | 28942 + Release **9012** Desarrollo → **OK** |
| Build+UAT | 28943 + Release **9013** UAT → **OK** |

**Prod** queda fuera (Aprobación 2). Secretos runtime RRHHDB/Jwt siguen placeholder.
