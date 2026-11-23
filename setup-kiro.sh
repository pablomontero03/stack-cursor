#!/usr/bin/env bash
# ============================================================
# automation-kiro — setup.sh
# Bootstrap del stack en Kiro Crew sobre Linux/WSL2
# Uso: ./setup.sh
# Idempotente: se puede correr varias veces sin problema
# ============================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT

# Colores para output
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
echo -e "${CYAN}  automation-kiro — Setup (Kiro Crew / Linux)${NC}"
echo -e "${CYAN}  Repo: ${REPO_ROOT}${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

# ============================================================
# 1. Verificar dependencias
# ============================================================
echo "--- [1/7] Verificando dependencias ---"

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
check_dep kirocrew
check_dep kiro-cli
check_dep git

if [[ $MISSING_DEPS -eq 1 ]]; then
  err "Hay dependencias faltantes. Ver KiroCrew-Setup-WSL2.md para instalarlas."
  exit 1
fi

# ============================================================
# 2. Verificar / descargar aks-mcp Linux
# ============================================================
echo ""
echo "--- [2/7] Verificando aks-mcp ---"

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
echo "--- [3/7] Cargando variables de entorno ---"

ENV_FILE="$REPO_ROOT/env/.env"
if [[ -f "$ENV_FILE" ]]; then
  # Exportar todas las variables del .env (ignorar comentarios y vacías)
  set -a
  # shellcheck disable=SC1090
  source <(grep -v '^\s*#' "$ENV_FILE" | grep -v '^\s*$')
  set +a
  # Resolver OPENEDX_KEY_PATH si usa REPO_ROOT
  export OPENEDX_KEY_PATH="${REPO_ROOT}/env/keyopenedx.pem"
  # ADO_MCP_AUTH_TOKEN = AZURE_DEVOPS_PAT
  export ADO_MCP_AUTH_TOKEN="${AZURE_DEVOPS_PAT:-}"
  ok ".env cargado desde $ENV_FILE"
else
  warn ".env no encontrado en $ENV_FILE"
  warn "Copiá env/.env.example a env/.env y completá los valores antes de usar el stack"
fi

# ============================================================
# 4. Enlazar agentes al directorio de Kiro
# ============================================================
echo ""
echo "--- [4/7] Enlazando agentes a ~/.kiro/agents/ ---"

AGENTS_SRC="$REPO_ROOT/.kiro/agents"
AGENTS_DST="$HOME/.kiro/agents"
mkdir -p "$AGENTS_DST"

if [[ -d "$AGENTS_SRC" ]]; then
  for agent_file in "$AGENTS_SRC"/*.json; do
    [[ -f "$agent_file" ]] || continue
    agent_name="$(basename "$agent_file")"
    target="$AGENTS_DST/$agent_name"
    if [[ -L "$target" ]]; then
      rm -f "$target"
    fi
    ln -sf "$agent_file" "$target"
    ok "Agente enlazado: $agent_name"
  done
else
  warn "Directorio de agentes no encontrado: $AGENTS_SRC"
  warn "Ejecutar las Fases 2b del plan de migración primero"
fi

# ============================================================
# 5. Enlazar skills al directorio de Kiro Crew
# ============================================================
echo ""
echo "--- [5/7] Enlazando skills a ~/.kiro/crew/skills/ ---"

SKILLS_SRC="$REPO_ROOT/.kiro/skills"
SKILLS_DST="$HOME/.kiro/crew/skills"
mkdir -p "$SKILLS_DST"

if [[ -d "$SKILLS_SRC" ]]; then
  for skill_dir in "$SKILLS_SRC"/*/; do
    [[ -d "$skill_dir" ]] || continue
    skill_name="$(basename "$skill_dir")"
    target="$SKILLS_DST/$skill_name"
    if [[ -L "$target" ]]; then
      rm -f "$target"
    fi
    ln -sf "$skill_dir" "$target"
    ok "Skill enlazada: $skill_name"
  done
else
  warn "Directorio de skills no encontrado: $SKILLS_SRC"
fi

# ============================================================
# 6. Agregar REPO_ROOT al .bashrc del usuario (si no está)
# ============================================================
echo ""
echo "--- [6/7] Configurando REPO_ROOT en el shell ---"

BASHRC="$HOME/.bashrc"
REPO_ROOT_LINE="export REPO_ROOT=\"$REPO_ROOT\""

if grep -qF "REPO_ROOT" "$BASHRC" 2>/dev/null; then
  ok "REPO_ROOT ya está en $BASHRC"
else
  echo "" >> "$BASHRC"
  echo "# automation-kiro stack" >> "$BASHRC"
  echo "$REPO_ROOT_LINE" >> "$BASHRC"
  ok "REPO_ROOT agregado a $BASHRC"
fi

# También exportar ahora mismo para esta sesión
export REPO_ROOT

# ============================================================
# 7. Reiniciar Kiro Crew para cargar agentes/skills nuevos
# ============================================================
echo ""
echo "--- [7/7] Reiniciando Kiro Crew ---"

if command -v kirocrew &>/dev/null; then
  if kirocrew restart &>/dev/null; then
    ok "Kiro Crew reiniciado"
  else
    warn "No se pudo reiniciar Crew automáticamente (puede que no esté corriendo como servicio)"
    info "Correr manualmente: kirocrew restart"
  fi
fi

# ============================================================
# Resumen final
# ============================================================
echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${GREEN}  ✅ Setup completo${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""
echo "  Repo root   : $REPO_ROOT"
echo "  Agentes     : $AGENTS_DST"
echo "  Skills      : $SKILLS_DST"
echo "  aks-mcp     : $AKS_MCP_BIN"
echo "  Dashboard   : http://localhost:5476"
echo ""
echo "  Próximos pasos si es una instalación nueva:"
echo "    1. Completar env/.env con los valores reales"
echo "    2. az login --use-device-code"
echo "    3. kubectl config use-context <cluster>"
echo "    4. kiro-cli login (si no está logueado)"
echo ""
