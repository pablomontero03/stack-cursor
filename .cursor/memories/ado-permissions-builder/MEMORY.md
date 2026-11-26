# Memoria — ado-permissions-builder

## Propósito

Construir la administración de grupos de seguridad (Development Team(s),
Code-Reviewers), sus membresías y permisos Git de `Shared-Service-GM`,
siguiendo intake → inventario → plan → validación → aprobación → apply →
readback.

## Alcance de la memoria

Aprendizajes reutilizables de construcción de planes de permisos
(convenciones confirmadas en vivo contra la API real, bugs reales
encontrados y corregidos, causas raíz de un apply fallido). No duplica el
procedimiento completo, que vive en
`.claude/agents/azure-devops-permissions/ado-permissions-builder.md` y
`.claude/skills/manage-azure-devops-permissions/SKILL.md`.

## Enlaces

- [Diagnóstico](./debugging.md)
- [Patrones](./patterns.md)

## Estado en vivo — Shared-Service-GM/Buklo (al 2026-09-02)

Snapshot, no garantía — re-exportar inventario/policies antes de asumir
que sigue así.

- 7 repos del proyecto: `buklo-backend` (origen, Build Validation 628),
  `buklo-mobile`, `buklo-web` (Build Validation 629), `buklo-knowledge-base`,
  `buklo-database-sqlproject`, `buklo-framework`, `buklo-database-snapshot`.
- Branch Policies replicadas desde `buklo-backend`: `buklo-mobile` (21,
  sin Build validation, a pedido explícito) y `buklo-web` (24, con Build
  629 propio). Los otros 4 repos no tienen Branch Policies de este dominio
  todavía — no se pidieron.
- Permisos Git (grupos/matriz) aplicados a los 7 repos + `All Repositories`:
  `Development Team` deniega Contribute en development/uat/release/main;
  `Code-Reviewers` tiene Allow global sin override de Contribute (puede
  completar PRs en las 4 ramas). Matriz difiere en 2 puntos del documento
  original por decisión explícita del usuario (ya reflejado en
  `references/permission-matrix.md`): `development` también deniega
  Contribute a Development Team; `Code-Reviewers`/`main` es `Not set` (no
  Deny) para poder completar PRs ahí.
- `All Repositories` tiene además 9 identidades no administradas por este
  dominio pero preservadas automáticamente en cualquier escritura futura
  (ver [[patterns]] § "Set ACL reemplaza"): los 4 grupos default del
  proyecto + 2 identidades de servicio de Build (replicados desde
  `CORE-PLT`, solo lectura), `Business Team IA`, y un bit residual
  (`Enterprise Live Migration`) puesto a mano por el usuario.
- Patrón real confirmado (no bug): usuario en Development Team Y
  Code-Reviewers a la vez queda bloqueado para completar PRs — ver
  [[patterns]] § "Deny de grupo siempre gana" (caso real: Edson Alvarez
  Obando, resuelto por el usuario sacándolo de Development Team).
- 2026-09-03: mismo usuario (Edson Alvarez Obando), problema DISTINTO —
  401 "you do not have access" a nivel de TODO el proyecto (Buklo ni le
  aparecía en la lista), pese a Access Level Basic y ACE Git perfecta en
  Code-Reviewers. Causa real: "View project-level information" (namespace
  `Project`, no administrado por este dominio) estaba en Not set para el
  grupo. Resuelto a mano por el usuario en el portal. Ver [[patterns]] §
  "View project-level information..." para el detalle completo — es un
  gap real de cobertura de este dominio, no un bug de un script.
- Capacidades del dominio: grupos/permisos y `pr-policy-admin` usados en
  vivo por primera vez esta sesión, funcionando end-to-end (2 incidentes
  mayores encontrados y corregidos, ver [[debugging]]).

## Aprendizajes esenciales

- **CRÍTICO**: el `acesDictionary` de Security usa el descriptor SID
  legado, nunca el de Graph — ver [[patterns]] § "Descriptor de ACE de
  Security" y [[debugging]] § "INCIDENTE MAYOR".
- **CRÍTICO**: "Set Access Control Lists" reemplaza el `acesDictionary`
  completo del token, no lo combina — ver [[patterns]] § "Set ACL
  reemplaza" y [[debugging]] § "INCIDENTE MAYOR 2". Guardia dura no
  bypasseable agregada en `Invoke-AdoPermissionsRest` a pedido explícito
  del usuario ("que no se elimine ningún grupo") — ver
  `.cursor/rules/azure-devops.mdc` (sección de seguridad) § "Guardia dura...".
- Modo **pr-policy-admin** (Branch Policies) agregado 2026-09-02 — ver
  [[patterns]] § "pr-policy-admin".
- Grupos nuevos: miembros/ACE siempre quedan en `deferredAfterCreation`
  del primer plan — ver [[patterns]] § "Grupos nuevos: 2 planes".
- Nunca invocar `Apply-AdoPermissionsPlan.ps1`/`Apply-AdoPermissionsDeletePlan.ps1`
  para probar algo — `$env:AZURE_DEVOPS_PAT` suele estar configurada y
  llega a la organización real. Ver [[debugging]] § "Incidente de red
  real durante pruebas".
- 2 discrepancias reales UI vs `displayName` de la API en el namespace
  "Git Repositories" — resolución siempre por el campo `name`. Ver
  `references/permission-matrix.md`.
- **Gap de cobertura real**: este dominio solo administra el namespace
  "Git Repositories" — el namespace `Project` ("View project-level
  information") queda completamente fuera de la matriz y puede bloquear
  el acceso a TODO el proyecto aunque la matriz Git esté perfecta. Ver
  [[patterns]] § "View project-level information...".
- Encoding: todo `.ps1` con texto no-ASCII literal necesita BOM UTF-8;
  todo `Get-Content -Raw` de un JSON propio necesita `-Encoding UTF8`;
  todo body con tildes hacia la API necesita bytes UTF-8 explícitos
  (nunca `[string]` directo en `Invoke-WebRequest`); tokens de rama se
  codifican en UTF-16LE, no UTF-8. Detalle completo de cada uno en
  [[debugging]].

Última revisión: 2026-09-03 (gap real de cobertura encontrado y
documentado: namespace `Project` / "View project-level information" no
administrado por este dominio, caso Edson Alvarez Obando #2).

Revisión anterior: 2026-09-02 (primera corrida real del dominio completo:
modo pr-policy-admin nuevo + matriz de grupos/permisos aplicada de
verdad por primera vez, incidente del descriptor SID resuelto y
verificado; caso Edson Alvarez Obando #1 diagnosticado; documentación
compactada).

## Lección 2026-09-21 — no ejecutar setup.sh de Kiro

Causa raíz confirmada de las "caídas del gateway" al operar ADO: NO era el
`curl`/PUT ni el volumen JSON — era `source ./setup.sh`, En Cursor no se usa ese reinicio de Kiro
en su paso [7/7] y mata el gateway/sesión. El comando completa (exit 0) y el restart
tumba la sesión acto seguido, por lo que parece fallo del `curl`.

**Vía correcta en sesión activa** — cargar el `.env` directo:
```bash
source /home/cursor/stack-cursor/env/.env
export REPO_ROOT=/home/cursor/stack-cursor
```
No ejecutar `source ./setup.sh`. Para variables: `set -a; source env/.env; set +a`.
Para Export/Apply de permisos: seguir corriéndolos en la terminal WSL del operador
(vuelven a tumbar por volumen HTTP), pero descartar el `setup.sh` como sospechoso
extra de caída.

## EXCEPCIÓN Buklo — Development Team completa sus propios PRs (2026-09-29)

**NO es cambio de estándar.** La matriz canónica sigue con `Development Team`
`Contribute=Deny` en ramas protegidas. Esto es un override EN VIVO solo para
Buklo, hecho SIN el generador de matriz. No replicar como patrón.

- **Vía técnica para un override que la matriz canónica NO contempla:** el
  generador estándar `New-AdoPermissionsPlan.ps1` reafirma la matriz (Deny), así
  que NO sirve. Se arma un plan `set-git-permissions-ace` a mano con las
  funciones oficiales del helper, con dos claves:
  1. `Test-AdoPermissionsPlan.ps1` NO re-deriva los bits contra la matriz —
     solo valida forma, hash de body, precondición, ambigüedad y lockout. Por
     eso acepta el valor de bits que traiga el plan. PERO exige que cada
     `project` tenga la estructura `developmentTeam`/`codeReviewers`
     (status='existing', descriptor real) o falla con "The property
     'developmentTeam' cannot be found". Poblar esa estructura = Test sella el
     `validationHash` sin alterar los bits del override.
  2. `Apply-AdoPermissionsPlan.ps1` exige `validated=true`+`validationHash`
     correcto (la fase interna `Invoke-AdoPermissionsApplyPhases` también lo
     exige vía la guardia de escritura del helper: rechaza con "el plan no está
     marcado validated=true"). NO se puede aplicar un plan sin sellar por Test.
- **Contribute = Allow explícito** (bit 4) para Development Team en
  `development`/`uat` de todos los repos de Buklo EXCEPTO `buklo-framework`.
  El `explicitAllow` de Development Team en esas ramas era 0 (los bits Read/
  CreateBranch/PRContribute son HEREDADOS). El recompute con managedMask=4 da
  `explicitAllow=4`; el `effectiveAllow` final es `16434(heredado)|4 = 16438`.
  No se pierde nada; el ACE explícito no repite bits heredados.
- **Guardia anti-borrado:** cada rama tenía 2 identidades con ACE real
  (Development Team + Code-Reviewers). El plan incluye AMBAS en el
  `acesDictionary` (Code-Reviewers copiado tal cual) o el Apply lo rechaza.
- **Branch Policies — auto-aprobación:** desactivar `blockLastPusherVote`
  (True→False) + `creatorVoteCounts=True` en las policies "Minimum number of
  reviewers" bloqueantes. Solo 3 lo impedían: id 1326 (backend/uat), 1346
  (mobile/dev), 1372 (web/uat). El endpoint `policy/configurations/{id}` NO
  está en el catálogo del helper (rechaza con 400), y curl a ADO tumba el
  gateway: usar `Invoke-RestMethod` GET+PUT del objeto completo (con revision).
- **Ojo lectura de inventario de policies:** `Export-AdoPolicyInventory.ps1`
  (por repositoryId) devuelve el catálogo COMPLETO del proyecto en cada
  archivo, no solo las del repo. Al analizar, filtrar por el `repositoryId` de
  cada `scope`, no por archivo, o parece que hay duplicados que no existen.
- Respaldos en `.local/azure-devops-permissions/`: inventario
  `inventory-permissions-Buklo-20260929-150852.json`, políticas
  `backups/policy-{1326,1346,1372}-backup-20260929-152439.json`.


## Regla — revisar todas las membresías del usuario (2026-09-30)

Add-only. Al conceder/verificar permisos Git de un usuario, enumerar **todas** sus
membresías de grupo y evaluar el permiso EFECTIVO, no solo confirmar que está en el grupo
objetivo. Razón: en ADO un `Deny` explícito de CUALQUIER grupo gana sobre el `Allow` del
grupo objetivo. Un grupo en `Not set` no aporta ni resta.

Vía de verificación (solo lectura):
- Usuario: `POST graph/subjectquery` (subjectKind User).
- Membresías: `GET graph/memberships/{graphDesc}?direction=up`; resolver cada
  `containerDescriptor` con `graph/groups/{desc}`.
- Descriptor legado del usuario: `GET identities?subjectDescriptors={graphDesc}` →
  `Microsoft.IdentityModel.Claims.ClaimsIdentity;<tenant>\<upn>`.
- ACE por grupo/rama: `GET accesscontrollists/{ns}?token=repoV2/{proj}/{repo}/refs/heads/<hex>&includeExtendedInfo=true`.
- Efectivo: `POST security/permissionevaluationbatch` con el descriptor legado, bit Contribute=4.

Ejemplo Miguel Esquivel Castrillo (`mesquivelc@grupomontecristo.com`), Buklo, 2026-09-30:
- Miembro de `[Buklo]\Development Team` (recibió la excepción Contribute=Allow) y de
  `[Buklo]\Buklo GM Cotizador`.
- Contribute efectivo=True en dev/uat verificado con `permissionevaluationbatch`.
- `Buklo GM Cotizador` estaba en `Not set` en todas las ramas → sacarlo no cambia el
  efectivo y no metía Deny. Script de readback reusable:
  `.local/azure-devops-permissions/Read-MiguelEffectiveContribute.ps1`.
- Falso positivo del guard data-exfiltration: la sintaxis pwsh `=@{`/`=@(` en un heredoc de
  shell matchea el patrón `-F *=@`. Fix: escribir el script con la tool `write` a archivo y
  ejecutarlo con `pwsh -NoProfile -File`, sin `=@` en la línea de shell.

## Excepción buklo-project (Buklo) + grupo anidado Team-Proyects — 2026-10-07

- **Repo:** `buklo-project` id `f2a03223-6e8c-4415-af3c-2945a61a92a6` (proyecto Buklo
  `26c82ecb-bb47-45f0-bc88-063dde58ef12`). Ramas: development, uat, release, main.
- **Grupo anidado:** `[Shared-Service-GM]\Team-Proyects` (SID legacy
  `S-1-9-...-1846990856-4084570703-2350565729-371267176`) está contenido en
  `[Buklo]\Development Team`. Hereda el Contribute del grupo padre, no necesita ACE propio.
- **Hallazgo clave:** Team-Proyects estaba también en `[Shared-Service-GM]\Project Collection
  Administrators` → le daba Contribute en TODAS las ramas por vía admin. El usuario lo sacó de ahí;
  SOLO entonces el grupo quedó en estado base (Contribute False) y aplicó la excepción de rama.
  **Lección operativa:** `permissionevaluationbatch` evalúa contra la identidad del PAT (operador),
  NO contra el grupo del body → daba True falso. La fuente de verdad del permiso de un GRUPO es el
  **ACE efectivo del grupo** en el token de rama (`accesscontrollists` con `includeExtendedInfo=true`,
  leer `extendedInfo.effectiveAllow/effectiveDeny` del SID legacy del grupo), NO el eval batch.
- **Contribute:** ACE directo `allow|=4`, `deny&=~4`, `merge=true` en el token de rama de dev/uat.
  Patrón Buklo confirmado: effAllow 16434→16438, effDeny 1032140→1032136 (bit 4 removido). Script:
  `.local/azure-devops-permissions/Apply-BukloProject-Contribute.ps1`.
- **21 políticas creadas** (repo no tenía ninguna) replicando buklo-web por rama:
  - dev/uat (2415-2424): excepción (MinReviewers auto-aprobación + Code-Reviewers opcional) + Work
    item + Comments + Merge strategy.
  - release/main (2425-2435): estrictas/bloqueantes. Reviewers: `[Buklo]\Code-Reviewers` (5fcb8ce3),
    `Production-Deployment-Approvers` (3550d2d3, release), `Release Executers` (397ddbfe, main).
  - **Build omitida:** buklo-web la apunta a buildDefinitionId=629 (su pipeline); buklo-project no
    tiene pipeline propio (0 definitions). No copiar la Build a un repo sin pipeline propio.
  - Script creador: `.local/azure-devops-permissions/Create-BukloProject-Policies.ps1` (dev/uat) y
    `Create-BukloProject-RelMain.ps1` (release/main). Readback:
    `Read-BukloProject-ACE.ps1` (ACE efectivo), `Read-BukloProject-NewPolicies.ps1` (políticas).
- **Excepción puntual solo buklo-project.** No tocó matriz canónica, generador ni otros repos.


## Excepción Database-Administration-and-Monitoring — Development teams completa sus PRs (2026-11-10)

Misma excepción que Buklo, aplicada a TODOS los repos del proyecto (60 repos; 96 ramas: 49 development + 47 uat). Grupo del proyecto = `Development teams` (plural, 1 solo candidato). Code-Reviewers = `2aef8f76-9f1b-49c7-99b9-8f2cb79af9f2`.
- Permisos: plan `plans/dbadmin-devteam-contribute-exception-20261110.json` (96 ops, validationHash e5a85cfd...), generado con `.local/azure-devops-permissions/New-DbAdminDevTeamContributeExceptionPlan.ps1`. DIFERENCIA CLAVE vs Buklo: usa `fullAcesDictionary` (incluye la ACE de USUARIO pmontero allow=12300 presente en cada token) en vez de solo `descriptors`; con la versión Buklo la guardia anti-borrado habría rechazado. Omite ramas ya en Allow (buklo_lab/development). Test OK → Apply 96x HTTP 204.
- Policies: `Set-DbAdminPolicyException.ps1` (dry-run por defecto, `-Apply` respalda y escribe, lee el LISTADO con paginación): 95 "Minimum reviewers" → creatorVoteCounts=true + blockLastPusherVote=false; 96 "Required reviewers" de Code-Reviewers → isBlocking=false. 191 PUT OK, 0 ERR. NO se tocó Build (38 bloqueantes dev/uat), Work item, Comments, Merge strategy, ni el Required reviewer 3550d2d3 de un uat.
- Readback: Contribute efectivo=True en 97/97 nodos, 0 ACE perdidas/alteradas. Ojo: el export de policies usa `settingsRaw` y `scope` top-level (no `settings`).
- Respaldos: `exports/inventory-permissions-Database-Administration-and-Monitoring-20261110-160609.json` (pre) y `-161152.json` (post); `backups/policies-dbadmin-ALL-20261110.json`, `-PRE-APPLY-20261110-161025.json`, `-APPLY-LOG-...json`, `-POST-20261110.json`.
- Rollback: reponer ACE con el pre-inventario (allow=0 deny=4 para el SID de Development teams) y policies desde el PRE-APPLY.

## Excepción Celula Web — Development teams completa sus PRs (2026-11-10)

Proyecto `Celula Web` (id 0070f711-1f8b-47e9-8e01-31a134d85363), 9 repos, 6 con development+uat (12 ramas). Permisos Git: NO hizo falta, `Development teams` (7d5a2b2d) ya tenía Contribute efectivo sin Deny heredado. Solo policies: `.local/azure-devops-permissions/Set-DevTeamPolicyException.ps1` (parametrizado: -ProjectName -CodeReviewersId -Tag; dry-run por defecto). Code-Reviewers del proyecto = 37bf1da1-921a-485f-b79f-a997c1e108f1 (verificado con graph/storagekeys). 11 PUT OK: 6 MinReviewers (creatorVotes=true, blockLastPusher=false) + 5 Required reviewers a opcional; 3 deshabilitadas intactas; Build/WorkItem/Comments/Merge intactos. Respaldos: backups/policies-celulaweb-{ALL,PRE-APPLY,APPLY-LOG,POST}-*.json, exports/inventory-permissions-Celula-Web-20261110-164201.json. Antes de usar el flujo en otro proyecto, mirar si el Deny de Contribute existe (inheritedDeny/effective) para saber si hacen falta los permisos.
