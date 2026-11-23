---
name: ado-classic-aks-plan-multi-env-generator-gaps
description: "RESOLVED 2026-08-26 and CONFIRMED same day by a 2nd from-scratch rebuild test (zero manual JSON patches, ~17min vs ~78min): the 3 real gaps found reconstructing Administracion-de-proyectos (CI trigger fields, hardcoded 'Produccion' flavor, pipeline/artifactAlias casing desync) are fixed IN New-AdoClassicAksPlan.ps1 itself via new optional params (-Stage/-DisableCi/-CiBranchFilters/-BuildName/-ReleaseName/-ExtraVariableGroupKeys/-PreDeploymentApprovalRequired). Kept below for historical context and to document exactly what changed."
metadata:
  type: project
---

**Context:** user deliberately deleted the real Build/Release/3 Variable
Groups of `administracion-proyectos-web` (org `Shared-Service-GM`, project
`DevOps`) to test a full from-scratch reconstruction using the CURRENT
generator + automations (`Build-MultiStage`, 8-piece merge batching,
fixed K8s manifest template). See [[ado-administracion-proyectos-plan-status]]
for the original build history. Rebuilding it exposed 3 real gaps in
`New-AdoClassicAksPlan.ps1` that aren't bugs in the sense of wrong output,
but missing capabilities that force a manual post-generation patch every
time — worth doing right once and remembering, rather than rediscovering
per app.

## Gap 1: `plan.repo` never gets `ciEnabled`/`ciBatchChangesEnabled`/`ciBranchFilters`

`New-AdoClassicAksPlan.ps1`'s `repo` object only ever contains
`name`/`prodBranch`/`pathFilter`/(later)`id`. But
`New-AdoBuildDefinitionPayload` (in `New-AdoClassicPayloads.ps1`) throws
if `plan.repo.ciBranchFilters` is missing — it's a hard requirement to
build the Build's trigger. There is no generator parameter for this today.

**How to apply:** after generating (and before the first
`Test-AdoClassicPlan.ps1` run against real dependencies), add to
`plan.repo` by hand: `ciEnabled=true`, `ciBatchChangesEnabled=false`,
`ciBranchFilters=[...]` (the actual CI branches, e.g.
`["development","uat","release"]` — confirm the real branch list/casing
against the live repo inventory, never assume). This is the SAME shared
value across all per-environment plan files for one app (it describes the
Build's own trigger, not a per-stage thing).

## Gap 2: the generator hardcodes a single "Producción" flavor regardless of which environment you're planning

Already partially known (see [[ado-batching-phases-standing-convention]]:
"`release.stage` still hardcoded `'Produccion'` on purpose"), but the
full list of fields that need a manual per-environment patch after
running the generator for Desarrollo/UAT is:

- `plan.names.variableGroup`, `plan.variableGroup.name` — generator
  always writes `"Produccion-$Producto-$App"`.
- `plan.variableGroup.keys.ambiente` — generator always writes `'prod'`.
- `plan.release.stage` — generator always writes `'Produccion'`.
- `plan.release.stageAutoDeploy` / `plan.release.preDeploymentApprovalRequired`
  — the generator's `release` object doesn't even HAVE these two
  properties (not just wrong values) — must `Add-Member -Force`, not a
  plain property assignment (a plain `$plan.release.stageAutoDeploy = ...`
  throws "property not found on this object").
- Any extra non-standard VG key (e.g. this app's `loglevel`) — the
  generator has no parameter for it; add via `Add-Member -Force` on
  `variableGroup.keys` per environment with its own value.
- `aksClusterName`/`aksResourceGroup` in `variableGroup.keys` — the
  generator ALWAYS adds both (they're Mandatory params). For an
  environment whose real Variable Group doesn't carry them (Dev/UAT here,
  because they use `Deployment-MultiStage-Cluster-Desarrollo` instead of
  `Deployment-Azur-Aks-v3`), pass real-but-transient values to satisfy the
  Mandatory+placeholder-check at generation time, then
  `$plan.variableGroup.keys.PSObject.Properties.Remove(...)` both keys
  post-generation. Never pass a fake/placeholder-looking string (would
  trip the placeholder-scan blocker even though you're about to delete
  the key) — use a real value you're about to discard instead.
- `conexkubernetes` + `dependencies.serviceConnectionAks` — for an
  environment where Producción-style config means "no Kubernetes service
  connection at all" (confirmed per-app, not assumed), generate with a
  real transient value (`ConexKubernetes` is Mandatory too), then blank
  `variableGroup.keys.conexkubernetes = ''` and
  `dependencies.serviceConnectionAks = { name='', id=$null }`
  post-generation. `Test-AdoClassicPlan.ps1` already has the fix (2026-08-25)
  to skip requiring this service connection when
  `dependencies.deployTaskGroup.name -eq 'Deployment-Azur-Aks-v3'` and the
  name is left blank — no blocker results.

**How to apply:** run `New-AdoClassicAksPlan.ps1` once per environment
(3 separate invocations for Desarrollo/UAT/Producción, each with its own
real `-Namespace`/`-ConexKubernetes`/`-DeployTaskGroupName`/`-ProdBranch`/
`-ReqCpu` etc.), then apply the patch list above per environment before
the first `Test-AdoClassicPlan.ps1` run. Never skip straight to
`Test-AdoClassicPlan.ps1` on the raw generator output for anything but a
single-stage "Producción-only" app — it will validate fine (structurally
correct) but describe the WRONG environment.

## Gap 3: naming casing propagates from `-Producto`/`-App` into fields you didn't override

If you pass `-Producto`/`-App` with the casing needed for `plan.names.folder`
(e.g. `-Producto 'Administracion-Proyectos' -App 'Web'` to get folder
`\Administracion-Proyectos`), the generator ALSO uses that same casing for
`plan.variableGroup.keys.pipeline` (`"Build-$Producto-$App"`) and
`plan.release.artifactAlias` (`"_Build-$Producto-$App"`) — even after you
override `plan.names.build` to the real (lowercase) Build name, those two
derived fields are silently left in the wrong casing unless you fix them
too. `pipeline` is a Variable Group value referenced by the Release
task's `$(pipeline)` input, and `artifactAlias` must match the real
Build's artifact alias — both matter functionally, not just cosmetically.

**How to apply:** after overriding `plan.names.build`, always also set
`plan.variableGroup.keys.pipeline` and `plan.release.artifactAlias` to
`"Build-<real-lowercase-name>"` / `"_Build-<real-lowercase-name>"`
explicitly, per environment. Don't assume overriding `names.build` alone
is enough.

## Reminder (not a new gap, just re-confirmed the hard way): avoid the bare Spanish word "todo" in any plan note

`Test-AdoClassicPlan.ps1`'s placeholder-scan regex (`\btodo\b`,
case-insensitive) flags the standalone Spanish word "todo" as if it were
the English placeholder TODO — this is documented as intentional in the
script's own comments (a real note could legitimately need that word, so
it isn't excluded from the scan). Hit this personally while writing a
note containing "reconstruir todo desde cero" — had to reword to
"reconstruir el pipeline completo desde cero". Just phrase around it,
don't fight the scanner.

## Outcome of applying all of the above (2026-08-26)

Produced 4 plan files, all `validated=true`, zero blockers (only the
2 expected informational warnings: no agent pool specified, confirm
Producción governance) against a fresh merged inventory
(`DevOps` + `Administracion-de-proyectos` projects):

- `aks-administracion-proyectos-web-rebuild-desarrollo.json` —
  `approvedOperations`: `create-variable-group` (Desarrollo) +
  `create-build-definition` (the one shared Build, built from this
  environment's plan object per precedent — Build doesn't link any VG,
  so its own `ambiente` build variable is just a Build-MultiStage
  `ambienteOverride=auto` fallback default).
- `aks-administracion-proyectos-web-rebuild-uat.json` — `approvedOperations`:
  `create-variable-group` (UAT) only.
- `aks-administracion-proyectos-web-rebuild-produccion.json` —
  `approvedOperations`: `create-variable-group` (Producción) only.
- `aks-administracion-proyectos-web-rebuild-release.json` —
  `approvedOperations` deliberately EMPTY: `create-release-definition`'s
  real body needs the 3 Variable Groups' real ids (assigned by the server
  only once Phase 1 of each of the 3 files above actually runs) and the
  Build's real id (Phase 2) — none exist yet in this reconstruction test,
  and inventing placeholder ids to compute a hash today would violate the
  "never invent an unconfirmed resource id" rule. This file instead
  documents the exact `New-AdoReleaseEnvironmentEntry` calls to run (with
  real, already-resolved `deployTaskGroupId` per stage) once the VG/Build
  apply phase completes, under a `plannedEnvironmentsAssembly` field
  (`variableGroupId`/`buildDefinitionId` marked literally
  `"PENDING_REAL_ID"`, a string that doesn't trip the placeholder
  scanner).

**How to apply next time (superseded by the fix below for gaps 1-3 —
step 6, the Release-assembly order, is still current):** this was the
order of operations before the generator fix: (1) generate N per-env base
plans, (2) apply the Gap 1-3 patches above BY HAND, (3)
`Test-AdoClassicPlan.ps1` each, (4) compute `create-variable-group` (and
`create-build-definition`, attached to exactly one environment's plan —
Desarrollo by precedent) `approvedOperations` via the real
`New-Ado*Payload` functions + `New-AdoApprovedOperationEntry`, (5)
re-validate to refresh `validationHash`, (6) leave
`create-release-definition` unhashed/undocumented-as-approved until a
prior apply phase has produced real VG+Build ids — never fabricate them.

## RESOLVED 2026-08-26 — all 3 gaps fixed directly in `New-AdoClassicAksPlan.ps1`

User asked to fix the generator itself, explicitly "con cuidado de no
romper nada y que de el mismo resultado" — done as pure additive
parameters, all with defaults that reproduce the exact previous output
when omitted. 325/325 tests green (was 310 before this fix), including
15 new tests (`Grupo C2`) specifically exercising the fix against a
fixture reproducing this app's real values.

- **Gap 1 fixed**: new `-CiBranchFilters` (default
  `@('development','uat','release')`, matches every real example) and
  `-DisableCi` (inverted switch, same PS 5.1 bool-via-`-File` pattern
  already used for `-DisableMergeBatching` — a plain `[bool]$CiEnabled = $true`
  can't be turned off reliably via `-File`). `repo.ciBatchChangesEnabled`
  is hardcoded `$false` (matches every real example, no param needed).
  `plan.repo` now always has all 3 fields — no more hand-patching before
  the first real `Test-AdoClassicPlan.ps1`/apply attempt.
- **Gap 2 fixed**: new `-Stage` (`ValidateSet Desarrollo/UAT/Produccion`,
  **default `Produccion`** — preserves the exact old hardcoded behavior
  for any caller not passing it) drives `variableGroup.name`,
  `keys.ambiente`, `release.stage`. `AksClusterName`/`AksResourceGroup`
  are no longer `[Parameter(Mandatory)]` — enforced only when
  `-DeployTaskGroupName -eq 'Deployment-Azur-Aks-v3'` (the default), and
  when a different deploy task group is used they're simply never added
  to `variableGroup.keys` (no more `Remove()` after the fact) — passing
  them anyway with a non-AKS-v3 deploy task group now throws explicitly
  instead of silently producing a stray key. `ConexKubernetes` is also no
  longer Mandatory (default `''`, matching the real "no k8s service
  connection" pattern already used for this app's own Producción).
  `release.stageAutoDeploy` now always exists with a real per-stage
  default (Desarrollo=true, UAT/Produccion=false — the confirmed real
  pattern); `preDeploymentApprovalRequired`/`Group` also always exist,
  but are NEVER defaulted to true even for Produccion — still require the
  explicit `-PreDeploymentApprovalRequired` switch +
  `-PreDeploymentApprovalGroup`, per `authorization.md`'s standing rule
  that this governance is never assumed. `-ExtraVariableGroupKeys` (new,
  format `'clave=valor;clave=valor'`) replaces the old `Add-Member -Force`
  need for non-standard keys like `loglevel`.
- **Gap 3 fixed**: new `-BuildName`/`-ReleaseName` overrides are now the
  ONLY source of `names.build`/`names.release` AND automatically drive
  `variableGroup.keys.pipeline`/`release.artifactAlias` from the same
  value — overriding the Build name can no longer leave those 2 fields
  desynced, because there's no longer a separate place to override them.

**2 more real PowerShell `-File`/`&` argument-passing bugs found writing
the tests for this fix (neither specific to this generator — both are
general traps worth remembering for ANY future parameter design on a
script invoked this way):**
1. Passing an explicit **empty string** (`-ConexKubernetes ''`) to a
   script invoked via `& powershell -File`/`&` gets silently DROPPED by
   PowerShell when building the child process's command line — every
   parameter after it then shifts by one and binds to the wrong value,
   producing a confusing "missing argument" error on a LATER parameter,
   not the one actually at fault. Fix/rule: to get an optional
   string param's empty default, always OMIT it — never pass `''`
   explicitly across a process boundary.
2. Passing a string containing **embedded double quotes** (e.g. a raw
   JSON blob `'{"loglevel":"info"}'`) through the same `& -File`
   boundary can lose those quotes in transit, corrupting the payload
   silently (arrived as `{loglevel:info}`, invalid JSON). Fix: never
   design a `-File`-invoked parameter around a quoted/structured format
   (JSON, hashtable literal) — use a flat delimiter format with no quote
   characters at all (this fix uses `key=value;key=value`).

Both were caught by directly testing the real script invocation (not
assumed) — same "verify before trusting" discipline as everywhere else in
this domain.

## CONFIRMED 2026-08-26 (same day, later) — 2nd from-scratch rebuild test, zero manual JSON patches

User deleted the real Build/Release/3 Variable Groups of
`administracion-proyectos-web` a SECOND time specifically to test whether
the fix above actually eliminates hand-patching (not just in theory).
Result: **zero manual edits to any of the 3 generated plan files.**
`New-AdoClassicAksPlan.ps1` run 3 times (Desarrollo/UAT/Producción) with
`-Stage`/`-CiBranchFilters` (default)/`-BuildName`/`-ReleaseName`/
`-ExtraVariableGroupKeys`/`-PreDeploymentApprovalRequired`+`-Group`,
omitting `-AksClusterName`/`-AksResourceGroup`/`-ConexKubernetes` for
Desarrollo/UAT and omitting `-ConexKubernetes` for Producción exactly as
documented — every field (`repo.ciBranchFilters`, `variableGroup.name`,
`keys.ambiente`, `release.stage`/`stageAutoDeploy`/
`preDeploymentApprovalRequired`/`Group`, `keys.pipeline`/
`release.artifactAlias` synced to the real lowercase Build name,
`keys.loglevel` via `-ExtraVariableGroupKeys`, no stray
`aksClusterName`/`aksResourceGroup`/`conexkubernetes` key where they
don't belong) came out correct on first generation. All 3
`Test-AdoClassicPlan.ps1` runs: `validated=true`, zero blockers, same 2
informational warnings as the first rebuild (no agent pool; confirm
Producción governance — the governance warning fires regardless of
`-Stage`, confirmed not a bug, just an unconditional reminder).

Elapsed time this round: **~17 minutes** end to end (export+merge
inventory, 3 plan generations, 3 validations, release-assembly
documentation file) vs ~78 minutes for the first hand-patched rebuild —
matches the expectation that closing the 3 gaps directly in the generator
removes the dominant cost, not just shifts it.

The only post-generation script run was the release-definition assembly
(`New-AdoReleaseEnvironmentEntry` called with a transient `-VariableGroupId 0`
then overwritten to the literal string `'PENDING_REAL_ID'` before writing
to disk) — this is NOT a generator gap, it's an inherent ordering
constraint (the Variable Groups/Build must exist for real before a
Release definition body can reference their real ids), identical to how
the first rebuild handled it. Don't conflate this with the 3 resolved
gaps above.

Plan files from this 2nd test:
`aks-administracion-proyectos-web-rebuild2-{desarrollo,uat,produccion,release}.json`
under `.local/azure-devops/plans/` (release file deliberately has empty
`approvedOperations`, same reasoning as the first rebuild's
`-rebuild-release.json`). Stopped before `Apply-AdoClassicPlan.ps1` by
explicit request — handed off for `ado-pipeline-reviewer` review first.

## Follow-up same session: reviewer caught a real gap in MY own process, not the generator

Main session added `-VariableGroupName` to the generator and regenerated
the 3 env plans (fixing a VG-name issue), then had `ado-pipeline-reviewer`
check them. Reviewer found ONE real blocker: **I never completed the
`approvedOperations` computation step this round** — I stopped right
after `Test-AdoClassicPlan.ps1` (per the original instruction to halt
before Apply), leaving `approvedOperations=[]` on all 3 env plans. That's
correct at that checkpoint, but incomplete once asked to prepare for
Apply: an empty `approvedOperations` makes `Apply-AdoClassicPlan.ps1` a
silent total no-op (zero writes, no visible error) — worth remembering
as a real reviewable state, not just "validated=true means ready to
apply". `validated=true` only means the plan's shape/ids are internally
consistent against inventory; it says nothing about whether
`approvedOperations` has actually been populated with real hashed
bodies.

Fixed by re-running the exact same `New-AdoVariableGroupPayload` (x3) +
`New-AdoBuildDefinitionPayload` (once, attached to Desarrollo only, same
precedent as the 1st rebuild) + `New-AdoApprovedOperationEntry` recipe as
the 1st rebuild, then re-running `Test-AdoClassicPlan.ps1` on all 3 to
refresh `validationHash` (same merged inventory, still inside the 24h
window). All 3 came back `validated=true`, zero blockers, same 2
informational warnings.

**Confirmed the Build manifest content came from the RIGHT source**
(`fixed-manifests/deployment-{dev,uat,prod}.yml`, not the visually
identical copies at the scratchpad root, not any other draft): read via
`Get-Content -Raw` PowerShell auto-strips a UTF-8 BOM, so the
`fixed-manifests/` copies (which have a BOM) and the scratchpad-root
copies (no BOM) hash identically once read this way — verified this
explicitly with `-ceq` before trusting it. Then did an independent
recompute of the build's `bodyHash` straight from `fixed-manifests/`
(matched exactly) plus a negative-control mutation of one manifest
character (produced a different hash) to prove the hash is genuinely
sensitive to that exact content, not a coincidence or stale value.

**Standing takeaway**: when a task explicitly says "stop before Apply",
remember that stopping there is a real, distinct state from "ready for
Apply" — `approvedOperations=[]` is valid mid-flow but must be flagged as
still-pending in the handoff, not left for the reviewer to catch as if it
were a bug in the generator.
