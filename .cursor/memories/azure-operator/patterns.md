# Patterns — azure-operator

Convenciones y decisiones técnicas confirmadas del dominio Azure
Resources. Ninguna todavía más allá de lo ya documentado en
`.cursor/rules/azure.mdc` (no se duplica
aquí) — este agente se creó el 2026-09-03 sin ejecuciones reales previas.

Punto de partida conocido en esta máquina (no un "patrón" del dominio en
sí, solo contexto de sesión, sanitizado): Azure CLI 2.61.0 ya autenticado
al momento de crear este dominio, tenant "Hospital Metropolitano"
(`33dd4184-...`), suscripción por defecto "Hospital Metropolitano"
(`69dc43ec-...`), usuario `helpdesk@grupomontecristo.com`. No asumir que
sigue siendo la sesión activa en una invocación futura — siempre
reverificar con `Test-AzureEnvironment.ps1`.

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
