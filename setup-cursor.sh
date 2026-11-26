#!/usr/bin/env bash
# ============================================================
# stack-cursor — setup-cursor.sh
# Copia de setup-kiro.sh adaptada a Cursor en este servidor.
# setup-kiro.sh queda intacto como referencia del stack Kiro.
#
# Uso: ./setup-cursor.sh
# Idempotente: se puede correr varias veces.
# Raíz: el directorio donde vive este script
#       (/home/cursor/stack-cursor en gmon-hub-linuxvm-eastus2-0001).
# ============================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "${GREEN}  ✅ $1${NC}"; }
warn() { echo -e "${YELLOW}  ⚠️  $1${NC}"; }
err()  { echo -e "${RED}  ❌ $1${NC}"; }
info() { echo -e "${CYAN}  →  $1${NC}"; }

echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}  stack-cursor — Setup (Cursor / Linux)${NC}"
echo -e "${CYAN}  Repo: ${REPO_ROOT}${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

# ============================================================
# 1. Verificar dependencias
# ============================================================
echo "--- [1/8] Verificando dependencias ---"

check_dep() {
  if command -v "$1" &>/dev/null; then
    ok "$1 encontrado: $(command -v $1)"
  else
    err "$1 NO encontrado — instalar antes de continuar"
    MISSING_DEPS=1
  fi
}

MISSING_DEPS=0
check_dep pwsh
check_dep az
check_dep kubectl
check_dep node
check_dep npx
check_dep git
check_dep python3
check_dep curl

if ! command -v kirocrew &>/dev/null || ! command -v kiro-cli &>/dev/null; then
  info "kirocrew y kiro-cli no hacen falta para Cursor. Siguen en setup-kiro.sh."
fi

if [[ $MISSING_DEPS -eq 1 ]]; then
  err "Hay dependencias faltantes."
  exit 1
fi

# ============================================================
# 2. Verificar / descargar aks-mcp Linux
# ============================================================
echo ""
echo "--- [2/8] Verificando aks-mcp ---"

AKS_MCP_DIR="$REPO_ROOT/.local/aks/tools/aks-mcp/v0.0.20"
AKS_MCP_BIN="$AKS_MCP_DIR/aks-mcp"
AKS_MCP_URL="https://github.com/Azure/aks-mcp/releases/download/v0.0.20/aks-mcp-linux-amd64"

mkdir -p "$AKS_MCP_DIR"

if [[ -x "$AKS_MCP_BIN" ]]; then
  ok "aks-mcp ya existe: $("$AKS_MCP_BIN" --version 2>/dev/null | head -1)"
else
  info "Descargando aks-mcp v0.0.20 para Linux..."
  if curl -fsSL -o "$AKS_MCP_BIN" "$AKS_MCP_URL"; then
    chmod +x "$AKS_MCP_BIN"
    ok "aks-mcp descargado: $("$AKS_MCP_BIN" --version 2>/dev/null | head -1)"
  else
    err "No se pudo descargar aks-mcp. Verificar conectividad a GitHub."
    exit 1
  fi
fi

# ============================================================
# 3. Cargar variables de entorno desde .env
# ============================================================
echo ""
echo "--- [3/8] Cargando variables de entorno ---"

ENV_FILE="$REPO_ROOT/env/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source <(grep -v '^\s*#' "$ENV_FILE" | grep -v '^\s*$')
  set +a
  export OPENEDX_KEY_PATH="${REPO_ROOT}/env/keyopenedx.pem"
  export ADO_MCP_AUTH_TOKEN="${AZURE_DEVOPS_PAT:-}"
  ok ".env cargado desde $ENV_FILE"
else
  warn ".env no encontrado en $ENV_FILE"
  warn "Copiá env/.env.example a env/.env y completá los valores antes de usar el stack"
fi

# ============================================================
# 4. Comprobar subagentes de Cursor (viven en el repo)
# ============================================================
echo ""
echo "--- [4/8] Comprobando subagentes en .cursor/agents/ ---"

AGENTS_SRC="$REPO_ROOT/.cursor/agents"
if [[ -d "$AGENTS_SRC" ]]; then
  agent_count="$(find "$AGENTS_SRC" -maxdepth 1 -type f -name '*.md' | wc -l)"
  ok "Subagentes en el repo: ${agent_count}"
  if [[ "$agent_count" -lt 24 ]]; then
    warn "Se esperaban 24 subagentes"
  fi
else
  warn "Directorio de subagentes no encontrado: $AGENTS_SRC"
fi

# ============================================================
# 5. Comprobar skills de Cursor (viven en el repo)
# ============================================================
echo ""
echo "--- [5/8] Comprobando skills en .cursor/skills/ ---"

SKILLS_SRC="$REPO_ROOT/.cursor/skills"
if [[ -d "$SKILLS_SRC" ]]; then
  skill_count="$(find "$SKILLS_SRC" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  ok "Skills en el repo: ${skill_count}"
else
  warn "Directorio de skills no encontrado: $SKILLS_SRC"
fi

# ============================================================
# 6. Agregar REPO_ROOT al .bashrc del usuario (si no está)
# ============================================================
echo ""
echo "--- [6/8] Configurando REPO_ROOT en el shell ---"

BASHRC="$HOME/.bashrc"
MARKER_BEGIN="# stack-cursor"
MARKER_END="# fin stack-cursor"
REPO_ROOT_LINE="export REPO_ROOT=\"$REPO_ROOT\""

if grep -qF "$MARKER_BEGIN" "$BASHRC" 2>/dev/null; then
  ok "REPO_ROOT de stack-cursor ya está en $BASHRC"
else
  echo "" >> "$BASHRC"
  echo "$MARKER_BEGIN" >> "$BASHRC"
  echo "$REPO_ROOT_LINE" >> "$BASHRC"
  echo "$MARKER_END" >> "$BASHRC"
  ok "REPO_ROOT agregado a $BASHRC"
fi

export REPO_ROOT

# ============================================================
# 7. Comprobar rules, hook y MCP de este repo
# ============================================================
echo ""
echo "--- [7/8] Comprobando rules, hook y MCP ---"

RULES_DIR="$REPO_ROOT/.cursor/rules"
if [[ -d "$RULES_DIR" ]]; then
  rule_count="$(find "$RULES_DIR" -maxdepth 1 -type f -name '*.mdc' | wc -l)"
  ok "Rules: ${rule_count}"
else
  warn "No está $RULES_DIR"
fi

HOOK="$REPO_ROOT/.cursor/hooks/sql-readonly-gate.sh"
if [[ -x "$HOOK" ]]; then
  printf '%s' '{"command":"sqlcmd -Q \"SELECT 1\""}' | "$HOOK" >/dev/null
  allow_code=$?
  printf '%s' '{"command":"DROP TABLE dbo.T"}' | "$HOOK" >/dev/null
  drop_code=$?
  if [[ "$allow_code" -eq 0 && "$drop_code" -eq 2 ]]; then
    ok "Hook SQL: SELECT permitido, DROP bloqueado"
  else
    err "Hook SQL inesperado (SELECT=$allow_code DROP=$drop_code)"
  fi
else
  err "Hook no ejecutable: $HOOK"
fi

if [[ -f "$REPO_ROOT/.cursor/mcp.json" ]]; then
  ok "MCP: $REPO_ROOT/.cursor/mcp.json"
else
  warn "No está .cursor/mcp.json"
fi

KUBE="$REPO_ROOT/.local/kube/config"
if [[ -r "$KUBE" ]]; then
  ok "Kubeconfig local legible"
else
  warn "Kubeconfig no legible en $KUBE"
fi


# ============================================================
# 8. az login — Managed Identity y, si falla, Service Principal
# ============================================================
echo ""
echo "--- [8/8] Autenticando az (Managed Identity > Service Principal) ---"
if [ -n "${KIRO_AZURE_MI_CLIENT_ID:-}" ] && az login --identity --client-id "$KIRO_AZURE_MI_CLIENT_ID" --output none 2>/dev/null; then
  ok "az autenticado con Managed Identity (${KIRO_AZURE_MI_NAME:-id-kiro-agent-hub})"
elif [ -n "${AZURE_CLIENT_ID:-}" ] && [ -n "${AZURE_CLIENT_SECRET:-}" ]; then
  if az login --service-principal \
      -u "$AZURE_CLIENT_ID" \
      -p "$AZURE_CLIENT_SECRET" \
      --tenant "$AZURE_TENANT_ID" \
      --output none 2>/dev/null; then
    ok "az autenticado como Service Principal (fallback)"
  else
    warn "az login SP falló -- verificar variables en env/.env"
  fi
else
  warn "Ni Managed Identity ni Service Principal disponibles -- az login omitido"
fi

# ============================================================
# Resumen final
# ============================================================
echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${GREEN}  ✅ Setup Cursor completo${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""
echo "  Repo root   : $REPO_ROOT"
echo "  Subagentes  : $AGENTS_SRC"
echo "  Skills      : $SKILLS_SRC"
echo "  Rules       : $RULES_DIR"
echo "  aks-mcp     : $AKS_MCP_BIN"
echo "  Referencia  : $REPO_ROOT/setup-kiro.sh"
echo ""
echo "  Abrir en Cursor por Remote SSH:"
echo "    usuario adoadmin, carpeta $REPO_ROOT"
echo ""
echo "  Si az no quedó autenticado:"
echo "    1. Completar AZURE_CLIENT_ID, AZURE_CLIENT_SECRET y AZURE_TENANT_ID en env/.env"
echo "    2. Volver a correr ./setup-cursor.sh"
echo "    3. kubectl config use-context <cluster>"
echo ""
