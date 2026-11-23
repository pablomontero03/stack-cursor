# Patrones — schema-sync-reviewer

Todavía no existen patrones confirmados propios de este agente. Checklist
que ya usa su proceso de revisión (ver
`.claude/agents/schema-sync-db/schema-sync-reviewer.md`): ausencia de
escritura SQL, uso exclusivo de SqlPackage Extract con
ApplicationIntent=ReadOnly, ausencia de Publish/Deploy/TargetConnectionString,
coincidencia database/repoName/projectName/workflow, una sola BD por
corrida salvo autorización explícita, orquestador inactivo, Git main → PR
release sin autocomplete, ausencia de secretos o conexiones completas,
validaciones correspondientes a los archivos modificados, y para repos
nuevos: GUID propio, estructura mínima y build exitoso antes de catálogo o
n8n. Patrones reales (hallazgos recurrentes) se agregan solo cuando se
confirmen en una revisión real.
