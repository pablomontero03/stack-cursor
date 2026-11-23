---
name: ado-administracion-proyectos-web-reconstruction-2026-08-26
description: "Full case detail: 2 real delete+rebuild cycles of administracion-proyectos-web's whole classic pipeline (VG+Build+Release) on 2026-08-26, used to validate the delete/rebuild mechanism and the generator-gaps fix in practice."
metadata:
  type: project
---

## 1ra reconstrucción (pipeline entero desde cero)

Release definition creada (id **383**) con los 3 stages usando ids reales
(VG 415/416/417, Build 624) + gate real de Producción aplicado como
`update-release-definition` separado (revision 2). Readback
`Test-AdoCreatedResources.ps1` en los 4 archivos de plan: exit 0, Build
624 + Release 383 + VG correspondiente, todo `True`. Comparación
campo-a-campo contra `references/Deploy-Desarrollo-UAT-Produccion-Administracion-Proyectos-Web.json`
(Release 381 histórica, no tocada): **coincide exacto** tras normalizar
ids nuevos esperados + 2 clases de diferencia ya conocidas y no
accionables (representación int/string de varios campos enum que Azure
DevOps devuelve inconsistente entre snapshots GET —
`source`/`conditionType`/`triggerType`/`executionOrder`/`phaseType`/
`parallelExecutionType` — y el mismo cosmético `tag` de Desarrollo/UAT
`$(Build.BuildId)` vs `$(tag)` documentado en
[[ado-release-create-update-real-bugs-2026-08-26]]). Pipeline completo
(VG 415/416/417 + Build 624 + Release 383) reproduce el original
borrado. Cero Builds encolados, cero instancias de Release reales, cero
despliegues, en las 5 fases de esta reconstrucción.

Fase 1 (VG+Build) aplicada primero: VG Desarrollo=415, VG UAT=416, VG
Producción=417, Build=624 — creados vía `Apply-AdoClassicPlan.ps1` (una
invocación por archivo de plan, cada una con su propia tarjeta de
aprobación), readback confirmó los 4 ids y `Release existe: False`
(esperado, pasos de Release pendientes, nueva aprobación aparte incluido
el gate real de Producción en 2 pasos).

## 2da reconstrucción (mismo día, prueba del fix de generador)

Usuario volvió a borrar Build+Release+3 VG de `administracion-proyectos-web`
para probar en la práctica el fix de
[[ado-classic-aks-plan-multi-env-generator-gaps]]. Resultado: **0 parches
manuales de JSON** en los 3 planes por ambiente, ~17 min de principio a
fin (vs ~78 min de la 1ra vez), los 3 `Test-AdoClassicPlan.ps1`
`validated=true` sin bloqueantes. Se detuvo antes de
`Apply-AdoClassicPlan.ps1` por pedido explícito, a la espera de revisión
de `ado-pipeline-reviewer`.

La 1ra construcción real (VG 412/413/414 + Build 623 + Release 382) fue
borrada de nuevo para esta 2da prueba.
