---
name: ado-buklo-microservice-storage-2026-08-27
description: "Full case: adding Desarrollo/UAT to Buklo Microservice Storage's existing classic pipeline (Build 588 + Release 370), 5th Buklo microservice done. Session was interrupted mid-task (usage limit) right before the Release PUT; resumed cleanly with a fresh GET per the coordinator's explicit no-reuse instruction, no rework needed on Build/VG side."
metadata:
  type: project
---

## Contexto

Mismo patrón que Gateway/Auth/Engine/Notifications. Diferencia real de
este servicio, decidida de antemano con el usuario (no reabierta):
Storage no tiene DB ni Redis, solo un Secret `AZURE_BLOB_STORAGE`
(connection string real hacia el bucket `montecristobucket`, solo
existe para Producción). Para Desarrollo/UAT se dejó **en blanco con un
comentario explicando que falta crear la cuenta/contenedor** — nunca se
reusó el connection string real de Producción (evita mezclar archivos de
prueba con datos reales).

## Resultado final

- VG `Desarrollo-Buklo-Microservice-Storage` = **426**, VG
  `UAT-Buklo-Microservice-Storage` = **427**.
- Build 588 → revisión 4→5 en un solo PUT combinado. `dependencies`
  verificado correcto contra Build 552 en el primer intento.
- Release 370 → revisión 4→5 en un solo PUT combinado. `properties`
  preservado proactivamente en los 3 environments. `currentRelease` de
  Producción se perdió igual (era 6733) — aceptado, conocido.
- Mismo patrón de Engine/Notifications: Producción tiene 3 de 4
  workflowTasks NSG deshabilitados, preservado tal cual.

## Corte de sesión real a mitad de tarea (uso, no error)

La sesión se cortó por límite de uso justo después de aplicar VG+Build
(ambos ya confirmados vía GET fresco por el coordinador antes de
retomar) y ANTES del PUT de Release. Al retomar:
- El coordinador ya había verificado el estado real con su propio GET
  fresco (no asumido) y me pasó el resumen exacto de qué faltaba.
- Aun así, hice mi propio GET fresco de Release 370 antes de armar el
  body (instrucción explícita: "no reuses nada de antes del corte") —
  confirmó exactamente lo que el coordinador ya había reportado
  (revisión 4, VG 383/384 prestadas, conditions vacías, sin
  Reportar-resultado-HU, Producción sin approval gate).
- El script genérico (`Build-UpdateReleaseBody-Combined-Generic.ps1`,
  ya creado durante el caso Notifications) permitió retomar sin
  reconstruir nada a mano — mismo patrón exacto, solo con los ids reales
  de este servicio como parámetros.

**Lección**: un corte de sesión a mitad de una tarea multi-paso no es
motivo para re-litigar ni reconfirmar TODO desde cero con el usuario —
alcanza con una verificación de estado real puntual (GET fresco) del
paso siguiente antes de continuar, confiando en que los pasos ya
aplicados (confirmados por readback antes del corte) siguen siendo
válidos.
