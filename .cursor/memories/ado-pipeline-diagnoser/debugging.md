# Diagnóstico — ado-pipeline-diagnoser

Todavía no existen aprendizajes de diagnóstico confirmados para este
agente. Se agregan solo cuando un diagnóstico real deja una causa raíz
verificada y reutilizable — no incidentes transitorios de una sola
ejecución.

## Bug ADO: "An item with the same key" en PUT de build definitions con File Creator
**Confirmado en producción 2026-09-21. Resuelto vía MCP.**

### Síntoma
PUT de `_apis/build/definitions/{id}` falla con error `"An item with the same key has already been added"` cuando la definición tiene un step de tipo **File Creator** (`fileContent` vacío o no nulo).

### Causa
Bug del servidor ADO — no del cliente. El servidor no acepta el payload completo del GET cuando hay steps File Creator con `fileContent` presente, independientemente del valor.

### Rutas que NO funcionan
- PUT directo del JSON del GET (ni completo ni parcial)
- Sustitución quirúrgica del `fileContent` con sed/grep antes del PUT
- `New-AdoClassicUpdatePlan.ps1` con `update-build-definition` si el step tiene `fileContent=''`

### Solución confirmada
**Usar el MCP de Azure DevOps** para actualizar el step directamente — el MCP reconstruye el payload interno evitando el conflicto de keys.

Si el MCP no está disponible: **UI de ADO** → Build → Edit → step File Creator → pegar el contenido manualmente. Es más rápido que depurar el bug del servidor.

### Referencia
Ver `ado-pipeline-builder/debugging.md` y `ado-pipeline-builder/patterns.md` para el diagnóstico completo y snippet de 3 pasos.
