# Expansión de PVC / disco en AKS — Referencia

> Confirmado en vivo 2026-10-13 ampliando el PVC de Elasticsearch del AKS prod 0001
> (alerta de disco 85% del canal teams-ops). Documenta la **confusión de los tamaños**
> y el **procedimiento manual de 2 pasos** para no re-descubrirlo.

## La confusión de los 3 tamaños (LÉASE PRIMERO)

Al mirar un PVC de Azure Disk CSI en estos clusters aparecen **tres números que NO coinciden**, y eso es esperado, no un error:

| Fuente | Qué muestra | Confiable? |
|---|---|---|
| `kubectl get pvc ... -o jsonpath='{.spec.resources.requests.storage}'` | Lo PEDIDO (lo que editás) | sí, es la intención |
| `kubectl get pvc ... .status.capacity.storage` **y** el PV `.spec.capacity` | Un valor **FANTASMA/desactualizado** (ej 150Gi) | **NO — ignorar** |
| `kubectl exec <pod> -- df -h <mountpath>` | El **disco real montado** | **SÍ — esta es la verdad** |

El `status` del PVC/PV se queda **congelado en un valor viejo** (se vio 150Gi cuando el disco real era 296G y luego 400G). El CSI de Azure **no reconcilia ese status** en estos StatefulSets. **Nunca decidas por el `status` del PVC ni del PV: usá `df` dentro del pod.**

## El CSI NO expande solo (en estos STS)

La doc de Microsoft dice que editar `spec.resources.requests.storage` del PVC "triggers the expansion of the underlying volume". En **estos StatefulSets no ocurre**: editar el PVC deja el `spec` nuevo pero el disco Azure no crece. Por eso el procedimiento acá es **manual en 2 manos**.

## Procedimiento confirmado (2 pasos + reinicio)

Ejemplo real: PVC `elasticsearch-master-elasticsearch-master-0`, ns `monitoring`,
cluster `gmon-prod-aks-eastus2-0001`, StorageClass `default`
(`allowVolumeExpansion=true`, provisioner `disk.csi.azure.com`), 300→400 GiB.

1. **Agente — subir el `spec` del PVC** al nuevo tamaño:
   ```bash
   kubectl --context <cluster> -n <ns> patch pvc <pvc> --type merge \
     -p '{"spec":{"resources":{"requests":{"storage":"400Gi"}}}}'
   ```
   (Shrink NO soportado: el nuevo valor debe ser >= al actual.)

2. **Pablo — ampliar el managed disk en Azure** (el agente NO lo hace; es la mano humana):
   ```bash
   az disk update \
     --resource-group mc_aks-<cluster>_noderg \
     --name <nombre-del-PV>  \   # = .spec.volumeName del PVC, ej pvc-accc9b07-...
     --size-gb 400
   ```
   El disk name y RG salen del PV: `kubectl get pv <volumeName> -o jsonpath='{.spec.csi.volumeHandle}'`.

3. **Reiniciar el StatefulSet** para que el pod monte el filesystem expandido
   (con visto bueno — reinicia el pod, es prod):
   ```bash
   kubectl --context <cluster> -n <ns> rollout restart statefulset <sts>
   kubectl --context <cluster> -n <ns> rollout status statefulset <sts> --timeout=150s
   ```

4. **Verificar con `df` en el pod** (NO por status del PVC):
   ```bash
   kubectl --context <cluster> -n <ns> exec <pod> -c <container> -- df -h <mountpath>
   ```
   Debe mostrar el tamaño nuevo (~400G) y el uso bajo del umbral.

## Acceso al AKS 0001 (NSG)

El API server privado del 0001 exige abrir la NSG `PRODAKS1_Rule` (ciclo
Allow→operar→Deny). **Cerrar SIEMPRE (Deny) al terminar.** Detalle en `aks.md`.
Si `az` no está logueado: `az login --identity --client-id "$KIRO_AZURE_MI_CLIENT_ID"`;
si el perfil de az no es escribible, usar `AZURE_CONFIG_DIR=$(mktemp -d)`.

## Reglas

- Prod: diagnóstico libre; la expansión se ejecuta con visto bueno (paso 2 lo hace Pablo).
- No confiar en el `status` del PVC/PV: medir con `df`.
- No omitir el reinicio del STS: sin él el `df` no refleja el disco nuevo.
