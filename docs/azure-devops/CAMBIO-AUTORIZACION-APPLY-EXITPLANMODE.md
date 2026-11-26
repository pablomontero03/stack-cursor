# Cambio de autorización para `Apply-AdoClassicPlan.ps1` y permisos operativos

Fecha de implementación: 2026-08-27

Fecha de ampliación de permisos operativos: 2026-08-27

Fecha de corrección integral del flujo builder/subagente: 2026-08-27

Fecha de corrección de arquitectura principal/subagente: 2026-08-27

## Resumen

Se corrigió la aprobación redundante que aparecía al ejecutar
`Apply-AdoClassicPlan.ps1` después de que el usuario ya había aprobado el
plan presentado por Claude mediante `ExitPlanMode`.

Antes del cambio, cualquier comando que mencionara
`Apply-AdoClassicPlan.ps1` producía incondicionalmente:

```json
{
  "permissionDecision": "ask"
}
```

Ahora, la aprobación del plan puede heredarse para una única ejecución
exacta de `Apply-AdoClassicPlan.ps1`. Si el hook no puede demostrar que la
ejecución pertenece al alcance aprobado, conserva `ask` como fallback.

No se agregó ningún permiso global para Bash, PowerShell, REST ni Azure
DevOps.

Después del primer cambio se detectó un segundo problema independiente: los
comandos preparatorios de solo lectura, generación y edición local seguían
mostrando tarjetas aunque formaran parte del trabajo que el usuario acababa de
aprobar. Esta segunda causa no estaba en el bloque de `Apply`; provenía del
evaluador base de permisos de Claude Code y de cómo el builder ejecutaba
PowerShell a través de `Bash`.

La ampliación documentada aquí corrige también ese enrutamiento sin cambiar
la lógica de creación, actualización, borrado, validación o readback de Azure
DevOps. Los scripts funcionales y el hook de `Apply` permanecieron intactos
durante esta segunda etapa.

Una revisión posterior de los transcripts reales demostró por qué esas dos
etapas todavía no resolvían el caso completo: el `ado-pipeline-builder`
ejecutaba los Apply desde su propio transcript, pero nunca llamaba a
`ExitPlanMode` allí. Además, su archivo de agente ni siquiera declaraba
`EnterPlanMode`/`ExitPlanMode` y contenía instrucciones contradictorias que le
ordenaban presentar el plan y luego confiar en una tarjeta nativa por cada
Apply. La aprobación del agente principal no podía ser encontrada por el hook
del subagente.

La primera propuesta para esa tercera causa intentó convertir al builder en
propietario de Plan Mode ejecutándolo en foreground. La prueba real demostró
que no era viable: los subagentes no disponen de `EnterPlanMode`, incluso en
foreground. Forzar `run_in_background: false` no cambia las herramientas
disponibles ni convierte su transcript en el transcript principal.

La corrección vigente separa responsabilidades. El builder solo prepara y
valida artefactos; la sesión principal presenta `ExitPlanMode`, recibe la
única aprobación y ejecuta en su propio transcript todos los comandos exactos
enumerados. El hook también deja de confundir una lectura o un `grep` del
archivo con una ejecución real.

No se agregó `PowerShell(*)`, `Bash(*)`, acceso REST directo ni bypass de
permisos. Tampoco se modificó ningún generador, payload, validador, readback o
script que escribe en Azure DevOps.

## Causa raíz corregida

El bloque anterior de `ado-security-gate.ps1` solo comprobaba si el texto
del comando contenía el nombre `Apply-AdoClassicPlan.ps1`. Cuando lo
encontraba, ejecutaba siempre `Ask-Permission`, sin considerar:

- que `ExitPlanMode` ya había sido aprobado;
- si el comando estaba dentro del plan presentado;
- si el plan y el inventario seguían intactos;
- si se trataba del primer intento o de un reintento.

Por ello, cambiar de modo `plan` a `auto` o `acceptEdits` no eliminaba la
tarjeta: la decisión explícita `ask` del hook tenía prioridad.

## Segunda causa raíz: aprobaciones de comandos preparatorios

Las capturas posteriores no correspondían al `ask` de
`Apply-AdoClassicPlan.ps1`. Se reprodujeron comandos representativos contra
los cinco hooks `PreToolUse` configurados para el proyecto y todos devolvieron
salida silenciosa, sin `permissionDecision: "ask"`. La tarjeta era el fallback
normal del sistema de permisos porque no encontraba una regla `allow`
aplicable al comando completo.

La sesión analizada estaba en `acceptEdits`. Ese modo autoriza herramientas de
edición y algunas operaciones de archivos dentro del workspace, pero no
autoriza automáticamente cualquier ejecución de terminal.

Se encontraron cinco causas concretas:

1. El builder solo declaraba `Bash`, aunque el proyecto ya tenía varias reglas
   `PowerShell(...)`. Ejecutar `powershell.exe` dentro de `Bash` no hace que se
   evalúen las reglas de la herramienta `PowerShell`.
2. Había una regla histórica `Bash(powershell -Command ' *)` que exige una
   comilla simple después de `-Command`. Las capturas utilizaban comillas
   dobles, por lo que no coincidían.
3. `Permitir siempre` había acumulado reglas Bash con el comando completo:
   aplicación, stage, ids, timestamp y ruta de sesión. Esas reglas solo sirven
   para esa invocación exacta y no se reutilizan al cambiar cualquiera de esos
   valores.
4. Algunos `tool_use` agrupaban dos procesos. Aunque el primero estuviera
   permitido, el segundo `powershell -Command` no lo estaba. Claude Code exige
   que cada subcomando de una ejecución compuesta tenga autorización.
5. Los archivos crudos y derivados se escribían bajo
   `AppData/Local/Temp/claude/.../scratchpad`, fuera del workspace original.
   Sin declarar ese directorio como directorio adicional, las ediciones allí
   conservaban una frontera de permiso independiente.

La aprobación de `ExitPlanMode` tampoco constituye por sí sola un permiso
general de terminal. Antes de este cambio, el único puente explícito entre el
plan aprobado y los permisos era el mecanismo especial implementado para
`Apply-AdoClassicPlan.ps1`.

### Clasificación de las capturas analizadas

| Comando observado | Causa de la tarjeta | Ruta nueva |
|---|---|---|
| Extraer el `File Creator` del Build 588 mediante `powershell -Command` y `WriteAllText` | One-liner no permitido y escritura en scratchpad externo | Inspeccionar con `Read`/`Grep` y escribir con `Write` dentro del scratchpad declarado |
| Descargar e inspeccionar el Variable Group 395 en dos procesos | La descarga estaba permitida, pero el segundo proceso inline no | Usar directamente `Get-AdoClassicVariables.ps1` con la herramienta `PowerShell` |
| Calcular la antigüedad de un inventario con `Get-Content` inline | Era lectura lógica, pero ejecución genérica de PowerShell | Leer el JSON con `Read`; `Get-FileHash` queda permitido para el hash criptográfico requerido |
| Ejecutar `New-AdoClassicAksPlan.ps1` para Desarrollo/UAT | Se invocaba mediante `Bash`, mientras la regla reutilizable era `PowerShell(...)` | Ejecutar el script directamente con la herramienta `PowerShell` |
| Modificar `artifactFilterBranch` con `Set-Content` en un one-liner | Edición local envuelta en terminal y rutas con timestamps | Usar `Edit`/`Write` antes de aprobar el plan |

Las imágenes repetidas del último comando correspondían a un único
`tool_use` en el transcript analizado; no se interpretaron como múltiples
ejecuciones idénticas del backend.

## Tercera causa raíz: transcript aislado y flujo contradictorio del builder

La auditoría de la sesión que produjo las capturas encontró dos transcripts
distintos: el del agente principal y el del `ado-pipeline-builder`. El hook de
`PreToolUse` recibe `transcript_path` de la sesión que está intentando el
comando; por seguridad no recorre otros transcripts ni supone que una
aprobación perteneciente a otro agente es válida.

En el transcript real del builder se comprobó:

- cero llamadas a `ExitPlanMode`;
- varios `Apply-AdoClassicPlan.ps1` ejecutados como tool uses independientes;
- scripts versionados lanzados mediante un segundo `powershell -File` dentro
  de la herramienta `PowerShell`, a menudo junto con asignaciones y varios
  comandos;
- helpers `.ps1` temporales creados y ejecutados desde el scratchpad;
- comandos de inspección que solo mencionaban el nombre del Apply.

Por lo tanto, el comportamiento del hook era correcto al responder `ask` a
los Apply reales: el transcript que pedía permiso no contenía una aprobación
heredable. Reiniciar o reanudar la conversación no podía fabricar el evento
`ExitPlanMode` faltante.

El archivo del agente explicaba la contradicción:

1. El frontmatter solo exponía `Read`, `Grep`, `Glob`, `Bash`, `PowerShell`,
   `Edit` y `Write`; no tenía `EnterPlanMode` ni `ExitPlanMode`.
2. Una sección decía terminar la preparación antes de `ExitPlanMode`, pero el
   proceso operativo ordenaba presentar un resumen e invocar inmediatamente
   cada Apply, usando su tarjeta nativa como única aprobación.
3. El agente principal podía enviar el builder al background. Los subagentes
   usan contexto/transcript aislado; las interacciones y permisos no se
   convierten automáticamente en una aprobación criptográficamente ligada al
   plan del hijo.

Existía además un falso positivo independiente en el hook. La condición era
una búsqueda textual global de `apply-adoclassicplan.ps1`; por eso este comando
de solo lectura entraba al bloque de autorización y terminaba en `ask`:

```text
grep -n "..." D:/.../Apply-AdoClassicPlan.ps1 | head -60
```

La solución no es heredar permisos de forma global entre agentes. Eso
rompería el aislamiento que permite comprobar exactamente qué plan aprobó el
usuario. La solución es que la sesión principal sea el único actor que aprueba
y aplica, mientras el builder se limita a preparar; además, el hook debe
distinguir intención de ejecución de una mera mención.

## Cuarta causa raíz: defecto del matcher PowerShell en Windows

Una prueba real posterior demostró que el enrutamiento directo por
`PowerShell` tampoco era suficiente. Claude Code guardó en
`.claude/settings.local.json` las invocaciones exactas aprobadas con
«Permitir siempre», pero volvió a preguntar por esos mismos comandos. Se
contabilizaron 74 reglas históricas relacionadas con los entrypoints de este
dominio.

Cada comando de las nuevas capturas se reprodujo contra
`ado-security-gate.ps1`; todos terminaron con código `0` y salida silenciosa.
Por tanto, las tarjetas no procedían del hook del proyecto: las generaba el
matcher base de permisos al no reconocer sus propias reglas con rutas Windows
que contienen barras invertidas. El defecto está reportado públicamente para
Claude Code en Windows y afecta tanto reglas creadas por «Permitir siempre»
como ciertos patrones PowerShell escritos manualmente.

La solución no es seguir acumulando reglas exactas ni conceder
`PowerShell(*)`. Se agregó un hook `PermissionRequest`, que se ejecuta justo
cuando Claude Code está a punto de mostrar una tarjeta. Este hook solo responde
`allow` si el comando ya superó `PreToolUse` y además cumple todo lo siguiente:

- herramienta `PowerShell` y evento `PermissionRequest`;
- una sola sentencia, un solo pipeline y un solo comando;
- operador `&` con ruta absoluta y literal;
- script real dentro de la carpeta versionada `scripts/`;
- entrypoint incluido en una lista positiva de preparación/lectura/readback;
- argumentos exclusivamente literales, sin variables, splatting,
  subexpresiones, redirecciones ni comandos auxiliares.

`Apply-AdoClassicPlan.ps1`, `Invoke-AdoRest.ps1`, scripts externos y lectura
local de secretos quedan fuera. En esos casos el hook permanece silencioso y
la decisión anterior continúa vigente.

## Corrección integral aplicada

### Sesión principal propietaria de la operación

`ado-pipeline-builder.md` ahora:

- precarga `manage-azure-devops-pipelines` mediante `skills`;
- no declara `EnterPlanMode` ni `ExitPlanMode`;
- puede trabajar en foreground o background porque no escribe remotamente;
- prepara planes, bodies, hashes, comandos Apply y readback;
- entrega esos artefactos a la sesión principal y se detiene antes del Apply;
- elimina el antiguo patrón de una tarjeta nativa por cada Apply.

`CLAUDE.md`, la skill y las reglas establecen que la sesión principal es la
única propietaria de `ExitPlanMode`, Apply y readback. Así la aprobación y las
escrituras permanecen en el mismo transcript sin debilitar el aislamiento.

### Invocaciones PowerShell deterministas

Cada script permitido debe ejecutarse como un único comando de la herramienta
`PowerShell`:

```powershell
& 'D:\Proyectos\automation\.claude\skills\manage-azure-devops-pipelines\scripts\Test-AdoClassicPlan.ps1' -PlanPath '...' -InventoryPath '...'
```

No se admite iniciar otro `powershell`/`pwsh`, anteponer asignaciones, usar
one-liners de transformación ni agrupar pipelines, separadores, bucles o
varios scripts en el mismo tool use. Así cada comando coincide de forma
estable con la allowlist acotada existente.

Los helpers temporales del scratchpad quedan fuera del flujo automático. Si
una capacidad reutilizable no existe como script versionado y revisado, el
builder debe detenerse e identificarla; no puede resolver la carencia pidiendo
permisos repetidos para código efímero.

### Gap de creación cerrado con runner versionado

La continuación de EMR expuso que `New-AdoClassicAksPlan.ps1` dejaba
`approvedOperations` vacío y que los servicios anteriores lo completaban con
scripts scratch. Se agregó `New-AdoClassicCreatePlan.ps1`, permitido solo como
preparador local, para derivar de los payloads oficiales las operaciones
`create-variable-group`, `create-build-definition` y
`create-release-definition`. El runner:

- no llama HTTP ni ejecuta Apply;
- calcula el `bodyHash` mediante `New-AdoApprovedOperationEntry`;
- nunca modifica el plan de origen;
- invalida la validación anterior para exigir nuevamente
  `Test-AdoClassicPlan.ps1`;
- rechaza ids futuros o inventados y exige que las dependencias de Release ya
  existan.

Esta última regla implica una frontera real: si Azure DevOps debe asignar
primero los ids de Libraries/Build, la creación y el relink posterior son dos
planes ejecutables. No es seguro prometer una sola aprobación criptográfica
para un body que todavía no puede existir. Dentro de cada plan ya final y
aprobado sí se ejecutan todos sus Apply enumerados sin tarjetas adicionales.

### Detección de intención real del Apply

`ado-security-gate.ps1` incorpora `Test-AdoApplyExecutionIntent`. El helper
analiza el AST de PowerShell y reconoce:

- ejecución directa por ruta, `&` o dot-sourcing;
- `powershell`/`pwsh -File Apply-AdoClassicPlan.ps1`;
- wrappers literales como `cmd /c` o `bash -c`;
- ejecución anidada en `-Command`;
- contenido de `-EncodedCommand` ya decodificado por el hook;
- comandos compuestos que contienen un Apply real.

Una sintaxis ambigua falla de forma cerrada y conserva `ask`. En cambio,
`grep`, `Get-Content` o comandos anidados que únicamente leen el archivo no
entran a la autorización del Apply y continúan sin decisión explícita del
hook.

### Alcance de una sola aprobación

La política quedó alineada con el objetivo operativo: una sola aprobación
puede cubrir la creación o actualización configuracional completa de una
misma aplicación, siempre que el plan enumere cuerpos, ids/revisiones,
ambientes y todos los comandos exactos. Esto incluye Variable Groups y
definiciones Build/Release, triggers/filtros y la configuración de aprobadores
de esa definición.

Siguen fuera y requieren aprobación separada: ejecutar/reintentar pipelines,
encolar Builds, crear una instancia de Release real, desplegar, aplicar DACPAC,
aprobar un stage en curso, borrar recursos, modificar task groups/service
connections/pools compartidos y cambiar permisos/ACL/membresías.

## Comportamiento nuevo

El hook devuelve `permissionDecision: "allow"` únicamente si se cumplen
todas estas condiciones:

1. El payload de `PreToolUse` contiene un transcript de la sesión actual.
2. El transcript contiene una aprobación exitosa de `ExitPlanMode`.
3. Se utiliza el último plan aprobado de la sesión.
4. Ese plan contiene exactamente un bloque visible
   `ado-apply-authorization` versión 1.
5. El comando actual coincide literalmente con un único comando enumerado
   en ese bloque.
6. La invocación usa el `Apply-AdoClassicPlan.ps1` oficial de la skill.
7. El comando está en una sola línea, usa rutas literales e incluye
   `-PlanPath` e `-InventoryPath`; el builder usa la forma directa `&` de la
   herramienta `PowerShell` (la forma histórica `powershell -File` permanece
   validada por compatibilidad).
8. Los SHA-256 actuales del plan y del inventario coinciden con los que vio
   y aprobó el usuario.
9. La aprobación tiene una antigüedad máxima de 24 horas, alineada con la
   vigencia máxima del inventario que sustenta el plan.
10. Si el comando ya fue intentado, el journal demuestra que ninguna operación
    salió de `pending`; cualquier estado iniciado, completado o ambiguo exige
    readback y una nueva aprobación.

Si cualquiera de esas condiciones falla, el hook no bloquea a ciegas la
operación: devuelve `permissionDecision: "ask"` junto con la causa por la
que no pudo heredar la aprobación.

## Permisos operativos agregados

La segunda etapa agregó una allowlist compartida y acotada en
`.claude/settings.json`. Solo incluye scripts versionados que realizan
inventario, lectura, generación local de planes, validación, dry-run o
readback, además de `Get-FileHash`:

```json
{
  "permissions": {
    "allow": [
      "PowerShell(*Export-AdoClassicInventory.ps1*)",
      "PowerShell(*Find-AdoResourceByName.ps1*)",
      "PowerShell(*Get-AdoClassicDefinitionTemplate.ps1*)",
      "PowerShell(*Get-AdoClassicVariables.ps1*)",
      "PowerShell(Get-FileHash *)",
      "PowerShell(*Invoke-AdoClassicPlan.ps1*)",
      "PowerShell(*New-AdoClassicAksPlan.ps1*)",
      "PowerShell(*New-AdoClassicDatabasePlan.ps1*)",
      "PowerShell(*New-AdoClassicDeletePlan.ps1*)",
      "PowerShell(*Show-AdoBuildSteps.ps1*)",
      "PowerShell(*Show-AdoReleaseEnvironments.ps1*)",
      "PowerShell(*Test-AdoClassicDeletePlan.ps1*)",
      "PowerShell(*Test-AdoClassicPlan.ps1*)",
      "PowerShell(*Test-AdoCreatedResources.ps1*)"
    ]
  }
}
```

No se incluyeron:

- `Apply-AdoClassicPlan.ps1`;
- `Invoke-AdoRest.ps1`;
- `Invoke-RestMethod`, `Invoke-WebRequest`, `curl` o `wget`;
- `PowerShell(*)` o `Bash(*)`;
- `powershell -Command *`;
- scripts arbitrarios creados en el scratchpad.

Las reglas de permisos se combinan entre los scopes de Claude Code. Por eso
la allowlist compartida complementa las reglas locales existentes sin borrar
ni reemplazar autorizaciones previas.

### Directorio temporal adicional

Se agregó en `.claude/settings.local.json`:

```json
{
  "permissions": {
    "additionalDirectories": [
      "C:/Users/pablo/AppData/Local/Temp/claude/D--Proyectos-automation"
    ]
  }
}
```

El alcance está limitado al árbol temporal que Claude usa para este proyecto.
No concede acceso equivalente a todo `C:/Users/pablo/AppData/Local/Temp` ni a
otros proyectos.

Este ajuste extiende al scratchpad las reglas normales de lectura y edición
del modo activo. No convierte los scripts temporales en comandos de terminal
permitidos ni concede permiso para ejecutar PowerShell arbitrario.

### Enrutamiento obligatorio del builder

El agente `ado-pipeline-builder` ahora declara:

```yaml
tools: Read, Grep, Glob, Bash, PowerShell, Edit, Write
skills:
  - manage-azure-devops-pipelines
```

Y debe aplicar estas reglas:

1. Ejecutar los scripts versionados directamente con `PowerShell` mediante
   una única invocación `& '<ruta absoluta>' ...`.
2. No envolverlos en `Bash(powershell ...)`.
3. No usar `powershell -Command`, `pwsh -Command`, `-EncodedCommand` ni
   one-liners equivalentes para inspeccionar o editar JSON/YAML.
4. Usar `Read`/`Grep` para inspección y `Edit`/`Write` para archivos locales.
5. Para variables clásicas, usar `Get-AdoClassicVariables.ps1` en lugar de
   descargar un body y recorrerlo con un segundo comando.
6. No ejecutar helpers temporales del scratchpad.
7. Completar generación, corrección, cuerpos, validación y hashes antes del
   handoff.
8. Entregar el bloque `ado-apply-authorization` y los comandos de readback a
   la sesión principal sin pedir aprobación ni ejecutar Apply.
9. La sesión principal presenta `ExitPlanMode`; después de aprobar, no modifica
   plan, inventario ni cuerpos y copia únicamente los comandos enumerados.

`Bash` se conserva en las herramientas del agente para no romper otras
capacidades existentes, pero dejó de ser el canal autorizado para ejecutar
los `.ps1` de esta skill.

### Reglas históricas preservadas

No se limpiaron las reglas antiguas de `.claude/settings.local.json`. Incluyen
comandos exactos guardados por aprobaciones anteriores y una regla histórica
para `powershell -Command` con comilla simple. Se conservaron deliberadamente
para no romper sesiones o flujos existentes.

El builder nuevo no debe depender de esas reglas. Una limpieza o migración de
ese historial sería un cambio separado, porque eliminar reglas locales puede
reintroducir tarjetas en flujos ajenos a Azure DevOps Pipelines.

## Formato que debe incluir el plan

Después de generar y validar el plan operativo, Claude debe calcular los
hashes reales con `Get-FileHash -Algorithm SHA256` y presentar un único
bloque visible como el siguiente dentro del plan de `ExitPlanMode`:

````markdown
```ado-apply-authorization
{
  "version": 1,
  "commands": [
    {
      "command": "& 'D:\\Proyectos\\automation\\.claude\\skills\\manage-azure-devops-pipelines\\scripts\\Apply-AdoClassicPlan.ps1' -PlanPath 'D:\\Proyectos\\automation\\.local\\azure-devops\\plans\\plan.json' -InventoryPath 'D:\\Proyectos\\automation\\.local\\azure-devops\\exports\\inventory.json'",
      "planSha256": "<SHA-256 real del plan>",
      "inventorySha256": "<SHA-256 real del inventario>"
    }
  ]
}
```
````

El bloque puede enumerar todos los comandos independientes que necesita la
operación atómica. No existe un máximo artificial de 20: cada entrada conserva
la misma validación estricta de comando y hashes. No se deben inventar hashes
ni modificar el comando después de que el usuario apruebe el plan.

## Flujo resultante

```text
inventario
  → generación del plan operativo
  → validación del plan
  → cálculo de SHA-256
  → builder entrega artefactos inmutables a la sesión principal
  → sesión principal llama ExitPlanMode con resumen + ado-apply-authorization
  → aprobación del usuario
  → sesión principal ejecuta cada Apply exacto: allow mientras el journal confirme que ninguna escritura previa inició
  → sesión principal hace readback
```

El flujo completo, incluyendo las operaciones preparatorias, queda así:

```text
lecturas e inventario
  → scripts versionados mediante PowerShell allowlisted
  → inspección local mediante Read/Grep
  → generación y edición local mediante scripts seguros o Edit/Write
  → validación independiente
  → cálculo de hashes mediante Get-FileHash
  → handoff del builder a la sesión principal
  → EnterPlanMode + ExitPlanMode en la sesión principal
  → aprobación del usuario
  → todos los Apply exactos enumerados: allow dentro del alcance aprobado
  → readback
```

Una operación no incluida en el plan, un script distinto, una modificación
posterior del JSON o una acción sensible conserva su pregunta o bloqueo
correspondiente. Un reintento local reutiliza la aprobación únicamente cuando
el journal no existe o mantiene todas las operaciones en `pending`. Si alguna
escritura pudo iniciar o completar, se exige readback y una nueva aprobación.

## Matriz de decisiones

| Situación | Decisión del hook |
|---|---|
| Apply enumerado, mismo transcript, hashes intactos, menos de 24 horas y journal seguro | `allow` |
| `grep`/`Get-Content` solo menciona el archivo Apply | sin decisión del hook; no `ask` por Apply |
| No existe un plan aprobado en la sesión | `ask` |
| El plan fue aprobado por otro agente/transcript | `ask` |
| El plan aprobado no contiene el bloque de autorización | `ask` |
| Se agregó, quitó o modificó un argumento | `ask` |
| Cambió `PlanPath`, `InventoryPath` o el contenido de alguno | `ask` |
| Se intenta ejecutar otro archivo con el mismo nombre | `ask` |
| Comando compuesto, pipeline, redirección, variable o subexpresión | `ask` |
| Uso de `-Command` o `-EncodedCommand` | `ask` |
| Aprobación con más de 24 horas | `ask` |
| Reintento sin journal o con todas las operaciones `pending` | `allow` |
| Reintento con estado `in-progress`, `succeeded`, desconocido o journal ilegible | `ask` |
| REST directo, exposición del PAT u otra prohibición previa | bloqueo existente, sin cambios |

## Archivos modificados

### Primera etapa: autorización heredada del `Apply`

- `.claude/hooks/azure-devops-pipelines/ado-security-gate.ps1`
  - incorpora la decisión `allow`;
  - analiza de forma restrictiva la invocación;
  - lee la aprobación del transcript;
  - valida comando, hashes, vigencia y uso único;
  - conserva `ask` como fallback.
- `.claude/hooks/azure-devops-pipelines/tests/run-hook-tests.ps1`
  - agrega transcripts y archivos ficticios;
  - prueba `allow`, cambio de argumento, alteración de hash, vencimiento y
    reintento.
- `.claude/hooks/azure-devops-pipelines/tests/README.md`
  - documenta la cobertura nueva.
- `CLAUDE.md`
  - actualiza la regla general del dominio.
- `.cursor/skills/manage-azure-devops-pipelines/SKILL.md`
  - define el flujo y el contrato del bloque de autorización.
- `.cursor/rules/azure-devops.mdc`
  - actualiza el alcance de la aprobación atómica.
- `.cursor/rules/azure-devops.mdc`
  - documenta las condiciones estrictas de `allow` y el fallback `ask`.
- `.cursor/skills/manage-azure-devops-pipelines/references/approval-matrix.md`
  - refleja la nueva matriz de aprobación.
- `.claude/skills/manage-azure-devops-pipelines/scripts/Apply-AdoClassicPlan.ps1`
  - actualiza únicamente la descripción de cómo se obtiene la aprobación.
- `docs/azure-devops/INSTRUCCIONES-CLAUDE-AZURE-DEVOPS-PIPELINES.md`
  - registra la corrección posterior respecto a la especificación original.

### Segunda etapa: reducción de aprobaciones preparatorias

- `.claude/settings.json`
  - agrega 14 reglas `PowerShell(...)` acotadas a scripts seguros y
    `Get-FileHash`;
  - no agrega ninguna regla para `Apply-AdoClassicPlan.ps1`, REST directo o
    PowerShell/Bash global.
- `.claude/settings.local.json`
  - agrega únicamente el scratchpad temporal de este proyecto a
    `permissions.additionalDirectories`;
  - conserva todas las reglas `allow`, `ask` y `deny` preexistentes.
- `.claude/agents/azure-devops/ado-pipeline-builder.md`
  - agrega las herramientas `PowerShell`, `Edit` y `Write`;
  - ordena ejecutar `.ps1` directamente con `PowerShell`;
  - reemplaza one-liners por `Read`/`Grep`/`Edit`/`Write`;
  - prohíbe modificar el plan después de su aprobación.
- `.cursor/skills/manage-azure-devops-pipelines/SKILL.md`
  - documenta el enrutamiento de herramientas y el alcance del allowlist;
  - aclara que `Apply`, REST directo y permisos globales no forman parte de
    la excepción.
  - incorpora runners versionados para operaciones create/update y elimina la
    necesidad de helpers scratch.
- `docs/azure-devops/CAMBIO-AUTORIZACION-APPLY-EXITPLANMODE.md`
  - integraba el diagnóstico y los cambios de las dos primeras etapas.

### Tercera etapa: intento foreground y detección por intención

- `.claude/agents/azure-devops/ado-pipeline-builder.md`
  - el primer intento agregó `EnterPlanMode`/`ExitPlanMode` y
    `background: false`;
  - la prueba real confirmó que foreground no habilita `EnterPlanMode` en un
    subagente, por lo que esa parte se retiró;
  - exige una invocación PowerShell directa por tool use y prohíbe helpers
    temporales.
- `CLAUDE.md`
  - establece que el builder solo prepara y la sesión principal aprueba,
    aplica y verifica;
  - documenta que la aprobación no se hereda entre transcripts.
- `.cursor/skills/manage-azure-devops-pipelines/SKILL.md`
  - incorpora el propietario único de la aprobación y la forma exacta de
    invocación;
  - aclara que el bloque autoriza cada comando enumerado mientras sus hashes y
    el journal permanezcan dentro del alcance aprobado.
- `.cursor/rules/azure-devops.mdc` y
  `.cursor/skills/manage-azure-devops-pipelines/references/approval-matrix.md`
  - alinean la aprobación atómica con creación o actualización completa de
    definiciones, incluidos triggers/filtros/aprobadores enumerados;
  - mantienen separadas ejecuciones, despliegues, borrados y recursos
    compartidos/permisos.
- `.claude/hooks/azure-devops-pipelines/ado-security-gate.ps1`
  - agrega detección AST de intención real de ejecución;
  - evita el falso `ask` por una mera mención del nombre del archivo;
  - mantiene fail-closed para sintaxis ambigua, wrappers y encoded commands.
- `.claude/hooks/azure-devops-pipelines/tests/run-hook-tests.ps1`
  - agrega casos para menciones inofensivas, ejecución directa/anidada/
    compuesta/codificada, varios Apply, transcript aislado y contrato del
    builder.
- `.claude/hooks/azure-devops-pipelines/tests/README.md`
  - documenta la cobertura de regresión nueva.
- `.claude/agent-memory/ado-pipeline-builder/MEMORY.md`, `patterns.md` y
  `debugging.md`
  - conservan los casos históricos, pero dejan explícito que los scripts de
    scratch allí mencionados no son helpers autorizados ni reutilizables;
  - remiten cualquier capacidad faltante a un helper versionado y probado.
- `docs/azure-devops/CAMBIO-AUTORIZACION-APPLY-EXITPLANMODE.md`
  - registra causa raíz, alcance, implementación, pruebas y operación.

La conclusión inicial de que la allowlist acotada era suficiente fue refutada
por la prueba real posterior descrita en la cuarta etapa.

### Cuarta etapa: autorización segura de preparación en Windows

- `.claude/hooks/azure-devops-pipelines/ado-preparation-permission.ps1`
  - nuevo hook `PermissionRequest`;
  - valida AST, ruta física, lista positiva y argumentos literales;
  - autoriza solo entrypoints preparatorios versionados;
  - permanece silencioso ante Apply, REST, secretos o sintaxis compuesta.
- `.claude/settings.json`
  - registra el nuevo hook exclusivamente para la herramienta `PowerShell`;
  - no agrega permisos globales ni modifica la autorización del Apply.
- `.claude/hooks/azure-devops-pipelines/tests/run-hook-tests.ps1`
  - agrega 13 casos de regresión para comandos observados y evasiones.
- `.claude/hooks/azure-devops-pipelines/tests/README.md`
  - documenta el contrato y que las pruebas no ejecutan los comandos.
- `.cursor/skills/manage-azure-devops-pipelines/SKILL.md`
  - documenta el fallback seguro ante el defecto del matcher Windows.
- `.claude/settings.local.json`
  - no se limpió ni se reescribió; las 74 reglas históricas se preservaron para
    evitar afectar otros flujos del usuario.

Durante la segunda etapa no se modificaron:

- `.claude/hooks/azure-devops-pipelines/ado-security-gate.ps1`;
- `.claude/skills/manage-azure-devops-pipelines/scripts/Apply-AdoClassicPlan.ps1`;
- `.claude/skills/manage-azure-devops-pipelines/scripts/New-AdoClassicAksPlan.ps1`;
- ningún otro generador, validador, payload o helper REST;
- `.mcp.json`;
- `env/Azure-DevOps.txt`.

No se creó, modificó, ejecutó ni eliminó ningún recurso de Azure DevOps como
parte de estos cambios.

## Validación realizada

Para la implementación original del `Apply` se ejecutó dos veces el arnés
completo:

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ".claude/hooks/azure-devops-pipelines/tests/run-hook-tests.ps1"
```

Resultado en ambas ejecuciones:

```text
Total: 90 - PASS: 90 - FAIL: 0
```

Después de la ampliación de permisos se volvió a ejecutar el arnés de hooks:

```text
Total: 90 - PASS: 90 - FAIL: 0
```

También se ejecutó la suite funcional completa de scripts para confirmar que
el cambio de permisos no alteró la lógica existente:

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ".claude/skills/manage-azure-devops-pipelines/scripts/tests/run-script-tests.ps1"
```

Resultado:

```text
Total: 334 - PASS: 334 - FAIL: 0
```

Después de corregir la arquitectura principal/subagente e incorporar los
runners versionados create/update, se ejecutaron nuevamente ambas suites:

```text
Hooks:   Total: 100 - PASS: 100 - FAIL: 0
Scripts: Total: 411 - PASS: 411 - FAIL: 0
```

Después de incorporar `PermissionRequest`, la suite de hooks terminó:

```text
Hooks: Total: 113 - PASS: 113 - FAIL: 0
```

Los 13 casos nuevos cubren los comandos exactos de inventario, generación de
planes AKS/create/update, validación e inspección observados en las capturas.
También confirman que el hook no autoriza Apply, REST genérico, comandos
compuestos, rutas mediante variables, revelación local de secretos, Bash ni
eventos distintos de `PermissionRequest`.

Los 6 casos nuevos del runner de creación verifican preparación de Variable
Group sin red, forma exacta de `approvedOperations`, invalidación obligatoria
de la validación previa, inmutabilidad del plan de origen, rechazo de
sobrescritura y rechazo de Releases con dependencias futuras sin id real.

Validaciones adicionales de la segunda etapa:

- `.claude/settings.json` y `.claude/settings.local.json` parsean como JSON;
- el frontmatter del builder contiene las herramientas esperadas;
- los comandos representativos de `New-AdoClassicAksPlan.ps1`,
  `Get-AdoClassicVariables.ps1`, `Get-AdoClassicDefinitionTemplate.ps1` y
  `Get-FileHash` coinciden con una regla acotada;
- ninguna regla nueva coincide con `Apply-AdoClassicPlan.ps1`,
  `Invoke-AdoRest.ps1`, `Invoke-RestMethod` ni `powershell -Command`;
- `ado-stop-validate.ps1` terminó con código 0 sobre el árbol real.

También se validó la sintaxis PowerShell de:

- `ado-security-gate.ps1`;
- `ado-preparation-permission.ps1`;
- `run-hook-tests.ps1`;
- `Apply-AdoClassicPlan.ps1`.

Las pruebas de hooks solo enviaron payloads JSON y archivos ficticios a los
hooks. No ejecutaron `Apply-AdoClassicPlan.ps1`, no se conectaron a Azure
DevOps y no leyeron credenciales.

La suite de scripts usa dobles y fixtures locales para sus pruebas de
operaciones y HTTP. No creó, actualizó ni borró recursos reales.

## Quinta etapa: cierre de huecos y validación final (2026-08-28)

La revisión posterior a la interrupción confirmó que las capturas de EMR se
generaron antes de que existiera el hook `PermissionRequest`: el subagente
trabajó aproximadamente entre las 19:14 y las 19:31, mientras el nuevo hook y
su registro en `settings.json` se crearon alrededor de las 19:38. Por tanto,
esas tarjetas no demostraban un fallo de la versión final; pertenecían a un
builder que ya había cargado el contrato anterior.

La revisión profunda sí encontró límites y discrepancias que podían provocar
nuevas tarjetas en sesiones largas. Se corrigieron así:

- `ado-permission-common.ps1` centraliza la decisión de autorización para
  `PreToolUse` y `PermissionRequest`; ambos hooks validan exactamente el mismo
  comando, transcript, hashes, antigüedad y journal.
- El transcript se recorre con `IO.File.ReadLines`; ya no se rechaza por superar
  25 MiB ni se carga completo en memoria.
- Se eliminó el máximo artificial de 20 comandos. Cada comando sigue requiriendo
  coincidencia literal única y hashes SHA-256 válidos.
- La vigencia del `ExitPlanMode` se elevó de 8 a 24 horas para coincidir con la
  evidencia de inventario aceptada por los validadores.
- Un reintento local puede reutilizar la aprobación si no existe journal o si
  todas sus operaciones continúan en `pending`. Cualquier estado iniciado,
  completado, desconocido o ilegible vuelve a `ask` para evitar duplicar una
  escritura remota.
- La inspección AST valida también argumentos adjuntos y arrays literales;
  variables, splatting, subexpresiones y comandos anidados no heredan permisos.
- El hook `PermissionRequest` sirve además como respaldo para un Apply ya
  autorizado si la interfaz intenta abrir una tarjeta a pesar del `allow` de
  `PreToolUse`.
- Se agregó `Convert-AdoEnvFileClassification.ps1` como entrypoint versionado.
  La clasificación redactada se autoriza automáticamente; `-PopulateRealValues`
  conserva aprobación puntual porque procesa secretos reales.
- Se agregó la regla exacta de lectura `mcp__azure-devops__repo_branch` sin
  ampliar permisos MCP de escritura.
- Se corrigió el arnés de Azure DevOps Permissions para escribir JSON sin BOM,
  evitando falsos fallos de `ConvertFrom-Json` bajo Windows PowerShell 5.1.

Validación final ejecutada desde cero después de la interrupción:

```text
Scripts Azure DevOps Pipelines: 413/413 PASS
Hooks Azure DevOps Pipelines:   124/124 PASS
Hooks Azure DevOps Permissions:  35/35 PASS
Hooks AKS:                        93/93 PASS
Hooks Schema Sync:                24/24 PASS
Total:                           689/689 PASS
```

Los dos casos nuevos del arnés de Pipelines comprueban expresamente un
transcript mayor de 25 MiB y un bloque aprobado con 21 comandos. Todas las
pruebas usan fixtures/dobles locales: no ejecutan Apply, no leen credenciales y
no realizan llamadas a Azure DevOps.

La suite offline verifica la decisión JSON de los hooks, pero no puede probar
por sí sola el renderizado de la tarjeta en la interfaz de Claude Code. La
comprobación end-to-end debe hacerse con una sesión principal nueva y un builder
nuevo; las tarjetas ya abiertas y los subagentes iniciados antes del cambio no
se actualizan retroactivamente.

## Consideraciones operativas

- Los planes aprobados antes de este cambio no contienen el bloque nuevo y
  continuarán mostrando `ask`. Deben presentarse nuevamente.
- El plan operativo y el inventario deben existir y estar validados antes
  de solicitar la aprobación de `ExitPlanMode`, porque sus hashes forman
  parte del alcance aprobado.
- El comando debe copiarse exactamente desde el plan. Incluso una variación
  aparentemente inocua produce `ask` por diseño.
- La autorización no es reutilizable para otro pipeline, aplicación,
  ambiente, familia o archivo. Un reintento del mismo comando solo se permite
  si el journal demuestra que ninguna escritura remota llegó a comenzar.
- Las prohibiciones anteriores del dominio se evalúan antes de esta
  excepción y permanecen intactas.
- El hook de preparación solo actúa cuando el builder utiliza una invocación
  directa con la herramienta `PowerShell`. Si vuelve a usar Bash, wrappers,
  rutas dinámicas o comandos compuestos, puede reaparecer una tarjeta por
  diseño.
- `acceptEdits` sigue siendo el modo esperado después de aprobar el plan para
  que `Edit`/`Write` no pidan confirmación dentro del workspace o del
  scratchpad adicional.
- Una sesión o subagente que ya estaba cargado antes del cambio puede conservar
  instrucciones anteriores. Iniciar una conversación nueva o reiniciar Claude
  Code garantiza que se cargue el contrato preparatorio vigente.
- Los scripts temporales arbitrarios no están incluidos en la allowlist. Si un
  flujo necesita ejecutar uno, debe convertirse en un helper versionado y
  revisado o tratarse como una acción fuera del alcance aprobado.
- La regla local histórica `Bash(powershell -Command ' *)` no fue creada por
  este cambio y permanece por compatibilidad. El nuevo enrutamiento evita
  utilizarla; retirarla requiere una limpieza separada con revisión de los
  demás dominios que comparten `settings.local.json`.

## Resultado esperado

Los comandos preparatorios equivalentes a las capturas deben dejar de mostrar
aprobaciones repetitivas cuando sigan el enrutamiento documentado. Las tarjetas
ya pendientes no se resuelven retroactivamente: hay que cancelar ese builder y
lanzar uno nuevo para comprobar el flujo actualizado.

- inventario, templates, variables, generación y validación: `PowerShell`
  directo, con fallback seguro de `PermissionRequest` si falla el matcher;
- lectura de JSON/YAML: `Read`/`Grep`;
- edición local: `Edit`/`Write` dentro del workspace o scratchpad adicional;
- hash: `Get-FileHash`;
- aplicación real: autorización heredada del bloque exacto aprobado.

Continúan preguntando o bloqueándose, por diseño:

- `Get-AdoClassicVariables.ps1 -RevealLocalSecrets`;
- un `Apply` sin autorización heredable, vencido o alterado, y cualquier
  reintento cuyo journal indique una escritura iniciada o un estado ambiguo;
- una operación distinta de la descrita en el plan;
- un script temporal o comando inline no incluido en la política;
- REST directo, lectura directa de credenciales o exposición del PAT;
- cualquier acción marcada como aprobación separada en
  `authorization.md` y `approval-matrix.md`.

## Sexta etapa: auditoría profunda posterior al fix (2026-08-28)

Se realizó una nueva revisión completa después de aplicar los cambios de la
quinta etapa. Esta auditoría fue de solo lectura: no modificó scripts, hooks,
agentes, settings ni recursos de Azure DevOps. Su objetivo fue confirmar si
quedaba alguna fuente adicional de tarjetas y establecer el mínimo real de
aprobaciones que puede alcanzar el diseño actual.

### Confirmación cronológica de las capturas de EMR

La transcripción local de la sesión `88368e03-0d00-4f4c-8b7f-829764c652ad`
confirmó que las tarjetas mostradas para:

- `Export-AdoClassicInventory.ps1`;
- `New-AdoClassicAksPlan.ps1`;
- `New-AdoClassicCreatePlan.ps1`;
- `New-AdoClassicUpdatePlan.ps1`;
- `Test-AdoClassicPlan.ps1`;
- `Show-AdoBuildSteps.ps1`;

ocurrieron con Claude Code `2.1.247`, antes de que estuvieran vigentes el hook
`ado-preparation-permission.ps1` y su registro definitivo en
`.claude/settings.json`. Por tanto, esas imágenes demuestran el comportamiento
anterior, pero no constituyen una reproducción del estado actual.

El entorno auditado ya usa Claude Code `2.1.248`. `claude doctor` no reportó
problemas de instalación y `claude plugin validate .claude/agents` confirmó que
el frontmatter de los agentes es válido.

### Simulación de los comandos observados

Se enviaron al hook `PermissionRequest`, como texto y sin ejecutarlos, tres
comandos con la misma forma que los observados en las capturas:

```text
Export-AdoClassicInventory.ps1 -> allow
New-AdoClassicAksPlan.ps1      -> allow
Test-AdoClassicPlan.ps1        -> allow
```

Los tres fueron reconocidos como una invocación directa, individual y literal
de un entrypoint versionado. El hook devolvió `decision.behavior = "allow"`.
Esta simulación confirma la decisión del hook actual, aunque la comprobación
final del renderizado de la interfaz sigue requiriendo una sesión nueva de
Claude Code.

### Revalidación completa

Se ejecutaron nuevamente las cinco suites offline sobre el árbol actual:

```text
Scripts Azure DevOps Pipelines: 413/413 PASS
Hooks Azure DevOps Pipelines:   124/124 PASS
Hooks Azure DevOps Permissions:  35/35 PASS
Hooks AKS:                        93/93 PASS
Hooks Schema Sync:                24/24 PASS
Total:                           689/689 PASS
```

Las pruebas de hooks solo clasificaron payloads JSON simulados. La suite de
scripts utilizó fixtures, dobles HTTP y directorios temporales. Ninguna prueba
ejecutó una operación real contra Azure DevOps ni leyó credenciales.

### Flujo confirmado como vigente

El builder continúa siendo exclusivamente preparatorio. Puede trabajar en
background, pero entrega a la sesión principal los planes, bodies, hashes y
comandos exactos. La sesión principal es la propietaria de `ExitPlanMode`, de
la aprobación y de todos los Apply enumerados.

Esta separación no se mantiene porque los subagentes carezcan de permisos del
padre. Claude Code aplica los settings y hooks de la sesión también a los
subagentes y muestra en la sesión principal las solicitudes de un subagente en
background. La razón específica de este diseño es que
`ado-permission-common.ps1` verifica el `transcript_path` de quien intenta el
Apply: un transcript aislado de subagente no contiene el `ExitPlanMode`
aprobado en el transcript principal.

Por ello, cambiar background por foreground no elimina tarjetas ni transfiere
la autorización del plan. El flujo correcto continúa siendo:

```text
builder prepara y valida
  -> sesión principal presenta ExitPlanMode
  -> usuario aprueba una vez
  -> sesión principal ejecuta todos los Apply exactos enumerados
  -> readback y reporte
```

### Cantidad de aprobaciones esperada en el estado actual

| Escenario | Aprobaciones esperadas |
|-----------|-------------------------|
| Inventario, generación, validación y readback mediante entrypoints reconocidos | 0 |
| Actualizar Build/Release existentes, sin secretos | 1 (`ExitPlanMode`) |
| Cada Apply exacto ya enumerado después de aprobar | 0 adicionales |
| Crear Libraries y después actualizar un Release que necesita sus IDs nuevos | 2 fases / 2 aprobaciones |
| Revelar secretos locales mediante `-RevealLocalSecrets` o materializar valores reales | +1 puntual |
| Encolar un Build, crear una ejecución de Release o desplegar | +1 separada por acción |
| Comando o recurso fuera del plan aprobado | +1 intencional |
| Desviación hacia Bash, `PowerShell -Command`, MCP no autorizado o script scratch | cantidad variable; puede aparecer una tarjeta por comando |

Por tanto, el caso normal sobre recursos ya existentes debe quedar en una sola
aprobación. Un flujo con IDs dependientes todavía requiere dos aprobaciones y
un flujo que además materialice secretos puede requerir tres.

### Hallazgos pendientes de corrección

Los siguientes puntos fueron identificados durante la auditoría, pero **no se
modificaron** como parte de esta etapa. Se documentan para una corrección
posterior controlada.

1. **`Bash` sigue expuesto al builder.**
   `.claude/agents/azure-devops/ado-pipeline-builder.md` declara
   `Read, Grep, Glob, Bash, PowerShell, Edit, Write`, aunque su contrato exige
   PowerShell directo. Retirar `Bash` reduciría el riesgo de volver a wrappers
   `Bash(powershell ...)`, comandos inline y tarjetas nativas fuera del hook
   preparatorio.

2. **`settings.local.json` conserva un historial muy amplio.**
   La auditoría contó 332 reglas `allow`: 248 relacionadas con Azure DevOps o
   sesiones de preparación, 116 ligadas a la sesión temporal `88368e03...` y
   86 autorizaciones de scripts scratch. También permanecen reglas amplias de
   `powershell -Command` y `node -e`. No son necesarias para el contrato nuevo
   y permiten que reaparezcan caminos operativos antiguos.

3. **Existe una escritura MCP autorizada permanentemente.**
   `mcp__azure-devops__wit_work_item_write` puede crear o modificar Work Items
   y hoy aparece en `permissions.allow`. Debe retirarse del permiso permanente
   para que una escritura fuera del plan vuelva a pedir aprobación.

4. **La cobertura MCP de solo lectura está incompleta.**
   Faltan permisos controlados para herramientas como
   `core_list_project_teams`, `repo_pull_request`,
   `repo_pull_request_thread`, `repo_search_commits`, `wit_query` y acciones
   puramente lectoras de `wit_backlog`/`pipelines_artifact`. La solución segura
   es un clasificador `PermissionRequest` por nombre de herramienta y acción;
   nunca un wildcard `mcp__azure-devops__*`, porque incluiría escrituras.

5. **Falta un entrypoint ejecutable para environments de Release.**
   El builder debe usar `New-AdoReleaseEnvironmentEntry`, pero hoy esa
   capacidad solo existe como función dentro de
   `New-AdoClassicPayloads.ps1`. No existe un wrapper `.ps1` ejecutable que el
   builder pueda invocar sin dot-sourcing. Esta brecha puede detener el flujo o
   empujar al modelo hacia un comando inline/script scratch, que vuelve a
   generar aprobaciones.

6. **`ado-security-gate.ps1` conserva una implementación histórica muerta.**
   El archivo todavía contiene la versión local antigua de la autorización
   (8 horas y máximo de 20 comandos) y después carga
   `ado-permission-common.ps1`, que la reemplaza con el contrato vigente de 24
   horas y sin límite artificial. Hoy no afecta el runtime, pero debe
   eliminarse para evitar una regresión futura.

7. **La dependencia de IDs nuevos todavía obliga a dos fases.**
   Cuando el Release necesita IDs de Variable Groups que aún no existen, el
   plan exacto del Release no puede hashearse antes de crearlos. Reducir ese
   escenario de dos aprobaciones a una exige una mejora mayor del motor de
   planes: referencias simbólicas resueltas dentro del mismo Apply aprobado.
   No es una simple modificación de permisos.

### Orden recomendado para una siguiente corrección

1. Retirar `Bash` del builder y eliminar la autorización permanente de
   `wit_work_item_write`.
2. Depurar las reglas históricas/scratch de `settings.local.json`, conservando
   solo permisos vigentes y verificables.
3. Crear el wrapper versionado para environments de Release y cubrirlo con el
   hook/test preparatorio.
4. Agregar autorización MCP de solo lectura con clasificación por acción.
5. Eliminar las funciones históricas duplicadas de
   `ado-security-gate.ps1`.
6. Ejecutar una prueba end-to-end desde una sesión nueva antes de considerar
   cerrada la reducción de tarjetas.
7. Evaluar por separado referencias simbólicas si se desea que los flujos con
   IDs dependientes también tengan una sola aprobación.

### Referencias oficiales verificadas

- Claude Code Permissions:
  <https://code.claude.com/docs/en/permissions>
- Claude Code Hooks:
  <https://code.claude.com/docs/en/hooks>
- Claude Code Subagents:
  <https://code.claude.com/docs/en/sub-agents>
- Toolset oficial del Azure DevOps MCP:
  <https://github.com/microsoft/azure-devops-mcp/blob/main/docs/TOOLSET.md>

Esta sexta etapa solamente documenta y valida el estado. Ninguno de los siete
hallazgos pendientes se presenta como ya aplicado.
