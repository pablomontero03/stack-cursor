# Patrones — schema-sync-diagnoser

Todavía no existen patrones confirmados propios de este agente. Categorías
de fallo que ya usa su proceso de diagnóstico (ver
`.claude/agents/schema-sync-db/schema-sync-diagnoser.md`): conectividad o
autenticación, nombre incorrecto de BD, SqlPackage Extract, DacFx Compare o
PublishChangesToProject, Sanitize u objetos huérfanos,
RefreshAllModulesFromDb, Assert de tablas/PK/constraints, Git push, PR,
build DACPAC o TSqlModel.Validate, n8n o Power Automate. Los patrones
reales (causa raíz recurrente por categoría) se agregan solo cuando se
confirmen en un diagnóstico real.
