# Conexiones y autenticación

Cargar en modo `auth`.

## 1. MCP oficial `cloudflare-api`

Declarado en `.mcp.json`:

```json
{
  "mcpServers": {
    "cloudflare-api": {
      "type": "http",
      "url": "https://mcp.cloudflare.com/mcp"
    }
  }
}
```

Streamable HTTP en `/mcp` — nunca la URL histórica `/sse`, nunca un MCP
propio desplegado por este dominio. Usa OAuth: la primera vez que se
invoque una tool de `cloudflare-api` en una sesión nueva, el cliente abre
la autorización de Cloudflare para que el usuario elija cuenta y permisos.
Claude no crea ninguna aplicación OAuth propia — no es necesaria para
conectarse al MCP oficial.

Después de configurar (o al reconectar):

1. Reiniciar/recargar Claude Code.
2. Confirmar que `cloudflare-api` aparece conectado
   (`claude mcp list`/`claude mcp get cloudflare-api`).
3. Enumerar los nombres y esquemas reales de las tools expuestas — no
   asumir que son exactamente `docs`/`search`/`execute` hasta confirmarlo.
4. Si difieren del esquema esperado (MCP Code Mode, ver
   `resource-classification.md`), actualizar esa referencia y
   `cloudflare-security-gate.ps1` antes de asumir cualquier comportamiento
   nuevo.
5. Realizar únicamente una consulta real de lectura para confirmar (ver
   `SKILL.md` y el doc original § "Verificación real permitida al
   finalizar").

## 2. API REST oficial

Base: `https://api.cloudflare.com/client/v4/`. Vía determinista para todo
Apply (creación/modificación/eliminación) y fallback de lectura cuando el
MCP no cubra una necesidad.

Autenticación: `$env:CLOUDFLARE_API_TOKEN` únicamente. Nunca Global API
Key. El helper `Invoke-CloudflareApiRequest`
(`scripts/Cloudflare-Common.ps1`) lee el token internamente, arma
`Authorization: Bearer ...` solo en memoria del proceso, nunca lo
imprime, nunca lo devuelve, y sanitiza cualquier mensaje de error antes de
propagarlo.

Usar API Tokens con privilegios mínimos, limitados por cuenta, zona,
recursos y vigencia cuando sea posible. Si una operación falla por falta
de permiso, reportar exactamente la operación y el permiso faltante — no
ampliar el token automáticamente ni sugerir uno más amplio sin
confirmarlo con el usuario primero.

## Independencia de las dos vías

La conexión MCP (OAuth) y la API REST (token) son completamente
independientes. Si una falla, nunca se sustituye por credenciales de la
otra — un fallo de OAuth no se resuelve "probando con el token", y un
fallo de token no se resuelve "usando la sesión OAuth del MCP para
escribir directamente" (las escrituras siempre pasan por los aplicadores
REST, nunca por MCP Code Mode abierto).

## Verificación de entorno

`Test-CloudflareEnvironment.ps1` reporta, sin fallar si falta algo:

- Si `$env:CLOUDFLARE_API_TOKEN` existe (booleano, nunca el valor).
- Si `.mcp.json` declara `cloudflare-api` (lectura del archivo, no
  ejecuta nada).
- Si hay conectividad de solo lectura contra
  `GET /client/v4/user/tokens/verify` (endpoint oficial que solo confirma
  validez del token, sin exponer nada sensible) — solo si el token existe.

Si falta `CLOUDFLARE_API_TOKEN`, reportarlo como pendiente. Nunca pedirle
al usuario que lo pegue directamente en el chat — indicar que debe
configurarse como variable de entorno (o el almacén local seguro que
prefiera: PowerShell SecretStore, Windows Credential Manager) fuera de
este flujo.
