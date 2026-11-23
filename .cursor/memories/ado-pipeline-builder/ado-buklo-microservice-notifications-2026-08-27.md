---
name: ado-buklo-microservice-notifications-2026-08-27
description: "Full case: adding Desarrollo/UAT to Buklo Microservice Notifications' existing classic pipeline (Build 587 + Release 369), 4th Buklo microservice done. Clean run, no unexpected data bugs (unlike Engine); introduced 2 fully-parameterized generic scratch scripts reused going forward."
metadata:
  type: project
---

## Contexto

Mismo patrón que Gateway/Auth/Engine ([[ado-buklo-microservice-gateway-dev-uat-2026-08-26]],
[[ado-buklo-microservice-auth-2026-08-27]],
[[ado-buklo-microservice-engine-2026-08-27]]), pedido de una sola vez.
Coordinador confirmó de antemano que `pathFilters` del trigger CI estaba
correcto acá (a diferencia de Engine) — confirmado igual con GET fresco,
no asumido.

## Resultado final

- VG `Desarrollo-Buklo-Microservice-Notifications` = **424**, VG
  `UAT-Buklo-Microservice-Notifications` = **425**.
- Build 587 → revisión 5→6 en un solo PUT combinado. `dependencies`
  verificado correcto contra Build 552 en el primer intento.
- Release 369 → revisión 3→4 en un solo PUT combinado. `properties`
  (Boards) preservado proactivamente en los 3 environments.
  `currentRelease` de Producción se perdió igual (era 6716) — aceptado,
  no se intentó evitar.
- Producción tiene el mismo patrón de Engine: 3 de 4 workflowTasks NSG
  deshabilitados (`enabled=False`), solo `Deployment-Azur-Aks-v3`
  activo — preservado tal cual, sin flag especial esta vez (ya es un
  patrón conocido, 2da vez que se ve).

## Sin bugs de datos esta vez (a diferencia de Engine)

Antes de sobreescribir, el `File Creator deployment.yml dev` tenía un
placeholder genuino (`# TODO: configurar deployment por ambiente`, un
`ConfigMap` stub de 136 caracteres) — NO contenido de otro servicio como
pasó con Engine/Gateway. Se verificó el contenido real (no solo la
longitud) antes de asumir que era benigno, mismo hábito aprendido de
Engine — esta vez confirmó que no había nada que reportar como anomalía.

## Bug propio de proceso encontrado y corregido en el momento

Al armar el PUT combinado de Release, reusé por error el MISMO archivo de
plan que ya había usado (y aplicado) para el PUT de Build, en vez de
generar uno nuevo con `New-AdoClassicAksPlan.ps1` — sobreescribiendo su
`approvedOperations` sin necesidad. No tuvo consecuencia real (el Build
ya se había aplicado con éxito antes de tocar el archivo, y
`Test-AdoClassicPlan.ps1` revalida el contenido actual de cualquier
forma), pero rompe la convención de "un archivo de plan por operación
atómica" ya establecida en Gateway/Auth/Engine. Corregido generando un
plan nuevo (`New-AdoClassicAksPlan.ps1` de nuevo) antes de poblar
`approvedOperations` del lado Release. **Repetir siempre: un
`New-AdoClassicAksPlan.ps1` nuevo por cada operación atómica (VG
Desarrollo, VG UAT, update Build, update Release), nunca reusar el
archivo de otra operación aunque sea del mismo microservicio.**

## Scripts genéricos parametrizados, para reusar en los próximos servicios

En vez de copiar y ajustar a mano el scratch script de Engine cada vez,
esta vez se armaron 2 versiones genéricas parametrizadas (mismo
directorio de scratchpad de la sesión):

- `Build-UpdateBuildBody-Combined-Generic.ps1` — Tarea 2 (fileContent
  dev/uat) + Tarea 5 lado Build (agrupación de merges +
  Reportar-resultado-HU) en un PUT. Parámetros: `-RawGetPath
  -DevYamlPath -UatYamlPath -OutPath -PlanPath`. Asume 6 steps
  preexistentes con los mismos 6 nombres exactos (`File Creator
  dockerfile`/`Replace tokens`/`File Creator deployment.yml dev`/`...uat`/
  `...produccion`/`Task group: Build`) — si un futuro microservicio no
  calza con ese layout exacto, hay que revisar antes de reusarlo tal
  cual.
- `Build-UpdateReleaseBody-Combined-Generic.ps1` — Tareas 3+4+5(release)+6
  en un PUT. Parámetros: ids de environment reales, VG antes/después,
  alias de artifact esperado. Ya incorpora el mecanismo corregido de
  `properties` (preservar) / `currentRelease` (nunca intentar).

Ambos con las mismas confirmaciones defensivas (throw si algo no calza
con lo esperado antes de escribir el archivo de salida) que los
scratch scripts anteriores.
