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
