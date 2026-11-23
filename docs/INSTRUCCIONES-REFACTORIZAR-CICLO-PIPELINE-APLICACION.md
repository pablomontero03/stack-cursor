# Instrucciones para refactorizar el ciclo de creación de pipelines de aplicación

## Objetivo

Refactorizar en `D:\Proyectos\automation` el ciclo coordinado de creación de pipelines de aplicación para que:

- La plantilla de cada ejecución contenga principalmente datos variables y decisiones del ciclo.
- Una nueva skill coordinadora administre el trabajo entre Azure DevOps, Cloudflare, análisis de código y AKS.
- Cada procedimiento técnico permanezca en la skill, referencia, script, regla o hook de su dominio.
- Se reduzcan lectura repetida, contexto y tiempo de ejecución sin eliminar controles.
- Una aprobación cubra el plan no productivo completo.
- Producción y toda eliminación mantengan aprobaciones separadas.

Esta tarea modifica únicamente archivos locales de automatización. No debe crear, modificar, ejecutar ni eliminar recursos reales de Azure DevOps, Cloudflare, Azure, Kubernetes o AKS. No debe ejecutar Builds ni crear instancias de Release. Utilizar mocks para todas las pruebas mutables.

## Principio de compatibilidad

La implementación debe ser aditiva y compatible con la estructura existente.

Antes de editar:

1. Inspeccionar `CLAUDE.md`, `.claude`, `docs`, `.mcp.json`, reglas, hooks, agentes, skills y scripts relacionados.
2. Identificar nombres y rutas reales; no inventar componentes duplicados.
3. Confirmar qué instrucciones ya están implementadas y dónde.
4. Registrar hashes de los archivos que se modificarán.
5. Preservar la plantilla completa actual. No eliminarla, renombrarla ni reemplazarla hasta que la nueva arquitectura pase las pruebas.

No debilitar ni reemplazar configuraciones de n8n, Schema Sync, Azure DevOps permissions, administración Linux, Azure, AKS, Cloudflare u otros dominios.

## Arquitectura objetivo

Crear la skill:

```text
.claude/skills/orchestrate-application-pipeline-cycle/
├── SKILL.md
└── references/
    ├── input-contract.md
    ├── orchestration-flow.md
    ├── approval-envelope.md
    └── status-timing-and-memory.md
```

No crear scripts dentro de esta skill si la misma capacidad ya existe en una skill de dominio. La coordinadora debe orquestar; no duplicar implementaciones de Azure DevOps, Cloudflare o AKS.

Si hacen falta validaciones puramente coordinadoras y deterministas, se permite agregar:

```text
.claude/skills/orchestrate-application-pipeline-cycle/scripts/
├── Test-ApplicationCycleInput.ps1
└── New-ApplicationCycleSnapshot.ps1
```

Crear esos scripts únicamente si aportan validación real y pruebas. No crear archivos vacíos o placeholders.

## Responsabilidad de la skill coordinadora

`SKILL.md` debe activarse para solicitudes de creación integral de un pipeline de aplicación que involucren dos o más de estos dominios:

- Azure DevOps clásico.
- Cloudflare DNS.
- Análisis de código o ramas.
- Kubernetes/AKS.
- Ejecución Desarrollo/UAT y preparación de Producción.

No debe activarse para una consulta aislada de un solo dominio, por ejemplo revisar únicamente un DNS, un Build existente o un pod.

La skill coordinadora debe:

1. Leer la plantilla ligera y validar su bloque `INPUT`.
2. Resolver los datos explícitos una sola vez.
3. Delegar procedimientos técnicos a las skills y agentes existentes.
4. Ejecutar consultas independientes de solo lectura en paralelo.
5. Compartir un resultado sanitizado por fuente para evitar consultas duplicadas.
6. Consolidar evidencia, diferencias, pendientes y riesgos.
7. Presentar un único plan no productivo.
8. Ejecutar el plan aprobado sin preguntas internas adicionales mientras permanezca dentro de su envolvente.
9. Solicitar aprobación separada para Producción.
10. Solicitar aprobación separada para toda eliminación.
11. Detenerse y replanificar si cambia un dato protegido o aumenta el alcance.
12. Mantener monitoreo y readback hasta clasificar correctamente el resultado.

## Distribución obligatoria de responsabilidades

### Plantilla ligera

Debe contener únicamente:

- Bloque `INPUT`.
- Objetivo concreto de la ejecución.
- Dominios participantes.
- Secuencia y dependencias de alto nivel.
- Envolvente de aprobación.
- Condiciones específicas para detener o replanificar.
- Criterios de aceptación del ciclo.
- Texto corto para iniciar.

No debe repetir procedimientos completos pertenecientes a una skill de dominio.

### Skill coordinadora

Mover o resumir aquí:

- Routing de agentes.
- Paralelismo de lecturas.
- Snapshot de hashes, commits, revisiones e IDs.
- Consolidación del plan.
- Dependencias Desarrollo → UAT → Producción.
- Aprobación no productiva consolidada.
- Aprobación separada de Producción.
- Comportamiento fuera del plan.
- Coordinación del polling.
- Clasificación integral del resultado.
- Registro de tiempos y routing de memorias.

### Skill de Azure DevOps Pipelines

Integrar en sus referencias o scripts existentes, sin duplicar:

- Resolución y comparación de exports canónicos.
- Matriz de conservación de tareas, variables, Task Groups y artifacts.
- Preflight de ramas y commits, si ya corresponde a este dominio; de lo contrario coordinarlo con el agente de código.
- Matriz consolidada de variables y secretos por referencia.
- Fuente `ADO_SECRET_CONTAINERREGISTRYPASSWORD` para la contraseña del Container Registry.
- Dry-run del generador usando los mismos tipos del plan real.
- Compatibilidad con `Hashtable`, `OrderedDictionary`, arrays y objetos deserializados.
- Contrato del comando Apply completo, sin prefijo `!` salvo que la interfaz lo requiera.
- Creación y readback de Build, Variable Groups y Release.
- Polling de Build y Release cada intervalo configurado.

La variable `ADO_SECRET_CONTAINERREGISTRYPASSWORD` debe:

- Leerse internamente desde el proceso actual.
- Comprobarse solo por presencia.
- Mapearse al nombre requerido por el modelo canónico.
- No solicitarse al usuario cuando exista.
- No pasarse como argumento de línea de comandos.
- No aparecer en planes, journals, logs, memorias o errores.
- Si fue creada con `setx` y la sesión actual no la ve, solicitar reiniciar terminal/Claude una vez y volver a comprobar; nunca pedir el valor por chat.

### Skill de AKS

Integrar en sus referencias o scripts existentes:

- Modos `completa`, `minima`, `omitir` y `preguntar` para descubrimiento previo.
- Validación mínima recomendada.
- Confirmación de suscripción, clúster, contexto y namespace.
- `allocatable.pods`/`maxPods`, pods no terminales por nodo y margen disponible.
- Capacidad temporal según réplicas, `maxSurge` y `maxUnavailable`.
- Pods Pending y eventos de scheduling.
- Node selector, taints, tolerations, CPU y memoria.
- Readback de Deployment, ReplicaSet, Pods, Service e Ingress.
- Clasificación `Despliegue completado`, `incompleto` o `fallido`.

La capacidad dinámica debe refrescarse inmediatamente antes de cada despliegue si la consulta anterior excede la antigüedad indicada en `INPUT.execution.aks_capacity_validation_max_age_seconds`.

### Skill de Cloudflare

Integrar en sus referencias o scripts existentes:

- Resolución de zona por FQDN.
- Validación de tipo, IP, proxy y TTL.
- Reutilización cuando el registro coincide.
- Conflicto cuando existe con valores diferentes.
- Comentario derivado del clúster confirmado.
- Readback posterior.
- Prohibición de duplicar o sobrescribir silenciosamente.

### Rules

Las reglas permanentes deben expresar:

- No mostrar secretos.
- No cambiar código de la aplicación salvo solicitud explícita y plan nuevo.
- No ejecutar Producción sin su aprobación separada.
- Toda eliminación requiere aprobación explícita, aunque estuviera sugerida por un diagnóstico.
- Un cambio fuera de los hashes, recursos, ramas, DNS, IPs, clústeres, namespaces o node pools aprobados requiere replanificación.
- No pedir una nueva aprobación por cada operación interna que ya pertenezca al plan aprobado.

No repetir procedimientos detallados en rules. Las rules declaran invariantes; las skills describen el procedimiento y los hooks lo hacen cumplir.

### Hooks

Reutilizar y extender hooks existentes solo cuando sea necesario. Deben:

- Reconocer un plan aprobado mediante identificador/hash y su envolvente exacta.
- Permitir operaciones incluidas en esa envolvente sin preguntas repetitivas.
- Solicitar aprobación si la operación no pertenece al plan.
- Solicitar aprobación separada para Producción.
- Solicitar siempre aprobación para eliminaciones.
- No registrar bodies o valores secretos.
- No sustituir una aprobación pendiente por un `deny` permanente cuando la operación legítima puede preguntarse.

No implementar la seguridad únicamente mediante texto en la skill.

### Scripts

La lógica repetible debe ser determinista y estar en scripts existentes del dominio:

- Validación de inputs.
- Snapshot y hashes.
- Generación y validación de planes.
- Dry-run.
- Apply.
- Polling cada `INPUT.execution.status_poll_interval_seconds`.
- Readback.
- Journal y tiempos.

Evitar que distintos agentes creen implementaciones paralelas para la misma operación.

### Memorias

Guardar todos los errores en el journal de ejecución. En memoria conservar únicamente aprendizajes reutilizables:

- Azure DevOps/generador/Apply → agente Azure DevOps correspondiente.
- Scheduling/capacidad/rollout → agente AKS correspondiente.
- DNS → agente Cloudflare correspondiente.
- Código o diferencias por rama → patrón de proyecto/aplicación.
- Resumen y tiempos → memoria de proyecto/sesión.

No copiar el journal completo en todas las memorias. No guardar secretos ni salidas sensibles.

## Paralelismo y ruta rápida segura

Durante el descubrimiento ejecutar simultáneamente:

1. Azure DevOps: exports, recursos compartidos, variables y secretos por referencia.
2. Código: las ramas Desarrollo, UAT y Producción.
3. Cloudflare: zonas y registros existentes.
4. AKS: descubrimiento según el modo seleccionado.

Optimizar así:

- Una consulta responsable por fuente y resultado compartido.
- Reutilización únicamente si hash, commit o revisión coinciden.
- Revisión incremental mientras otros agentes continúan.
- Consultas API agrupadas cuando sea seguro.
- Resultado parcial si un agente tarda; no repetir toda su investigación.
- Fallo rápido de la sección afectada sin cancelar las demás lecturas.

Mantener secuenciales:

- Escrituras relacionadas.
- Creación de Build antes del Release que lo referencia.
- Desarrollo antes de UAT.
- UAT estable antes de solicitar Producción.
- Readback inmediatamente después de cada escritura.

## Aprobaciones

### Aprobación 1 — Plan no productivo

Una sola aprobación cubre exactamente lo declarado en el plan:

- DNS sin conflicto.
- Variable Groups, Build, Release y Task Groups aprobados.
- Configuración de los tres ambientes sin desplegar Producción.
- Ejecución y readback de Desarrollo.
- Ejecución y readback de UAT.
- Correcciones dentro de la envolvente y límite aprobado.
- Polling, inventarios y journals internos.

No volver a preguntar por cada variable, POST, PUT, Build, Release, manifiesto o readback incluido.

### Aprobación 2 — Producción

Siempre separada y posterior a Desarrollo y UAT estables. Debe mostrar artifact, commit, imagen/digest, DNS, clúster, namespace, node pool, diff, riesgo, rollback y estado de los ambientes anteriores.

### Eliminaciones

Toda eliminación requiere aprobación independiente con recurso exacto, alcance, dependencias, datos persistentes, impacto y recuperación. Nunca incluir eliminaciones implícitas dentro de la aprobación no productiva.

## Monitoreo y estados

Después de iniciar Build o Release:

1. Consultar inmediatamente.
2. Consultar nuevamente cada `INPUT.execution.status_poll_interval_seconds`.
3. Continuar hasta estado terminal o timeout.
4. No limitarse a indicar que se esperarán unos minutos.
5. No pedir aprobaciones para consultas de estado.

Separar siempre:

- Build exitoso.
- Release ejecutado.
- Despliegue completado.
- Despliegue incompleto.
- Despliegue fallido.
- Versión anterior operativa.

Una instancia de Release creada no demuestra que el workload nuevo esté disponible.

## Tiempos

Registrar automáticamente:

- Inicio/final y duración por agente y fase.
- Tiempo de espera por aprobación o acción externa.
- Builds, Releases, rollouts y reintentos.
- Tiempo técnico.
- Tiempo de espera del usuario.
- Tiempo total transcurrido.

## Migración segura de la plantilla

1. Mantener intacta la plantilla completa actual.
2. Crear `docs\PLANTILLA-CICLO-CREACION-PIPELINE-APLICACION-LIGERA.md`.
3. Validar que todos sus `INPUT` sean reconocidos.
4. Ejecutar pruebas de routing y plan con mocks.
5. Comparar el plan simulado producido por la plantilla completa y la ligera.
6. Confirmar que la ligera no pierde entradas, aprobaciones, criterios de aceptación ni controles.
7. Solo después de la aprobación del usuario, decidir si la plantilla completa queda como referencia, se archiva o se retira.

## Pruebas obligatorias

Usar casos simulados sin red mutable ni recursos reales:

1. Aplicación web con todos los datos válidos.
2. API con adaptación de puertos y sondas.
3. Código ausente en la rama UAT.
4. Secreto ACR presente por variable de entorno, sin revelar su valor.
5. Variable creada con `setx` pero no visible en el proceso actual.
6. `OrderedDictionary` atravesando el generador.
7. DNS existente e idéntico.
8. DNS existente y diferente.
9. Nodo sin margen de pods para `maxUnavailable: 0`.
10. Build exitoso pero rollout incompleto.
11. Operación incluida en plan aprobado sin segunda pregunta.
12. Operación fuera del plan que solicita aprobación.
13. Producción que solicita aprobación separada.
14. Eliminación que siempre solicita aprobación.
15. Polling cada 120 segundos simulado con reloj falso, sin esperar realmente.
16. Registro de tiempos técnicos y externos.
17. Cero secretos en outputs, diffs, journals o memorias.
18. Cero llamadas reales POST, PUT, PATCH, DELETE, Build o Release.

Validar además las skills modificadas con el validador disponible y ejecutar todas las suites existentes para confirmar que n8n, Schema Sync, permisos, Azure, AKS, Cloudflare y Azure DevOps continúan funcionando.

## Entrega final de esta refactorización

Presentar:

1. Archivos creados y modificados.
2. Mapa final de responsabilidades.
3. Contenido que permaneció en la plantilla.
4. Contenido trasladado a cada skill/referencia/script/rule/hook.
5. Resultado de pruebas con PASS/FAIL exactos.
6. Comparación simulada entre plantilla completa y ligera.
7. Confirmación de cero cambios reales externos.
8. Confirmación de cero secretos mostrados o almacenados.
9. Confirmación de que no se eliminó ni reemplazó todavía la plantilla completa.
10. Comando exacto para iniciar un ciclo con la plantilla ligera.

No hacer commit ni push salvo solicitud explícita.

## Texto para iniciar la refactorización

> Implementa la refactorización descrita en `INSTRUCCIONES-REFACTORIZAR-CICLO-PIPELINE-APLICACION.md`. Primero inspecciona la estructura real y reutiliza los componentes existentes. Crea la skill coordinadora y la plantilla ligera sin eliminar ni reemplazar la plantilla completa. Distribuye cada procedimiento a su dominio, conserva el modelo de aprobaciones y utiliza únicamente mocks para las pruebas. No ejecutes Builds, Releases ni cambios reales en Azure DevOps, Cloudflare, Azure o AKS. Al terminar, presenta el mapa de responsabilidades, el diff y los resultados exactos de pruebas.
