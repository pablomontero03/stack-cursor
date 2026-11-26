# Migración de variables de entorno de pipelines Buklo a Azure Key Vault

> Estándar vigente desde 2026-11-17. Aplica a la migración de los pipelines Buklo existentes
> **y a todo pipeline nuevo**. Piloto validado: `Build-buklo-microservice-gateway` (Build 584,
> Release 366), ambiente **UAT** (k3s-dev `.43`, namespace `uat`).
> Este documento NO contiene valores de secretos. Nunca agregarlos aquí.

## 1. Qué cambia

| Antes | Ahora |
|---|---|
| El File Creator `deployment-<amb>.yml` del Build traía un `Secret` (valores en base64) y un `ConfigMap` con todas las variables. | El File Creator ya no lleva valores. Trae un `SecretStore` + `ExternalSecret` que leen el Key Vault del servicio. |
| Cambiar una variable = editar el yml del File Creator. | Cambiar una variable = editar el **catálogo** de la tarea `Key Vault sync <amb>` del Build. Los secretos se rotan en el portal de Key Vault. |
| Secretos visibles (base64) en la definición del Build. | Secretos en Key Vault; en el Build solo quedan como variables **secretas** `KV_<NOMBRE>` (semilla para crearlos si faltan). |

La app **no cambia**: el pod sigue recibiendo las mismas variables por `envFrom` → `secretRef` del mismo Secret `#{servicesname}#-secret`.

```
Build (tarea Key Vault sync)  --crea/actualiza/borra-->  Key Vault kv-bk-<svc>-<amb>
                                                              |
External Secrets Operator (cluster) --lee cada 1h----------- -+
        |
        v
Secret k8s #{servicesname}#-secret  --envFrom-->  pod
```

## 2. Estándar de nombres

- **Vault:** `kv-bk-<servicio>-<ambiente>`, un vault por servicio y ambiente. Ej: `kv-bk-gateway-api-uat`.
  - `<servicio>` = nombre del servicio sin el prefijo `microservice-` (ej. `gateway-api`).
  - `<ambiente>` = `dev`, `uat`, `prod`.
  - **Límite Azure: 3–24 caracteres, único global, solo letras/números/guiones.** Verificar con
    `az keyvault check-name --name <n>` antes de usarlo. Si no cabe (ej. `kv-bk-subscriptions-api-prod`
    = 28), abreviar el servicio (ej. `kv-bk-subs-api-prod`) y documentar la abreviatura aquí.
- **Secreto dentro del vault:** el nombre de la variable de entorno con `_` → `-`
  (Key Vault no admite `_`). Ej: `REDIS_HOST` → `REDIS-HOST`. El `ExternalSecret` lo revierte a `_`.
- **Sin claves compartidas:** cada servicio tiene en su vault todo lo que usa, aunque se repita en otros.
- **Tags del vault:** `ambiente=<amb>`, `app=buklo`, `servicio=<svc>`.
- **RG:** dev/uat → `gmon_dev_rg_eastus2_0001`. Prod → por definir (aprobación separada).

## 3. Prerrequisitos (una sola vez por ambiente/cluster) — ya hechos para dev/uat

| Pieza | Estado dev/uat | Detalle |
|---|---|---|
| External Secrets Operator en el cluster | ✅ k3s-dev | Helm `external-secrets/external-secrets` 2.14.0, namespace `external-secrets`, CRDs `external-secrets.io/v1`. |
| Identidad del **pipeline** con rol de escritura | ✅ | Service connection ADO `AZ CLI SPN` (id `059a4ee3…`) = app Entra `gmon_hub_spn_tf_eastus2_0001` (appId `211e3b6b…`). Rol **Key Vault Secrets Officer** a nivel RG `gmon_dev_rg_eastus2_0001`. Es Owner de la suscripción (puede crear vaults). |
| Identidad del **cluster** con rol de lectura | ✅ | App Entra `app-applications-uat-dev` (appId `0da83d0b…`). Rol **Key Vault Secrets User** a nivel RG `gmon_dev_rg_eastus2_0001`. Credenciales en `env/.env` como `ESO_UAT_CLIENT_ID` / `ESO_UAT_CLIENT_SECRET` / `ESO_UAT_CLIENT_SECRET_ID`. |
| Secret de credenciales por namespace | ✅ `uat` · ❌ `desarrollo` | `eso-azure-kv-credentials` (claves `client-id`, `client-secret`). Crear en cada namespace nuevo (ver §6). |
| Rol de lectura humano | ✅ (Pablo) | Para ver valores en el portal hace falta un rol de **datos** (`Key Vault Secrets Officer`/`User`). **Owner NO alcanza** (es plano de control). |

Al asignar los roles a nivel de **Resource Group**, todo vault nuevo que el pipeline cree en ese RG
ya es escribible por el pipeline y legible por el cluster, sin pasos manuales.

## 4. Cambios en un Build (por ambiente)

### 4.1 File Creator `deployment-<amb>.yml`
1. Quitar el documento `kind: Secret` (con los valores) y el `kind: ConfigMap` de variables.
2. Agregar en su lugar:

```yaml
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: kv-bk-<svc>-<amb>
  namespace: #{namespace}#
spec:
  provider:
    azurekv:
      authType: ServicePrincipal
      vaultUrl: "https://kv-bk-<svc>-<amb>.vault.azure.net"
      tenantId: "33dd4184-3068-47da-891d-a70e02f8c0c9"
      authSecretRef:
        clientId:
          name: eso-azure-kv-credentials
          key: client-id
        clientSecret:
          name: eso-azure-kv-credentials
          key: client-secret
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: #{servicesname}#-secret
  namespace: #{namespace}#
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: kv-bk-<svc>-<amb>
    kind: SecretStore
  target:
    name: #{servicesname}#-secret
    creationPolicy: Owner
  dataFrom:
    - find:
        name:
          regexp: ".*"
      rewrite:
        - regexp:
            source: "-"
            target: "_"
```

3. En el `Deployment`, dejar en `envFrom` solo el `secretRef` (`#{servicesname}#-secret`); quitar el `configMapRef`.
4. Deployment, Service, Ingress, HPA, RBAC y tokens `#{...}#` quedan igual.

### 4.2 Tarea nueva `Key Vault sync <amb> (kv-bk-<svc>-<amb>)`
- Tarea **Azure CLI** (`46e4be58-730b-4389-8a2f-ea10b3e5e815`, v2), service connection `AZ CLI SPN`,
  script bash inline. Va **justo después** del File Creator del ambiente.
- Variables de entorno de la tarea: `KV_<NOMBRE>: $(KV_<NOMBRE>)` por cada secreto.
- Variables del Build: `KV_<NOMBRE>` con `isSecret: true` (valor actual del secreto, solo como semilla).
- Comportamiento del script (idempotente):
  1. Crea el vault si no existe (`--enable-rbac-authorization true --enable-purge-protection true`, tags).
  2. **Catálogo** (variables no sensibles, bloque `<<'CATALOG'` … `CATALOG`, una `NOMBRE=valor` por línea):
     crea o actualiza si el valor cambió. **El pipeline es la fuente de verdad** de estas.
  3. **SENSITIVE** (lista de nombres de secretos): solo se crean si faltan, desde `KV_<NOMBRE>`;
     nunca se pisan → se rotan en el portal. Si falta y no hay variable → falla (`exit 1`).
  4. **Borrado:** elimina del vault todo lo que no esté en el catálogo ni en SENSITIVE (soft-delete).
     Protección: si el catálogo tiene menos de `MIN_CATALOG=5` líneas, no borra nada y deja warning.
  5. `kvset` recupera automáticamente un nombre que esté en soft-delete antes de escribirlo
     (necesario por purge protection).
- Plantilla de referencia (piloto gateway): `.local/azure-devops/plans/build-584-keyvault-uat/kv-sync-step.sh`
  (en `.local/`, no versionado; el catálogo contiene valores no sensibles del servicio).

### 4.3 Cosas que NO van en Key Vault
- Valores vacíos (`RSA_PRIVATE_KEY: ""`): Key Vault no admite secretos vacíos. Decidir con el dev si la app los necesita definidos.
- Tokens de pipeline (`#{reqmem}#`, `#{image}#`, etc.): siguen en el VG/Release como hoy.

## 5. Procedimiento de migración de un servicio/ambiente

1. **Respaldar** la definición del Build: `GET build/definitions/<id>` → `.local/azure-devops/backups/build-<id>-<motivo>-<fecha>.json`.
2. Extraer del File Creator del ambiente: variables del ConfigMap (catálogo) y del Secret (decodificar base64 → `KV_*`).
3. Verificar nombre del vault (`az keyvault check-name`) y que el ambiente tenga los prerrequisitos de §3.
4. Generar File Creator nuevo + tarea `Key Vault sync`; verificar que ningún valor sensible quede en archivos de plan.
5. `PUT build/definitions/<id>` (script Python a disco con urllib; ver lecciones). Confirmar revisión +1 y `KV_*` con `isSecret=true`.
6. Encolar el Build en la **rama del ambiente** (UAT solo despliega builds de `uat`; dev de `development`).
   El Release se crea solo si el stage tiene aprobación automática.
7. Verificar: log de la tarea (`set`/`ok`/`delete`, sin `FALTA`), `externalsecret` en `SecretSynced`,
   Secret con todas las claves, pod Running, health 200.
8. Limpiar: borrar el `ConfigMap <svc>-config` viejo si ningún workload lo referencia (verificar antes).
   El Secret viejo con el mismo nombre lo **adopta** External Secrets (no hace falta borrarlo).
9. **Producción:** nunca automático. Plan propio y aprobación separada de Pablo; identidades y RG prod distintos.

### Renombrar/cambiar de vault (hecho 2026-11-17: `kv-buklo-gateway-uat` → `kv-bk-gateway-api-uat`)
Orden seguro (sin dejar al pod sin fuente): cambiar el nombre en la tarea + File Creator → correr Build
(crea y puebla el nuevo desde catálogo y `KV_*`) → verificar pod/health → recién entonces borrar el
`SecretStore` viejo del cluster y el vault viejo. Un vault borrado queda en soft-delete 90 días y su
nombre no se puede reutilizar mientras tanto.

## 6. Operación diaria

| Quiero… | Dónde |
|---|---|
| Cambiar o agregar una variable normal | Línea `NOMBRE=valor` del catálogo de la tarea `Key Vault sync`. Correr el Build. |
| Borrar una variable normal | Borrar su línea del catálogo. El Build la borra del vault (soft-delete). |
| Rotar un secreto | Portal: vault → Secrets → secreto → **+ New Version**. El pipeline no lo pisa. |
| Ver un valor | Portal: vault → Secrets → secreto → versión → **Show Secret Value** (requiere rol de datos). |
| Que el pod tome el cambio | ESO sincroniza en ≤1h (forzar: `kubectl annotate externalsecret <n> force-sync="$(date +%s)" --overwrite`). La app lee env solo al arrancar → reinicio/despliegue. |
| Crear credencial ESO en un namespace nuevo | `kubectl -n <ns> create secret generic eso-azure-kv-credentials --from-literal=client-id=… --from-literal=client-secret=…` cargando los valores desde `env/.env` sin imprimirlos. |

**No editar a mano** el Secret `#{servicesname}#-secret` del cluster: External Secrets lo sobrescribe.
**No editar en el portal** una variable del catálogo: el siguiente Build la vuelve al valor del catálogo.

Scripts de apoyo del piloto (en `.local/azure-devops/plans/build-584-keyvault-uat/`):
`catalog-edit.py add NOMBRE=valor | remove NOMBRE` (edita el catálogo por API), `kv-log.sh <buildId>`
(resume lo que hizo la tarea), `queue-uat.py` (encola en `uat`), `rename-vault.py`.

## 7. Estado del piloto (gateway)

| Ambiente | Estado |
|---|---|
| UAT | ✅ Migrado. Vault `kv-bk-gateway-api-uat` (52 entradas: 44 catálogo + 8 secretos). Build 584 rev 43. Validado: Builds 28102, 28110 (alta de variable de prueba), 28112 (borrado real), 28131 (vault renombrado). Health 200. |
| Desarrollo | ⏳ Pendiente (falta `eso-azure-kv-credentials` en `desarrollo`). |
| Producción | ⏳ Pendiente, aprobación separada. |

Pendientes de seguridad: rotar el client secret de `app-applications-uat-dev` (quedó impreso en una
sesión del agente el 2026-11-16) y actualizar `eso-azure-kv-credentials` + `env/.env`. Borrar los
respaldos `env/.env.bak-20261116` y `env/.env.bak-pre-restore-20261116` cuando ya no se necesiten.


## 8. Lote UAT de microservicios (2026-11-17)

Migrados los File Creator UAT de los 13 Builds `Build-Buklo-Microservice-*` de `\buklo`, compilados desde la punta de `uat`.
Abreviaturas de nombre de vault adoptadas: `notifications`→`notif`, `subscriptions`→`subs`, `buklo-server`→`server`.
Variables vacías (solo AI, 7) se cargan como **secretos** con valor dummy `NOT_SET` (rellenar en el portal; el pipeline no las pisa).

| Build | Servicio | Vault | Entradas | Resultado |
|---|---|---|---|---|
| 585 | auth | `kv-bk-auth-api-uat` | 28 | ✅ Release-47 |
| 586 | engine | `kv-bk-engine-api-uat` | 56 | ✅ Release-86 |
| 587 | notifications | `kv-bk-notif-api-uat` | 20 | ✅ Release-13 |
| 588 | storage | `kv-bk-storage-api-uat` | 18 | ✅ Release-14 |
| 589 | ai | `kv-bk-ai-api-uat` | 44 | ❌ Build 28147 falla por código de app (vault poblado, pod sin cambios) |
| 590 | billing | `kv-bk-billing-api-uat` | 45 | ✅ Release-15 |
| 591 | emr | `kv-bk-emr-api-uat` | 11 | ✅ Release-32 |
| 592 | hacienda | `kv-bk-hacienda-api-uat` | 31 | ✅ Release-15 |
| 593 | realtime | `kv-bk-realtime-api-uat` | 25 | ✅ Release-10 |
| 594 | subscriptions | `kv-bk-subs-api-uat` | 16 | ✅ Release-22 |
| 595 | surveys | `kv-bk-surveys-api-uat` | 10 | ✅ Release-12 |
| 596 | ticketing | `kv-bk-ticketing-api-uat` | 42 | ✅ Release-16 |
| 621 | buklo-server | `kv-bk-server-api-uat` | 22 | ❌ Build 28155: `services/buklo-server` ya no existe en el repo (vault poblado, pod sin cambios) |

En los ✅: pod 1/1 sin reinicios, ExternalSecret `SecretSynced`, Secret con tantas claves como entradas del vault, y
ConfigMap `<image>-config` viejo borrado (sin referencias). Respaldos de las 13 definiciones previas:
`.local/azure-devops/backups/keyvault-uat-20261117/`. Scripts del lote: `.local/azure-devops/plans/keyvault-uat-microservices/`.

Pendientes del lote:
- **AI (589):** `services/ai/src/modules/agent-executor/__benchmarks__/executor-benchmark.ts` líneas 13-14, `import {` sin cerrar con un
  `import { Logger }` adentro, del commit `9eca3543` (John Quesada, 2026-10-03). Reportar al dev; al corregirse, reencolar 589 en `uat`
  y luego borrar `microservice-ai-api-config`.
- **buklo-server (621):** la carpeta `services/buklo-server` no está en `uat`, `development` ni `release`. Confirmar si el servicio se
  movió de repo o se dio de baja; según eso, ajustar o deshabilitar el Build. Su ConfigMap no se borró.
