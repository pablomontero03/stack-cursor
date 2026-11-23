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
  `.claude/rules/azure-devops-permissions/security.md` § "Guardia dura...".
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
