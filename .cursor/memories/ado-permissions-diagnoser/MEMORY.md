# Memoria — ado-permissions-diagnoser

## Propósito

Diagnosticar fallas de MCP, Graph API, Security API, PAT/scopes,
descriptores, tokens de seguridad, herencia y readback en el dominio de
administración de grupos y permisos Git de Azure DevOps. Nunca corrige
sin un plan aprobado.

## Alcance de la memoria

Aprendizajes reutilizables de diagnóstico (causas raíz confirmadas,
síntomas característicos). No duplica el procedimiento completo, que vive
en `.claude/agents/azure-devops-permissions/ado-permissions-diagnoser.md`
y `references/ado-security-api-map.md`.

## Enlaces

- [Diagnóstico](./debugging.md)
- [Patrones](./patterns.md)

## Aprendizajes esenciales

- Estado en vivo real de Buklo (qué Branch Policies y qué permisos Git
  quedaron aplicados a cada repo) vive en `MEMORY.md` de
  `ado-permissions-builder` § "Estado en vivo" — consultarlo antes de
  diagnosticar algo sobre este mismo proyecto para saber qué ya estaba
  bien y qué se corrigió recién.
- **CRÍTICO**: si una identidad que antes tenía ACE real en un token
  "desaparece" después de una escritura exitosa de OTRA identidad en el
  MISMO token, la causa casi segura es que esa escritura no incluyó el
  `acesDictionary` completo — "Set ACL" reemplaza todo el diccionario del
  token, no lo combina. Ver `debugging.md` de `ado-permissions-builder` §
  "INCIDENTE MAYOR 2" (síntoma real: 6 grupos default agregados borraron
  a Development Team/Code-Reviewers). Diagnóstico: comparar el
  `fullAcesDictionary` de 2 exportaciones consecutivas del mismo token.
  Desde este incidente, esto NUNCA debería volver a pasar por código de
  este dominio: hay una guardia dura en `Invoke-AdoPermissionsRest` que
  lo rechaza antes de escribir — si algo lo evade, es una regresión real
  y grave, priorizar encontrar cómo se saltó la guardia.
- **CRÍTICO** 2026-09-02: un `set-git-permissions-ace` que reporta
  "applied HTTP 200/204" NO garantiza que el ACE haya tomado efecto real
  — hay que verificar. Síntoma característico: la identidad/grupo no
  aparece en la lista de "Azure DevOps Groups" del portal (Security tab)
  después de una escritura "exitosa". Causa: el `acesDictionary` real usa
  como clave el descriptor SID legado
  (`Microsoft.TeamFoundation.Identity;S-1-9-...`), no el descriptor de
  Graph (`vssgp....`) — ver `debugging.md` de `ado-permissions-builder` §
  "INCIDENTE MAYOR" para el detalle completo (incluye 2 intentos
  fallidos de diagnóstico y por qué un GET con `&descriptors=` puede dar
  un falso positivo). **Herramienta de diagnóstico decisiva**: el Audit
  Log de la organización (`GET https://auditservice.dev.azure.com/{org}/_apis/audit/auditlog?api-version=7.1-preview.1`,
  mismo PAT) registra cada permiso modificado con actor y mecanismo de
  autenticación — si una escritura "exitosa" del script no aparece ahí,
  no tomó efecto real, sin ambigüedad. También distingue cambios hechos
  por el script (PAT) de cambios manuales del usuario en el portal (AAD +
  user-agent de navegador) — útil para no atribuir al script un cambio
  que en realidad hizo una persona a mano.
- 2026-09-02: primer uso real del dominio contra la organización (modo
  `pr-policy-admin`, replicación de Branch Policies).
- **Firma de síntoma real 2026-09-03**: usuario con Access Level Basic
  correcto, ACE Git (Contribute/Read/etc.) correcta y sin ninguna Deny en
  ningún nivel (All Repositories, repo, rama), y correctamente anidado en
  `Project Valid Users` — y AUN ASÍ recibe 401 "you do not have access" y
  ni el proyecto le aparece en la lista. Causa real confirmada: "View
  project-level information" (namespace `Project`, acción `GENERIC_READ`,
  bit `1`) del grupo estaba en **Not set** — namespace que este dominio
  NO administra en absoluto (solo administra "Git Repositories"). No
  investigar más a fondo la matriz Git ni el Access Level ante este
  síntoma exacto; ir directo a verificarlo — **esto SÍ es verificable por
  API** (`Get-AdoPermissionsFullAcesDictionary`, GET sin `&descriptors=`,
  contra el token CORRECTO de este namespace — NO el `projectId` pelado),
  sin necesidad del portal. El primer diagnóstico real lo dio por
  inconcluyente por 2 errores propios combinados (token equivocado en un
  intento, filtro `&descriptors=` ambiguo en el otro) — no repetir ese
  error: la receta correcta y ya verificada está en
  `.claude/agent-memory/ado-permissions-builder/patterns.md` § "View
  project-level information..." y en
  `references/ado-security-api-map.md` § "Namespace 'Project'".
- 2 endpoints del mapa de API (`Descriptors/Get` para resolver
  `scopeDescriptor`, `subjectquery` para resolver identidad) son "patrón
  inferido, no verificado con ejemplo oficial de Microsoft" — si fallan
  de forma inesperada en un diagnóstico real, ese es el primer lugar a
  revisar antes de asumir otra causa.
- Ver `debugging.md` del agente `ado-permissions-builder` para incidentes
  reales ya documentados: llamadas de red reales en pruebas,
  self-poisoning de `validationBlockers`, mojibake por falta de BOM en un
  `.ps1`, mojibake compuesto por `Get-Content -Raw` sin `-Encoding UTF8`
  al leer inventarios/planes, y un HTTP 400 real ("Unable to translate
  bytes [XX] ... to Unicode") al hacer POST de un body con tildes sin
  convertirlo a bytes UTF-8 primero. Los últimos 2 son la firma
  característica a buscar ante cualquier fallo de este dominio que
  involucre texto no-ASCII (nombres, mensajes de policy, descripciones).
- Un fallo HTTP 400 con ese mensaje exacto de "Unable to translate bytes"
  es SIEMPRE un problema de encoding del lado del cliente (nunca del
  contenido en sí) — no reintentar el mismo body tal cual, corregir el
  encoding de envío primero.

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
