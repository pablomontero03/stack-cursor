#!/usr/bin/env bash
# datahub-query.sh — helper de consulta a la API GMS de DataHub (prod-onprem-01 / k3s .31)
#
# Lee DATAHUB_GMS_URL y DATAHUB_GMS_TOKEN de env/.env (no versionado, chmod 600).
# La autenticacion de la API esta activada (METADATA_SERVICE_AUTH_ENABLED=true);
# un 401 = servidor sano pidiendo token, no fallo.
#
# Uso:
#   ./datahub-query.sh me                     # usuario autenticado
#   ./datahub-query.sh count                  # total de datasets
#   ./datahub-query.sh search <texto> [n]     # busca datasets (n=10 por defecto)
#   ./datahub-query.sh dataset <urn>          # detalle + esquema de un dataset
#   ./datahub-query.sh sources                # ingestion sources configuradas
#   ./datahub-query.sh gql '<query graphql>'  # GraphQL arbitrario
#   ./datahub-query.sh rest <path>            # GET REST/OpenAPI arbitrario (ej /openapi/v3/entity/dataset?count=1)
#
# Requiere: curl, jq (opcional; si no esta, imprime JSON crudo).

set -euo pipefail

# --- Resolver y cargar env/.env ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Buscar la raiz del repo (donde vive env/.env) subiendo desde el script
REPO_ROOT="${REPO_ROOT:-}"
if [[ -z "$REPO_ROOT" ]]; then
  d="$SCRIPT_DIR"
  while [[ "$d" != "/" ]]; do
    if [[ -f "$d/env/.env" ]]; then REPO_ROOT="$d"; break; fi
    d="$(dirname "$d")"
  done
fi
if [[ -z "$REPO_ROOT" || ! -f "$REPO_ROOT/env/.env" ]]; then
  echo "ERROR: no encuentro env/.env. Exporta REPO_ROOT o corre desde el repo." >&2
  exit 1
fi

set -a; . "$REPO_ROOT/env/.env"; set +a

: "${DATAHUB_GMS_URL:?falta DATAHUB_GMS_URL en env/.env}"
: "${DATAHUB_GMS_TOKEN:?falta DATAHUB_GMS_TOKEN en env/.env}"

HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1
_out() { if [[ $HAVE_JQ -eq 1 ]]; then jq .; else cat; fi; }

# --- Llamadas base ---
_gql() {
  local query="$1"
  # Serializar el query a JSON de forma segura
  local payload
  if [[ $HAVE_JQ -eq 1 ]]; then
    payload="$(jq -nc --arg q "$query" '{query:$q}')"
  else
    # Escape minimo si no hay jq
    local esc="${query//\\/\\\\}"; esc="${esc//\"/\\\"}"; esc="${esc//$'\n'/ }"
    payload="{\"query\":\"$esc\"}"
  fi
  curl -sk -X POST "$DATAHUB_GMS_URL/api/graphql" \
    -H "Authorization: Bearer $DATAHUB_GMS_TOKEN" \
    -H 'Content-Type: application/json' \
    --data-raw "$payload"
}

_rest() {
  local path="$1"
  curl -sk "$DATAHUB_GMS_URL$path" \
    -H "Authorization: Bearer $DATAHUB_GMS_TOKEN" \
    -H 'Accept: application/json'
}

# --- Subcomandos ---
cmd="${1:-me}"; shift || true

case "$cmd" in
  me)
    _gql '{ me { corpUser { username urn } platformPrivileges { managePolicies } } }' | _out
    ;;
  count)
    _gql '{ search(input:{type:DATASET, query:"*", start:0, count:0}) { total } }' | _out
    ;;
  search)
    q="${1:?uso: search <texto> [n]}"; n="${2:-10}"
    _gql "{ search(input:{type:DATASET, query:\"$q\", start:0, count:$n}) {
      total
      searchResults { entity { urn ... on Dataset { name platform { name } } } }
    } }" | _out
    ;;
  dataset)
    urn="${1:?uso: dataset <urn>}"
    _gql "{ dataset(urn:\"$urn\") {
      urn name platform { name }
      schemaMetadata { fields { fieldPath type nativeDataType } }
    } }" | _out
    ;;
  sources)
    _gql '{ listIngestionSources(input:{start:0, count:50}) {
      total
      ingestionSources { urn name type }
    } }' | _out
    ;;
  gql)
    _gql "${1:?uso: gql '<query>'}" | _out
    ;;
  rest)
    _rest "${1:?uso: rest <path>}" | _out
    ;;
  *)
    echo "Subcomando desconocido: $cmd" >&2
    echo "Usa: me | count | search <texto> [n] | dataset <urn> | sources | gql '<q>' | rest <path>" >&2
    exit 2
    ;;
esac
