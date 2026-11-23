# Guia de graficos y entregables (Azure FinOps)

## Elegir el grafico segun la pregunta -- no generar todos automaticamente

| Pregunta | Grafico |
|---|---|
| Como evoluciono el costo? | Linea (diaria o mensual) |
| Que compone el gasto? | Barras apiladas (por servicio/resource group) |
| Que recursos concentran el gasto? | Pareto |
| Por que cambio el costo entre dos periodos? | Waterfall |
| Hay un patron por dia/hora? | Heatmap |
| El costo se explica por el uso? | Dispersion (costo vs. utilizacion) |
| Ranking / recomendaciones accionables | Tabla |

## Formatos admitidos

- Resumen Markdown -- siempre el entregable principal.
- CSV -- datos normalizados (una fila por combinacion de dimensiones,
  columnas de moneda/tipo de costo explicitas).
- Excel -- tablas, filtros y graficos cuando el analisis lo amerite.
- PNG o SVG -- grafico individual embebido o referenciado.
- HTML autocontenido -- informe navegable con multiples graficos/
  secciones, sin dependencias externas cargadas desde internet.

## Donde se guardan

Todo entregable con datos reales de costo va bajo `.local/azure/finops/`
(no versionado -- ver `SKILL.md` seccion Rutas locales):

- `raw/` -- respuesta cruda de la API, sanitizada (sin headers de
  autenticacion).
- `normalized/` -- datos ya normalizados (moneda, periodo, formulas
  aplicadas).
- `reports/` -- Markdown/CSV/Excel/HTML.
- `charts/` -- PNG/SVG individuales.
- `executions/` -- manifiesto sanitizado de la corrida (ver
  `New-AzureFinOpsReport.ps1`).

Nunca escribir datos financieros descargados dentro de `docs/`, memoria
de agentes (`.claude/agent-memory/azure-finops-analyst/`), ni ningun
archivo versionado del repo -- esos lugares solo pueden contener
metodologia, esquemas sanitizados y ejemplos ficticios.

## Contenido minimo de un resumen ejecutivo

- Costo del periodo consultado y costo acumulado del mes (si aplica).
- Pronostico de cierre (si se pidio).
- Variacion absoluta y porcentual frente al periodo comparable --
  normalizada si se compara un mes parcial contra uno completo (ver
  cost-definitions.md).
- Principales responsables del cambio.
- Anomalias relevantes detectadas.
- Ahorro potencial identificado, con su nivel de confianza.
