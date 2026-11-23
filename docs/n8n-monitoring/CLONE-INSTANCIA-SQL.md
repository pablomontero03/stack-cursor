# Guía — Clonar pack de monitores SQL para una instancia nueva

> Copiado desde `c:\PabloDocs\aplicativos\flujos\CLONE-INSTANCIA-SQL.md` el
> 2026-08-20 para que viva dentro de la raíz del proyecto. Fuente operativa
> de verdad para el alcance "n8n Monitoreo SQL / MAIA" de `CLAUDE.md`. Ver
> también `.claude/skills/manage-n8n-monitoring/SKILL.md`.
>
> **Nota sobre el tamaño del pack:** el ejemplo de este doc (Caldera→UAT)
> tiene 10 flujos, pero eso **no es una cantidad fija**. El pack origen de
> cualquier instancia puede tener más o menos flujos. Antes de clonar,
> siempre listar dinámicamente los workflows reales de la carpeta/etiqueta
> origen (API o UI) en vez de asumir un número.

Documento paso a paso para crear (clonar) el set de flujos de monitoreo cuando entra una **nueva instancia de SQL Server** en n8n.

**Última actualización:** 2026-08-20  
**Referencia real:** clon `Sislocar-Caldera-192.168.4.15` → `UAT-Sislocar-Caldera-172.16.2.33`  
**Script de referencia:** `backups/_clone-caldera-to-uat.js`  
**Manifest de referencia:** `Sislocar-UAT-Caldera-172.16.2.33/_clone-manifest.json`  
**n8n:** `http://172.16.2.60:5678`  
**API:** ver también `N8N-API-RUNBOOK.md`

---

## 1. Qué es un “pack” de instancia

Para cada servidor/instancia SQL se mantiene un **pack** de ~10 flujos con el mismo patrón de nombre:

```
Monitoreo <tipo> <EtiquetaInstancia>
```

Ejemplo UAT Caldera:

| Tipo | Ejemplo de nombre |
|------|-------------------|
| AutoGrowth | `Monitoreo – AutoGrowth UAT-Sislocar-Caldera-172.16.2.33` |
| Uso CPU | `Monitoreo Uso CPU UAT-Sislocar-Caldera-172.16.2.33` |
| Uso Memoria | `Monitoreo Uso Memoria UAT-Sislocar-Caldera-172.16.2.33` |
| Fragmentación de Índices | `Monitoreo Fragmentación de Índices UAT-Sislocar-Caldera-172.16.2.33` |
| Bloqueos prolongados | `Monitoreo – Bloqueos prolongados UAT-Sislocar-Caldera-172.16.2.33` |
| Errores Jobs | `Monitoreo – Errores Jobs -UAT-Sislocar-Caldera-172.16.2.33` |
| IO Latencia | `Monitoreo IO Latencia UAT-Sislocar-Caldera-172.16.2.33` |
| Espacio en Discos | `Monitoreo – Espacio en Discos UAT-Sislocar-Caldera-172.16.2.33` |
| Cambios Password | `Monitoreo – Cambios Password UAT-Sislocar-Caldera-172.16.2.33` |
| Backups Recientes | `Monitoreo Backups Recientes UAT-Sislocar-Caldera-172.16.2.33` |

> El set exacto puede variar (a veces hay Accesos BD u otros). Contar siempre los del pack **origen** antes de clonar.

---

## 2. Convención de nombres

Usar una etiqueta única y estable:

```
[Ambiente-]Producto-Sitio-IP
```

Ejemplos ya usados:

| Etiqueta | IP |
|----------|-----|
| `Sislocar-Caldera-192.168.4.15` | Prod Caldera |
| `UAT-Sislocar-Caldera-172.16.2.33` | UAT Caldera |
| `Sislocar-Coyol-172.16.16.50` | Coyol |
| `Sislocar-Limon-192.168.10.10` | Limón |
| `Sislocar-Valencia-192.168.128.8` | Valencia |
| `UAT-172.16.2.34` | UAT genérico |
| `Desarrollo-172.16.2.30` | Desarrollo |

**Credencial SQL en n8n:**

```
Microsoft SQL account-<EtiquetaInstancia>
```

Ejemplo: `Microsoft SQL account-UAT-Sislocar-Caldera-172.16.2.33`

**Carpeta local de exports:**

```
c:\PabloDocs\aplicativos\flujos\<EtiquetaInstancia>\
```

**Canal Teams típico (SQL on-prem / MI Sislocar):** `ALERTAS BaseDatos`  
(PA / webhooks: reutilizar los del pack origen salvo que Ops pida otro canal.)

---

## 3. Prerrequisitos (antes de tocar n8n)

Checklist obligatorio:

1. **VPN / red** con acceso a `http://172.16.2.60:5678` y a la IP SQL destino.
2. **API key** en `c:\PabloDocs\aplicativos\flujos\key-api-n8n.txt` (no commitear).
3. **Instancia SQL lista** (login de monitoreo, SPs de `sqldb_database_maintenance` si aplica).
4. **Credencial creada en n8n** (Credentials → Microsoft SQL) apuntando al host destino.
   - Anotar **ID** y **nombre** exactos de la credencial.
5. **Pack origen elegido** (instancia “hermana” más parecida: mismo producto/Sislocar, mismo set de monitores).
6. **Carpeta destino en n8n** (project/folder) creada o identificada; anotar `folderId` si se conoce.
7. Definir si el clon es:
   - **Pruebas UAT** → schedule corto (1 min), **inactivo** al crear.
   - **Producción** → schedule operativo (ej. 5–15 min según estándar del origen), activar solo tras validar.

---

## 4. Datos a recolectar (llenar antes del script)

Copiar y completar:

```text
FROM_LABEL   = ...          # ej. Sislocar-Caldera-192.168.4.15
TO_LABEL     = ...          # ej. UAT-Sislocar-Caldera-172.16.2.33
FROM_IP      = ...          # ej. 192.168.4.15
TO_IP        = ...          # ej. 172.16.2.33
OLD_CRED_ID  = ...          # id credencial origen
OLD_CRED_NAME= Microsoft SQL account-<FROM_LABEL>
NEW_CRED_ID  = ...          # id credencial destino (ya creada en n8n)
NEW_CRED_NAME= Microsoft SQL account-<TO_LABEL>
SOURCE_FOLDER_ID = ...      # carpeta n8n del pack origen (opcional pero útil)
TARGET_FOLDER_ID = ...      # carpeta n8n destino (ej. AnRlYzsCoVh4Y6n1)
SOURCE_WORKFLOW_IDS = [ ... ]  # lista de IDs del pack origen
SCHEDULE_TEST_MINUTES = 1      # para UAT/pruebas
KEEP_INACTIVE = true           # true hasta validar
OUT_DIR = c:\PabloDocs\aplicativos\flujos\<TO_LABEL>
```

### Cómo listar los IDs del pack origen

En PowerShell:

```powershell
$key = (Get-Content "c:\PabloDocs\aplicativos\flujos\key-api-n8n.txt" -Raw).Trim()
$h = @{ "X-N8N-API-KEY" = $key }
$base = "http://172.16.2.60:5678/api/v1"
# Ajustar el search / filtrar por etiqueta
(Invoke-RestMethod "$base/workflows?limit=100" -Headers $h).data |
  Where-Object { $_.name -match 'Sislocar-Caldera-192\.168\.4\.15' } |
  Select-Object id, active, name
```

O abrir la carpeta en n8n y copiar cada workflow ID de la URL.

---

## 5. Procedimiento paso a paso

### Paso 0 — Backup mental / no romper prod

- **No activar** los clones hasta validar.
- No reutilizar la credencial de prod en el pack nuevo.
- Confirmar que el replace de strings no va a tocar webhooks/PA globales por accidente (los Teams URLs suelen ser compartidos a propósito; las IPs/nombres de instancia **sí** deben cambiar).

### Paso 1 — Crear credencial SQL en n8n

1. n8n → Credentials → Add → **Microsoft SQL**.
2. Host = IP/FQDN destino, DB según estándar del pack (a menudo `master` o la de maintenance; seguir el origen).
3. Usuario/password del login de monitoreo.
4. Probar conexión.
5. Guardar con nombre `Microsoft SQL account-<TO_LABEL>`.
6. Abrir la credencial y copiar el **ID** (aparece en URL o en API).

### Paso 2 — Crear carpeta destino en n8n (UI)

1. Ir al project correspondiente (ej. SQL / Sislocar).
2. Crear folder con el nombre `<TO_LABEL>` (o el que use Ops).
3. Anotar `folderId` de la URL si se puede (útil para inventario).

> La API pública usada en los scripts **no siempre mueve** el workflow a la carpeta; al final suele hacerse **manual** (drag & drop) o con endpoint interno si está disponible.

### Paso 3 — Preparar script de clon

1. Copiar `backups/_clone-caldera-to-uat.js` como base, por ejemplo:

   ```text
   backups/_clone-<origen>-to-<destino>.js
   ```

2. Editar constantes:

   - `FROM` / `TO` (etiquetas)
   - `FROM_IP` / `TO_IP`
   - `NEW_CRED` (`id` + `name`)
   - `OLD_CRED_IDS`
   - `CALDERA_WORKFLOW_IDS` → IDs del pack origen
   - `OUT_DIR` → carpeta local `...\flujos\<TO_LABEL>`
   - `SOURCE_FOLDER_ID` / `TARGET_FOLDER_ID` (documentación)
   - Schedule de prueba (`minutesInterval: 1`) o el de prod si aplica

3. Revisar la función `transformWorkflow`:

   - Replace global `FROM` → `TO`
   - Replace `FROM_IP` → `TO_IP`
   - Replace nombre de credencial vieja → nueva
   - Forzar `active = false`
   - Reasignar `credentials.microsoftSql` en nodos MSSQL
   - Ajustar `Schedule Trigger`
   - Timezone `America/Costa_Rica` si falta
   - Borrar campos de metadata (`id`, `versionId`, `shared`, etc.) antes del POST

### Paso 4 — Ejecutar el clon (API)

```powershell
cd c:\PabloDocs\aplicativos\flujos
node .\backups\_clone-<tu-script>.js
```

El script debe:

1. `GET /api/v1/workflows/{id}` de cada origen → backup en `backups/<origen>-to-<destino>-<ts>/`
2. Transformar payload
3. Validar (sin refs al origen, cred OK, schedule OK)
4. `POST /api/v1/workflows` con `{ name, nodes, connections, settings }`
5. `POST .../deactivate` si quedó activo
6. Guardar JSON final en `OUT_DIR`
7. Escribir `_clone-manifest.json`

### Paso 5 — Validar clones

Checklist por cada flujo del manifest:

- [ ] Nombre contiene `<TO_LABEL>`
- [ ] **Inactivo** (`active: false`)
- [ ] Credencial SQL = `NEW_CRED.id` en **todos** los nodos MSSQL
- [ ] No quedan strings `FROM_LABEL`, `FROM_IP`, ni `OLD_CRED_ID`
- [ ] `Set - Params` / textos: `instance_name` (o equivalente) apunta a la instancia nueva
- [ ] Schedule = el acordado (1 min en prueba)
- [ ] Webhooks Teams / PA siguen siendo los correctos del canal

Script de validación de referencia: `backups/_validate_uat_caldera_clones.js` (adaptar IDs/paths).

### Paso 6 — Mover a carpeta en n8n (UI)

1. Abrir cada workflow nuevo (o multi-select si la UI lo permite).
2. Mover al folder destino del project.
3. Confirmar búsqueda por etiqueta, ejemplo:

   `http://172.16.2.60:5678/projects/.../folders/<TARGET_FOLDER_ID>/workflows?search=caldera`

### Paso 7 — Prueba controlada (opcional pero recomendado)

1. Abrir **un** flujo liviano (ej. Espacio en Discos o AutoGrowth).
2. Ejecutar manualmente **una vez** (Execute workflow).
3. Verificar:
   - Conexión SQL OK
   - Sin error de credencial
   - Payload Teams con el **nombre de instancia correcto**
4. Si falla: corregir cred/params; **no** activar el pack.

### Paso 8 — Ajustar horario definitivo

Cuando pase la prueba:

1. Cambiar schedule de 1 min → horario estándar del pack origen (o el que defina Ops).
2. Documentar el horario en el manifest / Excel de inventarios si se usa (`_update_monitoreos_horario.js`).

### Paso 9 — Activar (solo con OK explícito)

1. Activar de a uno o todo el pack.
2. Vigilar ejecuciones 1–2 ciclos.
3. Confirmar alertas/recovery en el canal Teams correcto.

### Paso 10 — Post-trabajo

1. Dejar `_clone-manifest.json` en `OUT_DIR`.
2. Dejar backup en `backups/<origen>-to-<destino>-<ts>/`.
3. (Opcional) Habilitar MCP: `settings.availableInMCP = true` si el flujo debe verse en Instance-level MCP.
4. Actualizar inventario / Excel de horarios si aplica.
5. Anotar en este doc o en el manifest cualquier excepción (flujo omitido, schedule distinto, etc.).

---

## 6. Transformaciones que el script debe hacer (detalle técnico)

Al clonar cada workflow:

| Campo / zona | Acción |
|--------------|--------|
| `name` | Replace etiqueta origen → destino |
| Todo el JSON | Replace etiqueta + IP |
| `id`, `createdAt`, `updatedAt`, `versionId`, `shared`, `tags`, `parentFolder`, … | Eliminar antes del POST |
| `active` | `false` |
| Nodos `microsoftSql` | `credentials.microsoftSql = { id, name }` nuevos |
| `scheduleTrigger` | Parámetros del schedule acordado |
| `settings.timezone` | `America/Costa_Rica` si falta |
| `staticData` | Enviar `null` (no heredar estado de alertas del origen) |
| `settings` en PUT/POST | Solo keys permitidas por la API (`executionOrder`, `timezone`, `saveData*`, `callerPolicy`, `errorWorkflow`, `availableInMCP`, …) |

**POST create (mínimo):**

```json
{
  "name": "...",
  "nodes": [],
  "connections": {},
  "settings": {},
  "staticData": null
}
```

---

## 7. Ejemplo concreto — Caldera → UAT (hecho)

| | |
|--|--|
| Origen | `Sislocar-Caldera-192.168.4.15` |
| Destino | `UAT-Sislocar-Caldera-172.16.2.33` |
| Script | `backups/_clone-caldera-to-uat.js` |
| Cred destino | `4XAbU2ltIjXugd4t` / `Microsoft SQL account-UAT-Sislocar-Caldera-172.16.2.33` |
| Flujos | 10 (ver manifest) |
| Schedule inicial | 1 minuto |
| Estado al crear | Todos **inactivos** |
| Carpeta UI | project folder Caldera UAT (`AnRlYzsCoVh4Y6n1`) |
| Exports | `Sislocar-UAT-Caldera-172.16.2.33\` |

Otros clones previos (misma idea):

- `backups/_clone-coyol-to-caldera.js`
- `backups/_clone-uat-to-coyol.js`
- `backups/_clone-uat-to-etl.js`

---

## 8. Errores frecuentes

| Síntoma | Causa probable | Qué hacer |
|---------|----------------|-----------|
| SQL login failed | Credencial mal host/user o firewall | Probar cred en n8n; VPN/ruta a la IP |
| Flujos siguen con IP vieja | Replace incompleto | Buscar `FROM_IP` / `FROM_LABEL` en JSON y re-patch |
| Cred ID viejo en un nodo | Nodo con cred embebida distinta | Forzar `NEW_CRED` en **todos** los nodos MSSQL |
| Alerta Teams con nombre prod | `Set - Params.instance_name` sin replace | Corregir params y textos del payload |
| Pack se dispara solo | Quedó `active: true` | `POST /workflows/{id}/deactivate` |
| No aparece en carpeta | API no asignó folder | Mover manual en UI |
| Recovery/alerta “fantasma” | Se copió `staticData` del origen | Crear con `staticData: null` |
| Timeout API | VPN caída | Reconectar VPN; `GET /healthz` |

---

## 9. Checklist corto (imprimible)

```text
[ ] Credencial SQL destino creada y testeada
[ ] Pack origen identificado + lista de IDs
[ ] FROM/TO label + IP definidos
[ ] Carpeta n8n destino creada
[ ] Script de clon preparado (copia del de Caldera→UAT)
[ ] Ejecutar clon → todos INACTIVOS
[ ] Manifest generado sin remainingRefs / badCred
[ ] Mover a carpeta UI
[ ] Test manual de 1 flujo
[ ] Ajustar schedule definitivo
[ ] Activar con OK de Ops
[ ] Inventario / MCP / horarios actualizados
```

---

## 10. Relación con otros docs

| Doc / artefacto | Para qué |
|-----------------|----------|
| `N8N-API-RUNBOOK.md` | Auth API, CRUD workflows, ejecuciones |
| `backups/_clone-*-*.js` | Automatización del clon |
| `<Instancia>/_clone-manifest.json` | Trazabilidad source→new |
| `backups/_validate_*_clones.js` | Verificación post-clon |
| `backups/_update_monitoreos_horario.js` | Inventario por carpeta/canal |

---

## 11. Política operativa sugerida

1. **UAT / nuevas instancias:** clonar inactivo + schedule 1 min → probar → subir intervalo → activar.
2. **Prod:** clonar desde pack prod estable; no bajar a 1 min en prod salvo ventana controlada.
3. **Nunca** dejar un pack nuevo activo “por defecto” tras el POST.
4. Si solo cambia el ambiente (Prod→UAT) pero es la misma familia Sislocar, preferir clonar el pack Sislocar hermano, no un Softland/Azure distinto.

---

*Mantener este archivo actualizado cuando cambie el set estándar de monitores o el script de clon de referencia.*
