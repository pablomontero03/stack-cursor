# Alcance y enrutamiento

Cargar cuando haga falta decidir si una solicitud pertenece a
`manage-azure-resources` o a otro dominio del proyecto.

## Este dominio administra

Plano de control de Azure Resource Manager: tenants, suscripciones y
Resource Groups (según los permisos reales del usuario); Resource
Providers; VNets/subnets/NSG/route tables/public IPs/load balancers/
Private Endpoints/Private DNS; VMs/VMSS/discos/snapshots/NICs; App
Service/Functions/Container Apps; Azure Container Registry; Storage
Accounts (plano de control — crear/configurar, nunca leer blobs/tablas de
datos); Key Vault/Managed Identities/configuración de acceso (sin exponer
secretos); Azure SQL/SQL MI **únicamente en el plano de infraestructura**
(servidor, base vacía, firewall, redes, backup — nunca datos ni queries);
Azure Monitor/Log Analytics/alertas/diagnostic settings; tags, locks,
Azure Policy, RBAC y gobernanza; Cost Management/cuotas/uso/capacidad en
modo lectura; AKS **como recurso de Azure** (el clúster en sí y sus node
pools, cuando la solicitud es de infraestructura); cualquier otro Resource
Provider vía `az resource`/ARM REST controlado.

## El caso AKS — el único límite realmente ambiguo

Un clúster AKS es simultáneamente un recurso de Azure (facturación,
node pools, versión, redes, identidad) y un sistema Kubernetes con sus
propios objetos internos (pods, Deployments, Services, Helm releases).

- **"Crear el clúster", "agregar/redimensionar un node pool", "actualizar
  la versión de Kubernetes del clúster", "cambiar la red/identidad/RBAC de
  Azure del clúster", "az aks show/list/start/stop"** → este dominio
  (`manage-azure-resources`), vía `az aks ...` o ARM REST sobre
  `Microsoft.ContainerService/managedClusters`.
- **"Desplegar/escalar/reiniciar un Deployment", "ver logs de un pod",
  "instalar un Helm chart", "kubectl apply/get/exec", "el pod está en
  CrashLoopBackOff"** → `manage-aks-clusters` (usa kubectl/Helm/el MCP
  `aks`, tiene su propio kubeconfig y contexto).

Si la solicitud mezcla ambos (ej. "crear un node pool nuevo y desplegar mi
app en él"), dividir en dos tareas y usar el dominio correspondiente para
cada una — nunca un script de este dominio ejecuta `kubectl`, ni un script
de `manage-aks-clusters` ejecuta `az aks create/update/delete/upgrade`.

## Permanecen separados (nunca se mezclan con este dominio)

- **Azure DevOps** (pipelines, Builds, Releases, Variable Groups, grupos
  de seguridad, permisos Git, Branch Policies) — `manage-azure-devops-
  pipelines` / `manage-azure-devops-permissions`. Azure DevOps es un
  producto distinto de Azure Resource Manager, aunque comparta el mismo
  tenant de Azure AD para autenticación.
- **Objetos internos de Kubernetes/Helm** dentro de un clúster AKS ya
  existente — `manage-aks-clusters` (ver arriba).
- **Datos dentro de cualquier base SQL** (Azure SQL incluida) — siempre
  solo lectura, cualquier dominio, regla global de `CLAUDE.md`. Este
  dominio nunca ejecuta una query de datos ni siquiera de lectura contra
  una base Azure SQL — eso, si hiciera falta, es Schema Sync u otra
  herramienta con permiso explícito de solo lectura.
- **n8n** (monitoreo SQL, MAIA) — `manage-n8n-monitoring`, aunque la
  instancia de n8n corra sobre infraestructura Azure/VM/AKS que este
  dominio podría en teoría inventariar como recurso.
- **Los servidores Linux del catálogo `docs/servers/servers.json`** (ej.
  `172.16.2.60`, `172.16.2.43`, `10.1.0.200`, `172.16.2.31`, `openedx`) —
  `manage-linux-servers`, aunque alguno sea una VM que podría vivir en
  Azure; el acceso a esas VMs puntuales es siempre vía SSH directo, nunca
  vía Azure Resource Manager.

## Señal para decidir cuándo la solicitud es ambigua

1. Vocabulario del dominio: "Resource Group", "suscripción", "VNet",
   "Storage Account", "Key Vault", "az cli", "ARM template", "Bicep" →
   este dominio. "kubectl", "pod", "Helm chart", "namespace" → AKS.
   "pipeline", "Build", "Release", "Variable Group" → Azure DevOps
   Pipelines. "grupo de seguridad", "permisos Git", "Branch Policy" →
   Azure DevOps Permissions.
2. Recurso o ID ya conocido en un inventario existente de uno de los
   dominios.
3. Instrucción explícita del usuario, si la da.

Si sigue sin quedar claro, preguntar explícitamente antes de ejecutar
cualquier operación — nunca asumir ni probar un dominio y luego otro.
