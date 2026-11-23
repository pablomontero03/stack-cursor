---
name: ado-buklo-microservice-ai-2026-08-27
description: "Full case: adding Desarrollo/UAT to Buklo Microservice AI's existing classic pipeline (Build 589 + Release 371), 6th Buklo microservice done. Clean run, no new bugs — CI trigger and File Creator dev/uat placeholders were both already correct/genuine this time. First time env ids in a Release definition were seen to change on a PUT (467/468/469 -> 552/553/554), confirmed as expected (environments[].id is stripped before PUT, server reassigns), not an anomaly."
metadata:
  type: project
---

## Contexto

Mismo patrón que Gateway/Auth/Engine/Notifications/Storage. Intake ya
hecho en vivo por el coordinador (GETs frescos) antes de invocarme;
igual re-confirmé todo con mis propios GETs frescos antes de escribir
(convención ya establecida, nunca confiar en un intake sin re-verificar).

AI no tiene DB/Redis propios pero SÍ reusa recursos compartidos con el
mismo criterio ya usado para Elasticsearch/Qdrant en servicios
anteriores (nunca el criterio de Storage/`AZURE_BLOB_STORAGE`, que
requería dejar vacío): `AZURE_OPENAI_API_KEY`, `REDIS_PASSWORD`,
`ELASTICSEARCH_PASSWORD`, `AZURE_BOT_APP_PASSWORD`, `DB_USER`,
`DB_PASSWORD` copiados igual que Prod; `DB_NAME`/`DB_HOST`/`HOST_ENGINE`
sí varían por ambiente (BD compartida `buklo_lab`, servidor SQL
dev/uat, servicio Engine dev/uat).

## Resultado final

- VG `Desarrollo-Buklo-Microservice-AI` = **428**, VG
  `UAT-Buklo-Microservice-AI` = **429** — 14 keys idénticas al patrón de
  VG 396 (Prod real), confirmadas por GET fresco después de crear.
- Build 589 → revisión 4→5 en un solo PUT combinado (File Creator
  dev/uat + agrupación de merges + `Reportar-resultado-HU`).
  `dependencies` verificado correcto (array de 1 elemento) contra Build
  552 en el primer intento, confirmado por GET de readback.
- Release 371 → revisión 4→5 en un solo PUT combinado (relink VG +
  artifact conditions + `Reportar-resultado-HU` en los 3 stages +
  approval gate real de Producción). `properties` (Boards) preservado
  proactivamente en los 3 environments. `currentRelease` de Producción
  se perdió igual (era 6943, quedó en 0) — sabido, aceptado.
- Producción tiene el mismo patrón NSG que Engine/Notifications/Storage:
  3 de 4 workflowTasks deshabilitados, solo `Deployment-Azur-Aks-v3`
  activo — preservado tal cual.

## Sin bugs de datos esta vez

A diferencia de Engine (contenido de otro servicio) y a favor de lo
dicho en el intake: el CI trigger de Build 589 ya estaba correcto
(`pathFilters: +services/ai/**`, 3 branch filters) y el contenido
`ANTES` de los File Creator dev/uat era un placeholder genérico genuino
(`# TODO: configurar deployment por ambiente`, 174 caracteres, mismo
patrón que Notifications) — no contenido de otro microservicio. Se
verificó el contenido real (no solo la longitud) antes de sobreescribir,
igual hábito que en los 5 casos anteriores.

## Hallazgo nuevo, investigado y confirmado como comportamiento esperado
(no un bug): `environments[].id` cambia en cada PUT de una definición de
Release

Antes del PUT: env ids 467 (Desarrollo) / 468 (UAT) / 469 (Producción).
Después del PUT (mismo GET de readback, misma sesión): env ids 552 /
553 / 554 — los 3 cambiaron. Investigado antes de reportarlo como
anomalía: el mecanismo de field-stripping ya usado en los 5 casos
anteriores (`Build-UpdateReleaseBody-Combined-Generic.ps1`) quita `id`
de cada `environments[]` antes de enviar el PUT junto con
`owner`/`deployStep`/`badgeUrl` — es decir, el propio mecanismo YA
documentado provoca que Azure DevOps reasigne un id nuevo en cada
revisión. Coherente con que `environments[].id` nunca apareció en la
lista de campos "vale la pena preservar" en ningún caso anterior (a
diferencia de `properties`, que sí se preserva). No es un problema
real: nada externo referencia ese id entre revisiones de la definición
(a diferencia de `currentRelease.id`, que si se pierde sí apunta a un
release real). No se cambió nada del mecanismo — queda documentado acá
por si un futuro caso lo nota y duda si es un bug nuevo.

## Proceso — sin desvíos del patrón establecido

Se reusaron sin modificación los 4 scripts genéricos ya creados en
Notifications (`Build-UpdateBuildBody-Combined-Generic.ps1`,
`Build-UpdateReleaseBody-Combined-Generic.ps1`,
`Populate-UpdateBuildApprovalGeneric.ps1`,
`Populate-UpdateReleaseApprovalGeneric.ps1`) y el de Engine/Storage
(`Populate-VgApproval.ps1`). 4 planes independientes (VG Desarrollo, VG
UAT, update Build, update Release), cada uno con su propio
`New-AdoClassicAksPlan.ps1` — nunca reusando el archivo de otra
operación, con la lección de Notifications ya aplicada desde el
principio. Orden real: VG Desarrollo → VG UAT (para tener los ids reales
428/429) → update Build (independiente) → armar body de Release con los
ids reales de VG → update Release. Los 3 checks de validación
"posible duplicado"/"repo no existe" en el primer pase de
`Test-AdoClassicPlan.ps1` (antes de poblar `approvedOperations`) son
ruido esperado — se resuelven solos al poblar `approvedOperations` y
revalidar (mecanismo granular por `operationType`, no un bug).
