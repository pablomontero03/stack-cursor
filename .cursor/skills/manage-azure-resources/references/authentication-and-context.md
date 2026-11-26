# Autenticación y contexto

Cargar al verificar la sesión de Azure CLI, o al decidir si hace falta
pedirle al usuario que corra `az login`.

## Resolución de sesión

1. `Get-AzureAccountContext` (`Azure-Common.ps1`) ejecuta `az account
   show` (con `--subscription <id>` si se especificó) y devuelve
   sanitizado: `tenantId`, `subscriptionId`, `subscriptionName`,
   `userName`, `userType`, `environmentName`, `isDefault`.
2. Si no hay sesión activa o expiró, `Get-AzureAccountContext` devuelve
   `$null` — **nunca** se ejecuta `az login` automáticamente. Se reporta
   al usuario y se le pide que lo corra manualmente en su propia terminal.
3. Nunca se lee ni copia contenido de `%USERPROFILE%\.azure` (tokens
   cacheados por MSAL). La única forma de consultar la sesión es `az
   account show`/`az account list`, nunca leyendo el cache directamente.

## Multi-tenant / multi-suscripción

- Cada operación del plan lleva `tenantId` y `subscriptionId` explícitos
  — nunca se asume "la suscripción activa" para una escritura real.
- Usar `--subscription <ID>` explícito en cada comando `az` que lo
  soporte, en vez de `az account set` (que cambia el estado global de la
  sesión del usuario de forma persistente e implícita — evitarlo salvo
  que el usuario lo pida y apruebe explícitamente; `azure-security-gate.ps1`
  clasifica `az account set` como `ask`).
- Si el usuario tiene acceso a varios tenants/suscripciones y la
  solicitud no especifica cuál, preguntar antes de inventariar o
  planificar — nunca adivinar.

## Antes de aplicar cualquier plan

`Apply-AzureChangePlan.ps1` / `Apply-AzureDeletePlan.ps1` vuelven a
consultar `Get-AzureAccountContext` con el `subscriptionId` del plan y
comparan el `tenantId` real contra el del plan — si no coinciden (la
sesión cambió desde que se generó el plan), se rechaza sin tocar Azure.
Esto es una capa de seguridad automática, no requiere que el usuario lo
pida.

## Estado del MCP `azure`

Diferido — ver `.cursor/rules/azure.mdc` (sección Estado del MCP
`azure`). `Test-AzureEnvironment.ps1` siempre reporta
`mcpAzure.configured = false` con una nota explicativa; no intentar
conectar ni invocar ninguna tool `mcp__azure__*` mientras `.mcp.json` no
lo declare.
