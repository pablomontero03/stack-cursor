---
name: ado-buklo-web-standalone-build-2026-09-01
description: 2do uso real de la capacidad standalone-build (Build-Validation-buklo-web, proyecto Buklo) — cero código nuevo, reutilizó los runners construidos el mismo día para buklo-backend
metadata:
  type: project
---

Mismo día que [[patterns]] § "RESUELTO: constructor de Build clásico
standalone" y su 2do gap. Pedido de un 2do Build standalone en el mismo
proyecto (`Buklo`, repo `buklo-web`, id
`9f3ddab6-2d4c-491c-87b0-93888be32260`, rama `development`), mismo
mecanismo de 2 steps (File Creator + PowerShell@2) que
`Build-Validation-buklo-backend`, con un `detect-and-build.ps1` DISTINTO
(Nx/Angular con `apps/<app>/`+`Dockerfile.<app>` en vez de pnpm/Turborepo).

**Confirmó que la capacidad ya no necesita nada nuevo para un 2do repo del
mismo proyecto**: flujo completo (inventario fresco → `New-AdoClassicStandaloneBuildPlan.ps1`
→ `Test-AdoClassicPlan.ps1` para resolver `repo.id` → steps-spec con
`fileContentPath` → `New-AdoClassicCreatePlan.ps1 -Kind StandaloneBuild` →
`Test-AdoClassicPlan.ps1` final) corrió sin ningún bloqueante ni ajuste de
script. `$script:AdoAllowedProjects = @('DevOps','Buklo')` seguía vigente
de la sesión anterior (verificado por grep antes de asumirlo). Mismo pool
Microsoft-hosted reutilizado (`agentPoolId=9`/`Azure Pipelines`,
`queueId=null`), confirmado de nuevo contra un inventario fresco de
`Buklo` antes de reusarlo (no se asumió sin verificar, tal como pedía la
tarea) — sigue siendo el mismo id que en `buklo-backend`.

Plan final:
`D:\Proyectos\automation\.local\azure-devops\plans\standalone-build-buklo-web-with-op.json`,
`validated=true`, `validationHash=409af64406057fbd3c2499160d5ad7cf825225df57c5a90fb3d5b517a4c750ff`,
`bodyHash` de `approvedOperations[0]`
`c02b0760633ab7cae284a19bc564eb0380a054a109e3003da07564f122b24526`. Sin
escrituras reales, sin Apply ejecutado por este agente.

## Después de mi entrega: 2 gaps reales, resueltos por el coordinador solo

Build 629 creado (Apply hecho por el coordinador). Dos problemas
aparecieron DESPUÉS de mi entrega, en la sesión del coordinador, sin mi
participación — documentados acá para que la próxima invocación mía ya
los conozca:

1. **Queue rota**: `-QueueId` omitido (mi propio default) produjo
   `queue:{url:.../Queues/0, pool:null}` en vivo para este Build (a
   diferencia de 628, que sí resolvió a queue 1026 con el mismo código).
   "Agent pool 0 was not found" al primer build real. Corregido a mano
   por el usuario en el portal — **no corregido en
   `New-AdoStandaloneBuildDefinitionPayload` todavía**. Próxima vez:
   pasar `-QueueId` explícito (resuelto contra un Build ya funcionando en
   ese proyecto) en vez de confiar en la resolución automática de Azure
   DevOps, que quedó demostrada no confiable.
2. **`New-AdoClassicUpdatePayload.ps1` sin soporte `standalone-build`**:
   necesitaba corregir un bug real en el script embebido de Build 629
   (`$app:` sin llaves, ver memoria de proyecto del coordinador
   `ps-variable-colon-interpolation-gotcha`) vía `Set-AdoFileCreatorContent`,
   y ni Modo 1 (`-ExistingPlanPath`) ni Modo 2 (esqueleto) aceptaban esta
   familia. El coordinador agregó soporte a ambos modos (Modo 2 nuevo:
   `-Family standalone-build`, solo `-BuildName`). Ya disponible para
   usar la próxima vez sin volver a construirlo.

Detalle técnico completo (comandos exactos, diffs) en la memoria de
proyecto del coordinador: `ado-standalone-build-capability-2026-09-01.md`
(Gaps 3 y 4) y `ado-build-validation-buklo-web.md`.
