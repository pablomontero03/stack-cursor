# Servidor openedx-dev (10.2.1.132)

Fuente de verdad operativa para este servidor, gestionado por
`.cursor/skills/manage-linux-servers/SKILL.md`. No contiene contraseñas,
tokens ni ningún secreto — solo inventario, checklists y hallazgos
sanitizados.

> **Distinto del `openedx` de producción (`135.119.204.153`).** Este es el
> entorno de **DESARROLLO** que sirve `https://estudiante-desarrollo.gmontecristo.com/`.

## Datos del servidor

| Campo | Valor |
|---|---|
| IP | `10.2.1.132` |
| Puerto | `22` |
| Usuario | `adminedx` |
| Hostname real | `VM` |
| SO | Ubuntu 20.04 |
| Finalidad | Open edX DESARROLLO (`estudiante-desarrollo.gmontecristo.com`) |
| Despliegue | Tutor 17.0.5 (Docker) |

## Configuración SSH local requerida

```sshconfig
Host openedx-dev
    HostName 10.2.1.132
    Port 22
    User adminedx
    IdentityFile <ruta-repo>/env/keyopenedx-dev.pem
```

Conexión directa confirmada:

```bash
ssh -i env/keyopenedx-dev.pem adminedx@10.2.1.132
```

**Excepción conocida y aceptada:** igual que el `openedx` de producción, la
clave privada de este servidor (RSA 4096) vive en `env/keyopenedx-dev.pem`,
dentro de este repositorio, en vez de `%USERPROFILE%\.ssh\`. Las variables
`OPENEDX_DEV_IP` / `OPENEDX_DEV_USER` / `OPENEDX_DEV_KEY_PATH` están en
`env/.env` (chmod 600, no versionado). La clave nunca se escribe en el
catálogo ni en esta doc. Ver `.cursor/rules/linux-servers/security.md`.

## Servicios conocidos

- **Open edX (Tutor 17.0.5, Docker).** Dos deployments de Tutor en el host:
  - `local` → **el stack que sirve el sitio público** (runtime). Contenedores
    `tutor_local-*`: LMS, CMS, MySQL, MongoDB, Redis, Caddy, MFE, workers,
    Elasticsearch (11 contenedores en total).
  - `dev` → deployment de desarrollo de Tutor (no es el que sirve el sitio).
- El borde HTTP/HTTPS lo atiende **Caddy** (puertos 80/443); el `80` redirige
  a `443` (respuesta `308`, normal).

## Arranque del stack tras reboot

> **Resuelto (2026-10-29):** ver la sección "Persistencia tras reboot" abajo.
> Antes del fix, los contenedores `tutor_local-*` con `restart: unless-stopped`
> NO relevantaban si habían sido parados explícitamente antes del reboot, así
> que tras un apagado solo subía `elasticsearch` y el sitio quedaba caído.

**Arranque manual del stack (si hiciera falta; reversible, solo levanta
contenedores ya existentes, sin cambiar config ni datos):**

```bash
tutor local start -d
# esperar ~40s a que el LMS (Django) termine de inicializar
```

Verificación:

```bash
# puertos escuchando
ss -tlnp | grep -E ':80|:443'
# sitio público
curl -s -o /dev/null -w '%{http_code}\n' https://estudiante-desarrollo.gmontecristo.com/   # -> 200
curl -s -o /dev/null -w '%{http_code}\n' https://estudiante-desarrollo.gmontecristo.com/dashboard  # -> 302 (redirect a login, normal)
```

### ✅ Persistencia tras reboot (aplicada 2026-10-29)

Resuelto con una **systemd unit** que arranca el stack en cada boot:
`/etc/systemd/system/tutor-openedx.service` (`enabled`). Es idempotente y no
depende del estado previo de los contenedores (a diferencia de la restart
policy `unless-stopped`, que NO relevanta un contenedor parado explícitamente
antes del reboot — esa fue la causa de que tras el apagado solo subiera
`elasticsearch`).

```ini
[Unit]
Description=Open edX (Tutor local) stack
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=adminedx
Environment=PATH=/home/adminedx/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/home/adminedx/.local/bin/tutor local start -d
ExecStop=/home/adminedx/.local/bin/tutor local stop
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
```

Operación:

```bash
systemctl status  tutor-openedx.service    # estado
sudo systemctl start tutor-openedx.service # arrancar el stack (idempotente)
systemctl is-enabled tutor-openedx.service # -> enabled
```

Verificado en vivo: `ExecStart ... status=0/SUCCESS`, 11 contenedores arriba,
sitio `HTTP 200`. Los contenedores conservan además `restart: unless-stopped`.

## Comandos permitidos de diagnóstico

Ver Modo 2 y Modo 3 de `.cursor/skills/manage-linux-servers/SKILL.md`.
Para este server, confirmar siempre el estado del stack Docker antes de
asumir nada:

```bash
docker ps -a                 # contenedores (arriba / Exited)
docker compose ls            # deployments compose activos
tutor config printroot       # raíz de config de Tutor
```

## Política de cambios

- Todo cambio de configuración, instalación/actualización o reinicio pasa
  por los Modos 4, 5 o 6 del skill, cada uno con su propia aprobación
  explícita del usuario.
- Arrancar el stack (`tutor local start -d`) sobre un server **de desarrollo**
  es una acción operativa reversible; aun así, cualquier cambio de
  configuración de Tutor o de los contenedores requiere aprobación.
- Nunca se ejecuta ninguna de las acciones de la lista de "Prohibido
  permanentemente" del skill, bajo ninguna circunstancia.
- No se asume acceso sudo para el usuario `adminedx`.
- Ver `.cursor/rules/linux-servers/authorization.md` para el detalle
  completo de qué requiere aprobación.

## Checklist de conexión (Modo 1)

- [x] Entrada `openedx-dev` registrada en el catálogo `docs/servers/servers.json`.
- [x] Clave privada instalada en `env/keyopenedx-dev.pem` (chmod 600, no versionada).
- [x] Variables `OPENEDX_DEV_*` agregadas a `env/.env`.
- [x] Usuario autorizó explícitamente la conexión SSH (2026-10-29).
- [x] `ssh -i env/keyopenedx-dev.pem adminedx@10.2.1.132` confirmado.
- [x] Hostname y usuario devueltos coinciden con lo esperado (`VM`, `adminedx`).

## Checklist de diagnóstico de aplicativos (Modo 3)

- [x] Stack Tutor inventariado: 11 contenedores `tutor_local-*`, Caddy en 80/443.
- [x] Sitio público verificado arriba (`HTTP 200`).

## Historial de hallazgos (sanitizado)

| Fecha | Hallazgo |
|---|---|
| 2026-10-29 | Alta del server de desarrollo. SSH por llave RSA 4096 confirmado (`env/keyopenedx-dev.pem`). Ubuntu 20.04, hostname `VM`, Tutor 17.0.5. **Causa raíz de "el sitio no carga":** el server reinició ~1h15 antes y el stack `tutor_local-*` no tiene restart automático → tras el reboot solo subió `elasticsearch`, el resto quedó `Exited` (7 días). Fix: `tutor local start -d` → 11 contenedores arriba, `estudiante-desarrollo.gmontecristo.com` → `HTTP 200`. Mejora pendiente: persistencia tras reboot. |
| 2026-10-29 | **Refresh de datos prod → dev (igualar dev a prod).** Dumps de prod en vivo (solo lectura, prod intacto): `mysqldump --single-transaction` + `mongodump --gzip`. Transferencia prod→dev por pipe SSH (integridad byte a byte). Restore en dev: MySQL (2503→2856 usuarios, 55 cursos) + MongoDB (14.7 GB, 60 cursos, 62851 chunks, 0 failures, `--drop`). `tutor local do init` rc=0. Sitio dev `HTTP 200` con tema Montecristo. OAuth redirect_uris ya en `studio-desarrollo`. Rollback de dev en `~/openedx-refresh-backups/dev-rollback-20261029-2146`. El server se apaga por horario y cortó el 1er intento de Mongo; se completó con `nohup` en una ventana encendida. Pendiente: neutralizar secretos de prod (SMTP/OAuth/API keys) que viajaron en el dump. |
| 2026-10-29 | **Persistencia tras reboot aplicada:** systemd unit `tutor-openedx.service` (`enabled`), `ExecStart=tutor local start -d`. Verificada en vivo (status=0/SUCCESS, 11 contenedores, sitio 200). Resuelve el caído tras apagado por horario. |


### 2026-11-12 — Medición de disco (vía `az vm run-command`, solo lectura)
- `vm-openEdx-dev` (RG `OPENEDX-DESARROLLO`, IP privada `10.2.1.132`, **sin IP pública**) estaba desasignada; se encendió con `az vm start`.
- `/` 124G, 96G usados, 29G libres (78%). **No hay `/mnt` separado montado** (solo `sda`, 128G, Standard_LRS, sin disco temporal en la salida de `lsblk`). Los "186G libres en /mnt" citados antes eran de PRODUCCIÓN, no de dev.
- Ampliación del disco OS (si se decide): desasignar VM → `az disk update --size-gb 256` → arrancar → `growpart /dev/sda 1` + `resize2fs /dev/sda1`; snapshot previo recomendado.
- Aviso: `keyopenedx.pem` (prod) NO autentica en dev (`Permission denied (publickey)`); usar `env/keyopenedx-dev.pem`. Nunca asumir la IP `135.119.204.153` para dev.

### 2026-11-12 — Limpieza de respaldos viejos (aprobada por Pablo)
- Host verificado dentro del script (`hostname -I` = `10.2.1.132`, abortaba si no). Chequeo `lsof` previo: ningún archivo en uso.
- Borrados en `~/backups`: `openedx-preupgrade-2026-07-31_*` (2 carpetas + `.tar.gz`), `redis_20260612_145500`, `mongodump_2026-10-30.archive` (16G), `openedx-17.0.5_2026-10-30.tar` (3.1G), `openedx-mfe-17.0.1_2026-10-30.tar` (228M).
- Conservados: `forks-config-plugins_2026-10-30.tgz`, `openedx-mfe_id-ok_2026-11-11.tar.gz`, backups de Dockerfile/identificacion.yml, `dev-migration-20260708`, `dev-smtp-20260709_004825`.
- Resultado: `/` de 78% (96G) a 60% (74G usados, 51G libres). 11 contenedores `tutor_local-*` arriba, sin reinicios. Pendiente opcional: `docker builder prune` (3.6G) e imágenes sin uso (3.3G).
- 2026-11-12 (cont.): `docker builder prune -f` (3.6G) + `docker rmi node:18.19.0-bullseye-slim` (203M). `/` 60% → 57% (70G usados, 55G libres). 11 `tutor_local-*` arriba. **NO se borró** `overhangio/openedx:17.0.5-montecristo-id-ok` (3.1G, sin contenedor): es una imagen etiquetada a mano como versión buena, probable punto de retorno; solo con OK de Eduardo. Contenedores `tutor_dev-*` detenidos (5 meses) se conservan.
