# Flujo de orquestación

## Ruta rápida segura (paralelismo)

Reducir tiempo sin omitir controles:

1. Ejecutar en paralelo las consultas independientes de Azure DevOps,
   ramas/código, Cloudflare y AKS. Ninguna escritura se ejecuta en
   paralelo.
2. Asignar una única fuente responsable por inventario y compartir su
   resultado sanitizado con los demás agentes. No repetir la misma
   consulta de Variable Groups, Service Connections, exports, zonas DNS o
   inventario AKS desde varios agentes.
3. Crear al inicio un snapshot con hashes de exports, commits de ramas,
   revisiones de definiciones e IDs de recursos consultados
   (`New-ApplicationCycleSnapshot.ps1`).
4. Reutilizar dentro del mismo ciclo únicamente evidencia estática cuyo
   hash/commit/revisión siga coincidiendo. Si cambió, consultar y validar
   de nuevo.
5. Nunca reutilizar como vigente la capacidad dinámica de AKS. Antes de
   escribir, la comprobación de capacidad (`manage-aks-clusters`
   `Test-AksDeploymentCapacity.ps1`) debe tener antigüedad máxima
   `INPUT.execution.aks_capacity_validation_max_age_seconds`; si es más
   antigua, refrescarla.
6. Agrupar consultas de solo lectura cuando la API permita obtener los
   mismos datos en una sola llamada/lote, sin ampliar el alcance.
7. Iniciar la revisión de cada sección apenas esté disponible — los
   reviewers de dominio no esperan a que todos los demás agentes
   terminen.
8. Si un agente tarda, pedirle un resultado parcial (hechos confirmados +
   pendientes) y continuar las demás secciones sin repetir su
   investigación desde cero.
9. Fallar rápido dentro de la sección afectada: un error de rama no
   detiene DNS ni el análisis del modelo, pero sí impide ejecutar esa
   rama.
10. No repetir pruebas/diffs/inventarios cuando entradas y hashes no
    cambiaron. Registrar la reutilización y la evidencia que la respalda.

Esta ruta rápida nunca permite saltar: revisión independiente por
dominio, verificación del destino, capacidad AKS reciente, secretos
requeridos, dry-run del generador ADO, ni readback posterior.

## Descubrimiento en paralelo — quién hace qué

1. **Azure DevOps** (`ado-pipeline-builder`): validar una sola vez los
   exports canónicos; analizar Build/Release, Task Groups, variables,
   secretos por referencia, artifacts y manifiestos; preparar la matriz
   de conservación y el dry-run del generador.
2. **Cloudflare** (`cloudflare-operator` en modo lectura — **no**
   `cloudflare-diagnoser`, ver nota abajo): validar zonas, registros
   existentes, IPs, proxy, TTL y comentarios — usar
   `Resolve-CloudflareDnsRecord.ps1` para la clasificación determinista
   por ambiente.
3. **AKS** (`aks-operator` en modo lectura — **no** `aks-diagnoser`, ver
   nota abajo): actuar según
   `INPUT.discovery.cluster_validation_before_plan` (ver
   `manage-aks-clusters/references/capacity-validation.md` para el
   detalle completo de los 4 modos). En `completa`, validar clústeres,
   namespaces, ingress IPs, node pools, labels, capacidad y recursos
   comparables; en `minima` (default), limitarse a los destinos
   declarados; en `omitir`, no iniciar consultas reales antes del plan y
   marcar la evidencia AKS como `Pendiente de validación previa al
   despliegue`.
4. **Código/ramas**: validar simultáneamente las 3 ramas declaradas,
   existencia de la subruta, framework, Dockerfile, scripts, puertos,
   sondas, métricas, volúmenes y necesidad de RBAC — vía lecturas directas
   (`mcp__azure-devops__repo_file`/`repo_branch`/`repo_search_commits`),
   coordinadas por esta skill o por `ado-pipeline-builder` (no existe hoy
   un agente de dominio dedicado a análisis de código).

**Nota confirmada en vivo 2026-09-07 (corrida real de `app-sso`):**
`cloudflare-diagnoser` y `aks-diagnoser` NO tienen `Bash`/`PowerShell` ni
tools `mcp__*` en su definición de agente — solo `Read`/`Grep`/`Glob`/
`Write`/`Edit`. Sirven para analizar evidencia YA recolectada (logs,
inventarios exportados, manifiestos versionados, memoria de agente), no
para descubrimiento en vivo. Para leer estado real de Cloudflare/AKS
durante esta fase, usar `cloudflare-operator`/`aks-operator` en modo
lectura (tienen `Bash`), o que la sesión principal ejecute las consultas
directamente. Delegar descubrimiento en vivo a un `-diagnoser` produce un
reporte basado solo en memoria/archivos locales, que puede estar
desactualizado (pasó exactamente esto: una cifra de capacidad AKS
citada por `aks-diagnoser` desde memoria resultó estar obsoleta al
verificarla en vivo).

Ningún resultado AKS debe bloquear indefinidamente los resultados de
Azure DevOps, Cloudflare o análisis de código; consolidar lo disponible y
distinguir claramente lo confirmado de lo pendiente. Los reviewers
(`ado-pipeline-reviewer`, `cloudflare-reviewer`, `aks-reviewer`) revisan
de forma incremental apenas reciben su sección, sin esperar el cierre de
todos los demás agentes. Ningún subagente concede la aprobación — la
aprobación pertenece siempre al usuario.

Las escrituras y ambientes dependientes permanecen serializados: no
ejecutar en paralelo cambios sobre DNS, definiciones o despliegues
relacionados; crear la **definición** del Build antes de crear la
**definición** del Release que la referencia como artifact source (es un
orden de creación por la referencia al Build definition ID, NO una
dependencia de que el Build se haya EJECUTADO con éxito — la definición
del Release se crea aunque el Build nunca haya corrido o haya fallado);
Desarrollo antes que UAT; UAT estable antes de solicitar Producción;
readback inmediatamente después de cada escritura.

## Plan consolidado

Antes de cualquier escritura, presentar un único plan que incluya (ver
`approval-envelope.md` para cómo se traduce esto en el bloque de
aprobación visible):

- Rutas y hashes de los exports canónicos de Build y Release.
- Clasificación `api`/`web` y evidencia.
- Nombre/ubicación de Build y Release nuevos; Task Groups
  reutilizados/creados.
- Repositorio, subruta, ramas y commits validados.
- Matriz de conservación del modelo (conservado/adaptado/excluido, con
  evidencia).
- Variables heredadas/cambiadas/derivadas/pendientes y secretos por
  nombre+fuente, sin valores.
- DNS por ambiente y estado actual (`to_create`/`reuse`/`conflict`).
- Clúster/contexto/namespace por ambiente: `confirmado`, `candidato` o
  `pendiente` según el modo de validación AKS elegido.
- Recursos Kubernetes por ambiente: puertos, sondas, volúmenes, RBAC,
  selectors, métricas.
- Capacidad mínima de AKS y margen para el rollout, cuando corresponda.
- Secuencia de creación/ejecución, intervalo y timeouts de
  `INPUT.execution`.
- Envolvente de corrección y límite de reintentos.
- Confirmación de que el código no será modificado y de que Producción
  no se ejecutará todavía.
- Advertencia explícita de que el gate real de Producción del Release
  (grupo `Release Executers`) exige una segunda confirmación nativa
  posterior a crear el Release, inevitable por una restricción de la API
  de Azure DevOps — ver `approval-envelope.md` § "Confirmación nativa
  adicional esperada: gate real de Producción del Release".

## Envolvente de corrección y reintentos

Si ocurre un error de configuración, corregir y reenviar **sin** nueva
aprobación únicamente cuando la corrección:

- Mantiene los mismos repositorio, aplicación, ramas, DNS, IPs, clústeres
  y namespaces.
- Mantiene los mismos recursos y alcance aprobados.
- No agrega privilegios, secretos, Service Connections ni Variable
  Groups nuevos.
- No cambia aprobadores, pools, Task Groups compartidos ni políticas.
- No elimina recursos ni configuración.
- Corrige sintaxis, serialización, rutas, nombres derivados, mapeo de
  variables, task inputs, artifact references, puertos o sondas con
  evidencia ya incluida en el plan.
- Conserva la intención y los hashes de las entradas explícitas.

Máximo `INPUT.execution.max_automatic_configuration_retries_per_environment`
ciclos automáticos de corrección por ambiente. Cada corrección genera un
subplan derivado, nuevo hash, diff y entrada de journal, vinculado al plan
aprobado — nunca se reescribe el plan original.

Requiere un plan y aprobación **nuevos** si la corrección necesita:
cambiar IP/FQDN; usar otro clúster/contexto/namespace/node pool;
sustituir los exports canónicos por otro modelo no autorizado; crear
recursos no contemplados; cambiar RBAC más allá de lo aprobado; cambiar
secretos o conexiones; modificar código; ejecutar una eliminación;
ampliar impacto o indisponibilidad.

## Tratamiento de errores

| Tipo | Acción |
|---|---|
| Configuración del pipeline | Corregir dentro de la envolvente y reintentar. |
| Payload/API Azure DevOps | Corregir serialización o referencia dentro de la envolvente. |
| DNS ya existe igual (`reuse`) | Reutilizar y continuar. |
| DNS existe diferente (`conflict`) | Detener esa operación y solicitar replanificación. |
| Manifiesto generado inválido | Corregir dentro de la envolvente y validar de nuevo. |
| Despliegue AKS por configuración | Corregir dentro de la envolvente y reintentar. |
| Falta de permisos o conexión | Reportar el permiso/conexión exactos; no elevar automáticamente. |
| Error transitorio | Reintentar con backoff solo dentro del límite aprobado. |
| Error de código o compilación | Reportar con evidencia; no modificar el código. |
| Error que exige ampliar alcance | Detener y crear un plan nuevo. |

No ocultar un error porque un reintento posterior funcionó — incluir
causa, corrección y resultado final en el journal.

## Secuencia operativa

**Etapa 0 — descubrimiento:** validar conexiones de solo lectura; si
`cluster_validation_before_plan` es `preguntar`, una sola pregunta al
inicio sin bloquear los demás agentes; snapshot inicial; descubrimiento +
preflight de ramas en paralelo; cargar y validar exports canónicos una
sola vez; clasificar la aplicación; matriz de variables/secretos; generar
plan y payloads (evidencia AKS pendiente si fue omitida); dry-run del
generador; revisiones incrementales; Aprobación 1.

**Etapa 1 — preparación:** confirmar que hashes/commits/revisiones siguen
coincidiendo con el plan aprobado; ejecutar cada Apply aprobado como
bloque completo; crear/reutilizar DNS; readback DNS; crear Task
Group/Build/Release; readback de definiciones; confirmar que Producción
sigue sin ejecutarse. **La definición del Release se crea AQUÍ, junto con
el Build — NO se espera a que el Build se ejecute con éxito.** Crear la
definición del Release solo requiere que el Build definition exista (para
referenciarlo como artifact source con su ID); una ejecución verde del
Build es requisito para *ejecutar una instancia* del Release, no para
*crearlo*. Así queda todo el pipeline armado aunque el código falle: si el
Build falla, se corrige y se re-encola, pero las definiciones ya están
completas.

**Etapa 2 — Desarrollo:** cubierta por la misma Aprobación 1 cuando el
plan la enumeró explícitamente (ver `approval-envelope.md`) →
verificación mínima previa (capacidad incluida) → ejecutar pipeline desde
`branches.development` → monitoreo inmediato y por intervalo hasta
terminal → validar Build/artifact/imagen → monitorear Release (su
instancia real se crea recién acá, no antes) → monitorear rollout →
readback completo (Deployment/ReplicaSet/Pods/Service/Ingress) → validar
DNS/endpoint → corregir y reintentar dentro de la misma envolvente sin
pedir aprobación nueva (una corrección que cambia recursos/alcance, o
una eliminación, sí la exige).

**Etapa 3 — UAT:** igual que Desarrollo, cubierta por la misma Aprobación
1, solo si Desarrollo quedó estable y `run_uat_after_development_success`
es `true`.

**Etapa 4 — Producción:** preparar artifact exacto desde
`branches.production` sin desplegar → Aprobación 2 → verificación mínima
→ ejecutar y monitorear → validar datos de producción → sin rollback
automático (presentar como plan nuevo si hace falta).

## Migración de la plantilla completa

`docs/PLANTILLA-CICLO-CREACION-PIPELINE-APLICACION.md` se preserva
íntegra — no se elimina, renombra ni reemplaza como parte de este
refactor. Su contenido procedimental fue distribuido a esta skill y a las
skills de dominio (ver mapa de responsabilidades del reporte de entrega).
Su destino final (referencia histórica, archivo, o retiro) es una
decisión del usuario, posterior a validar que la plantilla ligera +
`orchestrate-application-pipeline-cycle` producen un plan equivalente —
nunca una decisión automática de esta skill.
