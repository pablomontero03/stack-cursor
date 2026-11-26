# Rollback y verificación de deploys — Referencia (dominio AKS/k3s)

> **Punto de partida, no un techo.** Los comandos de abajo son el patrón base de rollback/verificación.
> El agente debe adaptarlos al caso real (qué recurso, qué cluster, qué namespace, qué health) y
> extenderlos cuando la situación lo pida — no limitarse a copiar `rollout undo`.

Destilado del skill `devops-engineer` (patrón `kubectl rollout undo` + verificación), **adaptado a
nuestro stack**: clusters propios, MCP `aks` (`call_kubectl`), y el flujo plan→validación→apply→readback.
No introduce toolchain nuevo (nada de GitOps/ArgoCD/Terraform): usa lo que ya operamos.

## Regla previa — documentar el rollback ANTES de aplicar

Antes de cualquier cambio en un Deployment/Service/manifest **vivo** (patch, nuevo rev del File
Creator, bump de imagen), dejar escrito —en el plan, el PR o el ticket— **dos cosas**:

1. **Comando de rollback exacto** (ver abajo), con cluster + namespace + recurso concretos.
2. **Verificación de que el rollback funcionó** (readback de pods + health).

Esto convierte "revertir" en un paso preparado, no en una improvisación bajo presión. Encaja con la
regla de oro del stack: producción y lo destructivo requieren aprobación separada; un rollback de un
Deployment vivo de prod es un cambio y se trata como tal.

## Contextos reales (confirmar siempre en vivo)

Nunca asumir el contexto activo. Confirmar con `kubectl config current-context` antes de operar.
Contextos vigentes (al 2026-10-02): `k3s-dev`, `prod-onprem-01`, y los AKS privados
`gmon-prod-aks-eastus2-0001/0002/0003/0004`, `gmon-dev-aks-eastus2-0001`, `gmon-qa-aks-eastus2-0001/0002`.

> **AKS 0001:** recordar que el API server privado está detrás de `PRODAKS1_Rule` (NSG en Deny por
> defecto). Abrir→esperar ~25-30s→operar→**cerrar siempre**. Ver steering `aks`.

## 1. Ver el historial de revisiones antes de revertir

```bash
# ¿Qué revisiones hay y cuál está activa?
kubectl -n <ns> rollout history deployment/<nombre>

# Detalle de una revisión concreta (qué imagen/campos tenía)
kubectl -n <ns> rollout history deployment/<nombre> --revision=<N>
```

Decidir **a qué revisión** volver mirando el history, no a ciegas. La revisión previa suele ser la
sana inmediatamente anterior al cambio que rompió.

## 2. Rollback

```bash
# Revertir a la revisión inmediatamente anterior
kubectl -n <ns> rollout undo deployment/<nombre>

# Revertir a una revisión específica (preferible: explícito)
kubectl -n <ns> rollout undo deployment/<nombre> --to-revision=<N>

# Esperar a que el rollout termine (bloquea hasta Ready o falla)
kubectl -n <ns> rollout status deployment/<nombre> --timeout=120s
```

> **Ojo con los Deployments de Buklo:** el estado "deseado" lo fija el **File Creator del Build ADO**,
> no un YAML en repo. Un `rollout undo` revierte el ReplicaSet vivo a la imagen/plantilla anterior,
> pero **el próximo deploy del pipeline vuelve a aplicar lo que diga el File Creator**. Si el cambio
> que rompió vino del File Creator (puerto, probe, recursos), el rollback vivo es un parche temporal:
> hay que corregir también el File Creator (nuevo rev del Build) para que el pipeline no re-rompa.
> Esto ya nos pasó (cotizadores: puerto 4014 / `/api/health`).

## 3. Verificación (readback) — equivale al smoke test

```bash
# Pods del recurso: todos 1/1 Running, 0 restarts nuevos
kubectl -n <ns> get pods -l app=<label> -o wide

# Health real de la app (ajustar puerto/path reales; NO asumir)
#   - desde dentro del cluster, port-forward o exec:
kubectl -n <ns> exec deploy/<nombre> -- curl -sf http://localhost:<puerto><path-health>
#   - o port-forward local:
kubectl -n <ns> port-forward deploy/<nombre> <local>:<puerto>  # luego curl 127.0.0.1:<local><path-health>

# Confirmar la imagen/revisión activa tras el rollback
kubectl -n <ns> get deploy <nombre> -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

El rollback **no está terminado** hasta que: (1) los pods están `Running` sin restarts nuevos, y
(2) el health responde 200 en el puerto/path **reales** del servicio (confirmados, no supuestos).

## 4. Si el rollback tampoco levanta

No ciclar reintentando el mismo `undo`. Aplicar el método de diagnóstico
(`docs/METODO-DIAGNOSTICO-FALLOS.md`): loop reproducible → minimizar → hipótesis → una variable a la
vez. Un rollback que tampoco arranca suele significar que el problema **no era la revisión** (ej.
dependencia externa caída, Secret/ConfigMap cambiado aparte, nodo sin recursos) — ampliar el espacio
de hipótesis, no insistir con la reversión.

## Vía MCP `aks` (lo que el agente ejecuta aquí)

Todos los comandos de arriba se corren con la tool `call_kubectl` del MCP `aks` (incluye el prefijo
`kubectl`). El MCP **bloquea el flag `--context`**: para operar sobre un cluster distinto del activo,
usar `kubectl config use-context <ctx>` en un comando aparte y **restaurar el contexto original al
terminar**. Preferir siempre `-n <ns>` explícito; evitar `-A`.

## Cruce con nuestras reglas

- **Autofix de infra sin aprobación:** un rollback de un Deployment por un error de infra (manifest,
  recursos, puerto, probe) entra en el ciclo agéntico. Un cambio en **producción** o algo destructivo
  requiere **aprobación separada**.
- **Código de app:** si el deploy nuevo rompe por **código** (no infra), el rollback vivo estabiliza,
  pero la causa se **reporta con evidencia** al dev — no se corrige el código.
