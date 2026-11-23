# MCP `aks` — Azure/aks-mcp

## Versión fijada

- Proyecto: `Azure/aks-mcp`.
- Versión: **`v0.0.20`** — nunca `latest`.
- Binario: `aks-mcp-windows-amd64.exe`, descargado del release oficial de
  GitHub.
- SHA-256 esperado:
  `0aa997347a2971075c29b96ab8d943ca565c11b3ba805c605e17ebad29531a26`.
- Verificado programáticamente contra ese hash el 2026-08-26 antes de
  referenciarlo en `.mcp.json` (comparación de string, no solo inspección
  visual).
- Instalado en:
  `.local\aks\tools\aks-mcp\v0.0.20\aks-mcp.exe` (fuera de control de
  versiones).

## Configuración en `.mcp.json`

Proceso `stdio` local — nunca Docker, HTTP, SSE, proxy, gateway, ni
desplegado dentro del propio clúster.

```
"aks": {
  "type": "stdio",
  "command": "<ruta absoluta al .exe verificado>",
  "args": ["--access-level", "admin", "--timeout", "600", "--log-level", "info"],
  "env": { "USE_LEGACY_TOOLS": "false", "AKS_MCP_COLLECT_TELEMETRY": "false" }
}
```

- Sin `--allow-namespaces` (todos los namespaces disponibles).
- Sin `--enabled-components` (todos los componentes disponibles).
- Sin credenciales embebidas — usa la sesión `az` ya autenticada y el
  kubeconfig local del proceso que lo lanza.
- `AKS_MCP_COLLECT_TELEMETRY=false` — no se envía telemetría de uso.

## Reinstalar o actualizar (requiere aprobación)

1. Descargar el binario de la versión objetivo desde el release oficial
   de GitHub (`https://github.com/Azure/aks-mcp/releases`).
2. Calcular su SHA-256 y verificarlo contra el hash publicado para esa
   versión — nunca continuar si no coincide exacto.
3. Guardarlo en `.local\aks\tools\aks-mcp\<version>\aks-mcp.exe`.
4. Actualizar `.mcp.json` con la nueva ruta/versión — esto es "instalar,
   configurar o iniciar un MCP", exige aprobación explícita igual que la
   instalación inicial.
5. Reiniciar/recargar la sesión y repetir el handshake (`claude mcp get
   aks` + enumeración real de tools) antes de dar por completada la
   actualización.
6. Actualizar este documento con la nueva versión/hash — nunca dejar
   desactualizado el hash esperado.

## Tools reales — confirmadas 2026-08-26

Claude Code no recarga servidores MCP en caliente (agregar `aks` a
`.mcp.json` exige reiniciar/recargar la sesión antes de que la sesión
misma pueda invocar sus tools), pero la lista y el esquema real se
obtuvieron **sin esperar ese reload**: se envió un handshake MCP crudo
(`initialize` + `notifications/initialized` + `tools/list`) directo por
stdin/stdout contra el binario `v0.0.20` ya verificado, con
`--access-level admin` y sin `--enabled-components` (una vez instalados
helm/cilium/hubble — ver más abajo). `aks-security-gate.ps1` ya está
actualizado contra este esquema real (no la clasificación genérica
placeholder de antes).

13 tools expuestas:

| Tool | Clasificación en el hook | Motivo |
|---|---|---|
| `call_kubectl` | Delega al mismo clasificador que Bash/PowerShell (`Test-KubectlSegment`) sobre el campo `command` | Trae el comando kubectl completo como texto — misma forma exacta que una invocación de shell |
| `call_az` | Delega a `Test-AzSegment` sobre `cli_command`; `get-credentials` fuerza `ask` explícito | Ídem, más chequeo específico porque `call_az` acepta cualquier comando `az`, no solo `az aks` |
| `call_helm` | Delega a `Test-HelmSegment` sobre `command` | Ídem |
| `aks_advisor_recommendation` | **Siempre `allow`** | Su esquema real (`operation`: `list`/`report`) no expone ninguna operación de escritura, pese a que el servidor la anota `destructiveHint:true` (anotación inconsistente con su capacidad real) |
| `aks_detector` | **Siempre `allow`** | `operation`: `list`/`run`/`run_by_category` — todos diagnósticos de solo lectura sobre Azure, ninguno modifica el clúster |
| `aks_monitoring` | **Siempre `allow`** | Métricas, resource health, Application Insights, diagnostics, logs de control plane — todo lectura |
| `aks_network_resources` | **Siempre `allow`** | Consulta VNet/NSG/subnet/load balancer/private endpoint — solo lectura |
| `get_aks_vmss_info` | **Siempre `allow`** | Info de VMSS de solo lectura |
| `call_hubble` | **Siempre `allow`** | El propio servidor la anota `readOnlyHint:true`; Hubble es una CLI de observabilidad pura (no administra la instalación de Cilium) |
| `collect_aks_node_logs` | **Siempre `ask`** | El propio servidor la anota `readOnlyHint:false` — ejecuta un VMSS run-command real sobre el nodo aunque el resultado sea lectura de logs |
| `az_fleet` | Clasificación genérica por palabra clave sobre `operation`/`resource`/`args` (`list`/`show`→allow, `create`/`update`/`delete`/`get-credentials`→ask) | Mezcla operaciones de lectura y escritura bajo la misma tool según el valor de `operation` |
| `call_cilium` | Clasificación genérica por palabra clave sobre `command` | CLI de gestión de Cilium (`install`/`upgrade`/`uninstall` mutan; `status`/`endpoint list` no) |
| `inspektor_gadget_observability` | Clasificación genérica por palabra clave sobre `action` (`deploy`/`undeploy`/`run`/`start`/`stop`→ask, `get_results`/`list_gadgets`/`is_deployed`→allow) | Mezcla lectura de resultados con lifecycle de la extensión y ejecución de gadgets |

Cualquier tool nueva que aparezca en una versión futura del servidor cae
en la clasificación genérica por palabra clave (ver
`command-classification.md` § Tools MCP) hasta agregarla explícitamente
a esta tabla — nunca se asume lectura por default.

## Dependencias runtime descubiertas

Al arrancar sin `--enabled-components`, el binario valida en el inicio
que **todas** las CLIs de los 11 componentes disponibles
(`az_cli, monitor, fleet, network, compute, detectors, advisor,
inspektorgadget, kubectl, helm, cilium, hubble`) estén instaladas — si
falta alguna, el proceso termina inmediatamente con un error de
validación (visible como `CONNECTION_CLOSED` desde `claude mcp get aks`,
sin más detalle). En esta máquina faltaban `helm`, `cilium` y `hubble`;
se instalaron el 2026-08-26 (aprobado explícitamente por el usuario):

- `helm` — Chocolatey (`choco install kubernetes-helm`), v4.1.4 del
  paquete (hash verificado por el propio Chocolatey contra su feed).
- `cilium` (CLI) — Chocolatey (`choco install cilium-cli`), v0.19.7
  (ídem).
- `hubble` (CLI) — sin paquete en Chocolatey; descargado directo del
  release oficial `cilium/hubble` v1.19.4
  (`hubble-windows-amd64.tar.gz`), verificado por SHA-256 contra el
  `.sha256sum` publicado en el mismo release (match exacto confirmado por
  comparación de string), extraído a
  `.local\aks\tools\hubble\v1.19.4\hubble.exe` y copiado a
  `C:\ProgramData\chocolatey\bin\` (ya en el PATH del usuario por los
  otros dos paquetes) para quedar descubrible sin modificar variables de
  entorno.

Con los 3 instalados, el mismo handshake sin `--enabled-components`
inicializa correctamente ("All components enabled by default") y
`claude mcp get aks` reporta `Connected`.
