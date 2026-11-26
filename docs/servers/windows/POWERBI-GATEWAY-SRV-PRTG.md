# On-premises data gateway (Power BI) — SRV-PRTG `172.16.2.127`

Fuente de verdad del **On-premises data gateway** de Power BI alojado en
`SRV-PRTG` (`172.16.2.127`). Documento de dominio `windows-servers`.
Complementa `docs/servers/windows/172.16.2.127.md` (inventario del host) —
este archivo cubre específicamente el gateway, su watchdog y los modelos
que dependen de él. **Sin secretos**: solo inventario, diagnóstico y
procedimiento.

| Campo | Valor |
|---|---|
| Host | `SRV-PRTG` (`172.16.2.127`), Windows Server 2022, **4 GB RAM** |
| Cluster Power BI | `powerbi-grupomontecristo` |
| Servicio Windows | `PBIEgwService` (`On-premises data gateway service`), Start=Auto |
| Cuenta del servicio | `NT SERVICE\PBIEgwService` |
| Updater | `OpdgUpdaterService` (Running, Auto) |
| Proceso de datos | `Microsoft.PowerBI.EnterpriseGateway` |
| Contenedor de consultas | `Microsoft.Mashup.Container.NetFX45.exe` (ejecuta Power Query / M) |
| Versión documentada | 3000.298.8 (dic 2025 — Microsoft la marca desactualizada; no actualizada en prod) |
| Tarea ADO (diagnóstico inicial) | [#36083](https://dev.azure.com/Shared-Service-GM/Database-Administration-and-Monitoring/_workitems/edit/36083) bajo US 34710 |
| Convive en el host con | PRTG Probe (`PRTGProbeService` Running; `PRTGCoreService` Stopped) + agente Azure DevOps (`vstsagent.Shared-Service-GM.172.16.2.127-prtg`) |

> La Task 36083 cubre el diagnóstico del 22-sep y el primer watchdog. Los
> fixes posteriores (23-sep, 30-sep, 5-oct) viven **aquí**, no en esa Task.

---

## 1. Causa raíz — por qué se percibe "caído"

El gateway se ve "caído" / "no responde" en Power BI, y el truco operativo
histórico era abrir la app local y hacer **Sign in**. Las causas reales
(logs ODG) son tres, y **ninguna es que el servicio Windows esté detenido**:

1. El servicio Windows **se muere o reinicia** por presión de recursos.
2. Sigue **Running** pero **ahogado**: cientos de `msedgewebview2.exe` del
   Mashup (`Microsoft.Mashup.Container.NetFX45.exe`) bajo `PBIEgwService`
   (~2 GB). El host tiene **solo 4 GB** y PRTG + agente ADO comparten la
   máquina → fuga de WebView2 ahoga la RAM.
3. El **Sign in** de la ventanita es solo la UI de administración. El plano
   de datos usa el **registro local**; no hace falta loguearse para que el
   servicio vuelva **Online**.

**Deuda estructural (no la resuelve el watchdog):** el host necesita
**8–16 GB de RAM** o sacar el gateway de SRV-PRTG. Con 4 GB compartidos
entre PRTG + ADO + gateway, cualquier refresh pesado aprieta la RAM.

---

## 2. Watchdog instalado (automatización)

### Ubicación en el servidor

| Elemento | Ruta |
|---|---|
| Scripts | `C:\ProgramData\GatewayWatchdog\` |
| Log | `C:\ProgramData\GatewayWatchdog\watchdog.log` |
| Stamp último recover | `C:\ProgramData\GatewayWatchdog\last-restart.txt` |
| Copia en mantenimientos | `C:\mantenimientos\powerbi\gateway-watchdog\` |

### Tareas programadas (SYSTEM)

| Tarea | Cadencia | Qué hace |
|---|---|---|
| `PowerBI Gateway Watchdog` | cada **2 min** | recupera si hace falta |
| `PowerBI Gateway Nightly Restart` | **02:15** diario | solo recupera si está enfermo |

Recuperación nativa Windows (`sc failure PBIEgwService`): reinicia a
60 s / 60 s / 120 s si el proceso crashea.

### Lógica de decisión (comportamiento actual, tras fix 5-oct)

El watchdog, cada 2 min, mira servicio + nº de `msedgewebview2` + RAM libre:

1. **Servicio no Running** → recupera **ya** (sin cooldown).
2. **≥ 80 procesos `msedgewebview2`** → recupera (fuga Mashup). Cooldown 20 min.
3. **RAM crítica (< 80 MB) Y WebView2 ≥ 20** → recupera.
4. **RAM baja sola (< 400 MB) sin fuga WebView2** → **NO recupera** (un
   refresh MySQL/Elastic en 4 GB baja la RAM legítimamente; cortarlo genera
   `DM_GWPipeline_Gateway_SpooledOperationMissing`).

**Recuperación = `Stop-Service` → matar huérfanos Mashup/WebView2 → `Start-Service`.**
Nunca `Restart-Service` a secas: **no mata los WebView2** (bug 22-sep).

Nightly 02:15: **no reinicia si está sano** (evita cortar refreshes de
madrugada).

**Scripts versionados:** `docs/servers/windows/powerbi-gateway/Watch-PbiGateway.ps1`
y `docs/servers/windows/powerbi-gateway/Restart-PbiGateway-Nightly.ps1`.
Tras editarlos, copiar a `C:\ProgramData\GatewayWatchdog\` en el server (las
tareas ya apuntan ahí).

---

## 3. Historial de fixes

### 2026-09-22 — Primera automatización
Diagnóstico: RAM ~170–270 MB, 338 WebView2, servicio reiniciándose. Se dejó
`sc failure` + watchdog cada 15 min + nightly 02:15. Recover inicial:
`Restart-Service -Force`, cooldown 30 min.
**Bug:** `Restart-Service` no limpiaba WebView2 (seguían en 338); el cooldown
no corría (`TryParse` del stamp ISO fallaba) → **rebote cada 15 min** toda la
noche → Power BI *unreachable*.

### 2026-09-23 — Stop + kill + start
Recover real: Stop → kill Mashup/WebView2 de `PBIEgwService` → Start. Cooldown
con fecha `yyyy-MM-dd HH:mm:ss`. Corrida limpia: WebView2 **338 → 0**, RAM
~37 MB → ~1 GB. Intervalo **15 min → 2 min**; Stopped no espera cooldown.

### 2026-09-30 — SpooledOperationMissing (02:15)
`DM_GWPipeline_Gateway_SpooledOperationMissing` a las 08:15:33Z = **02:15 CR**.
El nightly cortó un refresh (`Service OnStop`). Nightly cambiado a **skip si
está sano**. Otros fallos del día (gateway Live): credenciales Web Elastic
inválidas; MySQL *Fatal error during data read* / timeout.

### 2026-10-05 — SpooledOperationMissing (08:13)
Error 14:13:53Z = **08:13 CR**. Watchdog: `Recover ... because freeMB=290`
(08:11 RAM 489 MB por refresh pesado). El umbral 400 MB en 4 GB trataba el
refresh como caída. **Fix:** RAM baja sin fuga WebView2 ya **no** reinicia;
recover por RAM solo si RAM crítica (< 80 MB) **y** WebView2 ≥ 20.
Confirmado en vivo ese día: proceso `Microsoft.PowerBI.EnterpriseGateway`
arrancó 08:13 (= el recover), servicio Running, salida a nube OK; crashes del
Mashup Container el 02/10 20:15, 04/10 05:21, 05/10 05:21.

---

## 4. Cómo interpretar errores de Power BI

| Código / síntoma | Qué es | Qué hacer |
|---|---|---|
| Gateway unreachable / no responde | Servicio Stopped o relé cortado | Ver `PBIEgwService` y `watchdog.log` |
| `DM_GWPipeline_Gateway_SpooledOperationMissing` | Refresh a medias cuando se reinició host/servicio | Reintentar **Actualizar ahora**; ver si coincidió con un Recover en el log |
| `DM_GWPipeline_Gateway_InvalidConnectionCredentials` | Elastic/Web/MySQL 401 | Re-autenticar **la fuente en el modelo**, NO Sign in del gateway |
| MySQL *Fatal error during data read* / Timeout | Consulta o BD | Query/timeout MySQL |
| App local pide Sign in pero servicio Running | Solo UI | Si el portal está Online, no hace falta loguearse |

---

## 5. Operación rápida (solo lectura)

```powershell
Get-Service PBIEgwService
Get-Content C:\ProgramData\GatewayWatchdog\watchdog.log -Tail 40
Get-Content C:\ProgramData\GatewayWatchdog\last-restart.txt
```

- Dump oficial de la app: Escritorio de Administrator → `ODGLogs\ODGLogs 02d1ce41 ...`
- Logs del servicio: `C:\Windows\ServiceProfiles\PBIEgwService\AppData\Local\Microsoft\On-premises data gateway\`
- Conexión al host: WinRM NTLM sobre HTTP:5985 desde el sandbox Linux con
  `pywinrm` (pwsh en Linux no trae cliente WSMan). Ver `docs/servers/windows/172.16.2.127.md`.

---

## 6. Modelo dependiente — "reportes maia" (Medismart_WFM)

Workspace `Medismart_WFM` (`b3a89803-6662-4935-85dd-ec6b429f0882`), dataset
`reportes maia` (`9893a0bd-704a-46cf-9f66-e5608caa45c3`). Dueño de settings:
`pmontero@grupomontecristo.com` (tras take over del 24-jul; antes
`gmatarrita@medismart.net`).

- **Orígenes:** SharePoint `msworkforce`, Web `elastic.grupomontecristo.com`,
  MySQL `cr_wfm` en `gmon-prod-mysql-eastus2-0001`.
- **Python en el modelo:** el gateway **empresarial NO ejecuta scripts
  Python/R** en refresh del servicio. Python en refresh requiere gateway
  **personal** en la misma máquina. Se instaló Python 3.11.9 en
  `C:\Python311` (pandas/matplotlib) pero eso **no** elimina el error
  "Configuración incorrecta" del gateway empresa cuando el modelo usa
  `Python.Execute`. Opciones: usar Personal Gateway o quitar/reemplazar el
  paso Python en Power Query. Detalle:
  `docs/servers/windows/powerbi-gateway/instalacion-python-gateway-172.16.2.127.txt`.
- **Rollbacks del take over y del mapeo de conexiones:**
  `docs/servers/windows/powerbi-gateway/rollback-takeover-reportes-maia.txt`
  y `rollback-conexiones-reportes-maia.txt`.
- **OAuth en browser automatizado:** el popup `oauthredirect.html` queda en
  blanco (el browser embebido no completa el `postMessage` de Power BI). El
  Sign in de SharePoint/OAuth se hace en Edge/Chrome normal, no automatizado.

---

## 7. Pendiente

- **Subir RAM a 8–16 GB** o sacar el gateway de SRV-PRTG (PRTG + ADO +
  gateway en 4 GB).
- Disco C: suele estar justo (~6–9 GB libres).
- Credenciales Elastic / timeouts MySQL son de **origen de datos**, no de la
  automatización del gateway.
- Actualizar el gateway (3000.298.8 marcada desactualizada; no aplicado en prod).
- Resolver Python en el modelo "reportes maia" (Personal Gateway o quitar el paso).
