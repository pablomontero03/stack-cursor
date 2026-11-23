# Timeouts recomendados — AIA-CC-MAIA-Chat

> Copiado desde `c:\PabloDocs\aplicativos\flujos\MAIA-timeouts-recomendados.md`
> el 2026-08-20 para que viva dentro de la raíz del proyecto. Fuente
> operativa de verdad para el alcance "n8n Monitoreo SQL / MAIA" de
> `CLAUDE.md`. Ver también `.claude/skills/manage-n8n-monitoring/SKILL.md`.
>
> **Instancia:** este workflow vive en la n8n **productiva de la empresa**
> (`https://automation.grupomontecristo.com`, MCP `n8n-productivo`), no en
> la instancia interna de monitoreo SQL (`n8n-interno`,
> `172.16.2.60:5678`) — aunque este doc esté guardado junto a los del
> monitoreo SQL por venir del mismo lote original. Corregido 2026-08-20.

Workflow: **AIA-CC-MAIA-Chat** (`DzYc4AtiN1Psphpj`)  
Entorno: producción (`gmon-prod-aks-eastus2-0001`, namespace `grupomontecristo`)  
Fecha de referencia: junio 2026  

Documento de recomendaciones. **No implica cambios aplicados.**

---

## Unidades en n8n

- **Embeddings:** segundos (campo *Timeout* en Options)
- **Chat Model:** milisegundos (campo *Timeout* en Options)

---

## Embeddings (`text-embedding-3-large`)

Recomendación uniforme: **60 s** en todos.

| Nodo | Vector store | Actual | Recomendado |
|------|--------------|--------|-------------|
| Embeddings Azure OpenAI | Red_Medica_MS | 12 s | **60 s** |
| Embeddings Azure OpenAI1 | Cotizador_MS | 12 s | **60 s** |
| Embeddings Azure OpenAI2 | Red_Medica_HM | 12 s | **60 s** |
| Embeddings Azure OpenAI3 | PortalCC | 60 s | **60 s** (mantener) |
| Embeddings Azure OpenAI4 | Promociones | 12 s | **60 s** |
| Embeddings Azure OpenAI5 | Glosario Medico | 12 s | **60 s** |
| Embeddings Azure OpenAI6 | BD_Radiología | 12 s | **60 s** |
| Embeddings Azure OpenAI7 | BD_Magna | 12 s | **60 s** |
| Embeddings Azure OpenAI8 | BD Sanford | 12 s | **60 s** |
| Embeddings Azure OpenAI10 | info_Santa_Cata | 12 s | **60 s** |
| Embeddings Azure OpenAI11 | Info_completa | 12 s | **60 s** |
| Embeddings Azure OpenAI12 | Info_MS_HM | 12 s | **60 s** |

---

## Chat Model (`gpt-4.1`)

| Nodo | Agente | Actual | Recomendado |
|------|--------|--------|-------------|
| Azure OpenAI Chat Model | **AI Agent** (principal) | 12 000 ms (12 s) | **120 000 ms (120 s)** |
| Azure OpenAI Chat Model9 | **AI Agent1** (login/validación) | 12 000 ms (12 s) | **60 000 ms (60 s)** |
| Azure OpenAI Chat Model1 | Modulo_Doctores | 200 000 ms (200 s) | **200 000 ms** (mantener) |
| Azure OpenAI Chat Model5 | Modulo_Radiologia | 200 000 ms (200 s) | **200 000 ms** (mantener) |
| Azure OpenAI Chat Model3 | Modulo_Info_General | 12 000 ms (12 s) | **90 000 ms (90 s)** |
| Azure OpenAI Chat Model4 | Información Sanford | 12 000 ms (12 s) | **90 000 ms (90 s)** |
| Azure OpenAI Chat Model6 | Magna_Medica | 12 000 ms (12 s) | **90 000 ms (90 s)** |
| Azure OpenAI Chat Model7 | Modulo_Santa_Catalina | 12 000 ms (12 s) | **90 000 ms (90 s)** |
| Azure OpenAI Chat Model8 | Modulo_Procedimientos_especificos | 12 000 ms (12 s) | **90 000 ms (90 s)** |
| Azure OpenAI Chat Model10 | Info_call_center | 12 000 ms (12 s) | **90 000 ms (90 s)** |

---

## Nodos sin timeout configurable en el nodo

| Nodo | Actual | Recomendado |
|------|--------|-------------|
| Code | Sin timeout propio | Depende de infra (ver abajo) |
| Code in JavaScript | Sin timeout propio | Depende de infra (ver abajo) |
| AI Agent / sub-agentes (agentTool) | Sin timeout propio | Lo cubren los Chat Model de arriba |

---

## Ajustes fuera de nodos (referencia)

| Configuración | Actual | Recomendado |
|---------------|--------|-------------|
| **Timeout Workflow** (settings del workflow) | OFF | **180 s** |
| `N8N_RUNNERS_TASK_REQUEST_TIMEOUT` (cola Code) | 60 s (default) | **90 s** solo si vuelven errores de cola |
| `N8N_RUNNERS_TASK_TIMEOUT` (ejecución Code) | 300 s (default) | **300 s** (mantener) |

---

## Resumen rápido

- **11 embeddings** pasar de 12 → **60 s**; **OpenAI3** ya está bien.
- **8 chat models** pasar de 12 s → **90 s** (sub-agentes) o **120 s** (agente principal) o **60 s** (login).
- **Chat Model1** y **Chat Model5** ya están en **200 s**; no hace falta tocarlos.

---

## Nota

En una captura de UI, **Embeddings Azure OpenAI3** mostraba **12 s**, pero en BD guardado está en **60 s**. Al aplicar cambios, conviene guardar el workflow y verificar que la UI coincida con lo guardado.
