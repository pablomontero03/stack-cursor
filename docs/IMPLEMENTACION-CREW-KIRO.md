# Implementación de Kiro Crew desde cero — Runbook de puesta en marcha

> Guía práctica para levantar el stack `automation-kiro` en una máquina nueva
> (o tras un **clone fresco** desde GitHub). Consolida los problemas reales
> encontrados el 2026-09-23 al re-implementar el stack, con su causa y su fix.
> Complementa `docs/ONBOARDING.md` (operación diaria); este doc es sobre el
> **arranque técnico** y sus gotchas.

---

## Orden recomendado de arranque

1. **Clonar el repo** y entrar a la raíz.
2. **Recrear `env/.env`** desde tu fuente de verdad (NO desde `.env.example` a secas —
   el example no trae valores). Ver sección "Secretos y `.env`".
3. **Corregir permisos** de las claves privadas (`env/*.pem` → `chmod 600`).
4. **Autenticar Azure con Service Principal** (ver "Azure / Service Principal").
5. **Ajustar `mcp.json`** para el MCP `aks` (ver "MCP aks").
6. `./setup-cursor.sh` en una instalación nueva. No existe `setup.sh` ni `--no-restart`.
7. **Validar conectividad** end-to-end (ver "Checklist de validación").

---

## Secretos y `.env`

- El `env/.env` **NO se versiona** (está en `.gitignore`). Un clone fresco llega
  **sin él** — solo con `env/.env.example`. Hay que recrearlo desde el backup del
  operador o desde los archivos sueltos de `env/` (`claves linux.txt`,
  `conexiones sql.txt`, etc.).
- **Comillas simples obligatorias** para valores con `$`, `+` u otros caracteres
  especiales. Sin comillas, `source env/.env` expande `$0`, `$1`, etc. y el valor
  sale corrupto. Ejemplo real: `N8N_SRV_PASS='M1s$0224+'` (sin comillas, `$0224`
  se expandía y el password quedaba mal → SSH rechazado).
- Al recrear el `.env`, **verificar cada credencial con una conexión real**, no
  asumir que el valor es correcto por estar presente.
- Restaurar permisos: `chmod 600 env/.env` y `chmod 600 env/*.pem`.

---

## Azure / Service Principal (crítico)

**El `az login` interactivo NO sirve para el agente.** El proceso del gateway corre
en un entorno con su **propio `/home/adoadmin/.azure` aislado** del `~/.azure` del
usuario SSH — aunque el hostname coincida. Un `az login --use-device-code` hecho en
la terminal del usuario deja el token en un `~/.azure` que el agente **no ve**, así
que el agente sigue reportando `Please run az login`.

**Solución correcta: Service Principal en `env/.env`.**

```
AZURE_CLIENT_ID=<appId del SP>
AZURE_CLIENT_SECRET=<secret>
AZURE_TENANT_ID=33dd4184-3068-47da-891d-a70e02f8c0c9
AZURE_SUBSCRIPTION_ID=69dc43ec-5f24-4203-9239-a8d0f8506d44
```

Crear el SP (desde una terminal con sesión az de usuario):
```bash
az ad sp create-for-rbac --name "kiro-crew-agent" \
  --role Reader \
  --scopes /subscriptions/69dc43ec-5f24-4203-9239-a8d0f8506d44
```

- `Reader` basta para lecturas (ARM, FinOps, MCP aks lee clusters).
- Para el **ciclo NSG del AKS 0001** (abrir/cerrar `PRODAKS1_Rule`) el SP necesita
  `Network Contributor` (o `Contributor`) en el RG `gmon_hub_rg_eastus2_0001`.
- El MCP aks puede autenticar con una **managed identity del host** en vez del SP
  del `.env` (usa `DefaultAzureCredential`). Si sus lecturas dan 403 con un client
  id distinto al del SP, hay que dar el rol a ESA identidad (la que aparece en el
  error `client '<appId>' with object id '<oid>'`).
- **RBAC tarda en propagar** (5-15 min) y el token cacheado del proceso es previo a
  la asignación → tras dar un rol, reiniciar el worker gmon-hub para tomar el token nuevo.

`./setup-cursor.sh` paso **[8/8]** hace `az login` automáticamente al
cargar el `.env`, así que la sesión Azure queda lista en cada arranque sin
intervención.

---

## MCP aks — no arranca por cilium/hubble

Síntoma: en `/mcp` el server `aks` sale **`failed` con 0 herramientas**.

Causa: el binario `aks-mcp` aborta al inicio con:
```
Validation failed:
cilium is not installed or not found in PATH (required when --enabled-components includes cilium)
hubble is not installed or not found in PATH (required when --enabled-components includes hubble)
```
Los binarios `cilium` y `hubble` **no vienen en el clone** (los instala `setup.sh`,
no van versionados). Con los componentes cilium/hubble habilitados por defecto, el
MCP no levanta.

**No es un problema de Azure ni de sesión az.**

Fix aplicado (en `.cursor/mcp.json`, server `aks`, campo `args`):
```json
"--enabled-components",
"az_cli,monitor,fleet,network,compute,detectors,advisor,inspektorgadget,kubectl,helm"
```
Esto excluye `cilium` y `hubble`. Requiere reiniciar el worker gmon-hub. Alternativa: instalar
`cilium` + `hubble` en `~/.local/bin`.

Además, para que el `az` interno del MCP autentique con el SP del `.env`, el bloque
`env` del server `aks` en `mcp.json` debe incluir `AZURE_CLIENT_ID`,
`AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`.

**Diagnóstico del arranque real:** el probe one-shot por pipe cierra el stdin antes
del `tools/list`; para ver el error real capturar el handshake stdio a archivo con
un `sleep` entre `initialize` y `tools/list`.

---

## AKS 0001 — NSG cerrada por defecto

El API server privado de `gmon-prod-aks-eastus2-0001` (`10.4.0.10:443`) está tras la
regla NSG **`PRODAKS1_Rule`** (nsg `gmon-hub-ComputeSubnet-nsg-eastus2-0001`, rg
`gmon_hub_rg_eastus2_0001`, Outbound `10.1.0.200 → 10.4.0.10:443`, prio 1100), en
**`Deny` por defecto**. Un `dial tcp 10.4.0.10:443: i/o timeout` es la NSG en Deny,
NO auth. Ciclo obligatorio: `--access Allow` → esperar ~25-30s → `kubectl` → `--access
Deny`. Ver `.cursor/rules/aks.mdc` sección "Acceso al AKS 0001". El 0004 no pasa por
esta regla. Requiere que el SP/identidad tenga permiso de escritura en esa NSG.

---

## Setup en Cursor

`setup-kiro.sh` reiniciaba Kiro Crew y mataba el gateway. En Cursor no se ejecuta. `./setup-cursor.sh` no reinicia el worker
activo**. Dentro de una sesión de Crew:
- Vía preferida: `source env/.env` directo (no reinicia nada).
- Si se necesitan variables: `set -a; source env/.env; set +a`.
- No ejecutar `source ./setup.sh`.

---

## Guards de KiroCrew que dan falso positivo (esperados)

Al validar conectividad, estos guards bloquean por la FORMA del comando (no hay
exfiltración real). Usar la alternativa, nunca reescribir para esquivar:
- `/dev/tcp/...` → usar la conexión real (SSH/curl) o `curl -sk`.
- `nc ... <redirect` → quitar el `nc`, usar `curl -sk`.
- Acceso a IMDS `169.254.169.254` → bloqueado; diagnosticar por otra vía.
- SSH sin `sshpass` (no está en el sandbox, sudo deshabilitado): usar helper
  `SSH_ASKPASS` + `setsid` que entrega el password desde una env var.

---

## Checklist de validación (end-to-end)

Tras el arranque, confirmar cada pieza con una lectura/conexión real:

| Componente | Cómo validar |
|---|---|
| **Servidores Linux** (SSH) | `hostname; uptime` vía SSH con credenciales del `.env` |
| **Servidor Windows** (WinRM) | `pywinrm` (instalar `--user`) → `hostname` sobre :5985 NTLM |
| **OpenEdX** | SSH con `env/keyopenedx.pem` (chmod 600 antes) |
| **MCP azure-devops / aks / n8n-interno / n8n-productivo / cloudflare** | una lectura real de cada uno |
| **MCP aks** | una operación read-only (ej. `aks_network_resources`) que devuelva datos sin 403 |
| **Clusters k3s** (.31, .43) | `kubectl --context <ctx> get --raw /version` |
| **AKS 0004** | igual, directo |
| **AKS 0001** | igual, tras abrir la NSG (ciclo Allow→Deny) |
| **Azure ARM / FinOps** | `az account show` (SP) + `az group list` |
| **Cloudflare** | REST `/user/tokens/verify` + `/zones` con `CLOUDFLARE_API_TOKEN` |
| **SQL DEV/UAT** (read-only) | `pymssql` (instalar `--user`), solo `SELECT` de metadatos |

Herramientas que faltan en el sandbox y se instalan con pip `--user`: `pywinrm`
(Windows/WinRM), `pymssql` (SQL read-only).

---

## Resumen de causas raíz de esta implementación (2026-09-23)

| Problema | Causa | Fix |
|---|---|---|
| `.60` SSH rechazado | password del `.env` desactualizado + sin comillas simples (`$0` expandido) | actualizar valor entre comillas simples |
| OpenEdX SSH rechazado | PEM en `0664` | `chmod 600 env/keyopenedx.pem` |
| Azure `Please run az login` | `~/.azure` del agente aislado del del usuario | Service Principal en `env/.env` |
| MCP aks `failed`/0 tools | falta cilium/hubble en PATH | `--enabled-components` sin cilium/hubble en `mcp.json` |
| MCP aks 403 al leer clusters | managed identity del host sin rol | dar `Reader`/`Contributor` a esa identidad + reiniciar el worker gmon-hub |
| AKS 0001 timeout | NSG `PRODAKS1_Rule` en Deny | ciclo Allow→consulta→Deny |

---

## Control de navegador remoto (panel Browser + saved state) — 2026-09-25

Cómo dejar operativo el navegador de Kiro cuando el gateway corre en el server
(headless) y el usuario accede desde su PC. Sirve para revisar sitios que exigen
login (ej. **App Store Connect**, **Google Play Console**) reutilizando una sesión
que el usuario abre una sola vez.

### Arquitectura y la brecha PC↔servidor

- El agente y `playwright-cli` corren en el **server** (headless); el Chrome del
  usuario vive en **su PC**. Por eso NO funcionan: el `attach --extension` a su
  Chrome (máquinas distintas), ni pilotar portales con anti-embedding (Azure manda
  `X-Frame-Options`/CSP y bloquea el iframe).
- Lo que SÍ funciona: **saved state** (skill `browser-auth`). El usuario se loguea
  una vez en el navegador del server (vía el panel), y el estado se guarda para
  reutilizarlo sin re-login.

### Fix 1 — `playwright-cli` en ruta CONFIABLE (0.7.1 endureció la seguridad)

0.7.x **rechaza** un `playwright-cli` que:
1. viva bajo `~/.local` (user-local, modificable sin privilegios), o
2. cuyo árbol de paquete sea **escribible por el usuario del gateway**.

Síntoma en el panel: `playwright-cli is not installed` aunque el binario exista.
En el log: `SECURITY: refusing playwright-cli candidate ...` /
`the executable hierarchy is writable by the gateway user at /usr/lib/node_modules`.

Fix (requiere sudo, se corre por SSH):
```bash
sudo npm install -g @playwright/cli@latest          # deja binario en /usr/bin
sudo chown root:root /usr/lib/node_modules          # que el user del gateway NO pueda reescribir el árbol
```
El `npm config get prefix` global suele ser `~/.local`; por eso un `install -g` a
secas puede caer en la ruta rechazada. Verificar `ls -la /usr/bin/playwright-cli`.

### Fix 2 — Panel Browser visible desde el PC (puerto loopback + túnel SSH)

El panel sirve su vista en un **loopback del server** que el PC no alcanza
(`No se puede acceder a la vista del navegador... dirección de bucle local`).

1. En Cursor no hay dashboard de Kiro ni puerto 35509. El estado del navegador está en `/home/cursor/stack-cursor/.local/pw-work` y `.local/browser-state/`.
2. Si hace falta un túnel SSH al host, el usuario es `adoadmin@10.1.0.200`.
   Permanente en `~/.ssh/config`: `LocalForward 35509 127.0.0.1:35509`.
   > Este host sale con `src 10.1.0.200` (misma identidad que el agente ADO).

### Fix 3 — scratch efímero mata el daemon de playwright

`/tmp` (`runtime-XXXX`) es **efímero** y puede desaparecer; entonces
`playwright-cli open` muere con `ENOENT ... mkdtemp .../scratch/runtime-.../playwright-artifacts`.
Fix: usar un directorio estable para el `TMPDIR` de playwright, NO el scratch:
```bash
STABLE=/home/cursor/stack-cursor/.local/pw-work; mkdir -p "$STABLE"
TMPDIR="$STABLE" playwright-cli -s=<slug> open <url>
```

### Flujo saved state (el que da el valor real)

1. Abrir el sitio en una sesión de shell propia: `TMPDIR=$STABLE playwright-cli -s=appstore open https://appstoreconnect.apple.com`.
2. **El usuario se loguea** en el panel (Apple ID + 2FA — es suyo, el agente no interviene).
   OJO: el panel del dashboard y el shell pueden usar **daemons distintos**; el usuario
   debe loguearse en la sesión que el SHELL ve (`playwright-cli list` la muestra), no solo
   en la del panel. Confirmar por URL: `snapshot | grep 'Page URL'` debe estar en `/apps`, no `/login`.
3. Guardar el estado (es una credencial → owner-only):
   ```bash
   TMPDIR=$STABLE playwright-cli -s=appstore state-save /home/cursor/stack-cursor/.local/browser-state/appstoreconnect.json
   chmod 600 /home/cursor/stack-cursor/.local/browser-state/appstoreconnect.json
   ```
   Un archivo de ~3 KB = sesión SIN login (mal); ~50-60 KB = sesión real (bien).
4. Reutilizar sin re-login: `TMPDIR=$STABLE playwright-cli -s=<slug> state-load <archivo>` + `goto`.

### Límites honestos

- **Solo sitios del usuario / con login que él complete.** No da acceso a portales de
  terceros arbitrarios ni pilotea Azure Portal (anti-embedding + MFA).
- **Apple caduca sesiones agresivamente**: cuando el `state-load` caiga en `/login`,
  repetir el flujo (túnel + login del usuario + `state-save`). Es esperado.
- El túnel SSH solo hace falta para que el USUARIO opere el panel; para que el agente
  navegue por shell (`state-load`) NO se necesita el túnel.
- La sesión del panel no es exportable trivialmente desde el shell; loguear en la
  sesión que el shell alcanza es lo que permite el `state-save`.
