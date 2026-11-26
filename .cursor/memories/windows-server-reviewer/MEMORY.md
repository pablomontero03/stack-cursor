# Memoria — windows-server-reviewer

## Propósito

Revisión independiente, solo lectura, de cambios de configuración,
instalaciones/actualizaciones y reinicios propuestos para cualquier
servidor del catálogo `docs/servers/windows/servers.json`, antes de que
se le pida aprobación al usuario.

## Alcance de la memoria

Hallazgos recurrentes y falsos positivos identificados al revisar
cambios propuestos para cualquiera de los servidores de este dominio
(compartida entre todos los servidores Windows del catálogo, hoy solo
`172.16.2.127`). No duplica el checklist completo, que vive en
`.claude/agents/windows-server/windows-server-reviewer.md`.

## Enlaces

- [Diagnóstico](./debugging.md)
- [Patrones](./patterns.md)

## Aprendizajes esenciales

Ninguno todavía — dominio creado el 2026-09-08 (primer servidor:
`172.16.2.127`, hostname real `SRV-PRTG`). Ninguna revisión real se
corrió todavía con este agente.

Última revisión: 2026-09-08 (creación inicial).

## Regla operacional: no ejecutar setup.sh de Kiro
Confirmado en producción 2026-09-21. No ejecutar `setup-kiro.sh`. `./setup-cursor.sh` no reinicia el worker.

**Siempre usar en sesiones activas de Crew:**
```bash
set -a; source /home/cursor/stack-cursor/env/.env; set +a
export REPO_ROOT=/home/cursor/stack-cursor
```
O con el flag seguro: `set -a; source env/.env; set +a`

No ejecutar `source ./setup.sh`. Para variables: `set -a; source env/.env; set +a`.
