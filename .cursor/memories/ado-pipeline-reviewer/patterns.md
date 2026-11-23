# Patrones — ado-pipeline-reviewer

Checklist que ya usa su proceso de revisión (ver
`.claude/agents/azure-devops/ado-pipeline-reviewer.md`): familia correcta
sin mezclar keys, ids/nombres confirmados en vivo (no copiados de las
guías), sin duplicados de Build/Release/Variable Group, CD trigger +
artifact filter bien planeados, sin secretos ni placeholders, sin
`image_pull_secret` en Prod AKS.

## Patrones confirmados

### Plan multi-stage AKS: un archivo por stage, mismo Build/Release
Cuando una app tiene 3 ambientes, es válido que `New-AdoClassicAksPlan.ps1`
genere 3 archivos de plan hermanos (uno por stage: Desarrollo/UAT/
Producción), todos apuntando al mismo `names.build` / `names.release`,
donde solo el stage listo para entregar queda `validated:true` con
`validationEvidence` completo y los demás quedan `validated:false` con
`validationBlockers` explícitos (rama o service connection sin confirmar)
en vez de rellenarse con un default inventado. Confirmado revisando
`aks-administracion-proyectos-web-{desarrollo,uat,produccion}.json`
(2026-08-24) — los blockers de UAT/Prod coincidieron exacto con lo que el
inventario en vivo mostraba (branches reales del repo, service connections
Prod ambiguas). Patrón sano: preferirlo sobre forzar un solo plan con
campos vacíos sin bloquear.

### Revisar consistencia entre `validationWarnings` y valores ya fijados
Un plan puede traer un warning tipo "confirmar con el usuario la
gobernanza de aprobación de Producción" y, al mismo tiempo, ya traer
`release.preDeploymentApprovalRequired: true` fijado como valor definitivo
para ese stage. Esto es una inconsistencia interna real (no un bloqueante
de aplicación, porque el stage ya está bloqueado por otras razones) pero
sí una señal de que el plan "asumió" una respuesta de gobernanza en el
campo mientras el propio warning admite que no está confirmada. Revisar
siempre que el warning y el valor concreto cuenten la misma historia;
si no, pedir que el campo quede explícitamente marcado como provisional
en vez de un booleano definitivo. Confirmado en la revisión de
`aks-administracion-proyectos-web-{uat,produccion}.json` (2026-08-24).

### Manifiestos K8s de SPA 100% estática (sin backend propio)
Para una app tipo SPA (React/Vite/nginx) sin backend ni credenciales
server-side, es razonable que el manifiesto propuesto omita `Secret` y
`ConfigMap` (a diferencia de la plantilla base con esos kinds) y que los
probes apunten a `/` en vez de `/health` si el `nginx.conf` real del repo
no expone ese path — siempre que la nota del plan lo justifique
explícitamente citando el archivo real revisado (no la plantilla).
Confirmado en `design-notes-administracion-proyectos-web.md`
(2026-08-24). Punto a vigilar: si el YAML base trae comentarios tipo
"SOLO Dev/UAT" junto a `imagePullSecrets` / `ingressClassName: nginx` en
vez de una plantilla Prod ya separada sin esas líneas, es un riesgo de
implementación (que el clon de Prod copie el comentario pero no elimine
las líneas) — señalarlo como pendiente de verificar en el momento de
generar los 3 `File Creator` reales, no solo confiar en la nota.

## Sincronizado 2026-08-25 desde trabajo directo (no delegado a este agente)

El siguiente checklist se descubrió/confirmó por la sesión principal
haciendo el trabajo directo (no vía este agente) — agregarlo a lo que se
revisa en el próximo plan real:

- **Verificar `Reportar-resultado-HU` (lado Build) con `alwaysRun=false`**,
  no `true` — un plan que traiga `true` ahí está copiando por error el
  valor del lado Release (donde sí es `true`); son campos independientes,
  confirmado contra Build 552 y 622 reales el 2026-08-25.
- **Método de validación recomendado antes de cualquier `-Apply` real**:
  comparación dry-run campo-por-campo contra el recurso vivo equivalente
  más cercano (mismos ids/valores ya en uso), no solo confiar en
  `Test-AdoClassicPlan.ps1`. Así se encontró el bug de `alwaysRun` arriba.
  Falsos positivos esperados en ese método (no marcarlos como bloqueantes):
  orden de claves JSON al serializar hashtables, y campos `queue.name`/
  `queue.pool.isHosted` que Azure DevOps solo agrega como enriquecimiento
  del GET (nunca hace falta producirlos al generar).
- **`Build-MultiStage` es el task group de build por default** (ya no
  `Build`) — si un plan trae `Build` para un pipeline nuevo sin que el
  usuario lo haya pedido explícitamente, señalarlo como desviación de la
  convención vigente, no asumir que es intencional.
- **Agrupación de merges activa por default** en todo pipeline AKS nuevo
  (8 piezas Build + 2 piezas Release, spec completo en
  `references/ado-classic-payload-templates.md`) — un plan que NO la
  incluya debe traer una nota explícita de por qué se excluyó
  (`-DisableMergeBatching`), no faltar en silencio.
- **`.env` con `-PopulateRealValues`**: si el plan puebla secretos reales
  en el manifiesto, verificar que venga acompañada la tabla corta
  nombre→categoría para que el usuario la revise antes de aplicar — su
  ausencia es una desviación de la práctica acordada, no solo un detalle
  de estilo.

## `approvedOperations` vacío tras regenerar el plan (2026-08-26, rebuild2 de administracion-proyectos-web)

`New-AdoClassicAksPlan.ps1` SIEMPRE inicializa `approvedOperations = @()`
al generar/regenerar un plan — es su comportamiento normal, no un bug.
Pero `Apply-AdoClassicPlan.ps1` solo ejecuta la fase (Variable Group /
Build / Release) para la que el plan trae una entrada de
`approvedOperations` del `operationType` correspondiente (ver su propio
docstring, línea ~30: "solo las fases para las que el plan trae una
entrada de approvedOperations del operationType correspondiente"). Un
plan `validated:true` con `approvedOperations` vacío es estructuralmente
válido (checklist punto 11 lo permite) pero es un **no-op total** si se
invoca `-Apply` sobre él — cero escrituras, no un error.

Por eso, siempre verificar explícitamente si `approvedOperations` tiene
contenido antes de responder si un plan "está listo para -Apply". Vacío
es aceptable en early-stage (recién generado/regenerado) pero es un
**pendiente de completitud, no de validez**, distinto de un bloqueante de
`Test-AdoClassicPlan.ps1`. El flujo observado para poblarlo (evidenciado
por los scripts que quedaron en el scratchpad de la 1ª reconstrucción:
`Build-VgApprovedOps.ps1`, `Build-BuildApprovedOp.ps1`,
`Build-ReleaseApprovedOp.ps1`, `patch-plans.ps1`) es: calcular el body
real con las funciones de `New-AdoClassicPayloads.ps1` (ej.
`New-AdoBuildDefinitionPayload` con los 3 manifiestos K8s reales),
hashearlo, añadir la entrada a `approvedOperations`, y volver a correr
`Test-AdoClassicPlan.ps1` para refrescar `validationHash` — recién ahí el
plan queda listo para invitar al usuario a aprobar `-Apply`. Cuando un
plan regenerado (ej. tras corregir un gap como el de
`-VariableGroupName`) vuelve a traer `approvedOperations` vacío en los
archivos de Variable Group/Build (a diferencia del archivo de Release,
que legítimamente queda vacío mientras los ids reales no existen), es un
hallazgo BLOQUEANTE a reportar antes de invitar al `-Apply`, no un
detalle menor. Ver
[[ado-administracion-proyectos-rebuild2-review-2026-08-26]].

## Plan "sin sustancia" para `update-release-definition` con VG ids pendientes (2026-08-26, Buklo Gateway Dev/UAT)

Cuando un plan de relink de Release (family AKS, `update-release-definition`
para linkear Variable Groups nuevas a environments existentes) se genera
ANTES de que existan los ids reales de esas VG (p. ej. porque los planes
`create-variable-group` que las crean todavía no se aplicaron), es
correcto que `approvedOperations` quede vacío. Pero eso NO exime al plan
de traer contenido revisable — confirmado en la revisión de
`aks-buklo-microservice-gateway-20260826-133216.json` (Plan D de esa
sesión): el archivo era casi un duplicado campo por campo del plan de
Build/VG del stage Desarrollo (mismo `names`/`repo`/`dockerfile`/
`buildVariables`/`variableGroup`/`release.stage:"Desarrollo"` únicamente),
sin ninguna mención al `releaseDefinitionId` real, a los ids de los
environments a tocar, ni a qué NO cambia. `New-AdoClassicAksPlan.ps1` no
tiene ningún modo dedicado a generar este tipo de operación (confirmado
por grep — no hay `environments`/`update-release-definition` en ese
script); el mecanismo real de aplicación vive en
`Apply-AdoClassicPlan.ps1` vía `-UpdateReleaseBodyPath` (un archivo de
body PUT separado, aparte del plan), así que el JSON del plan en sí es
la única evidencia disponible para vetar la intención antes de que ese
body exista.

**Mínimo exigible para aprobar un plan así, aunque `approvedOperations`
esté vacío a propósito:**
- `releaseDefinitionId` explícito (el id real, no asumido).
- Mapeo explícito environment→Library por cada ambiente a tocar (id o
  nombre de la Library nueva, aunque el id real de la VG creada todavía
  no exista — un placeholder documentado sirve).
- Confirmación explícita de qué NO cambia: el ambiente de Producción
  (variableGroups actuales, approvals, task groups, artifact filter) y
  cualquier otro campo del Release definition fuera del relink puntual.
- El mismo criterio de field-stripping que ya usa Plan C para Build
  definition (ver `ado-classic-payload-templates.md` § "Release
  definition"), pero aplicado explícitamente a nivel raíz de Release
  definition — listar qué campos GET-only se van a quitar.

Si un plan de este tipo no trae ninguno de estos 4 puntos (ni siquiera
como nota), no hay base para revisarlo — repórtalo como hallazgo
BLOQUEANTE ("plan sin sustancia"), no lo apruebes condicionalmente
esperando que "ya se completará después". El precedente de
`administracion-proyectos-web` sí incluía un `design-notes-*.md` hermano
documentando el criterio — su ausencia en un plan nuevo es la señal más
rápida de que faltó este paso.

## `artifactFilterBranch` copiado de Producción a Desarrollo/UAT sin corregir (2026-08-26, Buklo Gateway)

`New-AdoClassicAksPlan.ps1` (u otro flujo que arme el bloque `release` de
un plan AKS) puede dejar `release.artifactFilterBranch` con el mismo
valor que usa el stage Producción (típicamente `"release"`) incluso
cuando el plan es para el stage Desarrollo o UAT. Verificar siempre que
este campo coincida con la rama real de CADA stage
(`repo.ciBranchFilters` normalmente trae `development`/`uat`/`release`
en ese orden — Desarrollo debería usar `development`, UAT debería usar
`uat`, solo Producción usa la rama de prod real). Cross-check contra un
GET real de la Release definition: si los environments no-Prod
actualmente tienen `conditions: []` (sin filtro), el valor incorrecto en
el plan todavía no tiene efecto — pero es una desviación a señalar igual,
porque si ese campo se usa después para configurar un filtro nuevo (ver
guía §9.4 "Confirmar Artifact filter del stage Desarrollo/UAT si
corresponde"), un valor de rama incorrecto rompería el CD automático de
ese ambiente en silencio (nunca matchea ningún build real). Reportar como
hallazgo IMPORTANTE aunque `approvedOperations` no lo consuma todavía —
mejor corregirlo cuando es solo metadata que después de que rompa un
despliegue real.
