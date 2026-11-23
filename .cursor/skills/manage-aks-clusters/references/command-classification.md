# Clasificación de comandos — AKS/Kubernetes/Helm

Fuente operativa de lo que `aks-security-gate.ps1` implementa. Si hay
alguna discrepancia entre este documento y el hook real, el hook es la
fuente de verdad ejecutable — actualizar este documento para que coincida,
nunca al revés.

Principio: un comando o tool no listado aquí **siempre pregunta**, nunca
se asume lectura ni se bloquea de forma permanente.

## kubectl — permitido automáticamente

| Subcomando | Nota |
|---|---|
| `get` | Salvo `get secret(s)` con `-o yaml/json/jsonpath/go-template` (expone `data`) — eso pregunta |
| `describe` | |
| `logs` | |
| `events` (o `get events`) | |
| `top` | |
| `api-resources`, `api-versions`, `version`, `cluster-info` | |
| `auth can-i` | Siempre de solo lectura |
| `explain` | |
| `diff` | |
| `wait` | Nunca modifica por sí mismo |
| `rollout status`, `rollout history` | Lectura — distinto de `rollout restart`/`undo` |
| `config get-contexts`, `config current-context`, `config view` (sin `--raw`) | |
| `apply`, `create`, `replace` con `--dry-run=server` o `--dry-run=client` | Ninguno contacta el API server de forma mutante |

## kubectl — siempre pregunta

`apply`/`create`/`replace` sin dry-run, `patch`, `edit`, `delete`,
`scale`, `autoscale`, `label`, `annotate`, `set`, `expose`, `run`,
`rollout restart`, `rollout undo`, `cordon`, `uncordon`, `drain`, `taint`,
`certificate approve|deny`, `exec`, `attach`, `cp`, `debug`, `proxy`,
`port-forward`, `config use-context|set-context|set-cluster|
set-credentials|delete-context`, `config view --raw`, `get secret(s)` con
salida decodificable, y cualquier subcomando no listado arriba.

## Azure CLI (`az`) — permitido automáticamente

`az account show`, `az account list`, `az aks list`, `az aks show`,
`az aks nodepool list`, `az aks nodepool show`.

## Azure CLI — siempre pregunta

`az aks create|update|delete|upgrade|scale|start|stop`, `az aks
get-credentials` (modifica el kubeconfig local), crear/modificar/eliminar
node pools, cambios de red/identidad/RBAC/extensiones/Fleet/Azure
Monitor, y cualquier subcomando `az aks`/`az account` no listado arriba.

## Helm — permitido automáticamente

`list`, `status`, `history`, `get`, `show`, `search`, `template`, `lint`,
`upgrade --dry-run`.

## Helm — siempre pregunta

`install`, `upgrade` sin `--dry-run`, `rollback`, `uninstall`.

## Tools MCP `mcp__aks__*`

Esquema real de las 13 tools confirmado 2026-08-26 (ver `aks-mcp.md` §
Tools reales para la tabla completa y cómo se obtuvo sin esperar un
reload de sesión). Resumen de la lógica que implementa
`aks-security-gate.ps1`:

1. `call_kubectl` / `call_az` / `call_helm` — el comando completo viaja
   como texto en `command`/`cli_command`; se reusan los mismos
   clasificadores que para Bash/PowerShell (`Test-KubectlSegment`/
   `Test-AzSegment`/`Test-HelmSegment`), más un chequeo explícito de
   `get-credentials` para `call_az` (no solo `az aks get-credentials`,
   cualquier comando `az` que lo mencione).
2. `aks_advisor_recommendation`, `aks_detector`, `aks_monitoring`,
   `aks_network_resources`, `get_aks_vmss_info`, `call_hubble` — siempre
   `allow`: su esquema real no expone ninguna operación de
   escritura/eliminación.
3. `collect_aks_node_logs` — siempre `ask`: el propio servidor la anota
   `readOnlyHint:false` (ejecuta un VMSS run-command real).
4. `az_fleet`, `call_cilium`, `inspektor_gadget_observability` — mezclan
   lectura y escritura según un campo (`operation`/`action`/`command`);
   se clasifican por presencia de palabra clave sobre el nombre + todo el
   `tool_input` serializado (mutante: `apply|create|replace|patch|edit|
   delete|scale|autoscale|label|annotate|expose|run|cordon|uncordon|
   drain|taint|exec|attach|debug|proxy|port-forward|install|upgrade|
   rollback|uninstall|write|update|set|remove|start|stop|deploy|undeploy|
   enable|disable|credentials`; lectura: `get|list|describe|logs|events|
   top|status|history|show|search|explain|diff|version|read|report|
   results`; si menciona `secret` → pregunta siempre sin excepción).
5. Cualquier tool nueva no listada en los puntos 1-3 cae en la
   clasificación genérica del punto 4 — nunca se asume lectura por
   default; si ni la lista de lectura ni la de escritura matchean, el
   resultado es `ask`.

## Información sensible — siempre pregunta

Decodificar un `Secret`, mostrar un token de ServiceAccount, mostrar una
credencial de registry, mostrar un certificado o clave privada,
`kubectl config view --raw`, o cualquier comando cuyo resultado pueda
contener uno de estos valores. Listar nombres/metadatos de `Secret` (sin
proyectar `data`) sí está permitido automáticamente.

## Deny absoluto (defensa en profundidad, no política general)

`bypassPermissions`/`--dangerously-skip-permissions`, y copiar un
kubeconfig hacia una ruta del repositorio (`cluster\`, `docs\`, `.claude\`,
`.local\aks\`). Estos son los únicos 2 casos que el hook resuelve con
`deny` — todo lo demás no clasificado resuelve a `ask`.
