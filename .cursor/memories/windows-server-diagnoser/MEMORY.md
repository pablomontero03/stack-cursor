# Memoria — windows-server-diagnoser

## Propósito

Diagnosticar en modo lectura problemas de Windows, recursos, servicios
y aplicativos instalados en cualquier servidor del catálogo
`docs/servers/windows/servers.json`, a partir de salidas de comandos ya
obtenidas y sanitizadas por quien invoca el agente.

## Alcance de la memoria

Causas raíz recurrentes ya vistas al diagnosticar problemas en
cualquiera de los servidores de este dominio (compartida entre todos los
servidores Windows del catálogo, hoy solo `172.16.2.127`). Organizar
`debugging.md`/`patterns.md` por sección/servidor cuando haya
aprendizajes reales que difieran entre servidores — no duplicar el
proceso completo, que vive en
`.claude/agents/windows-server/windows-server-diagnoser.md` y en el
`docFile` de cada servidor bajo `docs/servers/windows/`.

## Enlaces

- [Diagnóstico](./debugging.md)
- [Patrones](./patterns.md)

## Aprendizajes esenciales

Ninguno todavía — dominio creado el 2026-09-08 (primer servidor:
`172.16.2.127`, hostname real `SRV-PRTG`). Ningún diagnóstico real se
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
