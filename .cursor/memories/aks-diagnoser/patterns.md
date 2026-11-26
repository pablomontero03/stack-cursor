# Patterns — aks-diagnoser

## Clústeres reales de este proyecto viven en kubeconfigs de Lens

Confirmado 2026-08-26 — mismo hallazgo que en la memoria de
`aks-operator` (ver ese archivo para la tabla completa). Resumen: NO usar
la resolución ambiente por defecto (`$env:USERPROFILE\.kube\config`
apunta a un clúster ajeno, `gmon-innovacion-aks-eastus2-0001`). Los reales
son 3 kubeconfigs bajo `$env:APPDATA\Lens\kubeconfigs\`: 1 desarrollo
(k3s, nodo único `srv-desarrollo-5`) y 2 con clústeres AKS de dev/qa/prod
(incluido `gmon-prod-aks-eastus2-0004`, ya conocido de los pipelines ADO
de este proyecto).

**How to apply:** cualquier diagnóstico pedido "sobre el cluster de
desarrollo/producción" debe resolver primero CUÁL de los 3 kubeconfigs y
qué contexto usar (el mismo nombre de contexto puede repetirse entre los
2 archivos de prod) — nunca asumir el kubeconfig por defecto de la
máquina. `Test-AksEnvironment.ps1` reporta la lista y sus contextos.

## Regla crítica: no procesar JSON grande inline en shell
**Causa de crashes del gateway confirmada en producción (2026-09-21).**

Procesar JSON de más de ~50KB directamente en el tool de shell (heredoc Python inline, `curl | python3`, `python3 -c "..."` con JSON grande) bloquea el ACP y tumba el gateway.

**Patrón correcto obligatorio:**
1. Descargar/guardar el JSON a un archivo en disco: `curl ... -o /tmp/data.json`
2. Procesar con un script `.py` separado que lee del archivo
3. Guardar el resumen en `/tmp/output.txt`
4. Leer y mostrar solo el `.txt` (que es corto)
5. Limpiar temporales: `rm -f /tmp/data.json /tmp/output.txt`

**Nunca:**
- Python inline con JSON de cientos de KB en el mismo comando
- `curl ... | python3 -c '...'` con respuesta grande
- Heredoc con JSON inline de cientos de líneas
- Usar `/tmp` directamente en bash sin verificar que existe

**Aplica a:** inventarios ADO, manifests Kubernetes, respuestas de API con listas largas, archivos de configuración grandes.

## Regla: no ejecutar setup.sh de Kiro
**Causa de crashes del gateway confirmada en producción (2026-09-21).**

No ejecutar `setup-kiro.sh` ni `source ./setup.sh`. Las variables se cargan con `set -a; source env/.env; set +a`. `./setup-cursor.sh` no reinicia el worker.

**Siempre usar `--no-restart` cuando se ejecuta desde una sesión activa de Crew:**
```bash
set -a; source env/.env; set +a
```

**Cuándo SÍ reiniciar (sin --no-restart):**
- Primera instalación en una máquina nueva
- Cuando el operador lo pide explícitamente
- Cuando se agregan nuevos agentes o skills que requieren recarga

**Cuándo NO reiniciar (usar --no-restart):**
- Cualquier vez que el agente ejecuta setup.sh para cargar variables de entorno
- Al inicio de scripts que solo necesitan `$REPO_ROOT`, `$AZURE_DEVOPS_PAT`, etc.
