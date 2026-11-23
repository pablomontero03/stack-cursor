---
name: ado-update-plan-runner-added-2026-08-27
description: Closed the 2nd real gap from the EMR scratch-script decline — New-AdoClassicUpdatePlan.ps1 is now a versioned runner around New-AdoClassicUpdatePayload.ps1, tested, never touched real Azure DevOps
metadata:
  type: project
---

2026-08-27, same day as [[ado-emr-scratch-script-authorization-declined-2026-08-27]].
The coordinator re-invoked with an explicit, narrowly-scoped dev task
(build the missing versioned runner, 100% local, zero real ADO GET/PUT/
POST beyond the runner's own read-only GET, zero Plan/ExitPlanMode/Apply)
— accepted and completed, since this doesn't touch any real resource and
doesn't need `EnterPlanMode`/`ExitPlanMode` (that flow is specifically for
Azure DevOps write approvals, not for adding a local script+tests to the
repo).

**What was built:**

- `Invoke-AdoClassicUpdatePlanGeneration` (new function, appended to
  `New-AdoClassicUpdatePayload.ps1` — kept as a functions-only file on
  purpose, same reason `Invoke-AdoApplyPhases` lives in
  `New-AdoClassicPayloads.ps1` rather than in `Apply-AdoClassicPlan.ps1`:
  a file with only function definitions can be dot-sourced and tested
  in-process with `Invoke-WebRequest` mocked; a file with a top-level
  `param()` block + real execution cannot, without spawning a real
  process with no way to mock the network).
- `New-AdoClassicUpdatePlan.ps1` (new file) — deliberately thin CLI
  wrapper: `param()` block, 3 dot-sources in the required order
  (`Invoke-AdoRest.ps1`, `New-AdoClassicPayloads.ps1`,
  `New-AdoClassicUpdatePayload.ps1`), one call to the function via
  `@PSBoundParameters`, then `Write-Host` summary. No logic of its own.
- Closed dispatch: `Invoke-AdoUpdateSplice` (`New-AdoClassicUpdatePayload.ps1`)
  — a literal PowerShell `switch` over the 10 known splice function names,
  never `Invoke-Expression`/`&`-on-a-string/`Get-Command` on an externally
  supplied name. An unknown name hits `default` and throws before
  anything executes. Verified live (not just by inspection) that
  `'Remove-Item'`/`'Invoke-Expression'` passed as `-FunctionName` are
  rejected without side effects.
- `ConvertTo-AdoHashtableDeep` — recursive `PSCustomObject`/array →
  `[ordered]` hashtable converter, needed because JSON-parsed splice
  entries can't be splatted directly (PowerShell splatting needs
  `IDictionary`, not `PSCustomObject`), and functions like
  `Add-AdoBuildVariables -Variables [hashtable]` need real hashtables.
  Confirmed live that `[ordered]@{}` built this way still binds
  case-insensitively when splatted (`'displayName'` key binds `-DisplayName`)
  — this is what lets the JSON spec use plain camelCase without a mapping
  table.
- 2 generation modes: `-ExistingPlanPath` (append this operation onto any
  plan already emitted by this skill — rejects a 2nd operation of the
  same `operationType`, always forces `validated=false`/clears
  `validationHash` even if the source plan was already validated) or a
  fresh **aks-only** minimal skeleton (no `-ExistingPlanPath`) requiring
  `-BuildName`/`-ReleaseName`/`-ServiceConnectionAcrName`/
  `-ArtifactFilterBranch` — deliberately did NOT build a dacpac
  fresh-skeleton path (no active dacpac work right now; `-ExistingPlanPath`
  covers that family if ever needed).
- `Set-AdoFileCreatorContent` splice entries accept `fileContentPath` (or
  alias `contentPath`) instead of inlining the whole rendered manifest
  into the JSON spec — reads the file raw, same
  `ConvertTo-AdoNormalizedRawString` workaround already inside
  `Set-AdoFileCreatorContent` applies automatically.

**Design decisions I had to resolve myself (task said "ajustalo si
encontrás algo mejor"):**

1. Original ask implied one script; I split it into a thin wrapper +
   library function specifically so it could be tested without a real
   network call — this wasn't spelled out in the request but is the only
   way to satisfy "agregá cobertura... mocks, fixtures sintéticas, sin
   red real" for a script that does a live GET.
2. Test-AdoClassicPlan.ps1 unconditionally resolves
   `dependencies.buildTaskGroup`/`deployTaskGroup`/`serviceConnectionAcr`
   even for an update-only plan (never actually needed to create a Build)
   — this is pre-existing validator behavior, not something I patched;
   the fresh-skeleton mode just populates those fields with real org
   defaults (`Build-MultiStage`/`Deployment-Azur-Aks-v3`) so validation
   against a live inventory will actually pass later.
3. Chose NOT to auto-add a `PowerShell(*New-AdoClassicUpdatePlan.ps1*)`
   wildcard to `settings.local.json` even though it's the same read-only/
   plan-generation category as `New-AdoClassicAksPlan.ps1` (already
   wildcarded) — that file is an actual live permission config, editing
   it myself without being asked felt too close to "changing permission
   settings" that no agent message can authorize on its own. Flagged as a
   suggested follow-up instead of doing it.

**Test coverage added:** Grupo AB in `run-script-tests.ps1` (closed-map
rejection incl. a real cmdlet name like `Remove-Item`, Kind-mismatch
guards, `ConvertTo-AdoHashtableDeep` nested conversion, org check,
`build`/`release` key injection rejection, ambiguous
`fileContent`+`fileContentPath` rejection, missing-skeleton-fields
rejection listing ALL missing fields at once, wrong-id-from-GET rejection,
full happy path incl. `bodyHash` round-trip fidelity against the body
actually written to disk, `contentPath` alias, merge-mode incl. duplicate-
operationType rejection, and 2 real integration checks: feeding the
runner's own output through `Invoke-AdoApplyPhases` mocked-PUT, and
through `Test-AdoClassicPlan.ps1` as a real child process with no
`-InventoryPath`). 405/405 `run-script-tests.ps1`, 103/103
`run-hook-tests.ps1`, both green.

**Real bug traps avoided while writing the tests (not found as bugs, but
worth remembering as gotchas)**: `Reset-MockWebRequest` must be called
right before any block that asserts an exact `$script:mockWebCallCount`
— it's cumulative across the whole test file's `try` block otherwise
(caught this in my own draft before running anything, via a stray
`Add-MockWebSuccessResponseWithBody -BodyObject (... -AsHashtable:$false
...)` leftover fragment I'd written and then had to delete — `-AsHashtable`
isn't a real `ConvertFrom-Json` parameter in Windows PowerShell 5.1, would
have thrown had it survived).

**Still not done (explicitly out of scope for this task):** actually
using this runner against Build 591/Release 373 (Buklo EMR) or any other
real resource. That's a future task requiring its own real user approval,
`EnterPlanMode`/`ExitPlanMode`, and Apply in that future session's own
transcript — same invariant as always.

See also [[ado-emr-scratch-script-authorization-declined-2026-08-27]] —
the delete-capability build (2026-08-26) followed the same "build the
missing versioned capability instead of a scratch/manual workaround"
pattern one task prior, but that one isn't recorded in this agent's own
memory folder (it's referenced only from the user's global auto-memory
index, a different memory system than this project-scoped one).
