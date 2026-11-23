---
name: ado-administracion-proyectos-rebuild-review-2026-08-26
description: "Review outcome for the from-scratch rebuild of administracion-proyectos-web's classic AKS pipeline (VG x3 + Build + Release) after the user's deliberate real-resource deletion test. 4 plan files, all validated=true/zero blockers from Test-AdoClassicPlan.ps1; reviewer found 2 open items before Apply, everything else checked out clean against the real (now-deleted) Build 622/Release 381 JSON snapshots."
metadata:
  type: project
---

**Context:** user deliberately deleted the real Build, Release definition
and 3 Variable Groups of `administracion-proyectos-web` (org
`Shared-Service-GM`, project `DevOps`) to test a full reconstruction with
`New-AdoClassicAksPlan.ps1` + `New-AdoReleaseEnvironmentEntry`. See
`.claude/agent-memory/ado-pipeline-builder/ado-classic-aks-plan-multi-env-generator-gaps.md`
for the builder-side gaps found doing this. Reference-only JSON snapshots
of the real (deleted) Build 622 / Release 381 live at
`references/Build-administracion-proyectos-web.json` and
`references/Deploy-Desarrollo-UAT-Produccion-Administracion-Proyectos-Web.json`.

## Verified clean (no action needed)

- Family purity (`family: "aks"` in all 4, no DACPAC keys mixed in).
- No id/branch/pool/task-group/cluster blindly copied from guides — repo
  id, task group ids/revisions, cluster `gmon-prod-aks-eastus2-0004` +
  RG `gmon_prod_rg_eastus2_0001` all independently cross-checked against
  the real deleted definitions' JSON and Test-AdoClassicPlan.ps1's live
  inventory resolution.
- CI trigger (`ciEnabled`/`ciBatchChangesEnabled`/`ciBranchFilters`)
  identical across all 3 per-environment plan files, matches the real
  Build 622 trigger exactly.
- Per-environment override hygiene (Gap 2/3 from the builder-gaps memory)
  correctly applied: no leftover "Produccion"/"prod" casing in
  Desarrollo/UAT's `names.*`, `variableGroup.name`, `keys.ambiente`,
  `keys.pipeline`, `release.stage`, `release.artifactAlias`.
  `aksClusterName`/`aksResourceGroup` correctly absent from Dev/UAT keys;
  `conexkubernetes`/`serviceConnectionAks` correctly blank only in
  Producción.
- Producción pre-deployment approval fields (group `[Shared-Service-GM]\Release
  Executers`, approver id `397ddbfe-1d60-4533-a4c9-b099f80ac154`) match the
  real deleted Release 381's environment id 509 exactly; correctly absent
  from Desarrollo/UAT.
- `-release.json`'s `approvedOperations` correctly empty, `PENDING_REAL_ID`
  never hashed, note explains why (real VG/Build ids don't exist yet).
- `plannedEnvironmentsAssembly` deployTaskGroupInputs contract fidelity
  verified byte-for-byte against the real deleted Release 381's
  `workflowTasks.inputs` for both `Deployment-MultiStage-Cluster-Desarrollo`
  (9 inputs, Desarrollo/UAT) and `Deployment-Azur-Aks-v3` (5 inputs,
  Producción).
- Build task group `Build-MultiStage` (current standard), merge-batching
  8-piece mechanism enabled with real resolved ids, `Reportar-resultado-HU`
  build-side `alwaysRun=false` confirmed both in plan intent and in
  `New-AdoClassicPayloads.ps1` source (build side false / release side
  true — matches Build 622/Release 381 exactly).
- Zero secrets, zero unresolved placeholders, all `approvedOperations`
  bodyHashes are 64-hex-char (SHA-256 shape), unique operationIds, URIs
  under `Shared-Service-GM`/`DevOps`.

## Open items before inviting the user to approve `-Apply`

1. **Manifest ambiguity** — see
   [[ado-plan-bodyhash-only-manifest-verification-gap]]. Two conflicting
   sets of the 3 K8s manifest files exist in the session scratchpad; must
   confirm with the builder which exact files map to `admproy-build`'s
   approved bodyHash, and get the wrong draft folder
   (`administracion-proyectos-manifests/`) deleted/quarantined before
   anyone runs `Apply-AdoClassicPlan.ps1`.
2. **Producción governance re-confirmation** — `Test-AdoClassicPlan.ps1`
   itself still emits the warning "Confirmar con el usuario si el stage
   Producción requiere pre-deployment approval según la gobernanza
   vigente del producto" in all 3 per-environment files, even though the
   plan already bakes in the historical Release Executers approver. Since
   this is a rebuild of a deleted-on-purpose real pipeline, reusing the
   old value is a reasonable default, but the user should explicitly
   re-confirm it rather than have it silently carried over.

**Verdict given 2026-08-26:** not yet ready for the Apply approval
invitation until both items above are closed; everything else in the 4
files is structurally sound and consistent with the real (deleted)
definitions.
