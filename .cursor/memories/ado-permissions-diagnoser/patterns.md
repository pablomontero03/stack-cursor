# Patrones — ado-permissions-diagnoser

## Orden de diagnóstico recomendado

1. Confirmar que el PAT existe (booleano, nunca el valor).
2. Confirmar que el namespace "Git Repositories" se resuelve en vivo y
   que las acciones del catálogo existen exactamente una vez cada una.
3. Si falla resolución de scope/identidad: revisar
   `Descriptors/Get`/`subjectquery` primero (endpoints no verificados con
   ejemplo oficial).
4. Si `Apply-*` omite una operación: es "skipped" por drift de
   precondición, comportamiento esperado — confirmar con el usuario antes
   de sugerir regenerar el plan.
5. Si `Apply-*` falla una operación real: revisar el journal de ejecución
   en `.local/azure-devops-permissions/executions/` antes de cualquier
   reintento.
6. Si un `set-git-permissions-ace` reportó "applied" pero el grupo no
   aparece en el portal (Security tab del repo/proyecto): NO asumir que
   funcionó por el código HTTP. Verificar con un GET crudo sin
   `&descriptors=` o con el Audit Log de la organización antes de seguir
   — ver `MEMORY.md` § "INCIDENTE MAYOR" del builder.

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
