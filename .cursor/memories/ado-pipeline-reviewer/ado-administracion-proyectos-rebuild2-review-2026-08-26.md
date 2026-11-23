---
name: ado-administracion-proyectos-rebuild2-review-2026-08-26
description: "Review outcome for the SECOND deliberate rebuild test of administracion-proyectos-web's classic AKS pipeline (2026-08-26), after the user found+fixed a 4th generator gap (-VariableGroupName casing). 4 plan files structurally clean and validated=true, but all 3 per-environment plans have empty approvedOperations -- Apply would be a no-op. Verdict: not yet ready for -Apply approval invitation."
metadata:
  type: project
---

**Context:** second round of the same real-deletion test as
[[ado-administracion-proyectos-rebuild-review-2026-08-26]] (VG
412/413/414, Build 623, Release 382 from round 1 were deleted again by
the user on purpose). Round 2 files:
`.local/azure-devops/plans/aks-administracion-proyectos-web-rebuild2-{desarrollo,uat,produccion,release}.json`.
The generator's 3 known gaps (CI trigger, "Produccion" hardcoded, pipeline/
artifactAlias casing) held up fine; the user found and fixed a 4th gap
directly (missing `-VariableGroupName` param, which without it produced
raw `Desarrollo-Administracion-Proyectos-Web` casing instead of the real
org value `Desarrollo-administracion-proyectos-web`) and regenerated all
3 plans with it before asking for review.

## Verified clean

- VG naming fix confirmed exact in all 3: `Desarrollo-administracion-proyectos-web`
  / `UAT-administracion-proyectos-web` / `Produccion-administracion-proyectos-web`
  (lowercase app segment, matches real org value, not raw casing).
- `variableGroup.keys.pipeline` / `release.artifactAlias` synced to
  `Build-administracion-proyectos-web` in all 3.
- `aksClusterName`/`aksResourceGroup` correctly absent from Dev/UAT keys,
  present with real values only in Producción
  (`gmon-prod-aks-eastus2-0004` / `gmon_prod_rg_eastus2_0001` — the
  correct `-0004` cluster, not the wrong `-0001` cluster id sometimes
  confused in this org).
- `preDeploymentApprovalRequired`/`preDeploymentApprovalGroup` (`[Shared-Service-GM]\Release
  Executers`) present ONLY in Producción; null/false in Desarrollo/UAT.
- `repo.ciEnabled`/`ciBranchFilters`/`ciBatchChangesEnabled` identical
  across all 3, matches the real deleted Build's trigger
  (`Build-administracion-proyectos-web.json`: branchFilters
  development/uat/release, batchChanges false, triggerType 2/CI).
- Task group ids/revisions (`Build-MultiStage` f214b26f, `Deployment-MultiStage-Cluster-Desarrollo`
  fc4043e2 for Dev/UAT, `Deployment-Azur-Aks-v3` 1fdf52f7 for Producción)
  and the approver id `397ddbfe-1d60-4533-a4c9-b099f80ac154` all
  cross-checked byte-for-byte against the real deleted reference JSONs.
- The 3 K8s manifests (`fixed-manifests/deployment-{dev,uat,prod}.yml` in
  the session scratchpad, same files as round 1) still preserve `#{...}#`
  tokens literally, Prod still correctly excludes `imagePullSecrets` and
  uses `ingressClassName: internal-ingress` (not `nginx`) — re-read and
  confirmed directly since the plan itself carries no manifest content.
  No stale `administracion-proyectos-manifests/` wrong-draft folder
  reappeared (stayed deleted from round 1's cleanup).
- `New-AdoReleaseEnvironmentEntry` used for the release assembly (plan's
  own note says so explicitly); `deployTaskGroupInputs` per stage match
  the historical Release 381 contract (9 inputs Dev/UAT, 5 inputs Prod).
- Zero secrets, zero unresolved generic placeholders (`PENDING_REAL_ID`
  in `-release.json` is deliberate and explained, same as round 1).
- `validationEvidence` complete and fresh in all 3 (~20 min gap between
  inventory generation and validation, well inside 24h caps).
- Family purity: `family: "aks"` in all 4, no DACPAC keys.

## BLOCKING finding

**All 3 per-environment plans (`-desarrollo`, `-uat`, `-produccion`) have
`approvedOperations: []`.** Unlike `-release.json` (whose empty
`approvedOperations` is explicitly explained in its own `notes` — real
VG/Build ids don't exist yet), the 3 environment files give no such
explanation, and this is a materially different state from round 1's
plans (which the prior review confirmed had real, hash-verified
`approvedOperations` entries before being cleared for `-Apply`).

Per `Apply-AdoClassicPlan.ps1`'s own docstring ("Orden de creacion:
Variable Group -> Build -> Release (solo las fases para las que el plan
trae una entrada de approvedOperations del operationType
correspondiente)"), invoking `-Apply` on these 3 files as they currently
stand would create **nothing at all** — a silent no-op, not an error.
This is a completeness gap, not a `Test-AdoClassicPlan.ps1` validity
bug (see [[patterns]] § "approvedOperations vacío tras regenerar el
plan" for the general lesson).

**Before inviting the user to approve `-Apply`:** compute and add
`approvedOperations` entries for `create-variablegroup` (x3, one per
environment) and `create-build-definition` (shared, using the
`fixed-manifests/` YAMLs — same content as round 1, so the previously
confirmed hash `990c0b9e...` should reproduce, but recompute rather than
assume since the VG name field is part of the hashed body), then
re-run `Test-AdoClassicPlan.ps1` to refresh `validationHash` on all 3.
`-release.json` correctly stays empty until the VG/Build ids are real.

## Secondary (non-blocking) item, carried over from round 1

Same as [[ado-administracion-proyectos-rebuild-review-2026-08-26]] item
2: `Test-AdoClassicPlan.ps1` still emits "confirmar con el usuario la
gobernanza de aprobación de Producción" in all 3 files even though the
plan already bakes in the historical Release Executers approver — ask
the user to explicitly re-confirm reusing that value rather than
treating it as silently inherited.

**Verdict given 2026-08-26 (round 2, first pass):** not yet ready for the
`-Apply` approval invitation — the empty `approvedOperations` on the 3
environment files must be resolved first (recompute + populate +
re-validate), and the Producción governance value should get an explicit
re-confirmation. Everything else checked out clean.

## RESOLVED same day — blocker closed

`ado-pipeline-builder` populated `approvedOperations`:
Desarrollo got `admproy-vg-desarrollo-r2` (create-variable-group) +
`admproy-build-r2` (create-build-definition, bodyHash `990c0b9e...`
matching the round-1-confirmed hash prefix for `fixed-manifests/`); UAT
got `admproy-vg-uat-r2`; Producción got `admproy-vg-produccion-r2` (all
create-variable-group). Re-ran `Test-AdoClassicPlan.ps1`, all 3 still
`validated=true`/no new blockers, `validationHash` refreshed, same fresh
inventory (`inventoryHash` unchanged).

Independently re-verified (read-only, no scripts executed by this
reviewer): all 4 `bodyHash` values are 64-hex-char; all `method`/`uri`
pairs match `Invoke-AdoRest.ps1`'s `$script:AdoAllowedOperationTypes`
spec exactly (host, path, api-version=7.1, no id suffix); both
`operationType` values are in `New-AdoClassicPayloads.ps1`'s allowed
`ValidateSet`; all `operationId`s unique across the 3 files;
`create-build-definition` correctly attached only to the Desarrollo file
(shared Build, same precedent as round 1); no other field in any of the
3 files changed versus the pre-fix version I'd already reviewed.

**Final verdict: ready to present the `-Apply` approval to the user**,
with the one carry-over caveat that Producción's pre-deployment approval
governance (reusing `[Shared-Service-GM]\Release Executers`) should get
an explicit re-confirmation from the user when asking, not be treated as
silently inherited.
