# Respaldos y rollback

Cargar en modo `backup-rollback`.

## Qué respaldar antes de modificar o eliminar (cuando sea posible)

- Registros DNS y configuración de zona.
- Rulesets completos, orden, fases y expresiones.
- Configuración SSL/TLS y certificados **sin claves privadas**.
- Worker script, versión, rutas, bindings y **nombres** de secrets (nunca
  valores).
- Configuración de Pages y dominios.
- Configuración de Access, Gateway y Tunnels.
- Configuración de balanceadores, pools y health monitors.
- Metadatos y configuración de KV, R2, D1 y Queues (nunca datos completos
  por defecto).

Todo respaldo va a `.local/cloudflare/backups/` (no versionado), como JSON
sanitizado (pasado por `Find-CloudflareSensitiveJsonProperties`/
`Find-CloudflareSensitiveRawText` antes de escribirse).

## Antes de eliminar

`Apply-CloudflareDeletePlan.ps1` escribe siempre el respaldo de solo
lectura del recurso **antes** de cualquier DELETE real. Un respaldo
fallido o vacío detiene esa eliminación puntual. Si una eliminación afecta
datos (R2/KV/D1) y no existe backup real de esos datos, advertir
explícitamente que la recuperación puede ser imposible — no asumir que
"algo" queda recuperable.

## Rollback — nunca automático

`Invoke-CloudflareRollback.ps1`:

1. Recibe un plan (change o delete) ya aplicado.
2. Para cada operación completada, arma una operación inversa candidata
   usando el `currentState`/respaldo capturado antes del cambio original
   (ej. `delete` → recrear con el estado previo como `desiredState`;
   `update` → revertir al `currentState` guardado).
3. Cuando no se puede inferir automáticamente la operación inversa, la
   marca explícitamente como pendiente (`argv: ["__PENDIENTE__"]` o
   `body: {"__PENDIENTE__": true}`) — nunca inventa un valor.
4. Arma esa propuesta como un plan NUEVO (`New-CloudflareChangePlan.ps1`/
   `New-CloudflareDeletePlan.ps1` según corresponda) y la **muestra** —
   nunca la valida ni la aplica por su cuenta.

Aplicar un rollback exige el flujo completo de `change-workflow.md`/
`deletion-workflow.md` con su propia aprobación nueva y separada de la
del cambio original — un rollback también modifica recursos reales y
puede introducir su propia indisponibilidad.
