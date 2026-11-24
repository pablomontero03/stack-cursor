# Ciclo de pipeline — gateway (optica-ecosystem)

Instancia del ciclo para `OpticaGateway` (YARP reverse proxy .NET 9).

Rama de trabajo: `feature/migracion` → PR a `development`.
Producción del Release usa `main` (no existe `refs/heads/release`).
Higiene Dr.Max (2026-11-24): sin Replace tokens; HPA min/max=1;
`hostAliases` no aplica (sin DB); probes HTTP `/health` puerto 8080;
Ingress sí (DNS público por ambiente).
Namespace Dev = `desarrollo` (RFC 1123; intake "Desarrollo" inválido).
**Naming:** `servicesname=optica-ecosystem-gateway`, `image=gateway-`.
Modelo Ingress: Build 709 (`optica-ecosystem-web`) + `Build-modelo-backend.json`.

```yaml
INPUT:
  application:
    id: gateway
    type: api

  repository:
    organization: Shared-Service-GM
    project: Dr.Max-Project
    name: optica-ecosystem
    url: 'https://dev.azure.com/Shared-Service-GM/Dr.Max-Project/_git/optica-ecosystem?version=GBdevelopment&path=/gateway/OpticaGateway'
    path: /gateway/OpticaGateway
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
    canonical_model_live_reference: 'https://dev.azure.com/Shared-Service-GM/DevOps/_build?definitionId=709'
    secret_sources:
      container_registry_password:
        environment_variable: ADO_SECRET_CONTAINERREGISTRYPASSWORD
        target_name: resolve_from_canonical_model

  application_variables:
    image: gateway-
    appname_candidate: optica-ecosystem-gateway
    servicesname: optica-ecosystem-gateway

  manifests:
    development: ./deployment-dev.yml
    uat: ./deployment-uat.yml
    production: ./deployment-prod.yml

  environments:
    development:
      namespace: desarrollo
      dns:
        fqdn: optica-ecosystem-gateway-dev.gmontecristo.com
        type: A
        # Misma IP pública unproxied que hermanos Dev/UAT en gmontecristo.com (sin orange cloud)
        ip: 177.93.30.165
        proxied: false
        ttl: auto
      cluster_candidate: k3s-dev
      node_selector: inherit
      ingress:
        className: nginx
        tlsSecret: gmontecristo-secret

    uat:
      namespace: uat
      dns:
        fqdn: optica-ecosystem-gateway-uat.gmontecristo.com
        type: A
        ip: 177.93.30.165
        proxied: false
        ttl: auto
      cluster_candidate: k3s-dev
      node_selector: inherit
      ingress:
        className: nginx
        tlsSecret: gmontecristo-secret

    production:
      namespace: application-services
      dns:
        fqdn: optica-ecosystem-gateway.grupomontecristo.com
        type: A
        # Sibling optica-ecosystem-web.grupomontecristo.com
        ip: 20.161.149.127
        proxied: false
        ttl: auto
      cluster_candidate: gmon-prod-aks-eastus2-0004
      node_selector: inherit
      ingress:
        className: internal-ingress
        tlsSecret: grupomontecristo-cert-secret

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
| Tecnología | .NET 9 Web (YARP) | `OpticaGateway.csproj` (`net9.0`, Yarp.ReverseProxy) |
| Archivo | `OpticaGateway.csproj` | `gateway/OpticaGateway/` |
| Puerto local | 5000 | `Properties/launchSettings.json` |
| Puerto contenedor | 8080 | Convención Optica Dockerfiles + probes |
| Health | `/health` | `Program.cs` `MapHealthChecks("/health")` |
| DB | no | sin ConnectionStrings → sin hostAliases |
| Dockerfile | **presente** (ICU Alpine) | PRs **16564**→`development`, **16565**→`uat` |
| ACR SC intake | no usar `SC-ACR-AZURE-GMON-DEV` | ACR Hub-2 |
| Branches reales | `development` / `uat` / `main` | no existe `refs/heads/release`; intake decía develop/release |
| Ingress ADDRESS k3s | `172.16.2.240` | `kubectl get ingress -n desarrollo` |
| DNS A Dev/UAT | `177.93.30.165` **proxied=false** | unproxied hermanos gmontecristo (p. ej. `*-dev/uat`); sin orange cloud |
| DNS A Prod | `20.161.149.127` proxied=false | sibling `optica-ecosystem-web.grupomontecristo.com` |
| DNS gateway | **creados** ×3, todos `proxied=false` | plan `579a0ea0…` aplicado; dig A OK |
| Plan DNS CF | applied + post-change OK | `.local/cloudflare/plans/gateway-dns-optica-ecosystem-579a0ea0-8130-4029-b7fb-4328b4da8af8.json` (`validationHash` `601a5937…`) |
| YARP backends | `http://optica-ecosystem-*-api.<ns>.svc.cluster.local` | manifests ConfigMap (dev/uat/prod) |
| Modelo Ingress | Build **709** + modelo-backend | class nginx+gmontecristo-secret (dev/uat); internal-ingress+grupomontecristo-cert-secret (prod) |
| AKS discovery | k3s ns OK; TLS `gmontecristo-secret` OK; margen pods ~58 | [AKS read validation Gateway](bc-4e301d52-55b1-5f5c-8728-5a7647e5a519) |
| YARP Dest Dev | 7 Services `optica-ecosystem-*-api` en `desarrollo` | auth, inventario, laboratorio, pacientes, rrhh, tickets, ventas |
| YARP Dest UAT | 6 Services (falta `auth-api` en vivo) | auth pendiente o degradado en UAT |

## Resultado ciclo (2026-11-24, Aprobación 1 no-prod)

| Recurso | Id |
|---|---|
| VG Dev / UAT / Prod | **576** / **574** / **575** |
| Build / Release | **721** (rev 2, `rutabuildcontext`) / **450** |
| PRs Dockerfile ICU | **16564**/`development`, **16565**/`uat` |
| Cloudflare DNS | 3× A `proxied=false` (Dev/UAT `177.93.30.165`, Prod `20.161.149.127`); `Test-CloudflarePostChange` matches=true; dig OK |
| Build+Dev | **29003** + Release **9066** Desarrollo → pod `optica-ecosystem-gateway` Running (`gateway-dev:29003`); Ingress `optica-ecosystem-gateway-dev.gmontecristo.com` → `172.16.2.240`; `/health` **200 Healthy** |
| Build+UAT | **29004** + Release **9068** UAT → deploy 1/1 Ready (`gateway-uat:29004`); Ingress `…-uat…` → `172.16.2.240`; `/health` **200 Healthy** |
| Nota UAT capacity | Tras `rollout restart` queda RS surplus Pending (`Insufficient cpu` en nodo único k3s); servicio saludable con 1 pod Ready. No se borró el Pending (delete = aprobación aparte). |
| Nota YARP UAT | Falta Service `optica-ecosystem-auth-api` en `uat` → ruta auth degradada hasta desplegar auth. |
| Jwt | Placeholder en Secret K8s; valor real fuera de este ciclo. |
| Producción | Pendiente Aprobación 2 (separada). Stage Prod del Release **no** ejecutado. |

## Trazabilidad intake → propuesto

| Concepto | Intake | Propuesto | Evidencia | Acción |
|---|---|---|---|---|
| Rama Dev | `develop` (+ PR a `development`) | `development` | ramas remotas + ciclos Optica previos | usar propuesto |
| Rama Prod | `release` | `main` | no existe `release` | usar propuesto |
| Namespace Dev | `Desarrollo` | `desarrollo` | RFC 1123 / k3s vivo | usar propuesto |
| ACR SC | `SC-ACR-AZURE-GMON-DEV` | `ACR Hub-2` | modelo-backend + Optica | usar propuesto |
| servicesname | `Gateway` | `optica-ecosystem-gateway` | patrón `<sistema>-<app>` | usar propuesto |
| ingress_host | "no aplica" vs DNS listados | DNS listados | sección DNS del intake | crear Ingress+DNS |
