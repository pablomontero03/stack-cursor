# Migración de automation-kiro a stack-cursor

Registro vivo. Cada fase marca su checklist y no reescribe el propósito de lo que ya existe en Kiro.

- Fuente de verdad del comportamiento: `/home/cursor/automation-kiro` (no se modifica durante la migración).
- Destino versionado: `/home/cursor/stack-cursor`.
- Fecha de inicio: 2026-11-23.
- Cursor no está instalado en el servidor. El uso será abrir esta carpeta desde Cursor por Remote SSH. `pwsh`, `az`, `kubectl` y `node` ya están en el servidor.

El stack Kiro está maduro. Al portar una skill o un subagente se copia el cuerpo, los `references`, los `assets`, los scripts y el prompt. Este documento fija el propósito para que esa copia no se redacte de nuevo.

## Cómo se actualiza

Al cerrar una fase: marcar las casillas, anotar la fecha en el registro y dejar la fuente intacta hasta la prueba en Cursor.

## Checklist

### Fase 1 — Esqueleto e inventario de propósitos

- [x] `README.md` con el estado y el modo de uso
- [x] `AGENTS.md` con el contrato (SQL de solo lectura, plan, revisión, aprobación)
- [x] `.gitignore` que deja fuera secretos y `.local/`
- [x] `env/.env.example` con los mismos nombres de variable que el ejemplo de Kiro, sin valores reales
- [x] Inventario de steering, skills, subagentes, memoria, hook y MCP (abajo)
- [x] Commit inicial sin secretos
- [x] `automation-kiro` sin cambios

### Fase 2 — Documentación y schema-sync

- [x] Copiar `docs/` completo, incluidos ciclos de pipeline, arquitectura por dominio y catálogos de servidores. Copia byte a byte, salvo la excepción de credenciales de abajo.
- [x] Copiar `schema-sync/` completo, byte a byte
- [x] Copiar las instrucciones de la raíz y `set-params.databases.json` a la misma ruta que en Kiro, sin cambiar el texto. Así las referencias no se rompen.
- [x] No reescribir rutas ni instrucciones en esta fase. El texto queda con los mismos propósitos y la misma lógica. El cambio de `.kiro/` a `.cursor/` se hace en la fase que crea esos archivos, y solo como sustitución de ruta.
- [x] Revisar secretos antes del commit. Única excepción: en `docs/azure-devops/Build-modelo-backend.json` se sustituyeron 18 valores literales de `ADMIN_API_KEY`, `CRYPTOP_SECRET_KEY`, `ELASTICSEARCH_PASSWORD`, `JIRA_WEBHOOK_SECRET`, `REDIS_PASSWORD` y `RSA_PASSPHRASE` por `${REDACTED}`. Las claves y el resto del modelo siguen.

### Fase 3 — Rules y skills

El texto de cada steering y de cada `SKILL.md` se conserva. Los `triggers` de Kiro se suman al `description` de Cursor y también se dejan en el frontmatter. No se reemplaza el procedimiento.

- [x] Sustituir solo rutas de archivos que existen y se están moviendo. El resto de la instrucción queda igual.
- [x] 9 steering `always` → `.cursor/rules/*.mdc` con `alwaysApply: true`. El cuerpo es el original.
- [x] `ado-task-logging-workflow.md` → `.cursor/rules/ado-task-logging-workflow.mdc` con `alwaysApply: false` y el mismo texto.
- [x] 11 skills de dominio en `.cursor/skills/`, con `references/`, `assets/` y `scripts/` íntegros (161 archivos en total, incluido `skill-creator`).
- [x] `skill-creator` se portó completo. No se descartó el procedimiento de evals.

Rutas que sí se actualizaron, porque el archivo existe o va a existir en la fase 4 con ese nombre:

- `.kiro/skills/` → `.cursor/skills/`
- `.kiro/settings/mcp.json` → `.cursor/mcp.json`
- `.kiro/agent-memory/` → `.cursor/memories/`
- `/home/kiro/proyectos/repositorios/automation-kiro` → `/home/cursor/stack-cursor`
- Citas a subagentes (`.kiro/agents/<dominio>/<nombre>.md`) → `.cursor/agents/<nombre>.md`, que es donde la fase 4 escribe el prompt original.

Rutas que se dejaron escritas igual a propósito: `.kiro/steering/<dominio>/security.md`, `.kiro/steering/<dominio>/authorization.md`, `.kiro/rules/<dominio>/authorization.md` y `.kiro/hooks/azure/*.ps1`. Esos archivos no existen en Kiro. Inventarlos habría sido escribir reglas nuevas. El texto operativo está en el `SKILL.md`, en `references/` y en el steering plano que ya quedó como rule.

### Fase 4 — Subagentes y memoria

El JSON de Kiro pasa a `.cursor/agents/<nombre>.md`. El campo `prompt` es el cuerpo, completo. `name` y `description` van al frontmatter, con el description de este inventario.

Cursor no tiene la lista de tools de Kiro (`fs_read`, `grep`, `execute_bash`, `fs_write`, `str_replace`). El límite de solo lectura de reviewers y diagnosers queda escrito en el prompt, además del hook de SQL.

- [ ] 24 subagentes convertidos sin recortar el prompt
- [ ] `.kiro/agent-memory/` → `.cursor/memories/<agente>/`, archivos tal cual
- [ ] Cada subagente apunta a su carpeta de memoria para leerla y actualizarla
- [ ] Incidentes de pipelines (lista abajo) copiados uno a uno

### Fase 5 — Hook y MCP

- [ ] `sql-readonly-gate` en `.cursor/hooks.json` (`beforeShellExecution`), mismo criterio de bloqueo
- [ ] Un solo `.cursor/mcp.json` con rutas de este servidor
- [ ] Tokens solo por variable de entorno (`env/.env`), nunca dentro del JSON
- [ ] Servidores: `azure-devops`, `aks`, `n8n-interno`, `n8n-productivo`, `cloudflare-api`

### Fase 6 — setup del servidor

- [ ] `setup.sh` comprueba `pwsh`, `az`, `kubectl`, `node`, `git` y el binario `aks-mcp`
- [ ] Deja de exigir `kirocrew` y `kiro-cli`
- [ ] `REPO_ROOT` = esta carpeta

### Fase 7 — Prueba en Cursor

- [ ] Abrir `/home/cursor/stack-cursor` por Remote SSH
- [ ] Las rules cargan
- [ ] Un subagente de solo lectura responde con su propósito original
- [ ] El hook bloquea un intento de escritura SQL
- [ ] A partir de aquí `automation-kiro` deja de ser la fuente de verdad

## Fuera de git, conservado en el servidor

No es pérdida: es material que no debe versionarse. Queda donde está.

| Qué | Dónde | Decisión |
|---|---|---|
| Sesiones, crew, logs, vault | `/home/kiro/.kiro` (~7.2 GB) | No entra al repo. La memoria ya destilada sí. |
| Estado de kiro-cli | `/home/kiro/.local/share/kiro-cli` (~1.6 GB) | No entra al repo. |
| Planes, ejecuciones, exports | `automation-kiro/.local` (~201 MB, hoy trackeado pese al gitignore) | No se copia. `.local/` de este repo queda ignorado. |
| Claves, PEM, conexiones, API keys | `automation-kiro/env/` (varios archivos trackeados pese al gitignore) | No se copian. Solo `.env.example`. |
| Bearer de n8n dentro de `mcp.json` | `.kiro/settings/mcp.json` y `.mcp.json` | No se copia el valor. Conviene rotarlo: ya está en el historial de `automation-kiro`. |

## Registro

### 2026-11-23 — Fase 1

Esqueleto commiteado en `stack-cursor`. Inventario de propósitos escrito desde los frontmatter y los `description` originales. `automation-kiro` no se tocó.

### 2026-11-23 — Fase 2

Se copió `docs/` (42 archivos), `schema-sync/` (3 archivos) y los cinco archivos de raíz que no son el esqueleto: las cuatro `INSTRUCCIONES-*.md` y `set-params.databases.json`. El contenido es el de Kiro. `INSTRUCCIONES-AUTOMATIZACION-CLOUDFLARE.md` de la raíz es el mismo archivo que `docs/azure-devops/INSTRUCCIONES-AUTOMATIZACION-CLOUDFLARE.md`; se conservan las dos copias, como en el origen.

No se parafraseó ningún procedimiento. Las rutas `.kiro/` siguen escritas igual, a propósito, hasta que existan los archivos de Cursor.

Excepción de seguridad: `docs/azure-devops/Build-modelo-backend.json` traía credenciales en claro (18 valores, repetidos en tres bloques). Esos valores quedaron como `${REDACTED}`. Los nombres de variable no se tocaron. Conviene rotar esas credenciales porque siguen en el historial de `automation-kiro`.

### 2026-11-23 — Fase 3

10 rules en `.cursor/rules/` y 12 skills en `.cursor/skills/` (161 archivos). El cuerpo de cada steering y de cada skill, incluidos scripts, references y assets, es el de Kiro. En el frontmatter de cada skill se conservaron `triggers` y `always`, y los triggers se añadieron al final del `description` para que Cursor pueda activarla.

No se reescribieron procedimientos. La revisión de secretos en las skills encontró solo valores de prueba (`DUMMY-...`, `FAKE_TEST_...`, fixtures). Se dejaron, porque forman parte de los tests.

`automation-kiro` no se modificó.

## Mapa de porte (todavía no ejecutado)

| Kiro | Cursor en este repo |
|---|---|
| `.kiro/steering/*.md` | `.cursor/rules/*.mdc` |
| `.kiro/skills/<skill>/` | `.cursor/skills/<skill>/` |
| `.kiro/agents/*.json` | `.cursor/agents/<nombre>.md` |
| `.kiro/agent-memory/<agente>/` | `.cursor/memories/<agente>/` |
| `.kiro/hooks/sql-readonly-gate.*` | `.cursor/hooks.json` + `.cursor/hooks/sql-readonly-gate.sh` |
| `.kiro/settings/mcp.json` | `.cursor/mcp.json` |
| `docs/`, `schema-sync/` | mismas rutas |
| `setup.sh` | `setup.sh` adaptado a este servidor |

## Steering — propósito

Se cargan solos salvo el de la Task, que es manual. El texto completo se porta en la fase 3.

| Archivo | Carga | Para qué existe |
|---|---|---|
| `global.md` | always | Raíz del repo, `pwsh`, SQL de solo lectura, modelo de aprobaciones mínimas con plan previo. |
| `azure.md` | always | Plano ARM (redes, VMs, App Service, ACR, Storage, Key Vault, Policy, RBAC, Cost Management en lectura, AKS como recurso). Flujo `New-AzureChangePlan` → test → aprobación → apply. No sustituye a Kubernetes. |
| `aks.md` | always | Objetos Kubernetes y Helm. Contextos de kubeconfig. Confirmar contexto activo antes de operar. |
| `azure-devops.md` | always | Pipelines y permisos de `Shared-Service-GM` / proyecto `DevOps`. Familias AKS y DACPAC separadas. MCP `azure-devops` primero; PAT solo como fallback de lectura. |
| `cloudflare.md` | always | DNS, WAF, Workers, Zero Trust, Tunnels y el resto de la cuenta. MCP `cloudflare-api` y API REST con token, no Global API Key. |
| `n8n.md` | always | Dos instancias que no se mezclan: `n8n-interno` (172.16.2.60, Schema Sync y monitoreo SQL) y `n8n-productivo` (automation.grupomontecristo.com, incluye MAIA). Si no está claro cuál es, se pregunta antes de ejecutar. |
| `schema-sync.md` | always | SQL → repos SSDT. Una sola base por vez. `databases.json` es el catálogo. Sin `Publish` ni escritura SQL. |
| `servers.md` | always | Catálogos `docs/servers/servers.json` y `docs/servers/windows/servers.json`. No asumir IP ni usuario vigentes. |
| `orchestration.md` | always | Solo cuando un pipeline de aplicación cruza 2 o más dominios. Un solo dominio va a su skill. Producción y borrados siguen con aprobación aparte. No modifica código de la aplicación. |
| `ado-task-logging-workflow.md` | manual | Al dar un trabajo por terminado: crear la Task en Azure DevOps y la segunda acción que el steering define junto con ella. |

## Skills — propósito

`always: false` en todas. El `description` y los `triggers` son los originales. En la fase 3 se copia el directorio entero, no solo `SKILL.md`.

### analyze-azure-costs

Análisis FinOps de la suscripción Azure Hospital Metropolitano: costos, consumo, anomalías, tendencias, pronósticos y oportunidades de optimización de cualquier servicio Azure.

Triggers: costos, finops, cost management, presupuesto, optimizacion, billing, azure costs.

Sub-skill de `manage-azure-resources`. Reusa su común, su plan/aprobación y los agentes de Azure. No duplica ese mecanismo.

### manage-aks-clusters

Administra, diagnostica y opera clústeres AKS/Kubernetes/Helm mediante kubectl, Helm y Azure CLI para pods, deployments, servicios, ingress, namespaces, node pools, autoscaling, RBAC y Secrets.

Triggers: aks, kubernetes, kubectl, helm, cluster, namespace, pod, deployment, ingress.

Dominio separado de pipelines, permisos, Schema Sync y servidores Linux.

### manage-azure-devops-permissions

Administra grupos de seguridad de proyecto, membresías, permisos Git y Branch Policies en proyectos de Shared-Service-GM para grupos Development Team y Code-Reviewers.

Triggers: permisos, permissions, grupos, members, code-reviewers, development team, ado.

Dominio separado de pipelines. El MCP `azure-devops` se usa para inventario de proyectos, repos y ramas. Graph y Security ACL van por los scripts del skill, porque el toolset oficial no los expone.

### manage-azure-devops-pipelines

Gestiona, crea, revisa y diagnostica pipelines de Azure DevOps para Shared-Service-GM mediante el MCP oficial y APIs REST: pipelines clásicos o YAML, Builds, Releases, Variable Groups, task groups, despliegues AKS o DACPAC.

Triggers: pipeline, ado, azure devops, build, release, dacpac, ssdt, deployment, devops.

Organización `Shared-Service-GM`, proyecto `DevOps`. Carga solo la guía del modo que corresponde. No mezcla la familia AKS con la DACPAC.

### manage-azure-resources

Administra el plano de control de Microsoft Azure vía Azure CLI y Resource Graph: VNets, NSG, VMs, App Service, ACR, Storage, Key Vault, RBAC, Policy, Monitor y AKS como recurso de Azure.

Triggers: azure, arm, resource group, az cli, vnet, nsg, vm, storage, keyvault, policy, rbac.

Los objetos dentro del clúster no son de este skill.

### manage-cloudflare

Administra Cloudflare vía MCP oficial y API REST: DNS, WAF, Workers, Pages, Zero Trust, Tunnels, SSL, Cache, Rulesets, KV, R2, D1 y Load Balancing.

Triggers: cloudflare, dns, waf, workers, pages, zero trust, tunnel, ssl, cache, ruleset.

### manage-linux-servers

Administra de forma controlada vía SSH cualquier servidor Linux del catálogo `docs/servers/servers.json`: mantenimiento del SO, aplicativos, instalación, diagnóstico y reinicio controlado.

Triggers: linux, servidor, ssh, bash, systemd, logs, service, puerto.

El acceso es shell real, sin una capa intermedia que limite el daño. Por eso el reviewer mira el cambio antes de aplicarlo.

### manage-windows-servers

Administra de forma controlada vía WinRM/PowerShell Remoting cualquier servidor Windows del catálogo `docs/servers/windows/servers.json`: mantenimiento del SO, aplicativos, IIS, servicios y reinicio controlado.

Triggers: windows, server, iis, powershell, event log, windows service.

### manage-n8n-monitoring

Opera, diagnostica y clona workflows n8n de monitoreo SQL y ajusta timeouts del workflow de IA AIA-CC-MAIA-Chat en las instancias internas de n8n.

Triggers: n8n, workflow, monitoreo sql, maia, automatizacion, clonar, schedule.

Runbook de API: `docs/n8n-monitoring/N8N-API-RUNBOOK.md`.

### manage-schema-sync-ssdt

Opera, revisa y diagnostica la sincronización de esquemas SQL hacia repositorios SSDT mediante SchemaSyncTool, SqlPackage, Azure DevOps y n8n.

Triggers: schema sync, ssdt, dacpac, base de datos, schema, sincronizacion.

Procedimiento: `schema-sync/README.md`. Catálogo: `schema-sync/databases.json` cuando exista.

### orchestrate-application-pipeline-cycle

Coordina el ciclo completo de creación/validación de un pipeline de aplicación cuando la solicitud involucra dos o más de: Azure DevOps clásico, Cloudflare DNS, análisis de código/ramas, Kubernetes/AKS y ejecución Desarrollo/UAT.

Triggers: ciclo completo, pipeline ciclo, orquestacion, multi-dominio, nueva aplicacion.

Skill coordinadora. No tiene vía de escritura propia. Delega el apply en los scripts de cada dominio.

### skill-creator

Crea skills nuevas, modifica las existentes y mide rendimiento con evals y benchmarks.

Triggers: nueva skill, crear skill, documentar procedimiento, skill creator.

En Cursor la creación de skills ya tiene soporte propio. El porte de este directorio se decide en la fase 3 para no perder el método de evals. No se descarta en silencio.

## Subagentes — propósito

24 agentes, modelo `auto`. Rol típico por dominio: quien prepara o aplica, quien revisa antes de tocar, quien diagnostica la primera causa. El `description` es el original y es el que debe quedar en el frontmatter.

Tools de Kiro, a conservar como restricción en el prompt:

- Diagnosers y reviewers de AKS, Azure, ADO, Linux, Windows y Schema Sync: `fs_read`, `grep` (no ejecutan ni escriben).
- Operators, FinOps, builders de permisos: `fs_read`, `grep`, `execute_bash`.
- `ado-pipeline-builder`: además `str_replace` y `fs_write`, porque entrega artefactos. No pide aprobación ni corre Apply.
- Cloudflare diagnoser/reviewer y n8n reviewer: `fs_read`, `grep`, `fs_write`, `str_replace`.

### AKS

- **aks-diagnoser.** Diagnóstico de solo lectura de clústeres AKS: eventos, logs, métricas, scheduling, red, DNS, almacenamiento, ingress, autoscaling, nodos y salud general. Usar cuando un pod, deployment, servicio o nodo de AKS falle y se necesite identificar la primera causa real antes de proponer un cambio.
- **aks-operator.** Inventario, planificación y ejecución aprobada de cambios sobre clústeres AKS (kubectl/Helm/Azure CLI/MCP aks). Usar para diagnosticar el estado antes de un cambio, generar un plan, validarlo, o aplicar un plan ya aprobado con `Apply-AksChangePlan.ps1`.
- **aks-reviewer.** Revisa de forma independiente un plan de cambio AKS (contexto, impacto, seguridad, respaldos, rollback y readback) antes de cualquier aplicación real. Usar antes de pedir aprobación o de correr `Apply-AksChangePlan.ps1`.

### Azure

- **azure-diagnoser.** Diagnóstico de solo lectura de recursos ARM: Activity Log, estado, Resource Graph, locks, RBAC, redes y salud general. Usar cuando una VM, App Service, Storage, red, Azure SQL como infraestructura o AKS como recurso falle y haga falta la primera causa antes de proponer un cambio.
- **azure-operator.** Inventario, planificación y ejecución aprobada sobre ARM (Azure CLI/Resource Graph/ARM REST). Aplicar solo un plan ya aprobado con `Apply-AzureChangePlan.ps1` / `Apply-AzureDeletePlan.ps1`.
- **azure-reviewer.** Revisión independiente del plan ARM (contexto, impacto, seguridad, respaldos, rollback y readback) antes de aplicar o de correr esos Apply.
- **azure-finops-analyst.** Análisis FinOps de la suscripción Hospital Metropolitano: costos, consumo, utilización, anomalías, tendencias, pronósticos y optimización de cualquier servicio (AKS, SQL, Azure OpenAI, Monitor/Log Analytics, redes, storage, reservas). Usar para explicar variaciones, comparar periodos, pronosticar el cierre, investigar anomalías, hallar ociosos o sobredimensionados, correlacionar costo con utilización y generar reportes.

### Azure DevOps — pipelines

- **ado-pipeline-builder.** Prepara y valida planes y payloads de pipelines clásicos (AKS o DACPAC) para Shared-Service-GM/DevOps. Subagente de preparación: nunca solicita la aprobación ni ejecuta Apply; entrega los artefactos finales a la sesión principal.
- **ado-pipeline-reviewer.** Revisa de forma independiente un plan de pipeline clásico contra las guías y el inventario en vivo, antes de cualquier aplicación. Usar antes de pedir aprobación para crear un Build/Release/Variable Group clásico o antes de correr `Apply-AdoClassicPlan.ps1`.
- **ado-pipeline-diagnoser.** Analiza builds, releases, logs y artefactos fallidos de Azure DevOps clásico (AKS o DACPAC). Usar cuando un Build, Release o deploy falle y se necesite la primera causa real antes de reintentar o modificar algo.

### Azure DevOps — permisos

- **ado-permissions-builder.** Administra grupos de proyecto (Development Team(s), Code-Reviewers), membresías y permisos Git de Shared-Service-GM a partir de intake + inventario + plan aprobado. Usar para crear o reutilizar grupos, normalizar descripción, agregar miembros, normalizar permisos Git repo/rama contra la matriz, o correr un plan ya validado con Apply tras aprobación explícita.
- **ado-permissions-reviewer.** Revisa el plan contra la matriz y el inventario en vivo antes de aplicar. No aplica cambios. Cubre `Apply-AdoPermissionsPlan.ps1` y `Apply-AdoPermissionsDeletePlan.ps1`.
- **ado-permissions-diagnoser.** Diagnostica fallas de MCP, Graph API, Security API, PAT/scopes, descriptores, tokens de seguridad, herencia y readback. No corrige nada sin un plan aprobado.

### Cloudflare

- **cloudflare-diagnoser.** Diagnóstico de solo lectura: DNS, propagación, SSL/TLS, WAF, cache, Workers, Pages, Zero Trust, Tunnels, balanceadores, logs y analytics. Primera causa antes de proponer un cambio.
- **cloudflare-operator.** Inventario, planificación y ejecución aprobada (API REST, MCP cloudflare-api, Terraform, Wrangler), incluidos planes de eliminación. Apply con `Apply-CloudflareChangePlan.ps1` / `Apply-CloudflareDeletePlan.ps1`.
- **cloudflare-reviewer.** Revisa scope, cuenta, zona, drift, dependencias, impacto, backups, eliminación lógica, rollback y readback antes de crear, modificar o eliminar.

### Servidores

- **linux-server-diagnoser.** Lee Linux, recursos, servicios, Docker/systemd y aplicativos del catálogo `docs/servers/servers.json` a partir de salidas ya obtenidas. Primera causa antes de proponer un cambio.
- **linux-server-reviewer.** Revisa, antes de aplicarlo, edición de archivos, Docker Compose, instalación, actualización o reinicio en cualquiera de esos servidores.
- **windows-server-diagnoser.** Igual en lectura para `docs/servers/windows/servers.json`, con salidas de PowerShell ya obtenidas.
- **windows-server-reviewer.** Revisa el cambio de Windows antes de pedir aprobación.

### n8n y Schema Sync

- **n8n-monitoring-diagnoser.** Analiza ejecuciones fallidas de workflows de monitoreo SQL o de AIA-CC-MAIA-Chat. Primera causa antes de reintentar o modificar.
- **n8n-monitoring-reviewer.** Revisa clones de packs de monitoreo SQL y cambios masivos (por ejemplo timeouts) antes de crear el pack o hacer PUT sobre varios nodos o workflows.
- **schema-sync-diagnoser.** Analiza logs y resultados de Schema Sync, SqlPackage, DacFx, SSDT, Git, Azure DevOps y n8n cuando falla una corrida, un build DACPAC, un assert o una notificación.
- **schema-sync-reviewer.** Revisa cambios de Schema Sync, SSDT, catálogos y workflows, con énfasis en solo lectura, mappings, Git y validaciones, antes de aceptar un cambio grande o habilitar una base.

## Memoria por subagente

Cada carpeta tiene `MEMORY.md`, `patterns.md` y `debugging.md`. Se copian enteros en la fase 4. Estos expedientes extra también:

**ado-pipeline-builder**

- `ado-administracion-proyectos-web-reconstruction-2026-08-26.md`
- `ado-buklo-microservice-ai-2026-08-27.md`
- `ado-buklo-microservice-auth-2026-08-27.md`
- `ado-buklo-microservice-billing-2026-08-27.md`
- `ado-buklo-microservice-emr-2026-08-27.md`
- `ado-buklo-microservice-engine-2026-08-27.md`
- `ado-buklo-microservice-gateway-dev-uat-2026-08-26.md`
- `ado-buklo-microservice-notifications-2026-08-27.md`
- `ado-buklo-microservice-storage-2026-08-27.md`
- `ado-buklo-uat-dbname-batch-2026-09-02.md`
- `ado-buklo-web-standalone-build-2026-09-01.md`
- `ado-classic-aks-plan-multi-env-generator-gaps.md`
- `ado-emr-scratch-script-authorization-declined-2026-08-27.md`
- `ado-release-create-update-real-bugs-2026-08-26.md`
- `ado-update-plan-runner-added-2026-08-27.md`

**ado-pipeline-reviewer**

- `ado-administracion-proyectos-rebuild-review-2026-08-26.md`
- `ado-administracion-proyectos-rebuild2-review-2026-08-26.md`
- `ado-plan-bodyhash-only-manifest-verification-gap.md`

El resto de subagentes, en esta fecha, solo tiene los tres archivos base.

## Hook

`sql-readonly-gate` corre antes de ejecutar bash. Lee el comando por stdin y bloquea escritura SQL (`INSERT`, `UPDATE`, `DELETE`, `DROP`, `ALTER`, `TRUNCATE`, `MERGE`, `CREATE`, `GRANT`, `REVOKE` y el resto de patrones del script). En Cursor el evento equivalente es `beforeShellExecution`. El script se adapta al protocolo de respuesta de Cursor; los patrones se mantienen.

## MCP a unificar en la fase 5

Hoy hay dos archivos distintos (rutas Windows en `.mcp.json` y rutas Linux viejas en `.kiro/settings/mcp.json`). Queda uno solo, relativo a este repo:

| Servidor | Para qué |
|---|---|
| `azure-devops` | `@azure-devops/mcp` sobre `Shared-Service-GM`, auth por `ADO_MCP_AUTH_TOKEN` |
| `aks` | binario `aks-mcp` v0.0.20, kubeconfig del servidor |
| `n8n-interno` | MCP del n8n en `172.16.2.60` |
| `n8n-productivo` | MCP de `automation.grupomontecristo.com` |
| `cloudflare-api` | `https://mcp.cloudflare.com/mcp` |

El MCP de Azure ARM (`@azure/mcp`) está diferido en el steering: el dominio Azure funciona con Azure CLI.
