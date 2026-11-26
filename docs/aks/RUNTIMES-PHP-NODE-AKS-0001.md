# Runtimes PHP / Node / otros por host — AKS producción

> Inventario en vivo. Generado 2026-10-22 15:20 UTC. Método: `kubectl get ingress -A` → service → pod → `php -v`/`node -v`; para pods sin PHP/Node se inspeccionó el contenedor en profundidad (nginx, Python, Java, proceso PID 1). NSG `PRODAKS1_Rule` abierta y cerrada (Deny) para el 0001; el 0004 conecta directo.

Leyenda: **x.y.z** = binario presente y respondió en el pod. Columna **Otro runtime / tipo** aclara qué corre cuando no es PHP/Node (frontend SPA servido por nginx, servicio Python/Java, o infra). `(sin pod)` = el service no tenía pods al momento.

# Runtimes por host — AKS `gmon-prod-aks-eastus2-0001`

Kubernetes v1.32. 53 hosts.

| # | Namespace | Host DNS | Service | Pod | PHP | Node | Otro runtime / tipo |
|---|---|---|---|---|---|---|---|
| 1 | cenrad | cenrad-devoluciones.grupomontecristo.com | gmondevolucionescenrad | `gmondevolucionescenrad-66f488f57-prgcn` | **8.2.29** | **v22.16.0** | — |
| 2 | cenrad | solurad-test.grupomontecristo.com | solurad | *(sin pod)* | — | — | — |
| 3 | cnc | cnc-devoluciones.grupomontecristo.com | gmondevolucionescnc | `gmondevolucionescnc-7c4679bd7f-fcrv7` | **8.2.29** | **v22.16.0** | — |
| 4 | common | devoluciones.grupomontecristo.com | gmodevolucioneshome | `gmodevolucioneshome-78dbc59dc9-rnfbw` | **8.3.13** | **v20.15.1** | — |
| 5 | common | portainer-sites.grupomontecristo.com | portainer | *(sin pod)* | — | — | — |
| 6 | common | redis-gmo.grupomontecristo.com | redisinsight-service | `redisinsight-df9f6c497-d9d6q` | — | — | redis (infra) |
| 7 | common | redis.grupomontecristo.com | redis-master | `redis-master-0` | — | — | redis (infra) |
| 8 | datahub | datahub.grupomontecristo.com | datahub-datahub-frontend | *(sin pod)* | — | — | — |
| 9 | drmax | drmax-devoluciones.grupomontecristo.com | gmondevolucionesdrmax | `gmondevolucionesdrmax-65667b746-cgpvs` | **8.2.29** | **v22.16.0** | — |
| 10 | drsdent | drsdent-devoluciones.grupomontecristo.com | gmondevolucionesdrsdent | `gmondevolucionesdrsdent-674fc5955c-nvk9s` | **8.2.29** | **v22.16.0** | — |
| 11 | grupomontecristo | arthur.grupomontecristo.com | corefrontendarthur | `corefrontendarthur-7c5778d88b-lwtwb` | — | — | nginx 1.27.3 (SPA, Alpine) — sin PHP/Node en runtime |
| 12 | grupomontecristo | insurance.grupomontecristo.comx | corefrontendinsurancecompanies | *(sin pod)* | — | — | — |
| 13 | grupomontecristo | laboratory.grupomontecristo.com | corefrontendlabresults | `corefrontendlabresults-d4bc8db7d-5jwks` | — | — | nginx 1.29.1 (SPA, Alpine) |
| 14 | grupomontecristo | suite.grupomontecristo.com | corefrontendweb | `corefrontendweb-7cdd4d5d47-prr92` | — | — | nginx 1.27.3 (SPA, Alpine) |
| 15 | grupomontecristo | bsc.grupomontecristo.com | gm-balance-score-card | *(sin pod)* | — | — | — |
| 16 | grupomontecristo | cotizadores.grupomontecristo.com | gm-cotizadores | *(sin pod)* | — | — | — |
| 17 | grupomontecristo | insurance.grupomontecristo.com | insurance-platform-web | `insurance-platform-web-769787568b-chv66` | — | — | nginx 1.31.6 (SPA, Alpine) |
| 18 | grupomontecristo | montecredito.cr | montecreditocr | `montecreditocr-75788f7c7c-frpgp` | **7.4.0** | — | — |
| 19 | grupomontecristo | automation.grupomontecristo.com | n8n | `n8n-758b56595c-dxdch` | — | **v24.13.1** | — |
| 20 | grupomontecristo | piwigo.grupomontecristo.com | piwigo | `piwigo-75d99bd6c9-h96pd` | **8.3.15** | — | — |
| 21 | grupomontecristo | portal.grupomontecristo.com | portal | *(sin pod)* | — | — | — |
| 22 | grupomontecristo | siprod.grupomontecristo.com | siprod | `siprod-7bd5d89df-bbs9m` | **7.4.0** | — | — |
| 23 | grupomontecristo | sirep.grupomontecristo.com | sirep | `sirep-6b4c6ccdf9-48ql7` | **8.0.0** | **v14.5.0** | — |
| 24 | grupomontecristo | socios.grupomontecristo.com | sirep | `sirep-6b4c6ccdf9-48ql7` | **8.0.0** | **v14.5.0** | — |
| 25 | grupomontecristo | montecristogolf.cr | site-golf | `site-golf-f749b467c-fs2t4` | — | — | nginx 1.29.3 (SPA, Alpine) |
| 26 | grupomontecristo | sso.grupomontecristo.com | site-sso-core | `site-sso-core-666f7f5959-6dczx` | — | — | nginx 1.29.0 (SPA, Alpine) |
| 27 | histomicroscopia | histomicroscopia-devoluciones.grupomontecristo.com | gmondevolucioneshistomicroscopia | `gmondevolucioneshistomicroscopia-5794b5d8d8-2wh5f` | **8.2.29** | **v22.16.0** | — |
| 28 | icem | icem-devoluciones.grupomontecristo.com | gmondevolucionesicem | `gmondevolucionesicem-6bdccdc5c6-49swj` | **8.2.29** | **v22.16.0** | — |
| 29 | innovacion | add-in.grupomontecristo.com | office-addin | `office-addin-7864dc9fb9-4m6qx` | — | — | nginx 1.29.1 (SPA, Alpine) |
| 30 | k8s-dashboard | cluster-sites-prod.grupomontecristo.com | k8s-dashboard-proxy | `k8s-dashboard-proxy-55c44f788b-vk2xc` | — | **v22.23.3** | — |
| 31 | k8s-dashboard | cluster-sites-prod.grupomontecristo.com | oauth2-proxy | `oauth2-proxy-6cc799566c-2v574` | — | — | oauth2-proxy (infra) |
| 32 | laboratoriospaez | cotizador.laboratoriospaez.com | cotizadorlabpaez | `cotizadorlabpaez-f4d6bf79f-sgqbl` | **7.4.0** | — | — |
| 33 | laboratoriospaez | laboratoriospaez-devoluciones.grupomontecristo.com | gmondevolucioneslaboratoriospaez | `gmondevolucioneslaboratoriospaez-5d8694cb54-phl77` | **8.2.29** | **v22.16.0** | — |
| 34 | magna | app.magnamedicacr.com | gmoappmagna | *(sin pod)* | — | — | — |
| 35 | medismart | afiliacionenlinea.medismart.net | frontendautoafiliacionlinea | `frontendautoafiliacionlinea-59b9768788-42w62` | **8.2.34** | **v20.20.2** | — |
| 36 | medismart | autogestion.medismart.net | autogestion-control | `autogestion-control-7b59bf954b-jbtqz` | **7.4.33** | — | — |
| 37 | medismart | cotizador.medismart.net | cotizadormedismart | `cotizadormedismart-577b44d88f-z9xxt` | **7.4.0** | — | — |
| 38 | medismart | medismart-devoluciones.grupomontecristo.com | gmondevolucionesmedismart | `gmondevolucionesmedismart-65587b8fd4-sw99z` | **8.2.29** | **v22.16.0** | — |
| 39 | medismart | portalcc.medismart.net | portalcc-intranetulemus | `portalcc-intranetulemus-cd789d96f-gg5kv` | **7.4.33** | — | — |
| 40 | medismart | red.medismart.online | redmedica | `redmedica-bc45fb57d-vj8l7` | **7.4.0** | — | — |
| 41 | medismart | medismart.net | web-medismart-ui | `web-medismart-ui-777659779c-dmpkd` | — | **v20.20.2** | — |
| 42 | medismart | www.medismart.net | web-medismart-ui | `web-medismart-ui-777659779c-dmpkd` | — | **v20.20.2** | — |
| 43 | metropolitanocr | empresas.metropolitanocr.com | scheduling | `scheduling-699f6b6bd5-8ph44` | — | **v18.20.8** | — |
| 44 | metropolitanocr | survey.metropolitanocr.com | surveymetropolitano | `surveymetropolitano-65689794cc-qwsnw` | **8.0.0** | — | — |
| 45 | mod-ag-test-dev | mod-ag-test-portal-dev.gmontecristo.com | mod-ag-test-portal-service | *(sin pod)* | — | — | — |
| 46 | monitoring-applications | elastic-aplicativos.grupomontecristo.com | elasticsearch-master | `elasticsearch-master-0` | — | — | elasticsearch (infra) |
| 47 | monitoring-applications | kibana-aplicativos.grupomontecristo.com | kibana-kibana | `kibana-kibana-6659ff5bdc-x5grm` | — | — | kibana (infra) |
| 48 | monitoring-metrics-logs | kibana-metrics-logs.grupomontecristo.com | kibana-kibana | *(sin pod)* | — | — | — |
| 49 | monitoring-metrics-logs | elastic-metrics-logs.grupomontecristo.com | elasticsearch-master | *(sin pod)* | — | — | — |
| 50 | monitoring | kibana.grupomontecristo.com | kibana-kibana | `kibana-kibana-55567fc65b-5bz7r` | — | — | kibana (infra) |
| 51 | monitoring | elastic.grupomontecristo.com | elasticsearch-master | `elasticsearch-master-0` | — | — | elasticsearch (infra) |
| 52 | pediaclinic | pediaclinic-devoluciones.grupomontecristo.com | gmondevolucionespediaclinic | `gmondevolucionespediaclinic-57d6cfdf46-76v6q` | **8.2.29** | **v22.16.0** | — |
| 53 | saat | saat-devoluciones.grupomontecristo.com | gmondevolucionessaat | `gmondevolucionessaat-74b9797f77-gt2sk` | **8.2.29** | **v22.16.0** | — |

---

# Runtimes por host — AKS `gmon-prod-aks-eastus2-0004`

Kubernetes v1.35. Conecta directo (no pasa por la NSG `PRODAKS1_Rule`). 29 filas.

| # | Namespace | Host DNS | Service | Pod | PHP | Node | Otro runtime / tipo |
|---|---|---|---|---|---|---|---|
| 1 | application-services | ai-autogestion-intranet.grupomontecristo.com | ai-intranet-service | `ai-intranet-service-f6cdb8df8-j6md6` | — | — | Python 3.11.15 (uvicorn/FastAPI) |
| 2 | application-services | ai-tools.grupomontecristo.com | ai-tools-api | `ai-tools-api-7c55445ff4-jlrd4` | — | — | Python 3.10.20 (uvicorn/FastAPI) |
| 3 | application-services | api.medismart.net | api-medismartnet | `api-medismartnet-7f99f9b475-r92gq` | **8.0.30** | — | — |
| 4 | application-services | autowebservice.grupomontecristo.com | auto-webservice | `auto-webservice-db7bd9f56-sw8bh` | **7.4.0** | — | — |
| 5 | application-services | enrollment-api.medismart.net | autoafiliacion-gateway-api | `autoafiliacion-gateway-api-5895b7bcb7-29lvc` | **8.2.30** | — | — |
| 6 | application-services | cotizadores-backend.grupomontecristo.com | backend-cotizadores | `backend-cotizadores-86f5db6f45-25ldl` | — | **v24.17.0** | — |
| 7 | application-services | microservice-buklo-server-api.grupomontecristo.com | microservice-buklo-server-api-service | `microservice-buklo-server-api-595cbd8884-t2lwg` | — | **v20.20.2** | — |
| 8 | application-services | gateway-buklo-dev.gmontecristo.com | microservice-engine-api-service | `microservice-engine-api-c86d6f665-hhq8f` | — | **v20.20.2** | — |
| 9 | application-services | microservice-gateway-api.grupomontecristo.com | microservice-gateway-api-service | `microservice-gateway-api-74b67bdf7b-4s5nt` | — | **v20.20.2** | — |
| 10 | application-services | microservice-gateway-api.buklo.dev | microservice-gateway-api-service | `microservice-gateway-api-74b67bdf7b-4s5nt` | — | — | — |
| 11 | application-services | api-empresas.metropolitanocr.com | scheduling-occupational-health-api | `scheduling-occupational-health-api-57879fbf97-z9gxf` | — | **v18.20.8** | — |
| 12 | application-services | siprod-backend.grupomontecristo.com | siprod-backend | `siprod-backend-7996448df6-r8d6k` | — | — | Java (Ubuntu 22.04) |
| 13 | application-services | tse.medismart.info | auto-webservice | `auto-webservice-db7bd9f56-sw8bh` | — | — | — |
| 14 | application-services | admin.medismart.net | web-medismart-strapi | `web-medismart-strapi-68bfdbd478-7b7h5` | — | **v20.20.2** | — |
| 15 | apps-web | analista-guia.grupomontecristo.com | analista-guia-web | *(sin pod)* | — | — | — |
| 16 | apps-web | cotizadores.grupomontecristo.com | cotizadores-web | `cotizadores-web-5fc9566ccc-z9dwr` | — | — | nginx 1.30.4 (SPA, Alpine) |
| 17 | apps-web | directorio.metropolitanocr.com | directorio-metropolitanocr | `directorio-metropolitanocr-56b59f8c6d-bt8h6` | — | — | nginx 1.31.2 (SPA, Alpine) |
| 18 | apps-web | hr-web.buklo.dev | hr-web | `hr-web-fd7cbb58b-n9gbs` | — | — | nginx 1.25.5 (SPA, Alpine) |
| 19 | apps-web | mailer-app.buklo.dev | mailer-app | `mailer-app-85cbdc8566-nprfc` | — | **v20.20.2** | — |
| 20 | apps-web | ontology-web.buklo.dev | ontology-web | `ontology-web-58d8654f57-gg7ht` | — | — | nginx 1.25.5 (SPA, Alpine) |
| 21 | apps-web | platform-docs.grupomontecristo.com | platform-docs-web | *(sin pod)* | — | — | — |
| 22 | apps-web | portal.grupomontecristo.com | portal | `portal-b67778dd6-585gf` | — | — | nginx 1.25.5 (SPA, Alpine) |
| 23 | apps-web | shell-web.buklo.dev | shell-web | `shell-web-ff94d68d8-hhvbh` | — | — | nginx 1.25.5 (SPA, Alpine) |
| 24 | apps-web | ticketing-web.buklo.dev | ticketing-web | `ticketing-web-d756cf4cb-ckj68` | — | — | nginx 1.25.5 (SPA, Alpine) |
| 25 | common | gateway.grupomontecristo.com | coremicroservicegateway | `coremicroservicegateway-585f5cff78-wj4fv` | — | **v18.20.8** | — |
| 26 | common | gateway-buklo.grupomontecristo.com | microservice-gateway-core-api-service | `microservice-gateway-core-api-6f54d6dbb7-cg872` | — | **v20.20.2** | — |
| 27 | data-services | qdrant-service.grupomontecristo.com | qdrant-service | `qdrant-service-0` | — | — | qdrant (infra) |
| 28 | k8s-dashboard | cluster-services-prod.grupomontecristo.com | k8s-dashboard-proxy | `k8s-dashboard-proxy-76f84946cf-6rmbv` | — | **v22.23.3** | — |
| 29 | k8s-dashboard | cluster-services-prod.grupomontecristo.com | oauth2-proxy | `oauth2-proxy-ccd89cdbf-5jwlz` | — | — | oauth2-proxy (infra) |

## Observaciones transversales
- **PHP 7.4 (EOL nov-2022)** en producción: 0001 → montecredito, siprod, cotizadorlabpaez, cotizadormedismart, redmedica, autogestion-control (7.4.33), portalcc (7.4.33); 0004 → auto-webservice (`autowebservice`/`tse.medismart.info`). Candidatos a actualizar (decisión del dev de cada app).
- **Node EOL**: 0001 `sirep`/`socios` → Node v14.5.0; varios servicios core en Node v18.20.8 (0001 `scheduling`; 0004 `coremicroservicegateway`, `scheduling-occupational-health-api`).
- **Stack moderno**: devoluciones (0001) PHP 8.2.29 + Node v22.16.0; microservicios Buklo (0004) Node v20.20.2.
- **Frontends SPA**: nginx sobre Alpine; el Node que los construyó fue build-time, no corre en el pod.
- **Servicios Python (0004)**: `ai-intranet-service` 3.11.15 y `ai-tools-api` 3.10.20 (uvicorn/FastAPI). **Java**: `siprod-backend`.
- **Typo de infra**: `insurance.grupomontecristo.com`**x** en el ingress `corefrontendinsurancecompanies` (0001).

