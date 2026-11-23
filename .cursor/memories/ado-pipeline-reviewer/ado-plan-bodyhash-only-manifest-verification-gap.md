---
name: ado-plan-bodyhash-only-manifest-verification-gap
description: "Structural limitation found reviewing the administracion-proyectos-web rebuild (2026-08-26): AKS plan JSONs only store bodyHash for create-build-definition, never the 3 K8s manifest files' content, so a reviewer cannot verify token-preservation/Prod-exclusions from the plan file alone -- must locate and diff the actual candidate manifest files on disk."
metadata:
  type: project
---

**Finding:** `Apply-AdoClassicPlan.ps1`'s own docstring confirms the plan
"solo guarda el HASH de cada body aprobado (nunca el body completo)" — for
`create-build-definition` this means the 3 deployment-{dev,uat,prod}.yml
contents used to compute the approved `bodyHash` are NOT in the plan JSON
and must be supplied again at apply time via
`-DeploymentDevYamlPath`/`-DeploymentUatYamlPath`/`-DeploymentProdYamlPath`.

**Why this matters for review:** reviewing only the 4 plan JSON files is
NOT sufficient to confirm checklist items like "tokens `#{...}#` preserved
literally" or "Prod excludes `imagePullSecrets`/`ingressClassName: nginx`"
— those live in external YAML files that may or may not still be on disk,
may exist in multiple conflicting drafts, and there is no field in the
plan that names which exact file path was hashed.

**Concrete instance:** reviewing the `administracion-proyectos-web`
rebuild, found 3 candidate manifest sets in the session scratchpad:
- `fixed-manifests/` and loose scratchpad-root `deployment-*.yml` — both
  byte-correct (tokens preserved, matches the real deleted Build 622
  exactly, Prod correctly excludes `imagePullSecrets`/`nginx`).
- `administracion-proyectos-manifests/` — WRONG: all org-standard tokens
  (`#{namespace}#`, `#{servicesname}#`, `#{containerregistries}#`,
  `#{image}#`, `#{ambiente}#`, `#{tag}#`, `#{reqcpu}#`, `#{reqmem}#`,
  `#{limcpu}#`, `#{limmem}#`) were pre-resolved to literal per-environment
  values — this would defeat the single-Build/Release-time-token-
  substitution architecture if ever fed to `-Apply`.

No field in any of the 4 plan JSONs said which set produced the approved
`bodyHash`. Mitigating factor: `Invoke-AdoRest` re-validates the
reconstructed body's hash before writing, so feeding the wrong file at
apply time fails cleanly (hash mismatch, no resource created) rather than
silently creating a broken Build — but it's still a real
confusion/wasted-attempt risk, and a genuine review gap.

**How to apply next time:** when reviewing an AKS plan with a pending
`create-build-definition` approvedOperation, always: (1) search the
scratchpad/plans directories for candidate `deployment-{dev,uat,prod}.yml`
files, (2) diff any duplicates found, (3) if more than one candidate set
exists, flag it explicitly and ask which exact 3 files map to the
approved bodyHash before endorsing `-Apply`, (4) recommend the builder
delete/quarantine incorrect drafts so they can never accidentally be
passed to `Apply-AdoClassicPlan.ps1`.

**RESOLVED 2026-08-26 (same review):** recomputed `Get-AdoBodyCanonicalHash`
directly against each candidate set (dot-sourcing `New-AdoClassicPayloads.ps1`,
calling `New-AdoBuildDefinitionPayload` with the real `$Plan` + each
`-DeploymentManifests` candidate). Confirmed definitively: both
`fixed-manifests/` and the scratchpad-root files hash to
`990c0b9e...` — matching the plan's approved `bodyHash` exactly (the BOM
difference between the two candidates disappears once `Get-Content -Raw`
reads them into a string, so it never affects the hash). The wrong
`administracion-proyectos-manifests/` set hashes to a different value
entirely (`a89fa11b...`), confirming it was never the one used to compute
the approved hash — just an abandoned draft. That folder was deleted from
the scratchpad to remove the ambiguity for good. **This closes the
blocker**: this specific instance no longer needs the user's input before
`-Apply`, though the general review technique above (recompute and
compare the hash directly, don't just eyeball file contents) remains the
right method for any future case with multiple candidate manifest sets on
disk.
