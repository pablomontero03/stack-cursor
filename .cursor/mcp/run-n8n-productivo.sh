#!/usr/bin/env bash
# n8n productivo. Misma URL que el MCP HTTP de Kiro.
# El bearer sale de N8N_PRODUCTIVO_MCP_TOKEN en env/.env.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
set -a
# shellcheck disable=SC1091
source "$ROOT/env/.env"
set +a
exec npx -y supergateway \
  --streamableHttp "${N8N_PRODUCTIVO_URL}/mcp-server/http" \
  --header "authorization:Bearer ${N8N_PRODUCTIVO_MCP_TOKEN}"
