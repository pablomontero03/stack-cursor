# Ciclo de pipeline — inventario-api (optica-ecosystem)

Instancia del ciclo para `Inventario.API`. Rama de trabajo de código:
`feature/migracion` → PR a `development`. Producción del Release usa
`main` de momento; migrará a `release` cuando exista esa rama (hoy
bloqueada por refs `release/*`).

```yaml
INPUT:
  application:
    id: inventario-api
    type: api

  repository:
    organization: Shared-Service-GM
    project: Dr.Max-Project
    name: optica-ecosystem
    url: 'https://dev.azure.com/Shared-Service-GM/Dr.Max-Project/_git/optica-ecosystem?version=GBdevelopment&path=/services/inventario/Inventario.API'
    path: /services/inventario/Inventario.API
    branches:
      development: development
      uat: uat
      production: main   # temporal; objetivo futuro: release

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
    image: inventario-api-
    # servicesname K8s = optica-ecosystem-inventario-api (corregido 2026-11-24)
    appname_candidate: optica-ecosystem-inventario-api
    servicesname: optica-ecosystem-inventario-api

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
      cluster_candidate: k3s-dev
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

## Notas

- Host: `Inventario.API` (.NET 9, puerto contenedor 8080, `/health`).
- Dockerfile creado en repo; manifests File Creator en
  `.local/azure-devops/manifests/optica-ecosystem-inventario-api/`.
- Ingress DNS: no aplica.
- Secretos de app en manifests: placeholders / Jwt compartido de Optica;
  ConnectionStrings y ServicioInventario deben revisarse antes de Prod.
- Build/Release propuestos: `Build-Optica-Ecosystem-inventario-api` /
  `Deploy-Desarrollo-UAT-Produccion-Optica-Ecosystem-inventario-api`.
- AKS (lectura 2026-11-24): prod `0004` + ns `application-services` OK;
  sin deployment inventario previo; capacidad rough OK. `k3s-dev` **no** está
  en el kubeconfig de este host → Dev/UAT namespaces/secret/capacidad pendientes
  hasta cargar el contexto. Manifest prod **sin** `acr-pull-secret`.
