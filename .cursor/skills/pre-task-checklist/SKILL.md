# Skill: Pre-Task Checklist — Consulta obligatoria antes de operar

## Cuándo aplicar

**SIEMPRE** antes de cualquier operación de escritura en este stack:
- Crear/modificar pipelines (Build, Release)
- Crear/modificar Variable Groups
- Crear/modificar manifests de Kubernetes (deployment, service, ingress, secrets, configmaps)
- Crear/modificar registros DNS en Cloudflare
- Crear/modificar workflows de n8n
- Crear/modificar permisos de ADO (grupos, membresías, ACEs)
- Crear/modificar configuración de Schema Sync
- Cualquier otra escritura a un recurso del stack

## Checklist obligatorio (ejecutar en orden)

### 1. Leer la memoria del dominio

Abrir `.cursor/memories/<subagente>/MEMORY.md` y `patterns.md` del dominio. Ahí están las decisiones, los errores ya resueltos y las preferencias. La tabla de qué carpeta corresponde está en `.cursor/rules/antes-de-actuar.mdc`.

No existe `memory_recall`.

### 2. Leer lecciones y sesiones anteriores

Buscar en `docs/` los archivos de lecciones del dominio y, si el tema aparece en `.local/sesiones-kiro/INDICE.md`, leer esos hilos.

No existe `learn_list`.

### 3. Leer el steering del dominio

Según el dominio de la tarea, leer el archivo correspondiente:

| Dominio | Archivo |
|---------|---------|
| Azure/ARM/FinOps | `.cursor/rules/azure.mdc` |
| AKS/Kubernetes/Helm | `.cursor/rules/aks.mdc` |
| ADO Pipelines | `.cursor/rules/azure-devops.mdc` |
| ADO Permissions | `.cursor/rules/azure-devops.mdc` |
| Cloudflare | `.cursor/rules/cloudflare.mdc` |
| n8n | `.cursor/rules/n8n.mdc` |
| Schema Sync | `.cursor/rules/schema-sync.mdc` |
| Servers Linux/Windows | `.cursor/rules/servers.mdc` |
| Teams Ops (alertas) | `.cursor/rules/teams-ops.mdc` |
| Multi-dominio | `.cursor/rules/orchestration.mdc` |

### 4. Leer el skill del dominio (si existe)

Los skills viven en `.cursor/skills/manage-<dominio>/SKILL.md`:

- `manage-azure-resources/SKILL.md`
- `manage-aks-clusters/SKILL.md`
- `manage-azure-devops-pipelines/SKILL.md`
- `manage-azure-devops-permissions/SKILL.md`
- `manage-cloudflare/SKILL.md`
- `manage-n8n-monitoring/SKILL.md`
- `manage-schema-sync-ssdt/SKILL.md`
- `manage-linux-servers/SKILL.md`
- `manage-windows-servers/SKILL.md`

Si el skill no existe, confiar en el steering.

### 5. Sesiones anteriores

Si hace falta contexto de un trabajo viejo, buscarlo en `.local/sesiones-kiro/INDICE.md` y leer el hilo. No existe `search_chat_history`.

## Aplicación a subagentes

Al delegar, el encargo tiene que nombrar el `SKILL.md` y las carpetas `.cursor/memories/` que el subagente debe leer antes de actuar. No existe `spawn_run` ni los flags `include_memory` / `include_lessons`.

## Excepciones (no requieren el checklist completo)

- **Lecturas puras:** `kubectl get`, `az show`, `GET` a APIs, inventarios
- **Diagnósticos:** revisar logs, estados, métricas
- **Respuestas a preguntas:** explicar algo, responder dudas
- **Operaciones triviales:** donde el contexto completo ya está en el mensaje del usuario

## Consecuencia de omitir el checklist

- Se repiten errores que ya fueron resueltos y guardados en lecciones
- Se ignoran decisiones previas del usuario
- El usuario tiene que recordarle al agente cosas que ya están documentadas
- Se pierde tiempo re-descubriendo problemas conocidos

## Ejemplo de uso correcto

**Usuario:** "Creá el pipeline para el nuevo servicio X"

**Agente (antes de hacer nada):**

1. Leer `.cursor/memories/ado-pipeline-builder/MEMORY.md` y `patterns.md`
2. Leer `.cursor/skills/manage-azure-devops-pipelines/SKILL.md`
3. Leer los docs que ese skill cita
4. Listar esas rutas en la respuesta

**Solo después**, armar el plan y presentarlo.
