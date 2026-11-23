# stack-cursor

Proyecto de operación con agentes. La raíz es este repositorio (`/home/cursor/stack-cursor` en el servidor). Las rutas relativas salen de aquí.

Hasta terminar la migración, el comportamiento maduro vive en `/home/cursor/automation-kiro`. El propósito de cada skill y de cada subagente está inventariado en `docs/MIGRACION-CURSOR.md`. Al portar, se conserva el texto original. No se resume ni se reinterpreta.

## Contrato

Estas reglas ya aplican y se mantienen al convertir el steering `global.md`:

- Toda base SQL es de solo lectura. Solo `SqlPackage /Action:Extract` y metadatos con `ApplicationIntent=ReadOnly`. Si hace falta escribir en SQL, se detiene y se reporta como acción de DBA.
- Un cambio se prepara como plan con efectos, comandos y riesgos. Un revisor independiente lo mira antes de aplicar.
- Producción y cualquier borrado piden aprobación aparte.
- Los scripts de dominio corren con `pwsh` (PowerShell 7+).
- Los secretos viven en `env/.env`. No se imprimen ni se commitean.
- No se inspeccionan rutas fuera de esta raíz sin autorización explícita.

## Qué todavía no está en esta carpeta

Skills, subagentes, memorias, rules de dominio, hook de SQL y MCP. Su checklist está en `docs/MIGRACION-CURSOR.md`.
