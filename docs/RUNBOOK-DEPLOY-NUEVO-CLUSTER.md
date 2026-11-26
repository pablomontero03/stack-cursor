# Runbook: Despliegue en cluster nuevo — cicd-dashboard + k8s-dashboard-hub

Documentado el 2026-09-25. Aplica al despliegue inicial en `prod-onprem-01` o cualquier
cluster nuevo donde se quiera replicar el stack completo.

---

## Prerrequisitos

- Namespace `tools-devops` creado
- Secret `acr-secret` (pull de ACR) y `grupomontecristo-cert-secret` (TLS) existentes
- Secret `oauth2-proxy-secret` existente (contiene `oauth2-proxy-client-secret` y `cookie-secret`)
- Secret `oauth2-proxy-k8s-hub-secret` existente (mismo contenido, para el hub)
- Redis `oauth2-redis` corriendo en `kubernetes-dashboard` namespace (db=1 para cicd, db=2 para hub)
- Nginx Ingress Controller instalado

---

## 1. Crear el Secret del cicd-dashboard (MANUAL — el pipeline NO lo crea)

```bash
kubectl -n tools-devops create secret generic cicd-dashboard-secret \
  --from-literal=AZURE_DEVOPS_PAT="<PAT de Azure DevOps>" \
  --from-literal=TEAMS_WEBHOOK_URL="<URL del webhook Teams del canal>"
```

Ver `/apps/cicd-dashboard/k8s/secret-template.yml` para instrucciones detalladas.

> ⚠️ **IMPORTANTE**: El pipeline del cicd (build def 683) ya NO crea este secret.
> Si no se crea manualmente antes de correr el pipeline, el pod arrancará sin PAT y
> todas las llamadas a ADO darán 401. Crear el secret ANTES de correr el pipeline.

---

## 2. Correr el pipeline del cicd-dashboard

En Azure DevOps, encolar el build de la definición **683** (`Build-DevOps-cicd-dashboard`)
desde el branch `release`. El release se dispara automáticamente y aplica:

- `cicd-dashboard-config` ConfigMap ✅
- `cicd-dashboard-ado`, `cicd-dashboard-html`, `cicd-dashboard-server`, `cicd-dashboard-teams` ConfigMaps ✅
- Deployment `cicd-dashboard` ✅
- Deployment `oauth2-proxy` (con todos los skip-auth-routes y oidc-email-claim=upn) ✅
- Service + Ingress ✅

**Lo que NO aplica el pipeline:**
- `cicd-dashboard-secret` (ver paso 1)

---

## 3. Correr el pipeline del k8s-dashboard-hub

En Azure DevOps, encolar el build de la definición **684** (`Build-DevOps-k8s-dashboard-hub`)
desde el branch `release`. El release aplica:

- `k8s-hub-config` ConfigMap ✅
- Deployment `k8s-dashboard-hub` ✅
- Deployment `oauth2-proxy-k8s-hub` (con cookie-samesite=none, skip-auth-route=^/proxy/, oidc-email-claim=upn) ✅
- Service + Ingress ✅

**Lo que NO aplica el pipeline (opcionales — el hub funciona sin ellos):**
- `k8s-hub-html` — solo necesario si se quiere aplicar cambios a `index.html` sin recompilar
- `k8s-hub-server` — solo necesario para hotfixes a `server.js` sin recompilar

Si se necesitan estos ConfigMaps (por ejemplo para aplicar un hotfix rápido):
```bash
kubectl -n tools-devops create configmap k8s-hub-html \
  --from-file=index.html=apps/k8s-dashboard-hub/src/public/index.html \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n tools-devops create configmap k8s-hub-server \
  --from-file=server.js=apps/k8s-dashboard-hub/src/server.js \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n tools-devops rollout restart deployment/k8s-dashboard-hub
```

---

## 4. Desplegar el proxy en cada cluster K8s (k8s-dashboard-proxy)

El hub embebe los K8s Dashboards via un proxy Node.js que debe estar en cada cluster.
Ver `docs/K8S-DASHBOARD-HUB-LECCIONES-APRENDIDAS.md` para el procedimiento completo.

Resumen rápido por cluster:

```bash
# En cada cluster (ajustar CTX y NS según la tabla abajo)
CTX=<contexto>
NS=<namespace>
DASHBOARD_HOST=<hostname del cluster>

# 1. ACR pull secret
kubectl --context $CTX -n $NS create secret docker-registry acr-pull-secret \
  --docker-server=gmonhubacreastus20001.azurecr.io \
  --docker-username=gmonhubacreastus20001 \
  --docker-password="<ACR_PASSWORD>"

# 2. Deployment + Service del proxy
kubectl --context $CTX apply -f - << 'EOF'
# ... (ver deployment completo en la sección de arquitectura del doc de lecciones)
EOF

# 3. Parchar oauth2-proxy del cluster
kubectl --context $CTX -n $NS patch deployment oauth2-proxy --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--skip-auth-route=GET=/teams-tab"},
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--skip-auth-route=HEAD=/teams-tab"},
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--skip-auth-route=^/k8s-proxy/"}
]'

# 4. Agregar paths al Ingress del cluster
kubectl --context $CTX -n $NS patch ingress k8s-dashboard --type=json -p='[
  {"op":"add","path":"/spec/rules/0/http/paths/0","value":{"path":"/teams-tab","pathType":"Prefix","backend":{"service":{"name":"k8s-dashboard-proxy","port":{"number":80}}}}},
  {"op":"add","path":"/spec/rules/0/http/paths/1","value":{"path":"/k8s-proxy","pathType":"Prefix","backend":{"service":{"name":"k8s-dashboard-proxy","port":{"number":80}}}}}
]'
```

| Cluster | Contexto | Namespace | Dashboard Host |
|---|---|---|---|
| prod-onprem-01 | `prod-onprem-01` | `kubernetes-dashboard` | `cluster-onprem-01.grupomontecristo.com` |
| k3s-dev | `k3s-dev` | `k8s-dashboard` | `cluster-dev.gmontecristo.com` |
| AKS 0004 | `gmon-prod-aks-eastus2-0004` | `k8s-dashboard` | `cluster-services-prod.grupomontecristo.com` |
| AKS 0001 | `gmon-prod-aks-eastus2-0001` | `k8s-dashboard` | `cluster-sites-prod.grupomontecristo.com` |

> AKS 0001 requiere abrir la NSG `PRODAKS1_Rule` antes de operar. Ver steering AKS.

---

## 5. Fix del kubernetes-dashboard CrashLoop (aplica a todos los clusters)

Si el pod `kubernetes-dashboard` crashea con `permission denied /tmp/dashboard.*.log`:

```bash
kubectl --context $CTX -n $NS patch deployment kubernetes-dashboard --type=json -p='[
  {"op":"add","path":"/spec/template/spec/volumes","value":[{"name":"tmp-dir","emptyDir":{}}]},
  {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts","value":[{"name":"tmp-dir","mountPath":"/tmp"}]}
]'
```

---

## 6. Verificación post-deploy

```bash
# cicd-dashboard
curl -sIo /dev/null -w "HTTP %{http_code}\n" "https://cicd-dashboard.grupomontecristo.com/" --max-redirs 0
kubectl -n tools-devops logs deployment/cicd-dashboard --tail=5  # NO debe tener 401

# k8s-hub
curl -sIo /dev/null -w "HTTP %{http_code}\n" "https://k8s-hub.grupomontecristo.com/" --max-redirs 0
curl -sk "https://k8s-hub.grupomontecristo.com/proxy/k3s-dev/" | grep -o "<title>[^<]*</title>"
# Debe decir: <title>Kubernetes Dashboard</title>

# hub oauth2-proxy args correctos
kubectl -n tools-devops get deployment oauth2-proxy-k8s-hub \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | python3 -m json.tool | \
  grep -E "cookie-name|cookie-same|skip.*proxy|oidc-email"
# Debe tener: oauth2_proxy_k8s_hub, none, ^/proxy/, upn
```

---

## 7. Rotar el PAT de Azure DevOps

Cuando se rota el PAT en Azure DevOps:

```bash
# 1. Actualizar el secret del cicd
kubectl -n tools-devops create secret generic cicd-dashboard-secret \
  --from-literal=AZURE_DEVOPS_PAT="<NUEVO_PAT>" \
  --from-literal=TEAMS_WEBHOOK_URL="<misma URL>" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n tools-devops rollout restart deployment/cicd-dashboard

# 2. El pipeline del hub NO necesita actualización (no usa el PAT del cicd)
```

> El pipeline ya NO sobreescribirá el secret — el PAT persiste entre deployments.
