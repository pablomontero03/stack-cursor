---
name: ado-buklo-microservice-auth-2026-08-27
description: "Full case: adding Desarrollo/UAT to Buklo Microservice Auth's existing classic pipeline (Build 585 + Release 367), which already had real Production traffic — same pattern as Gateway but requested/applied as one combined batch, plus the environments[].currentRelease/properties finding and its resolution."
metadata:
  type: project
---

## Contexto

Mismo patrón que [[ado-buklo-microservice-gateway-dev-uat-2026-08-26]],
pero pedido de una sola vez (usuario ya había validado el patrón con
Gateway) y con una diferencia real importante: Auth **ya tenía tráfico
productivo real** (release 6926 desplegado en Producción, 2026-08-19),
a diferencia de Gateway que era nuevo — eso es lo que expuso el hallazgo
de `currentRelease` (ver abajo).

## Resultado final

- VG `Desarrollo-Buklo-Microservice-Auth` = **420**, VG
  `UAT-Buklo-Microservice-Auth` = **421** — 14 keys idénticas al patrón
  de VG 392 (Prod real), `ambiente=dev/uat`, `namespace=desarrollo/uat`,
  `conexkubernetes=AKS-DEV-SVC`, sin `aksClusterName`/`aksResourceGroup`.
- Build 585 → revisión 11→12 en **un solo PUT combinado**: File Creator
  dev/uat con contenido real (verificado byte-a-byte idéntico a los
  archivos preparados) + agrupación de merges + `Reportar-resultado-HU`.
  `dependencies` como array verificado correcto contra Build 552 **en el
  primer intento** — el fix del generador (ver
  [[debugging]] § "Bug real en producción... phase.dependencies") ya
  estaba aplicado desde el día anterior (Gateway), no hubo que repetir
  el diagnóstico.
- Release 367 → revisión 4→5 en **un solo PUT combinado**: relink VG
  Desarrollo/UAT + artifact conditions (`sourceBranch`
  `development`/`uat`) + `Reportar-resultado-HU` en los 3 stages
  (incluida Producción) + approval gate real de Producción
  (`[Shared-Service-GM]\Release Executers`,
  `397ddbfe-1d60-4533-a4c9-b099f80ac154`). Mismo resultado final que los
  4 PUTs separados de Gateway, con menos revisiones — combinar toda la
  parte de Release en un solo body cuando no hay dependencia de ids
  todavía inexistentes (a diferencia del relink, que sí necesitaba
  esperar a que las VG existieran) es más eficiente y sigue siendo
  seguro de verificar con un solo readback+diff al final.

## Hallazgo real: `environments[Producción].currentRelease` se pierde

Ver detalle técnico completo, diagnóstico y cierre en
[[debugging]] § "Anomalía real encontrada en Auth" y § "CERRADO
2026-08-27". Resumen:

- Producción de Auth tenía `currentRelease.id=6926` (release real,
  desplegado 2026-08-19) antes de tocar nada. Después de mi PUT
  (agregar `Reportar-resultado-HU` + approver, nada relacionado a este
  campo), `currentRelease.id` quedó en `0`.
- Diagnóstico confirmó que **le pasó lo mismo a Gateway** desde mi
  PRIMER `update-release-definition` ahí (VG relink) — no detectado en
  su momento porque no se revisaba ese campo específico. El release real
  de Gateway (6925) también se confirmó 100% intacto como recurso
  independiente.
- Intento explícito de restaurar `currentRelease={id:6926,...}` +
  `properties={Boards...}` en un PUT: **`properties` SÍ persistió,
  `currentRelease` NO** (confirmado de solo lectura/calculado por el
  servidor — el PUT devuelve 200 pero el servidor descarta ese campo
  específico). Aplicado el mismo restore de `properties` a Gateway.
- Mecanismo hacia adelante corregido: preservar `properties` en el body
  de cualquier `update-release-definition` futuro cuando el environment
  ya trae datos reales ahí; nunca intentar preservar `currentRelease`
  (sin efecto). Documentado en
  `references/devops-guide.md` §9.4 punto 10.
- **Implicación para los 10 microservicios Buklo que faltan**: la
  mayoría van a tener despliegues reales en Producción como Auth (no
  nuevos como Gateway) — revisar `currentRelease.id` de Producción con
  GET fresco ANTES de aplicar cualquier `update-release-definition`, y
  avisar de la pérdida inevitable de ese puntero antes de aplicar, no
  después.

## Otros hallazgos menores de esta sesión

- Mi propio script de verificación (`Diff-ProduccionEnv.ps1`,
  `Inspect-ProduccionFull.ps1`) tuvo un bug trivial de PowerShell:
  intentar re-consultar un `environment` por `id` DESPUÉS de ya haberlo
  quitado como parte del field-stripping — corregido a buscar por
  `name` (mismo patrón de bug ya visto en Gateway, mismo fix).
