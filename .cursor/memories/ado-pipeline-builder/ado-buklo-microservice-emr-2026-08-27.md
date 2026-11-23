---
name: ado-buklo-microservice-emr-2026-08-27
description: EMR (8th Buklo microservice) prep completed with zero scratch scripts, using New-AdoClassicCreatePlan.ps1 + New-AdoClassicUpdatePlan.ps1 for the first time end-to-end; found a real cross-app VG-linkage bug and confirmed the 2-phase Library-creation constraint
metadata:
  type: project
---

2026-08-27, same day as [[ado-emr-scratch-script-authorization-declined-2026-08-27]]
and [[ado-update-plan-runner-added-2026-08-27]]. A later invocation (still
prep-only, no Apply, no ExitPlanMode — this agent never owns that) asked to
finish EMR (Build 591 / Release 373 / VG Producción 398) using the two
versioned runners built earlier that same day. Completed cleanly with
**zero scratch scripts** — first real end-to-end use of
`New-AdoClassicCreatePlan.ps1` (Kind VariableGroup) and
`New-AdoClassicUpdatePlan.ps1` (both Kinds, chained via `-ExistingPlanPath`)
for a real microservice, closing the loop from the same-day decline.

**Real finding (not introduced by this task, pre-existing infra bug):**
Release 373's Desarrollo (env 473) and UAT (env 474) environments were
linked to `variableGroups: [383]`/`[384]` — confirmed via inventory lookup
that VG 383/384 are actually **`Desarrollo-Buklo-ontology-web`** /
**`UAT-Buklo-ontology-web`**, a completely different microservice's
Libraries, not EMR's. Same bug family as the Engine
Gateway-content-in-Build finding ([[ado-buklo-microservice-engine-2026-08-27]])
but on the Release/VG-link side instead of Build file-creator content.
Confirms the task's premise (new correct Libraries + relink) was a real
fix, not precautionary busywork. **Not yet fixed** — see Phase 2 below.

**Confirmed constraint (answers the question the coordinator asked to
verify):** creating a Variable Group and relinking a Release environment
to its real id can NEVER be the same plan/Apply. Two independent reasons,
both structural, not workarounds:
1. `New-AdoClassicCreatePlan.ps1` explicitly documents (and enforces via
   `New-AdoClassicUpdatePayload.ps1`'s `Set-AdoReleaseEnvironmentVariableGroups`
   splice requiring `[int[]]`) that Azure DevOps only assigns the VG's
   real id at POST-creation time — never invented/predicted.
2. `approvedOperations` (both `New-AdoClassicCreatePlan.ps1` and
   `New-AdoClassicUpdatePlan.ps1`) rejects a 2nd operation of the **same
   operationType** in one plan — so even 2 `create-variable-group`
   operations (Desarrollo + UAT Libraries) can't share a plan file, each
   needs its own plan+Apply, regardless of the id problem.

**What COULD be done in Phase 1 despite the above:** the VG relink itself
was blocked, but `Add-AdoReleaseEnvironmentCdTrigger` (sourceBranch +
artifactAlias) has no such dependency — added CD triggers for
Desarrollo/UAT env in the same Phase 1 Release update PUT as the existing
Producción Reportar-resultado-HU + approval gate splices, since a
Release definition PUT is one full-body-per-definition call anyway (all 3
envs always travel together in one PUT, whether or not all 3 changed).
Confirmed via fresh GET that env 473/474 had **empty `conditions: []`**
before this change — no CD trigger existed at all, not even a wrong one.

**Result: 1 approval, 3 Apply commands** (not 1, not 4) — VG Desarrollo
create, VG UAT create, and Build 591 + Release 373 combined update (file
creator dev/uat + merge batching on Build; CD triggers Desarrollo/UAT +
Reportar-resultado-HU/gate Producción on Release, all in ONE
update-release-definition PUT). All 3 validated zero-blocker against a
fresh inventory (`Export-AdoClassicInventory.ps1`, same session). Phase 2
(VG relink for env 473/474 to the real new Library ids) is explicitly
**deferred** — cannot be prepared until Phase 1's 2 Library-creation
Applies actually run and a fresh readback confirms their real ids; a
future session/task, its own plan, its own approval.

**Design note confirmed while building the VG skeleton plans:**
`New-AdoClassicAksPlan.ps1` remains the only versioned way to produce the
`variableGroup.name/keys` shape `New-AdoClassicCreatePlan.ps1 -Kind
VariableGroup` needs, even when only a Library (no new Build/Release) is
actually wanted — just accept the extra unused fields (repo/dockerfile/
mergeBatching) it generates; `Test-AdoClassicPlan.ps1`'s
`planDeclaresNoNewBuild` skip (once `create-variable-group` is the only
approved op) makes the unrelated repo/dockerfile checks warnings, not
blockers, so this is safe/expected, not a workaround. Used
`-DeployTaskGroupName 'Deployment-MultiStage-Cluster-Desarrollo'` (not the
default `'Deployment-Azur-Aks-v3'`) to get the real Dev/UAT 14-key shape
(no `aksClusterName`/`aksResourceGroup`) — confirmed against EMR's own
live Release 373 Desarrollo/UAT `workflowTasks` which already use that
exact task group name/id, same convention as
[[ado-classic-aks-variablegroup-template]].

**Real secret observed, never printed/stored:** Release 373's per-environment
`variables.containerRegistryPassword` returns a live plaintext value via
GET (not masked, `isSecret` unset) — same shape as previously known
`isSecret` gaps on this org's container registry password variables
(see [[ado-buklo-dev-uat-convention]] Engine follow-up). Field-stripping
(`ConvertTo-AdoUpdateReleaseBody`) correctly leaves `environments[].variables`
untouched (pre-existing live value, not something this update introduces
or duplicates) — flagged here only as an observation, no action taken,
consistent with the standing "Buklo Build 552 hardcoded secrets" pattern
of not re-extracting/acting on unrelated pre-existing findings.

See also [[ado-emr-scratch-script-authorization-declined-2026-08-27]] and
[[ado-update-plan-runner-added-2026-08-27]] for the same-day runner build
this task validated in real use.
