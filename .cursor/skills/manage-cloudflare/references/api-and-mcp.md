# API y MCP — prioridad de herramientas y Code Mode

Cargar en modo `classify` junto con `resource-classification.md`.

## Prioridad de herramientas

1. MCP oficial para documentación, descubrimiento y lecturas compatibles.
2. API REST oficial para inventarios deterministas y todas las
   aplicaciones de planes.
3. GraphQL Analytics para estadísticas de lectura.
4. Terraform para infraestructura declarativa y versionable cuando el
   repositorio ya lo use o el usuario lo solicite.
5. Wrangler para Workers/Pages y productos compatibles cuando aporte
   validación o despliegue reproducible.

Nunca usar REST, Terraform o Wrangler para eludir una decisión de
seguridad del MCP o de un hook.

## MCP Code Mode

El MCP oficial puede exponer `search` y `execute`, donde `execute` recibe
código que llama endpoints de Cloudflare. Esquema esperado (a confirmar
contra el handshake real, ver `connections-and-authentication.md`):

| Tool | Clasificación |
|------|---------------|
| `docs` | Lectura permitida |
| `search` | Lectura permitida |
| `execute` — solo `GET`/`HEAD` a endpoints permitidos | Lectura permitida |
| `execute` — GraphQL con `query`, sin `mutation`, variables sanitizadas | Lectura permitida |
| `execute` — `POST`/`PUT`/`PATCH`/`DELETE`, método dinámico, URI dinámica, o código no clasificable | `ask` |
| `execute` — acceso a secrets/token/headers/credenciales | `ask` |
| Cualquier tool `mcp__cloudflare-api__*` no enumerada arriba | `ask` — nunca asumir lectura de un tool no reconocido |

`cloudflare-security-gate.ps1` implementa esta tabla de forma best-effort
(inspección simple del código recibido por `execute`, sin un sandbox de
ejecución) — cualquier caso no clasificable con certeza cae a `ask`, nunca
a `allow`.

## Escrituras: preferir el aplicador REST, no MCP abierto

Las escrituras planificadas deben ejecutarse preferentemente mediante
`Apply-CloudflareChangePlan.ps1`/`Apply-CloudflareDeletePlan.ps1` (REST
determinista), no mediante `execute` del MCP. Esto permite una sola
aprobación por plan completo y verificación exacta por hash — un `execute`
con escritura abierta no tiene ese mecanismo de plan/hash/journal.

Un cambio pequeño y puntual directo mediante MCP (sin generar un plan
formal) sigue siendo posible, pero exige: aprobación explícita mostrando
cuenta, zona, método, endpoint, recurso e impacto esperado, y readback
posterior. Esa aprobación nunca queda vigente para un cambio distinto —
no se convierte en un permiso permanente para `execute` con escritura.
