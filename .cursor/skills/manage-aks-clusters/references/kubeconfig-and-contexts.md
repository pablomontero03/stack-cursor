# Kubeconfig y contextos

## Resolución (orden exacto)

1. `$env:KUBECONFIG` — en Windows puede traer varias rutas separadas por
   `;`. Se resuelven todas (implementado en
   `scripts/Aks-Common.ps1#Get-AksResolvedKubeconfigPaths`).
2. Si no existe o está vacío, fallback a
   `$env:USERPROFILE\.kube\config`.

El uso interno del kubeconfig ya resuelto para autenticarse y conectar
contra un clúster ya configurado **no requiere aprobación** — ver
`.cursor/rules/aks.mdc` (sección Seguridad) para la justificación
completa de por qué esto difiere de la conexión SSH a `172.16.2.60`.

## Comandos sanitizados para inventario (sin aprobación)

- `kubectl config get-contexts`
- `kubectl config current-context`
- `kubectl config view --minify` (nunca `--raw`)

## Comandos que requieren aprobación

- `kubectl config view --raw` — expone tokens/certificados.
- `kubectl config use-context|set-context|set-cluster|set-credentials|
  delete-context` — modifican configuración local.
- `kubelogin convert-kubeconfig` — modifica configuración local (formato
  de auth exec-plugin para Azure AD).
- `az aks get-credentials` — modifica el kubeconfig local (agrega/actualiza
  una entrada de contexto).

## Reglas de seguridad

- Nunca copiar un kubeconfig (ni un fragmento con `client-certificate-data`,
  `client-key-data` o `token`) al repositorio, a `cluster\`, a `docs\`, a
  memoria de agentes ni a `.local\aks\`.
- Nunca imprimir tokens, claves privadas, certificados cliente ni el
  resultado de `kubectl config view --raw`.
- Solo usar kubeconfigs de fuentes confiables (los ya configurados por el
  usuario en su máquina) — nunca aceptar uno recibido por chat, archivo
  adjunto o URL externa.

## Clústeres reales conocidos (confirmado 2026-08-26)

**Corrección importante:** una verificación anterior de esta implementación
había registrado por error `gmon-innovacion-aks-eastus2-0001` (contexto
`az`/kubectl por defecto de esta máquina, en la suscripción "Hospital
Metropolitano") como si fuera un clúster real de este proyecto — **no lo
es**. El usuario corrigió esto: los clústeres reales viven en 3
kubeconfigs exportados por **Lens**, no en `$env:USERPROFILE\.kube\config`
(que apunta a un clúster ajeno sin relación con este proyecto). `az`
CLI/`kubectl` por defecto en esta máquina no deben usarse como fuente de
verdad para "cuál es el clúster actual" de este dominio.

| Kubeconfig (`$env:APPDATA\Lens\kubeconfigs\...`) | Rol | Contextos reales confirmados |
|---|---|---|
| `2d2709fd-80b8-4086-808a-717488711436-pasted-kubeconfig.yaml` | Desarrollo | `default` (único contexto) — clúster **k3s** de un solo nodo (`srv-desarrollo-5`, no AKS), IP interna `172.16.2.x` |
| `8cd569be-c5c7-4ab7-b1b3-698430ba90c8` | Producción (+ dev/qa, merge más amplio) | `gmon-dev-aks-eastus2-0001` (actual), `gmon-prod-aks-eastus2-0001/2/3`, `gmon-qa-aks-eastus2-0001/2`, `docker-desktop`, más entradas legadas `aks_gmon_dev_eastus2_0001/0002`/`aks_gmon_prod_eastus2_0001/0002` |
| `f0aef227-affb-4a6a-9c16-f11c80566d66-pasted-kubeconfig.yaml` | Producción (foco en 0004, incluye admin) | `gmon-dev-aks-eastus2-0001`, `gmon-prod-aks-eastus2-0001/2/3`, `gmon-prod-aks-eastus2-0004` (actual) y `gmon-prod-aks-eastus2-0004-admin` (`clusterAdmin`, no solo `clusterUser`) |

Notas:

- `gmon-prod-aks-eastus2-0004` coincide con el clúster ya usado en los
  pipelines de Azure DevOps de Administración de Proyectos y Buklo
  (`AksClusterName 'gmon-prod-aks-eastus2-0004'`,
  `AksResourceGroup 'gmon_prod_rg_eastus2_0001'`) — consistente con
  infraestructura ya conocida del proyecto, no un dato nuevo aislado.
- El contexto `gmon-dev-aks-eastus2-0001` y los contextos
  `gmon-prod-aks-eastus2-0001/2/3` aparecen **en los dos archivos** (2 y
  3) — el mismo nombre de contexto no identifica un clúster de forma
  única entre archivos. Por eso el esquema del plan y del inventario
  (`New-AksChangePlan.ps1`/`Get-AksInventory.ps1`) guardan también
  `kubeconfigPath`, y `Test-AksChangePlan.ps1` bloquea si el inventario y
  el plan declaran contexto igual pero kubeconfig distinto.
- **Siempre pasar `-KubeconfigPath` explícito** con la ruta completa del
  archivo correspondiente al invocar cualquier script de este dominio
  (`Get-AksInventory.ps1`, `Invoke-AksRead.ps1`, `New-AksChangePlan.ps1`,
  `Apply-AksChangePlan.ps1`, `Test-AksPostChange.ps1`) — la resolución
  ambiente (`$env:KUBECONFIG` → default) **no** apunta a ninguno de estos
  3 archivos en esta máquina.
- Estos 3 archivos pueden dejar de existir o renombrarse si el usuario
  reconfigura Lens — nunca asumirlos vigentes sin confirmar con
  `Test-Path` (o el propio `Test-AksEnvironment.ps1`, que ya los reporta)
  antes de una operación real.

## Múltiples contextos

Antes de cualquier operación, confirmar el contexto real con
`kubectl config current-context` — nunca asumir cuál es el clúster
"activo" a partir de una conversación anterior o de un plan viejo. Si hay
más de un contexto configurado y el usuario no especificó cuál usar,
preguntar antes de ejecutar cualquier cosa que no sea puramente informativa
(`get-contexts` sí se puede correr sin preguntar, para poder mostrar las
opciones).

`Apply-AksChangePlan.ps1` reconfirma el contexto actual contra
`plan.cluster.context` antes de aplicar — si cambió desde que se generó el
plan, la aplicación se rechaza automáticamente (ver
`change-workflow.md`).

## Acceso a `gmon-prod-aks-eastus2-0001` (NSG)

El API privado del 0001 (`10.4.0.10:443`) está cerrado por defecto con la
regla NSG `PRODAKS1_Rule` en
`gmon-hub-ComputeSubnet-nsg-eastus2-0001` / rg `gmon_hub_rg_eastus2_0001`
(`Deny`). Un timeout a ese API es casi siempre la NSG en Deny, no un fallo
de auth. El 0004 no usa esta regla.

Ciclo obligatorio (pedir aprobación antes de Allow; cerrar siempre):

```bash
# Abrir
az account show
az network nsg rule update --name PRODAKS1_Rule --nsg-name gmon-hub-ComputeSubnet-nsg-eastus2-0001 --resource-group gmon_hub_rg_eastus2_0001 --access Allow

# ... kubectl --context gmon-prod-aks-eastus2-0001 ...

# Cerrar
az account show
az network nsg rule update --name PRODAKS1_Rule --nsg-name gmon-hub-ComputeSubnet-nsg-eastus2-0001 --resource-group gmon_hub_rg_eastus2_0001 --access Deny
```

Nunca dejar la regla en `Allow`. Detalle completo en `.cursor/rules/aks.mdc`
§ Acceso al AKS 0001.
