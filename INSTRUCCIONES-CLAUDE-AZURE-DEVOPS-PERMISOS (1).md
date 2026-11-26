# Instrucciones para montar la administración de permisos de Azure DevOps

> **⚠️ Documento histórico (era Claude Code, 2026-08).** Las rutas corresponden
> al entorno Claude Code anterior (`D:\Proyectos\`, `.claude/rules/`).
> En Kiro, las rutas equivalentes son `.cursor/skills/` y `.cursor/rules/`.

Trabaja sobre el proyecto real ubicado en:

`D:\Proyectos\automation`

## Objetivo de esta tarea

Montar un dominio nuevo y completamente separado para administrar grupos y
permisos de Azure DevOps en múltiples proyectos de la organización
`Shared-Service-GM`.

Este dominio debe administrar:

- grupos de seguridad de proyecto;
- descripciones de grupos;
- miembros de grupos;
- permisos Git en `All Repositories` de cada proyecto;
- permisos por repositorio para el prefijo `feature/*` y las ramas
  `development`, `uat`, `release` y `main`;
- inventario, planificación, validación, aplicación y readback;
- diagnóstico de restricciones del MCP, API, PAT o permisos efectivos.

En esta tarea solamente debes construir, integrar y probar la estructura
local. No ejecutes cambios reales en Azure DevOps, no crees grupos reales, no
agregues miembros reales y no cambies permisos reales como consecuencia de
montar la herramienta.

## Restricción principal: no mezclar este dominio con Pipelines

Ya existe y funciona el dominio de Azure DevOps Pipelines. Debes inspeccionar
primero la estructura actual y conservarla completa.

No modifiques el comportamiento interno ni reutilices como destino estos
componentes:

- `.claude/skills/manage-azure-devops-pipelines/`
- `.claude/hooks/azure-devops-pipelines/`
- `.cursor/rules/azure-devops.mdc`
- `.claude/agents/azure-devops/ado-pipeline-*.md`
- `.claude/agent-memory/ado-pipeline-*/`
- `.local/azure-devops/`

No renombres, muevas, reemplaces ni elimines archivos existentes. Integra los
cambios en `CLAUDE.md`, `.claude/settings.json`,
`.claude/settings.local.json`, `.mcp.json` y `.gitignore` mediante cambios
mínimos y aditivos. No reemplaces ninguno de esos archivos completos.

Preserva también Schema Sync, n8n, AKS, servidores Linux/SSH y cualquier otro
dominio existente.

## Estructura nueva obligatoria

Usa nombres separados y explícitos para evitar confusión con Pipelines:

```text
.claude/
├── skills/
│   └── manage-azure-devops-permissions/
│       ├── SKILL.md
│       ├── assets/
│       │   └── ado-permissions-plan.example.json
│       ├── references/
│       │   ├── permission-matrix.md
│       │   ├── ado-security-api-map.md
│       │   └── approval-model.md
│       └── scripts/
│           ├── Invoke-AdoPermissionsRest.ps1
│           ├── Export-AdoPermissionsSecurityInventory.ps1
│           ├── New-AdoPermissionsPlan.ps1
│           ├── Test-AdoPermissionsPlan.ps1
│           ├── Apply-AdoPermissionsPlan.ps1
│           ├── Test-AdoPermissionsReadback.ps1
│           ├── New-AdoPermissionsDeletePlan.ps1
│           ├── Test-AdoPermissionsDeletePlan.ps1
│           ├── Apply-AdoPermissionsDeletePlan.ps1
│           └── tests/
│               └── run-script-tests.ps1
├── agents/
│   └── azure-devops-permissions/
│       ├── ado-permissions-builder.md
│       ├── ado-permissions-reviewer.md
│       └── ado-permissions-diagnoser.md
├── agent-memory/
│   ├── ado-permissions-builder/
│   │   ├── MEMORY.md
│   │   ├── debugging.md
│   │   └── patterns.md
│   ├── ado-permissions-reviewer/
│   │   ├── MEMORY.md
│   │   ├── debugging.md
│   │   └── patterns.md
│   └── ado-permissions-diagnoser/
│       ├── MEMORY.md
│       ├── debugging.md
│       └── patterns.md
├── rules/
│   └── azure-devops-permissions/
│       ├── authorization.md
│       └── security.md
└── hooks/
    └── azure-devops-permissions/
        ├── ado-permissions-security-gate.ps1
        ├── ado-permissions-post-validate.ps1
        ├── ado-permissions-stop-validate.ps1
        └── tests/
            ├── README.md
            └── run-hook-tests.ps1

docs/
└── azure-devops-permissions/
    └── PERMISSIONS-AUTOMATION-ARCHITECTURE.md
```

Los datos transitorios deben vivir únicamente en:

```text
.local/azure-devops-permissions/
├── exports/
├── plans/
├── executions/
└── pre-delete-backups/
```

Agrégalos a `.gitignore` sin eliminar patrones existentes. No guardes allí ni
en ningún otro archivo PAT, tokens, cabeceras de autorización o datos secretos.

## MCP primero y REST solamente para la brecha confirmada

Conserva el MCP existente `azure-devops`, actualmente fijado a
`@azure-devops/mcp@2.9.0`. No lo actualices, reinstales ni cambies sus dominios
durante esta tarea.

En una operación real, usa el MCP primero para:

- listar y resolver proyectos;
- listar repositorios;
- listar y consultar ramas;
- resolver identidades cuando la herramienta disponible sea suficiente;
- cualquier otra operación que exponga realmente.

El toolset oficial local actual no expone operaciones para Graph Groups,
Graph Memberships ni Security ACL/ACE. Para esas brechas implementa un
fallback REST controlado dentro de esta skill. Debe quedar documentado en
`references/ado-security-api-map.md`.

Usa únicamente documentación oficial de Microsoft como fuente:

- `https://github.com/microsoft/azure-devops-mcp/blob/main/docs/TOOLSET.md`
- `https://learn.microsoft.com/rest/api/azure/devops/graph/groups`
- `https://learn.microsoft.com/rest/api/azure/devops/graph/memberships`
- `https://learn.microsoft.com/rest/api/azure/devops/security/security-namespaces`
- `https://learn.microsoft.com/rest/api/azure/devops/security/access-control-lists`
- `https://learn.microsoft.com/rest/api/azure/devops/security/access-control-entries`
- `https://learn.microsoft.com/azure/devops/organizations/security/namespace-reference`
- `https://learn.microsoft.com/azure/devops/organizations/security/manage-tokens-namespaces`

No uses `curl`, `Invoke-RestMethod`, `Invoke-WebRequest`, `az devops security`
ni el helper REST desde comandos improvisados. Todas las llamadas REST deben
originarse dentro de los scripts autorizados de esta skill.

`Invoke-AdoPermissionsRest.ps1` es un helper privado. Los scripts autorizados
pueden cargarlo internamente por dot-sourcing, pero Claude nunca puede
invocarlo ni cargarlo directamente desde Bash o PowerShell.

No reutilices ni modifiques `Invoke-AdoRest.ps1` del dominio de Pipelines.

El fallback debe tomar el PAT únicamente de `$env:AZURE_DEVOPS_PAT`. Nunca
imprimirlo, devolverlo, persistirlo ni leer directamente
`env/Azure-DevOps.txt`. Si falta el PAT o sus alcances son insuficientes,
reporta el bloqueo exacto; no cambies credenciales ni permisos por cuenta
propia.

Documenta y valida como mínimo los alcances necesarios para el caso real:

- lectura de proyectos, repositorios y ramas;
- `vso.graph` / `vso.graph_manage` para grupos y membresías;
- `vso.security_manage` para consultar y administrar ACL/ACE;
- permisos efectivos de Azure DevOps para administrar grupos y permisos Git.

No asumas que tener el scope del PAT sustituye los permisos de la identidad
dueña del PAT.

## Resolución de grupos por proyecto

Los grupos son grupos de seguridad con alcance de proyecto, no equipos ni
grupos globales de la organización.

### Grupo de desarrollo

Para cada proyecto:

1. Busca de forma no sensible a mayúsculas/minúsculas los nombres exactos
   `Development Team` y `Development Teams`.
2. Si existe solamente uno, trabaja con el que existe. No lo renombres.
3. Si no existe ninguno, crea exactamente `Development Team`.
4. Si existen ambos, no elijas, fusiones, renombres ni elimines ninguno.
   Marca la ambigüedad y solicita al usuario cuál debe administrarse antes de
   generar un plan aplicable.
5. Nombres parecidos que no sean uno de los dos anteriores no cuentan como
   coincidencia.

Descripción estándar propuesta:

`Equipo de desarrollo del proyecto. Puede leer y contribuir en los repositorios y ramas autorizadas según la matriz definida, sin administrar permisos, editar políticas, omitir políticas ni eliminar recursos.`

### Grupo de revisión

Busca el nombre sin distinguir mayúsculas/minúsculas:

`Code-Reviewers (Revision Y Aprobacion Del Lider De Proyecto)`

Si no existe, créalo exactamente con ese nombre. No renombres automáticamente
una variante parecida.

Descripción estándar propuesta:

`Líderes o responsables de revisión y aprobación de código del proyecto. Participan en pull requests y aplican la matriz de permisos definida; este grupo por sí solo no crea una política de revisores obligatorios.`

Si un grupo existente no tiene descripción, el plan debe incluir agregar la
descripción estándar. Si tiene una descripción diferente, muestra
`actual → propuesta` en el plan; nunca la sobrescribas silenciosamente.

No agregues estos grupos como miembros de `Contributors`, `Project
Administrators` ni otro grupo si el usuario no lo solicitó expresamente y el
plan no lo enumeró.

## Intake obligatorio antes de generar el plan real

Pregunta al usuario en una sola recopilación clara:

1. Proyectos exactos que se administrarán. Puede indicar uno, varios o todos.
2. Miembros de `Development Team` o `Development Teams` para cada proyecto.
3. Miembros de `Code-Reviewers (...)` para cada proyecto.
4. Si desea conservar las descripciones existentes diferentes o reemplazarlas
   por las descripciones estándar propuestas.

Usa por defecto un modo de membresía **conservador/aditivo**:

- agregar solamente los miembros confirmados que falten;
- conservar todos los miembros existentes;
- no remover personas ni grupos silenciosamente;
- no interpretar una lista nueva como reemplazo total.

Resolver cada miembro por correo o descriptor único. Si un nombre produce más
de una identidad, preguntar; nunca elegir por similitud. Mostrar en el plan el
nombre visible y la identidad única resuelta.

Si el usuario solicita quitar un miembro, la remoción está permitida, pero es
una eliminación: debe mostrar exactamente quién se quitará, de qué grupo y de
qué proyecto, generar su plan de eliminación y solicitar la aprobación
separada descrita más adelante. Después de aprobarse, sí puede removerlo y
hacer readback.

## Alcance de repositorios y ramas

- La matriz de nivel alto se configura una sola vez en el nodo
  `All Repositories` de cada proyecto.
- Después se recorre cada repositorio real del proyecto para administrar los
  nodos de rama indicados.
- `feature/*` significa el prefijo/carpeta `refs/heads/feature`, aplicable a
  todas las ramas hijas presentes y futuras. No significa una rama llamada
  `features` ni se debe crear una rama ficticia.
- Las otras ramas objetivo son exactamente `refs/heads/development`,
  `refs/heads/uat`, `refs/heads/release` y `refs/heads/main`.
- El plan de normalización de permisos no debe crear, modificar, renombrar ni
  eliminar repositorios o ramas como efecto colateral. Estas operaciones no
  están prohibidas permanentemente: cuando el usuario las solicite deben usar
  un modo y un plan específico, con alcance, impacto y aprobación explícitos.
- No activar ni desactivar herencia.
- Si una rama no existe, repórtala como ausente. No la crees. Solo incluye un
  ACL preventivo para una rama futura si Azure DevOps lo soporta, el plan lo
  identifica claramente como tal y el usuario lo aprueba.
- El plan actual de permisos no configura políticas de rama, revisores
  obligatorios, checks ni aprobaciones de PR. El nombre del grupo
  Code-Reviewers no crea por sí mismo una política de aprobación. Sin embargo,
  estas políticas podrán crearse o modificarse en el futuro cuando el usuario
  lo solicite mediante un plan específico aprobado.

## Capacidad futura: repositorios, ramas y políticas de PR

No escribas en `CLAUDE.md`, rules o hooks una prohibición permanente contra
crear o modificar repositorios, ramas o políticas de PR.

Este montaje implementa primero el modo de grupos y permisos. Deja documentado
que el dominio puede ampliarse posteriormente con modos independientes, por
ejemplo:

- `repository-admin`: crear repositorios, cambiar configuración o renombrarlos;
- `branch-admin`: crear ramas o realizar cambios administrativos sobre ellas;
- `pr-policy-admin`: crear o modificar políticas, revisores obligatorios,
  checks y aprobaciones de PR.

Cuando el usuario solicite una de esas operaciones:

1. inventariar primero el estado real mediante MCP y, solo para brechas, API
   controlada;
2. indicar si la capacidad todavía no está implementada;
3. ampliar el dominio con scripts, reglas, hooks y pruebas específicos antes
   de hacer una escritura real;
4. presentar un plan exacto con `actual → deseado`, alcance e impacto;
5. solicitar una aprobación para ese plan;
6. después de aprobarlo, ejecutar las operaciones exactas sin aprobaciones
   internas repetidas y realizar readback.

Una operación futura de creación o modificación puede usar una sola aprobación
si todos sus efectos están enumerados en el plan. Toda eliminación —incluidas
ramas, repositorios o políticas— requiere una aprobación separada de alto
riesgo. Renombrar una rama normalmente implica crear una referencia nueva y
eliminar la anterior: la parte destructiva no puede quedar oculta dentro de la
aprobación de creación.

No crees ahora cascarones vacíos para estos modos futuros ni implementes
escrituras reales que no forman parte de la matriz de permisos solicitada. Solo
evita bloquear su incorporación posterior.

## Matriz explícita en `All Repositories`

Administra únicamente los permisos enumerados. Preserva cualquier permiso no
enumerado.

`Not set` significa quitar solamente el bit explícito administrado de
`allow/deny`, conservando todos los bits no administrados de la ACE.

| Permiso de la UI | Development Team(s) | Code-Reviewers |
|---|---:|---:|
| Advanced Security: manage and dismiss alerts | Deny | Not set |
| Advanced Security: manage settings | Deny | Not set |
| Advanced Security: view alerts | Deny | Not set |
| Bypass policies when completing pull requests | Deny | Not set |
| Bypass policies when pushing | Deny | Not set |
| Contribute | Allow | Allow |
| Contribute to pull requests | Allow | Allow |
| Create branch | Allow | Allow |
| Create repository | Deny | Not set |
| Create tag | Allow | Not set |
| Delete or disable repository | Deny | Not set |
| Edit policies | Deny | Not set |
| Enterprise Live Migration: manage migrations | Not set | Not set |
| Force push (rewrite history, delete branches and tags) | Deny | Not set |
| Manage notes | Deny | Not set |
| Manage permissions | Deny | Not set |
| Read | Allow | Allow |
| Remove others' locks | Deny | Not set |
| Rename repository | Deny | Not set |

En las capturas algunos valores de Code-Reviewers aparecen como
`Allow (inherited)`, por ejemplo `Advanced Security: view alerts`, `Create tag`
y `Manage notes`. No los conviertas en `Allow` explícito: su estado explícito
objetivo es `Not set`. El inventario y readback deben mostrar la fuente real de
la herencia.

## Matriz explícita por rama o prefijo

Los únicos permisos de rama administrados son:

- Bypass policies when completing pull requests;
- Bypass policies when pushing;
- Contribute;
- Edit policies;
- Force push (rewrite history, delete branches and tags);
- Manage permissions;
- Remove others' locks.

Para cada repositorio aplica esta matriz de **valores explícitos**:

| Nodo de rama | Grupo | Bypass PR | Bypass push | Contribute | Edit policies | Force push | Manage permissions | Remove locks |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| `feature/*` (`refs/heads/feature`) | Development Team(s) | Not set | Not set | Not set | Not set | Not set | Not set | Not set |
| `feature/*` (`refs/heads/feature`) | Code-Reviewers | Not set | Not set | Not set | Not set | Not set | Not set | Not set |
| `development` | Development Team(s) | Not set | Not set | **Deny** | Not set | Not set | Not set | Not set |
| `development` | Code-Reviewers | Not set | Not set | Not set | Not set | Not set | Not set | Not set |
| `uat` | Development Team(s) | Not set | Not set | **Deny** | Not set | Not set | Not set | Not set |
| `uat` | Code-Reviewers | Not set | Not set | Not set | Not set | Not set | Not set | Not set |
| `release` | Development Team(s) | Not set | Not set | **Deny** | Not set | Not set | Not set | Not set |
| `release` | Code-Reviewers | Not set | Not set | Not set | Not set | Not set | Not set | Not set |
| `main` | Development Team(s) | Not set | Not set | **Deny** | Not set | Not set | Not set | Not set |
| `main` | Code-Reviewers | Not set | Not set | Not set | Not set | Not set | Not set | Not set |

**Actualizado 2026-09-02** (decisión del usuario, ver
`.claude/agent-memory/ado-permissions-builder/patterns.md`): 2 cambios
respecto a la matriz original de arriba —
1. `development` pasa a ser rama protegida igual que uat/release/main:
   Development Team ahora tiene Contribute = **Deny** también ahí (antes
   `Not set`). Ninguna rama permite push directo salvo `feature/*`.
2. `main` / Code-Reviewers: Contribute pasa de **Deny** a `Not set` (hereda
   el Allow de `All Repositories`). El Deny original les habría impedido
   completar (mergear) un Pull Request justo en la rama donde más importa
   — el objetivo es que Code-Reviewers SÍ pueda aprobar y completar PRs en
   las 4 ramas protegidas; Development Team sigue sin poder (Deny).

Los textos `Allow (inherited)` y `Deny (inherited)` de las capturas son
resultados efectivos, no valores que se envían a la API. Nunca conviertas una
herencia en un Allow/Deny explícito sin mostrar en el plan qué nodo padre se
modificaría y por qué.

El inventario debe distinguir para cada permiso:

- `explicitAllow`;
- `explicitDeny`;
- `inheritedAllow`;
- `inheritedDeny`;
- `effectiveAllow`;
- `effectiveDeny`;
- token/nodo que origina la herencia cuando pueda determinarse.

Si el estado efectivo heredado difiere de las capturas debido a una ACE
intermedia, membresía anidada o herencia desactivada, repórtalo. No inventes una
modificación de un nodo no incluido en la matriz.

## Descubrimiento de namespace, acciones y tokens

No dependas solamente de números hardcodeados.

1. Consulta el security namespace real de Git Repositories.
2. Resuelve los bits por el nombre estable de cada acción y valida que cada
   acción esperada exista una sola vez.
3. Guarda en el inventario el namespace ID, nombre de acción, bit y display
   name encontrados.
4. Implementa una función determinista y probada para construir tokens de
   `All Repositories`, repositorio, rama y prefijo `refs/heads/feature` según la
   documentación oficial.
5. Valida cada token mediante una consulta ACL antes de generar operaciones de
   escritura.
6. Si la versión real cambia nombres, bits o formato, bloquea el plan y reporta
   la discrepancia; no adivines.

Para actualizar una ACE sin destruir información ajena:

```text
newAllow = (currentAllow AND NOT managedMask) OR desiredAllow
newDeny  = (currentDeny  AND NOT managedMask) OR desiredDeny
```

Envía la ACE calculada preservando todos los bits no administrados. Nunca uses
`merge=true` si eso impide limpiar un bit administrado que debe quedar
`Not set`. Nunca reemplaces una ACE con cero sin haber preservado los bits no
administrados.

## Flujo real obligatorio

```text
intake de proyectos y miembros
  → inventario MCP de proyectos/repositorios/ramas/identidades
  → inventario REST GET de grupos, membresías, namespaces y ACL/ACE
  → resolución de nombres, descriptores, herencia e impacto
  → plan JSON determinista y sanitizado
  → Test-AdoPermissionsPlan.ps1
  → revisión independiente con ado-permissions-reviewer
  → presentar plan completo e invocar Apply para mostrar una sola aprobación
  → apply exacto ya aprobado
  → readback completo
  → reporte de aplicado/omitido/fallido y divergencias
  → memoria solamente si existe aprendizaje reutilizable confirmado
```

No saltes pasos.

## Contenido mínimo del plan

El plan debe incluir como mínimo:

- versión de esquema;
- `operationKind` no destructivo;
- organización;
- proyectos y repositorios exactos con IDs y nombres;
- grupos resueltos, creados o ambiguos;
- descripción actual y deseada;
- miembros actuales y adiciones exactas;
- modo de membresía `additive`;
- inventario base y su hash;
- fecha de creación y expiración;
- matriz administrada;
- estado actual explícito, heredado y efectivo;
- estado explícito deseado;
- impacto esperado, incluidas personas afectadas por Deny;
- lista exacta de operaciones aprobables;
- para cada operación: tipo, método, URI relativa permitida, descriptor/token,
  body sanitizado, `bodyHash`, precondición y `operationId`;
- `validationHash` del plan validado.

El plan debe ser inmutable después de validarse. El journal de ejecución se
guarda por separado en `.local/azure-devops-permissions/executions/`.

Antes de cada escritura, relee el recurso y compara la precondición con el
inventario aprobado. Si existe drift, no sobrescribas el cambio reciente:
omite ese alcance, repórtalo y exige generar un plan nuevo.

## Modelo de aprobación solicitado

Las lecturas, inventarios, preguntas de intake, generación de planes, dry-runs,
validaciones y pruebas offline no requieren aprobación.

Para un plan no destructivo completo:

1. Presenta un resumen legible con todos los proyectos, grupos, descripciones,
   miembros a agregar, repositorios, ramas y cambios `actual → deseado`.
2. Incluye advertencias de herencia, membresía superpuesta y posible bloqueo
   por Deny.
3. Invoca inmediatamente `Apply-AdoPermissionsPlan.ps1` en el mismo turno.
4. El hook debe mostrar **una única tarjeta nativa de aprobación** para todo el
   plan enumerado. Esa tarjeta es la aprobación del plan; no pidas antes otro
   “sí” textual.
5. Una vez aceptada, ejecuta todas las operaciones exactas del plan y el
   readback dentro del mismo proceso PowerShell, sin pedir aprobaciones por
   cada proyecto, grupo, miembro, repositorio, rama, llamada REST o comando
   PowerShell interno.

La aprobación cubre únicamente el plan identificado por su hash. No cubre:

- operaciones agregadas después;
- otro proyecto o repositorio;
- otro plan;
- una corrección que cambie body, URI, descriptor o token;
- un reintento después de regenerar o modificar el plan;
- ninguna eliminación.

Los reintentos automáticos dentro de la misma ejecución aprobada se permiten
solamente para la misma operación inmutable ante HTTP 429 o 5xx transitorios,
con espera acotada y máximo tres intentos. No reintentes 400, 401, 403, 404,
409 ni un error de precondición/drift.

## Eliminaciones: aprobación siempre separada

`Apply-AdoPermissionsPlan.ps1`, que corresponde al modo actual no destructivo
de grupos y permisos, debe rechazar:

- cualquier método HTTP `DELETE`;
- eliminación de grupos;
- remoción de miembros;
- eliminación de ACE/ACL completas;
- eliminación de repositorios o ramas;
- cualquier `operationKind` destructivo.

Una normalización de un bit administrado a `Not set` no elimina un recurso y
puede formar parte del plan principal, siempre que conserve los bits no
administrados.

Para eliminar un grupo o remover una membresía, usa exclusivamente:

```text
New-AdoPermissionsDeletePlan.ps1
  → Test-AdoPermissionsDeletePlan.ps1
  → presentar exactamente una eliminación
  → Apply-AdoPermissionsDeletePlan.ps1
  → tarjeta de aprobación separada
  → respaldo previo obligatorio
  → eliminación
  → readback
```

Cada plan de eliminación contiene exactamente una eliminación. No agrupes
varias. Si el respaldo de solo lectura falla, no elimines nada. Aprobar una
eliminación no autoriza recrear el recurso.

La eliminación de repositorios, ramas y políticas no se implementa dentro de
`Apply-AdoPermissionsDeletePlan.ps1`, porque ese script actual se limita a
grupos y membresías. No obstante, no queda prohibida permanentemente. Cuando el
usuario la solicite, debe implementarse un modo de eliminación dedicado con:

- inventario y validación del objetivo exacto;
- plan de una sola eliminación;
- recuperación o respaldo verificable cuando sea aplicable;
- advertencia expresa si la acción no puede recuperarse completamente;
- aprobación separada de alto riesgo;
- validación previa inmediata y readback posterior.

## Controles contra bloqueo administrativo

Antes de validar un plan:

- identifica la cuenta que ejecuta el PAT/MCP;
- calcula si esa identidad es miembro directo o anidado de alguno de los
  grupos que recibirá Deny;
- detecta miembros presentes simultáneamente en Development Team(s) y
  Code-Reviewers;
- recuerda que Deny puede prevalecer sobre Allow de otro grupo;
- confirma que existe al menos otro administrador efectivo no afectado antes
  de aplicar Deny sobre `Manage permissions`;
- muestra el impacto de los Deny en el resumen del plan.

Si no puedes demostrar que se mantiene acceso administrativo, marca el plan
como bloqueado. No dependas de una suposición.

## Seguridad del helper REST

Implementa como mínimo:

- `[CmdletBinding()]`, modo estricto y `$ErrorActionPreference = 'Stop'`;
- hosts permitidos cerrados: `dev.azure.com` y `vssps.dev.azure.com` para la
  organización aprobada;
- métodos y rutas permitidos por tipo de operación;
- URI relativas normalizadas, sin host arbitrario ni redirecciones externas;
- paginación completa y continuation tokens;
- timeout explícito;
- redacción de cabeceras, PAT y cuerpos sensibles en errores;
- rechazo de `Invoke-Expression`, comandos arbitrarios y parámetros libres;
- serialización JSON determinista;
- validación de hashes y precondiciones inmediatamente antes de escribir;
- cuerpos sin secretos;
- readback después de cada escritura;
- resultado final estructurado sin credenciales.

Operaciones no destructivas permitidas en el plan principal:

- crear el grupo de proyecto faltante;
- agregar o actualizar su descripción;
- agregar un miembro confirmado;
- establecer una ACE Git calculada para los permisos administrados.

No permitas que el plan contenga una URL, método u operación distinta de la
lista cerrada.

## Hooks nuevos e integración en settings

Agrega en `.claude/settings.json`, preservando todas las entradas existentes:

- `PreToolUse` para `Bash|PowerShell` →
  `ado-permissions-security-gate.ps1`;
- `PostToolUse` para `Write|Edit|MultiEdit` →
  `ado-permissions-post-validate.ps1`;
- `Stop` → `ado-permissions-stop-validate.ps1`.

El security gate debe:

- permitir sin pregunta scripts de inventario, plan, validación, readback y
  pruebas;
- devolver `permissionDecision: "ask"` al detectar exactamente
  `Apply-AdoPermissionsPlan.ps1`;
- devolver `permissionDecision: "ask"` cada vez que detecte
  `Apply-AdoPermissionsDeletePlan.ps1`;
- negar la invocación o dot-sourcing directo de
  `Invoke-AdoPermissionsRest.ps1`;
- negar REST/CLI de permisos improvisado;
- negar un DELETE dentro del apply principal;
- no interferir con los scripts ni hooks de Pipelines.

No agregues `PowerShell(*)`, `Bash(*)`, `curl(*)`, REST global ni permisos
globales amplios a `.claude/settings.local.json`. Agrega solamente las entradas
mínimas para las herramientas MCP de lectura y los scripts no destructivos de
este dominio. El apply real debe entrar por su hook y una única tarjeta; todas
sus llamadas internas deben ejecutarse en el mismo proceso para que no aparezca
una segunda solicitud de PowerShell.

Los hooks post/stop deben validar solamente el nuevo dominio y los archivos
globales que se integraron. También deben comprobar que continúan presentes
los dominios y hooks anteriores. No hagan llamadas reales a Azure DevOps.

## Agentes y memoria

Los tres agentes deben incluir en frontmatter:

```yaml
memory: project
```

El `name` debe coincidir exactamente con la carpeta de memoria.

- `ado-permissions-builder`: intake, inventario, generación y aplicación de un
  plan aprobado.
- `ado-permissions-reviewer`: revisión independiente de alcance, matrices,
  hashes, herencia, membresías, impacto y riesgo de lockout. No aplica cambios.
- `ado-permissions-diagnoser`: diagnóstico de MCP, Graph API, Security API,
  PAT, scopes, descriptores, tokens, herencia y readback. No corrige sin plan.

Inicializa `MEMORY.md`, `debugging.md` y `patterns.md` con contenido mínimo y
específico. No copies las instrucciones completas ni guardes secretos, salidas
masivas o datos personales innecesarios.

## Integración mínima en CLAUDE.md

Agrega una sección separada llamada, por ejemplo:

`## Alcance adicional: Azure DevOps Permissions Administration`

Debe apuntar a la nueva skill, reglas y documentación y aclarar:

- que no pertenece al dominio de Pipelines;
- MCP primero y REST controlado para Graph/Security;
- una aprobación para el plan no destructivo completo;
- ninguna aprobación adicional de PowerShell después de aceptar esa tarjeta;
- toda eliminación requiere su propia aprobación;
- el plan actual de permisos no cambia ramas, repositorios ni políticas de PR
  como efecto colateral, pero esas operaciones pueden agregarse posteriormente
  mediante modos y planes específicos aprobados;
- no se exponen secretos.

Aclara en las reglas globales que la política de una aprobación atómica de este
dominio cubre únicamente los cambios no destructivos enumerados en un plan de
permisos validado. No debilites la política de aprobación de Pipelines, n8n,
Schema Sync, AKS, SSH ni otros dominios.

Actualiza de forma aditiva la tabla del MCP `azure-devops` para indicar que
también se usa como inventario de proyectos/repositorios/ramas para este
dominio. No reemplaces `.mcp.json` ni cambies el paquete fijado.

## Pruebas obligatorias

Crea pruebas offline con mocks; nunca uses la organización real ni un PAT real.

Debes cubrir al menos:

1. Existe `Development Team` y se reutiliza.
2. Existe `Development Teams` y se reutiliza.
3. No existe ninguno y se planea crear `Development Team`.
4. Existen ambos y el plan queda bloqueado por ambigüedad.
5. Code-Reviewers faltante y creación con nombre/descripción correctos.
6. Membresía aditiva conserva miembros existentes.
7. Identidad ambigua bloquea el plan.
8. La matriz `All Repositories` coincide exactamente con esta instrucción.
9. La matriz de `feature/*`, development, uat, release y main coincide.
10. `Not set` limpia solo bits administrados y conserva bits ajenos.
11. Construcción y validación del token de `refs/heads/feature`.
12. Plan alterado después de validar es rechazado.
13. Inventario expirado o drift es rechazado.
14. El apply principal rechaza DELETE, remoción de miembro y grupo.
15. Cada delete plan contiene exactamente una eliminación y respaldo.
16. El helper REST directo es bloqueado por el hook.
17. El apply principal produce una sola decisión `ask`.
18. Cada apply de eliminación produce su propia decisión `ask`.
19. No hay solicitudes adicionales para PowerShell interno después del apply.
20. El readback detecta diferencias explícitas, heredadas y efectivas.
21. El guard de lockout bloquea cuando no queda administrador seguro.
22. Los hooks existentes de Pipelines, Schema Sync y n8n se preservan.
23. `.mcp.json` conserva todos los MCP existentes y el paquete fijado.
24. Ningún fixture, log, plan o memoria contiene PAT o cabeceras de auth.
25. Una remoción de miembro es permitida únicamente mediante un delete plan y
    su aprobación separada.
26. Las reglas no prohíben permanentemente administrar repositorios, ramas o
    políticas de PR, pero el apply de permisos actual rechaza que se mezclen
    como efectos colaterales.

Ejecuta y reporta:

- validación JSON de los archivos modificados;
- parser de PowerShell para todos los `.ps1` nuevos o modificados;
- pruebas de scripts del nuevo dominio;
- pruebas de hooks del nuevo dominio;
- pruebas existentes de Azure DevOps Pipelines y Schema Sync para detectar
  regresiones, sin ejecutar nada real;
- búsqueda de secretos sanitizada;
- verificación de que no se hicieron llamadas reales ni cambios en Azure
  DevOps.

## Criterios finales de aceptación

La tarea queda completa solamente si:

- la nueva estructura está separada de Pipelines;
- no se alteró el comportamiento de los dominios existentes;
- las matrices están codificadas una sola vez como fuente de verdad y las
  pruebas las consumen, sin duplicaciones divergentes;
- el plan es determinista, validado, inmutable e idempotente;
- MCP se usa primero y la brecha Graph/Security usa REST controlado;
- existe una sola aprobación para el plan no destructivo completo;
- no hay aprobaciones PowerShell adicionales después de esa aprobación;
- toda eliminación usa una aprobación separada y respaldo;
- los miembros existentes se conservan por defecto y pueden removerse solo con
  un plan de eliminación aprobado;
- el plan actual no cambia repositorios, ramas ni políticas de PR como efecto
  colateral, pero no impide incorporar esas capacidades mediante planes
  específicos aprobados en el futuro;
- la herencia no se convierte silenciosamente en permisos explícitos;
- se preservan bits no administrados y cambios concurrentes;
- existe readback y reporte por proyecto/repositorio/rama;
- todos los tests offline pasan;
- no se ejecutó ningún cambio real en Azure DevOps.

Al finalizar, entrégame:

1. árbol de archivos creados y archivos globales modificados;
2. resumen del comportamiento implementado;
3. matriz final codificada;
4. resultado de todas las pruebas;
5. confirmación expresa de que Pipelines y los otros dominios siguen intactos;
6. confirmación expresa de que no se ejecutó ninguna operación real en Azure
   DevOps;
7. limitaciones encontradas del MCP/API o permisos faltantes, si existen.
