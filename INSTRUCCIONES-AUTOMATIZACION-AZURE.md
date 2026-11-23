# Implementación del dominio general de Microsoft Azure

## Contexto

Proyecto local:

```text
D:\Proyectos\automation
```

La estructura actual ya contiene dominios independientes para:

- Azure DevOps Pipelines.
- Azure DevOps Permissions.
- AKS/Kubernetes/Helm.
- n8n.
- Schema Sync.
- Administración del servidor Linux `172.16.2.60`.

Falta un dominio general para administrar recursos de Microsoft Azure mediante Azure Resource Manager. Esta implementación debe agregarse de forma aditiva, sin mezclar ni debilitar los dominios existentes.

El objetivo es que el agente pueda analizar, diagnosticar, crear, modificar y eliminar recursos de Azure. Las aprobaciones deben ser mínimas pero seguras:

1. Las lecturas, inventarios, diagnósticos, validaciones y simulaciones no requieren aprobación.
2. El agente prepara primero un plan detallado y revisado.
3. La aprobación del plan autoriza todas las creaciones y modificaciones declaradas.
4. Después de aprobar el plan no se piden aprobaciones adicionales para operaciones no destructivas incluidas en él.
5. Las eliminaciones requieren una aprobación adicional, inmediatamente antes de la fase destructiva.
6. Después de aprobar el lote de eliminaciones exacto, no se pregunta por cada comando interno.
7. Cualquier desviación del plan obliga a detenerse y preparar un plan nuevo.

## Resultado del análisis de la estructura actual

En el ZIP revisado se encontraron:

| Componente | Cantidad/estado |
| --- | --- |
| Skills | 7 |
| Agentes | 15 |
| Hooks PowerShell | 19 |
| Reglas | 13 |
| MCP configurados | `n8n-interno`, `n8n-productivo`, `azure-devops`, `aks` |
| Azure DevOps Pipelines | Implementación madura |
| Azure DevOps Permissions | Implementación madura |
| AKS | Implementación madura |
| Azure general | No existe |

Brechas adicionales detectadas:

- `README.md` solo contiene el título del proyecto.
- Las reglas de n8n y Schema Sync están vacías.
- `.claude/settings.local.json` tiene una gran cantidad de permisos específicos; Azure no debe aumentar esa lista con cientos de comandos `az`.
- El modelo de aprobación actual no es uniforme entre dominios.
- `.gitignore` declara que permite versionar `env`, `.local` y binarios.
- El ZIP contiene archivos cuyos nombres indican posibles claves, tokens y conexiones. Sus contenidos no fueron leídos, pero no deberían quedar expuestos en Git ni en artefactos compartidos.

La corrección de estos puntos debe presentarse dentro del plan de implementación. No debe modificarse silenciosamente la política de `.gitignore` porque actualmente documenta una decisión explícita del propietario.

## Nombre y límite del nuevo dominio

Nombre de la skill:

```text
manage-azure-resources
```

El dominio administra el plano de control de Azure, incluyendo:

- Tenants, suscripciones y Resource Groups, según los permisos reales del usuario.
- Resource Providers.
- VNets, subnets, NSG, route tables, public IPs, load balancers, Private Endpoints y Private DNS.
- Máquinas virtuales, VM Scale Sets, discos, snapshots e interfaces de red.
- App Service, Functions y Container Apps.
- Azure Container Registry.
- Storage Accounts y configuración del plano de control.
- Key Vault, Managed Identities y configuración de acceso, sin exponer secretos.
- Azure SQL, SQL Managed Instance y otros motores únicamente en el plano de infraestructura.
- Azure Monitor, Log Analytics, alertas y diagnostic settings.
- Tags, locks, Azure Policy, RBAC y gobernanza.
- Cost Management, cuotas, uso y recomendaciones de capacidad en modo de lectura.
- AKS como recurso de Azure y sus node pools cuando la solicitud sea de infraestructura Azure.
- Cualquier Resource Provider adicional mediante Azure CLI, `az resource` o ARM REST controlado.

Permanecen separados:

- Azure DevOps se administra con sus skills existentes.
- Los objetos internos de Kubernetes y Helm se administran con `manage-aks-clusters`.
- Los datos SQL continúan siendo estrictamente de solo lectura conforme a `CLAUDE.md`.
- n8n, Schema Sync y el servidor Linux mantienen sus propios dominios.

## Tipos de conexión

### 1. Azure CLI con sesión local

El usuario ejecuta manualmente:

```powershell
az login
```

La automatización reutiliza esa sesión.

Reglas obligatorias:

- Nunca ejecutar automáticamente `az login`.
- Nunca ejecutar `az logout` ni `az account clear`.
- Nunca leer ni copiar archivos internos de `%USERPROFILE%\.azure`.
- Verificar la sesión con `az account show`.
- Mostrar únicamente información sanitizada de la cuenta.
- Si la sesión expiró, detenerse y pedir al usuario que ejecute `az login` manualmente.
- Cada operación debe llevar `tenantId` y `subscriptionId` en el plan.
- Usar `--subscription <ID>` explícitamente cuando el comando lo soporte.
- Evitar depender de `az account set` o de una suscripción predeterminada implícita.
- Nunca ejecutar `az account get-access-token` con salida visible.
- Nunca usar `--debug` en comandos autenticados, porque puede producir información sensible.

### 2. MCP oficial de Azure

Agregar un servidor separado llamado:

```text
azure
```

No confundirlo con:

```text
azure-devops
```

Usar el paquete oficial:

```text
@azure/mcp
```

Durante la implementación:

1. Consultar la versión estable actual con `npm view @azure/mcp version`.
2. Fijar esa versión exacta en `.mcp.json`; no dejar `@latest` de forma permanente.
3. Ejecutarlo localmente mediante `stdio`.
4. No agregar tokens, passwords ni client secrets en `.mcp.json`.
5. Reutilizar la cadena de credenciales local que incluye la sesión de Azure CLI.
6. Después de reiniciar Claude, enumerar las herramientas reales expuestas.
7. No inventar nombres ni esquemas de herramientas MCP.
8. Validar cada tool real antes de incorporarla a los hooks.

Ejemplo conceptual; debe sustituirse `<VERSION_FIJADA>` por la versión verificada:

```json
{
  "mcpServers": {
    "azure": {
      "command": "cmd",
      "args": [
        "/c",
        "npx",
        "-y",
        "@azure/mcp@<VERSION_FIJADA>",
        "server",
        "start"
      ]
    }
  }
}
```

La integración debe conservar todos los servidores MCP existentes.

### Prioridad entre MCP y Azure CLI

Usar este orden:

1. MCP oficial para inventario, consultas, diagnóstico y operaciones de lectura que soporte correctamente.
2. Azure CLI para lecturas no disponibles en el MCP.
3. Azure Resource Graph para inventarios amplios.
4. API directa del Resource Provider como fuente final para el estado actual antes de modificar.
5. Azure CLI, Bicep/ARM o ARM REST controlado para aplicar cambios.

Por defecto, las escrituras consolidadas se ejecutan mediante Azure CLI dentro de `Apply-AzureChangePlan.ps1`. Esto permite que toda la fase no destructiva utilice una sola aprobación y un journal consistente.

Una escritura mediante MCP solo podrá habilitarse posteriormente si:

- La tool MCP real fue enumerada y clasificada.
- El plan contiene su nombre exacto.
- El input canónico y su hash están incluidos.
- Los hooks pueden comprobar que coincide exactamente con el plan aprobado.
- Existe journal y readback equivalente al ejecutor Azure CLI.

Mientras esas condiciones no estén implementadas y probadas, el MCP se utiliza para lectura y diagnóstico; las escrituras se hacen mediante el ejecutor del plan.

## Modelo de aprobaciones

### Matriz

| Operación | Aprobación |
| --- | --- |
| Lectura, lista, show, inventario | Ninguna |
| Diagnóstico y Activity Log | Ninguna |
| Azure Resource Graph | Ninguna |
| Validación, lint y sintaxis | Ninguna |
| ARM/Bicep `what-if` | Ninguna |
| Diff actual → deseado | Ninguna |
| Generar y validar el plan | Ninguna |
| Crear recursos incluidos en el plan | Cubierto por aprobación del plan |
| Modificar recursos incluidos en el plan | Cubierto por aprobación del plan |
| Acciones operativas no destructivas incluidas | Cubiertas por aprobación del plan |
| Eliminar recursos | Aprobación adicional del lote destructivo exacto |
| Salirse del plan o cambiar un target | Plan nuevo y nueva aprobación |

### Aprobación del plan principal

El plan debe ser suficientemente detallado para que una sola aprobación cubra todas las creaciones y modificaciones declaradas.

La aprobación principal debe identificar:

- Tenant.
- Suscripción.
- Resource Groups.
- Recursos actuales y deseados.
- Resource IDs exactos.
- Operaciones create/update/action.
- Comandos o deployments exactos.
- Dependencias.
- Locks y RBAC relevantes.
- Impacto y posible indisponibilidad.
- Efecto estimado en costo.
- What-if o diff.
- Estrategia de respaldo.
- Verificación posterior.
- Rollback o indicación de que no existe rollback automático.
- Política de retry y timeout.
- Hashes de plan e inventario.

Después de aprobar el plan:

- No pedir aprobación por cada recurso.
- No pedir aprobación por cada comando.
- No pedir aprobación por cada Resource Group.
- No pedir otra aprobación para readback.
- No pedir otra aprobación para retries que ya estén declarados en `retryPolicy`.
- No pedir confirmaciones textuales adicionales antes de ejecutar el Apply aprobado.

### Aprobación de eliminaciones

Las eliminaciones no quedan autorizadas solamente por aprobar el plan principal.

El plan debe incluirlas desde el inicio para poder analizar dependencias e impacto, pero el ejecutor debe separar las fases:

```text
Fase 1: create/update/action
Fase 2: readback de la fase no destructiva
Fase 3: presentar lote exacto de eliminaciones
Fase 4: aprobación destructiva
Fase 5: ejecutar eliminaciones aprobadas
Fase 6: readback final
```

La aprobación destructiva puede cubrir un lote relacionado de eliminaciones cuando todas:

- Pertenecen al mismo objetivo de cambio.
- Están en el mismo tenant y suscripción.
- Fueron enumeradas individualmente en el plan.
- Tienen resource IDs exactos.
- Tienen dependencias y recuperación analizadas.
- Tienen el mismo nivel de riesgo operativo.

No pedir una tarjeta por cada comando interno del lote.

Separar la aprobación cuando:

- Se elimina un Resource Group completo.
- Se eliminan recursos en suscripciones diferentes.
- Se elimina un lock para poder borrar.
- Se afectan datos persistentes, backups, Key Vault, identidades o RBAC crítico.
- Las eliminaciones no forman parte del mismo objetivo operativo.

Eliminar un Resource Group siempre debe ser una operación destructiva aislada. El plan debe enumerar previamente todos los recursos contenidos.

### Desviación del plan

Se considera fuera del plan si ocurre cualquiera de estos casos:

- Cambia el tenant o subscriptionId.
- Cambia el Resource Group.
- Cambia un resource ID.
- Aparece un recurso o dependencia no contemplada.
- Se necesita una operación adicional.
- Cambian los argumentos, body, template o parámetros aprobados.
- Cambia `bodyHash`, `validationHash` o `preconditionHash`.
- Existe drift desde el inventario validado.
- Se necesita quitar un lock no declarado.
- Se necesita elevar RBAC o agregar roles no declarados.
- Se necesita instalar una extensión o herramienta no incluida.
- Se necesita leer, crear o rotar un secreto no previsto.
- Una escritura termina en estado ambiguo y el readback no resuelve el resultado.

Ante una desviación:

1. Detener la ejecución antes de la operación no autorizada.
2. No improvisar ni ampliar el plan automáticamente.
3. Registrar un reporte sanitizado en `.local/azure/deviations/`.
4. Hacer readback del estado real.
5. Preparar un plan nuevo o una enmienda con nuevo hash.
6. Solicitar aprobación nuevamente.

## Estructura requerida

```text
.claude/
├── skills/manage-azure-resources/
│   ├── SKILL.md
│   ├── references/
│   │   ├── scope-and-routing.md
│   │   ├── authentication-and-context.md
│   │   ├── command-classification.md
│   │   ├── inventory-and-resource-graph.md
│   │   ├── change-plan-schema.md
│   │   ├── apply-readback-rollback.md
│   │   └── secrets-rbac-locks.md
│   └── scripts/
│       ├── Azure-Common.ps1
│       ├── Test-AzureEnvironment.ps1
│       ├── Get-AzureInventory.ps1
│       ├── Invoke-AzureRead.ps1
│       ├── Invoke-AzureWhatIf.ps1
│       ├── New-AzureChangePlan.ps1
│       ├── Test-AzureChangePlan.ps1
│       ├── Apply-AzureChangePlan.ps1
│       ├── Apply-AzureDeletePlan.ps1
│       ├── Test-AzurePostChange.ps1
│       ├── New-AzureRollbackPlan.ps1
│       └── tests/run-script-tests.ps1
├── agents/azure/
│   ├── azure-operator.md
│   ├── azure-diagnoser.md
│   └── azure-reviewer.md
├── agent-memory/
│   ├── azure-operator/
│   ├── azure-diagnoser/
│   └── azure-reviewer/
├── rules/azure/
│   ├── authorization.md
│   └── security.md
└── hooks/azure/
    ├── azure-security-gate.ps1
    ├── azure-plan-authorization.ps1
    ├── azure-delete-authorization.ps1
    ├── azure-post-validate.ps1
    ├── azure-stop-validate.ps1
    ├── azure-secret-scan-lib.ps1
    └── tests/run-hook-tests.ps1

docs/azure/AZURE-AUTOMATION-ARCHITECTURE.md

.local/azure/
├── inventory/
├── plans/
├── backups/
├── executions/
├── logs/
└── deviations/
```

Cada memoria debe incluir:

```text
MEMORY.md
debugging.md
patterns.md
```

Los tres agentes deben declarar:

```yaml
memory: project
```

## Esquema del plan Azure

Cada operación debe contener como mínimo:

```json
{
  "operationId": "string",
  "phase": "nonDestructive|destructive",
  "action": "create|update|action|delete",
  "tenantId": "string",
  "subscriptionId": "string",
  "resourceGroup": "string|null",
  "resourceId": "string",
  "resourceType": "string",
  "apiVersion": "string|null",
  "executor": "azureCli|armDeployment|armRest",
  "argv": [],
  "bodyHash": "string|null",
  "preconditionHash": "string",
  "currentState": {},
  "desiredState": {},
  "dependencies": [],
  "destructive": false,
  "reversible": true,
  "backupStrategy": "string",
  "rollbackStrategy": "string",
  "verification": [],
  "retryPolicy": {
    "maxAttempts": 1,
    "retryableCodes": [],
    "delaySeconds": 0
  },
  "timeoutSeconds": 600,
  "expectedFinalState": "string"
}
```

No almacenar comandos de shell arbitrarios. Guardar ejecutable y argumentos tokenizados para evitar sustituciones, pipes, redirecciones o inyección de comandos no aprobada.

El plan general debe contener:

- `schemaVersion`.
- `planId`.
- `createdAtUtc`.
- `ownerTranscriptId`.
- Tenant y suscripción.
- Inventarios utilizados y sus hashes.
- `approvedOperations` no destructivas.
- `pendingDeleteOperations` destructivas.
- Análisis de impacto y costo.
- `validationHash` SHA-256.
- Evidencia de what-if/diff.
- Estado de revisión independiente.

## Flujo obligatorio

### Preparación

1. Confirmar el objetivo solicitado.
2. Verificar Azure CLI y el MCP oficial.
3. Verificar `az account show` sin mostrar datos sensibles.
4. Confirmar tenant y suscripción.
5. Ejecutar inventario por MCP o Azure Resource Graph.
6. Confirmar recursos críticos directamente con su Resource Provider.
7. Consultar locks, RBAC relevante, dependencias y Activity Log.
8. Generar backup sanitizado cuando corresponda.
9. Generar Bicep/ARM what-if o diff actual → deseado.
10. Calcular impacto, indisponibilidad, costo y recuperación.
11. Generar el plan inmutable.
12. Validarlo.
13. Revisarlo con `azure-reviewer`.
14. La sesión principal presenta el plan y solicita una aprobación.

Los subagentes pueden preparar y revisar, pero la sesión principal es propietaria del plan, la aprobación y la ejecución.

### Aplicación no destructiva

Después de aprobar el plan:

1. `Apply-AzureChangePlan.ps1` valida transcript, hashes y precondiciones.
2. Ejecuta únicamente `approvedOperations`.
3. Registra cada transición en el journal bajo lock exclusivo.
4. Aplica retries solamente según `retryPolicy`.
5. Si una operación termina por timeout, realiza readback antes de reintentar.
6. Si el estado deseado ya existe, registra éxito idempotente.
7. Si el resultado continúa ambiguo, se detiene.
8. Ejecuta readback de la fase no destructiva.

No debe existir rollback automático. Un rollback siempre se prepara como plan nuevo porque también puede producir impacto.

### Aplicación destructiva

Si el plan contiene `pendingDeleteOperations`:

1. Revalidar inventario, locks y dependencias.
2. Mostrar el lote destructivo exacto.
3. Solicitar la aprobación destructiva correspondiente.
4. `Apply-AzureDeletePlan.ps1` ejecuta solamente las eliminaciones aprobadas.
5. No aceptar operaciones adicionales ni resource IDs diferentes.
6. Realizar readback y revisar Activity Log.

## Hooks

### `azure-security-gate.ps1`

Debe interceptar:

- `Bash`.
- `PowerShell`.
- Todas las tools reales `mcp__azure__.*` después de enumerarlas.

Comportamiento:

- Lecturas seguras: `allow`.
- Inventario, Resource Graph, Activity Log, what-if y validación: `allow`.
- Comando `az` mutable directo: `ask`.
- Apply no destructivo cuyo plan aprobado coincide: `allow` sin otra tarjeta.
- Apply destructivo: `ask` mediante el gate destructivo.
- Tool MCP de escritura no manifestada: `ask`.
- Tool MCP desconocida: `ask`.
- Lectura o exposición de secretos: `ask`.
- Nunca usar `deny` como respuesta general ante una operación Azure legítima.

### `azure-plan-authorization.ps1`

Debe permitir `Apply-AzureChangePlan.ps1` sin una segunda aprobación cuando:

- El último `ExitPlanMode` aprobado contiene un bloque `azure-apply-authorization`.
- El transcript coincide.
- El comando es exacto.
- Los hashes del plan e inventario coinciden.
- El plan no venció ni alcanzó estado terminal.
- No existe drift.

### `azure-delete-authorization.ps1`

Debe solicitar una tarjeta específica antes de `Apply-AzureDeletePlan.ps1`, mostrando:

- Tenant y suscripción.
- Resource Group.
- Cada resource ID.
- Dependencias.
- Locks.
- Datos o respaldos afectados.
- Recuperabilidad.
- Hash exacto del lote destructivo.

Una vez aprobado ese lote, no debe preguntar por cada comando interno.

## Journal e idempotencia

Estados permitidos:

```text
pending
in-progress
succeeded
failed-before-write
failed-after-write
ambiguous
skipped-already-desired
blocked-drift
blocked-deviation
```

Reglas:

- Lock exclusivo de archivo.
- Escritura atómica mediante archivo temporal y reemplazo.
- No repetir una operación `succeeded`.
- `failed-before-write` puede reintentarse si `retryPolicy` lo permite.
- `failed-after-write` y `ambiguous` exigen readback antes de decidir.
- Nunca volver a emitir automáticamente un DELETE ambiguo.
- El journal no modifica el plan inmutable.
- Nunca guardar secretos, tokens o bodies sensibles.

## Información sensible

Nunca imprimir ni guardar:

- Access tokens.
- Contenido del cache de Azure CLI.
- Key Vault secret values.
- Storage Account keys.
- SAS tokens.
- ACR credentials.
- Connection strings.
- Passwords.
- Certificados o claves privadas.
- Cuerpos sensibles de ARM REST.

Los secretos nuevos deben representarse mediante placeholders, por ejemplo:

```text
${AZURE_SECRET_NOMBRE}
```

El valor se resuelve únicamente dentro de un Apply aprobado y se entrega al destino sin imprimirse ni persistirse.

## Archivos locales y Git

Proponer explícitamente en el plan de implementación:

```gitignore
/env/
/.local/
*.pfx
*.pem
*.key
*kubeconfig*
```

Antes de modificar `.gitignore`, revisar si esos archivos ya están versionados. No ejecutar eliminación del índice, rotación de claves ni reescritura del historial sin una aprobación específica.

## Pruebas obligatorias

Crear pruebas offline con mocks para confirmar:

- Lecturas CLI permitidas.
- Lecturas MCP permitidas.
- What-if permitido.
- Escritura `az` directa pregunta.
- Tool MCP mutable pregunta.
- El plan aprobado permite create/update/action sin nuevas preguntas.
- Una operación no incluida se bloquea antes de ejecutarse.
- Cambio de tenant, suscripción, RG o resource ID se bloquea.
- Cambio de argumentos, body o hashes se bloquea.
- Drift se bloquea.
- Retry declarado continúa sin nueva aprobación.
- Retry no declarado se detiene.
- Timeout ambiguo hace readback.
- El plan principal no ejecuta deletes.
- El Apply destructivo siempre solicita aprobación.
- El lote destructivo aprobado no pregunta comando por comando.
- DELETE ambiguo no se repite.
- Eliminación de Resource Group queda aislada.
- Secretos no aparecen en planes, journals ni logs.
- Los hooks de los otros dominios continúan funcionando.
- Cero llamadas reales a Azure durante las pruebas.

## Verificaciones reales permitidas durante la implementación

Únicamente lectura:

- `az version`.
- `az account show` sanitizado.
- `az account list` sanitizado.
- Listar tenants y suscripciones visibles.
- Listar Resource Groups.
- Verificar Azure Resource Graph.
- Conectar el MCP y enumerar sus herramientas.
- Ejecutar al menos una consulta MCP segura de solo lectura.
- Consultar locks y Activity Log en modo lectura.

No crear, modificar ni eliminar recursos Azure mientras se implementa la estructura.

## Entrega final de la implementación

Entregar:

1. Archivos creados y modificados.
2. Integraciones existentes preservadas.
3. Versión exacta fijada de `@azure/mcp`.
4. Resultado de conexión por Azure CLI.
5. Resultado de conexión por MCP.
6. Tools MCP reales enumeradas y clasificadas.
7. Tenant y suscripción sanitizados.
8. Resultado exacto de pruebas PASS/FAIL.
9. Demostración mock del plan principal con create/update.
10. Demostración mock del gate destructivo.
11. Confirmación de cero cambios reales en Azure.
12. Riesgos pendientes de `.gitignore` y archivos sensibles.
13. Confirmación de que no hubo commit ni push.

No declarar que el dominio funciona si no se comprobaron las dos conexiones, los hooks, la aprobación única del plan no destructivo y la aprobación separada del lote destructivo.

## Fuentes oficiales

- Azure MCP Server: <https://learn.microsoft.com/en-us/azure/developer/azure-mcp-server/overview>
- Autenticación del Azure MCP Server: <https://learn.microsoft.com/en-us/azure/developer/azure-mcp-server/how-to/github-copilot-cli>
- Azure CLI interactivo: <https://learn.microsoft.com/en-us/cli/azure/authenticate-azure-cli-interactively>
- Administrar recursos con Azure CLI: <https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/manage-resources-cli>
- Azure Resource Graph: <https://learn.microsoft.com/en-us/azure/governance/resource-graph/>
- ARM/Bicep what-if: <https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/deploy-what-if>
- Azure Activity Log: <https://learn.microsoft.com/en-us/azure/azure-monitor/platform/activity-log>
- Resource locks: <https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/lock-resources>
- Eliminación de Resource Groups: <https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/delete-resource-group>
