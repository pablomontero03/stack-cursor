# Patrones — linux-server-diagnoser

Categorías de fallo que ya usa el proceso de este agente (ver su
frontmatter/instrucciones): recursos del host (CPU, memoria, disco,
inodes), servicio del sistema caído, contenedor (crash loop, OOMKilled,
unhealthy, imagen desactualizada), red (puerto/DNS/red Docker), volumen
(montaje, permisos, espacio), aplicativo específico (BD, cache, breaking
change de versión, variable de entorno — varía por servidor: n8n en
`172.16.2.60`, Elastic/Ollama en `172.16.2.31`, agente de Azure DevOps en
`10.1.0.200`, clúster de desarrollo en `172.16.2.43`, Open edX en
`openedx`), o configuración (compose/unit systemd desactualizado, valor
incorrecto). Patrones reales confirmados (qué causa raíz es más frecuente
en cada servidor puntual) se agregan solo cuando el agente los confirme
en diagnósticos reales — todavía no hay ninguno.

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
