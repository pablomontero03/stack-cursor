---
name: ado-release-create-update-real-bugs-2026-08-26
description: "3 real findings applying the Administracion-de-proyectos Release definition for real (id 382): a generator bug that silently dropped reportarResultadoTaskGroupId/stageVariables at apply time (fixed, 2 new regression tests), a genuine Azure DevOps API constraint (can't create isAutomated=false with no approver in one POST), and journal-reconciliation mechanics after a rejected write."
metadata:
  type: project
---

Context: completing [[ado-classic-aks-plan-multi-env-generator-gaps]] by
actually creating the Release definition for `administracion-proyectos-web`
(Release id **382**) after VG 412/413/414 + Build 623 already existed.

## Bug fixed: `-ReleaseEnvironmentsPath` silently dropped `reportarResultadoTaskGroupId`/`stageVariables`

`Invoke-AdoApplyPhases`'s Fase 3 reconstructs `$environments` from the JSON
file at `-ReleaseEnvironmentsPath` with an explicit 7-key hashtable literal
that never included these two optional fields — even though
`New-AdoReleaseEnvironmentEntry` produces them and
`New-AdoReleaseDefinitionPayload` consumes them via `.ContainsKey()`. Net
effect: a body correctly APPROVED (hashed) with
`Reportar-resultado-HU`/`enableAccessToken=true` got silently rebuilt
WITHOUT them at apply time → real `Invoke-AdoRest` bodyHash mismatch,
rejected before any write (safe, but for the wrong stated reason — looked
like "someone edited the plan" when actually the reconstruction code itself
was incomplete).

**Fixed** in `New-AdoClassicPayloads.ps1`, `Invoke-AdoApplyPhases` Fase 3:
now conditionally carries through `reportarResultadoTaskGroupId` and
`stageVariables` when the source JSON has them, leaving old behavior
unchanged when they're absent. Locked with 2 new regression tests (group
right after "Ronda 2" E2E, `run-script-tests.ps1`) — 272/272 green.
**Lesson**: any field `New-AdoReleaseEnvironmentEntry` adds to an
environment entry in the future must ALSO be added to this reconstruction
block, or it'll repeat this exact class of bug silently.

## Real Azure DevOps constraint: can't create a Release with `isAutomated=false` and no approver in one POST

Confirmed via the new response-body diagnostic (see below): Azure DevOps
rejects `create-release-definition` with a stage whose
`preDeployApprovals.approvals[0].isAutomated=false` has no `approver`
assigned — `400`, `VS402896: One or more pre-approvals or post-approvals
in stage '<X>' has an empty approver. Specify an approver or set Is
Automated and try again.` `New-AdoReleaseDefinitionPayload` has no
`approver` support at create time at all (confirmed by grep — only
`isAutomated` toggle).

**This means the create-then-update two-phase pattern already documented
for Release 381 (see [[ado-administracion-proyectos-plan-status]] "Producción
approval gate finally built") is not just historical convenience — it's
REQUIRED by the API.** Any future app needing a real approval gate on a
stage must: (1) create the Release with that stage `ApprovalRequired=$false`
(temporarily automated, matching every other stage), (2) get the real
Release id via readback, (3) GET it fresh, strip GET-only fields (see
[[ado-put-update-field-stripping]]), mutate that stage's
`preDeployApprovals` (`isAutomated=false` + `approver={id=...}` +
`approvalOptions.releaseCreatorCanBeApprover=true`), and apply that as a
SEPARATE `update-release-definition` operation with its own approval
(never groupable with the create, per `authorization.md` "modificar...
requiere aprobación separada").

## Diagnostic improvement: `Invoke-AdoRest.ps1` now surfaces the real ADO error body

The write-failure catch block previously only exposed
`$_.Exception.Message` (generic "(400) Solicitud incorrecta", no detail —
by design, to never leak request body/headers). Added a SEPARATE, safe
capture of the RESPONSE body (`$_.ErrorDetails.Message`, the actual ADO
service JSON error like `VS402896: ...` — never the request we sent, never
Authorization) appended to the thrown message, truncated to 1000 chars.
This is what made finding the constraint above possible instead of
guessing blind. Confirmed no test broke (272/272) and no request
data/secrets are exposed by this — the response body from ADO's own
validation errors is safe to surface.

## Journal reconciliation after a rejected (400) write: must delete the whole file, not edit a key

A `400` (genuine server rejection, not network ambiguity) still gets
recorded as journal state `'ambiguous'` (the catch block can't
distinguish "definitely rejected" from "response lost in transit").
Retrying after independently confirming via readback that nothing was
created requires manual reconciliation — but **editing the journal file to
remove just that operation's key is treated as corruption and hard-blocks**
(`Get-AdoExecutionJournal`: "falta(n) la(s) operacion(es) ... Bloqueo
seguro -- nunca se re-agrega como 'pending' una operacion desaparecida de
un journal existente"). The safe reconciliation is to delete the ENTIRE
journal file for that `validationHash` (a journal that doesn't exist at
all is the normal/expected "no attempts yet" state) — never surgically
edit an existing one. Always confirm via `Test-AdoCreatedResources.ps1`
(fresh GET) that nothing was actually created before doing this.

## Minor, not acted on: `New-AdoReleaseEnvironmentEntry`'s default `-Tag` doesn't match the org's real convention

Field-by-field comparison of the final Release 382 against the saved
reference (`references/Deploy-Desarrollo-UAT-Produccion-Administracion-Proyectos-Web.json`,
the pre-deletion real Release 381) found ONE real difference beyond the
expected new resource ids (412/413/414 vs 409/410/411, Build 623 vs 622):
Desarrollo/UAT's `deployTaskGroupInputs.tag` came out as literal
`"$(Build.BuildId)"` (the function's default) instead of the org's actual
convention `"$(tag)"` (an extra indirection through the stage's own linked
Variable Group's `tag` variable, which itself equals `$(Build.BuildId)`).
Functionally equivalent at runtime (ADO resolves variable references
recursively), so this was NOT corrected unilaterally — flagged to the user
instead, since any correction is itself a Release-definition update
requiring its own separate approval. If asked to fix it: change
`-Tag` to `'$(tag)'` when calling `New-AdoReleaseEnvironmentEntry` for
`Deployment-MultiStage-Cluster-Desarrollo` stages (Producción's contract
doesn't have a `tag` input at all, unaffected).

## Outcome

Release 382 created + updated to revision 2, field-by-field match against
the real historical reference confirmed (all 3 stages' deploy task group
contracts, `Reportar-resultado-HU`/`enableAccessToken`, Producción's real
approval gate with the correct approver). Full pipeline
(VG 412/413/414 + Build 623 + Release 382) now reproduces the deleted
original exactly, module the one cosmetic `tag` difference above. Zero
Builds queued, zero Release instances created, zero deploys, at every step.
