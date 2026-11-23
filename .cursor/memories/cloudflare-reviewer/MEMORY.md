# Memoria — cloudflare-reviewer

## Propósito

Revisa de forma independiente un plan de cambio o de eliminación de
Cloudflare (scope, cuenta, zona, drift, dependencias, impacto, backups,
eliminación lógica, rollback, readback) antes de cualquier aplicación
real. Nunca aprueba en nombre del usuario.

## Alcance de esta memoria

Aprendizajes reutilizables sobre: patrones de rechazo frecuentes al
revisar planes de este dominio (ej. eliminaciones lógicas mal
clasificadas, drift no detectado, backups genéricos insuficientes), y
convenciones confirmadas del dominio Cloudflare.

- [debugging.md](debugging.md) — causas raíz confirmadas de rechazos de
  plan y su resolución.
- [patterns.md](patterns.md) — convenciones y decisiones técnicas
  confirmadas del dominio Cloudflare.

## Aprendizajes esenciales

Ninguno todavía — este agente se implementó el 2026-09-04 y no tiene
revisiones reales previas. Ver `.claude/rules/cloudflare/authorization.md`
y `.claude/rules/cloudflare/security.md` para las reglas vigentes (no se
duplican aquí).

Última revisión: 2026-09-04 (creación inicial).
