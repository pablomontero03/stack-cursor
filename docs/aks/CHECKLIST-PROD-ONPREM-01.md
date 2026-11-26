# Checklist — prod-onprem-01 (k3s .31) hacia prod de primera clase

> Cluster k3s de un solo nodo (srvdesarrollo03, 172.16.2.31). Cargas: DataHub + 3 MCP Buklo.
> Acceso SSH: `LINUX_SRV_ADM_*` en `env/.env` (user adm01). k3s con `--disable=traefik,servicelb,metrics-server`.
> Última actualización: 2026-09-19

## ✅ Hecho
- [x] **metrics-server** — CPU/mem, `kubectl top`, HPA, Lens. (2026-09-18)
- [x] **cert-manager (DNS-01 Cloudflare)** — renovación automática de los 3 certs `*.buklo.dev`. (2026-09-18)
- [x] **Observabilidad + alertas** — 3 monitores AKS de n8n-interno (CPU/mem, disco PVC, reinicios) vigilan el `.31` con alertas a Teams. Kubeconfig SA read-only montado en el `.60`. (2026-09-18)
- [x] **Expansión de PVCs local-path** — `allowVolumeExpansion: true` (persistido en el manifiesto k3s). (2026-09-18)
- [x] **Kubernetes Dashboard + Azure AD SSO** — `cluster-onprem-01.grupomontecristo.com`, clon del `.43`, Origin Rule Cloudflare :4443. (2026-09-18)
- [x] **Logs centralizados — Loki + Promtail** — grafana/loki-stack v2.10.3 en ns `monitoring`, retención 7d, PVC 10Gi. Dashboard "Logs por Namespace" con variables namespace+pod (desde Prometheus kube_pod_info). (2026-09-18)
- [x] **Historial de métricas + dashboards — Prometheus + Grafana** — kube-prometheus-stack v91.4.1 en ns `monitoring`, Alertmanager OFF, reglas ON, retención 15d, limits explícitos. Grafana en https://grafana-onprem-01.grupomontecristo.com (login propio, password en env/.env GRAFANA_ONPREM01_ADMIN_PW), DNS proxied + Origin Rule :4443. (2026-09-18)
- [x] **Resource limits en cargas críticas** — Kafka (req 512Mi/limit 1536Mi) y Zookeeper (req 128Mi/limit 512Mi) en ns datahub. ES ya tenía. (2026-09-18)
- [x] **Respaldo del estado de k3s (SQLite)** — script `sqlite3 .backup` + cron diario 02:00, retención 14, ~3.3MB/snapshot en `/var/lib/rancher/k3s-backups/`. Doc en `docs/aks/RESPALDO-K3S-ONPREM-01.md`. Restore documentado, NO probado. (2026-09-19)

## 🟡 Prioridad MEDIA (endurecimiento — el cluster ya es productivo sólido)
- [ ] **5. Copia del backup fuera del nodo (off-site)** — hoy el `.db.gz` vive solo en el .31; si el disco muere, se pierde con él. Copiar a otro server/share/storage. Bajo esfuerzo cuando se defina destino.
- [ ] **6. Resource limits/requests en el resto de cargas** — Kafka/ZK ✅. Falta buklo-mcp (3 pods), ns monitoring y kubernetes-dashboard, para que NINGUNA carga pueda tumbar el nodo. Bajo riesgo, alto valor de estabilidad.
- [ ] **7. Probes liveness/readiness en todas las cargas** — que k8s reinicie solo un pod colgado. Revisar cuáles no las tienen.
- [ ] **8. NetworkPolicies (aislamiento entre namespaces)** — default-deny + reglas explícitas. OJO: k3s trae flannel que NO aplica NetworkPolicies; evaluar CNI (Cilium/Calico). Más trabajo, beneficio moderado con cargas conocidas.

## 🟢 Prioridad BAJA / seguridad avanzada
- [ ] **9. Cifrado de secrets en reposo** — hoy los secrets están en claro en state.db (y en el backup). Habilitar encryption-at-rest de k3s o Sealed Secrets.
- [ ] **10. Pod Security Standards** — impedir pods root/privilegiados. Hardening.
- [ ] **11. Plan de parcheo SO + k3s** — mantener el nodo al día con parches de seguridad (operacional).
- [ ] **12. Falco / runtime security** — solo si hay requisito de compliance.

## ❌ NO aplica a este cluster (sería sobre-ingeniería)
- HA / multi-master (es nodo único por diseño).
- Service mesh (Istio/Linkerd) — demasiado peso para las cargas actuales.
- Autoscaling de nodos — no hay pool de nodos que escalar.

## Nota
Monitoreo del host (.31) ya cubierto por node-exporter en Prometheus (disco/RAM/load).
Restore del backup: documentado en RESPALDO-K3S-ONPREM-01.md, NO probado (evitar riesgo a prod; validar en k3s desechable cuando haya).

**Publicar un sitio nuevo del .31 por internet (regla obligatoria):** NO basta el DNS.
Requiere `A → 190.113.100.74 proxied` **+** agregar el host a la Origin Rule
`:4443` del ruleset `http_request_origin` en Cloudflare (el .31 no expone el 443;
el borde escucha en 4443). Sin la Origin Rule el sitio da **521**. Detalle y zone/
ruleset IDs en `docs/cloudflare/CLOUDFLARE-AUTOMATION-ARCHITECTURE.md`. Hosts así:
grafana-onprem-01, datahub, cicd-dashboard, k8s-hub, cluster-onprem-01,
knowledge-base (2026-10-08).
