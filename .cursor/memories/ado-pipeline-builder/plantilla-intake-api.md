---
name: ado-pipeline-builder-plantilla-intake-api
description: "Plantilla genérica de intake para crear pipelines AKS de APIs en Azure DevOps. Usar esta plantilla para modo agéntico end-to-end sin preguntas."
metadata:
  type: intake-template
  created: 2026-11-24
  based-on: Optica-Ecosystem-auth-api (Build 713, Release 442)
---

# Plantilla Intake - Pipeline API AKS (Modo Agéntico)

**Propósito**: Crear Build Definition + Release Definition + 3 Variable Groups para cualquier API .NET que se despliega en AKS.

**Instrucciones**: Copiar esta plantilla, completar TODOS los campos, y pasarla al agente. El agente ejecutará el flujo completo sin preguntas adicionales.

---

## 📋 PARTE 1: Información Básica de la API

```yaml
# Información de la aplicación
aplicacion:
  nombre: "auth-api"                           # Nombre corto de la API (ej. auth-api, users-api, orders-api)
  sistema: "Optica-Ecosystem"                   # Sistema al que pertenece (ej. Optica-Ecosystem, CRM, Analytics)
  descripcion: "API de autenticación"           # Descripción breve (1 línea)
  tecnologia: ".NET 9.0"                        # Tecnología (ej. .NET 9.0, .NET 8.0, Node.js 20)
  puerto: 8080                                   # Puerto del contenedor

# Repositorio
repositorio:
  organizacion: "Shared-Service-GM"
  proyecto: "DevOps"
  repo: "Dr.Max-Project/optica-ecosystem"       # Nombre exacto del repositorio
  carpeta_solucion: "src/Auth.API"              # Ruta relativa desde raíz del repo al .csproj/.sln
  archivo_proyecto: "Auth.API.csproj"           # Nombre del archivo de proyecto

# Branches
branches:
  desarrollo: "develop"                          # Branch de desarrollo
  uat: "uat"                                     # Branch de UAT
  produccion: "release"                          # Branch de producción

# Azure Container Registry
acr:
  nombre: "gmonhubacreastus20001"
  registry_url: "gmonhubacreastus20001.azurecr.io"
  password: "REDACTED"

# Service Connections (IDs de Azure DevOps)
service_connections:
  acr_id: "b6de83c1-c511-4b3f-b92b-ed8c3c3d1f0e"
  acr_name: "SC-ACR-AZURE-GMON-DEV"
```

---

## 📋 PARTE 2: Configuración por Ambiente

```yaml
# Variable Groups - configuración por ambiente
ambientes:
  desarrollo:
    nombre: "Desarrollo"
    namespace: "optica-ecosystem-dev"           # Namespace de Kubernetes
    cluster_context: "gmon-prod-aks-eastus2-0004"
    replicas: 1
    cpu_request: "100m"
    cpu_limit: "500m"
    memory_request: "128Mi"
    memory_limit: "512Mi"
    ingress_host: "auth-api-dev.opticamontecristo.com"
    
  uat:
    nombre: "UAT"
    namespace: "optica-ecosystem-uat"
    cluster_context: "gmon-prod-aks-eastus2-0004"
    replicas: 2
    cpu_request: "200m"
    cpu_limit: "1000m"
    memory_request: "256Mi"
    memory_limit: "1Gi"
    ingress_host: "auth-api-uat.opticamontecristo.com"
    
  produccion:
    nombre: "Produccion"
    namespace: "optica-ecosystem-prod"
    cluster_context: "gmon-prod-aks-eastus2-0001"
    replicas: 3
    cpu_request: "500m"
    cpu_limit: "2000m"
    memory_request: "512Mi"
    memory_limit: "2Gi"
    ingress_host: "auth-api.opticamontecristo.com"
    # Approval requerido
    approval:
      enabled: true
      approver_group: "Release Executers"
      approver_id: "397ddbfe-1d60-4533-a4c9-b099f80ac154"
```

---

## 📋 PARTE 3: Manifests Kubernetes (K8s)

**IMPORTANTE**: Estos manifests deben estar **listos y validados** antes de crear el pipeline.

### 📄 deployment-dev.yml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $(servicesname)
  namespace: $(namespace)
  labels:
    app: $(servicesname)
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $(servicesname)
  template:
    metadata:
      labels:
        app: $(servicesname)
    spec:
      containers:
      - name: $(servicesname)
        image: $(containerRegistryUrl)/$(servicesname):$(tag)
        imagePullPolicy: Always
        ports:
        - containerPort: 8080
          protocol: TCP
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi
        env:
        - name: ASPNETCORE_ENVIRONMENT
          value: "Development"
        - name: ASPNETCORE_URLS
          value: "http://+:8080"
      imagePullSecrets:
      - name: acr-secret
---
apiVersion: v1
kind: Service
metadata:
  name: $(servicesname)
  namespace: $(namespace)
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 8080
    protocol: TCP
  selector:
    app: $(servicesname)
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $(servicesname)
  namespace: $(namespace)
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - auth-api-dev.opticamontecristo.com
    secretName: $(servicesname)-tls
  rules:
  - host: auth-api-dev.opticamontecristo.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: $(servicesname)
            port:
              number: 80
```

### 📄 deployment-uat.yml

```yaml
# Similar a dev, pero con:
# - replicas: 2
# - resources.requests.cpu: 200m, memory: 256Mi
# - resources.limits.cpu: 1000m, memory: 1Gi
# - ASPNETCORE_ENVIRONMENT: "Staging"
# - ingress.host: auth-api-uat.opticamontecristo.com
```

### 📄 deployment-prod.yml

```yaml
# Similar a dev, pero con:
# - replicas: 3
# - resources.requests.cpu: 500m, memory: 512Mi
# - resources.limits.cpu: 2000m, memory: 2Gi
# - ASPNETCORE_ENVIRONMENT: "Production"
# - ingress.host: auth-api.opticamontecristo.com
```

---

## 📋 PARTE 4: Task Groups (Auto-detectados)

**El agente detectará automáticamente estos Task Groups del proyecto DevOps**:

- **Build**: `Deployment-Build-Docker-v2` (ID: `73a09d8b-ceb8-4e7f-b9b3-ce62cb6e3aa3`)
- **Deploy AKS**: `Deployment-Azur-Aks-v3` (ID: `1fdf52f7-9160-4049-bb78-c7bffadf022d`)

**NO es necesario especificarlos en el intake.**

---

## 📋 PARTE 5: Naming Conventions (Auto-generados)

El agente generará automáticamente estos nombres siguiendo el patrón estándar:

```yaml
# Variable Groups (IDs asignados por Azure DevOps al crear)
variable_groups:
  desarrollo: "Desarrollo-{sistema}-{nombre}"   # Ej: Desarrollo-Optica-Ecosystem-auth-api
  uat: "UAT-{sistema}-{nombre}"                 # Ej: UAT-Optica-Ecosystem-auth-api
  produccion: "Produccion-{sistema}-{nombre}"   # Ej: Produccion-Optica-Ecosystem-auth-api

# Build Definition
build:
  nombre: "Build-{sistema}-{nombre}"            # Ej: Build-Optica-Ecosystem-auth-api
  carpeta: "\\{sistema}"                        # Ej: \Optica-Ecosystem

# Release Definition
release:
  nombre: "Deploy-Desarrollo-UAT-Produccion-{sistema}-{nombre}"
  # Ej: Deploy-Desarrollo-UAT-Produccion-Optica-Ecosystem-auth-api

# Docker Image Tag
docker:
  image_name: "{sistema}-{nombre}"              # Ej: optica-ecosystem-auth-api (lowercase)
  tag_format: "$(Build.BuildId)"                # Ej: 12345

# Kubernetes
kubernetes:
  service_name: "{sistema}-{nombre}"            # Ej: optica-ecosystem-auth-api (lowercase)
```

**NO es necesario especificarlos en el intake.**

---

## ✅ Checklist Pre-Envío (OBLIGATORIO)

Antes de enviar el intake al agente, verificar:

- [ ] **Información básica**: nombre, sistema, descripción completos
- [ ] **Repositorio**: organización, proyecto, repo, carpeta y archivo de proyecto correctos
- [ ] **Branches**: nombres exactos de develop, uat, release
- [ ] **ACR**: password y registry URL correctos
- [ ] **Service Connections**: IDs válidos de Azure DevOps
- [ ] **Ambientes**: namespace, cluster, recursos (CPU/memory) por ambiente
- [ ] **Ingress hosts**: dominios correctos por ambiente
- [ ] **Manifests K8s**: 3 archivos listos (deployment-dev/uat/prod.yml)
- [ ] **Approval**: approver_id correcto para Producción (si aplica)

---

## 🚀 Flujo Agéntico Automático

Una vez enviado el intake completo, el agente ejecutará:

1. **Validación del intake** (esquema, campos obligatorios)
2. **Inventario en vivo** (task groups, service connections, clusters)
3. **Generación de nombres** siguiendo convenciones
4. **Creación de Variable Groups** (3: Desarrollo, UAT, Producción)
5. **Creación de Build Definition** (con 3 manifests embebidos)
6. **Creación de Release Definition** (con 3 stages y approval en Prod)
7. **Configuración de variables ACR** (Pipeline + Stage-level en los 3 stages)
8. **Verificación post-creación** (checklist completo)
9. **Reporte final** con IDs y URLs

**Tiempo estimado**: ~10-15 minutos (vs 2.5 horas con errores).

---

## 📝 Ejemplo de Intake Completo

```yaml
aplicacion:
  nombre: "users-api"
  sistema: "CRM"
  descripcion: "API de gestión de usuarios"
  tecnologia: ".NET 9.0"
  puerto: 8080

repositorio:
  organizacion: "Shared-Service-GM"
  proyecto: "DevOps"
  repo: "CRM/users-service"
  carpeta_solucion: "src/Users.API"
  archivo_proyecto: "Users.API.csproj"

branches:
  desarrollo: "develop"
  uat: "uat"
  produccion: "release"

acr:
  nombre: "gmonhubacreastus20001"
  registry_url: "gmonhubacreastus20001.azurecr.io"
  password: "REDACTED"

service_connections:
  acr_id: "b6de83c1-c511-4b3f-b92b-ed8c3c3d1f0e"
  acr_name: "SC-ACR-AZURE-GMON-DEV"

ambientes:
  desarrollo:
    nombre: "Desarrollo"
    namespace: "crm-dev"
    cluster_context: "gmon-prod-aks-eastus2-0004"
    replicas: 1
    cpu_request: "100m"
    cpu_limit: "500m"
    memory_request: "128Mi"
    memory_limit: "512Mi"
    ingress_host: "users-api-dev.grupomontecristo.com"
    
  uat:
    nombre: "UAT"
    namespace: "crm-uat"
    cluster_context: "gmon-prod-aks-eastus2-0004"
    replicas: 2
    cpu_request: "200m"
    cpu_limit: "1000m"
    memory_request: "256Mi"
    memory_limit: "1Gi"
    ingress_host: "users-api-uat.grupomontecristo.com"
    
  produccion:
    nombre: "Produccion"
    namespace: "crm-prod"
    cluster_context: "gmon-prod-aks-eastus2-0001"
    replicas: 3
    cpu_request: "500m"
    cpu_limit: "2000m"
    memory_request: "512Mi"
    memory_limit: "2Gi"
    ingress_host: "users-api.grupomontecristo.com"
    approval:
      enabled: true
      approver_group: "Release Executers"
      approver_id: "397ddbfe-1d60-4533-a4c9-b099f80ac154"

# + 3 archivos: deployment-dev.yml, deployment-uat.yml, deployment-prod.yml
```

---

## 🔄 Actualizaciones y Modificaciones

Si necesitas modificar un pipeline existente, usa el flujo de update:

1. **Identificar el recurso**: Build ID, Release ID, Variable Group IDs
2. **Generar plan de update**: `New-AdoClassicUpdatePlan.ps1`
3. **Validar**: `Test-AdoClassicPlan.ps1`
4. **Aplicar**: `Apply-AdoClassicPlan.ps1`

---

## 📚 Referencias

- **Skill**: `.cursor/skills/manage-azure-devops-pipelines/SKILL.md`
- **Errores comunes**: `errores-comunes.md` (esta memoria)
- **Patrones**: `patterns.md` (esta memoria)
- **Pipeline ejemplo**: Build 713, Release 442 (Optica-Ecosystem-auth-api)
