#!/usr/bin/env bash
# Cloudflare MCP. El token sale de CLOUDFLARE_API_TOKEN en env/.env.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
set -a
# shellcheck disable=SC1091
source "$ROOT/env/.env"
set +a
exec npx -y supergateway \
  --streamableHttp "https://mcp.cloudflare.com/mcp" \
  --header "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}"
