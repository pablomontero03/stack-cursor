# Implementación del dominio de automatización Cloudflare

## Instrucción principal

Implementa completamente el dominio de administración de Cloudflare dentro de:

`D:\Proyectos\automation`

La implementación debe permitir inventariar, analizar, diagnosticar, crear y modificar recursos Cloudflare con el mínimo de aprobaciones, manteniendo trazabilidad y protección contra cambios accidentales.

Toda eliminación debe requerir una aprobación destructiva independiente. Una aprobación anterior de creación o modificación nunca autoriza eliminaciones.

No realices durante la construcción de este dominio ningún cambio real en Cloudflare. Solo se permiten pruebas offline y comprobaciones reales de lectura después de que la estructura esté implementada.

## Principios de integración

La implementación debe ser aditiva y conservar íntegramente todo lo que ya funciona para Azure, Azure FinOps, AKS, Azure DevOps, n8n, Schema Sync, SSH y cualquier otro dominio existente.

Antes de editar:

1. Lee `CLAUDE.md` y todas las reglas aplicables.
2. Inspecciona la estructura real de `.claude`, `.mcp.json`, `.gitignore`, `docs` y `.local`.
3. Identifica las convenciones existentes para skills, agentes, memorias, hooks, scripts, planes, hashes, journals, readback y rollback.
4. Comprueba qué archivos Cloudflare existen y si están vacíos, incompletos o activos.
5. Presenta un plan exacto de archivos que crearás o modificarás.
6. Indica cómo preservarás cada integración existente.
7. No modifiques nada hasta que el usuario apruebe el plan de implementación.

Después de aprobar ese plan, realiza todas las ediciones, pruebas offline y validaciones de lectura incluidas sin volver a pedir aprobación. Detente solamente si necesitas:

- Salirte del plan aprobado.
- Modificar otro dominio de manera no prevista.
- Revelar o trasladar secretos.
- Ejecutar una escritura real en Cloudflare.
- Eliminar archivos o configuración existente del proyecto.
- Instalar software o dependencias no incluidas en el plan.

No hagas commit, push, publicación ni despliegue salvo solicitud explícita.

## Objetivo funcional

El dominio debe poder trabajar, sin quedar limitado a una lista cerrada, con:

- Cuentas, miembros, roles y zonas.
- Dominios y configuración de zona.
- DNS, registros, DNSSEC y analytics.
- Proxy de Cloudflare y configuración de origen.
- SSL/TLS, certificados, Origin CA y mTLS.
- WAF, reglas administradas y personalizadas.
- Rate limiting, DDoS, Bot Management y reglas de seguridad.
- Redirect Rules, Transform Rules, Page Rules y Rulesets.
- Cache, Cache Rules, Tiered Cache y purgas.
- Workers, rutas, custom domains, versiones, secrets y bindings.
- Pages, deployments, dominios y configuración.
- KV, R2, D1, Queues, Durable Objects, Vectorize y Workflows.
- Load Balancing, pools, health monitors y steering.
- Zero Trust, Access, Gateway, WARP y posture checks.
- Cloudflare Tunnels y sus rutas.
- Logpush, audit logs, observabilidad y GraphQL Analytics.
- Notifications, webhooks y alertas.
- API Tokens y permisos, únicamente mediante flujos expresamente autorizados.
- Terraform y Wrangler cuando sean la herramienta correcta.
- Cualquier producto nuevo disponible en la API oficial, después de descubrir y validar su esquema.

Una operación desconocida no debe quedar prohibida permanentemente. Debe clasificarse como `ask` hasta que sea analizada e incorporada de forma segura.

## Arquitectura requerida

Adapta nombres y ubicaciones a las convenciones reales del proyecto. No crees una arquitectura paralela si ya existe un patrón equivalente.

Estructura recomendada:

```text
.claude/
├── skills/
│   └── manage-cloudflare/
│       ├── SKILL.md
│       ├── references/
│       │   ├── connections-and-authentication.md
│       │   ├── api-and-mcp.md
│       │   ├── resource-classification.md
│       │   ├── change-workflow.md
│       │   ├── deletion-workflow.md
│       │   ├── dns-and-certificates.md
│       │   ├── security-and-zero-trust.md
│       │   ├── workers-and-storage.md
│       │   └── backup-and-rollback.md
│       └── scripts/
│           ├── Test-CloudflareEnvironment.ps1
│           ├── Invoke-CloudflareRead.ps1
│           ├── Get-CloudflareInventory.ps1
│           ├── New-CloudflareChangePlan.ps1
│           ├── Test-CloudflareChangePlan.ps1
│           ├── Apply-CloudflareChangePlan.ps1
│           ├── New-CloudflareDeletePlan.ps1
│           ├── Test-CloudflareDeletePlan.ps1
│           ├── Apply-CloudflareDeletePlan.ps1
│           ├── Test-CloudflarePostChange.ps1
│           ├── Invoke-CloudflareRollback.ps1
│           └── tests/
│               └── run-script-tests.ps1
├── agents/
│   └── cloudflare/
│       ├── cloudflare-operator.md
│       ├── cloudflare-diagnoser.md
│       └── cloudflare-reviewer.md
├── agent-memory/
│   ├── cloudflare-operator/
│   │   ├── MEMORY.md
│   │   ├── patterns.md
│   │   └── debugging.md
│   ├── cloudflare-diagnoser/
│   │   ├── MEMORY.md
│   │   ├── patterns.md
│   │   └── debugging.md
│   └── cloudflare-reviewer/
│       ├── MEMORY.md
│       ├── patterns.md
│       └── debugging.md
├── rules/
│   └── cloudflare/
│       ├── authorization.md
│       └── security.md
└── hooks/
    └── cloudflare/
        ├── cloudflare-security-gate.ps1
        ├── cloudflare-post-validate.ps1
        ├── cloudflare-stop-validate.ps1
        └── tests/
            └── run-hook-tests.ps1

docs/
└── cloudflare/
    └── CLOUDFLARE-AUTOMATION-ARCHITECTURE.md

.local/
└── cloudflare/
    ├── inventory/
    ├── plans/
    ├── delete-plans/
    ├── backups/
    ├── executions/
    ├── reports/
    └── logs/
```

Agregar `/.local/cloudflare/` a `.gitignore` sin eliminar exclusiones existentes.

Los archivos versionados pueden contener esquemas, plantillas sanitizadas y documentación. Inventarios reales, respaldos, planes, respuestas API, journals y reportes operativos deben permanecer en `.local/cloudflare/`.

## Conexiones

Implementa dos vías complementarias:

### 1. MCP oficial de Cloudflare

Agregar de forma aditiva a `.mcp.json`:

```json
{
  "mcpServers": {
    "cloudflare-api": {
      "type": "http",
      "url": "https://mcp.cloudflare.com/mcp"
    }
  }
}
```

Conservar todos los servidores MCP existentes. Si `enabledMcpjsonServers` está configurado, agregar `cloudflare-api` sin quitar los demás.

El servidor oficial utiliza OAuth. Al conectar, el cliente debe abrir la autorización de Cloudflare para que el usuario seleccione cuenta y permisos. No crear una aplicación OAuth propia: no es necesaria para conectarse al MCP oficial.

Usar Streamable HTTP en `/mcp`. No configurar URLs históricas `/sse` ni desplegar un MCP propio salvo que el usuario lo solicite en otro plan.

Después de configurar:

1. Reiniciar o recargar Claude Code.
2. Confirmar que `cloudflare-api` aparece conectado.
3. Enumerar los nombres y esquemas reales de las herramientas expuestas.
4. Verificar `docs`, `search` y `execute` si son las herramientas vigentes.
5. Realizar únicamente una consulta real de lectura.

No inventar nombres de herramientas antes del handshake.

### 2. API oficial de Cloudflare

La API REST será la vía determinista para aplicar planes de cambios y eliminaciones. Puede usarse también como fallback de lectura cuando el MCP no cubra una necesidad.

Autenticación permitida:

- Variable de entorno `CLOUDFLARE_API_TOKEN`.
- PowerShell SecretStore.
- Windows Credential Manager.
- Otro almacén local seguro ya establecido en el proyecto.

No usar Global API Key. No guardar el token en `.mcp.json`, `settings.json`, `CLAUDE.md`, Git, planes, logs, memorias, documentación ni argumentos visibles del proceso.

El helper debe leer el token internamente, agregar `Authorization: Bearer ...`, no imprimirlo y eliminarlo de errores sanitizados. Nunca devolver el header `Authorization` a Claude.

Usar API Tokens con privilegios mínimos y limitar por cuenta, zona, recursos y vigencia cuando sea posible. Si faltan permisos, reportar la operación y el permiso exactos; no ampliar el token automáticamente.

La conexión MCP por OAuth y la API por token son independientes. El fallo de una no debe provocar que se copien credenciales de la otra.

## Prioridad de herramientas

Usar en este orden:

1. MCP oficial para documentación, descubrimiento y lecturas compatibles.
2. API REST oficial para inventarios deterministas y todas las aplicaciones de planes.
3. GraphQL Analytics para estadísticas de lectura.
4. Terraform para infraestructura declarativa y versionable cuando el repositorio ya lo use o el usuario lo solicite.
5. Wrangler para Workers/Pages y productos compatibles cuando aporte validación o despliegue reproducible.

No usar REST, Terraform o Wrangler para eludir una decisión de seguridad del MCP o de un hook.

## Modelo de aprobación mínimo y seguro

### Lecturas sin aprobación

Permitir automáticamente:

- Documentación y búsqueda de endpoints.
- HTTP `GET` y `HEAD` contra `api.cloudflare.com` con scope explícito.
- GraphQL `POST` únicamente para consultas analíticas sin mutaciones.
- Listar cuentas, zonas, DNS, rulesets, Workers, Pages, almacenamiento, Tunnels, Access, Gateway, balances y configuración.
- Leer analytics, audit logs, logs sanitizados, health y estado.
- Inventarios, comparaciones, diagnósticos y readback.
- Exportar localmente inventarios y respaldos sanitizados a `.local/cloudflare/`.
- `terraform plan`, `terraform validate`, `terraform fmt -check` y `terraform show` sin apply.
- `wrangler` en operaciones demostrablemente de lectura o validación local.
- Dry-runs y simulaciones que no escriban en Cloudflare.

Los nombres de secrets, variables y bindings pueden inventariarse. Leer valores secretos, descargar material criptográfico o mostrar tokens requiere aprobación explícita y debe evitarse si no es indispensable.

### Una aprobación para crear o modificar

Todas las creaciones y modificaciones no destructivas deben agruparse en un plan inmutable. El usuario aprueba una sola vez el plan completo.

Después de esa aprobación, `Apply-CloudflareChangePlan.ps1` puede ejecutar todas las operaciones exactas incluidas sin preguntas internas adicionales, siempre que:

- El plan, su hash y su vigencia sigan válidos.
- Cuenta, zona, recurso, método, URI y body coincidan.
- Las precondiciones y el estado previo no hayan cambiado.
- No exista ninguna eliminación explícita o lógica.
- No se amplíe el alcance.

Si una condición falla, detenerse. No adaptar silenciosamente el plan ni ejecutar parcialmente operaciones dependientes.

### Aprobación obligatoria para toda eliminación

Cada eliminación requiere un plan destructivo independiente y una nueva aprobación. La aprobación general del plan de cambios nunca la cubre.

Para minimizar preguntas, una sola aprobación destructiva puede cubrir un lote atómico de eliminaciones relacionadas, pero cada elemento debe aparecer individualmente con tipo, ID, nombre, cuenta, zona, dependencias e impacto. No se permite agregar elementos después de aprobar.

Se considera eliminación:

- Cualquier HTTP `DELETE`.
- Borrar zonas, dominios o registros DNS.
- Eliminar Rulesets, reglas WAF, Access policies o Gateway rules.
- Eliminar Workers, rutas, Pages projects o deployments.
- Eliminar KV namespaces/keys, R2 buckets/objects, D1 databases, Queues o datos.
- Eliminar Tunnels, rutas, certificados, load balancers, pools o monitors.
- `terraform destroy` o un `terraform apply` cuyo plan destruya recursos.
- `wrangler delete` y comandos equivalentes.
- Purga de cache, porque elimina contenido almacenado.
- Reemplazar una colección omitiendo elementos existentes.
- Actualizar un Ruleset, política, lista o configuración de manera que desaparezcan entradas.
- Desvincular un custom domain, route, binding, hostname o integración.
- Revocar tokens, certificados, credenciales o accesos.
- Cualquier acción irreversible o con pérdida de datos, aunque utilice `POST`, `PUT` o `PATCH`.

El gate debe clasificar eliminaciones lógicas por el efecto de la operación, no solamente por el verbo HTTP.

## MCP Code Mode y seguridad

El MCP oficial puede exponer `search` y `execute`, donde `execute` recibe código que llama endpoints de Cloudflare. No permitir globalmente cualquier `execute`.

Clasificación:

- `docs`: lectura permitida.
- `search`: lectura permitida.
- `execute` que solo realiza `GET` o `HEAD` a endpoints permitidos: lectura permitida.
- `execute` con GraphQL: permitido únicamente si contiene una operación `query`, sin `mutation` y con variables sanitizadas.
- `execute` con `POST`, `PUT`, `PATCH`, `DELETE`, método dinámico, URI dinámica o código no clasificable: `ask`.
- `execute` con acceso a secrets, token, headers o credenciales: `ask`.

Las escrituras planificadas deben ejecutarse preferentemente mediante el aplicador REST determinista, no mediante código MCP abierto. Esto permite una sola aprobación y verificación exacta por hash.

Un cambio pequeño directo mediante MCP sigue siendo posible, pero debe pedir aprobación mostrando cuenta, zona, método, endpoint, recurso e impacto, y después hacer readback. No debe considerarse aprobado permanentemente.

## Plan de cambios

`New-CloudflareChangePlan.ps1` debe producir JSON canónico, sin secretos, que incluya como mínimo:

- `schemaVersion`.
- `planId`.
- `createdAtUtc` y `expiresAtUtc`.
- `connectionMode`.
- `accountId`.
- `zoneIds` aplicables.
- Objetivo y alcance.
- Inventario base y `preStateHash`.
- Estado actual y estado deseado.
- Operaciones ordenadas.
- Dependencias entre operaciones.
- Riesgo, impacto y posible indisponibilidad.
- Estrategia de respaldo.
- Verificación posterior.
- Estrategia de rollback.
- `validationHash` del plan completo.

Cada operación debe incluir:

- `operationId` único.
- Tipo de operación.
- Método HTTP exacto o comando exacto.
- URI exacta.
- `accountId` y `zoneId` explícitos.
- Tipo, ID y nombre del recurso.
- Body sanitizado.
- `bodyHash`.
- Precondiciones.
- Resultado esperado.
- Readback esperado.
- Indicador `isDestructive=false`.

El plan normal debe rechazar cualquier operación destructiva. No basta con marcarla como no destructiva: debe verificar método y efecto.

## Flujo de creación y modificación

1. Confirmar cuenta, zona y objetivo.
2. Hacer inventario de lectura.
3. Consultar documentación y esquema actuales.
4. Verificar permisos sin exponer credenciales.
5. Guardar respaldo sanitizado.
6. Calcular `preStateHash`.
7. Preparar el cambio y sus dependencias.
8. Ejecutar validaciones o plan de Terraform si corresponde.
9. Generar el plan inmutable.
10. Ejecutar `Test-CloudflareChangePlan.ps1`.
11. Pasar el plan al `cloudflare-reviewer`.
12. Presentar una sola aprobación con resumen completo.
13. Ejecutar `Apply-CloudflareChangePlan.ps1` después de aprobar.
14. Releer cada recurso inmediatamente antes de escribir y comprobar drift.
15. Ejecutar solo operaciones declaradas.
16. Registrar journal sanitizado.
17. Hacer readback, pruebas funcionales seguras y comparación final.

Si existe drift, no sobrescribir. Regenerar inventario, diff y plan; solicitar una nueva aprobación.

No realizar rollback automático. Preparar el rollback y solicitar aprobación, porque un rollback también modifica recursos y puede introducir una interrupción.

## Flujo de eliminación

1. Identificar exactamente cuenta, zona, tipo, nombre e ID.
2. Detectar dependencias y consumidores.
3. Determinar si contiene datos, configuración, tráfico o credenciales.
4. Crear un respaldo suficiente y comprobar que sea legible.
5. Explicar impacto, indisponibilidad y recuperación real.
6. Generar un delete plan separado con `isDestructive=true`.
7. Validarlo y revisarlo de forma independiente.
8. Presentar una aprobación destructiva separada.
9. Releer el recurso y validar drift inmediatamente antes de eliminar.
10. Ejecutar únicamente el lote exacto aprobado.
11. Registrar el resultado y hacer readback.

El delete plan debe incluir `deletePlanId`, `validationHash`, operaciones exactas, dependencias, orden, respaldo, recuperación y confirmación de que no contiene recursos adicionales.

Nunca usar selectores amplios, comodines, `all`, listas obtenidas después de la aprobación ni paginación cuyo resultado no quedó materializado dentro del plan aprobado.

## Respaldos y rollback

Antes de modificar o eliminar, conservar cuando sea posible:

- Registros DNS y configuración de zona.
- Rulesets completos, orden, fases y expresiones.
- Configuración SSL/TLS y certificados sin claves privadas.
- Worker script, versión, rutas, bindings y nombres de secrets.
- Configuración de Pages y dominios.
- Configuración de Access, Gateway y Tunnels.
- Configuración de balanceadores, pools y health monitors.
- Metadatos y configuración de KV, R2, D1 y Queues.

No descargar por defecto datos completos de R2, KV o D1. Si una eliminación afecta datos, indicar si existe backup real; si no existe, advertir que la recuperación puede ser imposible.

Nunca guardar valores de Worker secrets, tokens, claves privadas, Origin CA private keys ni credenciales dentro del respaldo.

## Agentes

### `cloudflare-operator`

Responsable de inventarios, preparación de planes y ejecución aprobada mediante los aplicadores. No aprueba sus propios cambios.

### `cloudflare-diagnoser`

Responsable de DNS, propagación, TLS, WAF, cache, Workers, Pages, Zero Trust, Tunnels, balanceadores, logs, analytics y errores API. Opera en lectura por defecto. Las correcciones se transfieren al flujo de plan.

### `cloudflare-reviewer`

Responsable de revisar scope, cuenta, zona, drift, dependencias, impacto, backups, eliminación lógica, rollback y readback. Puede rechazar técnicamente un plan, pero la aprobación final siempre corresponde al usuario.

Los tres agentes deben usar `memory: project` si esa es la convención existente. Sus memorias solo contienen aprendizajes reutilizables y sanitizados; nunca inventarios reales completos, tokens, headers, secrets, IDs sensibles o cuerpos de respuestas privadas.

## Hook de seguridad

`cloudflare-security-gate.ps1` debe interceptar como mínimo:

- Bash.
- PowerShell.
- Herramientas reales del MCP `cloudflare-api` después del handshake.
- `curl`, `Invoke-RestMethod`, `Invoke-WebRequest` y SDKs dirigidos a Cloudflare.
- Terraform y Wrangler cuando afecten Cloudflare.
- Aplicadores Cloudflare.

Comportamiento:

- Lectura demostrable: permitir.
- Simulación o validación sin escritura: permitir.
- Aplicador de plan normal válido: una decisión `ask` para todo el plan.
- Escritura directa: `ask`.
- Eliminación explícita o lógica: `ask` destructivo separado.
- Lectura o exposición de secretos: `ask`.
- Operación desconocida: `ask`.
- Nunca usar `deny` como política general para una operación legítima y clasificable.

El hook debe reconocer comandos compuestos, comillas, aliases, variables, métodos en distinto orden, PowerShell, Bash, URLs codificadas y cuerpos cargados desde archivo. Si no puede determinar el método, endpoint o efecto, debe preguntar.

Los hooks `PostToolUse` no sustituyen la aprobación previa. El hook `Stop` debe comprobar operaciones pendientes, readback y fallos no reportados, sin ejecutar correcciones automáticamente.

## Journal y protección contra repetición

Registrar en `.local/cloudflare/executions/`:

- Plan ID y hash.
- Hora de aprobación y ejecución.
- Cuenta y zonas.
- Operation IDs.
- Método y URI sanitizados.
- Body hash, nunca el token.
- Estado anterior y posterior por hash.
- Resultado y readback.
- Operaciones omitidas o fallidas.

Una operación ya completada no puede repetirse al reejecutar el mismo plan. Las escrituras no deben reintentarse a ciegas después de timeout. Primero consultar si el estado deseado ya quedó aplicado.

## Pruebas obligatorias

Usar mocks, fixtures sanitizados y endpoints falsos. Cero escrituras reales durante las pruebas.

Validar al menos:

- Lecturas REST `GET`/`HEAD` permitidas.
- MCP `docs` y `search` permitidos.
- MCP `execute` con GET permitido.
- GraphQL `query` permitido.
- GraphQL `mutation` pregunta.
- POST, PUT y PATCH directos preguntan.
- DELETE siempre pregunta de forma destructiva.
- Purge cache se clasifica como eliminación.
- Reemplazo de Ruleset que remueve reglas se clasifica como eliminación lógica.
- Terraform plan permitido.
- Terraform apply pregunta.
- Terraform destroy pregunta de forma destructiva.
- Wrangler de lectura permitido.
- Wrangler deploy pregunta.
- Wrangler delete pregunta de forma destructiva.
- Plan normal rechaza operaciones destructivas.
- Delete plan acepta únicamente inventario materializado y exacto.
- Hash alterado bloquea la aplicación.
- Cuenta o zona distinta bloquea la aplicación.
- Drift bloquea la aplicación.
- Repetición de operación completada queda bloqueada.
- Paginación no agrega recursos después de aprobar.
- 401, 403, 409, 429 y 5xx se sanitizan.
- Token y Authorization nunca aparecen en salida, errores, planes o journal.
- Los hooks y MCP existentes de otros dominios continúan funcionando.

## Verificación real permitida al finalizar

Después de que todas las pruebas offline pasen, realizar únicamente:

1. Handshake del MCP oficial.
2. Confirmación del usuario en OAuth si el cliente la solicita.
3. Enumeración de tools reales.
4. Lista de cuentas accesibles.
5. Lista de zonas y su estado.
6. Lectura de unos pocos registros DNS sin valores secretos.
7. Una consulta de audit logs o analytics si los permisos y el plan contratado lo permiten.
8. Verificación de acceso API de solo lectura, si `CLOUDFLARE_API_TOKEN` ya existe.

No crear registros DNS de prueba, Workers, KV, reglas ni otros recursos para verificar la conexión.

## Validación final de la implementación

Entregar:

1. Archivos creados y modificados.
2. Integraciones existentes preservadas.
3. Configuración MCP agregada, sin secretos.
4. Método de autenticación utilizado.
5. Cuenta y zonas detectadas, sin información sensible.
6. Herramientas MCP reales enumeradas.
7. Resultado de la API de lectura.
8. Cantidad exacta de pruebas PASS y FAIL.
9. Ejemplos simulados de un change plan y un delete plan.
10. Confirmación de cero escrituras y cero eliminaciones reales.
11. Permisos faltantes detectados.
12. Pendientes antes del primer cambio real.
13. Confirmación de que no hubo commit ni push.

No declarar que el dominio funciona si no se comprobó el handshake MCP y al menos una consulta segura de lectura.

## Referencias oficiales que deben quedar documentadas

- MCP oficial: `https://mcp.cloudflare.com/mcp`
- Servidores MCP de Cloudflare: `https://developers.cloudflare.com/agents/model-context-protocol/cloudflare/servers-for-cloudflare/`
- Repositorio MCP: `https://github.com/cloudflare/mcp`
- API oficial: `https://developers.cloudflare.com/api/`
- Skills oficiales: `https://github.com/cloudflare/skills`
- Terraform Provider: `https://developers.cloudflare.com/terraform/`

No copies manuales completos dentro de la skill. Conserva únicamente decisiones locales, flujos, esquemas y referencias necesarias; consulta la documentación oficial actual cuando una operación lo requiera.
