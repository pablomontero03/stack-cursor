# Runbook — Integración n8n (API)

> Copiado desde `c:\PabloDocs\aplicativos\flujos\N8N-API-RUNBOOK.md` el
> 2026-08-20 para que viva dentro de la raíz del proyecto. Fuente operativa
> de verdad para el alcance "n8n Monitoreo SQL / MAIA" de `CLAUDE.md`. Ver
> también `.claude/skills/manage-n8n-monitoring/SKILL.md`.

Documento de referencia para retomar trabajo con la instancia n8n desde Cursor u otro chat.
**Última actualización:** 2026-05-25

---

## Instancia

| Campo | Valor |
|-------|-------|
| URL base | `http://172.16.2.60:5678` |
| Health check | `GET /healthz` → `{"status":"ok"}` |
| API pública | `http://172.16.2.60:5678/api/v1/` |
| API key | Archivo local `key-api-n8n.txt` (no commitear) |
| Header requerido | `X-N8N-API-KEY: <contenido de key-api-n8n.txt>` |

> Usar **HTTP**, no HTTPS. La IP es interna (`172.16.2.60`).

---

## Troubleshooting — el MCP `n8n-interno` no expone sus herramientas

Síntoma: en una sesión del dashboard no aparece ninguna tool `n8n-interno::*`
(sí carga `azure-devops`), aunque `GET /healthz` responde 200.

**Causa raíz (verificada 2026-09-09):** dos errores de configuración, NO un
problema de variables de entorno (`N8N_MCP_URL` no la usa este servidor; la
URL y el token van literales en la config).

1. **Ruta MCP incorrecta.** El endpoint MCP de n8n es
   `http://172.16.2.60:5678/mcp-server/http`, no `/mcp`. Un `POST /mcp`
   devuelve `404 Cannot POST /mcp`; `/mcp-server/http` responde 200 al
   handshake `initialize`. (`GET /mcp` daba 200 y despistaba — el protocolo
   MCP usa POST.)
2. **Token equivocado.** El JWT del header debe tener `"aud":"mcp-server-api"`.
   Un token con `"aud":"public-api"` (el de la API pública de n8n) da **401**
   contra `/mcp-server/http`. El token MCP correcto se obtiene del nodo
   **MCP Server** en la UI de n8n.

**La config vive en 4 archivos — corregir uno solo NO basta:**

- `<repo>/.cursor/mcp.json` (proyecto)
- `~/.cursor/mcp.json` (config del worker)
- `/home/cursor/stack-cursor/.cursor/mcp.json` (agente del dashboard — tiene la ruta en 2 lugares: `url` y `args --streamableHttp`)
- `/home/cursor/stack-cursor/.cursor/mcp.json` (KiroCrew)

Si el servidor falló repetidamente puede quedar en cuarentena en
`/home/cursor/stack-cursor/.cursor/mcp.json`; un reinicio del worker gmon-hub tras el fix lo
reintenta.

**Pasos para dejarlo funcionando:**

1. Corregir ruta + token en los 4 archivos.
2. reiniciar el worker gmon-hub para recargar `.cursor/mcp.json`.
3. Abrir una **sesión nueva** del dashboard — la lista de tools se fija al
   crear la sesión y no se recarga desde adentro.

**Diagnóstico útil** (expone el estado de carga por servidor MCP):

```bash
el worker gmon-hub carga `.cursor/mcp.json` 2>&1 \
  | grep -iE "mcpServerName|InitFailureReason|toolsPerMcpServer"
```

`InitFailureReason` vacío + `toolsPerMcpServer=34` = `n8n-interno` cargó bien.

> Nota: el MCP `n8n-interno` es el **servidor MCP oficial de n8n (SDK,
> v1.1.0)** — expone 34 tools para construir/buscar/validar workflows
> (`search_workflows`, `get_workflow_details`, `create_workflow_from_code`,
> etc.), no la API de administración clásica. La API pública clásica
> (`/api/v1/`, header `X-N8N-API-KEY`) es una vía distinta.

---

## Troubleshooting — el MCP `n8n-productivo` no queda usable con supergateway (SSE 404)

Síntoma: con `n8n-productivo` configurado vía `supergateway --streamableHttp`
(`type: stdio`), la sesión no expone tools `n8n-productivo::*`. La telemetría
el cliente MCP puede mostrar `Failed to open SSE stream: Not Found`.

**Causa raíz (verificada 2026-09-09) — es el TRANSPORTE, no la versión ni la
config:**

- URL (`https://automation.grupomontecristo.com/mcp-server/http`) y token
  (`aud=mcp-server-api`) correctos: el `POST initialize` + `tools/list`
  responden **200** y devuelven **3 tools** (`search_workflows`,
  `execute_workflow`, `get_workflow_details`) por HTTP normal.
- El servidor productivo (**n8n MCP Server v1.0.0**) NO expone el canal SSE
  (un `GET` al endpoint da `404 Cannot GET /mcp-server/http`). `supergateway`
  exige abrir ese SSE tras el initialize y aborta con el 404.
- Claude Desktop conecta ese mismo servidor con **3 tools** porque usa el
  transporte **HTTP directo** (no supergateway) y no depende del SSE.

**Fix (aplicado 2026-09-09) — cambiar el transporte a HTTP directo:** definir
`n8n-productivo` como `type: http` con `url` + `headers`, SIN `command`/`args`
de supergateway:

```jsonc
"n8n-productivo": {
  "type": "http",
  "url": "https://automation.grupomontecristo.com/mcp-server/http",
  "headers": { "Authorization": "Bearer ${N8N_PRODUCTIVO_MCP_TOKEN}" }
}
```

Aplicar en los **4 archivos de config** (ver la sección de n8n-interno) y
reiniciar + sesión nueva. Nota: `n8n-interno` (v1.1.0) sí soporta el SSE, por
eso funciona con supergateway; `n8n-productivo` (v1.0.0) requiere HTTP directo
hasta que su instancia se actualice.

---

## Troubleshooting — colisión de nombres de tools entre interno y productivo

Síntoma: `search_workflows` devuelve el catálogo del INTERNO (Schema Sync,
monitoreo SQL, AKS) aunque se pidió el de productivo — o al revés.

**Causa:** `n8n-interno` y `n8n-productivo` exponen tools con nombres
IDÉNTICOS (`search_workflows`, `execute_workflow`, `get_workflow_details`).
si dos tools se llaman igual, el cliente puede dejar solo una invocable bajo ese nombre (la del
interno, con 34 tools). Ambos servidores cargan bien (`fail=""`, 34 y 3
tools), pero el modelo ve un solo `search_workflows`.

**Fix (aplicado 2026-09-09) — `toolAliases` en el agente:** en
`/home/cursor/stack-cursor/.cursor/mcp.json`, remapear las tools de productivo a nombres
únicos:

```json
"toolAliases": {
  "@n8n-productivo/search_workflows": "prod_search_workflows",
  "@n8n-productivo/execute_workflow": "prod_execute_workflow",
  "@n8n-productivo/get_workflow_details": "prod_get_workflow_details"
}
```

Requiere reiniciar el worker gmon-hub y abrir un chat nuevo. Tras esto: `prod_search_workflows`
= productivo (negocio/MAIA), `search_workflows` = interno.

**Verificar SIEMPRE por contenido antes de reportar** cuál instancia
respondió:
- Interno → Schema Sync, monitoreo SQL por servidor, AKS, framework `fwk_sp_*`.
- Productivo → negocio/MAIA: `MAA-*`, `Arthur *`, `Chatbot*`, `PP-CC-*`,
  `PortalCC`, ElevenLabs, cotizadores. (29 workflows, todos activos al
  2026-09-09.)

⚠️ `prod_execute_workflow` EJECUTA workflows productivos (MAIA/negocio) —
requiere aprobación explícita caso por caso. `PP-CC-PortalCC_Providers` tiene
un nodo rotulado "CUIDADO Validen antes de activar/ejecutar".

---

## Seguridad

- La API key vive solo en `key-api-n8n.txt`.
- **Rotar la key** cuando termine la fase de pruebas.
- No subir `key-api-n8n.txt` a git ni pegar la key en chats.
- Los JSON de workflows locales pueden contener webhooks de Teams, credenciales referenciadas por ID, etc.

---

## Cómo conectar desde PowerShell (Windows)

```powershell
$key = (Get-Content "c:\PabloDocs\aplicativos\flujos\key-api-n8n.txt" -Raw).Trim()
$headers = @{ "X-N8N-API-KEY" = $key }
$base = "http://172.16.2.60:5678/api/v1"
```

En bash/Linux usar `curl.exe` o `curl` según el entorno. En PowerShell, `curl` es alias de `Invoke-WebRequest`; preferir `Invoke-RestMethod` o `curl.exe`.

---

## Operaciones verificadas

### Listar workflows

```powershell
Invoke-RestMethod -Uri "$base/workflows?limit=100" -Headers $headers
```

Ejemplo de respuesta (muestra real):

- `05BjFKmWmDiD5CI9` — AKS - Pod Restart Monitor (active)
- `0tfRdEj6vq9fJ0zz` — Ops - Baseline nocturno (active)
- Varios flujos de monitoreo SQL UAT/Prod

### Obtener un workflow

```powershell
Invoke-RestMethod -Uri "$base/workflows/{id}" -Headers $headers
```

### Crear workflow

```powershell
$body = Get-Content ".\sitios\Monitoreo – Disponibilidad URLs HTTP.json" -Raw | ConvertFrom-Json
# Para crear, enviar solo campos necesarios:
$payload = @{
  name = $body.name
  nodes = $body.nodes
  connections = $body.connections
  settings = $body.settings
} | ConvertTo-Json -Depth 100

Invoke-RestMethod -Method POST -Uri "$base/workflows" -Headers $headers -ContentType "application/json" -Body $payload
```

### Actualizar workflow

```powershell
Invoke-RestMethod -Method PUT -Uri "$base/workflows/{id}" -Headers $headers -ContentType "application/json" -Body $payload
```

### Activar / desactivar

```powershell
Invoke-RestMethod -Method POST -Uri "$base/workflows/{id}/activate" -Headers $headers
Invoke-RestMethod -Method POST -Uri "$base/workflows/{id}/deactivate" -Headers $headers
```

---

## Ejecuciones y logs

### Listar ejecuciones

```powershell
# Todas (paginadas)
Invoke-RestMethod -Uri "$base/executions?limit=20" -Headers $headers

# Filtrar por workflow
Invoke-RestMethod -Uri "$base/executions?workflowId={id}&limit=20" -Headers $headers

# Solo errores
Invoke-RestMethod -Uri "$base/executions?status=error&limit=20" -Headers $headers
```

Status posibles: `success`, `error`, `running`, `waiting`, `canceled`

### Ver detalle + logs por nodo

```powershell
Invoke-RestMethod -Uri "$base/executions/{executionId}?includeData=true" -Headers $headers
```

Con `includeData=true` se obtiene:

- `data.resultData.runData` — resultado por nodo (success/error, tiempos)
- `data.resultData.error` — error global (mensaje, stack)
- `data.resultData.lastNodeExecuted` — último nodo que corrió

Ejemplo diagnosticado (2026-05-25):

| Execution ID | Workflow | Resultado |
|--------------|----------|-----------|
| `935257` | Monitoreo Fragmentación de Índices UAT | Error timeout SQL 15s en nodo `MSSQL - Fragmentación Índices` |

Nodos vistos en `runData`:

1. Schedule Trigger — success
2. Set - Params — success
3. MSSQL - Fragmentación Índices — **error** (15022 ms)

### Reintentar ejecución fallida

```powershell
Invoke-RestMethod -Method POST -Uri "$base/executions/{id}/retry" -Headers $headers -ContentType "application/json" -Body "{}"
```

> Solo aplica a ejecuciones con error. Pide confirmación antes de reintentar en producción.

---

## Ejecutar workflows manualmente

| Método | Estado en esta instancia |
|--------|--------------------------|
| `POST /workflows/{id}/execute` | **No disponible** (HTTP 405) — requiere n8n más reciente |
| Webhook del workflow | **Sí**, si el flujo tiene nodo Webhook activo |
| Schedule Trigger | Solo corre en su horario; no se dispara por API |
| `POST /executions/{id}/retry` | **Sí**, solo re-ejecuta fallos previos |

### Seguimiento en tiempo real

- Consultar `GET /executions?status=running`
- Detalle nodo a nodo al terminar, o antes si el workflow tiene **Save execution progress** activado en settings
- No hay streaming de logs vía API pública (log streaming es feature enterprise)

---

## Carpeta local de workflows

Ruta: `c:\PabloDocs\aplicativos\flujos\`

```
flujos/
├── key-api-n8n.txt          # API key (local, no git)
├── N8N-API-RUNBOOK.md       # Este archivo (API n8n)
├── CLONE-INSTANCIA-SQL.md   # Guía paso a paso: clonar pack monitores SQL
├── cluster/                 # Flujos AKS / kubectl
├── sitios/                  # Monitoreo URLs, certificados TLS
├── <EtiquetaInstancia>/     # Exports + _clone-manifest.json por servidor
└── *.json                   # Monitoreos SQL Server UAT/Prod
```

Los JSON son exports de n8n con estructura estándar: `name`, `nodes`, `connections`, `settings`, etc.

Para **crear el pack completo de una instancia SQL nueva** (clon desde Caldera/Coyol/UAT/etc.), seguir **`CLONE-INSTANCIA-SQL.md`**.

---

## Flujo de trabajo recomendado con Cursor

1. Leer este archivo al iniciar un chat nuevo sobre n8n.
2. Leer `key-api-n8n.txt` solo en el entorno local (nunca commitear).
3. Para diagnosticar: listar ejecuciones → filtrar errores → `includeData=true` → identificar nodo fallido.
4. **Antes de cualquier cambio en un flujo:**
   - Descargar respaldo vía API a `backups/` con timestamp en el nombre.
   - **Indicar al usuario qué se va a cambiar** y esperar OK si aplica.
   - Aplicar cambio → probar → documentar en bitácora.
5. Para cambios: editar en n8n vía API (`PUT`) y sincronizar JSON local si corresponde.
6. Para **nueva instancia SQL**: usar `CLONE-INSTANCIA-SQL.md` + script tipo `backups/_clone-caldera-to-uat.js`.

---

## Bitácora de cambios

| Fecha | Qué se hizo |
|-------|-------------|
| 2026-05-25 | Verificada conectividad a `172.16.2.60:5678` (healthz OK) |
| 2026-05-25 | Confirmada API pública activa; key en `key-api-n8n.txt` funciona |
| 2026-05-25 | Listados workflows y ejecuciones recientes vía API |
| 2026-05-25 | Probado `includeData=true` — logs por nodo disponibles |
| 2026-05-25 | Confirmado que `POST /workflows/{id}/execute` no existe (405) en esta versión |
| 2026-05-25 | Probado retry de ejecución `935257` → nueva `935279` (mismo error SQL timeout) |
| 2026-05-25 | Creado este runbook |
| 2026-05-25 | Regla acordada: respaldo en `backups/` + avisar cambios antes de aplicar |
| 2026-05-25 | Backup flujo Fragmentación Índices UAT → `backups/Monitoreo Fragmentacion de Indices UAT-172.16.2.34-20260525-091937.json` |
| 2026-05-25 | Diagnóstico exec 935294: timeout 15s en nodo `MSSQL – Fragmentación índices` (SP `usp_MonitoreoFragmentacionIndices`) |
| 2026-05-25 | Usuario aumentó Request Timeout credencial UAT a 120000 ms |
| 2026-05-25 | Backup CPU Softland → `backups/Monitoreo Uso CPU Produccion Softland-172.16.2.26-20260525-092636.json` |
| 2026-05-25 | Diagnóstico exec 935302: FOR XML falla por CHAR(0) en nodo `MSSQL – Snapshot para Teams` (workflow `1j3Qc5WItZqFTgem`) |
| 2026-05-25 | Fix CPU Softland: `REPLACE(..., CHAR(0), N'')` en 4 bloques FOR XML del nodo Snapshot. Retry exec 935558 = success |
| 2026-05-25 | Hotfix BOM UTF-8 en query Snapshot (introducido al guardar SQL con BOM). Validado retry 935648 = success |
| 2026-05-25 | CPU Softland Snapshot v2: eliminados 4 bloques FOR XML (concat COALESCE + sanitize @base). Retry 936150 ambos items OK |
| 2026-05-25 | Espacio en Discos UAT: 7 nodos MSSQL cambiados de Softland a credencial `SVQZeW7xxkefknXC` (UAT-172.16.2.34) |
| 2026-05-25 | CPU UAT: 9 nodos MSSQL cambiados de Softland a credencial `SVQZeW7xxkefknXC` (UAT-172.16.2.34) |
| 2026-05-27 | Diagnóstico exec 957811/957817: fallo transitorio DNS (`EAI_AGAIN`) y timeout hacia `gmon-prod-sqlmi-eastus2-0001` desde n8n; múltiples flujos Monitoreo Datos afectados ~17:00–17:25 UTC |
| 2026-05-27 | Fix HANA_NOMEDICA action_1 (`k7Qcvy5PQjFjT0Bc`) y action_2 (`99tsTib9pOlePWm4`): `retryOnFail=true`, `maxTries=3`, `waitBetweenTries=5000` en nodos MSSQL. Retry exec 957811 → 958310 success |
| 2026-05-27 | Extendido retry MSSQL a los 21 flujos `Monitoreo Datos` (42 nodos). Excepción: `TASK_MONITOR_CONCILATION_CONSISTENCY` requirió filtrar `settings.binaryMode` en el PUT |
| 2026-05-27 | UAT (10 flujos): webhooks Teams unificados + migración `MessageCard` → `{ text }`. AKS CPU/Memory: solo migración formato (webhooks propios). Retry 958706→958907 y 958811→958911 OK |
| 2026-05-27 | Retry global MSSQL+HTTP: 127 flujos activos, 614 nodos (`retryOnFail`, `maxTries=3`, `waitBetweenTries=5000`). 11 flujos archivados Sislocar-Coyol omitidos |
| 2026-05-27 | Post-retry: execs 959375/960523 (Frag UAT) timeout 120s × ~3 intentos (~370s total); exec 960516 (Frag Prod) timeout 15s × ~4 intentos — SP `usp_MonitoreoFragmentacionIndices` excede timeout, no es bug del retry |
| 2026-05-27 | Execs 960200/961096 (Espacio Discos Desarrollo): 403 intermitente en Teams con MessageCard; webhooks Desarrollo responden 200 OK — migrados 9 flujos Desarrollo + Fragmentación Prod a formato `{ text }` |
| 2026-05-28 | Webhooks unificados UAT (8cad4dfe/b2d2abe1) aplicados a **30 flujos** UAT + Desarrollo + Sislocar-Limon; MessageCard/Adaptive → `{ text }`. Revertidos nodos de lógica parcheados por error (Decidir estado, Build extras/insert) |
| 2026-05-28 | Exec 961701 IO Latencia UAT: 403 transitorio Teams con payload `{ text }` correcto (1934 chars); 3 retries fallaron, replay mismo payload → 200 en intento 2. Teams HTTP: **maxTries=5, waitBetweenTries=10000** en 123 flujos (243 nodos) |
| 2026-05-28 | Exec 961850 Fragmentación Sislocar-Limon: Teams recibió `{ text: "" }` vacío — bug migración: `__teamsTextFromCard` no leía `card.text`. Fix helper en 32 flujos |
| 2026-05-28 | Execs 966092/966125 Memoria Desarrollo: HTTP `jsonBody={{$json.body}}` pero Build devolvía `{ card }` → JSON inválido. Fix en Memoria Desarrollo + Memoria Sislocar-Limon |
| 2026-07-27 | Nuevo flujo `Monitoreo - Accesos BD UAT-172.16.2.34` (`VIFct62aPY6MaPsT`): alerta por vencer (cada 3h), recovery al ampliar, revoke+INFO con `usp_RevocarAccesosExpirados`. Credencial UAT. Test E2E IdAcceso 6 → EXPIRADO |

---

## Pendientes / mejoras

- [ ] Rotar API key cuando termine la fase de pruebas
- [ ] Evaluar upgrade de n8n para habilitar `POST /workflows/{id}/execute`
- [ ] Agregar `key-api-n8n.txt` a `.gitignore` si el repo se sube a git
- [ ] Definir primer workflow a subir/modificar desde la carpeta local

---

## Prompt útil para retomar en otro chat

```
Lee c:\PabloDocs\aplicativos\flujos\N8N-API-RUNBOOK.md y conéctate a n8n
usando key-api-n8n.txt. [describe aquí la tarea]
```
