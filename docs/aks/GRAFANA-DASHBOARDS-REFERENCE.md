# Referencia — Dashboards Grafana (para uso del agente)

> Patrones para diseñar y construir dashboards en **nuestro** Grafana. Destilado del
> skill público `wshobson/agents/grafana-dashboards` (2026-10-02) y adaptado al stack
> real. **No instalamos el skill** — rescatamos los patrones.
>
> **Esto es un PUNTO DE PARTIDA, no un techo.** RED/USE y los paneles de abajo son el
> andamiaje por defecto; el agente debe **adaptarlos y extenderlos** a lo que la
> pregunta real pida (métricas de negocio, trazas, correlación con logs de Loki,
> paneles ad-hoc). No limitarse a copiar RED/USE si el caso necesita más.

## Nuestro Grafana (inventario vivo — confirmar antes de operar)

- Stack: **kube-prometheus-stack v91.4.1** en el cluster **`prod-onprem-01`** (k3s .31),
  ns `monitoring`. Trae Prometheus + Grafana + node-exporter + kube-state-metrics.
  Retención 15d, **Alertmanager OFF** (reglas ON, sin alerting), limits explícitos.
- URL: `https://grafana-onprem-01.grupomontecristo.com` (login propio, password en
  `env/.env` → `GRAFANA_ONPREM01_ADMIN_PW`; nunca imprimirla). DNS proxied + Origin Rule :4443.
- **Logs: Loki + Promtail** (grafana/loki-stack v2.10.3, ns `monitoring`, retención 7d).
  Datasource Loki disponible en el mismo Grafana → se puede correlacionar métrica↔log.
- Los microservicios **Buklo** exponen métricas Prometheus: anotaciones
  `prometheus.io/scrape:"true"`, `prometheus.io/port:"3000"`, `prometheus.io/path:"/api/v1/metrics"`.
- Métricas de infra disponibles del stack: `node_*` (node-exporter: CPU/RAM/disco/red del
  .31), `kube_pod_info`/`kube_*` (kube-state-metrics), `container_*` (cAdvisor).

> Nota: el cluster es nodo único por diseño; no hay autoscaling de nodos ni service mesh.
> Dashboards de "flota de nodos" no aplican — es un host.

---

## Métodos de diseño (andamiaje, no límite)

### RED — para SERVICIOS (los microservicios Buklo)
- **Rate** — requests/seg: `sum(rate(http_requests_total[5m])) by (service)`
- **Errors** — % error: `sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m])) * 100`
- **Duration** — latencia p95: `histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service))`

> Ajustar los nombres de métrica a lo que el servicio Buklo expone realmente en
> `/api/v1/metrics` — confirmar con una query en Explore antes de fijar el panel; no
> asumir `http_requests_total` si el servicio usa otro nombre.

### USE — para RECURSOS (nodo .31, pods)
- **Utilization** — CPU nodo: `100 - (avg by (instance)(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)`
- **Saturation** — presión/cola: `node_load1`, memoria disponible `node_memory_MemAvailable_bytes`
- **Errors** — p.ej. reinicios de pod: `kube_pod_container_status_restarts_total`

### Más allá de RED/USE (extender según el caso)
- **Negocio/KPIs**: contadores propios que exponga la app (ej. citas creadas, cotizaciones).
- **Correlación con Loki**: panel de logs filtrado por `{namespace="$namespace", pod="$pod"}`
  junto al panel de métrica, para saltar de un pico a sus logs.
- **Saturación de recurso vs límite**: `kubectl top` equivalente en PromQL —
  `sum(container_memory_working_set_bytes{pod=~"$pod"}) / sum(kube_pod_container_resource_limits{resource="memory",pod=~"$pod"})`.
  (Esto conecta con la lección de OOM: ver uso asentado vs límite.)

---

## Jerarquía de información (de arriba a abajo)

1. **Big numbers** (stat): estado crítico de un vistazo (up/down, error rate actual).
2. **Tendencias** (time series): rate, latencia, CPU/mem en el tiempo.
3. **Detalle** (table/heatmap): estado por pod, distribución de latencia.

---

## Tipos de panel (JSON base)

### Stat (valor único con umbrales)
```json
{
  "type": "stat",
  "title": "Error Rate %",
  "targets": [{ "expr": "sum(rate(http_requests_total{status=~\"5..\"}[5m])) / sum(rate(http_requests_total[5m])) * 100" }],
  "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "value" },
  "fieldConfig": { "defaults": { "unit": "percent", "thresholds": { "mode": "absolute",
    "steps": [ {"value":0,"color":"green"}, {"value":1,"color":"yellow"}, {"value":5,"color":"red"} ] } } }
}
```

### Time series
```json
{
  "type": "timeseries",
  "title": "Request Rate por servicio",
  "targets": [{ "expr": "sum(rate(http_requests_total[5m])) by (service)", "legendFormat": "{{service}}" }],
  "fieldConfig": { "defaults": { "unit": "reqps" } }
}
```

### Table (estado instantáneo)
```json
{
  "type": "table",
  "title": "Pods arriba",
  "targets": [{ "expr": "up", "format": "table", "instant": true }],
  "transformations": [{ "id": "organize", "options": { "renameByName": { "instance": "Instancia", "job": "Servicio", "Value": "Estado" } } }]
}
```

### Heatmap (distribución de latencia)
```json
{
  "type": "heatmap",
  "title": "Latencia (heatmap)",
  "targets": [{ "expr": "sum(rate(http_request_duration_seconds_bucket[5m])) by (le)", "format": "heatmap" }],
  "dataFormat": "tsbuckets",
  "yAxis": { "format": "s" }
}
```

## Variables de template (dashboards reutilizables)

```json
{ "templating": { "list": [
  { "name": "namespace", "type": "query", "datasource": "Prometheus",
    "query": "label_values(kube_pod_info, namespace)", "refresh": 1 },
  { "name": "pod", "type": "query", "datasource": "Prometheus",
    "query": "label_values(kube_pod_info{namespace=\"$namespace\"}, pod)", "refresh": 1, "multi": true }
] } }
```
Usar en queries: `...{namespace="$namespace", pod=~"$pod"}`. (Es el mismo patrón del
dashboard "Logs por Namespace" que ya tenemos con Loki.)

## Buenas prácticas

1. Confirmar el **nombre real** de cada métrica en Explore antes de fijar el panel.
2. Unidades correctas (`reqps`, `percent`, `s`, `bytes`) y umbrales con significado.
3. Agrupar métricas relacionadas en filas; descripciones en los paneles.
4. Variables para no clonar dashboards por servicio/namespace.
5. Rango por defecto razonable (6h) y probar con varios rangos.
6. Arrancar de un dashboard de la comunidad cuando exista y adaptarlo, no desde cero.

## Alertas — matiz de nuestro stack

El skill original mete alertas en el panel. **Nuestro Alertmanager está OFF** en
`prod-onprem-01` (reglas ON, sin routing). El alerting operativo hoy lo cubren los
**3 monitores AKS de n8n-interno** (CPU/mem, disco PVC, reinicios → Teams). Si se
quiere alertar desde Grafana, primero habilitar Alertmanager/contact points — es un
cambio de infra con su propia validación, no asumirlo disponible.

## Higiene de cardinalidad y volumen (self-hosted)

Destilado del skill `grafana/skills/cost-management`, **traducido de Grafana Cloud a nuestro
kube-prometheus-stack self-hosted**: NO tenemos Adaptive Metrics/Logs/Traces ni Alloy ni factura
Cloud. Aquí el "costo" no es una factura por serie/byte — es **memoria y disco de nuestro Prometheus/
Loki en `prod-onprem-01`** (nodo único, recursos del cluster congelados). Bajar cardinalidad y volumen
es alivio de recursos reales, no ahorro de bill.

### Métricas — hallar y domar alta cardinalidad

La cardinalidad (labels con muchos valores: `pod`, `instance`, `id` únicos) multiplica las series
activas y es la causa #1 de presión de memoria en Prometheus. Diagnóstico en Explore (PromQL):

```promql
# Métricas con más series (las más caras en memoria)
topk(20, count by (__name__)({__name__=~".+"}))

# Para una métrica concreta, qué label explota la cardinalidad
count(http_request_duration_seconds_bucket) by (le)        # ejemplo: buckets
count(count by (<label>) (<metrica>))                      # valores distintos de un label
```

- **No agregar labels de altísima cardinalidad** (ids de request, UUIDs, timestamps) a métricas
  custom de los microservicios Buklo — infla Prometheus sin valor de dashboard.
- **Recording rules** para queries caras/ad-hoc que se repiten en dashboards: pre-agregan en
  ingestión y evitan recalcular rangos largos en cada refresh (menos CPU/latencia). Van en las
  `PrometheusRule` del kube-prometheus-stack (Helm values o CR `PrometheusRule`), no en la UI.

### Logs (Loki/Promtail) — bajar bytes ingeridos

El ruido típico son los **health/readiness probes** y accesos repetitivos. Se dropean en el pipeline
de **Promtail** (nuestro agente, no Alloy) con una stage `drop`:

```yaml
# En el pipeline_stages del scrape de Promtail
- drop:
    expression: '.*(GET|HEAD) /(health|healthz|readyz|api/health).*'
```

Verificar el efecto (LogQL): los accesos de health deben caer a ~0 y los bytes ingeridos bajar.

```logql
sum(rate({namespace="<ns>"} |~ "/health" [5m]))   # debe tender a 0 tras el filtro
```

- Confirmar SIEMPRE que el filtro no tape un error real antes de dropear (un `/health` que empieza a
  dar 500 es señal, no ruido — dropear solo los 200).
- Cambios en Promtail/PrometheusRule son **config de infra** (ciclo agéntico), pero en
  `prod-onprem-01` **enunciar que es prod** antes de aplicar y validar readback.

## Reglas de uso para el agente

- Grafana es **lectura/visualización**; crear/editar dashboards es config, no toca datos.
- No imprimir `GRAFANA_ONPREM01_ADMIN_PW` ni ningún secreto.
- Confirmar contexto (`kubectl config current-context` = `prod-onprem-01`) y métricas
  vivas antes de construir; no asumir nombres de métrica de esta guía.
- Preferir **dashboard-as-code** (JSON versionado) sobre edición manual perdible;
  nuestro provisioning es Helm (kube-prometheus-stack), no Terraform/Ansible.

## Fuente

- Skill `wshobson/agents/grafana-dashboards` (patrones RED/USE, JSON de paneles, PromQL).
- Adaptado a kube-prometheus-stack `prod-onprem-01` + Loki + microservicios Buklo.
