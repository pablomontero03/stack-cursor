# Instrucciones para Claude Code — Azure DevOps Pipelines

> **⚠️ Documento histórico (era Claude Code, 2026-08).** Las rutas, nombres de
> herramientas y estructura de directorios corresponden al entorno Claude Code
> anterior (`D:\Proyectos\`, `.claude/skills/`, `.claude/rules/`). En Kiro, las
> rutas equivalentes son `.cursor/skills/`, `.cursor/rules/` y `.cursor/agents/`.
> Preservado como referencia de las decisiones de diseño originales del dominio.

## Objetivo

Incorporar al proyecto `D:\Proyectos\automation` una estructura profesional para consultar, crear, revisar, ejecutar y diagnosticar pipelines de Azure DevOps, con foco inicial en pipelines clásicos de aplicaciones hacia AKS y pipelines clásicos de bases de datos DACPAC/SSDT.

La organización de referencia es `Shared-Service-GM` y el proyecto principal de pipelines es `DevOps`.

La conexión debe utilizar el MCP oficial de Microsoft para Azure DevOps y un PAT almacenado únicamente como variable de entorno del usuario. No guardar el PAT en el proyecto, en `.mcp.json`, en documentación, en memorias, en logs ni en archivos `token.txt`.

## Alcance autorizado en esta tarea

En esta primera tarea sí se autoriza:

1. Leer la estructura actual del proyecto.
2. Crear o modificar archivos locales de configuración, skills, agentes, memorias, reglas, hooks, pruebas, scripts y documentación.
3. Agregar el MCP oficial de Azure DevOps a `.mcp.json` sin alterar las conexiones n8n existentes.
4. Instalar o descargar el paquete oficial `@azure-devops/mcp` mediante `npx` si es necesario.
5. Verificar la conexión mediante consultas de solo lectura.
6. Consultar de forma segura proyectos, repositorios, ramas, definiciones, task groups, Variable Groups, colas y service connections para construir un inventario sanitizado.

En esta tarea no se autoriza todavía:

- Crear, modificar o eliminar recursos reales en Azure DevOps.
- Crear todavía un Build, Release o Variable Group real.
- Ejecutar o reintentar pipelines.
- Crear un Release o desplegar a Dev, UAT o Producción.
- Aprobar despliegues.
- Ejecutar un DACPAC o escribir en SQL.
- Modificar task groups, service connections, agent pools, permisos o políticas.
- Hacer commit o push.

El objetivo inmediato es dejar preparada y validada toda la plataforma de automatización. La creación de un pipeline real se hará después con los datos exactos de la aplicación y una aprobación explícita.

## Decisión técnica obligatoria: MCP más REST controlado

Usar un diseño híbrido:

1. Usar el MCP oficial `@azure-devops/mcp` como primera opción para inventario, consultas, builds, logs, artefactos y operaciones que exponga realmente.
2. El toolset oficial actual permite consultar pipelines, ejecutar pipelines y crear pipelines YAML, pero no expone todas las operaciones necesarias para crear de punta a punta un pipeline clásico: Variable Group, Build clásico y Release clásico.
3. Para esas brechas de pipelines clásicos, usar exclusivamente scripts PowerShell deterministas que llamen las APIs REST oficiales de Azure DevOps.
4. No utilizar REST como forma de evadir una llamada MCP rechazada o denegada. REST está permitido únicamente cuando la capacidad clásica no existe en el MCP oficial.
5. Toda escritura REST debe pasar por un plan validado, un modo dry-run y una aprobación explícita.

## 1. Inspección inicial obligatoria

Antes de editar:

1. Leer completos:
   - `CLAUDE.md`
   - `.mcp.json`
   - `.claude/settings.json`
   - `.claude/settings.local.json`
   - `.gitignore`
   - `.cursor/rules/global.mdc` (sección de memoria de agentes)
2. Inventariar las carpetas actuales dentro de `.claude/` y `docs/`.
3. Preservar Schema Sync, n8n, AKS y el dominio del servidor SSH.
4. No reemplazar archivos completos si basta con integrarlos.
5. No crear otra copia de `skill-creator`. Si existe una copia local innecesaria bajo `.claude/skills/skill-creator/`, reportarla, pero no eliminarla salvo que la tarea actual ya incluya una autorización previa para hacerlo.

## 2. Revisar las tres guías suministradas

Leer completamente y conservar como referencias operativas:

- `ado-classic-from-scratch.md`
- `ado-classic-playbook-any-project.md`
- `devops-guide.md`

Usar esta prioridad cuando exista contradicción:

1. La solicitud explícita del usuario y el plan aprobado de la operación actual.
2. `ado-classic-from-scratch.md` para creación nueva sin clonar definiciones.
3. `ado-classic-playbook-any-project.md` para decisiones genéricas.
4. `devops-guide.md` para datos específicos y patrones Buklo.
5. Inventario en vivo de Azure DevOps como confirmación final de IDs, nombres y revisiones.

No asumir que los IDs o nombres documentados siguen vigentes. Verificarlos en modo lectura antes de preparar un plan.

### Correcciones de interpretación obligatorias

- La guía principal indica crear desde cero, mientras el playbook incluye ejemplos de clonado. El modo predeterminado de esta skill será **desde cero**. Solo clonar si el usuario lo solicita explícitamente y el origen pertenece a la misma familia.
- No mezclar las familias AKS y DACPAC/SSDT.
- Hay referencias al cluster `gmon-prod-aks-eastus2-0001` y otras al `gmon-prod-aks-eastus2-0004`. No elegir por memoria: consultar el destino real y pedir confirmación si hay discrepancia.
- `base64` no cifra secretos. Nunca guardar secretos reales dentro de YAML, referencias, planes o memoria. Usar placeholders y preferir Variable Groups secretos, Key Vault o el mecanismo seguro vigente de la organización.
- Dev y UAT no deben crearse con valores residuales o placeholders de otro producto. Crear únicamente los ambientes cuyos valores hayan sido entregados y validados.
- Se puede preparar una definición de Release DACPAC, pero ejecutarla en modo `Apply` constituye una escritura a SQL y requiere una autorización posterior, específica y de alto riesgo.

## 3. Configurar el MCP oficial de Microsoft

Claude Code se ejecuta en Windows nativo. Utilizar el servidor local `stdio`, porque el MCP remoto de Azure DevOps todavía no admite el flujo de autenticación de Microsoft Entra requerido por Claude Code.

Primero consultar la versión estable publicada:

```powershell
npm view @azure-devops/mcp version
```

Fijar en `.mcp.json` la versión estable obtenida para evitar que un cambio de nombres de tools rompa reglas y permisos. No utilizar `@next`.

Integrar este servidor dentro del objeto `mcpServers` ya existente, conservando `n8n-interno` y `n8n-productivo`:

```json
"azure-devops": {
  "type": "stdio",
  "command": "cmd",
  "args": [
    "/c",
    "npx",
    "-y",
    "@azure-devops/mcp@VERSION_ESTABLE_VERIFICADA",
    "Shared-Service-GM",
    "--authentication",
    "envvar",
    "-d",
    "core",
    "repositories",
    "pipelines",
    "work-items"
  ],
  "env": {
    "ADO_MCP_AUTH_TOKEN": "${AZURE_DEVOPS_PAT}",
    "ado_mcp_project": "DevOps"
  }
}
```

Sustituir `VERSION_ESTABLE_VERIFICADA` por la versión real obtenida. No dejar el placeholder.

No guardar el PAT literal. El usuario lo establecerá en PowerShell con:

```powershell
setx AZURE_DEVOPS_PAT "<PAT>"
```

Recordar que `setx` solo afecta terminales nuevas. La comprobación segura es:

```powershell
[bool][Environment]::GetEnvironmentVariable("AZURE_DEVOPS_PAT", "User")
```

Debe devolver `True`. Nunca ejecutar un comando que imprima el valor.

Si se necesita cargarlo en una terminal nueva antes de iniciar Claude:

```powershell
$env:AZURE_DEVOPS_PAT = [Environment]::GetEnvironmentVariable("AZURE_DEVOPS_PAT", "User")
```

### Scopes recomendados para el PAT

No pedir `Full access`. Solicitar únicamente los scopes requeridos por las operaciones previstas:

- Project and Team: lectura.
- Code: lectura.
- Build: lectura y ejecución/administración necesaria para definiciones.
- Release: lectura, escritura, ejecución y administración.
- Variable Groups: lectura, creación y administración.
- Task Groups: lectura.
- Service Connections: lectura/consulta y uso, sin administración salvo solicitud futura.
- Agent Pools: lectura.
- Work Items: lectura si los task groups relacionan builds con requerimientos.

Los permisos efectivos nunca superan los permisos de la cuenta que creó el PAT.

## 4. Estructura que se debe crear

Crear exactamente esta estructura, adaptando únicamente nombres si ya existe un dominio equivalente:

```text
.claude/
├── skills/
│   └── manage-azure-devops-pipelines/
│       ├── SKILL.md
│       ├── references/
│       │   ├── ado-classic-from-scratch.md
│       │   ├── ado-classic-playbook-any-project.md
│       │   ├── devops-guide.md
│       │   ├── ado-api-map.md
│       │   └── approval-matrix.md
│       ├── scripts/
│       │   ├── Invoke-AdoRest.ps1
│       │   ├── Test-AdoEnvironment.ps1
│       │   ├── Export-AdoClassicInventory.ps1
│       │   ├── New-AdoClassicAksPlan.ps1
│       │   ├── New-AdoClassicDatabasePlan.ps1
│       │   ├── Test-AdoClassicPlan.ps1
│       │   ├── Invoke-AdoClassicPlan.ps1
│       │   ├── Apply-AdoClassicPlan.ps1
│       │   └── Test-AdoCreatedResources.ps1
│       └── assets/
│           ├── classic-aks-plan.example.json
│           └── classic-dacpac-plan.example.json
├── agents/
│   └── azure-devops/
│       ├── ado-pipeline-builder.md
│       ├── ado-pipeline-diagnoser.md
│       └── ado-pipeline-reviewer.md
├── agent-memory/
│   ├── ado-pipeline-builder/
│   │   ├── MEMORY.md
│   │   ├── debugging.md
│   │   └── patterns.md
│   ├── ado-pipeline-diagnoser/
│   │   ├── MEMORY.md
│   │   ├── debugging.md
│   │   └── patterns.md
│   └── ado-pipeline-reviewer/
│       ├── MEMORY.md
│       ├── debugging.md
│       └── patterns.md
├── rules/
│   └── azure-devops-pipelines/
│       ├── authorization.md
│       └── security.md
└── hooks/
    └── azure-devops-pipelines/
        ├── ado-security-gate.ps1
        ├── ado-post-validate.ps1
        ├── ado-stop-validate.ps1
        └── tests/
            ├── README.md
            └── run-hook-tests.ps1

docs/
└── azure-devops/
    └── PIPELINE-AUTOMATION-ARCHITECTURE.md
```

Los planes y exports locales deben escribirse únicamente bajo:

```text
.local/azure-devops/plans/
.local/azure-devops/exports/
.local/azure-devops/audit/
```

Agregar `/.local/azure-devops/` a `.gitignore`.

## 5. Diseño de `SKILL.md`

El frontmatter debe contener únicamente:

```yaml
---
name: manage-azure-devops-pipelines
description: Gestiona, crea, revisa y diagnostica pipelines de Azure DevOps para Shared-Service-GM mediante el MCP oficial y APIs REST controladas. Usar al trabajar con pipelines clásicos o YAML, Builds, Releases, Variable Groups, task groups, artefactos, ejecuciones, despliegues AKS o pipelines DACPAC/SSDT.
---
```

Mantener `SKILL.md` conciso y usar progressive disclosure. Debe contener:

1. Enrutamiento de modos:
   - `inspect`: inventario y consultas de solo lectura.
   - `classic-aks`: Library + Build clásico + Release clásico hacia AKS.
   - `classic-dacpac`: Build y Release clásicos de base de datos.
   - `yaml`: pipelines YAML mediante capacidades reales del MCP.
   - `run-monitor`: ejecución, seguimiento y diagnóstico.
2. Prioridad MCP → REST controlado solo para brechas clásicas.
3. Flujo obligatorio: intake → inventario → plan → validación independiente → aprobación → apply → readback → reporte → memoria.
4. Separación estricta entre AKS y DACPAC.
5. Tabla que indique qué referencia cargar en cada modo.
6. Regla de no asumir IDs, repositorios, branches, pools, service connections, task groups, clusters ni namespaces.
7. Regla de no guardar secretos.
8. Política de aprobación por operación atómica.

No duplicar dentro de `SKILL.md` el contenido completo de las tres guías.

## 6. Comportamiento de los scripts

### `Invoke-AdoRest.ps1`

- Debe ser el único helper autorizado para llamadas REST clásicas.
- Leer el token de `$env:AZURE_DEVOPS_PAT` sin imprimirlo.
- Construir `Authorization: Basic` solo en memoria.
- Admitir `GET`, `POST`, `PUT` y `DELETE`, pero no permitir escrituras si el llamador no usa el flujo de plan aprobado.
- No registrar headers ni bodies con valores secretos.
- Usar `https://dev.azure.com/Shared-Service-GM` para Build/Distributed Task y `https://vsrm.dev.azure.com/Shared-Service-GM` para Release.
- Usar APIs oficiales 7.1 cuando estén disponibles.

### Scripts de plan

`New-AdoClassicAksPlan.ps1` y `New-AdoClassicDatabasePlan.ps1` deben producir JSON sanitizado, sin ejecutar cambios. Deben fallar si falta un dato obligatorio o si existen placeholders sin resolver.

### `Test-AdoClassicPlan.ps1`

Debe validar como mínimo:

- Familia correcta: AKS o DACPAC.
- Nombres y rutas.
- Repo y branch existentes.
- Dockerfile y contexto Docker.
- Path filters.
- Puertos y probes.
- Variables obligatorias sin mezclar capas.
- Task groups existentes y revisión vigente.
- Pool existente.
- Service connections existentes.
- Variable Group destino no duplicado.
- Build/Release destino no duplicado.
- CD trigger y artifact filter planificados.
- Aprobación de Producción definida según gobernanza.
- Ausencia de secretos, PAT, passwords o connection strings.
- Ausencia de valores `CHANGE_ME`, `xxx` o referencias heredadas de otra aplicación, salvo placeholders deliberadamente documentados que impidan `Apply`.

### `Invoke-AdoClassicPlan.ps1` / `Apply-AdoClassicPlan.ps1`

> **Especificación original sustituida — no operativa.** Lo que sigue en
> esta sección (un único script `Invoke-AdoClassicPlan.ps1` con un switch
> `-Apply` que decide entre dry-run y escritura real) NO es como quedó
> implementado. La versión operativa separó esto en **dos scripts
> distintos**, precisamente para que `ado-security-gate.ps1` pueda pedir
> permiso por el NOMBRE del script en vez de interpretar variantes de un
> flag (abreviaciones de PowerShell, `-Apply:$true`, etc.):
>
> - **`Invoke-AdoClassicPlan.ps1`** — dry-run EXCLUSIVO. No declara ningún
>   parámetro `-Apply`; nunca escribe nada, sin importar qué se le pase.
> - **`Apply-AdoClassicPlan.ps1`** — el ÚNICO script que puede escribir en
>   Azure DevOps. Exige `-PlanPath` y `-InventoryPath`, revalida
>   `validationHash` y la evidencia de inventario (frescura acotada a un
>   tope absoluto de 24h, independiente de lo que declare el plan), y hoy
>   SIEMPRE rechaza antes de crear cualquier recurso porque las fases de
>   Build y Release clásico no están implementadas contra un payload
>   confirmado en vivo (ver `references/ado-classic-playbook-any-project.md`
>   Sec. 10).
>
> El resto de los puntos de abajo (resumen sanitizado antes de escribir,
> creación en orden, no borrar recursos parciales, no encolar el Build ni
> crear el primer Release, no desplegar a Producción como efecto
> colateral) siguen siendo el comportamiento esperado **cuando
> `Apply-AdoClassicPlan.ps1` finalmente implemente esas fases** — se
> mantienen como diseño de referencia, no como descripción de un script
> `-Apply` único que no existe.

## 7. Agentes y memorias

### `ado-pipeline-builder`

Responsable de intake, inventario, construcción del plan y aplicación aprobada. Debe comprobar primero la familia y el ambiente.

### `ado-pipeline-diagnoser`

Solo lectura. Analiza builds, releases, logs, artefactos y errores. Identifica la primera causa real y separa errores en cascada. No reintenta ni modifica.

### `ado-pipeline-reviewer`

Solo revisión independiente. Compara el plan con las guías y con el inventario en vivo. Debe emitir bloqueantes y advertencias antes de cualquier `-Apply`.

Los tres agentes deben incluir:

```yaml
memory: project
```

Cada carpeta de memoria debe coincidir exactamente con el `name` del agente y seguir `.cursor/rules/global.mdc` (sección de memoria de agentes).

No inicializar la memoria con datos no confirmados. Después de una tarea, guardar únicamente patrones reutilizables, causas raíz confirmadas y soluciones validadas. Nunca guardar PAT, passwords, headers, secretos, Variable Group secret values ni payloads sensibles.

## 8. Política de autorización

Implementar en `authorization.md`:

### Permitido sin pregunta adicional

- Consultar proyectos, repositorios, ramas y definiciones.
- Leer builds, releases, logs y artefactos.
- Consultar nombres y metadatos de Variable Groups, task groups, pools y service connections sin leer secretos.
- Generar inventarios, planes, exports sanitizados, diffs y dry-runs.
- Validar archivos locales y ejecutar pruebas de hooks/scripts.

### Preguntar una vez por operación atómica

Una aprobación puede cubrir la creación completa de un pipeline cuando Claude haya presentado un plan exacto que enumere:

- organización y proyecto;
- familia AKS o DACPAC;
- aplicación/base y ambientes;
- Variable Groups que se crearán;
- Build y Release que se crearán;
- repo, branch, path filters y pool;
- task groups y service connections que se referenciarán;
- triggers, filtros y aprobaciones;
- efectos esperados y plan de verificación.

Después de aprobar ese plan, Claude puede crear esos recursos y hacer el readback sin volver a preguntar por cada POST interno. La aprobación no se reutiliza para otro pipeline, otro ambiente ni un reintento posterior.

### Aprobación separada obligatoria

- Encolar el primer Build.
- Ejecutar o reintentar un pipeline.
- Crear o desplegar un Release real.
- Desplegar a Producción.
- Ejecutar DACPAC en `Apply`.
- Aprobar un stage.
- Activar CD automático si puede desplegar inmediatamente.
- Modificar o eliminar una definición existente.
- Cambiar aprobadores, permisos, service connections, pools o task groups.
- Eliminar recursos parciales como rollback.

## 9. Seguridad

Implementar en `security.md` y en el hook:

- Nunca imprimir, leer en voz alta, persistir ni registrar el PAT.
- Nunca inspeccionar `C:\mantenimientos\azure devops\token.txt`; esa referencia de las guías es legado y se sustituye por `${AZURE_DEVOPS_PAT}`.
- Nunca incluir el token en línea de comandos, documentación, planes, memorias o archivos versionables.
- No permitir `Full access` como recomendación predeterminada.
- No deshabilitar aprobaciones o filtros de rama para resolver rápidamente un bloqueo.
- No copiar secretos de una aplicación o ambiente a otro.
- No considerar base64 como protección de secretos.
- No modificar task groups compartidos; solo referenciarlos por ID/revisión verificada.
- No modificar service connections ni agent pools durante la creación de un pipeline.
- No clonar entre familias incompatibles.
- No convertir una denegación MCP en una llamada REST equivalente.

El hook no debe bloquear indiscriminadamente todo Azure DevOps. Debe:

- permitir lecturas y dry-runs;
- rechazar exposición de credenciales;
- rechazar REST de escritura directo que no pase por `Apply-AdoClassicPlan.ps1` (el único script habilitado para escribir — ver corrección en la sección 6; `Invoke-AdoClassicPlan.ps1` es dry-run exclusivo y nunca escribe);
- dejar que el sistema de permisos pregunte antes de acciones riesgosas aprobables.

## 10. Integración con configuración existente

### `.claude/settings.json`

Agregar los hooks de Azure DevOps sin reemplazar los hooks actuales:

- `PreToolUse` para Bash → `ado-security-gate.ps1`.
- `PostToolUse` para Write/Edit/MultiEdit → `ado-post-validate.ps1`.
- `Stop` → `ado-stop-validate.ps1`.

### `.claude/settings.local.json`

- Conservar permisos actuales no relacionados.
- Agregar `azure-devops` a `enabledMcpjsonServers`.
- No adivinar nombres de tools MCP. Primero conectar el servidor y listar los nombres reales expuestos por la versión fijada.
- Permitir automáticamente únicamente tools de lectura.
- Configurar como `ask` las tools de escritura, ejecución, cancelación, retry y creación.
- Permitir scripts locales de inventario, plan y validación.
- Configurar como `ask` `Apply-AdoClassicPlan.ps1` y cualquier script de ejecución real. *(Corrección posterior: la implementación separó `Invoke-AdoClassicPlan.ps1` — dry-run exclusivo — de `Apply-AdoClassicPlan.ps1`, el único script que puede escribir. Para evitar una segunda aprobación redundante, el hook permite una sola ejecución cuando coincide exactamente con el comando y los hashes visibles del último plan aprobado por `ExitPlanMode`; cualquier desviación conserva `ask`.)*
- No agregar permisos temporales de `awk`, `mv`, pruebas aisladas o comandos con paths específicos que luego queden como basura.

### `CLAUDE.md`

Agregar una sección breve de Azure DevOps Pipelines que defina:

- organización `Shared-Service-GM`;
- proyecto predeterminado `DevOps`;
- skill y documentación fuentes de verdad;
- política MCP primero y REST controlado para brechas clásicas;
- aprobación atómica;
- separación AKS/DACPAC;
- prohibición de secretos;
- ejecución y Producción con aprobación separada.

No copiar toda la skill dentro de `CLAUDE.md`.

### `.gitignore`

Agregar como mínimo:

```gitignore
/.local/azure-devops/
```

Confirmar que `.claude/settings.local.json`, `.env` y `.env.*` continúen ignorados.

## 11. Validaciones obligatorias

Ejecutar sin crear recursos reales:

1. Validar JSON de `.mcp.json`, `settings.json`, `settings.local.json` y ejemplos.
2. Validar frontmatter de la skill: nombre en minúsculas, números y guiones; sin campos adicionales.
3. Confirmar que `SKILL.md` no sea excesivo y que las tres guías vivan en `references/`.
4. Validar sintaxis de todos los scripts PowerShell.
5. Ejecutar las pruebas de hooks.
6. Ejecutar los scripts de plan con datos ficticios sanitizados.
7. Verificar que dry-run no haga POST, PUT ni DELETE.
8. Buscar posibles secretos y confirmar que solo existan placeholders.
9. Confirmar que cada agente tenga `memory: project` y su carpeta de memoria exacta.
10. Verificar que los hooks previos sigan registrados.
11. Verificar `claude mcp list`.
12. Realizar una prueba MCP de solo lectura:
    - listar proyectos;
    - confirmar que existe `DevOps`;
    - listar definiciones o builds sin ejecutar nada.
13. No imprimir el PAT durante ninguna validación.

## 12. Resultado que debe entregar Claude

Al terminar, presentar:

1. Árbol exacto de archivos creados y modificados.
2. Versión fijada de `@azure-devops/mcp`.
3. Estado de conexión MCP.
4. Lista de domains y tools reales disponibles.
5. Confirmación expresa de que el MCP oficial no cubre toda la creación clásica y que el fallback REST quedó limitado a scripts controlados.
6. Resultado de pruebas de hooks, sintaxis y dry-run.
7. Scopes de PAT requeridos, sin mostrar el token.
8. Elementos pendientes antes de crear el primer pipeline real.
9. Confirmación de que no se creó, modificó, ejecutó ni eliminó ningún recurso real de Azure DevOps.
10. Confirmación de que no hubo commit ni push.

## Referencias oficiales verificadas

- MCP oficial de Azure DevOps: https://github.com/microsoft/azure-devops-mcp
- Configuración local y autenticación: https://github.com/microsoft/azure-devops-mcp/blob/main/docs/GETTINGSTARTED.md
- Toolset oficial: https://github.com/microsoft/azure-devops-mcp/blob/main/docs/TOOLSET.md
- Limitación del MCP remoto con Claude Code: https://learn.microsoft.com/azure/devops/mcp-server/remote-mcp-server
- API Build Definitions: https://learn.microsoft.com/rest/api/azure/devops/build/definitions/create?view=azure-devops-rest-7.1
- API Release Definitions: https://learn.microsoft.com/rest/api/azure/devops/release/definitions/create?view=azure-devops-rest-7.1
- API Variable Groups: https://learn.microsoft.com/rest/api/azure/devops/distributedtask/variablegroups/add?view=azure-devops-rest-7.1
- API Task Groups: https://learn.microsoft.com/rest/api/azure/devops/distributedtask/taskgroups/list?view=azure-devops-rest-7.1
