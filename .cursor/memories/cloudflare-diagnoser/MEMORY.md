# Memoria — cloudflare-diagnoser

## Propósito

Diagnóstico de solo lectura de recursos Cloudflare — DNS, propagación,
SSL/TLS, WAF, cache, Workers, Pages, Zero Trust, Tunnels, balanceadores,
logs y analytics. Opera en lectura por defecto; cualquier corrección se
transfiere al flujo de plan de `cloudflare-operator`.

## Alcance de esta memoria

Aprendizajes reutilizables sobre: patrones de causa raíz confirmados para
fallas de DNS/TLS/WAF/cache/Workers/Pages/Zero Trust, convenciones de
nombres de zonas/recursos con los que se trabajó, y falsos positivos
descartados durante el diagnóstico.

- [debugging.md](debugging.md) — diagnósticos y causas raíz confirmadas.
- [patterns.md](patterns.md) — convenciones y decisiones técnicas
  confirmadas del dominio Cloudflare.

## Aprendizajes esenciales

- Convención real de nombres DNS de apps `buklo-web`: Dev/UAT
  `<nombre-sin-'app-'>-web-{dev,uat}.gmontecristo.com`; Producción
  `<nombre>-web.buklo.dev` (NO `grupomontecristo.com` — un pedido en esa
  zona para Producción de una app `buklo-web` es un conflicto de
  nomenclatura, reportarlo siempre). Ver `patterns.md`.
- Esta sesión (2026-09-07) se ejecutó sin `Bash`/PowerShell/MCP
  disponibles — solo pudo diagnosticar con evidencia local de archivos,
  no con consultas reales a Cloudflare. Verificar disponibilidad de
  herramienta de ejecución al empezar cualquier invocación futura. Ver
  `debugging.md`.

Última revisión: 2026-09-07.

## Regla operacional: no ejecutar setup.sh de Kiro
Confirmado en producción 2026-09-21. No ejecutar `setup-kiro.sh`. `./setup-cursor.sh` no reinicia el worker.

**Siempre usar en sesiones activas de Crew:**
```bash
set -a; source /home/cursor/stack-cursor/env/.env; set +a
export REPO_ROOT=/home/cursor/stack-cursor
```
O con el flag seguro: `set -a; source env/.env; set +a`

No ejecutar `source ./setup.sh`. Para variables: `set -a; source env/.env; set +a`.

## Subida de archivos del dashboard bloqueada por WAF managed (2026-09-23)

Síntoma: en `crew.gmontecristo.com` (dashboard KiroCrew, Cloudflare Tunnel → `127.0.0.1:5476`, tras Cloudflare Access) al subir un archivo o pegar un pantallazo se abría el diálogo, se elegía el archivo y **no se adjuntaba**. Con DevTools → Network, el POST `/api/upload/file` daba **403** con header de respuesta `cf-mitigated: challenge` y body HTML de reto (`text/html`, CSP con `challenges.cloudflare.com`).

Causa raíz: un **managed ruleset WAF de Cloudflare** (OWASP Core / Managed Free) interceptaba el POST `multipart/form-data` en el borde y devolvía un challenge — la petición **nunca llegaba al gateway** (`gateway.log` sin rastro). No era límite de tamaño (falló con imagen de 150 KB), ni bug de frontend, ni Cloudflare Tunnel.

Fix (aplicado por API, aprobado por Pablo): regla `skip` en el ruleset WAF **custom** de la zona `gmontecristo.com` (id `a44e342e3fc84c369355f1ca1c25b11d`):
- Expresión: `(http.host eq "crew.gmontecristo.com" and starts_with(http.request.uri.path, "/api/upload"))`
- `action: skip`, `action_parameters.phases: ["http_request_firewall_managed"]`
- Mismo patrón que las reglas existentes de `admin-dev.gmontecristo.com` y `sirep-uat.gmontecristo.com`.
- Se agregó por `POST .../rulesets/{id}/rules` (agrega sin reemplazar las 3 reglas previas).

Cloudflare Access sigue protegiendo el endpoint (solo se salta el WAF de bots, no la autenticación). Verificado en vivo: tras aplicar, la subida de 2 imágenes + 1 JSON funcionó.

Aparte: `/api/instances` da **403** por `instances.enabled=false` en `config.json` — es la feature de instancias SSH remotas, **no** relacionada con la subida; no se tocó.

NOT: no diagnosticar el fallo de subida como límite de 100 MB de Cloudflare ni bug de Node/frontend cuando la respuesta trae `cf-mitigated: challenge`; eso es WAF managed. No activar `instances.enabled` por el 403 de `/api/instances`.


## Host del cluster .31 por Cloudflare que no carga DENTRO de la oficina (2026-10-19)

Sintoma: un host del cluster prod on-prem `.31` publicado por Cloudflare (ej `knowledge-base.grupomontecristo.com`) carga **fuera** de la oficina pero **no adentro** (`ERR_CONNECTION_REFUSED`). **NO es un deny/permiso de Cloudflare** -- el registro proxied esta correcto y responde 200 server=cloudflare desde internet.

Causa raiz: el DNS interno de la oficina (AD, zona autoritativa `grupomontecristo.com`, DCs `SRV-MIS-DC01 172.16.2.7` / `.8`) tenia un **A record interno -> `190.113.100.74`** (la IP publica real del borde `.31`). Adentro el host resolvia directo a esa IP y pegaba al `:443`, que el `.31` **no expone** (su borde solo escucha `:4443` y es Cloudflare quien reescribe el puerto via Origin Rule) -> conexion rechazada. Afuera, al resolver a Cloudflare (`104.21.x`/`172.67.x`), CF entrega al borde en `:4443` -> carga.

Diagnostico (lo que lo confirma):
- `nslookup <host>` interno da la IP de origen (o `Non-existent domain` si la zona autoritativa interna no tiene el registro) mientras `nslookup <host> 1.1.1.1` da IPs de Cloudflare -> divergencia interno vs externo = split-horizon.
- Que el DNS interno sea **autoritativo de toda la zona `grupomontecristo.com`** (no un registro suelto) es lo que hace que, si falta/esta mal el host, de `Non-existent domain` en vez de reenviar al publico.

Fix definitivo (en el DNS interno, CERO cambios en Cloudflare):
- **NO** A interno a `190.113.100.74` (da el error) ni **A fijos a IPs de Cloudflare** (el pool CF rota y pueden ser mas de 2 -> bomba de tiempo).
- **CNAME interno** al nombre que Cloudflare mantiene al dia: patron **`<host>.grupomontecristo.com.cdn.cloudflare.net`** (ej `knowledge-base.grupomontecristo.com.cdn.cloudflare.net`). Sigue el pool CF solo, nunca mas se toca.
- Requisito del CNAME: el DNS interno debe tener **forwarders con salida a internet** para resolver el target `.cdn.cloudflare.net` (cross-zone). Validado 2026-10-19 por WinRM al `.127`: `Resolve-DnsName` encadena CNAME -> A de CF y el HTTP real da 200 server=cloudflare. Si el DC no resolviera externos, caer a los 2 A de CF como paliativo.

Matiz post-fix (lo que confundio hoy): tras corregir el DNS, el `nslookup`/HTTP del OS ya daba Cloudflare pero el **navegador seguia fallando** por **cache DNS propia de Chrome** (independiente del OS) con el `190.113.100.74` viejo. Verificar end-to-end a nivel OS (`Invoke-WebRequest` 200) separa "problema de red/DNS" de "cache del navegador"; el fix del navegador es `chrome://net-internals/#dns` Clear host cache + `#sockets` Flush, o ventana incognito, o `ipconfig /flushdns` + Ctrl+F5.

Pendiente para infra: los otros hosts del `.31` publicados por CF (`grafana-onprem-01`, `datahub`, `cicd-dashboard`, `k8s-hub`, `cluster-onprem-01`) merecen el mismo CNAME interno si alguno quedo con A a `190.113.100.74`.

Registro de actividad: Task hija 43758 bajo la HU 42601 (proyecto Database-Administration-and-Monitoring), 2h est/comp, Closed.

NOT: no diagnosticar como deny/permiso de Cloudflare ni tocar Cloudflare (el borde esta correcto); no poner A interno a la IP de origen `190.113.100.74` ni A fijos a IPs de CF; no concluir "sigue roto" sin descartar la cache del navegador tras arreglar el DNS.
