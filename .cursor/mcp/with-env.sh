#!/usr/bin/env bash
# Carga env/.env (el de Kiro, no versionado) y ejecuta el comando MCP.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
set -a
# shellcheck disable=SC1091
source "$ROOT/env/.env"
set +a
exec "$@"
