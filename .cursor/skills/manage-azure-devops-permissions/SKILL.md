---
name: manage-azure-devops-permissions
description: Administra grupos de seguridad de proyecto, membresias, permisos Git y Branch Policies en proyectos de Shared-Service-GM para grupos Development Team y Code-Reviewers.
triggers: [permisos, permissions, grupos, members, code-reviewers, development team, ado]
always: false
---

# Manage Azure DevOps Permissions

Organización: `Shared-Service-GM`. Dominio **separado** de
`manage-azure-devops-pipelines` — no comparte scripts, hooks, agentes,
memoria ni datos transitorios con ese dominio. Reutiliza el mismo MCP
`azure-devops` ya declarado en `.mcp.json` (`@azure-devops/mcp@2.9.0`) solo
para inventario de proyectos/repositorios/ramas; nunca para Graph Groups,
Graph Memberships ni Security ACL/ACE, que el toolset oficial no expone
hoy (ver `references/ado-security-api-map.md`).

## Flujo real obligatorio

```text
intake de proyectos y miembros (conversacional, nunca por similitud)
  → Export-AdoPermissionsSecurityInventory.ps1 (GET puro: grupos,
    membresías, security namespace, ACL/ACE — solo lectura)
  → New-AdoPermissionsPlan.ps1 (plan JSON determinista, validated=false)
  → Test-AdoPermissionsPlan.ps1 (matrices, hashes, herencia, guard de
    lockout, secretos, placeholders — validated=true + validationHash)
  → presentar plan completo e invocar Apply-AdoPermissionsPlan.ps1 en el
    mismo turno (una sola tarjeta de aprobación cubre todo el plan)
  → apply exacto ya aprobado (respeta precondición, journal de ejecución)
  → reporte de aplicado/omitido/ya-aplicado/fallido
  → [OBLIGATORIO] invocar ado-permissions-reviewer para verificar que el
    estado en vivo coincide con el patrón canónico esperado — sin este
    paso el ciclo no está cerrado. El reviewer verifica AllRepos, feature/*
    y ramas protegidas para cada grupo y reporta ✅/❌ por nodo.
```

No saltar pasos. `Apply-AdoPermissionsPlan.ps1` rechaza siempre cualquier
operación destructiva — eliminar usa un flujo aparte (ver abajo).

## Limitación de diseño deliberada: grupos nuevos quedan en 2 pasos

Cuando `Development Team`/`Development Teams` o `Code-Reviewers` **no
existen todavía**, el primer plan solo los crea (con su descripción
estándar). Sus miembros y sus ACE quedan en `deferredAfterCreation` del
plan — nunca en `approvedOperations` — porque el descriptor real del grupo
no existe hasta después de aplicar la creación, y
`Invoke-AdoPermissionsRest` exige que la URI/body de cada escritura
coincida EXACTO con lo aprobado (no hay forma segura de referenciar un id
que el propio plan todavía no creó). Después de aplicar y confirmar el
descriptor real, volver a exportar el inventario y generar un plan nuevo
para ese grupo — recién ahí sus miembros y ACE entran en
`approvedOperations`. Mismo principio que obligó a Pipelines a separar
`update-build-definition`/`update-release-definition` de la creación
original.

## Resolución de grupos — nunca por similitud

- `Development Team` / `Development Teams`: búsqueda insensible a
  mayúsculas por nombre exacto. Ninguno → crear `Development Team`. Uno →
  reusarlo. Ambos → el plan queda bloqueado (`developmentTeam.status =
  'blocked-ambiguous'`) hasta que el intake incluya
  `developmentTeamDescriptorOverride` con el descriptor elegido.
- `Code-Reviewers (Revision Y Aprobacion Del Lider De Proyecto)`: mismo
  criterio, nombre exacto único.
- Miembros: resolver cada uno por correo o descriptor único (vía MCP o
  Graph `subjectquery` REST); un nombre ambiguo bloquea, nunca se elige
  por similitud.

## Matriz de permisos — fuente única de verdad

Las 2 matrices completas (`All Repositories` y por rama) están codificadas
**una sola vez**, como dato ejecutable, en
`scripts/Invoke-AdoPermissionsRest.ps1::Get-AdoPermissionsMatrixDefinition`.
`references/permission-matrix.md` es una copia de solo lectura humana —
nunca la fuente de verdad. Cualquier cambio de matriz se hace únicamente
en esa función.

Resolución de acciones del security namespace "Git Repositories": por el
campo **estable** `name` de cada acción (nunca por `displayName` de UI —
hay discrepancias reales confirmadas entre el texto de la UI y el
`displayName` que devuelve la API, ver comentarios de
`Get-AdoPermissionsManagedActionCatalog`), y el bit real usado en cada ACE
es SIEMPRE el que devuelve la consulta en vivo, nunca un valor
hardcodeado — si la API cambia un nombre o bit, el plan se bloquea y
reporta la discrepancia.

## Preservación de bits no administrados

`newAllow = (currentAllow AND NOT managedMask) OR desiredAllow` (mismo
para deny) — `Get-AdoPermissionsRecomputedAceBits`. Nunca se reemplaza una
ACE completa sin haber preservado los bits que este dominio no administra.

## Preservación de identidades ajenas — nunca se borra un grupo (guardia dura)

Esto es distinto de preservar BITS dentro de una misma identidad (arriba):
la API `accesscontrollists` reemplaza el `acesDictionary` COMPLETO de un
token, no lo combina — un body que omite una identidad que ya tiene ACE
real ahí la BORRA (incidente real 2026-09-02, ver
`.cursor/memories/ado-permissions-builder/debugging.md` § "INCIDENTE
MAYOR 2"). Dos capas, ninguna opcional:

1. `New-AdoPermissionsPlan.ps1` siempre parte del `fullAcesDictionary`
   real del token (capturado por `Export-AdoPermissionsSecurityInventory.ps1`)
   y solo agrega/sobrescribe los 2 roles que administra.
2. `Invoke-AdoPermissionsRest.ps1` tiene una guardia dura que vuelve a
   consultar el estado en vivo justo antes de escribir y RECHAZA la
   operación (sin llegar a la red) si dejaría fuera a alguna identidad
   con ACE real hoy — sin flag para desactivarla, protege incluso un
   plan armado a mano. Ver `.cursor/rules/azure-devops-permissions/security.md`
   § "Guardia dura..." y el test 10d de `run-script-tests.ps1`.

## Prioridad: MCP primero, REST controlado para la brecha

1. MCP oficial `azure-devops` para proyectos/repositorios/ramas cuando la
   operación puntual lo exponga.
2. `Invoke-AdoPermissionsRest.ps1` (helper privado, nunca invocado directo
   desde Bash/PowerShell) para Graph Groups/Memberships y Security
   ACL/Namespaces — brecha real del MCP hoy, documentada en
   `references/ado-security-api-map.md`.
3. Toda escritura pasa por un plan validado + una entrada exacta de
   `approvedOperations` (operationType + method + uri + bodyHash +
   precondición) + journal de ejecución separado en
   `.local/azure-devops-permissions/executions/` (nunca reescribe el
   plan) + aprobación explícita.
4. Nunca sustituir una operación MCP o del helper por un `curl`/
   `Invoke-RestMethod`/`Invoke-WebRequest` suelto.

## Eliminaciones — siempre aparte

```text
New-AdoPermissionsDeletePlan.ps1 (exactamente 1 eliminación)
  → Test-AdoPermissionsDeletePlan.ps1
  → Apply-AdoPermissionsDeletePlan.ps1 (respaldo de solo lectura
    obligatorio antes del DELETE; tarjeta de aprobación separada)
```

`Apply-AdoPermissionsPlan.ps1` (el flujo principal) rechaza siempre
cualquier `DELETE`, `delete-security-group` o `remove-group-membership`.

## Probar scripts de escritura sin tocar la red real

`Apply-AdoPermissionsPlan.ps1` y `Apply-AdoPermissionsDeletePlan.ps1`
**nunca se invocan directamente** para probar cambios — si
`$env:AZURE_DEVOPS_PAT` está configurada (lo está normalmente en este
entorno, compartida con Pipelines), una invocación real llega a la
organización real aunque los datos sean ficticios. Sus fases viven en
funciones separadas y testeables
(`Invoke-AdoPermissionsApplyPhases`, `Invoke-AdoPermissionsDeleteApplyPhase`,
ambas en `Invoke-AdoPermissionsRest.ps1`) para poder dot-sourcearlas y
reemplazar `Invoke-AdoPermissionsRest` por una versión mockeada antes de
llamarlas — ver `scripts/tests/run-script-tests.ps1`.

## Modo pr-policy-admin: replicar Branch Policies entre repos

Implementado 2026-09-02 (ver `.cursor/memories/ado-permissions-builder/patterns.md`
§ "pr-policy-admin" para el detalle técnico completo). Replica Branch
Policies (Policy Configurations de PR: mínimo de revisores, work item
linking, comment requirements, merge strategy, required reviewers, build
validation) de un repo origen hacia uno o más branches de un repo
destino, dentro del mismo proyecto.

```text
Export-AdoPolicyInventory.ps1 (GET puro, origen y destino)
  → New-AdoPolicyPlan.ps1 (compara y genera SOLO creaciones nuevas;
    nunca actualiza ni duplica una policy que ya exista en destino)
  → Test-AdoPolicyPlan.ps1 (bodyHash, spec, antigüedad de inventarios,
    secretos, buildDefinitionIdOverride si aplica)
  → presentar el plan completo e invocar Apply-AdoPolicyPlan.ps1 en el
    mismo turno (una sola tarjeta de aprobación cubre todo el plan)
  → [OBLIGATORIO post-apply] Invoke-AdoRemapPolicyReviewers.ps1 para
    reemplazar el reviewer ID del proyecto modelo por el del grupo
    Code-Reviewers del proyecto destino en todas las políticas
    "Required reviewers" — sin este paso el reviewer apunta a un grupo
    ajeno. Uso (modo autodetect — recomendado):
      pwsh -File Invoke-AdoRemapPolicyReviewers.ps1 -Project '<proyecto-destino>'
    El script autodetecta OldReviewerId (IDs foráneos en las políticas) y
    NewReviewerId (Code-Reviewers del proyecto via Graph API). Pasar
    -OldReviewerId / -NewReviewerId explícitamente solo si el autodetect
    no puede resolverlos (proyecto sin grupo Code-Reviewers, múltiples
    grupos con ese nombre).
```

Reglas clave:

- Solo se replica una policy cuyo `scope` de origen tenga EXACTAMENTE 1
  elemento (repo+rama exactos) — cualquier otra forma se excluye y se
  reporta, nunca se asume.
- Si el destino ya tiene una policy del mismo `(type.id, refName)`, se
  excluye automáticamente — este modo solo crea, nunca actualiza.
- Una policy de tipo "Build" nunca se replica con el `buildDefinitionId`
  del origen tal cual (apunta al pipeline del repo ORIGEN) —
  `New-AdoPolicyPlan.ps1` exige `-BuildDefinitionIdOverride <id del Build
  del repo destino>` para incluirla, o excluirla del todo vía
  `-ExcludePolicyTypeIds`.
- `-ExcludePolicyTypeIds` (por defecto excluye Build) y `-Branches`
  permiten adaptar el alcance por repo destino (ej. un repo que todavía
  no tiene su propio pipeline de Build Validation, o que solo necesita
  algunas ramas).
- **Required reviewers — grupo del propio proyecto:** al replicar desde
  un proyecto modelo, el `requiredReviewerIds` del origen apunta al grupo
  `Code-Reviewers` del proyecto FUENTE. SIEMPRE reemplazar ese ID por el
  del grupo `Code-Reviewers` del proyecto DESTINO antes o después de aplicar.
  Nunca dejar un reviewer de otro proyecto (ej. `[Buklo]\\Code-Reviewers`)
  como reviewer requerido en repos de otro proyecto.
  Confirmado y corregido 2026-09-17 en 127 políticas de DB-Admin.

## Capacidad futura: repositorios y ramas

Este montaje implementa grupos/permisos y pr-policy-admin. No está
prohibido permanentemente ampliar el dominio con modos independientes
(`repository-admin`, `branch-admin`) cuando el usuario lo solicite — cada
uno exige su propio inventario, plan `actual → deseado`, aprobación y, si
aplica, respaldo. No crear cascarones para esto todavía.
