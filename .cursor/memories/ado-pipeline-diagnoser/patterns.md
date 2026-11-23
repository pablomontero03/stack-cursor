# Patrones — ado-pipeline-diagnoser

Todavía no existen patrones confirmados propios de este agente.
Categorías de fallo que ya usa su proceso de diagnóstico (ver
`.claude/agents/azure-devops/ado-pipeline-diagnoser.md`): familia AKS
(tokens sin resolver, contexto Docker, `ImagePullBackOff`,
`acr-pull-secret`, CD trigger/artifact filter, CrashLoop/probe, BOM UTF-8)
y familia DACPAC (`databaseProjectName` desalineado, Library no linkeada,
`instanciadb_prod` mal resuelto, orden de jobs incorrecto, login SQL). Los
patrones reales (causa raíz recurrente por categoría) se agregan solo
cuando se confirmen en un diagnóstico real.
