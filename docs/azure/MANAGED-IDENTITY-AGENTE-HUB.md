# Managed Identity dedicada del agente — `id-kiro-agent-hub`

**Creada:** 2026-10-06 · **Por:** sesión Kiro (aprobación de Pablo) · **Cuenta ejecutora:** `helpdesk@grupomontecristo.com` (Owner)

## Objetivo

Dar al agente Kiro (corriendo en la VM `gmon-hub-linuxvm-eastus2-0001`) acceso **estable y sin secreto** a Azure, para que no dependa de un `az login` interactivo que se pierde al reiniciar el gateway o al expirar el token. El token de una user-assigned Managed Identity lo emite y renueva Azure automáticamente mientras el proceso corra en esa VM.

Reemplaza el problema de que el cache MSAL de `az` queda cifrado contra el keyring de la sesión interactiva y el proceso del agente no lo puede desencriptar.

## Qué se creó (todo nuevo, nada existente modificado salvo el enlace a la VM)

| Recurso | Valor |
|---|---|
| User-assigned MI | `id-kiro-agent-hub` |
| RG de la MI | `GMON_HUB_RG_EASTUS2_0001` |
| Location | `eastus2` |
| **clientId** | `689b038a-9e4c-490f-99cf-886eb89a4870` |
| **principalId** | `9818f44c-8429-4ba2-970d-ca3c2903bd5c` |
| Subscription | `Hospital Metropolitano` (`69dc43ec-5f24-4203-9239-a8d0f8506d44`) |
| Tenant | `Grupo Montecristo` (`33dd4184-3068-47da-891d-a70e02f8c0c9`) |

### Enlace a la VM
La MI se **agregó** a la VM `gmon-hub-linuxvm-eastus2-0001` junto a su System-assigned identity preexistente (`8d8cd5ca-ef19-467a-ab42-b7291c2dc2bb`), que quedó **intacta**. Tipo resultante de la VM: `SystemAssigned, UserAssigned`. Sin reinicio, sin downtime.

### Role assignments (scope mínimo, 2)
| Rol | Scope |
|---|---|
| `Azure Kubernetes Service Cluster User Role` | AKS `gmon-prod-aks-eastus2-0001` (solo ese cluster) |
| `Network Contributor` | NSG `gmon-hub-ComputeSubnet-nsg-eastus2-0001` (solo esa NSG) |

El primero permite `az aks get-credentials` del 0001 (el RBAC de Kubernetes adentro sigue aplicando). El segundo permite abrir/cerrar la regla `PRODAKS1_Rule` para el ciclo documentado de acceso al API server privado 10.4.0.10:443.

## Cómo lo usa el agente

Variables en `env/.env` (líneas agregadas al final, prefijo propio `KIRO_AZURE_MI_` para no colisionar con las `AZURE_*` del SP preexistente):

```
KIRO_AZURE_MI_CLIENT_ID=689b038a-9e4c-490f-99cf-886eb89a4870
KIRO_AZURE_MI_PRINCIPAL_ID=9818f44c-8429-4ba2-970d-ca3c2903bd5c
KIRO_AZURE_MI_NAME=id-kiro-agent-hub
```

Login sin secreto:
```bash
set -a; source /home/cursor/stack-cursor/env/.env; set +a
az login --identity --client-id "$KIRO_AZURE_MI_CLIENT_ID" -o none
```

> Sintaxis vigente: `--client-id` (la vieja `--username` quedó obsoleta en az CLI recientes).

Ciclo completo de acceso al 0001 (abrir NSG → esperar → kubectl → cerrar), tal como lo ejecuta el agente de forma autónoma:
```bash
az network nsg rule update --name PRODAKS1_Rule \
  --nsg-name gmon-hub-ComputeSubnet-nsg-eastus2-0001 \
  --resource-group gmon_hub_rg_eastus2_0001 --access Allow -o none
sleep 30
az aks get-credentials --name gmon-prod-aks-eastus2-0001 \
  --resource-group gmon_prod_rg_eastus2_0001 --overwrite-existing -o none
kubectl --context gmon-prod-aks-eastus2-0001 get ns
# ... diagnóstico ...
az network nsg rule update --name PRODAKS1_Rule \
  --nsg-name gmon-hub-ComputeSubnet-nsg-eastus2-0001 \
  --resource-group gmon_hub_rg_eastus2_0001 --access Deny -o none
```

**Siempre cerrar la NSG (Deny) al terminar.** Nunca dejar `PRODAKS1_Rule` en Allow.

## Verificación (hecha 2026-10-06, OK)

- `az login --identity --client-id ...` → `az account show` devuelve `userType: servicePrincipal`, `user: userAssignedIdentity`.
- Abrir NSG como la MI → `NSG=Allow`.
- `kubectl --context gmon-prod-aks-eastus2-0001 get ns` → lista namespaces reales del cluster.
- Cerrar NSG → `NSG=Deny`.
- Ejecutado tanto en terminal interactiva como desde el **proceso del agente**: ambos OK.

## Rollback completo

Para deshacer TODO lo creado (dejar el entorno exactamente como estaba antes del 2026-10-06). Ejecutar como una cuenta Owner (ej. `helpdesk@grupomontecristo.com`):

```bash
SUB=69dc43ec-5f24-4203-9239-a8d0f8506d44
VM_RG=GMON_HUB_RG_EASTUS2_0001
VM=gmon-hub-linuxvm-eastus2-0001
MI_PRINCIPAL=9818f44c-8429-4ba2-970d-ca3c2903bd5c
MI_ID="/subscriptions/$SUB/resourcegroups/$VM_RG/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-kiro-agent-hub"
AKS_ID="/subscriptions/$SUB/resourcegroups/gmon_prod_rg_eastus2_0001/providers/Microsoft.ContainerService/managedClusters/gmon-prod-aks-eastus2-0001"
NSG_ID="/subscriptions/$SUB/resourceGroups/gmon_hub_rg_eastus2_0001/providers/Microsoft.Network/networkSecurityGroups/gmon-hub-ComputeSubnet-nsg-eastus2-0001"

# 1) Quitar los 2 role assignments
az role assignment delete --assignee "$MI_PRINCIPAL" --role "Azure Kubernetes Service Cluster User Role" --scope "$AKS_ID"
az role assignment delete --assignee "$MI_PRINCIPAL" --role "Network Contributor" --scope "$NSG_ID"

# 2) Desenlazar la MI de la VM (NO toca la SystemAssigned preexistente 8d8cd5ca...)
az vm identity remove --name "$VM" --resource-group "$VM_RG" --identities "$MI_ID"

# 3) Borrar la MI
az identity delete --ids "$MI_ID"

# 4) Revertir env/.env: quitar las 3 lineas KIRO_AZURE_MI_* y el bloque de comentario
#    (hay respaldo env/.env.bak-mi-<timestamp> creado al agregarlas)
```

**Nota sobre la System-assigned existente:** el paso 2 usa `--identities` apuntando SOLO a la user-assigned, así que `az vm identity remove` quita únicamente esa; la System-assigned (`8d8cd5ca-ef19-467a-ab42-b7291c2dc2bb`) permanece. No borrarla.

## Pendientes / notas

- **Arranque automático:** `./setup-cursor.sh` paso `[8/8]` ya prioriza la Managed Identity (`az login --identity --client-id "$KIRO_AZURE_MI_CLIENT_ID"`) y solo cae al Service Principal (`AZURE_CLIENT_*`) como fallback. Por eso el login sobrevive reinicios del gateway sin intervención.
- Config `az config set core.encrypt_token_cache=false` quedó aplicada en `~/.azure/config` de la VM (fue parte del diagnóstico previo). Es inocua; si se quiere revertir: `az config unset core.encrypt_token_cache`.
- La MI solo funciona DESDE esta VM. Si el agente migra de host, usar el Service Principal (`AZURE_CLIENT_*` ya presente en `env/.env`) o crear una MI en el nuevo host.
