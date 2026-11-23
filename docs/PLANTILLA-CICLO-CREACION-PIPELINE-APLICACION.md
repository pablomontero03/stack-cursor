# Plantilla coordinada para crear y validar un pipeline de aplicación

## Datos que debe completar el usuario

Este bloque es la **única fuente de verdad para los datos que cambian entre aplicaciones**. Antes de iniciar un ciclo nuevo, modificar únicamente los valores dentro de `INPUT`. El resto del documento los referencia con rutas lógicas como `INPUT.repository.url`; esas rutas no son variables de PowerShell ni requieren interpolación: el coordinador debe resolverlas desde este bloque, conservarlas en el plan y no sustituirlas con valores encontrados en una plantilla histórica.

```yaml
INPUT:
  application:
    id: app-directory
    type: auto                 # auto | api | web | database

  repository:
    organization: Shared-Service-GM
    project: Buklo
    name: buklo-web
    url: 'https://dev.azure.com/Shared-Service-GM/Buklo/_git/buklo-web?version=GBdevelopment&path=/apps/app-directory'
    path: /apps/app-directory
    branches:
      development: development
      uat: uat
      production: release

  azure_devops:
    project: DevOps
    pipeline_folder: '\buklo'
    pipeline_folder_url: 'https://dev.azure.com/Shared-Service-GM/DevOps/_build?definitionScope=%5Cbuklo'
    canonical_exports_directory: 'D:\Proyectos\automation\docs\azure-devops'
    build_export_candidates:
      - Build-moldelo.json
      - Build-modelo.json
    release_export: Release-modelo.json
    secret_sources:
      container_registry_password:
        environment_variable: ADO_SECRET_CONTAINERREGISTRYPASSWORD
        target_name: resolve_from_canonical_model

  application_variables:
    image: app-directory-web
    appname_candidate: app-directory

  manifests:
    development: ./deployment-dev.yml
    uat: ./deployment-uat.yml
    production: ./deployment-prod.yml

  environments:
    development:
      namespace: desarrollo
      dns:
        fqdn: app-directory-web-dev.gmontecristo.com
        type: A
        ip: 177.93.30.165
        proxied: false
        ttl: auto
      cluster_candidate: discover
      node_selector: inherit

    uat:
      namespace: uat
      dns:
        fqdn: app-directory-web-uat.gmontecristo.com
        type: A
        ip: 177.93.30.165
        proxied: false
        ttl: auto
      cluster_candidate: discover
      node_selector: inherit

    production:
      namespace: apps-web
      dns:
        fqdn: app-directory-web.grupomontecristo.com
        type: A
        ip: 20.161.149.127
        proxied: false
        ttl: auto
      cluster_candidate: gmon-prod-aks-eastus2-0004
      node_selector:
        agentpool: userpool03

  discovery:
    cluster_validation_before_plan: minima     # preguntar | completa | minima | omitir

  execution:
    max_automatic_configuration_retries_per_environment: 2
    status_poll_interval_seconds: 120
    build_wait_timeout_minutes: 60
    release_wait_timeout_minutes: 60
    rollout_wait_timeout_minutes: 20
    aks_capacity_validation_max_age_seconds: 300
    record_phase_timings: true
    run_development_after_plan_approval: true
    run_uat_after_development_success: true
    prepare_production: true
    production_requires_separate_approval: true
    allow_application_code_changes: false
    allow_deletions: false
```

### Modos de validación AKS antes del plan

Interpretar `INPUT.discovery.cluster_validation_before_plan` así:

| Valor | Comportamiento antes de presentar el plan |
|---|---|
| `preguntar` | Formular al inicio una sola pregunta para elegir `completa`, `minima` u `omitir`. Mientras llega la respuesta, continuar las demás consultas de solo lectura. No quedarse esperando indefinidamente a un subagente. |
| `completa` | Consultar en vivo clústeres, contextos, namespaces, ingress IPs, node pools, labels, capacidad, recursos comparables y demás evidencia AKS necesaria. |
| `minima` | Consultar únicamente lo necesario para validar los destinos declarados, namespaces, ingress IPs, node pools/selectors y capacidad inmediata para completar el rollout. Es el valor recomendado y predeterminado. |
| `omitir` | No consultar clústeres durante la preparación del plan. Utilizar código, exports e inventarios locales y marcar como `Pendiente de validación previa al despliegue` toda afirmación que dependa del estado real de AKS. La omisión no debe bloquear las secciones de código, Azure DevOps o Cloudflare. |

Si el valor es inválido, hacer una sola pregunta al inicio. Si el usuario no responde, continuar produciendo un plan parcial y marcar únicamente la sección AKS como pendiente; no afirmar que el clúster fue validado.

La elección anterior afecta solo el **descubrimiento previo al plan**. Inmediatamente antes de cualquier despliegue real siempre se debe ejecutar una verificación mínima, de solo lectura y sin aprobación adicional, para confirmar:

- Suscripción, clúster y contexto objetivo.
- Namespace objetivo.
- IP o ingress objetivo cuando aplique.
- Existencia y compatibilidad del node pool/selector cuando aplique.
- Capacidad de pods por nodo: pods no terminales asignados, `allocatable.pods`/`maxPods` y margen restante.
- Capacidad temporal requerida por la estrategia de rollout (`replicas`, `maxSurge` y `maxUnavailable`). Con `maxUnavailable: 0`, comprobar que pueda programarse al menos el pod adicional requerido antes de retirar la versión anterior.
- Pods `Pending`, eventos recientes de scheduling y causas como `Too many pods`, recursos insuficientes, taints o afinidad incompatible.
- CPU y memoria solicitadas frente a capacidad asignable cuando los datos estén disponibles.
- Permisos efectivos necesarios mediante `kubectl auth can-i` o equivalente.
- Que el destino no cambió respecto del plan aprobado.

Si esa verificación contradice el plan, detener únicamente la operación afectada y presentar el cambio requerido. Nunca desplegar en un destino distinto por inferencia.

## Ruta rápida segura

Reducir el tiempo sin omitir controles mediante estas reglas:

1. Ejecutar en paralelo las consultas independientes de Azure DevOps, ramas/código, Cloudflare y AKS. Ninguna escritura se ejecuta en paralelo.
2. Asignar una única fuente responsable para cada inventario y compartir su resultado sanitizado con los demás agentes. No repetir la misma consulta de Variable Groups, Service Connections, exports, zonas DNS o inventario AKS desde varios agentes.
3. Crear al inicio un snapshot con hashes de exports, commits de ramas, revisiones de definiciones e IDs de recursos consultados.
4. Reutilizar dentro del mismo ciclo únicamente evidencia estática cuyo hash, commit o revisión siga coincidiendo. Si cambió, consultar y validar nuevamente.
5. Nunca reutilizar como vigente la capacidad dinámica de AKS. Antes de escribir, la comprobación de capacidad debe tener una antigüedad máxima de `INPUT.execution.aks_capacity_validation_max_age_seconds`; si es más antigua, refrescarla.
6. Agrupar consultas de solo lectura cuando la API permita obtener los mismos datos en una sola llamada o lote, sin ampliar el alcance.
7. Iniciar la revisión de cada sección apenas esté disponible; los reviewers no deben esperar a que todos los demás agentes terminen para comenzar.
8. Si un agente tarda, solicitarle un resultado parcial con hechos confirmados y pendientes. Continuar las demás secciones y no repetir su investigación desde cero.
9. Fallar rápido dentro de la sección afectada: un error de rama no detiene DNS o el análisis del modelo, pero sí impide ejecutar esa rama.
10. No repetir pruebas, diffs o inventarios cuando sus entradas y hashes no hayan cambiado. Registrar la reutilización y la evidencia que demuestra que sigue siendo válida.

Esta ruta rápida no permite saltar la revisión independiente, la verificación del destino, la capacidad AKS reciente, los secretos requeridos, el dry-run del generador ni el readback posterior.

## Cómo interpretar esta solicitud

Esta solicitud es un **manifiesto de sobrescrituras**, no una definición completa del pipeline.

Regla fundamental:

> Cambia únicamente los valores declarados explícitamente o aquellos que deban adaptarse como consecuencia demostrable del código, del repositorio o del ambiente. Todo lo demás debe heredarse y conservarse de los exports canónicos ubicados en `D:\Proyectos\automation\docs\azure-devops`.

No reduzcas una definición existente únicamente a los campos presentes en esta plantilla. No elimines tareas, variables, opciones, triggers, artifacts, Variable Groups, Service Connections, Task Groups, aprobaciones, retención, demandas, pools o configuraciones que la plantilla no mencione.

Clasifica cada dato encontrado como:

| Clasificación | Tratamiento |
|---|---|
| Explícito | Valor indicado en esta solicitud; debe aplicarse. |
| Heredado | Se conserva exactamente de los exports canónicos de Build y Release, salvo incompatibilidad demostrada. |
| Derivado | Se obtiene del código, manifiestos, clúster o configuración real. |
| Protegido | No se elimina, cambia ni inventa sin una necesidad confirmada y aprobación correspondiente. |
| Pendiente | No puede inferirse con seguridad; debe aparecer claramente en el plan. |

Los valores explícitos tienen prioridad sobre los exports canónicos. Los datos derivados deben presentar evidencia. Los datos heredados deben indicar el archivo y campo de origen.

## Objetivo de esta ejecución

Crear el ciclo completo de CI/CD para `INPUT.application.id`, incluyendo:

1. Validación del código, clasificación de la aplicación y carga de los exports canónicos.
2. Creación o validación de DNS en Cloudflare.
3. Creación de las definiciones clásicas necesarias en Azure DevOps.
4. Generación de manifiestos `deployment-dev.yml`, `deployment-uat.yml` y `deployment-prod.yml` mediante File Creator.
5. Ejecución y validación de Desarrollo.
6. Ejecución y validación de UAT.
7. Preparación de Producción.
8. Ejecución de Producción únicamente después de su aprobación separada.

No modificar código de la aplicación durante este ciclo. Si el fallo está en el código, detener la corrección automática y reportarlo con evidencia.

## Uso de los datos explícitos

Los datos explícitos se leen exclusivamente de `INPUT`. Al iniciar, el coordinador debe validar en una sola pasada que estén presentes y que no existan contradicciones internas. Si falta un dato imprescindible, agrupar todos los faltantes en una sola pregunta; no preguntar campo por campo.

Si un nombre derivado del código, de una convención o de un export difiere del valor declarado en `INPUT`, no sustituirlo silenciosamente. El plan debe incluir una trazabilidad explícita:

| Concepto | Valor solicitado en `INPUT` | Valor propuesto | Evidencia | Acción |
|---|---|---|---|---|
| Ejemplo: DNS, imagen, app name, Build, Release o recurso Kubernetes | Valor original | Valor derivado | Código/export/convención | Conservar o sustituir |

El valor propuesto solo puede utilizarse si aparece en el plan aprobado. Después de la aprobación, cualquier cambio adicional de FQDN, IP, imagen, nombre de aplicación, repositorio, rama, clúster, namespace o node pool queda fuera del plan y requiere replanificación.

La ubicación del repositorio se resuelve desde `INPUT.repository`. La carpeta `INPUT.azure_devops.pipeline_folder` define el destino y puede utilizarse para validar la convención de nombres, pero **no determina el pipeline modelo**. No copiar automáticamente una definición de esa carpeta: puede contener pipelines antiguos, especializados o manifiestos YAML simplificados que no corresponden al estándar actual.

El nombre final del Build, Release y Task Group debe seguir la convención vigente de `INPUT.azure_devops.pipeline_folder`, sin heredar por ello la estructura de un pipeline arbitrario de esa carpeta. Presentar los nombres propuestos en el plan.

### Fuentes canónicas de Build y Release

Utilizar obligatoriamente los exports locales de `INPUT.azure_devops.canonical_exports_directory`. Resolver el Build en el orden declarado en `INPUT.azure_devops.build_export_candidates` y utilizar el Release indicado en `INPUT.azure_devops.release_export`.

Primero listar la carpeta y resolver el nombre exacto existente. Si solo existe el candidato alternativo de Build, utilizarlo y documentar la diferencia ortográfica; no crear un duplicado ni renombrarlo sin autorización. Si falta cualquiera de los dos exports, detener la preparación del payload y reportar el archivo faltante.

Reglas:

- Estos JSON son las fuentes canónicas para la estructura completa del Build y Release.
- Leerlos localmente; no volver a consultar el pipeline histórico como fuente principal.
- No modificar, sobrescribir ni sanitizar los exports originales durante esta tarea.
- Validar que sean JSON completos, coherentes entre sí y que no contengan valores secretos visibles.
- Si aparece un secreto visible, no mostrarlo; reportar únicamente archivo y campo, y detener su utilización hasta que exista una copia sanitizada.
- Conservar del export todas las propiedades compatibles que no deban cambiar.
- Sustituir IDs y referencias que obligatoriamente deben apuntar al nuevo Build, Release, artifact o recurso.
- La carpeta de destino se puede consultar para nombres y compatibilidad, nunca para reemplazar silenciosamente estos modelos.

Los exports provienen de una API con estructura suficientemente completa. Deben servir como base robusta tanto para nuevas APIs como para nuevos sitios web, aplicando la clasificación y adaptación indicadas a continuación.

### Clasificación obligatoria del tipo de aplicación

Antes de generar cualquier plan, revisar `INPUT.application.type`. Si es `auto`, clasificar el contenido de `INPUT.repository.path` como exactamente uno de estos tipos; si contiene `api`, `web` o `database`, confirmar que el código sea compatible con la selección explícita y reportar cualquier contradicción:

| Tipo | Estado actual | Tratamiento |
|---|---|---|
| `api` | Soportado | Adaptar los modelos canónicos a una API, conservando toda la estructura compatible. |
| `web` | Soportado | Adaptar los mismos modelos a un sitio web/frontend y retirar únicamente elementos exclusivos de API que sean incompatibles. |
| `database` | No soportado todavía | Detenerse: no reutilizar los modelos de aplicación. Esperar los exports específicos de base de datos. |
| `unknown` | No soportado | Presentar evidencia y solicitar aclaración antes del plan. |

La clasificación debe basarse en evidencia combinada:

- `package.json`, proyectos, frameworks y scripts.
- Dockerfile, comando de arranque y puertos.
- Presencia de frontend compilado, servidor web, API routes o controladores.
- Configuración de ingress y rutas.
- Aplicaciones comparables dentro del mismo monorepo.

No clasificar únicamente por el nombre del repositorio o carpeta.

Para `api`:

- Conservar tareas, manifiestos y patrones aplicables del modelo.
- Validar todos los endpoints, puertos, sondas, Services, RBAC y métricas.
- No asumir que esta API usa exactamente las mismas rutas que la API exportada.

Para `web`:

- Conservar build, artifact, seguridad, variables comunes, conexiones, publicación, Release y estructura Kubernetes que sigan siendo compatibles.
- Adaptar el build context, comandos, archivos generados, puertos, Services, Ingress y sondas al frontend real.
- Omitir únicamente tareas o recursos exclusivos de una API cuando exista evidencia de incompatibilidad.
- No simplificar el pipeline solo porque sea un sitio web.
- Documentar cada exclusión respecto de los exports canónicos.

Para `database`:

- No utilizar los exports declarados para Build y Release en `INPUT.azure_devops` como base.
- No intentar adaptar una plantilla de API o web.
- Informar que todavía no existe una plantilla canónica de base de datos.
- Cuando el usuario agregue los exports futuros, incorporarlos como una categoría separada sin mezclar sus tareas, artifacts, aprobaciones o flujo con aplicaciones.

### DNS de Cloudflare

Crear o reutilizar los registros declarados bajo `INPUT.environments.<ambiente>.dns`. No aceptar un FQDN, IP, tipo, proxy o TTL obtenido de otra fuente como sustitución silenciosa de estos valores explícitos.

Para cada registro:

- Determinar la zona correcta por el FQDN.
- Utilizar el nombre relativo o FQDN según lo exija la API, sin cambiar el resultado final.
- En la API de Cloudflare, representar TTL Auto con el valor admitido por la API vigente.
- Mantener `proxied=false`.
- Usar como comentario el nombre real del clúster correspondiente al ambiente.
- Utilizar `INPUT.environments.<ambiente>.cluster_candidate` como candidato para el comentario, nunca como confirmación del clúster real.
- Si la validación AKS previa es `completa` o `minima`, obtener el clúster real antes de fijar el comentario. Si es `omitir`, dejar el comentario pendiente en el plan y resolverlo en la verificación mínima previa al despliegue; esto no debe bloquear la preparación del DNS.

Si un registro ya existe:

- Si tipo, IP y proxy coinciden, reutilizarlo y no recrearlo.
- Si difiere, mostrar el conflicto en el plan.
- No sobrescribir silenciosamente un registro existente.
- No crear registros duplicados.
- Ninguna eliminación de DNS forma parte de esta solicitud.

### Variables por ambiente

Los valores explícitos se obtienen de `INPUT.application_variables` y `INPUT.environments.<ambiente>.namespace`.

No asumir que los nombres reales de variables sean exactamente `image`, `appname` y `namespace`. Revisar los exports canónicos y mapear estos conceptos a los nombres y mayúsculas utilizados realmente, por ejemplo `IMAGE`, `APP_NAME`, `SERVICE_NAME` o equivalentes.

Validar `INPUT.application_variables.appname_candidate` antes de fijar `appname`:

- Buscar el nombre en el código y configuración de la aplicación.
- Comparar con aplicaciones similares del monorepo.
- Revisar Services, Deployments, Ingress y configuración actual del clúster.
- Revisar las variables y sustituciones de los exports canónicos.
- Confirmar que el nombre cumple la convención utilizada por Azure DevOps, ACR y Kubernetes.

Si el sistema requiere otra forma, proponerla en el plan con evidencia. No cambiarla silenciosamente.

Todas las demás variables deben heredarse de los exports canónicos y validarse. Esto incluye variables con valores compartidos entre aplicaciones y ambientes.

Para secretos:

- Reutilizar Variable Groups, Key Vault, Kubernetes Secrets o Service Connections existentes.
- Para la contraseña del Container Registry, utilizar la fuente declarada en `INPUT.azure_devops.secret_sources.container_registry_password.environment_variable` y resolver el nombre de destino desde el modelo canónico.
- Si esa variable de entorno está disponible en el proceso actual, utilizarla internamente sin solicitar aprobación ni pedir nuevamente su valor.
- Comprobar únicamente presencia/no presencia; nunca imprimir, devolver, registrar ni comparar el valor en texto visible.
- Recordar que una variable creada con `setx` solo aparece en procesos nuevos. Si no está visible, solicitar reiniciar la terminal o la sesión de Claude/Cursor una sola vez y volver a comprobarla; no pedir que el usuario escriba el secreto en el chat.
- No intentar recuperar valores secretos que Azure DevOps no permite volver a mostrar.
- No imprimir, copiar ni guardar secretos en planes, logs, journals, memorias o documentación.
- No solicitar nuevamente un secreto si puede reutilizarse una referencia existente.
- Si falta un secreto imprescindible, reportar únicamente su nombre y fuente esperada.

## Validación de los modelos canónicos

El agente de Azure DevOps debe cargar y comparar el Build resuelto desde `INPUT.azure_devops.build_export_candidates` y el Release indicado por `INPUT.azure_devops.release_export` antes de consultar definiciones en la carpeta destino.

Validar al menos:

- Relación entre Build, artifact y Release.
- Referencias históricas que deban sustituirse.
- Repositorio, ruta, ramas y triggers.
- Dockerfile, build context y package manager esperados.
- Estrategia de tags e imagen ACR.
- Agent pool y demands.
- Task Groups y revisiones.
- Variable Groups y Key Vault.
- Service Connections.
- Artifacts y nombres de artifact.
- File Creator y manifiestos generados.
- Build options, retención y permisos de cola.
- Ambientes, condiciones y aprobadores del Release clásico.
- Clústeres, namespaces e ingress referenciados.
- Campos específicos de API que deban adaptarse si la aplicación es `web`.

### Matriz obligatoria de conservación del modelo

Antes de construir el payload, comparar el modelo canónico y la definición propuesta campo por campo. La revisión debe incluir todas las tareas, incluso las deshabilitadas, y detectar al menos:

- Variables utilizadas por tareas o sustituciones, incluyendo `appname` o su nombre real equivalente.
- Tareas de reemplazo de tokens, sintaxis de tokens, rutas objetivo y orden respecto de File Creator.
- Que cada token consumido tenga una fuente definida y que no queden tokens sin resolver.
- Tareas File Creator, archivos producidos y contenido por ambiente.
- Orden, versión, estado habilitado/deshabilitado y entradas relevantes de cada tarea.
- Variable Groups, nombres de secretos y referencias, sin mostrar valores secretos.
- Task Groups, Service Connections, agent pools, demands, artifacts, triggers y condiciones.

El plan debe presentar una matriz resumida como esta:

| Elemento del modelo | Conservado | Adaptado | Excluido | Evidencia o justificación |
|---|---:|---:|---:|---|
| Variables | Sí/No | Detalle | Detalle | Export/código |
| Reemplazo de tokens | Sí/No | Detalle | Detalle | Tokens y archivos consumidores |
| File Creator | Sí/No | Detalle | Detalle | Manifiestos generados |
| Tareas restantes | Sí/No | Detalle | Detalle | Compatibilidad demostrada |
| Variable Groups y conexiones | Sí/No | Detalle | Detalle | Referencias sanitizadas |
| Artifact y vínculo con Release | Sí/No | Detalle | Detalle | IDs/referencias nuevas |

No considerar validado el Build si falta una variable o una tarea que el manifiesto generado consume, aunque el JSON propuesto sea sintácticamente válido.

### Preflight obligatorio de ramas

Validar en paralelo todas las ramas declaradas antes de ejecutar el primer Build. Para cada rama confirmar, sin modificarla:

- Que la rama existe y resolver su commit actual.
- Que existe `INPUT.repository.path` en ese commit.
- Que existen Dockerfile, archivos de proyecto, lockfile y archivos requeridos por las tareas del modelo.
- Que los scripts de build/start referenciados existen.
- Que las rutas usadas por File Creator y reemplazo de tokens corresponden al contenido de esa rama.

Registrar el commit validado por ambiente. Inmediatamente antes de ejecutar el Build, confirmar que la rama sigue apuntando al mismo commit; si cambió, repetir únicamente su validación. Si el código o la ruta no existen en `uat` o Producción, clasificarlo como problema de rama/código, no crear un PR ni modificar código automáticamente y no consumir una ejecución que se sabe inviable.

### Preflight obligatorio de variables y secretos

Construir una sola matriz consolidada a partir del modelo, tareas, manifiestos y código:

| Nombre lógico | Nombre real | Consumidor | Ambiente | Secreto | Fuente | Estado |
|---|---|---|---|---:|---|---|

- Confirmar que toda variable consumida esté definida o derivada con evidencia.
- Confirmar por nombre y referencia la existencia de cada secreto obligatorio, sin leer ni mostrar su valor.
- Tratar la contraseña del Container Registry como obligatoria cuando una tarea o conexión ACR la consuma. Su fuente aprobada es `INPUT.azure_devops.secret_sources.container_registry_password.environment_variable`; mapearla al nombre real requerido por el modelo, por ejemplo `containerRegistryPassword` o `SECRET_CONTAINERREGISTRYPASSWORD`, sin preguntar por el valor cuando la variable de entorno exista.
- El script Apply o helper controlado debe leerla directamente del entorno y mantenerla únicamente en memoria. No pasarla como argumento de línea de comandos, no incorporarla al archivo del plan y no mostrarla en errores.
- Si la variable no aparece en el proceso actual después de haber sido creada con `setx`, indicar que se reinicie la terminal/sesión y reintentar la comprobación. No clasificarla inmediatamente como secreto faltante ni solicitar su contenido.
- Reutilizar Variable Groups, Key Vault o Service Connections aprobados antes de pedir un secreto nuevo.
- Agrupar todos los faltantes en una sola presentación antes del Apply.
- No iniciar el Apply ni un Build si falta una variable o referencia secreta imprescindible conocida.

### Dry-run del generador con forma real

Antes del Apply real, ejecutar el generador con mocks y una copia sanitizada que conserve la misma forma y tipos del plan real:

- Probar objetos `Hashtable`, `OrderedDictionary`, arrays y objetos deserializados que realmente atraviesen el código.
- No asumir que métodos como `.ContainsKey()` existen en todas las colecciones; utilizar operaciones compatibles o normalizar el tipo explícitamente.
- Generar Build, Variable Groups y Release simulados completos.
- Validar JSON, referencias cruzadas, tokens, variables, orden de tareas y hashes.
- Confirmar cero llamadas POST, PUT, PATCH o DELETE durante la prueba.

Si el dry-run falla, corregir el generador y repetir únicamente las pruebas afectadas antes de solicitar o consumir la aprobación del Apply.

### Contrato del comando Apply

Cuando sea necesario presentar o ejecutar un comando Apply:

- Construirlo una sola vez a partir del plan aprobado y validarlo antes de mostrarlo o ejecutarlo.
- Entregarlo en un único bloque copiable, completo y sin fragmentos que deban concatenarse manualmente.
- No anteponer `!` salvo que la interfaz activa requiera expresamente ese prefijo; PowerShell y Bash normales no lo requieren.
- Incluir ruta del script, plan, hash y parámetros obligatorios.
- No incluir valores secretos en el comando. Para la contraseña del Container Registry, el Apply debe leer `INPUT.azure_devops.secret_sources.container_registry_password.environment_variable` desde el proceso actual.
- No pedir al usuario que reconstruya parámetros desde varios mensajes.
- Antes de ejecutarlo, comprobar que el comando resuelve el mismo plan y hash aprobados.
- Una ejecución incompleta o con parámetros ausentes no consume autorización para improvisar otro alcance; corregir el comando y mantener el mismo plan cuando la intención no cambie.

El plan debe indicar:

- Rutas y hashes de ambos exports canónicos.
- Clasificación final `api` o `web` y evidencia.
- Campos heredados de cada export.
- Campos sustituidos por datos explícitos.
- Campos adaptados por evidencia del código o ambiente.
- Campos excluidos y la razón técnica.
- Referencias cruzadas que apuntarán a recursos nuevos.
- Confirmación de que los exports originales no serán modificados.

Las definiciones existentes dentro de `INPUT.azure_devops.project` y `INPUT.azure_devops.pipeline_folder` se consultan únicamente para validar nombres, disponibilidad de recursos compartidos y compatibilidad actual. No son candidatos alternativos al modelo salvo que el usuario lo autorice mediante un plan nuevo.

## Contrato de preservación

Salvo cambio explícito o incompatibilidad demostrada, conservar:

- Tipo de pipeline clásico.
- Opciones y propiedades de la definición.
- Checkout y configuración del repositorio.
- Task Groups y sus revisiones.
- Orden, versión y configuración de tareas.
- Agent pool, demands y capacidades.
- Triggers y filtros que sí correspondan al nuevo pipeline.
- Variables comunes.
- Variable Groups y referencias a Key Vault.
- Service Connections.
- Estrategia de autenticación.
- Convención de imagen y tags.
- Artifact name, tipo y publicación.
- Release artifact y vínculo con el Build nuevo.
- Ambientes, condiciones y retención.
- Aprobadores de Producción cuando exista un patrón confirmado.
- Timeouts, retries y opciones de ejecución.

No conservar IDs que deban apuntar al recurso nuevo. Adaptar referencias cruzadas, nombres, repositorio, rutas, branches, artifacts y definition IDs sin perder el resto de la configuración.

## Análisis del código

Antes de diseñar las tareas y manifiestos, revisar en `INPUT.repository.path`:

- `package.json` y scripts de build/start.
- Lockfile y package manager.
- Dockerfile y build context.
- Archivos de configuración del framework.
- Variables de entorno declaradas, sin mostrar secretos.
- Puerto real de escucha.
- Endpoints de health, readiness y liveness.
- Endpoint de métricas, si existe.
- Rutas base y prefijos.
- Dependencias que accedan a Kubernetes API.
- Necesidad de volúmenes y rutas montadas.
- Requisitos de usuario, filesystem y permisos.
- Referencias a ConfigMaps, Secrets o ServiceAccount.

No asumir que un frontend o API similar tiene los mismos puertos o sondas. La evidencia del código tiene prioridad sobre los exports canónicos en los campos incompatibles.

## File Creator y manifiestos

Configurar las tareas File Creator correspondientes para generar:

- `INPUT.manifests.development`
- `INPUT.manifests.uat`
- `INPUT.manifests.production`

No simplificar los manifiestos al contenido listado en esta plantilla. Partir de los manifiestos contenidos en los exports canónicos y conservar todos los recursos y campos compatibles con el tipo `api` o `web` detectado.

### Recursos RBAC

Validar si corresponden:

```yaml
apiVersion: v1
kind: ServiceAccount
```

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
```

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
```

Incluirlos únicamente si existe evidencia de que:

- La aplicación consulta o modifica la API de Kubernetes.
- El manifiesto necesita una identidad dedicada por una razón confirmada.
- El patrón organizacional exige RBAC para este tipo de workload.
- Existen permisos mínimos claramente identificados.

No copiar permisos amplios por costumbre. No crear `ClusterRole` ni `ClusterRoleBinding` si un `Role` de namespace es suficiente. Si no se necesitan, omitir los tres recursos y documentar la validación.

### Volúmenes

Validar conjuntamente:

- `volumes`.
- `volumeMounts`.
- ConfigMap o Secret referenciado.
- Ruta dentro del contenedor.
- Existencia y permisos del archivo o directorio.
- Compatibilidad con filesystem de solo lectura, si aplica.

No implementar un `volumeMount` aislado sin su volumen y fuente correspondientes.

### Puertos y sondas

Validar todos estos valores como un conjunto:

- Puerto escuchado por la aplicación.
- Dockerfile `EXPOSE`, si existe.
- `containerPort`.
- Service `port` y `targetPort`.
- Ingress/backend port.
- Startup, readiness y liveness probes.
- Puerto y ruta de métricas.

Las sondas deben apuntar a rutas realmente implementadas y retornar un estado compatible. Si no existe endpoint HTTP adecuado, proponer el tipo de sonda seguro que siga el patrón existente, sin inventar una ruta.

### Node selector

En Producción utilizar el selector declarado en `INPUT.environments.production.node_selector`.

Antes de aplicarlo, el agente AKS debe confirmar:

- Que el clúster de Producción es el correcto.
- Que existe el node pool declarado en `INPUT.environments.production.node_selector`.
- Que los nodos tienen la etiqueta esperada.
- Que están Ready y son schedulables.
- Que arquitectura, taints, tolerations y capacidad son compatibles.

No aplicar automáticamente el selector de Producción a Desarrollo o UAT. Para esos ambientes utilizar su `INPUT.environments.<ambiente>.node_selector`: heredar o derivar cuando el valor sea `inherit`.

### Prometheus

No implementar estas anotaciones salvo que corresponda:

```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "3000"
  prometheus.io/path: "/api/v1/metrics"
```

Solo incluirlas si:

- El código expone realmente el endpoint.
- Puerto y ruta son correctos.
- El sistema de monitoreo del clúster utiliza estas anotaciones.
- No existe ya un ServiceMonitor, PodMonitor u otro mecanismo que las vuelva redundantes.

Después del despliegue, validar que el endpoint responde sin exponer datos sensibles.

## Coordinación de agentes

El agente principal actuará como coordinador. Debe utilizar los agentes especializados existentes; no reemplazarlos ni duplicarlos.

### Fase de descubrimiento en paralelo

Ejecutar simultáneamente trabajos de solo lectura:

1. `ado-pipeline-builder`: validar una sola vez los exports canónicos; analizar Build/Release, Task Groups, variables, secretos por referencia, artifacts y manifiestos; preparar la matriz de conservación y el dry-run del generador.
2. `cloudflare-diagnoser` o `cloudflare-operator` en modo lectura: validar zonas, registros existentes, IPs, proxy, TTL y comentarios.
3. `aks-diagnoser`: actuar según `INPUT.discovery.cluster_validation_before_plan`. En `completa`, validar clústeres, namespaces, ingress IPs, node pools, labels, capacidad y recursos comparables; en `minima`, limitarse a los destinos declarados; en `omitir`, no iniciarlo antes del plan y marcar la evidencia AKS pendiente.
4. Agente de análisis de código disponible: validar simultáneamente las ramas declaradas, existencia de la subruta, framework, Dockerfile, scripts, puertos, sondas, métricas, volúmenes y necesidad de RBAC.

Los agentes pueden compartir resultados sanitizados mediante el coordinador. No deben modificar recursos durante esta fase. Ningún resultado AKS debe bloquear indefinidamente los resultados de Azure DevOps, Cloudflare o análisis de código; el coordinador debe consolidar lo disponible y distinguir claramente lo confirmado de lo pendiente.

### Fase de revisión

Los reviewers correspondientes deben revisar sus secciones de manera incremental tan pronto como el coordinador entregue sus entradas, sin esperar innecesariamente el cierre de todos los agentes:

- `ado-pipeline-reviewer`: definiciones, herencia, payloads, branches y artifacts.
- `cloudflare-reviewer`: DNS, zonas, conflictos e impacto.
- `aks-reviewer`: manifiestos, namespaces, scheduling, RBAC, sondas y readback.

El coordinador debe resolver inconsistencias y generar un solo plan consolidado. Ningún subagente concede la aprobación; la aprobación pertenece al usuario.

### Fase de aplicación

Después de la aprobación, realizar escrituras de manera serializada y respetando dependencias. No ejecutar en paralelo cambios sobre DNS, definiciones o despliegues relacionados.

## Plan consolidado y aprobaciones

Antes de cualquier escritura, presentar un plan único que incluya:

- Rutas y hashes de los exports canónicos de Build y Release.
- Clasificación `api` o `web` y evidencia.
- Nombre y ubicación del Build nuevo.
- Nombre y ubicación del Release nuevo.
- Task Groups reutilizados o creados.
- Repositorio, subruta y ramas.
- Variable Groups, Key Vault y Service Connections.
- Variables heredadas, cambiadas, derivadas y pendientes.
- DNS por ambiente y estado actual.
- Clúster, contexto y namespace por ambiente, indicando `confirmado`, `candidato` o `pendiente` según el modo de validación AKS elegido.
- Recursos Kubernetes por ambiente.
- Puertos, sondas, volúmenes, RBAC, selectors y métricas.
- Secuencia de creación y ejecución.
- Intervalo y tiempos máximos de monitoreo definidos en `INPUT.execution`.
- Pruebas y readback.
- Envolvente de corrección y límite de reintentos.
- Confirmación de que el código no será modificado.
- Confirmación de que Producción no será ejecutada todavía.

### Aprobación 1: plan no productivo

Una sola aprobación puede cubrir exactamente:

- Crear los tres DNS declarados, siempre que no exista conflicto.
- Crear las definiciones Build/Release/Task Group aprobadas.
- Configurar Desarrollo, UAT y Producción sin desplegar Producción.
- Ejecutar Build/Release de `INPUT.repository.branches.development` cuando `INPUT.execution.run_development_after_plan_approval` sea `true`.
- Validar Desarrollo en AKS.
- Ejecutar Build/Release de `INPUT.repository.branches.uat` cuando `INPUT.execution.run_uat_after_development_success` sea `true`.
- Validar UAT en AKS.
- Aplicar correcciones incluidas en la envolvente aprobada.
- Reintentar Desarrollo o UAT dentro del límite aprobado.

Después de esta aprobación, no preguntar por cada variable, tarea, manifiesto, llamada POST/PUT, Build, Release o readback interno que esté expresamente incluido.

### Aprobación 2: Producción

Producción siempre requiere una aprobación posterior y separada cuando `INPUT.execution.production_requires_separate_approval` sea `true`, después de demostrar que Desarrollo y UAT finalizaron correctamente.

La tarjeta de aprobación debe mostrar:

- Build y Release exactos.
- Rama `INPUT.repository.branches.production` y commit exacto.
- Artifact e image tag/digest exactos.
- DNS e IP de Producción.
- Clúster y namespace declarados en `INPUT.environments.production`.
- Node pool/selector de `INPUT.environments.production.node_selector` validado.
- Diff final del manifiesto.
- Aprobadores y condiciones del ambiente.
- Estado de Desarrollo y UAT.
- Riesgo, impacto, rollback y readback.

No aprobar ni ejecutar Producción automáticamente por el éxito de UAT.

### Eliminaciones

Mientras `INPUT.execution.allow_deletions` sea `false`, esta solicitud no autoriza eliminaciones. Toda eliminación de Cloudflare, Azure DevOps, AKS, artifacts, definiciones, variables, recursos Kubernetes o configuración debe utilizar el flujo destructivo separado y recibir aprobación explícita, aunque parezca necesaria para completar el plan.

## Envolvente de corrección y reintentos

Si ocurre un error de configuración, Claude puede corregir y reenviar sin una nueva aprobación únicamente cuando la corrección:

- Mantenga los mismos repositorio, aplicación, ramas, DNS, IPs, clústeres y namespaces.
- Mantenga los mismos recursos y alcance aprobados.
- No agregue privilegios, secretos, Service Connections ni Variable Groups nuevos.
- No cambie aprobadores, pools, Task Groups compartidos ni políticas.
- No elimine recursos o configuración.
- Corrija sintaxis, serialización, rutas, nombres derivados, mapeo de variables, task inputs, artifact references, puertos o sondas con evidencia ya incluida.
- Conserve la intención y los hashes de las entradas explícitas.

Permitir como máximo `INPUT.execution.max_automatic_configuration_retries_per_environment` ciclos automáticos de corrección por ambiente. Cada corrección debe generar un subplan derivado, nuevo hash, diff y entrada de journal, vinculado al plan aprobado.

Requiere un plan y aprobación nuevos si la corrección necesita:

- Cambiar una IP o FQDN.
- Usar otro clúster, contexto, namespace o node pool.
- Sustituir los exports canónicos por otro modelo no autorizado.
- Crear recursos no contemplados.
- Cambiar permisos RBAC más allá de lo aprobado.
- Cambiar secretos o conexiones.
- Modificar código.
- Ejecutar una eliminación.
- Ampliar el impacto o la indisponibilidad.

## Tratamiento de errores

Clasificar el error antes de actuar:

| Tipo | Acción |
|---|---|
| Configuración del pipeline | Corregir dentro de la envolvente y reintentar. |
| Payload/API Azure DevOps | Corregir serialización o referencia dentro de la envolvente. |
| DNS ya existe igual | Reutilizar y continuar. |
| DNS existe diferente | Detener esa operación y solicitar replanificación. |
| Manifiesto generado inválido | Corregir dentro de la envolvente y validar nuevamente. |
| Despliegue AKS por configuración | Corregir dentro de la envolvente y reintentar. |
| Falta de permisos o conexión | Reportar el permiso/conexión exactos; no elevar automáticamente. |
| Error transitorio | Reintentar con backoff solo dentro del límite aprobado. |
| Error de código o compilación | Reportar con evidencia; no modificar el código. |
| Error que exige ampliar alcance | Detener y crear un plan nuevo. |

No ocultar un error porque el reintento posterior funcionó. Incluir causa, corrección y resultado final en el journal.

## Monitoreo activo de Build, Release y rollout

Después de iniciar un Build, Release o despliegue, el coordinador debe monitorearlo activamente. No limitarse a informar que esperará unos minutos ni depender de que el usuario solicite otra revisión.

Reglas:

1. Consultar el estado inmediatamente después de crear o iniciar la ejecución.
2. Mientras continúe en un estado no terminal, volver a consultar cada `INPUT.execution.status_poll_interval_seconds` segundos —120 segundos, es decir, dos minutos, por defecto—.
3. Mantener el monitoreo hasta alcanzar un estado terminal o el tiempo máximo correspondiente:
   - Build: `INPUT.execution.build_wait_timeout_minutes`.
   - Release: `INPUT.execution.release_wait_timeout_minutes`.
   - Rollout: `INPUT.execution.rollout_wait_timeout_minutes`.
4. Las consultas de estado y readback son de solo lectura, forman parte del plan aprobado y no requieren aprobaciones adicionales.
5. Evitar espera activa o consultas excesivas. Utilizar una tarea controlada en segundo plano o el mecanismo de espera disponible y presentar únicamente cambios relevantes de estado.
6. En cada consulta confirmar el ID exacto de la ejecución para no mezclarla con Builds o Releases anteriores.

Para Build, registrar:

- Build ID.
- Estado y resultado normalizados, además de los valores originales devueltos por la API cuando ayuden al diagnóstico.
- Rama y commit.
- Hora de cola, inicio y finalización.
- Errores de timeline únicamente si falla o queda parcialmente exitoso.

Para Release, registrar por separado:

- Release ID.
- Ambiente objetivo.
- Deployment attempt.
- Estado de la ejecución del ambiente.
- Artifact, Build ID, imagen y tag/digest esperados.

Para el rollout de Kubernetes, registrar:

- Réplicas deseadas, actualizadas, disponibles y Ready.
- Imagen de los pods nuevos.
- Pods `Pending`, motivo de scheduling y eventos relevantes.
- Si el endpoint responde con la versión nueva o continúa atendiendo la anterior.

Crear una instancia de Release o recibir un resultado exitoso del job no equivale por sí solo a que la aplicación nueva quedó desplegada. Si se alcanza un timeout, reportar `monitoreo agotado; ejecución aún en curso o bloqueada`, conservar el último estado observado y no declarar éxito ni fracaso sin evidencia terminal.

### Registro automático de tiempos

Cuando `INPUT.execution.record_phase_timings` sea `true`, registrar automáticamente timestamps UTC de inicio y finalización, duración y resultado de:

- Descubrimiento por agente y plan consolidado.
- Espera de cada aprobación, separada del tiempo técnico.
- Creación y readback de DNS, Variable Groups, Build y Release.
- Cada Apply, corrección y reintento.
- Cada Build y sus estados de cola/ejecución.
- Cada Release y ambiente.
- Cada rollout y readback AKS.
- Tiempo total técnico y tiempo total transcurrido de la sesión.

No reconstruir las duraciones posteriormente a partir de mensajes cuando el journal pueda capturarlas en el momento. El reporte final debe mostrar ambos totales:

- `tiempo_tecnico`: ejecución y análisis realizados por los agentes.
- `tiempo_espera_usuario`: tiempo detenido esperando decisiones, PR u otra acción externa.
- `tiempo_total_transcurrido`: desde el inicio del descubrimiento hasta el último estado reportado.

Las mediciones y consultas de estado no requieren aprobaciones adicionales ni deben ralentizar el flujo perceptiblemente.

## Secuencia operativa

### Etapa 0: descubrimiento

1. Validar conexiones de solo lectura a Azure DevOps y Cloudflare. Validar AKS ahora solo cuando el modo elegido sea `completa` o `minima`.
2. Si `INPUT.discovery.cluster_validation_before_plan` es `preguntar`, formular una sola pregunta al inicio. Ejecutar en paralelo los demás agentes sin esperar esa respuesta para comenzar.
3. Capturar timestamps de inicio y crear el snapshot de hashes, commits, revisiones e IDs.
4. Ejecutar los agentes de descubrimiento y el preflight de ramas en paralelo. Si el modo es `omitir`, no iniciar consultas reales a los clústeres en esta etapa.
5. Cargar y validar los exports canónicos una sola vez y compartir el resultado sanitizado.
6. Clasificar la aplicación como `api` o `web` y validar datos explícitos y derivados.
7. Construir la matriz consolidada de variables y secretos por referencia.
8. Generar el plan y payloads, dejando la evidencia AKS como pendiente si fue omitida.
9. Ejecutar el dry-run del generador con la misma forma del plan real.
10. Completar las revisiones independientes iniciadas incrementalmente.
11. Solicitar Aprobación 1.

### Etapa 1: preparación

1. Confirmar que hashes, commits, revisiones y parámetros del comando Apply siguen coincidiendo con el plan aprobado.
2. Ejecutar cada comando Apply aprobado como un bloque completo; no reconstruirlo manualmente durante la ejecución.
3. Crear o reutilizar DNS aprobados.
4. Hacer readback DNS.
5. Crear Task Group únicamente si el patrón exige uno nuevo.
6. Crear Build clásico.
7. Crear Release clásico enlazado al Build nuevo.
8. Hacer readback de todas las definiciones.
9. Confirmar que Producción permanece sin ejecutar.

### Etapa 2: Desarrollo

1. Ejecutar la verificación mínima obligatoria previa al despliegue para Desarrollo, incluyendo capacidad de pods y margen requerido por el rollout.
2. Ejecutar el pipeline desde `INPUT.repository.branches.development` cuando esté habilitado por `INPUT.execution.run_development_after_plan_approval`.
3. Consultar el Build inmediatamente y luego cada intervalo configurado hasta su estado terminal.
4. Validar Build, artifact e imagen. No continuar si el Build no termina exitosamente.
5. Ejecutar/desplegar Desarrollo según el patrón aprobado y monitorear el Release con el mismo intervalo.
6. Monitorear el rollout hasta que finalice o alcance su timeout.
7. Validar `INPUT.environments.development.namespace`.
8. Revisar Deployment, ReplicaSet, Pods, Service, Ingress y recursos auxiliares.
9. Validar scheduling, imágenes, puertos, sondas, eventos y logs sanitizados.
10. Validar `INPUT.environments.development.dns` y el endpoint de forma segura.
11. Corregir y reintentar si corresponde.

### Etapa 3: UAT

Iniciar únicamente después de que Desarrollo esté estable y cuando `INPUT.execution.run_uat_after_development_success` sea `true`:

1. Ejecutar la verificación mínima obligatoria previa al despliegue para UAT, incluyendo capacidad de pods y margen requerido por el rollout.
2. Ejecutar el pipeline desde `INPUT.repository.branches.uat`.
3. Consultar el Build inmediatamente y luego cada intervalo configurado hasta su estado terminal.
4. Validar Build, artifact e imagen. No continuar si el Build no termina exitosamente.
5. Ejecutar/desplegar UAT según el patrón aprobado y monitorear el Release con el mismo intervalo.
6. Monitorear el rollout hasta que finalice o alcance su timeout.
7. Repetir readback completo en `INPUT.environments.uat.namespace`.
8. Validar `INPUT.environments.uat.dns` y el endpoint.
9. Corregir y reintentar si corresponde.

### Etapa 4: Producción

1. Preparar el artifact exacto desde `INPUT.repository.branches.production` cuando `INPUT.execution.prepare_production` sea `true`.
2. No desplegar todavía.
3. Presentar Aprobación 2.
4. Después de aprobar, ejecutar la verificación mínima obligatoria para Producción, incluyendo capacidad de pods y margen requerido por el rollout.
5. Ejecutar Producción y monitorear Build, Release y rollout con el intervalo y timeouts configurados.
6. Validar los datos de `INPUT.environments.production`, pods, Service, Ingress, DNS, endpoint, eventos y logs sanitizados.
7. No hacer rollback automático; presentarlo para aprobación si fuese necesario.

## Readback Kubernetes

Después de cada despliegue comprobar, como mínimo:

- Recursos creados y sus nombres.
- Namespace correcto.
- Imagen, tag y digest.
- Réplicas desired/current/ready/available.
- Pods Ready y reinicios.
- Node y node pool asignados.
- Service ports y targetPorts.
- Endpoints asociados al Service.
- Ingress host, backend y address.
- Startup, readiness y liveness.
- ConfigMaps, nombres de Secrets y mounts, sin valores secretos.
- ServiceAccount, Role y RoleBinding si existen.
- Events relevantes.
- Logs necesarios sanitizados.
- Resolución DNS y respuesta del endpoint.

Comparar el estado real con el YAML generado, no limitarse a que el pipeline aparezca verde.

## Clasificación obligatoria del resultado por ambiente

Reportar por separado el estado del Build, del Release y del workload. No utilizar `desplegado exitosamente` solo porque se creó una instancia de Release o porque sus tareas finalizaron.

| Estado del ambiente | Condición mínima |
|---|---|
| `Preparado` | Definiciones y configuración creadas, sin ejecución. |
| `Build exitoso` | Build terminal exitoso y artifact/imagen confirmados. No demuestra despliegue. |
| `Release ejecutado` | Instancia y ambiente de Release ejecutados. No demuestra por sí solo que el nuevo workload esté disponible. |
| `Despliegue completado` | Rollout terminado, réplicas nuevas Ready/available, imagen esperada confirmada y endpoint/readback correctos. |
| `Despliegue incompleto` | Release ejecutado, pero rollout pendiente, bloqueado o agotó el tiempo de monitoreo. |
| `Despliegue fallido` | Existe evidencia terminal de fallo y la versión nueva no alcanzó el estado esperado. |
| `Versión anterior operativa` | El servicio continúa respondiendo mediante pods anteriores; debe indicarse junto a `Despliegue incompleto` o `fallido`, nunca como éxito de la versión nueva. |

Para declarar `Despliegue completado`, comprobar conjuntamente:

- Build y Release asociados a los IDs correctos.
- `updatedReplicas`, `readyReplicas` y `availableReplicas` esperadas.
- Pods nuevos usando la imagen/tag/digest esperado.
- Ausencia de pods nuevos en `Pending` o fallando readiness.
- Service/Ingress apuntando al workload previsto.
- Endpoint validado y, cuando sea posible, evidencia de que responde la versión nueva.

Si un pod nuevo queda `Pending` por `Too many pods` mientras la versión anterior continúa sirviendo tráfico, el resultado correcto es `Despliegue incompleto; versión anterior operativa`, no `UAT desplegado` ni `ciclo completado`.

## Documentación de errores y memorias

Documentar todos los errores en el journal de la ejecución, pero distribuir aprendizajes en memorias según su dominio para evitar duplicación y contradicciones:

- Generador, payload, variables, tareas, Apply y Azure DevOps → memoria de `ado-pipeline-builder` y patrón de proyecto cuando sea reutilizable.
- Scheduling, capacidad, límites de pods y comportamiento del rollout → memoria del agente AKS correspondiente.
- DNS y comportamiento de Cloudflare → memoria del agente Cloudflare correspondiente.
- Código ausente, incompatibilidad por rama o particularidades de la aplicación → memoria/patrón del proyecto o aplicación.
- Resumen integral y tiempos → journal y memoria de proyecto de la sesión.
- Feedback repetido de interacción, comandos o routing → memoria de feedback correspondiente.

No copiar el error completo en todas las memorias. Guardar en cada una únicamente el aprendizaje reutilizable, evidencia sanitizada, alcance y referencia al journal. Nunca almacenar secretos, tokens, kubeconfigs ni valores sensibles.

## Entrega final

Entregar un único reporte consolidado con:

1. Exports canónicos utilizados, hashes y confirmación de que permanecieron intactos.
2. Clasificación `api` o `web`, evidencia y adaptaciones realizadas.
3. Build, Release y Task Groups creados/reutilizados con IDs.
4. Variables heredadas, modificadas y derivadas, sin secretos.
5. DNS creados o reutilizados.
6. Manifiestos finales por ambiente.
7. Recursos RBAC incluidos u omitidos y evidencia.
8. Puertos, sondas, volúmenes, selectors y métricas validados.
9. Resultados separados de Build, Release y workload para Desarrollo y UAT, utilizando la clasificación anterior.
10. Errores encontrados, correcciones y reintentos.
11. Confirmación de que no se modificó código.
12. Estado de Producción: pendiente de aprobación, ejecutado o fallido.
13. Readback de AKS por ambiente.
14. Confirmación de cero eliminaciones.
15. Journal y hashes de planes ejecutados.
16. Tiempos exactos por fase, esperas, Builds, Releases, rollouts, correcciones y total transcurrido.
17. Aprendizajes guardados y memoria de destino, sin duplicar el journal completo.

No declarar éxito completo hasta que el estado real de los recursos coincida con los manifiestos y los endpoints previstos hayan sido validados.

## Texto breve para iniciar el trabajo

Después de guardar esta plantilla dentro del proyecto, iniciar con:

> Ejecuta el ciclo descrito en `PLANTILLA-CICLO-CREACION-PIPELINE-APLICACION.md`. Toma todos los datos variables exclusivamente del bloque `INPUT` al inicio y valida sus faltantes en una sola pasada. Esta plantilla contiene sobrescrituras, no una definición completa. Usa obligatoriamente los exports canónicos indicados en `INPUT.azure_devops`; no selecciones un pipeline arbitrario por la carpeta destino. Aplica la ruta rápida segura: ejecuta en paralelo las lecturas independientes, comparte un solo inventario por fuente y reutiliza únicamente evidencia estática cuyo hash, commit o revisión siga coincidiendo. Ejecuta los preflight de ramas, variables/secretos y generador antes del Apply. Para la contraseña del Container Registry usa internamente `INPUT.azure_devops.secret_sources.container_registry_password.environment_variable`; si existe, no me solicites el valor ni lo muestres. Clasifica la aplicación como API o sitio web según el código, conserva todo lo compatible de los modelos y adapta únicamente lo necesario. Aplica `INPUT.discovery.cluster_validation_before_plan`; el valor predeterminado `minima` debe revisar también capacidad de pods y margen para el rollout. Si está en `preguntar`, pregúntame una sola vez al inicio si deseo validación `completa`, `minima` u `omitir`, y mientras tanto continúa Azure DevOps, Cloudflare y análisis de código. No te quedes esperando indefinidamente al agente AKS. Preséntame un único plan consolidado y no realices escrituras hasta que lo apruebe. Después de iniciar cada Build o Release, consulta su estado inmediatamente y luego cada `INPUT.execution.status_poll_interval_seconds` segundos hasta terminar o alcanzar el timeout; no te limites a decir que esperarás unos minutos. Registra automáticamente los tiempos técnicos, las esperas y el total transcurrido.
