# Patrones — ado-permissions-builder

## "Set ACL" reemplaza, nunca combina — siempre partir del acesDictionary completo, y hay una guardia dura que lo hace cumplir

Toda escritura de `set-git-permissions-ace` debe construir su
`acesDictionary` en 2 pasos: (1) copiar TAL CUAL cada entrada de
`AclSnapshot.fullAcesDictionary` (el ACL real completo del token,
capturado por `Export-AdoPermissionsSecurityInventory.ps1` vía
`Get-AdoPermissionsFullAcesDictionary`) que no sea una de las que este
dominio administra; (2) agregar/sobrescribir solo esas. Nunca enviar un
`acesDictionary` que sea un subconjunto de lo que ya existe — la API
`accesscontrollists` REEMPLAZA el diccionario completo del token, no lo
combina (documentado por Microsoft, confirmado con un incidente real
2026-09-02, ver [[debugging]] § "INCIDENTE MAYOR 2"). Esto aplica a
CUALQUIER token (`All Repositories` o una rama), no solo al que causó el
incidente.

Esto NO depende solo de que el script generador se acuerde de hacerlo
bien: `Invoke-AdoPermissionsRest` tiene una guardia dura que RECHAZA
cualquier `set-git-permissions-ace` cuyo body dejaría fuera a una
identidad con ACE real hoy, consultando en vivo antes de escribir. Sin
excepción ni flag para desactivarla — cubre incluso un plan armado a
mano. Ver `.claude/rules/azure-devops-permissions/security.md` §
"Guardia dura..." y el test 10d.

## Descriptor de ACE de Security: SID legado, no Graph

Toda escritura o lectura de `acesDictionary` (API `accesscontrollists`)
debe pasar el descriptor de Graph (`vssgp.BASE64...`) por
`ConvertTo-AdoPermissionsSecurityAceDescriptor` antes de usarlo como
clave — la API real usa `Microsoft.TeamFoundation.Identity;S-1-9-...`
(el SID, obtenido decodificando Base64 el payload de `vssgp.`), no el
descriptor de Graph. Ver [[debugging]] § "INCIDENTE MAYOR" para el
incidente real que expuso esto (2026-09-02) — sin esta conversión, una
escritura de ACE reporta éxito (HTTP 200/204) sin tomar efecto real, de
forma indistinguible de un éxito real salvo verificando con un GET sin
filtros o con el Audit Log de la organización.

## Grupos nuevos: 2 planes

Cuando `Development Team(s)` o `Code-Reviewers` no existen todavía, el
primer plan SOLO crea el grupo (con su descripción estándar). Sus
miembros confirmados y sus ACE quedan listados en `deferredAfterCreation`
del plan (informativo, nunca ejecutable). Después de aplicar y confirmar
el descriptor real (readback o una nueva exportación de inventario), un
SEGUNDO plan agrega los miembros y fija las ACE — recién ahí el grupo
cuenta como "existente" para `New-AdoPermissionsPlan.ps1`.

Motivo técnico: `Invoke-AdoPermissionsRest` exige que la URI (para
membresías) y el body (para ACE) de cada escritura coincidan EXACTO con
lo aprobado en el plan — el descriptor real de un grupo nuevo no existe
hasta después de que su propia creación se aplique, así que no hay forma
segura de referenciarlo dentro del MISMO plan que lo crea.

## Fuente única de las matrices

Nunca copiar/pegar valores de matriz a mano en un plan o en una
conversación. Siempre partir de
`Get-AdoPermissionsMatrixDefinition`/`Get-AdoPermissionsManagedActionCatalog`
en `scripts/Invoke-AdoPermissionsRest.ps1` — es la única fuente de
verdad, y las pruebas la consumen directamente (casos 8-9 de
`run-script-tests.ps1`).

## Resolución de un token de rama

`ConvertTo-AdoPermissionsGitToken -ProjectId <guid> -RepositoryId <guid>
-RefSegments @('main')` (o `@('feature')` para el prefijo completo,
`@('feature','sub-branch')` para una rama con "/" en el nombre). Cada
segmento se hex-codifica por separado, en **UTF-16LE** (2 bytes por
carácter, no UTF-8/1 byte — bug real corregido 2026-09-02, ver
[[debugging]] § "Token de rama con codificación equivocada"). Nunca
construir el token a mano.

## pr-policy-admin: replicar Branch Policies entre repos (agregado 2026-09-02)

Flujo: `Export-AdoPolicyInventory.ps1` (GET puro, `_apis/policy/
configurations` -- OJO: el query param `repositoryId` NO filtra
server-side pese a estar documentado; siempre trae TODAS las policies del
PROYECTO, hay que filtrar client-side por `scope[].repositoryId`) para
origen y destino → `New-AdoPolicyPlan.ps1` (compara y genera solo
creaciones) → `Test-AdoPolicyPlan.ps1` → `Apply-AdoPolicyPlan.ps1`. Mismo
patrón plan-validado-aprobación que grupos/permisos, pero un modo nuevo y
más simple (sin matriz, un solo `operationType`:
`create-policy-configuration`, POST puro).

Reglas de diseño confirmadas en vivo:

- Solo se replica una policy cuyo `scope` tenga EXACTAMENTE 1 elemento
  (repo+rama exactos) -- cualquier otra forma se reporta y se excluye,
  nunca se asume.
- Si el destino YA tiene una policy del mismo `(type.id, refName)`, se
  excluye automáticamente (`skippedAlreadyExists`) -- este modo SOLO crea,
  nunca actualiza ni duplica. Confirmado real: `buklo-web/development` ya
  tenía su Build de una corrida previa (2026-09-01) y se excluyó sola.
- Una policy tipo "Build" (`type.id` = `0609b952-1397-4640-95ec-e00a01b2c241`)
  NUNCA se replica con el `buildDefinitionId` del origen tal cual --
  apunta al pipeline de Build Validation del repo ORIGEN, casi seguro
  inválido en el destino. `New-AdoPolicyPlan.ps1` EXIGE
  `-BuildDefinitionIdOverride <id>` para incluir Build (o excluirlo del
  todo vía `-ExcludePolicyTypeIds`) -- confirmado real: `buklo-backend`
  usa Build 628, `buklo-web` usa su propio Build 629; copiar 628 a ciegas
  hubiera dejado las ramas de `buklo-web` validándose contra el pipeline
  equivocado.
- `requiredReviewerIds` son identity ids ORG-level (vssps), reutilizables
  tal cual entre repos/proyectos de la misma organización -- resolver a
  nombre legible antes de mostrarle el plan al usuario vía GET
  `_apis/identities?identityIds=...` (read-only, sin aprobación).
- Toda esta cadena de scripts requiere `-Encoding UTF8` en cada
  `Get-Content -Raw` (ver [[debugging]]) -- un plan con mensajes
  acentuados (`message` de "Required reviewers") es el caso real que lo
  expuso.

## Deny de grupo siempre gana — usuario en 2 grupos a la vez puede quedar bloqueado

Un usuario miembro de `Development Team` Y `Code-Reviewers` a la vez queda
BLOQUEADO para completar PRs en las ramas protegidas: Azure DevOps combina
los permisos de TODOS los grupos de un usuario y **Deny siempre gana sobre
Allow**, sin importar el grupo de origen ni la especificidad — el Deny de
Contribute de Development Team le gana al Allow heredado que da
Code-Reviewers, y ningún Allow (ni siquiera individual explícito) puede
revertir eso para el mismo usuario. Único fix real: sacarlo de Development
Team, dejarlo solo en Code-Reviewers (no pierde nada funcional — esa
membresía ya da Contribute/ContributeToPRs/CreateBranch/Read a nivel
global). Caso real confirmado 2026-09-02: `ealvarez@grupomontecristo.com`
(Edson Alvarez Obando) en Buklo — el usuario lo resolvió sacándolo de
Development Team manualmente por el portal (confirmado por lectura
posterior). Ante el mismo síntoma en cualquier proyecto, revisar primero
las membresías de grupo del usuario antes de sospechar de la matriz o del
código.

## Membresía aditiva: nunca "restar"

`New-AdoPermissionsPlan.ps1` compara los miembros confirmados contra
`members` del inventario y solo agrega los que faltan — nunca genera una
operación de remoción, sin importar qué lista de miembros traiga el
intake. Remover un miembro exige `New-AdoPermissionsDeletePlan.ps1` con
su propia aprobación.

## "View project-level information" (namespace `Project`, `GENERIC_READ`) — este dominio NO lo administra

Confirmado en vivo 2026-09-03 (caso real: Edson Alvarez Obando, grupo
`Code-Reviewers` de Buklo). La matriz de este dominio
(`Get-AdoPermissionsMatrixDefinition`) administra ÚNICAMENTE el namespace
"Git Repositories" (Contribute, Read, Create branch, etc. — ver
`references/permission-matrix.md`). **Nunca toca el namespace `Project`**,
cuya acción `GENERIC_READ` es "View project-level information" en la UI
(Project Settings > Permissions > [grupo]).

Síntoma real: un grupo administrado por este dominio (Code-Reviewers)
puede tener su matriz Git perfecta — Allow correcto, sin ninguna Deny, ACE
heredada correctamente hasta el repo — y el usuario igual recibe 401 "you
do not have access" al intentar abrir CUALQUIER cosa del proyecto (el
proyecto ni le aparece en la lista de proyectos), porque "View
project-level information" estaba en **Not set** para ese grupo. Esto
pasa aunque el usuario tenga Access Level Basic asignado correctamente, y
aunque el grupo esté anidado (como está por defecto) dentro de `Project
Valid Users` — esa membresía anidada NO alcanza por sí sola para que la
ACE de "View project-level information" del grupo pase de Not set a
Allow.

**IMPORTANTE — esto SÍ es verificable por API, no es un límite de
alcance.** El primer diagnóstico en vivo lo dio por no concluyente por 2
errores metodológicos propios, combinados:

1. Se consultó `Get-AdoPermissionsFullAcesDictionary` (GET SIN filtro
   `&descriptors=`, la forma correcta y definitiva) pero con el TOKEN
   EQUIVOCADO — `$projectId` pelado en vez del token real de este
   namespace — lo que devolvió `aclFound=false` de forma engañosa
   (parece "sin ACL"; en realidad es "namespace/token equivocado").
2. Al corregir el token, se volvió a consultar pero CON filtro
   `&descriptors=` (`GET .../accesscontrollists/{ns}?descriptors=...`),
   que por diseño de la API "hace eco" `allow=0/deny=0` tanto para un
   descriptor sin ACE real como para uno con una ACE real explícita en
   Not set — ambiguo, no concluyente por sí solo (mismo comportamiento ya
   documentado para "Git Repositories", ver más arriba).

**La combinación correcta y definitiva es la MISMA que ya se usa para
"Git Repositories"**: `Get-AdoPermissionsFullAcesDictionary` (GET SIN
`&descriptors=`) contra el **token correcto** de este namespace. Verificado
en vivo 2026-09-03 DESPUÉS del fix manual del usuario: esa consulta trae
las 11 identidades reales con ACE en el token de Buklo, incluida
`Code-Reviewers` con `allow: 1` (bit `GENERIC_READ` = "View project-level
information", confirmado por el bit real, no supuesto) — o sea, la misma
info exacta que muestra la página de Project Settings > Permissions del
portal. No hizo falta el portal para verlo; solo faltó combinar bien la
consulta la primera vez.

**Detalle técnico del token**: el namespace `Project` (id
`52d39943-cb85-4d7f-8fa8-c6baac873819`) usa como token real
`$PROJECT:vstfs:///Classification/TeamProject/{projectId}` — NO el
`projectId` pelado (ese es el token de "Git Repositories" a nivel `All
Repositories`, un namespace distinto). Ver
`references/ado-security-api-map.md` § "Namespace 'Project'" para el
detalle completo y la receta de verificación exacta.

**Recomendación para la próxima vez que se cree o trabaje con
`Development Team(s)`/`Code-Reviewers`**: verificar por API — GET sin
`&descriptors=` contra el token correcto, buscando el bit `1`
(`GENERIC_READ`) del descriptor legado del grupo — que "View
project-level information" esté en Allow, además de la matriz Git. No
asumir que la matriz Git administrada por este dominio es suficiente para
que el proyecto sea visible, y no concluir "no se puede verificar por
API" sin antes probar esta combinación exacta. Ampliar
`Get-AdoPermissionsMatrixDefinition` para administrar también esta acción
del namespace `Project` es un candidato de mejora futura — no
implementado en esta sesión.
