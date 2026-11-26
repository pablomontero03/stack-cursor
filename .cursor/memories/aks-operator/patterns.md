# Patterns — aks-operator

## Clústeres reales de este proyecto viven en kubeconfigs de Lens, no en el default

Confirmado 2026-08-26. `$env:USERPROFILE\.kube\config` (resolución
ambiente por defecto de `kubectl`/`az` en esta máquina) apunta a un
clúster **ajeno** a este proyecto (`gmon-innovacion-aks-eastus2-0001`,
suscripción "Hospital Metropolitano") — el usuario dio ese nombre por
error en la implementación inicial y lo corrigió después.

Los clústeres reales:

| Kubeconfig | Rol | Contextos |
|---|---|---|
| `$env:APPDATA\Lens\kubeconfigs\2d2709fd-80b8-4086-808a-717488711436-pasted-kubeconfig.yaml` | Desarrollo | `default` — clúster k3s de un solo nodo (`srv-desarrollo-5`, no AKS) |
| `$env:APPDATA\Lens\kubeconfigs\8cd569be-c5c7-4ab7-b1b3-698430ba90c8` | Prod (+ dev/qa) | `gmon-dev-aks-eastus2-0001`, `gmon-prod-aks-eastus2-0001/2/3`, `gmon-qa-aks-eastus2-0001/2`, más entradas legadas |
| `$env:APPDATA\Lens\kubeconfigs\f0aef227-affb-4a6a-9c16-f11c80566d66-pasted-kubeconfig.yaml` | Prod (foco 0004) | `gmon-dev-aks-eastus2-0001`, `gmon-prod-aks-eastus2-0001/2/3/4`, `gmon-prod-aks-eastus2-0004-admin` |

`gmon-prod-aks-eastus2-0004` coincide con el clúster ya usado en los
pipelines ADO de Administración de Proyectos/Buklo — dato consistente,
no aislado.

**How to apply:** siempre pasar `-KubeconfigPath` explícito (ruta
completa) a `Get-AksInventory.ps1`/`Invoke-AksRead.ps1`/
`New-AksChangePlan.ps1`/`Apply-AksChangePlan.ps1`/`Test-AksPostChange.ps1`
— nunca asumir la resolución ambiente. `Test-AksEnvironment.ps1` ya
reporta existencia + contextos de estos 3 archivos por default (parámetro
`-KnownKubeconfigPaths`, sobreescribible si el usuario reconfigura Lens).
El mismo nombre de contexto aparece en más de un archivo (`gmon-dev-
aks-eastus2-0001` y `gmon-prod-aks-eastus2-0001/2/3` están en los 2
archivos "prod") — el contexto solo no identifica el clúster de forma
única, por eso el plan y el inventario también guardan `kubeconfigPath` y
`Test-AksChangePlan.ps1` los cruza.

## `-KubeconfigPath` no existía en la v1 original — bug real corregido

La primera versión de los scripts (`New-AksChangePlan.ps1`,
`Apply-AksChangePlan.ps1`, etc.) solo pasaba `--context` a kubectl,
asumiendo que la resolución ambiente ya tenía todo — no funcionaba contra
ningún clúster real de este proyecto. Se agregó `-KubeconfigPath` de
punta a punta (`Aks-Common.ps1#Get-AksKubectlConnectionArgs`, campo
`cluster.kubeconfigPath` en plan e inventario, chequeo cruzado en
`Test-AksChangePlan.ps1`). Verificado con un test que confirma la
invocación REAL de `kubectl config current-context --kubeconfig <ruta>`
(no solo que el parámetro se acepta).

## Regla crítica: no procesar JSON grande inline en shell
**Causa de crashes del gateway confirmada en producción (2026-09-21).**

Procesar JSON de más de ~50KB directamente en el tool de shell (heredoc Python inline, `curl | python3`, `python3 -c "..."` con JSON grande) bloquea el ACP y tumba el gateway.

**Patrón correcto obligatorio:**
1. Descargar/guardar el JSON a un archivo en disco: `curl ... -o /tmp/data.json`
2. Procesar con un script `.py` separado que lee del archivo
3. Guardar el resumen en `/tmp/output.txt`
4. Leer y mostrar solo el `.txt` (que es corto)
5. Limpiar temporales: `rm -f /tmp/data.json /tmp/output.txt`

**Nunca:**
- Python inline con JSON de cientos de KB en el mismo comando
- `curl ... | python3 -c '...'` con respuesta grande
- Heredoc con JSON inline de cientos de líneas
- Usar `/tmp` directamente en bash sin verificar que existe

**Aplica a:** inventarios ADO, manifests Kubernetes, respuestas de API con listas largas, archivos de configuración grandes.

## Regla: no ejecutar setup.sh de Kiro
**Causa de crashes del gateway confirmada en producción (2026-09-21).**

No ejecutar `setup-kiro.sh` ni `source ./setup.sh`. Las variables se cargan con `set -a; source env/.env; set +a`. `./setup-cursor.sh` no reinicia el worker.

**Siempre usar `--no-restart` cuando se ejecuta desde una sesión activa de Crew:**
```bash
set -a; source env/.env; set +a
```

**Cuándo SÍ reiniciar (sin --no-restart):**
- Primera instalación en una máquina nueva
- Cuando el operador lo pide explícitamente
- Cuando se agregan nuevos agentes o skills que requieren recarga

**Cuándo NO reiniciar (usar --no-restart):**
- Cualquier vez que el agente ejecuta setup.sh para cargar variables de entorno
- Al inicio de scripts que solo necesitan `$REPO_ROOT`, `$AZURE_DEVOPS_PAT`, etc.
