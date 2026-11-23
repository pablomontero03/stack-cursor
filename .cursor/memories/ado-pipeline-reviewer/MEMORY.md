# Memoria — ado-pipeline-reviewer

## Propósito

Revisar de forma independiente planes de pipelines clásicos de Azure
DevOps (AKS o DACPAC, `Shared-Service-GM` / proyecto `DevOps`) contra las
guías y el inventario en vivo, antes de cualquier `-Apply`.

## Alcance de la memoria

Aprendizajes reutilizables de revisión (errores recurrentes que un plan
generado suele traer, falsos positivos de `Test-AdoClassicPlan.ps1` ya
descartados). No duplica el procedimiento completo, que vive en
`.claude/agents/azure-devops/ado-pipeline-reviewer.md`.

## Enlaces

- [Diagnóstico](./debugging.md)
- [Patrones](./patterns.md)

## Aprendizajes esenciales

- Plan multi-stage AKS válido: un archivo de plan por stage, mismo
  Build/Release, solo el stage listo queda `validated:true`. Ver
  [[patterns]].
- Revisar siempre que `validationWarnings` no contradiga un valor ya
  fijado (ej. `preDeploymentApprovalRequired` fijado sin que la
  gobernanza esté confirmada). Ver [[patterns]].
- Checklist ampliado 2026-08-25: verificar `Build-MultiStage` (no
  `Build`), agrupación de merges por default (8+2 piezas,
  `alwaysRun=false` en `Reportar-resultado-HU` del lado Build), tabla de
  revisión cuando el plan use `-PopulateRealValues`, y
  `New-AdoReleaseEnvironmentEntry` para ensamblado multi-ambiente. Ver
  [[patterns]] § "Sincronizado 2026-08-25".
- Método recomendado antes de aprobar un `-Apply`: dry-run
  campo-por-campo contra el recurso vivo equivalente, no solo confiar en
  `Test-AdoClassicPlan.ps1`. Ver [[patterns]].

- [Plan bodyHash-only manifest verification gap](ado-plan-bodyhash-only-manifest-verification-gap.md) —
  los planes AKS solo guardan el hash del body de `create-build-definition`,
  nunca el contenido de los 3 manifiestos K8s; localizar y diffear los
  archivos reales en disco (pueden existir borradores en conflicto) antes
  de avalar un `-Apply`.
- Borrado real de Build/Release/Variable Group agregado 2026-08-26
  (trabajo directo de la sesión principal): revisar con
  `Test-AdoClassicDeletePlan.ps1` (nunca `Test-AdoClassicPlan.ps1`),
  confirmar `backupRequired=true` fijo, exactamente 1 `approvedOperation`
  por plan, y que `resourceId` coincida con el id real en inventario
  fresco. Ver checklist punto 17 en
  `.claude/agents/azure-devops/ado-pipeline-reviewer.md`.

- **Verificar SIEMPRE si `approvedOperations` tiene contenido real**,
  distinto de si el plan es `validated:true` — un plan válido con
  `approvedOperations` vacío hace que `-Apply` sea un no-op total (nada se
  crea), no un error. Ver [[patterns]] § "approvedOperations vacío tras
  regenerar el plan".
- Un plan `update-release-definition` con `approvedOperations` vacío a
  propósito (ids de VG todavía no existen) puede quedar sin ninguna base
  revisable ("plan sin sustancia") — exigir como mínimo
  `releaseDefinitionId`, mapeo explícito environment→Library, qué NO
  cambia, y criterio de field-stripping antes de aceptarlo. Ver
  [[patterns]] § "Plan sin sustancia para update-release-definition".
- Revisar siempre `release.artifactFilterBranch` por stage — un valor de
  Producción copiado por error a Desarrollo/UAT no tiene efecto mientras
  nadie lo consuma, pero rompe el CD en silencio si se usa después. Ver
  [[patterns]] § "artifactFilterBranch copiado de Producción".
- Diffear campo a campo contra dumps GET reales (los que el builder haya
  dejado en el scratchpad) es más confiable que confiar en el `bodyHash`
  opaco del plan, y puede revelar hallazgos fuera del alcance del plan
  mismo (ej. un secreto real sin `isSecret=true` en el recurso vivo). Si
  no hay tool Bash disponible en la sesión, verificar
  `Test-AdoClassicPlan.ps1` a mano (forma de hash, ids, frescura de
  inventario) y reportar explícitamente la limitación. Ver [[debugging]].
- **Nunca citar el código fuente/default de un generador como "el
  contrato real confirmado" sin un GET propio de un recurso real
  equivalente** — un default puede tener un gap real (parámetro que
  acepta pero no puebla) y producir un bloqueante falso. Ver [[debugging]]
  § "Bloqueante falso... 2026-09-04".

Última revisión: 2026-09-04 (4ª revisión real: Release de `app-logistics`
buklo-web — reportó un bloqueante FALSO sobre `containerRegistryUsername/
Password` que el builder refutó con GET propio; re-verificado por este
agente en una segunda pasada con su propio GET, confirmando que el
builder tenía razón. Ver [[debugging]]). 3ª revisión 2026-08-26: Buklo
Gateway Dev/UAT, Planes A-D, ver checklist ampliado en
`.claude/agents/azure-devops/ado-pipeline-reviewer.md` — encontró plan D
"sin sustancia" y `artifactFilterBranch` mal copiado, ambos corregidos
por el builder y aplicados con éxito (Build 584 rev20, Release 366 rev4,
VG 418/419, Producción intacta). 2ª revisión: 2da prueba de
reconstrucción de `administracion-proyectos-web`, ver
[[ado-administracion-proyectos-rebuild2-review-2026-08-26]] — gap de
`-VariableGroupName` confirmado corregido; bloqueante de
`approvedOperations` vacío reportado y luego CERRADO en la misma sesión
tras repoblarlo el builder y re-verificarlo este agente. 1ª revisión en
[[ado-administracion-proyectos-rebuild-review-2026-08-26]]).
