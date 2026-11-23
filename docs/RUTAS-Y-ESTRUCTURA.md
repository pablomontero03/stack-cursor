# Rutas y estructura del setup Kiro Crew

Referencia completa de todos los archivos y carpetas relevantes del setup.
Útil para orientarse, diagnosticar problemas o reproducir la instalación.

---

## WSL — Kiro Crew (config del gateway)

```
~/.kiro/crew/
├── config.json              ← Config principal: approval_mode, dashboard.url,
│                               telegram, workspaces, MCPs en runtime
├── .env                     ← Credenciales del gateway (chmod 600, nunca versionar)
│                               KIROCREW_BIND=0.0.0.0
│                               TELEGRAM_BOT_TOKEN
│                               CLOUDFLARE_API_TOKEN / CLOUDFLARE_ACCOUNT_ID
│                               AZDO_PAT / N8N_MCP_TOKEN / N8N_PRODUCTIVO_MCP_TOKEN
├── mcp.json                 ← MCPs de Crew — uno de los 4 archivos a sincronizar
├── oauth_endpoints.json     ← Hosts OAuth de confianza (Cloudflare, n8n)
├── skills/ → symlinks       ← Skills enlazadas al repo por setup.sh
└── models/                  ← Modelo de embeddings (~610 MB, auto-descargado)
```

---

## WSL — kiro-cli (config del motor de modelos)

```
~/.kiro/
├── settings/
│   ├── mcp.json             ← MCPs globales — uno de los 4 a sincronizar
│   └── cli.json             ← Config del CLI
└── agents/
    ├── kirocrew.json        ← Agente principal (generado por `setup --agent-only`)
    └── *.json               ← 24 agentes del stack (symlinks al repo por setup.sh)

~/.local/
├── bin/
│   ├── kiro-cli             ← Binario del motor de modelos
│   └── kirocrew             ← Binario de Kiro Crew
└── share/kiro-cli/
    └── data.sqlite3         ← Estado interno de kiro-cli (historial, sesiones)
```

---

## WSL — Credenciales de infraestructura

```
~/.kube/config               ← Kubeconfig unificado (chmod 600)
│                               Contextos: k3s-dev, gmon-prod-aks-0001, gmon-prod-aks-0004,
│                               gmon-dev/qa-aks (apagados), docker-desktop, etc.

~/.azure/                    ← Credenciales de az login
│                               Suscripción activa: Hospital Metropolitano
│                               (69dc43ec-5f24-4203-9239-a8d0f8506d44)

~/.git-credentials            ← PAT de Azure DevOps para git (chmod 600)
│                               Format: https://Shared-Service-GM:<PAT>@dev.azure.com

~/.ssh/                      ← Claves SSH (si se configuraron)
```

---

## WSL — Stack automation-kiro (el repo)

> **Raíz:** `~/proyectos/repositorios/automation-kiro/` (= `$REPO_ROOT`)

```
automation-kiro/
│
├── .kiro/                   ← Config del proyecto (viaja con el repo en git)
│   ├── settings/
│   │   ├── mcp.json         ← MCPs del proyecto — uno de los 4 a sincronizar
│   │   └── cli.json
│   ├── steering/            ← 9 steering files (cargados automáticamente)
│   │   ├── global.md        ← Reglas globales, modelo de aprobaciones, SQL read-only
│   │   ├── azure.md         ← Azure ARM + FinOps
│   │   ├── aks.md           ← Kubernetes/AKS/Helm
│   │   ├── azure-devops.md  ← Pipelines + Permissions
│   │   ├── cloudflare.md    ← DNS, WAF, Workers, etc.
│   │   ├── n8n.md           ← n8n interno + productivo/MAIA
│   │   ├── schema-sync.md   ← Schema Sync + SSDT
│   │   ├── servers.md       ← Servidores Linux/Windows
│   │   └── orchestration.md ← Skill coordinadora multi-dominio
│   ├── agents/              ← 24 agentes JSON del stack
│   ├── skills/              ← 12 skills con SKILL.md + scripts PowerShell
│   │   ├── manage-azure-devops-pipelines/   (30 scripts)
│   │   ├── manage-cloudflare/               (15 scripts)
│   │   ├── manage-azure-devops-permissions/ (14 scripts)
│   │   ├── manage-azure-resources/          (13 scripts)
│   │   ├── manage-aks-clusters/             (12 scripts)
│   │   ├── analyze-azure-costs/             (8 scripts)
│   │   ├── manage-n8n-monitoring/
│   │   ├── manage-linux-servers/
│   │   ├── manage-windows-servers/
│   │   ├── manage-schema-sync-ssdt/
│   │   ├── orchestrate-application-pipeline-cycle/
│   │   └── skill-creator/
│   ├── agent-memory/        ← Memoria de patrones y debugging (24 agentes)
│   └── hooks/
│       ├── sql-readonly-gate.json   ← Hook Kiro: bloquea escritura SQL
│       └── sql-readonly-gate.sh
│
├── env/
│   ├── .env                 ← TODAS las credenciales (chmod 600, en .gitignore)
│   └── .env.example         ← Plantilla con placeholders (versionada en git)
│
├── .local/
│   └── aks/tools/aks-mcp/v0.0.20/aks-mcp   ← Binario MCP de AKS (Linux)
│
├── docs/
│   ├── RUTAS-Y-ESTRUCTURA.md          ← Este archivo
│   ├── mcp/MCP-CONNECTIONS-STATUS.md  ← Estado operativo de todos los MCPs
│   ├── azure/                         ← Arquitectura Azure
│   ├── azure-devops/                  ← Arquitectura pipelines
│   ├── cloudflare/                    ← Arquitectura Cloudflare
│   ├── aks/                           ← Arquitectura AKS
│   ├── n8n-monitoring/                ← Runbooks n8n
│   └── servers/                       ← Catálogos de servidores
│
├── schema-sync/             ← Dominio Schema Sync (databases.json, etc.)
├── setup.sh                 ← Bootstrap: enlaza agentes/skills, descarga aks-mcp,
│                               carga env/.env, exporta REPO_ROOT, reinicia Crew
└── .gitignore               ← Excluye env/.env, .local/, binarios

Otros repos:
~/proyectos/repositorios/buklo-framework/   ← Repo Azure DevOps (Node.js)
~/proyectos/env/README.md                   ← Doc de credenciales
```

---

## Windows — Scripts y accesos directos

```
C:\Users\pablo\
├── kirocrew-portproxy.ps1      ← Arranca Crew + ajusta portproxy al iniciar sesión
│                                  (ejecutado por la tarea programada)
├── kirocrew-url.ps1             ← Genera URL con token para la LAN + copia al portapapeles
├── kirocrew-portproxy.log       ← Log del arranque automático
└── Desktop\
    └── Kiro Crew - URL acceso.bat  ← Doble clic → genera token → URL en portapapeles
```

### Tarea programada de Windows
| Campo | Valor |
|---|---|
| Nombre | `Start-KiroCrew-WSL` |
| Evento | Al iniciar sesión (AtLogOn) |
| Nivel | RunLevel Highest (admin) |
| Acción | `powershell.exe -File kirocrew-portproxy.ps1` |

---

## Accesos (URLs y canales)

| Superficie | Cómo acceder |
|---|---|
| Dashboard (esta PC) | `http://localhost:5476` — sin token |
| Dashboard (otra PC de casa) | `http://192.168.100.2:5476/?token=...` — token de 20h |
| Celular | Telegram `@Kirocrewpm_bot` |

---

## Los 4 archivos MCP (mantener sincronizados)

Cuando se actualiza la config de un MCP, hay que actualizarlos **todos**:

```
1. ~/proyectos/repositorios/automation-kiro/.kiro/settings/mcp.json   ← repo
2. ~/.kiro/settings/mcp.json                                            ← global kiro-cli
3. ~/.kiro/crew/mcp.json                                                ← Crew
4. ~/.kiro/agents/kirocrew.json                                         ← auto-generado
```

Después de cambiar 1-3:
```bash
kirocrew setup --agent-only    # regenera el kirocrew.json (archivo 4)
kirocrew restart               # recarga el gateway
# Abrir sesión NUEVA en el dashboard (las sesiones abiertas no recargan tools)
```

---

## Comandos clave

```bash
# Reiniciar el gateway (el más usado)
kirocrew restart
# → imprime las URLs con token directamente

# Estado
kirocrew status
kirocrew doctor

# Cambiar de proyecto en el chat
"ve a /home/kiro/proyectos/repositorios/buklo-framework"

# Ver/cambiar contexto de kubectl
kubectl config get-contexts
kubectl config use-context k3s-dev
kubectl config use-context gmon-prod-aks-eastus2-0004

# Suscripción activa de Azure
az account show --query name -o tsv
az account set --subscription "Hospital Metropolitano"

# Bootstrap completo (nueva máquina o setup inicial)
cd ~/proyectos/repositorios/automation-kiro
cp env/.env.example env/.env    # completar con valores reales
bash setup.sh
```

---

*Última actualización: 2026-09-10*
