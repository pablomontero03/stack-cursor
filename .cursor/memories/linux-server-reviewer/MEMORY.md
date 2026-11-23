# Memoria — linux-server-reviewer

## Propósito

Revisión independiente, solo lectura, de cambios de configuración,
instalaciones/actualizaciones y reinicios propuestos para cualquier
servidor del catálogo `docs/servers/servers.json`, antes de que se le
pida aprobación al usuario.

## Alcance de la memoria

Hallazgos recurrentes y falsos positivos identificados al revisar
cambios propuestos para cualquiera de los servidores de este dominio
(compartida entre los 5 servidores actuales: `172.16.2.60`,
`172.16.2.43`, `10.1.0.200`, `172.16.2.31`, `openedx`, y los que se
agreguen al catálogo). No duplica el checklist completo, que vive en
`.claude/agents/linux-server/linux-server-reviewer.md`.

## Enlaces

- [Diagnóstico](./debugging.md)
- [Patrones](./patterns.md)

## Aprendizajes esenciales

Ninguno todavía — este agente se generalizó el 2026-09-08 (antes
`172.16.2.60-reviewer`, específico de un solo servidor) al agregar 4
servidores nuevos al dominio. Ninguna revisión real se corrió todavía
sobre ninguno de los 5 servidores del catálogo con este agente.

Última revisión: 2026-09-08 (generalización a multi-servidor).
