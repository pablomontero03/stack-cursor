# Diagnóstico — ado-pipeline-reviewer

## Bloqueante falso: citar el default del generador como "contrato real" sin GET propio (2026-09-04, Release de app-logistics)

Marqué como bloqueante que `deployTaskGroupInputs.containerRegistryUsername/
Password` usaran macros `$(containerRegistryUsername)`/`$(containerRegistryPassword)`
"huérfanas" (0 coincidencias grepeando las Variable Groups y el Build),
citando el default de `New-AdoReleaseEnvironmentEntry` (código fuente del
generador) como si fuera el contrato real confirmado (`''` hardcodeado).
Nunca hice un GET propio de un Release hermano real para confirmarlo. El
builder lo refutó con 2 GET reales (Releases 361/364): las macros SÍ son
correctas — se resuelven contra `environments[].variables`, una colección
que grep de Variable Groups/Build nunca iba a encontrar porque vive en el
propio Release, no en esos otros recursos.

**Lección**: el código fuente de un generador describe su comportamiento
por DEFECTO, no necesariamente el contrato real de la plataforma — puede
tener un gap (un parámetro que el default no puebla pero que sí acepta,
como `stageVariables` en este caso). Antes de marcar un bloqueante basado
en "el generador no lo hace así", hacer SIEMPRE el GET propio de al menos
un recurso real equivalente (no confiar en que otro agente ya lo hizo,
tampoco confiar en el propio código como si fuera documentación de la
API). Cuando se me pidió re-verificar con mi propio GET, sí encontré el
mecanismo real correcto — la técnica funciona, el problema fue no
aplicarla ANTES de reportar el bloqueante, no después.

**Nota aparte, sin acción**: ese mismo GET reveló que el password real de
ACR en los Releases 361/364 está sin `isSecret=true` (texto plano) — mismo
patrón ya documentado abajo para Release 366. No se toca, es hallazgo
informativo de la organización, no de los planes revisados esa vez.

## `containerRegistryPassword` sin `isSecret=true` — encontrado diffeando contra un GET real, no confiando en el plan (2026-08-26, Buklo Gateway)

Revisando la Release 366 real (dump `raw-release-366-*.json` que el
builder había dejado en el scratchpad, no algo que yo mismo pedí bajar)
apareció el valor en texto plano de `containerRegistryPassword` para los
3 environments. Azure DevOps **nunca** devuelve por GET el valor real de
una variable `isSecret=true` (confirmado en `security.md` del dominio,
aplica igual a variables a nivel de environment de Release, no solo a
Variable Groups) — que el valor viniera legible confirma que esa
variable NO está marcada como secreta en el recurso real, un hallazgo de
la organización en sí, no de los planes bajo revisión. Esto estaba fuera
del alcance de los 4 planes que se estaban revisando (ninguno tocaba esa
variable), así que se reportó como hallazgo informativo/tarea de
remediación separada — nunca se intentó corregir ni se tocó nada, solo
se documentó. Técnica reutilizable: cuando el builder deja dumps GET
crudos en el scratchpad como evidencia de su trabajo, leerlos igual
aunque no sean parte de los 4 archivos de plan — pueden revelar
configuración viva incorrecta que ningún plan iba a exponer directamente.
No hace falta ir a buscarlos activamente si no existen; pero si existen,
son la mejor fuente de verdad disponible sin acceso a MCP/PAT en la
sesión de revisión.

## `Test-AdoClassicPlan.ps1` no se pudo re-ejecutar por falta de tool Bash en la sesión de revisión (2026-08-26)

La sesión de este agente tuvo únicamente Read/Grep/Glob/Write/Edit
disponibles — sin Bash ni ninguna forma de invocar PowerShell. El
checklist pide re-correr `Test-AdoClassicPlan.ps1` como parte de la
revisión (punto 6 del prompt de tarea); cuando la herramienta no está
disponible, la alternativa real (no un placeholder vacío) es: (1) leer
el plan y el inventario referenciado directamente con `Read`/`Grep` y
verificar a mano lo que el script verificaría —
`operationId` único, `method`/`uri` exactos por `operationType`, forma
SHA-256 de cada `bodyHash` (contar 64 caracteres hex), que
`inventoryGeneratedAtUtc` del plan coincida con el `generatedAtUtc` real
del archivo de inventario, que `paginationComplete:true`; (2) si el
builder dejó en el scratchpad el body real que se hasheó (no solo el
hash), diffearlo campo a campo contra un GET real reciente en vez de
confiar en el hash opaco — así se encontraron los hallazgos de
`replicas`/`artifactFilterBranch`/task-groups obsoletos en esta misma
revisión. Reportar explícitamente esta limitación en el resultado final
(qué no se pudo re-ejecutar y por qué) en vez de omitirlo o fingir que
se corrió.
