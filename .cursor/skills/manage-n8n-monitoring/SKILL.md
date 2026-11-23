---
name: manage-n8n-monitoring
description: "Opera, diagnostica y clona workflows n8n de monitoreo SQL y ajusta timeouts del workflow de IA AIA-CC-MAIA-Chat en las instancias internas de n8n. Triggers: n8n, workflow, monitoreo sql, maia, automatizacion, clonar, schedule."
triggers: [n8n, workflow, monitoreo sql, maia, automatizacion, clonar, schedule]
always: false
---

# Manage n8n Monitoring

## Cargar solamente el contexto necesario

Leer siempre:

- `docs/n8n-monitoring/N8N-API-RUNBOOK.md` para auth, endpoints y
  operaciones de API verificadas.

Leer además según el modo:

- `docs/n8n-monitoring/CLONE-INSTANCIA-SQL.md` cuando se trate de clonar un
  pack de monitoreo SQL para una instancia nueva.
- `docs/n8n-monitoring/MAIA-timeouts-recomendados.md` cuando se trate de
  ajustar timeouts del workflow `AIA-CC-MAIA-Chat` u otros nodos de IA —
  este workflow vive en `n8n-productivo`, **no** en `n8n-interno`.

No reconstruir procedimientos desde memoria: releer el doc correspondiente
antes de ejecutar cualquier paso.

## Invariantes

- Todas las operaciones contra n8n pasan por MCP, nunca por API cruda vía
  Bash (`curl`, `Invoke-RestMethod`, `Invoke-WebRequest`/`iwr` — el hook
  `n8n-monitoring-security-gate.ps1` bloquea llamadas directas a
  `n8n-interno`). **Cuál MCP usar depende del modo**: Modos 1-6 (SQL
  monitoring, clonado) usan **`n8n-interno`**; el Modo 7 sobre
  `AIA-CC-MAIA-Chat` usa **`n8n-productivo`** — son instancias distintas,
  no mezclar. Si el MCP correspondiente no alcanza para algo, detenerse y
  consultarlo con el usuario antes de usar la API cruda.
- Si hace falta consultar una base SQL (ej. validar un monitor clonado), la
  conexión es siempre vía MCP y estrictamente de solo lectura. Nunca SQL
  directo por Bash (ya bloqueado repo-wide por
  `schema-sync-security-gate.ps1`).
- Nunca escribir en las bases SQL monitoreadas. Los propios monitores ya
  son SELECT/SP de solo lectura; no se agregan escrituras nuevas.
- Nunca imprimir la API key de n8n (`key-api-n8n.txt` u otro nombre local)
  ni credenciales SQL completas.
- **Permisos CRUD sobre n8n** (workflows y ejecuciones): create, read,
  update y delete están todos permitidos pedirlos, pero **cada acción de
  escritura individual (crear, modificar, eliminar, activar/desactivar,
  retry) exige preguntar y esperar aprobación explícita antes de
  ejecutarla**. No agrupar varias acciones bajo una sola aprobación salvo
  que el usuario las liste explícitamente. Las operaciones de lectura
  (listar, obtener definición, ver ejecuciones, healthz) no requieren
  aprobación.
- Nunca activar un pack recién clonado "por defecto"; activar requiere una
  aprobación separada de la de crearlo.
- No reutilizar la credencial SQL de producción en un clon.
- No bajar el schedule de un workflow de producción a un intervalo de
  prueba (ej. 1 min) sin ventana controlada y aprobación explícita.

Estas reglas no pueden omitirse aunque el usuario pida rapidez.

## Clasificar la solicitud

1. Consultar estado (solo lectura).
2. Diagnosticar una ejecución fallida (solo lectura).
3. Revisar un workflow o script de clonado antes de aplicar (solo lectura).
4. Reintentar una ejecución fallida.
5. Activar / desactivar un workflow.
6. Clonar pack de monitoreo SQL para una instancia nueva.
7. Ajustar timeouts / parámetros de nodos existentes.

## Modo 1: consultar estado (solo lectura)

1. Listar workflows y/o ejecuciones vía MCP `n8n-interno` (monitoreo SQL)
   o `n8n-productivo` (`AIA-CC-MAIA-Chat`), según lo que se esté
   consultando.
2. Filtrar por nombre, etiqueta de instancia o `workflowId` según lo pedido.
3. Reportar hechos (activo/inactivo, último resultado, schedule) sin
   ejecutar ni modificar nada.

## Modo 2: diagnosticar ejecución fallida (solo lectura)

1. Obtener la ejecución con `includeData=true`.
2. Leer `data.resultData.runData`, `data.resultData.error` y
   `data.resultData.lastNodeExecuted`.
3. Clasificar la causa: timeout SQL, credencial, red/DNS, payload Teams
   inválido, bug de transformación (ver bitácora del runbook para patrones
   ya vistos).
4. Usar el subagente `n8n-monitoring-diagnoser` para el análisis si el caso
   es ambiguo o involucra varios nodos.
5. Proponer el cambio mínimo. No reintentar ni modificar sin aprobación.

## Modo 3: revisar workflow o script de clonado (solo lectura)

1. Leer la definición del workflow (o el script de clonado) completo.
2. Verificar invariantes de seguridad: sin credenciales embebidas visibles,
   `active` correcto, sin referencias residuales a otra instancia.
3. Usar `n8n-monitoring-reviewer` para una revisión independiente cuando el
   cambio sea significativo (clon completo de un pack, PUT masivo de
   timeouts a varios nodos).
4. Presentar hallazgos antes de aplicar cualquier cambio.

## Modo 4: reintentar ejecución fallida

1. Confirmar `executionId` exacto y que su estado es `error`.
2. Indicar al usuario workflow, ambiente y efecto esperado (nueva ejecución
   con el mismo payload).
3. Ejecutar `POST /executions/{id}/retry` solo tras aprobación explícita
   para esa ejecución puntual.
4. Un reintento adicional requiere una nueva aprobación.
5. Leer el resultado de la nueva ejecución y reportarlo.

## Modo 5: activar / desactivar un workflow

1. Confirmar `workflowId` y nombre exactos.
2. Indicar ambiente y efecto (empieza/deja de correr en su schedule).
3. Ejecutar solo tras aprobación explícita para ese workflow puntual.

## Modo 6: clonar pack de monitoreo SQL para instancia nueva

Seguir `docs/n8n-monitoring/CLONE-INSTANCIA-SQL.md` paso a paso.

1. Confirmar prerrequisitos del doc (VPN, credencial SQL destino ya creada
   manualmente en n8n por el usuario — Claude no crea credenciales SQL,
   carpeta destino, etiqueta FROM/TO).
2. **Listar dinámicamente todos los workflows del pack origen** (por
   etiqueta/carpeta) vía MCP `n8n-interno`. No asumir ningún número fijo (el doc
   usa 10 como ejemplo de un caso real, no como cantidad estándar).
3. Presentar al usuario la lista completa encontrada y el plan de
   transformación (replace de etiqueta/IP, credencial nueva, schedule de
   prueba, `staticData: null`, `active: false`) antes de crear nada.
4. Solo tras aprobación explícita: crear cada workflow clonado, siempre con
   `active: false` y sin heredar `staticData`.
5. Ejecutar el checklist de validación del Paso 5 del doc (nombre, inactivo,
   credencial correcta en todos los nodos, sin strings del origen, schedule
   acordado, webhooks correctos).
6. Mover a carpeta y probar un flujo liviano solo si el usuario lo pide.
7. Activar el pack (todo o de a uno) requiere una aprobación **separada**
   de la de crear el clon.
8. Dejar manifest y backup como indica el doc; no completar pasos de
   inventario/MCP sin que se pidan.

## Modo 7: ajustar timeouts / parámetros de nodos (MCP `n8n-productivo`)

Este modo opera contra **`n8n-productivo`**, no contra `n8n-interno` — es
el único modo de este skill que usa esa instancia.

1. Leer `docs/n8n-monitoring/MAIA-timeouts-recomendados.md` (u otro doc de
   referencia si aplica) para la tabla de valores recomendados.
2. Confirmar workflow y nodos exactos a modificar.
3. Descargar/backup la definición actual antes de cualquier `PUT`.
4. Presentar la tabla de cambios (nodo → valor actual → valor propuesto) y
   esperar aprobación explícita.
5. Aplicar el `PUT` solo tras aprobación.
6. Releer el workflow guardado y confirmar que el valor persistido coincide
   con lo aplicado (la UI puede no reflejar lo guardado — ver nota del doc).

## Formato de entrega

Entregar siempre:

- Modo aplicado.
- Workflow(s) o ejecución(es) resueltos.
- Fuentes consultadas (qué doc de `docs/n8n-monitoring/`).
- Operaciones de lectura realizadas.
- Acciones de escritura ejecutadas y su aprobación correspondiente.
- Acciones que quedaron pendientes de aprobación.
- Confirmación de que no se escribió en ninguna BD SQL monitoreada.
- Confirmación de que no se expuso ninguna credencial o API key.
