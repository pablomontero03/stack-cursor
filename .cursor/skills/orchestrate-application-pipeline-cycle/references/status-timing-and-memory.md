# Monitoreo, estados, tiempos y memorias

## Monitoreo activo (nunca pasivo)

Después de iniciar un Build, Release o despliegue:

1. Consultar el estado inmediatamente.
2. Mientras siga en estado no terminal, volver a consultar cada
   `INPUT.execution.status_poll_interval_seconds` (120s por defecto) —
   usar `manage-azure-devops-pipelines/scripts/Wait-AdoClassicRun.ps1`
   para Build/Release clásico.
3. Continuar hasta estado terminal o el timeout correspondiente:
   `build_wait_timeout_minutes` / `release_wait_timeout_minutes` /
   `rollout_wait_timeout_minutes`.
4. Nunca limitarse a "esperar unos minutos" ni depender de que el usuario
   pida otra revisión.
5. Estas consultas son de solo lectura, forman parte del plan aprobado y
   no requieren aprobaciones adicionales.
6. En cada consulta confirmar el ID exacto de la ejecución (no mezclarla
   con Builds/Releases anteriores).

Crear una instancia de Release, o recibir un resultado de job exitoso, no
equivale por sí solo a que la aplicación nueva quedó desplegada. Al
agotar un timeout, reportar "monitoreo agotado; ejecución aún en curso o
bloqueada", conservar el último estado observado y no declarar éxito ni
fracaso sin evidencia terminal.

## Clasificación obligatoria del resultado por ambiente

Reportar por separado el estado del Build, del Release y del workload.
Nunca usar "desplegado exitosamente" solo porque se creó una instancia de
Release o porque sus tareas finalizaron.

| Estado | Condición mínima |
|---|---|
| `Preparado` | Definiciones y configuración creadas, sin ejecución. |
| `Build exitoso` | Build terminal exitoso y artifact/imagen confirmados. No demuestra despliegue. |
| `Release ejecutado` | Instancia y ambiente de Release ejecutados. No demuestra por sí solo que el workload nuevo esté disponible. |
| `Despliegue completado` | Rollout terminado, réplicas nuevas Ready/available, imagen esperada confirmada, endpoint/readback correctos. |
| `Despliegue incompleto` | Release ejecutado, pero rollout pendiente, bloqueado o agotó el timeout. |
| `Despliegue fallido` | Evidencia terminal de fallo; la versión nueva no alcanzó el estado esperado. |
| `Versión anterior operativa` | El servicio sigue respondiendo con pods anteriores — se indica junto a `incompleto`/`fallido`, nunca como éxito. |

`Build exitoso`/`Release ejecutado` se derivan de
`Wait-AdoClassicRun.ps1` (`manage-azure-devops-pipelines`).
`Despliegue completado`/`incompleto`/`fallido` y `previousVersionServing`
se derivan de `Get-AksRolloutClassification`
(`manage-aks-clusters/scripts/Aks-Common.ps1`, ver
`references/capacity-validation.md` de ese dominio). Un pod nuevo
`Pending` por `Too many pods` mientras la versión anterior sigue
sirviendo tráfico es siempre `Despliegue incompleto; versión anterior
operativa` — nunca "UAT desplegado" ni "ciclo completado".

Para declarar `Despliegue completado`, comprobar conjuntamente: Build y
Release asociados a los IDs correctos; `updatedReplicas`/`readyReplicas`/
`availableReplicas` esperadas; pods nuevos con la imagen/tag/digest
esperado; ausencia de pods nuevos `Pending` o fallando readiness;
Service/Ingress apuntando al workload previsto; endpoint validado.

## Registro automático de tiempos

Cuando `INPUT.execution.record_phase_timings` sea `true`, registrar
automáticamente timestamps UTC de inicio/fin, duración y resultado de:
descubrimiento por agente y plan consolidado; espera de cada aprobación
(separada del tiempo técnico); creación y readback de DNS/Variable
Groups/Build/Release; cada Apply, corrección y reintento; cada Build y
sus estados de cola/ejecución; cada Release y ambiente; cada rollout y
readback AKS.

El reporte final siempre muestra los 3 totales:

- `tiempo_tecnico`: ejecución y análisis realizados por los agentes.
- `tiempo_espera_usuario`: tiempo detenido esperando decisiones, PR u
  otra acción externa.
- `tiempo_total_transcurrido`: desde el inicio del descubrimiento hasta
  el último estado reportado.

Nunca reconstruir duraciones posteriormente a partir de mensajes cuando
el journal pudo capturarlas en el momento. Las mediciones y consultas de
estado no requieren aprobaciones adicionales ni deben ralentizar el flujo
perceptiblemente.

## Routing de memorias — por dominio, nunca duplicado

Documentar **todos** los errores en el journal de la ejecución. Guardar
en memoria únicamente el aprendizaje reutilizable (nunca el journal
completo):

| Origen del aprendizaje | Memoria destino |
|---|---|
| Generador, payload, variables, tareas, Apply y Azure DevOps | Memoria de `ado-pipeline-builder` (o `ado-pipeline-operator`/`-reviewer` según cuál lo detectó) + patrón de proyecto si es reutilizable entre apps |
| Scheduling, capacidad, límites de pods, comportamiento del rollout | Memoria del agente AKS correspondiente (`aks-operator`/`-diagnoser`/`-reviewer`) |
| DNS y comportamiento de Cloudflare | Memoria del agente Cloudflare correspondiente |
| Código ausente, incompatibilidad por rama, particularidades de la app | Memoria/patrón del proyecto o aplicación (memoria de sesión, no de un agente de dominio) |
| Resumen integral y tiempos | Journal de la ejecución + memoria de proyecto/sesión |
| Feedback repetido de interacción, comandos o routing | Memoria de feedback correspondiente |

Nunca almacenar secretos, tokens, kubeconfigs ni valores sensibles en
ninguna memoria. Un aprendizaje se guarda solo si es reutilizable en una
conversación futura — no todo lo que ocurrió en la sesión amerita una
memoria nueva (ver criterio de qué guardar en `.cursor/skills/` de este dominio).
