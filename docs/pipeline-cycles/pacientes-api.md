# Ciclo de pipeline — pacientes-api (optica-ecosystem)

Instancia del ciclo para `Pacientes.API` (.NET 9 Web API).

Rama de trabajo: `feature/migracion` → PR a `development`.
Producción del Release usa `main` (no existe `refs/heads/release`).
Higiene Dr.Max (2026-11-24): sin Replace tokens; HPA min/max=1; hostAliases
solo con DB (sí aplica: PacientesDB + CrmDB); probes HTTP `/health` puerto 8080;
Ingress no aplica. Namespace Dev = `desarrollo` (RFC 1123; intake "Desarrollo" inválido).

```yaml
INPUT:
  application:
    id: pacientes-api
    type: api

  repository:
    organization: Shared-Service-GM
    project: Dr.Max-Project
    name: optica-ecosystem
    url: 'https://dev.azure.com/Shared-Service-GM/Dr.Max-Project/_git/optica-ecosystem?version=GBdevelopment&path=/services/pacientes/Pacientes.API'
    path: /services/pacientes/Pacientes.API
    branches:
      development: development   # intake decía develop; PR/CI Optica usan development
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
    image: pacientes-api-
    # servicesname K8s = optica-ecosystem-pacientes-api (corregido 2026-11-24)
    appname_candidate: optica-ecosystem-pacientes-api
    servicesname: optica-ecosystem-pacientes-api

  manifests:
    development: ./deployment-dev.yml
    uat: ./deployment-uat.yml
    production: ./deployment-prod.yml

  environments:
    development:
      namespace: desarrollo   # RFC 1123. Intake "Desarrollo" rompe kubectl (lección laboratorio-api).
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
| Tecnología | .NET 9 Web API (`Microsoft.NET.Sdk.Web`) | `Pacientes.API.csproj` |
| Archivo | `Pacientes.API.csproj` | repo |
| Puerto contenedor | 8080 | Dockerfile (launchSettings local 5007) |
| Health | `/health` | `Program.cs` MapHealthChecks |
| DB | `ConnectionStrings:PacientesDB`, `CrmDB` | appsettings → hostAliases sí |
| ACR SC intake | no usar `SC-ACR-AZURE-GMON-DEV` | patrón hermanos: ACR Hub-2 |
| Pipeline previo | no existe | inventario DevOps `\\Optica-Ecosystem` |

## Resultado ciclo (2026-11-24, Aprobación 1 no-prod)

| Recurso | Id |
|---|---|
| VG Dev / UAT / Prod | **564** / **562** / **563** |
| Build / Release | **717** (rev 2, `rutabuildcontext`) / **446** |
| PRs | 16484 → development, 16485 → uat (merged) |
| Build+Dev | 28919 + Release **8999** Desarrollo → **OK** |
| Build+UAT | 28920 + Release **9000** UAT → **OK** |

**Prod** queda fuera (Aprobación 2). Secretos runtime PacientesDB/CrmDB/Jwt siguen placeholder. Namespace Dev ya nació como `desarrollo` (lección laboratorio-api).
