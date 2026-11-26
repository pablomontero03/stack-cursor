# Memoria — ado-pipeline-diagnoser

## Propósito

Diagnosticar fallos de Builds, Releases y despliegues AKS/DACPAC clásicos
de Azure DevOps (`Shared-Service-GM` / proyecto `DevOps`) a partir de logs
y estado ya obtenidos, en modo solo lectura, sin reintentar ni modificar.

## Alcance de la memoria

Aprendizajes reutilizables de diagnóstico específicos de pipelines
clásicos ADO (causas raíz confirmadas, patrones de fallo recurrentes por
familia). No duplica el procedimiento completo, que vive en
`.claude/agents/azure-devops/ado-pipeline-diagnoser.md` y las guías de
`.claude/skills/manage-azure-devops-pipelines/references/`.

## Enlaces

- [Diagnóstico](./debugging.md)
- [Patrones](./patterns.md)

## Aprendizajes esenciales

Ninguno todavía. Este archivo se actualiza solo cuando exista una
modificación real.

## Lección 2026-09-21 — no ejecutar setup.sh de Kiro

Causa raíz confirmada de las "caídas del gateway" al operar ADO: NO era el
`curl`/PUT ni el volumen JSON — era `source ./setup.sh`, En Cursor no se usa ese reinicio de Kiro
en su paso [7/7] y mata el gateway/sesión. El comando completa (exit 0) y el restart
tumba la sesión acto seguido, por lo que parece fallo del `curl`.

**Vía correcta en sesión activa** — cargar el `.env` directo:
```bash
source /home/cursor/stack-cursor/env/.env
export REPO_ROOT=/home/cursor/stack-cursor
```
No ejecutar `source ./setup.sh`. Para variables: `set -a; source env/.env; set +a`.
Para GET/PUT de definiciones grandes: descargar a archivo aislado y leer con la
herramienta de archivos, nunca procesar el JSON grande dentro del tool de shell.

## "El Release no se dispara/despliega tras el build" en Classic Release clonados por API (2026-09-18)

NO diagnosticar como race del CD trigger. Causa raíz: DOS campos mal copiados al
clonar la definición de Release, que dejan el stage en `notStarted`:

1. CD trigger con `triggerCondition` de `sourceBranch: ""` (branch vacío nunca
   matchea) en vez de `triggerConditions: []`.
2. Condición `artifact` del stage con `name: "ReleaseStarted"` (inválido) en vez del
   alias real del artifact (`_Build-...-k3s`).

Comprobar ambos comparando la definición contra una hermana que SÍ dispara: GET
`release/definitions/<id>`, revisar `triggers[].triggerConditions` y
`environments[].conditions[]` de tipo `artifact`. El fix es del builder (PUT), no del
diagnoser. La activación manual por `PATCH environments status=inProgress` enmascara
este bug — no reportarla como solución.

DIAGNÓSTICO 'could not read Username ... terminal prompts disabled' en pipelines pull-request-cherry-pick-*
(task group Promote-WorkItem-Cherry-Pick, 2026-10-15/16): el error aparece en 'git push origin --delete temp/...'
(Paso 5.1) y DESPISTA — parece credencial ausente o falta de permiso, pero la causa real es que la función
Ensure-RemoteHasAuth reescribe el remote a 'https://:$token@' (usuario VACÍO), rompiendo el match del
http.<url-con-Shared-Service-GM@>.extraheader del checkout → la ESCRITURA no autentica (las lecturas REST/fetch sí,
por eso confunde). Pistas para distinguir: (1) si las lecturas (fetch, ls-remote, API GET) funcionaron y SOLO el push
falla → es la auth del remote, no red ni token global vacío; (2) 'could not read Username' = git 2.34 convierte el
rechazo en prompt; un 403/TF401027 explícito sería falta de ForcePush (otro problema). El bug es latente (task group
sin cambios) y solo se dispara con rama temporal previa a borrar — chequear cuántas ramas temp/uat/* acumuladas hay.
Fix es del builder (editar el task group a http.extraheader global bearer), NO del diagnoser. NOT: no diagnosticarlo
como falta de permiso ForcePush ni como token/PAT vencido; no reportar 'el pipeline se rompió' sin ver que el task
group no cambió y que el disparador es el delete de rama preexistente.

## 2026-11-12 — Bases BD validadas con el Orquestador Schema Sync
job_schedule, stg_blue, core_global, core_workflow, core_config y buklo_lab: Schema Compare de VS coincide con el
Orquestador (main = prod) y sus pipelines ya corren en UAT y Prod. Un fallo de deploy ahí NO es drift repo-vs-BD
de esas bases; mirar compilación/código de BD o config del pipeline. Ver docs/schema-sync/FASE2-RECONCILE-FROM-EXTRACT.md.
