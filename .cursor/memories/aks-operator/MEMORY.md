# Memoria — aks-operator

## Propósito

Responsable de inventario, planificación y ejecución aprobada de cambios
sobre clústeres AKS (kubectl/Helm/Azure CLI/MCP `aks`). Nunca ejecuta una
escritura real sin una aprobación explícita del usuario para esa operación
puntual o para el lote atómico de un plan aprobado.

## Alcance de esta memoria

Aprendizajes reutilizables sobre: comportamiento real de
`New-AksChangePlan.ps1` / `Apply-AksChangePlan.ps1` / `Invoke-AksRead.ps1`,
particularidades de clústeres/contextos reales con los que se trabajó,
convenciones de namespaces y nombres de recursos por producto/ambiente, y
errores frecuentes al planificar cambios.

- [debugging.md](debugging.md) — diagnósticos y causas raíz confirmadas al
  planificar o aplicar cambios.
- [patterns.md](patterns.md) — convenciones y decisiones técnicas
  confirmadas del dominio AKS.

## Aprendizajes esenciales

- El clúster k3s dev de un solo nodo (`srv-desarrollo-5`) tiene un límite
  de 110 pods por nodo (default de kubelet) — un rollout nuevo en
  cualquier namespace/app puede quedar atascado en `Pending` por
  "Too many pods" si el clúster ya está cerca de ese tope, sin relación
  con CPU/memoria/imagen/probes. Ver `debugging.md` para el caso real
  (`directory-web`, namespace `uat`, 2026-09-07).

Ver `.cursor/rules/aks.mdc`
para las reglas vigentes (no se duplican aquí).

Última revisión: 2026-09-07 (primer hallazgo real de diagnóstico).

## Auto-corrección en ciclos de pipeline (2026-09-11)

Si durante un ciclo de despliegue un recurso k8s (Ingress, Deployment, Service, Secret, etc.) fue creado por el plan actual y está causando conflicto en un re-deploy del mismo ciclo:
- El agente puede eliminarlo y re-aplicar **sin pedir aprobación** al usuario.
- Es corrección del propio plan, no eliminación destructiva de un recurso externo.
- Guardar nombres de recursos creados durante el ciclo para poder corregirlos.
- **Nunca pedir al usuario que elimine algo que el agente creó en ese mismo ciclo.**

Ejemplo: Ingress con host duplicado por re-deploy → `kubectl delete ingress <nombre> -n <namespace>` y re-apply.

## Lección 2026-09-21 — no ejecutar setup.sh de Kiro

Causa raíz confirmada de las "caídas del gateway" al correr scripts que cargan
variables: NO era el `curl`/comando en sí — era `source ./setup.sh`, que corre
En Cursor no hay reinicio de Kiro Crew. El comando completa
(exit 0) y el restart tumba la sesión acto seguido.

**Vía correcta en sesión activa** — cargar el `.env` directo:
```bash
source /home/cursor/stack-cursor/env/.env
export REPO_ROOT=/home/cursor/stack-cursor
```
No ejecutar `source ./setup.sh`. Para variables: `set -a; source env/.env; set +a`.
Para kubectl no hace falta el PAT; el kubeconfig ya está en `~/.kube/config`.

## Lección 2026-09-23 — AKS 0001 detrás de NSG cerrada (ciclo Allow→consulta→Deny)

El API server privado de `gmon-prod-aks-eastus2-0001` (`10.4.0.10:443`) está
bloqueado por defecto por la regla NSG **`PRODAKS1_Rule`** (nsg
`gmon-hub-ComputeSubnet-nsg-eastus2-0001`, rg `gmon_hub_rg_eastus2_0001`,
Outbound `10.1.0.200 → 10.4.0.10:443`, prio 1100), en **`Deny`**. Este host
sale con `src 10.1.0.200` (misma identidad de red del agente ADO), así que
el timeout `dial tcp 10.4.0.10:443: i/o timeout` es la NSG en Deny, **NO**
auth ni `az login`. El 0004 no pasa por esta regla y conecta directo.

Ciclo OBLIGATORIO (igual que el Release def 273 / env 279; requiere aprobación
por ser cambio en NSG de prod):
1. `az network nsg rule update --name PRODAKS1_Rule --nsg-name gmon-hub-ComputeSubnet-nsg-eastus2-0001 --resource-group gmon_hub_rg_eastus2_0001 --access Allow`
2. esperar ~25-30s la propagación → `kubectl --context gmon-prod-aks-eastus2-0001 ...`
3. `az network nsg rule update ... --access Deny` (restaurar el estado seguro).

**Nunca dejar `PRODAKS1_Rule` en Allow sin cerrar.** Consulta puntual → Deny
inmediato. Conexión larga → preguntar al usuario "¿cierro la NSG?" antes de
terminar. Validado en vivo 2026-09-23: 0001 = k8s v1.32.11 tras abrir; regla
restaurada a Deny.

## Lección 2026-09-23 — Puesta en marcha del MCP aks desde clone fresco

En una implementación nueva de Kiro Crew el MCP `aks` no arranca por dos causas
independientes de la conectividad al cluster:

1. **cilium/hubble faltantes:** el binario `aks-mcp` aborta con `Validation failed:
   cilium/hubble is not installed` y sale con 0 herramientas (esos binarios no vienen
   en el clone; los instala `setup.sh`, no van versionados). Fix: en
   `.cursor/mcp.json` agregar a los args del server `aks`
   `--enabled-components az_cli,monitor,fleet,network,compute,detectors,advisor,
   inspektorgadget,kubectl,helm` (excluye cilium/hubble). Requiere reiniciar el worker gmon-hub.
2. **Auth Azure:** el `~/.azure` del gateway está aislado del del usuario SSH → NO
   sirve `az login` interactivo. Usar Service Principal en `env/.env`
   (AZURE_CLIENT_ID/SECRET/TENANT_ID/SUBSCRIPTION_ID) e incluir esas 4 vars en el
   bloque `env` del server aks de `mcp.json`. Si el MCP autentica con una managed
   identity del host (client id distinto al SP), darle `Reader`/`Contributor` y
   reiniciar; el RBAC tarda 5-15 min en propagar y el token cacheado es previo.

Runbook completo: `docs/IMPLEMENTACION-CREW-KIRO.md`. Validado 2026-09-23 leyendo el
VNet del 0004 sin 403.
