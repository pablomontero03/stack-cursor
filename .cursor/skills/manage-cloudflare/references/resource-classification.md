# Clasificación de recursos y operaciones

Cargar en modo `classify`. Implementado en `cloudflare-security-gate.ps1`
— este documento es la referencia legible, el hook es la fuente ejecutable
(deben mantenerse sincronizados).

## Lecturas automáticas

- `GET`/`HEAD` contra `api.cloudflare.com` con scope explícito.
- `POST` a un endpoint `/graphql` cuyo `query` no contenga `mutation`.
- `docs`/`search` del MCP oficial; `execute` de solo lectura (ver
  `api-and-mcp.md`).
- Listar cuentas, zonas, DNS, Rulesets, Workers, Pages, KV/R2/D1/Queues,
  Tunnels, Access, Gateway, balanceadores, configuración, analytics,
  audit logs, logs sanitizados, health y estado.
- `terraform plan|validate|fmt -check|show` sin apply.
- `wrangler whoami|tail|deployments list|kv:key list|kv:namespace
  list|d1 list|pages deployment list|secret list` (nombres, no valores).

## Requiere aprobación (no destructivo)

- Cualquier `POST`/`PUT`/`PATCH` que no caiga en "eliminación lógica" de
  abajo, dirigido a crear o modificar un recurso real.
- `terraform apply` (sin evidencia de que destruya recursos).
- `wrangler deploy|publish|pages deploy|d1 execute` (no se puede verificar
  desde texto si un `d1 execute` es un `SELECT` seguro — siempre pregunta).
- `execute` del MCP con escritura no clasificable como GraphQL de solo
  lectura.

## Eliminación — siempre aprobación destructiva separada

Clasificar por EFECTO, no solo por verbo HTTP (ver
`.claude/rules/cloudflare/security.md` § Eliminación lógica para la lista
completa). Patrones reconocidos estáticamente por el hook:

| Patrón | Clasificación |
|--------|---------------|
| Cualquier `DELETE` HTTP | Eliminación |
| `POST .../purge_cache` | Eliminación (purga contenido almacenado) |
| `PUT`/`POST` a un path que contenga `/rulesets` | Eliminación potencial — no se puede verificar de forma estática si remueve reglas; el hook pregunta siempre, el flujo de plan exige mover a `pendingDeleteOperations` si de verdad remueve entradas |
| `terraform destroy`, o `apply` con evidencia de destruir recursos | Eliminación |
| `wrangler delete`, `kv:key delete`, `kv:namespace delete`, `d1 delete`, `secret delete` | Eliminación |
| Revocar un token, certificado o acceso | Eliminación |
| Desvincular un custom domain, route, binding, hostname o integración | Eliminación |

## Secretos — siempre `ask`

Aunque el verbo sea `GET` (formalmente "lectura"): descargar Origin CA
private keys, valores de Worker secrets (si existiera tal endpoint),
certificados con clave privada, o cualquier endpoint que devuelva un
token/credencial en texto plano.

## Operación no reconocida

Un endpoint, método, tool MCP o subcomando de Terraform/Wrangler que no
encaje con certeza en ninguna fila de arriba siempre resuelve a `ask` —
nunca se asume lectura ni se bloquea de forma permanente.
