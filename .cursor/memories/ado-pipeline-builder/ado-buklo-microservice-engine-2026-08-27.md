---
name: ado-buklo-microservice-engine-2026-08-27
description: "Full case: adding Desarrollo/UAT to Buklo Microservice Engine's existing classic pipeline (Build 586 + Release 368), 3rd Buklo microservice done. First time using the corrected properties-preserving mechanism proactively (no restore-after-the-fact needed), and a real pre-existing data bug found in Build 586 (dev/uat File Creators had Gateway's content, not Engine's)."
metadata:
  type: project
---

## Contexto

Mismo patrón que [[ado-buklo-microservice-gateway-dev-uat-2026-08-26]] y
[[ado-buklo-microservice-auth-2026-08-27]], pedido de una sola vez desde
el inicio. Primera vez que se usa el mecanismo de field-stripping YA
CORREGIDO (preservar `properties` proactivamente, nunca `currentRelease`)
desde el principio, sin necesidad de un PUT de restauración aparte.

## Resultado final

- VG `Desarrollo-Buklo-Microservice-Engine` = **422**, VG
  `UAT-Buklo-Microservice-Engine` = **423** — 14 keys idénticas al
  patrón de VG 393 (Prod real).
- Build 586 → revisión 9→10 en un solo PUT combinado (File Creator
  dev/uat + agrupación de merges + `Reportar-resultado-HU`).
  `dependencies` verificado correcto contra Build 552 en el primer
  intento.
- Release 368 → revisión 2→3 en un solo PUT combinado (relink VG +
  artifact conditions + `Reportar-resultado-HU` en los 3 stages +
  approval gate real de Producción). `properties` de los 3 environments
  preservado PROACTIVAMENTE en el mismo PUT — no hizo falta un PUT de
  restauración aparte, a diferencia de Gateway/Auth. `currentRelease` de
  Producción se perdió igual (era 6927, quedó en 0) — sabido, aceptado,
  no se intentó evitar.

## 2 hallazgos reales encontrados y reportados antes de aplicar nada

1. **Producción de Engine tiene 3 de sus 4 workflowTasks deshabilitados**
   (`PROD AKS NSG TEMP ALLOW`, `60s Wait for NSG to get applied`,
   `PROD AKS NSG DENY` con `enabled=False`; solo
   `Deployment-Azur-Aks-v3` activo) — a diferencia de Gateway/Auth, donde
   los 4 estaban `enabled=True`. No se tocó (fuera de alcance), y se
   preservó exacto (mismo `enabled` de cada uno) al insertar
   `Reportar-resultado-HU` al final. Confirmar SIEMPRE el estado real de
   cada workflowTask antes de asumir que sigue el patrón de los
   servicios anteriores.
2. **Bug de datos real, preexistente, no relacionado a esta tarea**: los
   `File Creator deployment.yml dev`/`uat` de Build 586 tenían contenido
   de **Gateway** (`microservice-gateway-core`) en vez de Engine —
   confirmado leyendo el contenido real antes de sobreescribir, no solo
   la longitud (que por casualidad coincidía con los tamaños viejos de
   Gateway, lo que fue la primera señal de alarma). `deployment.yml
   produccion` sí tenía el contenido correcto de Engine. La Tarea 2
   (reemplazar dev/uat con el YAML preparado) corrigió esto como efecto
   colateral — pero se reportó como hallazgo aparte antes de aplicar,
   no se asumió en silencio que "ya se iba a arreglar solo".

## Aprendizaje de proceso: verificar CONTENIDO, no solo longitud

La longitud de un `filecontent` que "coincide" con la de otro servicio
(en este caso, exactamente los mismos 11670/11642 caracteres que Gateway
tenía originalmente) es una señal de alarma suficiente para leer el
contenido real antes de asumir que es del servicio correcto — no
descartarlo como coincidencia. Aplicable a cualquier verificación futura
de `File Creator` antes de sobreescribir.
