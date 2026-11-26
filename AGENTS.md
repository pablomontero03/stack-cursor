# stack-cursor

Proyecto de operación con agentes. La raíz es este repositorio (`/home/cursor/stack-cursor` en el servidor). Las rutas relativas salen de aquí.

El comportamiento de operación es el de esta carpeta. `automation-kiro` queda como origen, no como lugar de trabajo. Antes de actuar en un dominio se sigue `.cursor/rules/antes-de-actuar.mdc`: skill, memoria y docs, en ese orden.

## Contrato

Estas reglas ya aplican y se mantienen al convertir el steering `global.md`:

- Toda base SQL es de solo lectura. Solo `SqlPackage /Action:Extract` y metadatos con `ApplicationIntent=ReadOnly`. Si hace falta escribir en SQL, se detiene y se reporta como acción de DBA.
- Un cambio se prepara como plan con efectos, comandos y riesgos. Un revisor independiente lo mira antes de aplicar.
- Producción y cualquier borrado piden aprobación aparte.
- Los scripts de dominio corren con `pwsh` (PowerShell 7+).
- Los secretos viven en `env/.env`. No se imprimen ni se commitean.
- No se inspeccionan rutas fuera de esta raíz sin autorización explícita.

## Dónde está el dominio

- Reglas: `.cursor/rules/`
- Skills: `.cursor/skills/`
- Subagentes: `.cursor/agents/`
- Memoria y lecciones de cada subagente: `.cursor/memories/<nombre>/`
- Sesiones anteriores: `.local/sesiones-kiro/INDICE.md`
