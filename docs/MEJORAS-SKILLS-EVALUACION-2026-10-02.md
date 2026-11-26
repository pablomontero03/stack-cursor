# Mejoras agregadas — Evaluación de skills skills.sh (2026-10-02/03)

Resumen de lo incorporado al stack `automation-kiro` tras evaluar ~30 skills del catálogo
público skills.sh. **Criterio aplicado:** no instalar bundles de terceros; destilar solo los
fragmentos operativos aplicables a nuestra infra real, adaptados a nuestras herramientas vivas
(az CLI, MCP, kubectl, curl), y engancharlos desde la steering del dominio con **inserción pura**
(verificada por `git diff --numstat`, 0 borrados). Todo es **solo lectura / referencia**; nada
cambia recursos por sí mismo.

---

## 1. Documentos de referencia nuevos (`docs/`)

Cada doc se abre a demanda cuando la tarea lo toca; el agente lo encuentra por el *pointer* en la
steering del dominio (ver §2).

| Documento | Para qué sirve | Destilado de |
|---|---|---|
| `docs/METODO-DIAGNOSTICO-FALLOS.md` | Método disciplinado para diagnosticar cualquier fallo de infra (pod, pipeline, DACPAC, DNS, VG, n8n, servidor): (1) loop reproducible rojo/verde antes de teorizar, (2) minimizar, (3) 3-5 hipótesis falsables, (4) instrumentar una variable a la vez. Incluye **salvaguarda anti-ciclo**: si las hipótesis se agotan, ampliar el espacio o cambiar de enfoque, no orbitar las mismas ideas. | `mattpocock/diagnosing-bugs` |
| `docs/azure/KQL-ARG-DIAGNOSTICS-REFERENCE.md` | Queries Azure Resource Graph (resource health, provisioning, recursos degradados) y KQL de App Insights/Log Analytics para diagnóstico. Apuntadas a la suscripción Hospital Metropolitano, traducidas a `az graph query`/`az rest`. | `azure-skills/azure-diagnostics` + `azure-observability` |
| `docs/azure/FINOPS-COST-QUERY-FORECAST-REFERENCE.md` | FinOps completo: **Cost Management** (lo que gastamos — Query/Forecast por `az rest`), **ARG de recursos huérfanos** (discos/IPs/NICs sin usar, Advisor de costo), **priority score** para priorizar optimizaciones por ROI, **tracking vía ADO Boards** (no GitHub), y la **Retail Prices API** pública (lo que cuesta un SKU de lista — confirmada idéntica a la calculadora Azure). | `azure-skills/azure-cost` + `az-cost-optimize` + `azure-pricing` |
| `docs/azure/RESOURCE-GROUP-ARCHITECTURE-DIAGRAMS.md` | Procedimiento para diagramar la arquitectura de un Resource Group (todo ARM: VMs, redes, Firewall, VPN GW, Storage, Key Vault, App Registrations, SQL, AKS-recurso, Azure OpenAI): `az resource list` → mapear relaciones → Mermaid por capas. Con la regla de completitud (traer el RG entero, cubrir sub-recursos y dependencias cross-RG) y un **ejemplo vivo real** del hub `gmon_hub_rg_eastus2_0001`. | `azure-skills/azure-resource-visualizer` |
| `docs/aks/GRAFANA-DASHBOARDS-REFERENCE.md` | Patrones RED/USE, tipos de panel (JSON), variables de template y PromQL para armar dashboards en nuestro Grafana (`kube-prometheus-stack` en prod-onprem-01). Incluye **higiene de cardinalidad y volumen** self-hosted (hallar métricas caras, recording rules, drop de logs de health en Promtail). Nota: Alertmanager OFF, alerting por monitores n8n→Teams. | `wshobson/grafana-dashboards` + `grafana/cost-management` |
| `docs/aks/ROLLBACK-VERIFICACION-DEPLOYS-REFERENCE.md` | Cómo revertir y verificar un deploy en nuestros clusters: `rollout history/undo/status` + readback de health, con el **caveat del File Creator** (el rollback vivo lo revierte el próximo deploy del pipeline si el cambio vino del File Creator del Build ADO). | `jeffallan/devops-engineer` |

---

## 2. Pointers en steering (se cargan en contexto al operar cada dominio)

Inserción pura (0 borrados). Hacen que el agente **sepa que el doc existe y cuándo usarlo**.

| Archivo | Qué se agregó |
|---|---|
| `.cursor/rules/global.mdc` | Sección **"Consulta de documentación oficial Microsoft (transversal)"**: la CLI `mslearn` (`npx -y @microsoft/learn-cli`) como vía de consulta de doc Microsoft/Azure en todos los dominios — con la salvaguarda de que es **una opción, no la autoridad final** (combinar con criterio propio, web_search y el inventario en vivo). + pointer al método de diagnóstico. |
| `.cursor/rules/azure.mdc` | `mslearn` para doc oficial Azure; pointers a los docs FinOps, KQL/ARG y diagramas de RG. |
| `.cursor/rules/aks.mdc` | Pointers a los docs de Grafana dashboards y de rollback/verificación de deploys. |
| `.cursor/rules/n8n.mdc` | Sección **"Ciclo de construcción de un workflow (tools nativas del MCP)"**: el orden `get_workflow_best_practices` → `search_nodes`/`get_node_types` → `validate_node_config` → `validate_workflow` → `prepare_workflow_pin_data`/`test_workflow` → `publish_workflow`, + **higiene de JSON de nodo** (no credential placeholder, id=UUID v4, typeVersion vigente). |
| `.cursor/skills/analyze-azure-costs/SKILL.md` | Pointer al doc FinOps en su sección de fuentes. |

---

## 3. Lecciones guardadas (`learn_add`, scope automation-kiro)

Se cargan como correcciones aprendidas al inicio de sesión.

- **`mslearn` CLI** como vía de consulta de doc oficial Microsoft (transversal; una opción, no la autoridad final; solo lectura, no reemplaza az/MCP).
- **Azure Retail Prices API** pública para precios de lista (confirmada idéntica a la Pricing Calculator; no confundir con Cost Management).

---

## Skills que NO aportaron (descartados, no instalados)

La mayoría cayó por uno de estos motivos, documentados aquí para no re-evaluarlos:
- **Ecosistema de terceros** (inference.sh/belt, parallel.ai, ECC, cavekit, Matt Pocock router, OpenClaw): dependen de servicios/CLIs/formatos ajenos; varios enrutan tráfico/datos por un tercero.
- **Desarrollo de app** (Go benchmark, web performance, CrewAI, iOS App Store, Salesforce DX, architecture blueprint, prompt engineering, assistant-ui, PM metrics): asumen que escribimos/mantenemos aplicaciones; nosotros operamos infra.
- **Duplican el runtime** (continuous-learning, agentmemory, prompt-optimizer, ask-questions): Kiro Crew ya trae memoria/aprendizaje/clarificación nativos.
- **Versión/variante distinta** (los 3 de n8n de czlonkowski: nombres de tool distintos a nuestro MCP; los 3 de Elastic: asumen ES/Kibana 9.x + CLI `elastic`, tenemos 8.15 + curl/DSL — **quedan como PENDIENTE** si subimos a 9.x).
- **Cableado a otro tenant/producto** (azure-pipelines de VS Code: org `monacotools`; Grafana Cloud app-observability: no tenemos Cloud).

---

## Pendientes anotados

- **Elastic (ES|QL / onboarding / Kibana dashboards):** reevaluar si actualizamos el stack Elastic a 9.x con Kibana o instalamos la CLI `elastic`. Hoy: ES 8.15.1, acceso por curl+DSL para DataHub.
- Documentar el acceso a NUESTRO Elasticsearch (endpoint real, 8.15.1, credenciales `ES_GMONTECRISTO_*`, curl+DSL) — acordado NO implementar ahora.
