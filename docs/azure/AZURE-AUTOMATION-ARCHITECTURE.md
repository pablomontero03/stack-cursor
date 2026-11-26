# Arquitectura — Administración de recursos de Azure (Azure Resource Manager)

Implementado 2026-09-03 a partir de `INSTRUCCIONES-AUTOMATIZACION-AZURE.md`
(raíz del proyecto), con una decisión del usuario que modifica el alcance
original: **el MCP oficial `azure` (`@azure/mcp`) queda diferido** — la
única versión publicada en npm en ese momento era una pre-release
(`3.0.0-beta.40`, sin versión estable). El dominio se construyó para
funcionar 100% con Azure CLI + Azure Resource Graph + ARM REST
controlado, sin ninguna dependencia del MCP.

## Objetivo

Administrar el plano de control de Microsoft Azure (tenants,
suscripciones, Resource Groups, redes, cómputo, Storage, Key Vault, Azure
SQL como infraestructura, Monitor, gobernanza, AKS como recurso) con el
mismo modelo de aprobación mínima-pero-segura que ya usan Azure DevOps
Pipelines, Azure DevOps Permissions y AKS: lectura/inventario/diagnóstico/
simulación automáticos; una sola aprobación cubre todo un plan no
destructivo completo; las eliminaciones exigen siempre una aprobación
separada, inmediatamente antes de la fase destructiva.

## Componentes

```text
.claude/
├── skills/manage-azure-resources/
│   ├── SKILL.md
│   ├── references/            (7 archivos, ver tabla de enrutamiento en SKILL.md)
│   └── scripts/                (11 scripts + tests/)
├── agents/azure/                (azure-operator, azure-diagnoser, azure-reviewer)
├── agent-memory/azure-*/        (MEMORY.md, debugging.md, patterns.md por agente)
├── rules/azure/                 (authorization.md, security.md)
└── hooks/azure/                 (7 scripts + tests/)

docs/azure/AZURE-AUTOMATION-ARCHITECTURE.md   (este archivo)

.local/azure/                    (no versionado)
├── inventory/  plans/  backups/  executions/  logs/  deviations/
```

- **`Azure-Common.ps1`**: librería compartida — hash canónico SHA-256 del
  plan, journal de ejecución con lock exclusivo de archivo y escritura
  atómica, contexto de cuenta (`az account show` sanitizado), y las 2
  funciones de escaneo de secretos (`Find-AzureSensitiveJsonProperties` /
  `Find-AzureSensitiveRawText`).
- **`New-AzureChangePlan.ps1` / `Test-AzureChangePlan.ps1`**: arman y
  validan un plan inmutable con el esquema completo de 23 campos por
  operación (ver `references/change-plan-schema.md`).
- **`Apply-AzureChangePlan.ps1`**: único script que ejecuta escrituras no
  destructivas reales.
- **`Apply-AzureDeletePlan.ps1`**: único script que ejecuta eliminaciones
  reales — siempre con respaldo pre-delete automático y aprobación
  separada.
- **`Test-AzurePostChange.ps1`**: readback de solo lectura tras aplicar.
- **`New-AzureRollbackPlan.ps1`**: prepara (nunca aplica) un plan inverso.

## Modelo de autorización

Ver el detalle completo en `.cursor/rules/azure.mdc` — resumen:

- Lectura, inventario, Resource Graph, Activity Log, what-if y validación:
  automáticos.
- Aprobación del plan principal: una sola tarjeta cubre TODAS las
  operaciones `create`/`update`/`action` de `approvedOperations`.
- Aprobación destructiva: siempre separada, cubre el lote exacto de
  `pendingDeleteOperations` identificado por sus `operationId`. Un
  Resource Group completo siempre queda aislado — nunca comparte lote.
- Reutilización de aprobación visible: `azure-plan-authorization.ps1` /
  `azure-delete-authorization.ps1` permiten el comando exacto de Apply sin
  tarjeta nueva cuando el último plan aprobado por `ExitPlanMode` contiene
  el bloque ```azure-apply-authorization``` / ```azure-delete-authorization```
  correspondiente, con el hash del plan verificado y vigencia ≤24h — mismo
  mecanismo (adaptado) que `ado-apply-authorization` en Azure DevOps
  Pipelines.
- Nunca `deny` como resultado general — solo 2 bloqueos absolutos
  detectables por texto (`bypassPermissions`/
  `--dangerously-skip-permissions`).

## Plan de cambio — esquema y garantías

Esquema exacto en `references/change-plan-schema.md`. Garantías
implementadas y probadas (ver § Pruebas):

- `argv` siempre tokenizado — nunca un string de shell crudo.
- Plan inmutable: cualquier edición posterior invalida `validationHash`.
- Drift de inventario detectado en `Test-AzureChangePlan.ps1` Y de nuevo
  en `Apply-AzureChangePlan.ps1`/`Apply-AzureDeletePlan.ps1`.
- Aislamiento de Resource Group completo enforced en 3 capas
  (`New-AzureChangePlan.ps1`, `Test-AzureChangePlan.ps1`,
  `Apply-AzureDeletePlan.ps1`).
- `Apply-AzureDeletePlan.ps1` exige que `-OperationIds` coincida EXACTO
  con el lote — rechaza subconjuntos distintos o ids adicionales.
- Journal con lock exclusivo + escritura atómica; una operación
  `succeeded` nunca se reintenta automáticamente.
- Respaldo pre-delete obligatorio (`az resource show`) — un respaldo
  fallido o vacío detiene esa eliminación.

## MCP `azure` — diferido

Estado 2026-09-03: **no instalado, no declarado en `.mcp.json`**. La
única versión publicada de `@azure/mcp` en npm es `3.0.0-beta.40` (sin
versión estable). Decisión del usuario: construir el dominio completo
sobre Azure CLI/Resource Graph/ARM REST primero, y agregar el MCP en una
fase separada — cuando exista una versión estable, o cuando el usuario lo
pida explícitamente — fijando una versión exacta y probándolo primero
solo en modo lectura (ver `.cursor/rules/azure.mdc` §
Conexión del MCP para el procedimiento).

Ninguna funcionalidad de este dominio depende del MCP — inventario
(Resource Graph), diagnóstico, planificación, creación, modificación y
eliminación funcionan completos vía los scripts de `scripts/`.

## Autenticación

Azure CLI ya instalado y autenticado en esta máquina al momento de
construir el dominio (verificado 2026-09-03, sanitizado): versión 2.61.0,
tenant "Hospital Metropolitano" (`33dd4184-...`), suscripción por defecto
"Hospital Metropolitano" (`69dc43ec-...`), usuario
`helpdesk@grupomontecristo.com`. Este dominio reutiliza esa sesión —
nunca ejecuta `az login`/`az logout`/`az account clear` por su cuenta. Ver
`references/authentication-and-context.md`.

## Pruebas

- `scripts/tests/run-script-tests.ps1`: 24/24 PASS. `az` se intercepta
  con un stub (`az.cmd` + `az-stub.ps1`) antepuesto al PATH del proceso de
  prueba — cero red, cero Azure real.
- `hooks/tests/run-hook-tests.ps1`: 48/48 PASS. Cada caso invoca el hook
  real vía stdin JSON mockeado.
- Ambas suites: cero llamadas reales a Azure.

## Verificaciones reales ejecutadas durante la implementación (solo lectura)

Permitidas explícitamente por la guía original — ninguna crea, modifica
ni elimina un recurso real:

- `az version` → CLI 2.61.0 instalada.
- `az account show` (sanitizado) → sesión activa confirmada (ver §
  Autenticación).
- Nota: no se ejecutó `az graph query` real contra la suscripción del
  usuario durante esta implementación — la verificación de Resource Graph
  quedó cubierta por la suite de pruebas offline (stub). Queda pendiente
  como primera prueba real de solo lectura antes del primer uso operativo
  (`Get-AzureInventory.ps1` con una suscripción real).

## Pendiente de aprobación

Estos 2 puntos requieren una decisión/aprobación explícita del usuario
antes de aplicarse — **no se tocaron automáticamente**:

### 1. `.gitignore` — agregar `.local/azure/`

Propuesta exacta (agregar al `.gitignore` raíz del proyecto):

```gitignore
/env/
/.local/
*.pfx
*.pem
*.key
*kubeconfig*
```

Nota: `/.local/` ya cubriría `.local/azure/` completo si se agrega tal
cual la guía original lo propone (cubre también `.local/aks/`,
`.local/azure-devops/`, etc. — todos ya no versionados hoy de facto,
aunque el `.gitignore` actual del repo declare permitir versionar `env`,
`.local` y binarios, según lo que ya señalaba
`INSTRUCCIONES-AUTOMATIZACION-AZURE.md` § Resultado del análisis). Antes
de aplicar, revisar si alguno de esos paths ya está versionado
(`git ls-files .local/`) — no se ejecuta eliminación del índice ni
reescritura de historial sin aprobación específica separada.

### 2. Instalación futura del MCP `azure`

Cuando exista una versión estable de `@azure/mcp`, o el usuario lo pida
explícitamente: fijar la versión exacta en `.mcp.json` (nunca `@latest`),
reiniciar Claude Code, enumerar sus tools reales, y clasificarlas una por
una en `references/command-classification.md` y en
`azure-security-gate.ps1` antes de habilitar cualquier escritura vía MCP
— mientras tanto, las escrituras siguen pasando exclusivamente por
`Apply-AzureChangePlan.ps1`/`Apply-AzureDeletePlan.ps1`.

## Decisiones de diseño no triviales tomadas durante la implementación

1. **`-Operations` de `New-AzureChangePlan.ps1` es opcional** (default
   `@()`), a diferencia de lo implícito en el esquema de la guía — un plan
   puramente de eliminaciones (sin ninguna operación no destructiva) es un
   caso legítimo y common (ej. "borrar 3 recursos huérfanos"). PowerShell
   rechaza un parámetro `Mandatory` de tipo array con una colección vacía,
   así que forzarlo `Mandatory` habría impedido ese caso de uso.
2. **Mecanismo de reutilización de aprobación visible simplificado**
   respecto al de Azure DevOps Pipelines: en vez de verificar hash de plan
   + hash de inventario por separado, alcanza con el hash del PLAN — el
   plan ya embebe y revalida en cada Apply el hash de cada inventario que
   referencia (`inventoryHashes`), así que un inventario alterado ya
   invalida el plan por otra vía.
3. **`azure-delete-authorization.ps1` casi siempre cae a confirmación
   nativa, no a reutilización silenciosa.** El parámetro `-OperationIds`
   de `Apply-AzureDeletePlan.ps1` normalmente se pasa como un array
   (`@('id1','id2')`), que el analizador AST del mecanismo de reutilización
   no puede tratar como valor literal simple (solo strings literales
   califican) — en la práctica, esto significa que una eliminación real
   casi siempre pide confirmación nativa explícita en el momento, en vez
   de reutilizar una aprobación previa. Se dejó así a propósito: es un
   sesgo hacia más fricción en la ruta más peligrosa del dominio, no un
   bug a "arreglar" sin más contexto — si se quisiera habilitar el reuso
   también aquí, haría falta extender el analizador para reconocer arrays
   de literales, evaluado como mejora futura, no bloqueante.
4. **`'pat'` excluido de los nombres de propiedad sensibles.** Como
   substring genérico, producía falsos positivos constantes (`path`,
   `update`, `template`, `compute`, ...) durante las pruebas — los
   secretos reales de Azure no usan ese nombre (usan
   `clientSecret`/`accessToken`/`accountKey`/`sasToken`, todos ya
   cubiertos). Corregido tras encontrarlo con la suite de pruebas.
5. **Bug real de PowerShell encontrado y evitado sistemáticamente**:
   una función que hace `return @($lista)` sufre "unwrapping" de array de
   un solo elemento al cruzar el límite de pipeline de una llamada de
   función — el llamador recibe el objeto escalar, no un array de 1, y
   cualquier `.Count` posterior falla silenciosamente. Todo el código de
   producción de este dominio ya envolvía las llamadas relevantes con
   `@(...)` en el sitio de la llamada (mismo patrón defensivo que AKS/ADO
   ya usaban) — el bug solo afectó las aserciones de prueba directas
   sobre `Find-Azure*`/`Find-AzureHook*`, corregidas del mismo modo.

## Azure FinOps (`analyze-azure-costs`) — agregado 2026-09-03

Sub-skill implementada a partir de `INSTRUCCIONES-SUBAGENTE-AZURE-FINOPS.md`
(raíz del proyecto), sobre este mismo dominio — sin crear una arquitectura
paralela. Acotada a la suscripción `69dc43ec-5f24-4203-9239-a8d0f8506d44`
("Hospital Metropolitano").

```text
.claude/
├── skills/analyze-azure-costs/
│   ├── SKILL.md
│   ├── references/      (cost-definitions, cost-data-sources, utilization-correlation, reporting-and-charts)
│   └── scripts/          (6 scripts + tests/, todos dot-sourcean Azure-Common.ps1 del dominio general)
├── agents/azure/azure-finops-analyst.md
└── agent-memory/azure-finops-analyst/   (MEMORY.md, debugging.md, patterns.md)

.local/azure/finops/       (no versionado)
├── raw/  normalized/  reports/  charts/  executions/
```

Reutiliza integralmente el dominio general: `Azure-Common.ps1` (hash,
journal, contexto de cuenta, escaneo de secretos), `azure-operator`
(ejecución aprobada de cualquier plan de optimización) y `azure-reviewer`
(revisión independiente) — no se creó un mecanismo de plan ni un reviewer
paralelo. Ningún script de este sub-dominio ejecuta una escritura real.

### 2 ediciones quirúrgicas a los hooks existentes (nada más se tocó)

1. `azure-secret-scan-lib.ps1` → `Get-AzureHookScanTargetPaths` ahora
   también escanea `.claude/agent-memory/azure-finops-analyst/`.
2. `azure-security-gate.ps1` → nueva función
   `Test-AzureCostManagementReadOnlyRestPost` + una línea nueva
   (`costmanagement query|forecast` → `allow`). Clasifica como lectura
   automática un `az rest --method post` **únicamente** cuando: el host es
   `management.azure.com`; la ruta es EXACTA
   `/subscriptions/69dc43ec-.../[resourcegroups/<x>/]providers/Microsoft.CostManagement/(query|forecast)`;
   y el `--body` inline (si existe) parsea como JSON con TODAS sus claves
   de nivel superior dentro del set permitido (`type`, `timeframe`,
   `timePeriod`, `dataset`, `granularity`, `aggregation`, `grouping`,
   `filter`, `sorting`, `top`, `skiptoken`). Otra suscripción, otra ruta,
   `--body @archivo.json` (no verificable), o una clave desconocida
   siguen preguntando — nunca se asume lectura sin poder validar el
   esquema exacto. Las 48 pruebas de hook previas siguen pasando sin
   cambios; se sumaron 10 casos nuevos (58/58 total).

### Bugs reales encontrados y corregidos durante la construcción

1. **PowerShell: array-de-arrays se aplana al recolectarse dentro de
   `@()`** (afectó el stub de pruebas: `rows = @(@('a',1,'USD')
   @('b',2,'USD'))` sin el operador coma unario se aplanaba a un array
   plano de 6 elementos, no 2 filas de 3 columnas). Fix: `,@(...)` en
   cada fila.
2. **PowerShell: un `if/else` asignado a una variable "desenvuelve" un
   array interno de 1 solo elemento** — encontrado en `$currencies`
   (`Invoke-AzureCostQuery.ps1`) y `$advisorRecommendations`
   (`Get-AzureCostRecommendations.ps1`), rompiendo silenciosamente
   `recommendationCount`/`currencyWarning` en el caso más común (1 sola
   moneda / 1 sola recomendación). Fix: envolver TODO el if/else con un
   `@()` exterior, nunca solo la rama interna (documentado en
   `.claude/agent-memory/azure-finops-analyst/patterns.md`).
3. **`Export-Csv` usa la cultura regional de la máquina para números** —
   en esta máquina escribía `120,75` (coma decimal) dentro de un CSV
   delimitado por comas: válido sintácticamente (entre comillas) pero
   incorrecto/ambiguo para un lector que espere punto decimal. Fix:
   formatear el valor con `CultureInfo.InvariantCulture` antes de
   `Export-Csv`.
4. **`New-AzureFinOpsReport.ps1` sumaba costos de monedas distintas sin
   advertir** en su primera versión — corregido antes de la primera
   corrida real: si los datos traen más de una moneda, `total` queda
   `null` y se agrega una advertencia explícita en vez de calcular un
   total mezclado.

### Bug real encontrado en el dominio general (NO corregido — fuera del alcance aprobado de esta tarea)

**`Get-AzureInventory.ps1` (dominio general, `manage-azure-resources`)
subcuenta drásticamente los recursos reales de la suscripción cuando cae
al fallback `az resource list`.** Confirmado en vivo 2026-09-03: `az
resource list --subscription 69dc43ec-...` devuelve un array plano real
de ~445 recursos (verificado con una llamada `az` directa), pero
`Get-AzureInventory.ps1`/`Get-AzureCostInventory.ps1` reportó
`resourceCount: 1`, con ese único elemento envuelto de forma anómala en
un objeto `{ "value": [...] }` en vez de ser un elemento plano del array
`resources`. La extensión `resource-graph` tampoco está instalada en esta
máquina (`Test-AzureEnvironment.ps1` ya lo señalaba como posible), lo que
fuerza justamente esa ruta de fallback. Reportado a la sesión principal
para su propio análisis y corrección — esta implementación FinOps no lo
tocó porque `Get-AzureInventory.ps1` no está entre los archivos
autorizados para editar en esta tarea puntual.

### Pruebas y verificaciones reales (FinOps)

- `analyze-azure-costs/scripts/tests/run-script-tests.ps1`: **20/20
  PASS**, cubre los 10 puntos de la guía original § Pruebas (normalización
  ActualCost/AmortizedCost, monedas no se suman, mes parcial vs. completo,
  agrupaciones, forecast, Pareto, datos faltantes/nulos, paginación
  (`properties.nextLink`), errores HTTP sin exponer info sensible, y
  generación CSV/Excel/gráficos) — cero llamadas reales a Azure.
- `hooks/tests/run-hook-tests.ps1`: **58/58 PASS** (48 previos + 10
  nuevos de la excepción Cost Management).
- `manage-azure-resources/scripts/tests/run-script-tests.ps1`: re-confirmado
  **24/24 PASS** tras las 2 ediciones a los hooks — cero regresión.
- Verificaciones reales de solo lectura, sesión ya autenticada
  (`69dc43ec-5f24-4203-9239-a8d0f8506d44`, "Hospital Metropolitano"):
  `az account show` ✓; `Test-AzureFinOpsContext.ps1` confirma
  `subscriptionMatches=true` ✓; **Cost Management Query real**: la
  primera llamada (idéntica a la que arma `Invoke-AzureCostQuery.ps1`)
  devolvió 3 días reales de costo (USD, 1-3 sept 2026); llamadas
  posteriores —incluida la del propio script— chocaron con `429 Too Many
  Requests` real de la API (throttling genuino de Cost Management en esta
  suscripción, no un bug del script: el mismo cuerpo idéntico vía `az
  rest` directo también quedó 429 en los reintentos); el script manejó el
  fallo correctamente (`ok:false` con nota genérica, sin exponer nada
  sensible) ✓; **Resource Graph/inventario real**: `resourceCount:1` — ver
  el bug del dominio general documentado arriba, el mecanismo igual
  respondió y quedó registrado ✓; **Azure Monitor Metrics real**: el
  único recurso que el inventario devolvió
  (`Microsoft.Insights/dataCollectionEndpoints`) no soporta métricas de
  plataforma — pendiente, no se pudo completar con un recurso real
  disponible en esta corrida; **Azure Advisor real**: ✓, 38
  recomendaciones de costo reales devueltas (incluye una de savings plan
  con ahorro anual estimado de USD 4586, y varias de VM reservada).

### Pendiente

- Reintentar la consulta real de Cost Management fuera de esta sesión
  (el throttling debería despejarse solo).
- Cuando exista un recurso real que soporte Azure Monitor Metrics
  (después de que se corrija el bug de inventario de arriba, o
  apuntando manualmente a uno conocido, ej. el AKS
  `gmon-prod-aks-eastus2-0001` que Advisor sí ve), completar esa
  verificación real pendiente.
- Instalar la extensión `resource-graph` de Azure CLI (con aprobación) si
  se quiere Resource Graph real en vez de depender siempre del fallback
  `az resource list`.
- Primer análisis FinOps completo real (resumen ejecutivo, desglose,
  optimización) — no se generó ninguno con datos reales durante esta
  implementación, solo el mecanismo quedó validado.
