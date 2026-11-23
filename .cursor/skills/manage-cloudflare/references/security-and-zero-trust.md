# Seguridad de borde y Zero Trust

Cargar en modo `security`. Cubre: WAF (reglas administradas y
personalizadas), rate limiting, DDoS, Bot Management, Redirect Rules,
Transform Rules, Page Rules, Rulesets, Zero Trust (Access, Gateway, WARP,
posture checks), Cloudflare Tunnels y sus rutas.

## Lectura (automática)

Listar Rulesets y sus fases, reglas WAF activas, políticas de rate
limiting, configuración de Bot Management, políticas de Access y Gateway,
dispositivos WARP enrolados, Tunnels y sus rutas configuradas, logs y
eventos de seguridad.

## Escritura (aprobación del plan principal)

Crear/modificar una regla WAF, una Redirect/Transform Rule, una política
de rate limiting, una política de Access o Gateway, una ruta de Tunnel.
**Reemplazar un Ruleset completo** entra en esta categoría SOLO si el
nuevo contenido preserva todas las reglas existentes (agrega o modifica
sin remover) — si remueve alguna regla existente, es una eliminación
lógica (ver `deletion-workflow.md`) y exige la aprobación separada.

## Eliminación (aprobación separada, incluida la lógica)

- Eliminar una regla WAF, una política de Access/Gateway, una ruta de
  Tunnel.
- Reemplazar un Ruleset omitiendo reglas existentes.
- Revocar un dispositivo WARP o una sesión de Access.
- `terraform destroy`/`wrangler delete` sobre cualquier recurso de este
  dominio.

## Notas de clasificación

`cloudflare-security-gate.ps1` no puede determinar de forma estática, solo
mirando el body de un `PUT`, si un reemplazo de Ruleset remueve reglas
respecto al estado real — por eso clasifica CUALQUIER `PUT`/`POST` a
`/rulesets/...` como `ask` (nunca `allow` automático), y es
`Test-CloudflareChangePlan.ps1` + `cloudflare-reviewer` quienes deben
comparar contra el inventario real antes de aprobar, moviendo la operación
a `pendingDeleteOperations` si de verdad remueve entradas.
