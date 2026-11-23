# Arquitectura — Administración de AKS

Implementado 2026-08-26, de forma aditiva sobre la arquitectura ya
existente para n8n, Azure DevOps Pipelines, Azure DevOps Permissions,
Schema Sync y `manage-linux-servers`. Este documento describe el diseño; la
operación cotidiana vive en
`.claude/skills/manage-aks-clusters/SKILL.md`.

## Objetivo

Permitir administrar clústeres AKS/Kubernetes/Helm con el mismo modelo de
seguridad y aprobación que los demás dominios del repositorio:
lectura/inventario/diagnóstico automáticos, escritura real bajo
aprobación explícita por lote atómico, eliminación siempre con su propia
aprobación y respaldo obligatorio, y ninguna prohibición absoluta sobre
una operación legítima de AKS.

## Componentes

```
.claude/
  skills/manage-aks-clusters/
    SKILL.md                          -- enrutamiento por modo
    references/*.md                   -- 7 documentos operativos
    scripts/
      Aks-Common.ps1                  -- hash canonico, journal, kubeconfig
      Test-AksEnvironment.ps1         -- diagnostico de entorno (lectura)
      Get-AksInventory.ps1            -- inventario sanitizado (lectura)
      Invoke-AksRead.ps1              -- wrapper de lectura kubectl
      New-AksChangePlan.ps1           -- genera plan inmutable
      Test-AksChangePlan.ps1          -- valida + escribe validationHash
      Apply-AksChangePlan.ps1         -- UNICO script que escribe al cluster
      Test-AksPostChange.ps1          -- readback
      Invoke-AksRollback.ps1          -- propone rollback (nunca ejecuta)
      tests/run-script-tests.ps1      -- 16 casos, mocks, sin red/cluster
  agents/aks/
    aks-operator.md                   -- inventario/plan/apply aprobado
    aks-diagnoser.md                  -- solo lectura
    aks-reviewer.md                   -- revision independiente del plan
  agent-memory/aks-{operator,diagnoser,reviewer}/
    MEMORY.md, debugging.md, patterns.md
  rules/aks/
    authorization.md                  -- que exige aprobacion
    security.md                       -- que proteger y por que
  hooks/aks/
    aks-security-gate.ps1             -- PreToolUse (Bash/PowerShell/mcp__aks__*)
    aks-post-validate.ps1             -- PostToolUse (Write/Edit/MultiEdit)
    aks-stop-validate.ps1             -- Stop (revision final de sesion)
    aks-secret-scan-lib.ps1           -- deteccion de secretos compartida
    tests/run-hook-tests.ps1          -- 77 casos, mocks, sin red/cluster

docs/aks/AKS-AUTOMATION-ARCHITECTURE.md -- este documento
cluster/                                -- manifiestos K8s sanitizados y versionables
.local/aks/ (no versionado)
  inventory/  plans/  backups/  executions/  tools/  logs/
```

## Modelo de autorización

| Categoría | Decisión | Ejemplos |
|---|---|---|
| Lectura, inventario, diagnóstico, `diff`, `--dry-run=server` | Automático | `kubectl get/describe/logs`, `az aks list/show`, `helm list/status/template` |
| Escritura real, eliminación, acción interactiva | Preguntar (aprobación explícita) | `kubectl apply/patch/delete/exec`, `helm install/upgrade/uninstall`, `az aks update/delete` |
| Lectura de secretos / kubeconfig `--raw` | Preguntar siempre | `kubectl get secret -o yaml`, `config view --raw` |
| Comando/tool MCP no reconocido | Preguntar (nunca denegar) | cualquier `mcp__aks__*` sin clasificación cierta |
| `bypassPermissions`, copiar kubeconfig al repo | Deny absoluto (los únicos 2 casos) | defensa en profundidad, no política general |

Implementado por `aks-security-gate.ps1`: parsea `Bash`/`PowerShell`
(decodificando `-EncodedCommand`, dividiendo comandos compuestos, sin
depender del orden de los argumentos) y toda tool real `mcp__aks__.*`.

## Plan de cambio — esquema y garantías

Un plan (`New-AksChangePlan.ps1`) es JSON con: `cluster`
(suscripción/resource group/nombre/contexto), `namespace`, `operations` /
`approvedOperations` (el mismo lote — nunca se aprueba un subconjunto
distinto del declarado), `impact` (qué cambia, qué no, dependencias,
indisponibilidad posible, verificación, rollback), `validation`
(dry-run/diff/`auth can-i` realizados), y — una vez validado —
`validated=true` + `validationHash` (SHA-256 canónico sobre todo lo
anterior) + `validationEvidence` (inventario usado, su antigüedad,
timestamp de validación).

`Apply-AksChangePlan.ps1` rechaza cualquier plan cuyo `validationHash` no
coincida con el contenido actual del archivo, cuyo contexto actual
(`kubectl config current-context`) no coincida con `plan.cluster.context`,
o que no tenga `validated=true`. Cada operación se registra en un journal
(`​.local/aks/executions/<validationHash>.json`) protegido con lock
exclusivo de archivo (`FileShare.None`) y escritura atómica
(archivo temporal + `Move-Item -Force`) — una operación ya
`succeeded`/`in-progress`/`ambiguous` nunca se reintenta automáticamente.
Toda eliminación escribe un respaldo de solo lectura antes del `delete`
real; un respaldo fallido detiene la operación sin borrar nada.

## MCP `aks`

`Azure/aks-mcp` v0.0.20, binario Windows AMD64 verificado por SHA-256
antes de referenciarlo en `.mcp.json`, ejecutado como proceso `stdio`
local (`--access-level admin --timeout 600 --log-level info`, sin
`--allow-namespaces` ni `--enabled-components`, `USE_LEGACY_TOOLS=false`,
`AKS_MCP_COLLECT_TELEMETRY=false`), sin credenciales propias — usa la
sesión `az` y el kubeconfig local del proceso. `claude mcp get aks`
confirma `Connected`. Detalle completo, incluida la tabla de las 13 tools
reales y cómo se clasifica cada una, en
`.claude/skills/manage-aks-clusters/references/aks-mcp.md`.

Hallazgo real durante la instalación: sin `--enabled-components`, el
binario valida al arrancar que las CLIs de **todos** los componentes
(incluye `helm`, `cilium`, `hubble`) estén presentes, y termina el
proceso si falta alguna — visible solo como `CONNECTION_CLOSED` sin más
detalle. Esta máquina no tenía `helm`/`cilium`/`hubble` instalados; se
instalaron (aprobado explícitamente) vía Chocolatey (`helm`, `cilium
CLI`) y binario verificado por SHA-256 del release oficial (`hubble`
CLI) — ver `aks-mcp.md` para el detalle exacto. El esquema real de las 13
tools se obtuvo enviando un handshake MCP crudo
(`initialize`/`tools/list`) directo por stdin/stdout contra el binario,
sin necesidad de esperar un reload de sesión de Claude Code.

## Kubeconfig

Resolución ambiente (sin `-KubeconfigPath` explícito): `$env:KUBECONFIG`
(con soporte de múltiples rutas separadas por `;` en Windows) →
`$env:USERPROFILE\.kube\config`. Su uso interno para autenticarse no
exige aprobación (a diferencia de una conexión SSH); leerlo con `--raw` o
copiarlo a cualquier ruta del repositorio sí la exige (o está prohibido
de forma absoluta en el segundo caso). Nunca se versiona.

En la práctica, los clústeres reales de este proyecto **no** están en esa
resolución ambiente — viven en 3 kubeconfigs exportados por Lens, y hay
que pasar `-KubeconfigPath` explícito en cada invocación (ver
`references/kubeconfig-and-contexts.md` § Clústeres reales conocidos).

## Pruebas

93 casos automatizados (77 de hooks + 16 de scripts) con mocks/temp
dirs/un `kubectl.cmd` stub para el único caso que necesitaba interceptar
`kubectl config current-context` — cero red, cero clúster real. Después
de las pruebas unitarias, un pequeño set de verificaciones reales de solo
lectura (versiones de herramientas, kubeconfig, contextos, `cluster-info`,
`auth can-i --list`, `get namespaces`, handshake del MCP) confirma que el
diseño funciona contra el entorno real sin modificar nada — ver el
resumen de validación de la implementación para el resultado exacto.

## Decisiones de diseño y limitaciones conocidas (v1)

- El journal y el hash canónico replican el patrón ya probado en
  producción del dominio Azure DevOps Pipelines
  (`Invoke-AdoRest.ps1`), simplificado para el alcance de este dominio —
  no incluye todavía la reconciliación "chequeo en vivo antes de cada
  fase" que ese dominio agregó después de detectar casos límite reales en
  uso; se puede endurecer de la misma forma si aparece la necesidad.
- La clasificación de `az_fleet`, `call_cilium` e
  `inspektor_gadget_observability` (las 3 tools MCP que mezclan lectura y
  escritura bajo la misma tool) sigue siendo genérica por palabra clave
  — puede preguntar de más en algún caso límite (ej. `aks_detector`
  ya no aplica porque quedó siempre-`allow`, pero una tool nueva de una
  futura versión del servidor caería en este mismo mecanismo hasta
  agregarla explícitamente a la tabla de `aks-mcp.md`).
- `kubelogin` no estaba instalado en la máquina donde se implementó este
  dominio y sigue sin estarlo — los scripts lo detectan y reportan como
  ausente en vez de asumir que existe. `helm`, `cilium` CLI y `hubble`
  CLI sí se instalaron durante esta implementación (ver § MCP `aks`) para
  poder conectar el MCP sin restringir `--enabled-components`.
- **Corrección 2026-08-26:** la primera verificación real de esta
  implementación probó contra `gmon-innovacion-aks-eastus2-0001` (el
  contexto `az`/kubectl por defecto de esta máquina) y encontró timeout
  de red hacia su endpoint privado — el usuario aclaró después que ese
  clúster **no** es parte de este proyecto; fue un error al dar la
  información inicial. Los clústeres reales viven en 3 kubeconfigs
  exportados por Lens (ver `references/kubeconfig-and-contexts.md` §
  Clústeres reales conocidos: 1 clúster k3s de desarrollo + varios AKS de
  dev/qa/prod, incluido `gmon-prod-aks-eastus2-0004`, ya conocido de los
  pipelines de Azure DevOps de este mismo proyecto). Contra el kubeconfig
  de desarrollo, `kubectl get nodes` conectó correctamente (`srv-
  desarrollo-5`, k3s, `Ready`) — sin problema de red real una vez
  apuntando al kubeconfig correcto. Por eso se agregó soporte explícito
  de `-KubeconfigPath` a todos los scripts que invocan kubectl (no
  existía en la v1 original, que solo pasaba `--context` asumiendo la
  resolución ambiente) — ver `Aks-Common.ps1#Get-AksKubectlConnectionArgs`
  y el campo `cluster.kubeconfigPath` del esquema de plan/inventario.
