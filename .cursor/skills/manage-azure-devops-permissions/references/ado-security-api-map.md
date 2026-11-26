# Mapa de API — Graph Groups/Memberships y Security ACL

Todos los endpoints de abajo fueron confirmados el 2026-08-26 directo
contra la documentación oficial de Microsoft (URLs citadas en cada
sección) — no adivinados. El toolset oficial del MCP `azure-devops`
(`@azure-devops/mcp@2.9.0`) no expone Graph Groups, Graph Memberships ni
Security ACL/ACE hoy — ver
`https://github.com/microsoft/azure-devops-mcp/blob/main/docs/TOOLSET.md`.
Esta es la brecha real que cubre `Invoke-AdoPermissionsRest.ps1`.

## Graph Groups

Fuente:
`https://learn.microsoft.com/rest/api/azure/devops/graph/groups`

### Create

```
POST https://vssps.dev.azure.com/{organization}/_apis/graph/groups?scopeDescriptor={scopeDescriptor}&api-version=7.1-preview.1
Body: { "displayName": "...", "description": "..." }
```

`scopeDescriptor` (prefijo `scp.`) es el descriptor del proyecto — se
resuelve vía Descriptors/Get (abajo) usando el `projectId` como
`storageKey`. Sin `scopeDescriptor`, el grupo se crearía a nivel
organización — nunca se omite este parámetro en este dominio.

### Update (descripción)

```
PATCH https://vssps.dev.azure.com/{organization}/_apis/graph/groups/{groupDescriptor}?api-version=7.1-preview.1
Content-Type: application/json-patch+json
Body: [ { "op": "add", "path": "/description", "value": "..." } ]
```

Se usa `"op": "add"` (no `"replace"`) porque, según RFC 6902, `add` sobre
un miembro existente lo reemplaza igual, y funciona tanto si el grupo
tenía descripción como si no.

### Delete

```
DELETE https://vssps.dev.azure.com/{organization}/_apis/graph/groups/{groupDescriptor}?api-version=7.1-preview.1
```

Sin body. Solo vía `Apply-AdoPermissionsDeletePlan.ps1`.

## Graph Memberships

Fuente:
`https://learn.microsoft.com/rest/api/azure/devops/graph/memberships`

### Add

```
PUT https://vssps.dev.azure.com/{organization}/_apis/graph/memberships/{subjectDescriptor}/{containerDescriptor}?api-version=7.1-preview.1
```

Sin body. `subjectDescriptor` es el miembro (usuario o grupo);
`containerDescriptor` es el grupo destino.

### Remove

```
DELETE https://vssps.dev.azure.com/{organization}/_apis/graph/memberships/{subjectDescriptor}/{containerDescriptor}?api-version=7.1-preview.1
```

Sin body. Solo vía `Apply-AdoPermissionsDeletePlan.ps1`.

### Descriptors — resolver el scope de un proyecto

```
GET https://vssps.dev.azure.com/{organization}/_apis/graph/descriptors/{storageKey}?api-version=7.1-preview.1
```

`storageKey` = el `projectId` (GUID) del proyecto. Devuelve
`{ "value": "scp.XXXX" }`, el `scopeDescriptor` a usar en Create de
grupos. Patrón inferido por consistencia con el resto de Graph API (mismo
host, mismo `api-version=7.1-preview.1`) — no verificado con un ejemplo
sample de Microsoft; si un uso real devuelve un error de forma
inesperada, revisar esta sección antes de asumir que el problema está en
otro lado.

### Subject query — resolver identidad por correo/nombre

```
POST https://vssps.dev.azure.com/{organization}/_apis/graph/subjectquery?api-version=7.1-preview.1
Body: { "query": "correo o nombre", "subjectKind": ["User", "Group"] }
```

Mismo estado que Descriptors/Get arriba: patrón inferido, no verificado
con ejemplo oficial. Si un miembro no se resuelve como se espera, probar
primero el MCP (si en el futuro expone esta capacidad) antes de confiar
ciegamente en esta forma.

## Security Namespaces

Fuente:
`https://learn.microsoft.com/rest/api/azure/devops/security/security-namespaces/query`

```
GET https://dev.azure.com/{organization}/_apis/securitynamespaces?api-version=7.1
```

Devuelve TODOS los namespaces. Nunca se hardcodea el `namespaceId` de
"Git Repositories" — se busca en vivo por `name -eq 'Git Repositories'` (o
`displayName`), y se valida que aparezca exactamente una vez (ver
`Resolve-AdoPermissionsNamespaceActions`). El id confirmado hoy es
`2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87`, pero eso es un dato observado, no
un supuesto que el código confíe sin re-validar.

## Access Control Lists (ACE/ACL)

Fuente:
`https://learn.microsoft.com/rest/api/azure/devops/security/access-control-lists`

### Query

```
GET https://dev.azure.com/{organization}/_apis/accesscontrollists/{securityNamespaceId}?token={token}&descriptors={descriptors}&includeExtendedInfo=true&api-version=7.1
```

`includeExtendedInfo=true` es obligatorio para este dominio: sin eso, la
API no devuelve `inheritedAllow`/`inheritedDeny`/`effectiveAllow`/
`effectiveDeny` — el inventario los necesita para reportar la distinción
completa que exige el documento fuente (explicit/inherited/effective).

### Set

```
POST https://dev.azure.com/{organization}/_apis/accesscontrollists/{securityNamespaceId}?api-version=7.1
Body: { "value": [ { "inheritPermissions": true|false, "token": "...", "acesDictionary": { "<descriptor>": { "descriptor": "<descriptor>", "allow": N, "deny": N } } } ] }
```

"All data that currently exists for the ACLs supplied will be
overwritten" — en la práctica esto es por-descriptor dentro del
`acesDictionary` enviado, no un reemplazo del ACL completo del token: los
descriptores que no se incluyen en el payload no se tocan. Por eso cada
operación de este dominio solo incluye los 1-2 descriptores que realmente
administra (Development Team(s) y/o Code-Reviewers), nunca el ACL entero
de un token. **Confirmado en vivo 2026-09-02** (incidente real, ver
`.claude/agent-memory/ado-permissions-builder/debugging.md` §
"INCIDENTE MAYOR"): ningún otro grupo preexistente (`Contributors`,
`Readers`, `Project Administrators`, etc.) resultó afectado por 30
escrituras reales a este endpoint — el Audit Log de la organización lo
confirma sin ambigüedad.

**`<descriptor>` (clave y campo `descriptor`) NUNCA es el descriptor de
Graph** (`vssgp.BASE64...`, el que usan Graph Groups/Memberships) — es el
descriptor LEGADO basado en SID: `Microsoft.TeamFoundation.Identity;
S-1-9-...`. El payload Base64 de `vssgp.XXXX` es, literalmente, el SID en
texto plano (`vssgp.` + Base64 de `S-1-9-...`) — se obtiene decodificando
Base64, sin llamada adicional a la API. Usar siempre
`ConvertTo-AdoPermissionsSecurityAceDescriptor` para esta conversión,
nunca el descriptor de Graph crudo ni un prefijo inventado sobre él —
Azure DevOps acepta un descriptor con forma incorrecta con HTTP 200/204
sin error, pero nunca lo asocia a la identidad real (confirmado con el
incidente real de arriba: 30/30 escrituras "exitosas" sin efecto real).

## Tokens del namespace "Git Repositories"

Fuente:
`https://learn.microsoft.com/azure/devops/organizations/security/namespace-reference`,
`https://learn.microsoft.com/azure/devops/organizations/security/manage-tokens-namespaces`

- Nodo `All Repositories` de un proyecto: `repoV2/{projectId}`.
- Repositorio específico: `repoV2/{projectId}/{repositoryId}`.
- Rama o prefijo `refs/heads/...`:
  `repoV2/{projectId}/{repositoryId}/refs/heads/<segmentos hex-UTF8 separados por "/">`.
  Cada segmento del ref (separado por `/`) se hex-codifica POR SEPARADO —
  `ConvertTo-AdoPermissionsHexUtf8` en `Invoke-AdoPermissionsRest.ps1`.
  El prefijo `feature/*` completo usa un único segmento `['feature']`
  (representa el nodo contenedor de todas las ramas hijas).

Todo token se construye con `ConvertTo-AdoPermissionsGitToken`/
`ConvertTo-AdoPermissionsProjectToken` — nunca a mano — y su forma se
valida contra el regex de `set-git-permissions-ace` en
`$script:AdoPermissionsAllowedOperationTypes` antes de cualquier
escritura.

## Namespace "Project" — "View project-level information" (NO administrado por este dominio)

Confirmado en vivo 2026-09-03, en el contexto de diagnosticar un 401 real
("you do not have access") que resultó no tener nada que ver con "Git
Repositories" (ver `.claude/agent-memory/ado-permissions-builder/patterns.md`
§ "View project-level information..." para el caso completo).

- `namespaceId`: `52d39943-cb85-4d7f-8fa8-c6baac873819` (`name: 'Project'`).
  Acción `GENERIC_READ` = "View project-level information" en la UI
  (Project Settings > Permissions > [grupo]).
- **Token real de un proyecto en ESTE namespace**:
  `$PROJECT:vstfs:///Classification/TeamProject/{projectId}` — distinto
  del token de "Git Repositories" a nivel `All Repositories`
  (`repoV2/{projectId}`, ver arriba) y distinto también del `projectId`
  pelado. Usar el `projectId` pelado como token contra este namespace
  devuelve `aclFound=false` de forma engañosa (parece "sin ACL
  configurada"; en realidad es "namespace/token equivocado" — no sacar
  ninguna conclusión de esa respuesta sin corregir el token primero).
- Este dominio (`Get-AdoPermissionsMatrixDefinition`,
  `references/permission-matrix.md`) **no administra este namespace en
  absoluto** — solo administra "Git Repositories". Un grupo
  (`Development Team(s)`/`Code-Reviewers`) puede tener su matriz Git
  perfecta (Allow correcto, sin ninguna Deny, heredado hasta el repo) y
  seguir en **Not set** acá, lo que bloquea el acceso a TODO el proyecto
  (401, el proyecto ni aparece en la lista) de forma indistinguible a
  simple vista de un problema de Access Level o de la matriz Git. Estar
  anidado en `Project Valid Users` (que pasa por defecto al crear el
  grupo) tampoco alcanza por sí solo.
- No está incluido en la matriz administrada todavía — candidato de
  mejora futura, no implementado en esta sesión. Mientras tanto, fijarlo
  a mano en el portal para cualquier grupo nuevo/con miembros nuevos es
  responsabilidad del usuario, no de este automation.
- **Esto SÍ se puede verificar por API, no hace falta el portal.** Receta
  verificada en vivo 2026-09-03:
  `Get-AdoPermissionsFullAcesDictionary -CoreBase $coreBase -NamespaceId
  '52d39943-cb85-4d7f-8fa8-c6baac873819' -Token
  "`$PROJECT:vstfs:///Classification/TeamProject/$projectId"` (GET SIN
  `&descriptors=` — la forma filtrada por descriptores "hace eco"
  `allow=0/deny=0` tanto para un descriptor sin ACE real como para uno en
  Not set, y es por eso ambigua/no concluyente por sí sola). El resultado
  trae solo los descriptores con ACE real; el bit `1` = `GENERIC_READ` =
  "View project-level information" para el descriptor legado del grupo en
  cuestión. El primer diagnóstico real de este caso lo dio por
  inconcluyente por usar el `projectId` pelado como token (namespace
  equivocado, `aclFound=false` engañoso) combinado con la forma filtrada
  ambigua en el segundo intento — no repetir esa combinación de errores.

### Confirmación 2026-11-03 (Centro-Inteligencia — grupo `Development Team`, usuario `jalvarez`)

Caso real que reconfirma esta sección end-to-end. Pablo agregó el grupo
`Development Team` con **Read=Allow en los permisos de REPOS**
(`_settings/repositories` > Security) y aun así los miembros recibían
`401 - you do not have access` en la raíz del proyecto
(`dev.azure.com/Shared-Service-GM/Centro-Inteligencia/`). Verificado en
vivo (solo lectura):

- `jalvarez` **sí** era miembro del grupo `Development Team`
  (`graph/memberships` down), **sí** tenía Access Level `express`
  (Basic) active, y su **Read efectivo** sobre los repos ya daba `True`
  (`security/permissionevaluationbatch`, namespace Git, token
  `repoV2/{projId}` y `repoV2/{projId}/{repoId}`). O sea, la capa Git
  estaba perfecta — y aun así 401.
- El 401 se destrabó **solo** al agregar el grupo en
  `_settings/permissions` (la pantalla de **permisos de PROYECTO**, no la
  de Repositories). Ese alta es exactamente lo que setea el
  `Project / GENERIC_READ` ("View project-level information") descrito
  arriba y mete al grupo en el circuito de `Project Valid Users`.

**Regla operativa para un grupo NUEVO en un proyecto:** no basta una
capa, se necesitan DOS, y son pantallas distintas:
1. **Pertenencia al proyecto** (capa `Project` / Project Valid Users):
   anidar el grupo en `Readers`/`Contributors`/el Team por defecto, o
   agregarlo en `_settings/permissions`. Sin esto → 401 en la puerta del
   proyecto, ANTES de evaluar cualquier permiso de repo.
2. **Permiso de recursos** (capa `Git Repositories`): Read=Allow en
   `_settings/repositories` > Security.

Lo mantenible es **anidar el grupo en `Readers`** del proyecto: así cada
persona que se agregue a `Development Team` hereda a la vez la pertenencia
al proyecto y el Read, sin tener que tocar dos pantallas a mano cada vez.
El descriptor del Team por defecto de este proyecto es
`[Centro-Inteligencia]\Centro-Inteligencia Team`
(domain `vstfs:///Classification/TeamProject/13fe5ce3-fc99-4f26-9223-9453edce740b`).
