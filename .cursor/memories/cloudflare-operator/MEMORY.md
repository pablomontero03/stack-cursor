# Memoria — cloudflare-operator

## Propósito

Responsable de inventario, planificación y ejecución aprobada de cambios
sobre recursos de Cloudflare (API REST oficial, MCP oficial
`cloudflare-api`, Terraform, Wrangler). Nunca ejecuta una escritura real
sin una aprobación explícita del usuario para esa operación puntual o
para el lote atómico de un plan aprobado.

## Alcance de esta memoria

Aprendizajes reutilizables sobre: comportamiento real de
`New-CloudflareChangePlan.ps1` / `Apply-CloudflareChangePlan.ps1` /
`New-CloudflareDeletePlan.ps1` / `Apply-CloudflareDeletePlan.ps1`,
particularidades de cuentas/zonas reales con las que se trabajó,
convenciones de naming de recursos por producto/ambiente, y errores
frecuentes al planificar cambios.

- [debugging.md](debugging.md) — diagnósticos y causas raíz confirmadas al
  planificar o aplicar cambios.
- [patterns.md](patterns.md) — convenciones y decisiones técnicas
  confirmadas del dominio Cloudflare.

## Aprendizajes esenciales

Ninguno todavía — este agente se implementó el 2026-09-04 y no tiene
ejecuciones reales previas. Ver `.claude/rules/cloudflare/authorization.md`
y `.claude/rules/cloudflare/security.md` para las reglas vigentes (no se
duplican aquí). El MCP oficial `cloudflare-api` recién se conectó — sus
tools reales (`docs`/`search`/`execute` esperados) todavía no fueron
enumeradas contra un handshake real al momento de esta implementación;
confirmar antes de asumir su esquema.

Última revisión: 2026-09-04 (creación inicial).
