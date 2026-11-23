#!/bin/bash
################################################################################
# validate-all-servers.sh
# 
# Valida conectividad a TODOS los servidores del catálogo siguiendo
# las lecciones aprendidas de 2026-11-23.
#
# Uso: ./scripts/validate-all-servers.sh [--verbose]
################################################################################

set -euo pipefail

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

REPO_ROOT="/home/cursor/stack-cursor"
VERBOSE=false

# Parsear argumentos
if [[ "${1:-}" == "--verbose" ]]; then
    VERBOSE=true
fi

# Cargar variables de entorno CORRECTAMENTE
echo -e "${BLUE}Cargando variables de entorno...${NC}"
set -a
source "${REPO_ROOT}/env/.env"
set +a

# Contadores
TOTAL=0
CONECTADOS=0
FALLIDOS=0
DESHABILITADOS=0

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  VALIDACIÓN COMPLETA DE SERVIDORES - $(date '+%Y-%m-%d %H:%M:%S')"
echo "════════════════════════════════════════════════════════════"
echo ""

################################################################################
# Función: Validar servidor Linux con password
################################################################################
validate_linux_pass() {
    local host=$1
    local user=$2
    local pass_var=$3
    local expected_hostname=$4
    local description=$5
    
    TOTAL=$((TOTAL + 1))
    echo -e "${BLUE}[$TOTAL] $host ($user) - $description${NC}"
    
    # Paso 1: Variable
    local pass="${!pass_var:-}"
    if [ -z "$pass" ]; then
        echo -e "${RED}   ✗ Variable $pass_var NO definida${NC}"
        FALLIDOS=$((FALLIDOS + 1))
        return 1
    fi
    [ "$VERBOSE" = true ] && echo "   ✓ Variable $pass_var definida"
    
    # Paso 2: Ping
    if ! ping -c 1 -W 2 "$host" >/dev/null 2>&1; then
        echo -e "${RED}   ✗ No responde a ping${NC}"
        FALLIDOS=$((FALLIDOS + 1))
        return 1
    fi
    [ "$VERBOSE" = true ] && echo "   ✓ Ping OK"
    
    # Paso 3: SSH
    local result
    result=$(timeout 5 sshpass -p "$pass" ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o BatchMode=no "${user}@${host}" "hostname" 2>&1)
    
    if echo "$result" | grep -q "$expected_hostname"; then
        echo -e "${GREEN}   ✅ CONECTADO - $expected_hostname${NC}"
        CONECTADOS=$((CONECTADOS + 1))
        return 0
    else
        echo -e "${RED}   ✗ FALLO: $(echo "$result" | head -1)${NC}"
        FALLIDOS=$((FALLIDOS + 1))
        return 1
    fi
}

################################################################################
# Función: Validar servidor Linux con clave privada
################################################################################
validate_linux_key() {
    local host=$1
    local user=$2
    local key_path=$3
    local expected_hostname=$4
    local description=$5
    
    TOTAL=$((TOTAL + 1))
    echo -e "${BLUE}[$TOTAL] $host ($user) - $description${NC}"
    
    # Paso 1: Clave existe
    if [ ! -f "$key_path" ]; then
        echo -e "${RED}   ✗ Clave $key_path NO encontrada${NC}"
        FALLIDOS=$((FALLIDOS + 1))
        return 1
    fi
    [ "$VERBOSE" = true ] && echo "   ✓ Clave privada encontrada"
    
    # Paso 2: Ping (opcional para OpenEdX prod que a veces no responde ping)
    if ! ping -c 1 -W 2 "$host" >/dev/null 2>&1; then
        [ "$VERBOSE" = true ] && echo "   ⚠ No responde a ping (continuando)"
    else
        [ "$VERBOSE" = true ] && echo "   ✓ Ping OK"
    fi
    
    # Paso 3: SSH
    local result
    result=$(timeout 5 ssh -i "$key_path" -o ConnectTimeout=3 -o StrictHostKeyChecking=no "${user}@${host}" "hostname" 2>&1)
    
    if echo "$result" | grep -q "$expected_hostname"; then
        echo -e "${GREEN}   ✅ CONECTADO - $expected_hostname${NC}"
        CONECTADOS=$((CONECTADOS + 1))
        return 0
    else
        echo -e "${RED}   ✗ FALLO: $(echo "$result" | head -1)${NC}"
        FALLIDOS=$((FALLIDOS + 1))
        return 1
    fi
}

################################################################################
# Función: Validar servidor Windows con WinRM
################################################################################
validate_windows() {
    local host=$1
    local user=$2
    local pass_var=$3
    local expected_hostname=$4
    local description=$5
    
    TOTAL=$((TOTAL + 1))
    echo -e "${BLUE}[$TOTAL] $host ($user) - $description${NC}"
    
    # Paso 1: Variable
    local pass="${!pass_var:-}"
    if [ -z "$pass" ]; then
        echo -e "${RED}   ✗ Variable $pass_var NO definida${NC}"
        FALLIDOS=$((FALLIDOS + 1))
        return 1
    fi
    [ "$VERBOSE" = true ] && echo "   ✓ Variable $pass_var definida"
    
    # Paso 2: Ping
    if ! ping -c 1 -W 2 "$host" >/dev/null 2>&1; then
        [ "$VERBOSE" = true ] && echo "   ⚠ No responde a ping (continuando)"
    else
        [ "$VERBOSE" = true ] && echo "   ✓ Ping OK"
    fi
    
    # Paso 3: WinRM con Python
    local py_result
    py_result=$(python3 << PYEOF
import winrm, os, sys
try:
    session = winrm.Session('http://${host}:5985/wsman', 
                           auth=('${user}', '${pass}'), 
                           transport='ntlm', 
                           server_cert_validation='ignore')
    result = session.run_cmd('hostname')
    if result.status_code == 0:
        print(result.std_out.decode().strip())
        sys.exit(0)
    else:
        print(f"ERROR_CODE_{result.status_code}")
        sys.exit(1)
except Exception as e:
    print(f"ERROR_{type(e).__name__}")
    sys.exit(1)
PYEOF
)
    
    local exit_code=$?
    if [ $exit_code -eq 0 ] && echo "$py_result" | grep -qi "$expected_hostname"; then
        echo -e "${GREEN}   ✅ CONECTADO - $py_result${NC}"
        CONECTADOS=$((CONECTADOS + 1))
        return 0
    else
        echo -e "${RED}   ✗ FALLO: $py_result${NC}"
        FALLIDOS=$((FALLIDOS + 1))
        return 1
    fi
}

################################################################################
# Función: Servidor deshabilitado
################################################################################
mark_disabled() {
    local host=$1
    local description=$2
    local reason=$3
    
    TOTAL=$((TOTAL + 1))
    DESHABILITADOS=$((DESHABILITADOS + 1))
    echo -e "${YELLOW}[$TOTAL] $host - $description${NC}"
    echo -e "${YELLOW}   🔒 DESHABILITADO: $reason${NC}"
}

################################################################################
# SERVIDORES LINUX
################################################################################

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "SERVIDORES LINUX"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 10.1.0.200 - Servidor actual
TOTAL=$((TOTAL + 1))
CONECTADOS=$((CONECTADOS + 1))
echo -e "${BLUE}[$TOTAL] 10.1.0.200 (adoadmin) - Agente ADO${NC}"
echo -e "${GREEN}   ✅ SERVIDOR ACTUAL - $(hostname)${NC}"
echo ""

# 172.16.2.43 - k3s dev
validate_linux_pass "172.16.2.43" "administrator" "DEV_SRV_PASS" "srv-desarrollo-5" "k3s dev"
echo ""

# 172.16.2.31 - k3s prod + Ollama
validate_linux_pass "172.16.2.31" "adm01" "LINUX_SRV_ADM_PASS" "srvdesarrollo03" "k3s prod + Ollama"
echo ""

# 172.16.2.60 - n8n Docker
validate_linux_pass "172.16.2.60" "soporte" "N8N_SRV_PASS" "SVR-SFTP-TEST" "n8n Docker"
echo ""

# 135.119.204.153 - OpenEdX prod
validate_linux_key "135.119.204.153" "adminedx" "${REPO_ROOT}/env/keyopenedx.pem" "VM" "OpenEdX prod"
echo ""

# 172.16.2.61 - NVIDIA GPU #1
validate_linux_pass "172.16.2.61" "${NVIDIA_SPARK_61_USER}" "NVIDIA_SPARK_61_PASS" "spark-8bac" "NVIDIA DGX GPU #1"
echo ""

# 172.16.2.63 - NVIDIA GPU #2
validate_linux_pass "172.16.2.63" "${NVIDIA_SPARK_63_USER}" "NVIDIA_SPARK_63_PASS" "spark-0a57" "NVIDIA DGX GPU #2"
echo ""

# 172.16.2.95 - eIntegra Core
validate_linux_pass "172.16.2.95" "${EPRAC_95_USER}" "EPRAC_95_PASS" "crsrvapipampa01" "eIntegra Core Docker"
echo ""

# 10.2.1.132 - OpenEdX dev
TOTAL=$((TOTAL + 1))
echo -e "${BLUE}[$TOTAL] 10.2.1.132 (adminedx) - OpenEdX dev${NC}"
if ping -c 1 -W 2 "10.2.1.132" >/dev/null 2>&1; then
    echo -e "${YELLOW}   ⚠ Ping OK pero falta clave keyopenedx-dev.pem${NC}"
    FALLIDOS=$((FALLIDOS + 1))
else
    echo -e "${RED}   ✗ NO ALCANZABLE (timeout)${NC}"
    FALLIDOS=$((FALLIDOS + 1))
fi
echo ""

# 172.16.16.193 - pampa api (disabled)
mark_disabled "172.16.16.193" "pampa api prod" "Caído por corte de luz"
echo ""

################################################################################
# SERVIDORES WINDOWS
################################################################################

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "SERVIDORES WINDOWS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 172.16.2.127 - SRV-PRTG
validate_windows "172.16.2.127" "administrator" "LINUX_127_PASS" "SRV-PRTG" "ADO builds Windows"
echo ""

# 172.16.2.76 - CRSRVSISRDP
validate_windows "172.16.2.76" "${CRSRVSISRDP_76_USER}" "CRSRVSISRDP_76_PASS" "CRSRVSISRDP" "IIS eFlow"
echo ""

# 172.16.16.243 - SRV-UAT-RJ
TOTAL=$((TOTAL + 1))
echo -e "${BLUE}[$TOTAL] 172.16.16.243 (administrator.MCCL) - IIS any2cloud QA${NC}"
echo -e "${YELLOW}   ⚠ NO RUTEADO desde hub (subred UAT 172.16.16.x)${NC}"
FALLIDOS=$((FALLIDOS + 1))
echo ""

################################################################################
# RESUMEN
################################################################################

echo "════════════════════════════════════════════════════════════"
echo "RESUMEN FINAL"
echo "════════════════════════════════════════════════════════════"
echo ""

local pct_conectados=$((CONECTADOS * 100 / TOTAL))

echo -e "${GREEN}✅ CONECTADOS:    $CONECTADOS de $TOTAL ($pct_conectados%)${NC}"
echo -e "${RED}❌ FALLIDOS:      $FALLIDOS${NC}"
echo -e "${YELLOW}🔒 DESHABILITADOS: $DESHABILITADOS${NC}"
echo ""

if [ $CONECTADOS -ge 9 ]; then
    echo -e "${GREEN}Estado: EXCELENTE${NC}"
    exit 0
elif [ $CONECTADOS -ge 6 ]; then
    echo -e "${YELLOW}Estado: BUENO${NC}"
    exit 0
else
    echo -e "${RED}Estado: REQUIERE ATENCIÓN${NC}"
    exit 1
fi
