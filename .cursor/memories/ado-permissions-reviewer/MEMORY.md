# Memoria — ado-permissions-reviewer

## Propósito

Revisar de forma independiente un plan de
`manage-azure-devops-permissions` (grupos, membresías, permisos Git)
antes de que se aplique — nunca escribe ni ejecuta nada.

## Alcance de la memoria

Aprendizajes reutilizables de revisión (riesgos reales encontrados,
falsos positivos del propio criterio de revisión). No duplica el
checklist completo, que vive en
`.claude/agents/azure-devops-permissions/ado-permissions-reviewer.md`.

## Enlaces

- [Diagnóstico](./debugging.md)
- [Patrones](./patterns.md)

## Aprendizajes esenciales

- Estado en vivo real de Buklo (qué Branch Policies y qué permisos Git
  quedaron aplicados a cada repo) vive en `MEMORY.md` de
  `ado-permissions-builder` § "Estado en vivo" — no se duplica acá,
  consultarlo antes de revisar un plan nuevo sobre este mismo proyecto.
- **CRÍTICO** al revisar cualquier plan con una operación
  `set-git-permissions-ace`: confirmar que su `body.value[0].acesDictionary`
  incluye TODAS las identidades del `fullAcesDictionary` actual del token
  (no solo las 2 que administra este dominio) — si el plan solo trae un
  subconjunto, aplicarlo BORRA cualquier otra identidad con ACE real que
  ya estuviera ahí (la API reemplaza el diccionario completo, no lo
  combina). Ver `debugging.md` de `ado-permissions-builder` § "INCIDENTE
  MAYOR 2". Nota: desde este mismo incidente existe además una guardia
  dura dentro de `Invoke-AdoPermissionsRest` que rechaza esto
  automáticamente aunque la revisión lo pase por alto — no reemplaza la
  revisión, es defensa en profundidad.
- **CRÍTICO** 2026-09-02: revisar un plan de `set-git-permissions-ace`
  aprobado y "aplicado" no es suficiente para confirmar que el permiso
  real cambió — un HTTP 200/204 exitoso puede no haber tomado efecto si
  el `acesDictionary` usa la clave equivocada (descriptor de Graph en vez
  del SID legado `Microsoft.TeamFoundation.Identity;S-1-9-...`, ver
  `debugging.md` de `ado-permissions-builder` § "INCIDENTE MAYOR"). Antes
  de dar por buena una aplicación real de ACE, pedir o hacer un readback
  con GET SIN filtro `&descriptors=` (trae el `acesDictionary` completo),
  o consultar el Audit Log de la organización — nunca confiar solo en el
  código de estado HTTP de la respuesta.
- 2026-09-02: primer uso real del dominio contra la organización. Nota:
  todo el trabajo de esta sesión (grupos/permisos y `pr-policy-admin`) lo
  hizo la sesión principal directamente, sin invocar este subagente como
  proceso separado — si una sesión futura sí lo invoca para revisar un
  plan nuevo sobre Buklo, no asumir que ya existe una revisión registrada
  de lo aplicado hoy.
- Un `token` en el plan con forma `repoV2/<guid>/<guid>/refs/heads/<hex>`
  no es un secreto (es el identificador público del recurso ACL) — no
  marcarlo como hallazgo de seguridad.
- Un grupo recién creado que NO tiene operaciones de membresía/ACE en el
  mismo plan no es un descuido — es el comportamiento correcto (ver
  `deferredAfterCreation` en el plan y `patterns.md` del builder).
- Para un plan de `pr-policy-admin` (Branch Policies), revisar
  específicamente: (1) toda operación `type.id` = Build
  (`0609b952-1397-4640-95ec-e00a01b2c241`) trae un `buildDefinitionId`
  que es del repo DESTINO, nunca copiado sin más del origen — pedir
  confirmación explícita de a qué pipeline apunta si no es obvio por el
  nombre; (2) el plan nunca contiene una operación cuyo `(type.id,
  refName)` ya exista en el inventario destino (`skippedAlreadyExists`
  debería explicar cualquier ausencia esperada); (3) `requiredReviewerIds`
  resueltos a nombre legible antes de aprobar, nunca aprobar un GUID sin
  identificar a quién representa.

- **Agregado 2026-09-03**: al revisar un plan que crea o agrega el primer
  miembro a `Development Team(s)`/`Code-Reviewers`, señalar que "View
  project-level information" (namespace `Project`) NO está cubierto por
  la matriz de este dominio — puede quedar en Not set y bloquear el
  acceso al proyecto entero pese a una matriz Git perfecta. Ver checklist
  punto 11 en `patterns.md` y `MEMORY.md`/`patterns.md` de
  `ado-permissions-builder` (caso real: Edson Alvarez Obando, Buklo).

Última revisión: 2026-09-03.

## Lección 2026-09-21 — no ejecutar setup.sh de Kiro

Causa raíz confirmada de las "caídas del gateway": NO era el `curl`/PUT ni el volumen
JSON — era `source ./setup.sh`, En Cursor no se usa ese reinicio de Kiro
el gateway/sesión. El comando completa (exit 0) y el restart tumba la sesión acto
seguido, por lo que parece fallo del `curl`.

**Vía correcta en sesión activa** — cargar el `.env` directo:
```bash
source /home/cursor/stack-cursor/env/.env
export REPO_ROOT=/home/cursor/stack-cursor
```
No ejecutar `source ./setup.sh`. Para variables: `set -a; source env/.env; set +a`.
