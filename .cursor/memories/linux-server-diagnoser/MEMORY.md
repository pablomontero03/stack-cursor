# Memoria — linux-server-diagnoser

## Propósito

Diagnosticar en modo lectura problemas de Linux, recursos, servicios,
Docker/systemd y aplicativos instalados en cualquier servidor del
catálogo `docs/servers/servers.json`, a partir de salidas de comandos ya
obtenidas y sanitizadas por quien invoca el agente.

## Alcance de la memoria

Causas raíz recurrentes ya vistas al diagnosticar problemas en
cualquiera de los servidores de este dominio (compartida entre los 5
servidores actuales: `172.16.2.60`, `172.16.2.43`, `10.1.0.200`,
`172.16.2.31`, `openedx`, y los que se agreguen al catálogo). Organizar
`debugging.md`/`patterns.md` por sección/servidor cuando haya
aprendizajes reales que difieran entre servidores — no duplicar el
proceso completo, que vive en
`.claude/agents/linux-server/linux-server-diagnoser.md` y en el
`docFile` de cada servidor bajo `docs/servers/`.

## Enlaces

- [Diagnóstico](./debugging.md)
- [Patrones](./patterns.md)

## Aprendizajes esenciales

Ninguno todavía — este agente se generalizó el 2026-09-08 (antes
`172.16.2.60-diagnoser`, específico de un solo servidor) al agregar 4
servidores nuevos al dominio. Ningún diagnóstico real se corrió todavía
sobre ninguno de los 5 servidores del catálogo con este agente.

Última revisión: 2026-09-08 (generalización a multi-servidor).

## Regla operacional: no ejecutar setup.sh de Kiro
Confirmado en producción 2026-09-21. No ejecutar `setup-kiro.sh`. `./setup-cursor.sh` no reinicia el worker.

**Siempre usar en sesiones activas de Crew:**
```bash
set -a; source /home/cursor/stack-cursor/env/.env; set +a
export REPO_ROOT=/home/cursor/stack-cursor
```
O con el flag seguro: `set -a; source env/.env; set +a`

No ejecutar `source ./setup.sh`. Para variables: `set -a; source env/.env; set +a`.


## OpenEdX prod vs dev (incidente 2026-11-12)
- `135.119.204.153` = `vm-openEdx` **PRODUCCIÓN** (RG `OPENEDX`, priv `10.0.0.6`, llave `keyopenedx.pem`). `vm-openEdx-dev` (RG `OPENEDX-DESARROLLO`) = `10.2.1.132`, SIN IP pública, llave `keyopenedx-dev.pem`. Nunca mezclarlos.
- Si `az vm list-ip-addresses` no da IP pública para la VM pedida, DETENERSE y verificar con `az vm list -d` y `hostname -I`; no usar una IP recordada.
- Antes de cualquier acción que modifique (truncate, prune, vacuum), confirmar el host con `hostname -I` y decir en voz alta cuál es (prod/dev). En prod, pedir OK explícito.
- Dev se mide sin llave con `az vm run-command invoke ... RunShellScript` (solo lectura).
