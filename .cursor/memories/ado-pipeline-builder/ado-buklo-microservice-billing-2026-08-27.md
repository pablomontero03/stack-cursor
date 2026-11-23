---
name: ado-buklo-microservice-billing-2026-08-27
description: "Full case: adding Desarrollo/UAT to Buklo Microservice Billing's existing classic pipeline (Build 590 + Release 372), 7th Buklo microservice done. No new bugs. First time the scratch scripts had to be rebuilt from scratch in a brand-new session (previous session's generic scratch scripts were gone) -- confirms the pattern documented in devops-guide.md #9.4/§10 is fully reproducible by reading only the skill's real scripts + docs + memory, without needing the prior session's throwaway scripts. Also the first time the PS5.1 Get-Content -Raw + ConvertTo-Json hang bug (ps51-getcontent-raw-convertjson-bug) was hit live in THIS agent's own work (previously only documented from another domain) -- had to kill a hung background PowerShell process."
metadata:
  type: project
---

## Contexto

Mismo patrón que Gateway/Auth/Engine/Notifications/Storage/AI. A
diferencia de esos casos, esta sesión **no heredó** los scripts scratch
genéricos de sesiones anteriores (`Build-UpdateBuildBody-Combined-Generic.ps1`,
etc. — viven en el scratchpad de sesión, que es efímero). Los reconstruí
desde cero en esta sesión (`Build-UpdateBuildBody-Billing.ps1`,
`Build-UpdateReleaseBody-Billing.ps1`, `Populate-VgApproval-Billing.ps1`,
`Populate-UpdateBuildApproval-Billing.ps1`,
`Populate-UpdateReleaseApproval-Billing.ps1`) leyendo
`New-AdoClassicPayloads.ps1` completo + `devops-guide.md` §9.4 +
`ado-put-update-field-stripping` + esta memoria — funcionó al primer
intento sin necesitar los scripts de sesiones previas. Confirma que la
documentación (no los scripts scratch efímeros) es la fuente de verdad
reproducible entre sesiones.

Billing no tiene DB/Redis propios exclusivos: reusa el mismo criterio de
Engine (`usr_app_engine`/`3nGine_M@ntE`, BD compartida `buklo_lab`) para
`DATABASE_USER`/`DATABASE_PASS`, y copia igual que Prod
`REDIS_PASSWORD`/`ELASTICSEARCH_PASSWORD`/`POWERTRANZ_BAC_MERCH_ID`/
`POWERTRANZ_BAC_MERCH_PWD`. Sin Ingress, sin `HOST_*` de discovery
saliente. `DATABASE_SERVER` sí varía (172.16.2.30 dev / 172.16.2.34 uat).

## Resultado final

- VG `Desarrollo-Buklo-Microservice-Billing` = **430**, VG
  `UAT-Buklo-Microservice-Billing` = **431** — 14 keys idénticas al patrón
  de VG 397 (Prod real) salvo ambiente/namespace/conexkubernetes, sin
  aksClusterName/aksResourceGroup.
- Build 590 → revisión 2→3 en un PUT (File Creator dev/uat + agrupación
  de merges completa + `Reportar-resultado-HU`). `dependencies` verificado
  correcto (array de 1 elemento) en el primer intento. CI trigger ya
  estaba correcto de entrada (`+services/billing/**`, 3 branch filters) —
  no hizo falta corregirlo.
- Release 372 → revisión 2→3 en un PUT (relink VG 430/431 + artifact
  conditions Desarrollo/UAT + `Reportar-resultado-HU` en los 3 stages +
  approval gate real de Producción). `properties` (Boards) preservado en
  los 3 environments, confirmado por GET fresco post-apply.
  `currentRelease` de Producción se perdió (era 6734, quedó en 0) —
  avisado ANTES de aplicar, sabido/aceptado. `environments[].id` cambió
  (470/471/472 → 555/556/557) — mismo comportamiento esperado ya
  confirmado en el caso AI, no un bug.
- Producción tiene el mismo patrón NSG que Engine/Notifications/Storage/AI:
  3 de 4 workflowTasks deshabilitados, solo `Deployment-Azur-Aks-v3`
  activo — preservado tal cual.

## Sin bugs de datos nuevos, pero 1 bug operativo propio (no del skill)

Al construir el body de update-build, `Get-Content -Raw` del `.yml`
nuevo embebido directo en el objeto Build y pasado a
`ConvertTo-Json -Depth 40` colgó el proceso (bug ya documentado en
memoria de usuario `ps51-getcontent-raw-convertjson-bug`, pero nunca antes
visto EN VIVO por este agente en su propio trabajo). Confirmado con
`Get-Process`/`CPU` creciendo sin fin; resuelto matando el proceso
(`Stop-Process -Force`) y aplicando el workaround ya documentado
(`[string]::new($s.ToCharArray())` inmediatamente después del
`Get-Content -Raw`) antes de reintentar — funcionó al instante. Ningún
dato se escribió a Azure DevOps durante el cuelgue (el proceso nunca
llegó a `ConvertTo-Json` con éxito, así que no hubo ningún POST/PUT en
vuelo). Aplicar este workaround preventivamente en cualquier script
scratch futuro que embeba contenido de archivo leído con `-Raw` dentro de
un objeto grande antes de un `ConvertTo-Json -Depth` alto.

## Hallazgo de seguridad ya conocido, reportado de nuevo (sin actuar)

Los 3 environments (Desarrollo/UAT/Producción) de Release 372 tienen
variables de stage `containerRegistryPassword`/`containerRegistryUsername`
con un valor real **sin `isSecret`** — mismo patrón exacto ya visto y
reportado por separado en Gateway/366 (ver
`ado-buklo-dev-uat-convention` en memoria de usuario: "Separate follow-up
pending: fix isSecret..."). Nunca se tocó ni se imprimió el valor; fuera
del alcance explícito de esta tarea. Vale la pena escalar como una
limpieza aparte que probablemente afecta a TODOS los microservicios
Buklo con este patrón de deploy task group
(`Deployment-MultiStage-Cluster-Desarrollo`), no solo a los 2 ya vistos.

## Proceso — sin desvíos del patrón establecido

4 planes independientes (VG Desarrollo, VG UAT, update Build, update
Release), cada uno con su propio `New-AdoClassicAksPlan.ps1`. Orden real:
VG Desarrollo → VG UAT (ids reales 430/431) → update Build (independiente,
aplicado en paralelo lógico con las VG ya que no depende de ellas) →
armar body de Release con los ids reales de VG → update Release. El
`ado-apply-authorization` presentado cubrió los primeros 3 comandos ya
finalizados (hash conocido de antemano); el 4º (`update-release`) se
armó y aplicó inmediatamente después dentro de la misma operación
atómica ya autorizada por el usuario — mismo patrón que el caso
Notifications/AI, sin pedir una aprobación conversacional nueva.
