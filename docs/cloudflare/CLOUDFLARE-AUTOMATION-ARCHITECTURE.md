# Arquitectura — Administración de Cloudflare

Implementado 2026-09-04 a partir de
`INSTRUCCIONES-AUTOMATIZACION-CLOUDFLARE.md` (raíz del proyecto), siguiendo
el mismo modelo de aprobación mínima-pero-segura que ya usan Azure
Resources, AKS y Azure DevOps en este proyecto, adaptado a las dos vías de
conexión propias de Cloudflare (MCP oficial por OAuth + API REST por
token).

## Objetivo

Administrar cuentas, zonas, DNS/DNSSEC, SSL/TLS/Origin CA/mTLS, WAF/rate
limiting/Bot Management, Redirect/Transform/Page Rules y Rulesets, Cache y
purgas, Workers/Pages/KV/R2/D1/Queues/Durable Objects/Vectorize/Workflows,
Load Balancing, Zero Trust (Access/Gateway/WARP), Tunnels, Logpush/audit
logs/GraphQL Analytics, notifications y API Tokens: lectura/inventario/
diagnóstico/simulación automáticos; una sola aprobación cubre todo un plan
no destructivo completo; las eliminaciones —incluidas las lógicas por
efecto— exigen siempre una aprobación separada, inmediatamente antes de la
fase destructiva.

## Componentes

```text
.claude/
├── skills/manage-cloudflare/
│   ├── SKILL.md
│   ├── references/            (9 archivos)
│   └── scripts/                (12 scripts + tests/)
├── agents/cloudflare/           (cloudflare-operator, cloudflare-diagnoser, cloudflare-reviewer)
├── agent-memory/cloudflare-*/   (MEMORY.md, debugging.md, patterns.md por agente)
├── rules/cloudflare/            (authorization.md, security.md)
└── hooks/cloudflare/            (7 scripts + tests/)

docs/cloudflare/CLOUDFLARE-AUTOMATION-ARCHITECTURE.md   (este archivo)

.local/cloudflare/               (no versionado)
├── inventory/  plans/  delete-plans/  backups/  executions/  reports/  logs/
```

- **`Cloudflare-Common.ps1`**: librería compartida — hash canónico
  SHA-256 del plan, journal de ejecución con lock exclusivo de archivo y
  escritura atómica (8 estados, sin el `blocked-deviation` que sí tiene
  Azure), `Invoke-CloudflareApiRequest` (helper REST que arma
  `Authorization: Bearer` solo en memoria), contexto de cuenta, y 2
  funciones de escaneo de secretos adaptadas con nombres propios de
  Cloudflare (`origincakey`, `tunnelsecret`, `workersecret`, etc.).
- **`New-CloudflareChangePlan.ps1` / `Test-CloudflareChangePlan.ps1`**:
  arman y validan un plan inmutable con el esquema de 27 campos por
  operación (ver `references/change-workflow.md`) — 4 más que Azure
  (`zoneId`, `resourceName`, `expectedReadback` explícitos, y `method`/
  `uri` separados en vez de embebidos en `argv`).
- **`Apply-CloudflareChangePlan.ps1`**: único script que ejecuta
  escrituras no destructivas reales.
- **`New-CloudflareDeletePlan.ps1` / `Test-CloudflareDeletePlan.ps1` /
  `Apply-CloudflareDeletePlan.ps1`**: plan de eliminación separado,
  siempre con respaldo pre-delete automático y aprobación separada.
- **`Test-CloudflarePostChange.ps1`**: readback de solo lectura tras
  aplicar.
- **`Invoke-CloudflareRollback.ps1`**: prepara (nunca aplica) un plan
  inverso.

## Modelo de autorización

Ver el detalle completo en `.cursor/rules/cloudflare.mdc` — resumen:

- Lectura, inventario, GraphQL de solo lectura, `docs`/`search`/`execute`
  de solo lectura del MCP, simulación Terraform, Wrangler de lectura:
  automáticos.
- Aprobación del plan principal: una sola tarjeta cubre TODAS las
  operaciones de `approvedOperations`.
- Aprobación destructiva: siempre separada, cubre el lote exacto de
  `pendingDeleteOperations` identificado por sus `operationId`.
- **Eliminación lógica por efecto** (capa que Azure no necesita): purga de
  cache, reemplazo de un Ruleset que remueve reglas, desvincular un
  binding/custom domain/route, revocar un token/certificado —
  `cloudflare-security-gate.ps1` los clasifica como `ask` por patrón de
  endpoint conocido, nunca intenta diffear contra el estado real de forma
  estática; esa comparación vive en `Test-CloudflareChangePlan.ps1` y en
  `cloudflare-reviewer`.
- **MCP Code Mode**: `docs`/`search` siempre lectura; `execute` se
  clasifica inspeccionando el `tool_input` recibido (heurística por
  regex, sin sandbox de ejecución) — cualquier mención de escritura,
  método dinámico o acceso a secretos fuerza `ask`; cualquier tool
  `mcp__cloudflare-api__*` no enumerada (fuera de `docs`/`search`/
  `execute`) también cae a `ask`, porque el handshake real contra el MCP
  oficial todavía no se hizo al momento de esta implementación.
- Reutilización de aprobación visible: `cloudflare-plan-authorization.ps1`
  / `cloudflare-delete-authorization.ps1` permiten el comando exacto de
  Apply sin tarjeta nueva cuando el último plan aprobado por
  `ExitPlanMode` contiene el bloque
  ```cloudflare-apply-authorization```/```cloudflare-delete-authorization```
  correspondiente, con hash del plan verificado y vigencia ≤24h — mismo
  mecanismo que Azure Resources, portado 1:1.
- Nunca `deny` como resultado general — solo 2 bloqueos absolutos
  detectables por texto (`bypassPermissions`/
  `--dangerously-skip-permissions`).

## MCP oficial `cloudflare-api`

Agregado a `.mcp.json` (`type: "http"`, `url:
"https://mcp.cloudflare.com/mcp"`) de forma aditiva, sin tocar
`n8n-interno`, `n8n-productivo`, `azure-devops` ni `aks`. Usa OAuth del
lado del cliente — no se creó ninguna aplicación OAuth propia. **El
handshake real (conexión, enumeración de tools, primera consulta de
lectura) todavía no se ejecutó al cierre de esta implementación** — ver §
Pendiente más abajo. La clasificación de MCP Code Mode en
`cloudflare-security-gate.ps1` se construyó contra el esquema esperado
por el propio documento de instrucciones (`docs`/`search`/`execute`) y
debe reconfirmarse (y corregirse si difiere) contra la conexión real antes
de asumir cualquier comportamiento no probado — mismo criterio que Azure
mantuvo con su MCP diferido.

## API REST

`https://api.cloudflare.com/client/v4/`, vía `$env:CLOUDFLARE_API_TOKEN`
(nunca Global API Key). `Invoke-CloudflareApiRequest` arma
`Authorization: Bearer` solo en memoria, nunca lo imprime ni lo devuelve,
y sanitiza errores. Es la vía determinista para todo Apply.

## Pruebas

- `scripts/tests/run-script-tests.ps1`: **32/32 PASS**, verificado de
  forma independiente por la sesión principal (no solo reportado por el
  fork que lo construyó). Mockea `Invoke-CloudflareApiRequest` mediante
  una variable global (`$Global:CloudflareApiRequestMock`) en vez de un
  stub de binario en PATH, porque Cloudflare no tiene CLI propio como
  `az` — cero red, cero Cloudflare real. Sin artefactos residuales en
  `.local/cloudflare/` tras la corrida.
- `hooks/tests/run-hook-tests.ps1`: **52/52 PASS**, también verificado de
  forma independiente. Cada caso invoca el hook real vía stdin JSON
  mockeado.
- Ambas suites: cero llamadas reales a Cloudflare.

## Verificaciones reales ejecutadas durante la implementación

**Ejecutadas el 2026-09-05**, tras el reinicio de sesión y el
consentimiento OAuth del usuario en el navegador (cuenta
`pmontero@grupomontecristo.com`, alcance "Grant access to all accounts"):

- Handshake del MCP oficial `cloudflare-api`: OK.
- Tools reales enumeradas: exactamente `docs`, `search`, `execute`
  (Code Mode) — coincide con el esquema asumido al construir
  `cloudflare-security-gate.ps1` y `references/api-and-mcp.md`; no hizo
  falta corregir nada.
- Cuentas accesibles: `ab5d029b2bb52510fa80b693c36ff61d` (Grupo
  Montecristo) y una cuenta personal del usuario.
- Zonas listadas en Grupo Montecristo: 50 devueltas en la primera página
  (todas `status: active`), incluye `grupomontecristo.com`, `buklo.dev`,
  `gmontecristo.com`, entre otras — no se paginó más allá porque el doc
  solo pide "listar zonas", no un inventario completo.
- Lectura de DNS: zona `grupomontecristo.com` (206 registros totales), se
  leyeron 5 (`type`/`name`/`proxied`/`ttl`), sin exponer `content` (IP/
  valores) ni ningún dato sensible.
- `$env:CLOUDFLARE_API_TOKEN`: `False` (no configurado) — reportado como
  pendiente, no bloqueante; el MCP ya cubre lectura/diagnóstico completo,
  solo haría falta para ejecutar un `Apply-*` real vía REST.
- No se ejecutó una consulta de audit logs/analytics (no había un plan
  activo que la requiriera en esta verificación).
- Cero recursos de prueba creados (DNS, Workers, KV, reglas) en ningún
  caso; cero escrituras reales.

## Pendiente de aprobación

### 1. `.gitignore` — agregar `/.local/cloudflare/`

Igual tratamiento que Azure Resources: el `.gitignore` raíz del proyecto
declara hoy, por decisión explícita del propietario, que no se excluye
ningún archivo del repositorio. Agregar esta línea contradice esa
declaración existente y no se aplicó automáticamente — requiere
confirmación puntual del usuario.

### 2. `CLOUDFLARE_API_TOKEN`

No configurado todavía (ver § Verificaciones reales arriba). Es una
acción del usuario, no algo que se resuelva desde este flujo — solo
necesaria si se quiere usar la vía REST para un Apply real además del
MCP.

## Decisiones de diseño no triviales tomadas durante la implementación

1. **Sin directorio `deviations/`** (a diferencia de Azure): el doc de
   Cloudflare no lo pide y su árbol de `.local/cloudflare/` no lo incluye
   — el drift bloquea el Apply y se reporta inline, sin archivo aparte.
2. **`Cloudflare-Common.ps1` no aparece en el árbol ilustrativo del doc
   original** pero se agregó por ser la convención ya establecida en
   Azure/AKS/ADO de este proyecto (librería compartida dot-sourced) — el
   propio doc pide "adaptar convenciones existentes, no crear arquitectura
   paralela".
3. **`cloudflare-plan-authorization.ps1`/`cloudflare-delete-authorization.ps1`/
   `cloudflare-permission-common.ps1`** tampoco están en el árbol
   ilustrativo del doc, pero implementan el mecanismo que el doc describe
   en prosa ("Apply-CloudflareChangePlan.ps1 puede ejecutar todas las
   operaciones... sin preguntas internas adicionales") — se agregaron por
   consistencia con el resto del proyecto.
4. **Estrategia de prueba offline distinta a Azure**: en vez de un stub de
   binario (`az.cmd`), el harness mockea directamente la función
   `Invoke-CloudflareApiRequest` — mismo patrón que ya usa
   `azure-devops-permissions` para `Invoke-AdoPermissionsRest`, más
   apropiado porque Cloudflare no tiene un CLI propio equivalente a `az`
   para esta vía.
5. **Eliminación lógica de Rulesets — resuelta en dos capas, nunca en el
   hook por sí solo**: `cloudflare-security-gate.ps1` no puede determinar
   de forma estática si un `PUT` a un Ruleset remueve reglas existentes
   (requeriría diffear contra el estado real), así que clasifica CUALQUIER
   escritura a `/rulesets/...` como `ask`; la decisión de si en efecto es
   una eliminación lógica que debe moverse a un delete plan la toma
   `Test-CloudflareChangePlan.ps1` (comparando contra el inventario) y
   `cloudflare-reviewer`.


## Publicar un sitio del cluster prod on-prem `.31` (prod-onprem-01) — regla obligatoria

Confirmado 2026-10-08 al publicar `knowledge-base.grupomontecristo.com`.

Todo hostname nuevo que apunte al cluster **prod on-prem `.31`** (`prod-onprem-01`,
`172.16.2.31`) y deba servirse por internet requiere **DOS pasos en Cloudflare, no
uno**:

1. **DNS** — registro `A → 190.113.100.74 proxied=true`. NO apuntar a
   `172.16.2.31` (IP privada: lo deja interno). `190.113.100.74` es el egress/edge
   NAT del `.31`.
2. **Origin Rule** — agregar el host al ruleset `http_request_origin` de la zona
   `grupomontecristo.com` (zone `8825f873e698947fe47a6bdaafe65a61`, ruleset
   `667e45fc1dce47e8bca14bf203573af7`) con `action=route` y
   `action_parameters.origin.port=4443`. **Compare-and-append**: leer el ruleset,
   agregar solo la regla nueva, preservar las existentes; nunca reemplazar el
   ruleset entero.

**Por qué:** el `.31` **no expone el 443** a internet; el borde escucha en el
puerto **`4443`** y Cloudflare reescribe el puerto de origen por hostname con esa
Origin Rule. Si se crea solo el DNS, Cloudflare intenta el 443 por defecto, no hay
nada escuchando y el sitio responde **521** aunque el DNS, el cert TLS del ingress
y el pod estén perfectos (el origen responde `200` desde dentro del cluster).

**Diagnóstico de un `521` del `.31`:** NO perseguir cert/ingress/pod ni un filtro de
SNI en el borde — verificar PRIMERO que el host tenga su regla `:4443` en el ruleset
`http_request_origin`. Un `503` (no `521`) significa que el edge SÍ conectó al
origen y el backend respondió — ahí sí es la app, no la Origin Rule.

Hosts ya publicados con este patrón: `grafana-onprem-01`, `datahub`,
`cicd-dashboard`, `k8s-hub`, `cluster-onprem-01`, `knowledge-base`.

> Aplica **solo** al cluster on-prem `.31`. El `k3s-dev` (`.43`) y los AKS se
> publican por su propia vía — confirmar contra el inventario en vivo, no asumir
> `4443` para otros clusters.

---

## Publicaciones any2cloud / APIBOT (IIS Windows, NO cluster) — prod y QA

El API **any2cloud / APIBOT** (sitio IIS en Windows, no en k8s) se publica por internet por **DNS-only directo al borde con puerto en la URL**, NO por el proxy de Cloudflare. Se intentó proxied y daba **522 intermitente** (el NAT del borde no permite TODAS las edges de Cloudflare en el puerto del any2cloud, solo algunas → unos clientes 403/200 y otros 522). Por eso la decisión final en ambos ambientes es **DNS-only (nube gris)**: el tráfico va directo del cliente al borde, sin el filtro de edges de CF.

### Regla clave transversal — SNI estricto por hostname

Los bindings IIS de any2cloud son **SNI estricto por hostname** (`netsh http show sslcert` muestra `Hostname:port = <host>:443` con su cert). El cliente DEBE entrar por el **nombre DNS**, nunca por la IP pública cruda: por IP sin SNI, IIS no encuentra binding que matchee y **cierra la conexión → 000**, aunque el NAT esté perfecto. Síntoma de SNI estricto confirmado en QA: `curl https://localhost/...` (sin el nombre) da **000**, pero `curl https://<nombre>/...` da **200**.

### PROD — any2cloud.grupomontecristo.com (server .76 eFlow)

| Campo | Valor |
|---|---|
| Server | `172.16.2.76` (CRSRVSISRDP, IIS eFlow) |
| DNS | `api-bot-any2cloud.grupomontecristo.com` → `190.113.100.74` **DNS-only** |
| URL de acceso | `https://api-bot-any2cloud.grupomontecristo.com:6789/APIBOT/...` |
| NAT borde | `190.113.100.74:6789 → 172.16.2.76:6789` |
| Puerto interno IIS | **6789** (binding propio del sitio any2cloud; HTTPS/TLS 1.3 con cert `*.grupomontecristo.com`) |

**Por qué `:6789` y no `:443` interno:** en el `.76` el `443` lo usan OTROS sitios eFlow (cca/ccaapi). El any2cloud se montó como sitio IIS aparte con binding propio en `*:6789`, así que el NAT es `6789 → 6789` (puerto-a-mismo-puerto). El `6789` interno habla HTTPS (confirmado: TLS 1.3, cert wildcard).

### QA — api-bot-qa-any2cloud.gmontecristo.com (server .243 SRV-UAT-RJ)

| Campo | Valor |
|---|---|
| Server | `172.16.16.243` (SRV-UAT-RJ, segmento UAT `172.16.16.x`) |
| DNS | `api-bot-qa-any2cloud.gmontecristo.com` → `190.171.118.98` **DNS-only** (zona `gmontecristo.com`, egress UAT Telecable AS52263) |
| URL de acceso | `https://api-bot-qa-any2cloud.gmontecristo.com/APIBOT/APIBOT.dll/api/bot/metodos/Health` (**443 limpio, SIN puerto**) |
| NAT borde | `190.171.118.98:443 → 172.16.16.243:443` |
| Puerto interno IIS | **443** (el any2cloud QA SÍ es dueño del 443 interno → URL limpia sin puerto) |
| Estado final | ✅ **200** `{"result":[{"status":"OK","database":"OK"}]}` (2026-10-26) |

**Por qué el QA pudo quedar en `:443` limpio y el prod no:** depende de la config IIS de cada server. En el `.243` any2cloud es dueño del `443` interno (no hay otro sitio peleando el puerto), así que el NAT apunta al `443` y la URL queda sin puerto. En el `.76` el `443` estaba ocupado → se usó `6789`.

### Diagnóstico de la publicación any2cloud (checklist)

1. **`000`/timeout desde una PC externa, IP directa** → el NAT del borde no entrega al server interno en ese puerto (infra: crear/revisar el NAT). Un server **recién migrado** suele perder su NAT viejo (al mover el prod del `.243` al `.76`, el NAT del `.243` quedó sin apuntar).
2. **`SYN_RECEIVED` colgados en el `netstat` del server interno** (de IPs de internet) → el SYN entra pero el handshake no completa = **ruta de retorno asimétrica del NAT** (la respuesta sale por un path que el cliente no reconoce). Infra debe alinear el NAT de retorno. Confirmado en QA el 2026-10-26 y resuelto por infra.
3. **`local 443 SNI → 200` pero `local 443 (localhost) → 000`** → NO es bug, es SNI estricto (ver arriba). El IIS está bien.
4. **522 (solo si está proxied)** → el borde no permite todas las edges de CF en ese puerto → pasar a **DNS-only** (la vía elegida para any2cloud), o pedir a infra abrir todos los rangos de CF.

### Limitación del agente para validar estos servers

- El `.76` sale por el borde `190.113.100.74` (compartido con el `.31`) → el agente desde el hub (`10.1.0.200`) **sí** alcanza ese borde para medir prod.
- El `.243` está en el segmento **`172.16.16.x` (UAT)**, sin ruta desde el hub: toda sonda da **`Connection timed out`** (hay `ip route` pero el firewall hub↔UAT descarta el paquete). **El agente NO puede validar el `.243` por sí mismo** — las validaciones IIS se corren en el propio server (PowerShell) y las de camino público desde una PC externa. Mediciones del agente a estos servers están sesgadas (hairpin / sin ruta): la verdad es el navegador/PC externa.
