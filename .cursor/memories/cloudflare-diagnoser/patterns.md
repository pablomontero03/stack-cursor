# Patrones — cloudflare-diagnoser

## Convención de nombres DNS de apps `buklo-web` (frontends Nx/Angular)

Confirmado 2026-09-07 a partir de evidencia local (manifiestos K8s ya
generados por el dominio de Azure DevOps Pipelines para
`buklo-logistics-web`, y la memoria cross-dominio
`ado-buklo-web-frontend-deploy-pattern` de ese otro proyecto de agentes) —
no verificado todavía contra el estado real de Cloudflare en esa sesión
por falta de herramienta de ejecución (ver `debugging.md`).

- **Dev/UAT**: hostname `<nombre-app-sin-prefijo-'app-'>-web-{dev,uat}.gmontecristo.com`
  (ej. `logistics-web-dev.gmontecristo.com` para la app `app-logistics`,
  NO `app-logistics-web-dev.gmontecristo.com`). El prefijo `app-` del
  nombre de carpeta/pipeline se **descarta** en el hostname público.
- **Producción — el patrón real diverge de `grupomontecristo.com`**: las
  apps hermanas (`shell-web`, `hr-web`, `ontology-web`, `ticketing-web`,
  `app-logistics`) usan en Producción `<nombre>-web.buklo.dev`
  (`ingressClassName: internal-ingress`, no una IP pública de AKS
  directamente comparable a un registro `A` de `grupomontecristo.com`).
  Un pedido de zona/registro de Producción en `grupomontecristo.com` para
  una app `buklo-web` nueva **contradice la convención ya usada por sus 5
  apps hermanas** — reportarlo siempre como conflicto de nomenclatura
  explícito, nunca asumir cuál de los dos patrones es el correcto ni
  "corregirlo" silenciosamente en el reporte.
- Esta convención es específica de `buklo-web` (monorepo Angular/Nx,
  proyecto ADO `Buklo`/`DevOps`). No se confirmó (ni se debe asumir) que
  aplique a otros monorepos o dominios de aplicación.

## Segunda corroboración (`app-sso`, 2026-09-07) — mismo patrón, mismo conflicto

El pedido de descubrimiento para `app-sso` llegó con exactamente el mismo
patrón Dev/UAT (`sso-web-dev.gmontecristo.com`,
`sso-web-uat.gmontecristo.com` — coincide con la convención de arriba) y
el mismo tipo de pedido de Producción en `grupomontecristo.com`
(`sso-web.grupomontecristo.com`) que ya se había marcado como conflicto
de nomenclatura para `app-directory`. Sigue sin verificarse contra el
estado real de Cloudflare (ver `debugging.md` — recurrencia de falta de
`Bash`/MCP), pero la repetición del mismo pedido de Producción en la zona
"equivocada" para una segunda app en el mismo día sugiere que puede ser
una convención deliberada nueva del usuario para esta tanda de apps (o un
copy-paste del mismo template de intake) — no necesariamente un error
aislado. Igual criterio: reportar el conflicto explícito, nunca asumir
cuál de los dos patrones (`buklo.dev` de las apps hermanas vs.
`grupomontecristo.com` pedido ahora dos veces) es el correcto.

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
