---
name: manage-cloudflare
description: Administra Cloudflare via MCP oficial y API REST: DNS, WAF, Workers, Pages, Zero Trust, Tunnels, SSL, Cache, Rulesets, KV, R2, D1 y Load Balancing.
triggers: [cloudflare, dns, waf, workers, pages, zero trust, tunnel, ssl, cache, ruleset]
always: false
---

# Manage Cloudflare

Dominio separado de Azure Resources, AKS/Kubernetes/Helm, Azure DevOps
Pipelines/Permissions, Schema Sync, n8n y `manage-linux-servers` — sin
scripts, hooks, agentes, memoria ni datos transitorios compartidos con
ninguno de ellos.

## Regla de oro de este dominio

Lectura/inventario/diagnóstico/simulación son automáticos; toda escritura
real (creación/modificación) exige una sola aprobación por plan completo;
toda eliminación —incluida la eliminación lógica por efecto (purga de
cache, reemplazo de Ruleset que remueve reglas, desvincular un binding,
revocar un token, `terraform destroy`, `wrangler delete`)— exige siempre
su propia aprobación separada; nada queda prohibido de forma permanente
salvo lo listado en `.cursor/rules/cloudflare/security.md` § Prohibido
permanentemente — un endpoint, comando o tool MCP no reconocido siempre
resuelve a "preguntar", nunca a "denegar". Ver detalle completo en
`.cursor/rules/cloudflare/authorization.md` y `security.md`.

## Estado del MCP oficial `cloudflare-api`

`type: "http"`, `url: "https://mcp.cloudflare.com/mcp"`, agregado a
`.mcp.json`. Usa OAuth del lado del cliente — la primera vez que se
invoque, el usuario debe completar el consentimiento en el navegador
(elegir cuenta y permisos). No se inventan nombres de tools antes del
handshake real: el esquema esperado es `docs`/`search`/`execute` (MCP Code
Mode, ver `references/api-and-mcp.md`), pero debe reconfirmarse contra la
conexión real antes de asumir cualquier comportamiento no probado.

La API REST oficial (`https://api.cloudflare.com/client/v4/`, vía
`$env:CLOUDFLARE_API_TOKEN`) es la vía determinista para todo Apply — ver
`references/connections-and-authentication.md`.

## Cargar solamente el contexto necesario

No cargar todas las referencias de una. Cargar según el modo (tabla
abajo). Nunca duplicar su contenido en este archivo ni en la respuesta al
usuario — referenciarlas por ruta.

## Enrutamiento de modos

| Modo | Cuándo | Referencia a cargar |
|------|--------|----------------------|
| `auth` | Verificar sesión OAuth del MCP, o si `$env:CLOUDFLARE_API_TOKEN` existe | `references/connections-and-authentication.md` |
| `classify` | Decidir si un endpoint REST/comando Terraform-Wrangler/tool MCP concreto es automático o exige aprobación | `references/resource-classification.md` |
| `inventory` | Inventariar cuentas/zonas/recursos | `Get-CloudflareInventory.ps1` (sin referencia dedicada, es autoexplicativo) |
| `plan` | Armar/validar un plan de cambio antes de aplicar | `references/change-workflow.md` (delegar a `cloudflare-operator`, revisar con `cloudflare-reviewer`) |
| `delete` | Armar/validar/aplicar una eliminación | `references/deletion-workflow.md` — siempre aprobación separada |
| `dns-tls` | DNS, DNSSEC, SSL/TLS, certificados, Origin CA, mTLS | `references/dns-and-certificates.md` |
| `security` | WAF, rate limiting, Bot Management, Zero Trust, Access, Gateway, Tunnels | `references/security-and-zero-trust.md` |
| `workers-storage` | Workers, Pages, KV, R2, D1, Queues, Durable Objects, Vectorize, Workflows | `references/workers-and-storage.md` |
| `apply` | Aplicar un plan ya aprobado, o hacer readback | `references/change-workflow.md` § Apply |
| `backup-rollback` | Preparar un respaldo o una propuesta de rollback | `references/backup-and-rollback.md` |
| `diagnose` | Un recurso falla o se comporta raro | delegar a `cloudflare-diagnoser` |

## Flujo de decisión rápido

1. ¿Es lectura/inventario/GraphQL de solo lectura/`docs`/`search`/
   `execute` de solo lectura/simulación Terraform/Wrangler de lectura? →
   ejecutar directo, sin pedir aprobación (ver
   `references/resource-classification.md`).
2. ¿Es una eliminación, explícita (`DELETE`) o lógica por efecto (purga de
   cache, Ruleset que remueve reglas, desvincular binding, revocar
   token/certificado, `terraform destroy`, `wrangler delete`)? → siempre
   su propia aprobación, nunca agrupada con el plan principal (ver
   `references/deletion-workflow.md`).
3. ¿Es cualquier otra escritura real (crear/actualizar recurso, `POST`/
   `PUT`/`PATCH` no clasificado como lectura)? → flujo completo de
   `references/change-workflow.md` — aprobación explícita antes de
   ejecutar, cubre todo el lote no destructivo del plan.
4. ¿Involucra un secreto (Worker secret, Origin CA private key, valor de
   token, certificado con clave privada)? → preguntar siempre, evitar si
   no es indispensable.
5. ¿El endpoint, comando o tool no encaja claramente en ninguna categoría
   anterior? → preguntar. Nunca asumir lectura, nunca bloquear
   permanentemente.

## Agentes de este dominio

- **`cloudflare-operator`** (`.cursor/agents/cloudflare-operator.md`):
  inventario, planificación y ejecución aprobada de cambios.
- **`cloudflare-diagnoser`** (`.cursor/agents/cloudflare-diagnoser.md`):
  diagnóstico de solo lectura (DNS, propagación, TLS, WAF, cache, Workers,
  Pages, Zero Trust, Tunnels, balanceadores, logs, analytics); deriva
  cualquier corrección al flujo de plan.
- **`cloudflare-reviewer`** (`.cursor/agents/cloudflare-reviewer.md`):
  revisión independiente de un plan antes de aplicarlo; nunca aprueba en
  nombre del usuario.

## Scripts (`scripts/`)

| Script | Uso | Requiere aprobación |
|--------|-----|----------------------|
| `Cloudflare-Common.ps1` | Librería compartida (hash de plan, journal, contexto de cuenta, `Invoke-CloudflareApiRequest`, escaneo de secretos) — dot-sourced, nunca se ejecuta directo | — |
| `Test-CloudflareEnvironment.ps1` | Diagnóstico de token/MCP/conectividad de solo lectura | No |
| `Invoke-CloudflareRead.ps1` | Wrapper que exige `GET`/`HEAD` | No |
| `Get-CloudflareInventory.ps1` | Inventario sanitizado de cuentas/zonas/DNS | No |
| `New-CloudflareChangePlan.ps1` | Genera un plan de cambio inmutable (sin validar) | No |
| `Test-CloudflareChangePlan.ps1` | Valida un plan (secretos, forma, drift, GraphQL) y lo marca `validated=true` | No |
| `Apply-CloudflareChangePlan.ps1` | **Único** script que ejecuta escrituras reales no destructivas | **Sí** — el hook pregunta por su nombre (o reusa una aprobación visible ≤24h) |
| `New-CloudflareDeletePlan.ps1` | Genera un plan de eliminación separado | No |
| `Test-CloudflareDeletePlan.ps1` | Valida un delete plan (recursos concretos, inventario reciente) | No |
| `Apply-CloudflareDeletePlan.ps1` | **Único** script que ejecuta eliminaciones reales | **Sí, siempre separada** de la del plan principal |
| `Test-CloudflarePostChange.ps1` | Readback tras aplicar (no destructivo o destructivo) | No |
| `Resolve-CloudflareDnsRecord.ps1` | Clasifica un FQDN deseado contra el estado real: `to_create`/`reuse`/`conflict` (usado también por `orchestrate-application-pipeline-cycle`) | No |
| `Invoke-CloudflareRollback.ps1` | Prepara y muestra (nunca ejecuta) una propuesta de rollback como plan nuevo | No — pero aplicar ese rollback exige el flujo completo con aprobación nueva |

## Rutas locales (`.local/cloudflare/`, no versionado)

`inventory/`, `plans/`, `delete-plans/`, `backups/` (respaldo pre-delete),
`executions/` (journal de aplicación), `reports/`, `logs/`. Ver
`.cursor/rules/cloudflare/security.md` § Archivos locales para el estado
pendiente de aprobación del `.gitignore`.

## Fuentes de verdad de este dominio

- Autorización y seguridad: `.cursor/rules/cloudflare/authorization.md` y
  `.cursor/rules/cloudflare/security.md`.
- Arquitectura completa: `docs/cloudflare/CLOUDFLARE-AUTOMATION-ARCHITECTURE.md`.
- Especificación original: `INSTRUCCIONES-AUTOMATIZACION-CLOUDFLARE.md`
  (raíz del proyecto).
- Referencias oficiales de Cloudflare (no copiar manuales completos aquí,
  consultar la documentación vigente cuando una operación lo requiera):
  MCP oficial `https://mcp.cloudflare.com/mcp`, API oficial
  `https://developers.cloudflare.com/api/`, Terraform Provider
  `https://developers.cloudflare.com/terraform/`.
