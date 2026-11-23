# Implementación del dominio Azure FinOps

## Objetivo

Implementar en `D:\Proyectos\automation` una capacidad especializada de análisis FinOps para la suscripción:

- Nombre: `Hospital Metropolitano`
- Subscription ID: `69dc43ec-5f24-4203-9239-a8d0f8506d44`
- Tenant: `Grupo Montecristo`
- Autenticación: sesión local iniciada manualmente mediante `az login`

El resultado debe permitir investigar costos, consumo, utilización, anomalías, tendencias, pronósticos y oportunidades de optimización de cualquier servicio Azure. No debe limitarse a una familia de recursos, servicio o conjunto predeterminado de métricas.

El archivo `documentacion-metricas-azure-monitor-cli.md` queda expresamente fuera del alcance de esta implementación. No leerlo, copiarlo, moverlo, modificarlo ni incorporarlo como referencia de la skill FinOps. Ese documento corresponde a métricas operativas de Azure Monitor/OpenAI y no constituye una fuente de costos.

La implementación debe ser aditiva y seguir exactamente las convenciones ya existentes del dominio general Azure. No reemplazar ni debilitar skills, agentes, hooks, reglas, memorias, MCP ni permisos existentes.

## Inspección previa obligatoria

Antes de editar:

1. Leer `CLAUDE.md` y las reglas aplicables.
2. Identificar la skill y los agentes del dominio general Azure ya implementado.
3. Identificar el flujo actual de plan, revisión, aprobación, aplicación, readback y eliminación.
4. Revisar los hooks Azure y su clasificación real de comandos.
5. Presentar un plan de archivos que se crearán o modificarán.
6. No modificar nada hasta recibir la aprobación del plan de implementación.

Después de aprobar el plan de implementación, realizar todos los cambios incluidos sin pedir aprobaciones adicionales. Detenerse únicamente si hace falta salirse del plan, tocar otro dominio, revelar secretos o realizar una operación real contra Azure que no sea de lectura.

## Diseño recomendado

Crear una skill especializada y un subagente dentro del dominio Azure existente:

```text
.claude/
├── skills/
│   └── analyze-azure-costs/
│       ├── SKILL.md
│       ├── references/
│       │   ├── cost-data-sources.md
│       │   ├── cost-definitions.md
│       │   ├── utilization-correlation.md
│       │   └── reporting-and-charts.md
│       └── scripts/
│           ├── Test-AzureFinOpsContext.ps1
│           ├── Invoke-AzureCostQuery.ps1
│           ├── Get-AzureCostInventory.ps1
│           ├── Get-AzureResourceMetrics.ps1
│           ├── Get-AzureCostRecommendations.ps1
│           ├── New-AzureFinOpsReport.ps1
│           └── tests/
│               └── run-script-tests.ps1
├── agents/
│   └── azure/
│       └── azure-finops-analyst.md
└── agent-memory/
    └── azure-finops-analyst/
        ├── MEMORY.md
        ├── patterns.md
        └── debugging.md
```

Adaptar las rutas si la estructura Azure existente usa otros nombres. No crear una segunda arquitectura paralela.

No crear hooks duplicados si el hook general de Azure puede ampliarse de manera segura. Reutilizar el agente Azure reviewer existente para revisar planes de optimización; no crear otro reviewer salvo que la arquitectura actual lo requiera realmente.

## Skill `analyze-azure-costs`

La descripción debe activarla para solicitudes como:

- Analizar costos de Azure.
- Explicar aumentos o reducciones de gasto.
- Comparar períodos.
- Pronosticar el cierre mensual.
- Investigar anomalías.
- Encontrar recursos ociosos o sobredimensionados.
- Correlacionar costo con utilización.
- Evaluar reservas, Savings Plans o cambios de SKU.
- Generar reportes, gráficos, CSV o Excel.
- Analizar costos de AKS, SQL, Azure OpenAI, Azure Monitor u otros servicios.

No debe activarse para administración general de recursos que no tenga un objetivo financiero.

## Subagente `azure-finops-analyst`

Responsabilidades:

1. Descubrir el alcance solicitado y confirmar siempre suscripción, moneda, período y tipo de costo.
2. Consultar datos reales sin modificar recursos.
3. Combinar costos con inventario, métricas y recomendaciones.
4. Detectar tendencias, anomalías, concentración y desperdicio.
5. Generar gráficos y estadísticas reproducibles.
6. Separar hechos medidos, cálculos, estimaciones e hipótesis.
7. Cuantificar ahorro potencial mensual y anual cuando exista evidencia suficiente.
8. Declarar riesgos operativos, confiabilidad del cálculo y datos faltantes.
9. Preparar planes de optimización, pero transferir su ejecución al operador Azure existente.
10. Validar después de un cambio aprobado si el ahorro previsto se materializó.

Incluir `memory: project` si esa es la convención vigente. La memoria puede guardar patrones, nombres de reportes y metodologías validadas, pero nunca costos descargados completos, tokens, credenciales, kubeconfigs, identificadores sensibles de facturación ni datos que deban permanecer en `.local`.

## Fuentes de datos

Utilizar la fuente adecuada según el caso:

1. Azure Cost Management Query API para análisis interactivo y agrupaciones.
2. Cost Details o Exports para datasets grandes, automatizaciones e histórico.
3. Formato FOCUS cuando facilite análisis normalizado.
4. Azure Resource Graph para inventario, tipos, ubicaciones, tags, SKUs y relaciones.
5. Azure Monitor Metrics para utilización y rendimiento.
6. Azure Advisor para recomendaciones de costo.
7. APIs de Reservations y Savings Plans para cobertura, utilización y recomendaciones cuando estén disponibles.
8. Price Sheet o precios contractuales disponibles para la cuenta.
9. Azure Retail Prices API únicamente como precio público de referencia.
10. Azure CLI y `az rest` usando la sesión local ya autenticada.

No sustituir costos facturados o precios negociados por precios públicos. Si solo existe precio retail, identificar el resultado como estimación de lista.

Azure MCP no es requisito. Si el servidor MCP general de Azure está disponible y validado, puede utilizarse para consultas de lectura. Azure CLI, Resource Graph y las APIs oficiales deben seguir funcionando como vía completa independiente.

## Validación de identidad y alcance

Antes de cada extracción:

1. Ejecutar `az account show`.
2. Confirmar el tenant esperado.
3. Confirmar explícitamente la suscripción `69dc43ec-5f24-4203-9239-a8d0f8506d44`.
4. Usar `--subscription 69dc43ec-5f24-4203-9239-a8d0f8506d44` o el scope completo en todas las consultas.
5. No ejecutar `az login`, `az logout` ni cambiar la suscripción activa automáticamente.
6. Si la sesión expiró o apunta a otro tenant, detenerse e indicarlo sin intentar autenticarse por el usuario.

## Definiciones financieras obligatorias

Todo informe debe distinguir claramente:

- Costo real (`ActualCost`).
- Costo amortizado (`AmortizedCost`).
- Pronóstico (`Forecast`), si existe.
- Moneda de facturación.
- Período y zona horaria.
- Costos acumulados del mes frente a meses completos.
- Precio unitario, precio efectivo y costo total cuando estén disponibles.
- Consumo, compras, reservas, Savings Plans, créditos, reembolsos y ajustes.
- Datos con impuestos o sin impuestos según lo que realmente entregue la fuente.
- Fecha y hora de actualización de los datos.

No comparar un mes parcial contra un mes completo sin normalizarlo o indicarlo. No sumar importes con monedas distintas. No presentar ahorro estimado como ahorro garantizado.

## Análisis mínimos disponibles

El subagente debe poder producir, según la solicitud:

### Resumen ejecutivo

- Costo del período.
- Costo acumulado del mes.
- Pronóstico de cierre.
- Variación absoluta y porcentual frente al período comparable.
- Principales responsables del cambio.
- Anomalías relevantes.
- Ahorro potencial identificado.

### Desglose

- Por servicio.
- Por recurso.
- Por resource group.
- Por región.
- Por tipo de recurso.
- Por meter, producto, publisher o charge type.
- Por tag, aplicación, ambiente o centro de costo cuando los datos lo permitan.
- Por día, semana y mes.

### Estadística

- Promedio, mediana, mínimo, máximo y desviación.
- Tendencia y tasa de crecimiento.
- Comparación día contra día, semana contra semana, mes contra mes y año contra año cuando exista histórico.
- Concentración de costos y análisis Pareto.
- Detección de saltos, caídas y cambios estructurales.
- Pronóstico con metodología y margen de incertidumbre identificados.

### Optimización

- Recursos detenidos pero con costos asociados.
- Recursos ociosos o infrautilizados.
- SKUs potencialmente sobredimensionados.
- Discos, snapshots, IPs u otros recursos sin asociación útil.
- Costos de red y transferencia.
- Retención e ingestión de Log Analytics y Azure Monitor.
- Backups y almacenamiento redundante.
- Cobertura y utilización de Reservations y Savings Plans.
- Recomendaciones de Azure Advisor.
- Recursos sin tags de asignación financiera.

Cada recomendación debe incluir evidencia, costo actual, ahorro estimado, confianza, esfuerzo, riesgo, dependencias, impacto en disponibilidad y método de validación posterior.

## Análisis especializados

### AKS

Correlacionar costos de nodos, node pools, discos, red, balanceadores, Container Registry, Monitor y Log Analytics con CPU, memoria, réplicas y capacidad solicitada/utilizada.

No inventar costo por namespace o workload. Solo presentarlo si existe asignación confiable mediante tags, exportaciones, cost analysis de AKS/OpenCost u otra metodología demostrable. Documentar recursos compartidos y reglas de reparto.

### SQL y bases de datos

Analizar SKU, vCores, almacenamiento, backup, redundancia, licenciamiento, reservas, utilización y ventanas de actividad. Una recomendación de reducción debe considerar límites de escalado, rendimiento, alta disponibilidad y tiempo de cambio.

### Azure AI/OpenAI

El análisis puede incluir:

- Costo por deployment y modelo cuando la facturación lo permita.
- Tokens de entrada y salida.
- Solicitudes.
- Costo por millón de tokens.
- Costo por solicitud.
- Latencia, errores y disponibilidad.
- Picos de utilización y rate limit.
- Capacidad provisionada frente a consumo.

Si Cost Management solo entrega costo a nivel de recurso y las métricas están por deployment, cualquier reparto debe marcarse como estimación y explicar la fórmula. No atribuir costo exacto a un deployment sin datos que lo respalden.

### Azure Monitor y Log Analytics

Analizar ingestión, retención, consultas, alertas, métricas, Application Insights y exportaciones. Distinguir claramente datos operativos de cargos facturados.

## Gráficos y entregables

Elegir gráficos según la pregunta, no generar todos automáticamente:

- Línea: evolución diaria o mensual.
- Barras apiladas: composición por servicio o resource group.
- Pareto: recursos que concentran el gasto.
- Waterfall: explicación de la variación entre períodos.
- Heatmap: patrones por día y hora.
- Dispersión: costo frente a utilización.
- Tabla: ranking y recomendaciones accionables.

Formatos admitidos:

- Resumen Markdown.
- CSV con datos normalizados.
- Excel con tablas, fórmulas, filtros y gráficos.
- PNG o SVG para gráficos individuales.
- HTML autocontenido para informe navegable.

Guardar datos, reportes y gráficos generados en una ruta ignorada por Git, siguiendo el patrón actual, por ejemplo:

```text
.local/azure/finops/
├── raw/
├── normalized/
├── reports/
├── charts/
└── executions/
```

No escribir datos financieros descargados dentro de `docs`, memorias ni archivos versionados. La documentación versionada solo debe contener metodología, esquemas sanitizados y ejemplos ficticios.

## Modelo de aprobación

### Sin aprobación adicional

- Consultas de costos y forecasts.
- Consultas de Resource Graph.
- Métricas de Azure Monitor.
- Recomendaciones de Advisor ya existentes.
- Inventario y validación de permisos.
- Lectura de budgets, exports y alertas existentes.
- Generación local de CSV, Excel, Markdown, HTML y gráficos dentro de `.local`.
- Cálculos, correlaciones y simulaciones.
- Preparación y revisión de un plan de optimización.

### Una aprobación del plan

La aprobación de un plan inmutable puede cubrir todas las creaciones y modificaciones no destructivas incluidas expresamente, por ejemplo:

- Crear o actualizar budgets.
- Crear o actualizar alertas y scheduled actions.
- Crear o actualizar exports.
- Agregar o corregir tags.
- Aplicar una optimización de SKU o configuración.
- Configurar monitoreo financiero.

Después de aprobar el plan no pedir confirmaciones internas adicionales mientras método, URI, scope, recurso, valores y hash coincidan exactamente. Si aparece una desviación, detenerse y preparar un plan nuevo.

### Aprobación separada obligatoria

Toda eliminación requiere aprobación explícita, aunque aparezca en el plan original:

- Eliminar un recurso.
- Eliminar un budget, export, alerta o scheduled action.
- Quitar una reserva, configuración o vínculo que pueda afectar facturación o disponibilidad.
- Acciones irreversibles o con pérdida potencial de datos.

Mostrar recurso exacto, scope, costo actual, dependencias, impacto, respaldo y posibilidad de recuperación.

El subagente FinOps no debe aplicar por sí solo cambios de infraestructura. Debe generar el plan y transferirlo al operador Azure y al reviewer existentes. La ejecución seguirá el wrapper aprobado del dominio general Azure.

## Caso especial: consultas HTTP POST de solo lectura

Cost Management utiliza HTTP `POST` para algunas consultas que no modifican estado. Evitar que esto produzca aprobaciones innecesarias.

El hook Azure puede clasificar como lectura únicamente operaciones que cumplan simultáneamente:

1. Host oficial `management.azure.com`.
2. Suscripción y scope explícitos autorizados.
3. Ruta exacta de consulta de Cost Management o Forecast documentada.
4. Cuerpo limitado a `type`, `timeframe`, `timePeriod`, `dataset`, `granularity`, `aggregation`, `grouping`, `filter`, `sorting` y paginación admitida.
5. Sin URI de creación, actualización, eliminación o action.
6. Sin parámetros desconocidos.

No permitir `POST` genérico. Si la ruta o el cuerpo no coinciden con el esquema de lectura validado, devolver `ask`.

Agregar pruebas para confirmar:

- Cost query exacta: lectura permitida.
- Forecast exacto: lectura permitida.
- Query a otra suscripción no autorizada: preguntar.
- `POST` genérico: preguntar.
- Crear budget/export/scheduled action: cubierto solamente por plan aprobado.
- Delete: aprobación separada.
- No se imprimen tokens ni headers de autorización.

## Calidad y trazabilidad

Cada ejecución de análisis debe registrar de forma sanitizada:

- Subscription ID y scope.
- Ventana consultada.
- Tipo de costo.
- Moneda.
- Fuentes utilizadas.
- Hora de extracción.
- Frescura declarada por la fuente.
- Hash de los datos normalizados o manifiesto de archivos.
- Fórmulas y supuestos.
- Advertencias y datos faltantes.
- Versión de scripts.

Nunca registrar access tokens, encabezados Authorization, respuestas de autenticación ni secretos.

## Pruebas

Crear pruebas con fixtures sintéticos y sin consultar Azure para validar:

1. Normalización de ActualCost y AmortizedCost.
2. Monedas distintas no se suman.
3. Mes parcial no se compara incorrectamente con mes completo.
4. Agrupaciones por servicio, recurso, RG y tags.
5. Forecast y variaciones.
6. Anomalías y Pareto.
7. Datos faltantes y valores nulos.
8. Paginación de APIs.
9. Respuestas 401, 403, 429 y 5xx sin exponer información sensible.
10. Generación de CSV, Excel y gráficos.
11. Cost query POST clasificada como lectura solo con ruta y esquema exactos.
12. Mutaciones y eliminaciones correctamente transferidas al flujo de aprobación.

Después de las pruebas simuladas, permitir únicamente verificaciones reales de lectura:

- `az account show`.
- Confirmación de acceso al scope de la suscripción.
- Una consulta pequeña de costo del período reciente.
- Una consulta de Resource Graph.
- Una métrica de Azure Monitor.
- Lectura de recomendaciones de Advisor.

No crear budgets, exports, alertas ni modificar recursos durante la implementación inicial.

## Entrega final

Entregar:

1. Archivos creados y modificados.
2. Integraciones existentes preservadas.
3. Fuentes de datos habilitadas.
4. Resultado exacto de pruebas PASS/FAIL.
5. Permisos de Cost Management detectados.
6. Consulta real de lectura realizada y período utilizado.
7. Ejemplo de reporte sanitizado con al menos tres gráficos útiles.
8. Confirmación de que `documentacion-metricas-azure-monitor-cli.md` fue excluido y permaneció intacto.
9. Confirmación de cero modificaciones en Azure.
10. Pendientes para el primer análisis completo.

No declarar que funciona si no se validó una consulta real de costos usando la sesión local de `az login`.
