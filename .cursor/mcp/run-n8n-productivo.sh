#!/usr/bin/env bash
# n8n productivo. Misma URL que el MCP HTTP de Kiro.
# El bearer sale de N8N_PRODUCTIVO_MCP_TOKEN en env/.env.
# El User-Agent evita el bloqueo 1010 de Cloudflare.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
set -a
# shellcheck disable=SC1091
source "$ROOT/env/.env"
set +a
exec npx -y supergateway \
  --streamableHttp "${N8N_PRODUCTIVO_URL}/mcp-server/http" \
  --header "authorization:Bearer ${N8N_PRODUCTIVO_MCP_TOKEN}" \
  --header "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
