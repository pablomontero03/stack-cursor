#!/bin/sh
# Parametric schema-sync runner (READ-ONLY against SQL).
# Env/args:
#   DATABASE, REPO_NAME, PROJECT_NAME, REPO_URL, SQL_SERVER (optional)
#   WORK_ROOT (optional; default $ROOT/work/$REPO_NAME)
#   BUNDLE_JSON — path or inline JSON for solution-bundle (global+workflow)
#   PRESERVE_SQLCMD_REFS — comma-separated DB names for single-project mode
set -eu

if [ -n "${SCHEMA_SYNC_ROOT:-}" ]; then
  ROOT="$SCHEMA_SYNC_ROOT"
elif [ -d /data/schema-sync ]; then
  ROOT="/data/schema-sync"
elif [ -d /home/soporte/schema-sync ]; then
  ROOT="/home/soporte/schema-sync"
else
  ROOT="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
fi

cd "$ROOT"

# ── Fase 2 (opt-in por base): main = BD de prod via Extract + reconciliacion ──────
# Si DATABASE esta listada en reconcile-enabled.txt: corre el sync de siempre (salida a
# stderr) y despues reconcile-and-push.sh, cuyo JSON es el resultado final para n8n.
if [ -z "${RECONCILE_INNER:-}" ] && [ -z "${BUNDLE_JSON:-}" ] && [ -n "${DATABASE:-}" ] \
   && [ -f "$ROOT/reconcile-enabled.txt" ] && grep -qxF "$DATABASE" "$ROOT/reconcile-enabled.txt"; then
  RECONCILE_INNER=1 sh "$0" "$@" >&2 || true
  export ROOT DATABASE REPO_NAME="${REPO_NAME:-project_$DATABASE}"
  export PROJECT_NAME="${PROJECT_NAME:-$DATABASE}"
  export SQL_SERVER="${SQL_SERVER:-gmon-prod-sqlmi-eastus2-0001.15c9ad07b4c3.database.windows.net}"
  export WORK_ROOT="${WORK_ROOT:-$ROOT/work/$REPO_NAME}"
  export RESULT_JSON_PATH="${RESULT_JSON_PATH:-$ROOT/results/${DATABASE}.json}"
  exec sh "$ROOT/reconcile-and-push.sh"
fi
# Bundle: si algun proyecto del bundle (projectName) esta en reconcile-enabled.txt, corre el sync
# de siempre del bundle y despues reconcile-bundle-and-push.sh sobre esos proyectos.
if [ -z "${RECONCILE_INNER:-}" ] && [ -n "${BUNDLE_JSON:-}" ] && [ -f "${BUNDLE_JSON:-}" ] \
   && [ -f "$ROOT/reconcile-enabled.txt" ] \
   && python3 -c 'import json,sys; b=json.load(open(sys.argv[1])); e={l.strip() for l in open(sys.argv[2])}; sys.exit(0 if any(p["projectName"] in e for p in b.get("projects",[])) else 1)' "$BUNDLE_JSON" "$ROOT/reconcile-enabled.txt"; then
  export ROOT BUNDLE_JSON
  export SQL_SERVER="${SQL_SERVER:-gmon-prod-sqlmi-eastus2-0001.15c9ad07b4c3.database.windows.net}"
  export WORK_ROOT="${WORK_ROOT:-$ROOT/work/$REPO_NAME}"
  export RESULT_JSON_PATH="${RESULT_JSON_PATH:-$ROOT/results/bundle-${REPO_NAME}.json}"
  RECONCILE_INNER=1 sh "$0" "$@" >&2 || true
  cp -f "$RESULT_JSON_PATH" "$WORK_ROOT/phase1-result.json" 2>/dev/null || true
  exec bash "$ROOT/reconcile-bundle-and-push.sh"
fi
# ── fin Fase 2 ───────────────────────────────────────────────────────────────────

# Allow per-workflow overrides (e.g. Softland on-prem login) to win over .env defaults.
_SQL_USER_OVERRIDE="${SQL_USER:-}"
_SQL_PASSWORD_OVERRIDE="${SQL_PASSWORD:-}"
_SQL_SERVER_OVERRIDE="${SQL_SERVER:-}"

if [ -f "$ROOT/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$ROOT/.env"
  set +a
fi

[ -n "$_SQL_USER_OVERRIDE" ] && SQL_USER="$_SQL_USER_OVERRIDE"
[ -n "$_SQL_PASSWORD_OVERRIDE" ] && SQL_PASSWORD="$_SQL_PASSWORD_OVERRIDE"
[ -n "$_SQL_SERVER_OVERRIDE" ] && SQL_SERVER="$_SQL_SERVER_OVERRIDE"

: "${SQL_USER:?SQL_USER required}"
: "${SQL_PASSWORD:?SQL_PASSWORD required}"
: "${AZDO_PAT:?AZDO_PAT required}"

# Hard stop: never allow SqlPackage publish/deploy overrides via env.
case "${SQLPACKAGE_EXTRA_ARGS:-}${SCHEMA_SYNC_EXTRA_ARGS:-}" in
  *Publish*|*Deploy*|*TargetConnectionString*)
    echo "Refusing schema-sync: extra args must not Publish/Deploy to SQL." >&2
    exit 2
    ;;
esac
echo "Schema-sync SQL mode: READ-ONLY (ApplicationIntent=ReadOnly, /Action:Extract only)" >&2

# Defaults keep OpsObservability pilot behavior if unset.
# A bundle run does not set DATABASE; that default must not label its commit.
DATABASE_WAS_UNSET=0
if [ -z "${DATABASE:-}" ]; then
  DATABASE_WAS_UNSET=1
fi
DATABASE="${DATABASE:-OpsObservability}"
REPO_NAME="${REPO_NAME:-project_OpsObservability}"
PROJECT_NAME="${PROJECT_NAME:-$DATABASE}"
SQL_SERVER="${SQL_SERVER:-gmon-prod-sqlmi-eastus2-0001.15c9ad07b4c3.database.windows.net}"
REPO_URL="${REPO_URL:-https://dev.azure.com/Shared-Service-GM/Database-Administration-and-Monitoring/_git/${REPO_NAME}}"
PR_REVIEWER_EMAIL="${PR_REVIEWER_EMAIL:-pmontero@grupomontecristo.com}"

export SQL_USER SQL_PASSWORD AZDO_PAT PR_REVIEWER_EMAIL
SQLPACKAGE="${SQLPACKAGE:-$ROOT/sqlpackage/sqlpackage}"
if [ ! -x "$SQLPACKAGE" ] && [ -x "$ROOT/sqlpackage/sqlpackage" ]; then
  SQLPACKAGE="$ROOT/sqlpackage/sqlpackage"
fi
export SQLPACKAGE

# Per-repo persistent work dir + lock
WORK_ROOT="${WORK_ROOT:-$ROOT/work/$REPO_NAME}"
mkdir -p "$WORK_ROOT"
export WORK_ROOT

LOCK_FILE="$WORK_ROOT/schema-sync.flock"
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    echo "SYNC_EXIT=3"
    echo "{\"status\":\"error\",\"database\":\"$DATABASE\",\"repo\":\"$REPO_NAME\",\"synced\":false,\"hadDrift\":false,\"buildOk\":false,\"message\":\"Otra corrida de schema-sync ya está en curso para $REPO_NAME (flock).\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
    exit 3
  fi
fi

RESULT_DIR="$ROOT/results"
mkdir -p "$RESULT_DIR"
if [ -n "${BUNDLE_JSON:-}" ]; then
  RESULT_JSON_PATH="${RESULT_JSON_PATH:-$RESULT_DIR/bundle-${REPO_NAME}.json}"
else
  RESULT_JSON_PATH="${RESULT_JSON_PATH:-$RESULT_DIR/${DATABASE}.json}"
fi
export RESULT_JSON_PATH
RUN_STARTED_EPOCH="$(date +%s)"

chmod +x "$ROOT/SchemaSyncTool" "$SQLPACKAGE" 2>/dev/null || true
# publish/ holds self-contained runtime + binary
if [ -x "$ROOT/publish/SchemaSyncTool" ]; then
  TOOL="$ROOT/publish/SchemaSyncTool"
elif [ -x "$ROOT/SchemaSyncTool" ]; then
  TOOL="$ROOT/SchemaSyncTool"
else
  echo "SchemaSyncTool binary not found under $ROOT" >&2
  exit 1
fi
chmod +x "$TOOL" 2>/dev/null || true
set +e
if [ -n "${BUNDLE_JSON:-}" ]; then
  export BUNDLE_JSON
  "$TOOL" \
    --work-root "$WORK_ROOT" \
    --bundle-json "$BUNDLE_JSON" \
    --sql-server "$SQL_SERVER" \
    --repo-name "$REPO_NAME" \
    --repo-url "$REPO_URL" \
    --pr-reviewer-email "$PR_REVIEWER_EMAIL" \
    "$@"
else
  if [ -n "${PRESERVE_SQLCMD_REFS:-}" ]; then
    export PRESERVE_SQLCMD_REFS
  fi
  "$TOOL" \
    --work-root "$WORK_ROOT" \
    --sql-server "$SQL_SERVER" \
    --database "$DATABASE" \
    --repo-name "$REPO_NAME" \
    --project-name "$PROJECT_NAME" \
    --repo-url "$REPO_URL" \
    --pr-reviewer-email "$PR_REVIEWER_EMAIL" \
    "$@"
fi
exit_code=$?
set -e
echo "SYNC_EXIT=$exit_code" >&2

accept_database() {
  if [ -n "${BUNDLE_JSON:-}" ] && [ "$DATABASE_WAS_UNSET" -eq 1 ]; then
    printf '%s' "$REPO_NAME"
  else
    printf '%s' "$DATABASE"
  fi
}

# Prefer a result written by THIS run (mtime >= start). Never reuse stale JSON.
RESULT_FRESH=0
if [ -f "$RESULT_JSON_PATH" ]; then
  # portable mtime check via find -newermt when available
  if find "$RESULT_JSON_PATH" -newermt "@${RUN_STARTED_EPOCH}" 2>/dev/null | grep -q .; then
    RESULT_FRESH=1
  elif [ "$(stat -c %Y "$RESULT_JSON_PATH" 2>/dev/null || echo 0)" -ge "$RUN_STARTED_EPOCH" ]; then
    RESULT_FRESH=1
  fi
fi

if [ "$exit_code" -eq 0 ]; then
  # Tool already printed compact JSON on stdout.
  exit 0
fi

if [ "$RESULT_FRESH" -eq 1 ]; then
  # Try to accept known DacFx incongruence before surfacing the raw error
  _ACCEPT="$ROOT/accept-dacfx-incongruence.py"
  _REPO_DIR="$WORK_ROOT/${REPO_NAME}"
  if [ "$exit_code" -ne 0 ] && [ -f "$_ACCEPT" ]; then
    _OUT=$(python3 "$_ACCEPT"              --result-json "$RESULT_JSON_PATH"              --repo-dir    "$_REPO_DIR"              --database    "$(accept_database)" --allow-missing-tables 2>&1)
    if [ $? -eq 0 ]; then
      echo "$_OUT"
      exit 0
    fi
  fi
  # Soft failure after Emit: surface file (may be full-size) and treat as handled for n8n.
  head -c 200000 "$RESULT_JSON_PATH"
  echo
  exit 0
fi

echo "{\"status\":\"error\",\"database\":\"$(accept_database)\",\"repo\":\"$REPO_NAME\",\"synced\":false,\"hadDrift\":false,\"buildOk\":false,\"message\":\"SchemaSyncTool exit=$exit_code without fresh result JSON. Check .NET runtime / logs.\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
# ── DacFx gap recovery ──────────────────────────────────────────────────────
# If SchemaSyncTool failed due to "hueco DacFx" (missing tables not emitted by
# PublishChangesToProject), generate the missing .sql files from the DACPAC and
# retry the full sync pass.  Pure Python, no SQL writes, no DB connection.
# Trigger recovery when the result JSON signals a DacFx gap (regardless of freshness)
_HAS_GAP=0
if [ -f "$RESULT_JSON_PATH" ] && grep -q "Falta tabla" "$RESULT_JSON_PATH" 2>/dev/null; then
  _HAS_GAP=1
fi
if false; then  # DISABLED: DacFx gap recovery (usr_repo_sync now has db_datareader)
  _FMT_SCRIPT="$ROOT/fix-missing-tables.py"
  _DACPAC="$WORK_ROOT/out/${PROJECT_NAME}/db.dacpac"
  _PROJ_DIR="$WORK_ROOT/${REPO_NAME}/databases/${PROJECT_NAME}"
  if python3 "$_FMT_SCRIPT" \
       --dacpac       "$_DACPAC" \
       --project-dir  "$_PROJ_DIR" \
       --result-json  "$RESULT_JSON_PATH" 2>&1; then
    echo "fix-missing-tables: OK, relanzando SchemaSyncTool con DACPAC ya en disco..." >&2
    set +e
    "$TOOL" \
      --work-root        "$WORK_ROOT" \
      --sql-server       "$SQL_SERVER" \
      --database         "$DATABASE" \
      --repo-name        "$REPO_NAME" \
      --project-name     "$PROJECT_NAME" \
      --repo-url         "$REPO_URL" \
      --pr-reviewer-email "$PR_REVIEWER_EMAIL"
    exit_code=$?
    set -e
    echo "SYNC_EXIT_RETRY=$exit_code" >&2
    if [ "$exit_code" -eq 0 ]; then
      exit 0
    fi
    # Re-check result file freshness
    RESULT_FRESH=0
    if [ -f "$RESULT_JSON_PATH" ]; then
      if find "$RESULT_JSON_PATH" -newermt "@${RUN_STARTED_EPOCH}" 2>/dev/null | grep -q .; then
        RESULT_FRESH=1
      fi
    fi
    if [ "$RESULT_FRESH" -eq 1 ]; then
      head -c 200000 "$RESULT_JSON_PATH"; echo; exit 0
    fi
  fi
fi
# ── end DacFx gap recovery ──────────────────────────────────────────────────


# ── DacFx incongruence acceptance ───────────────────────────────────────────
# When the only remaining error is the known DacFx Linux bug (pace.* tables
# with circular FKs never fully emitted by PublishChangesToProject), accept
# the result as success so n8n reports OK instead of a false alarm.
if [ "$exit_code" -ne 0 ] && [ -f "$RESULT_JSON_PATH" ]; then
  _ACCEPT="$ROOT/accept-dacfx-incongruence.py"
  _REPO_DIR="$WORK_ROOT/${REPO_NAME}"
  if [ -f "$_ACCEPT" ]; then
    _OUT=$(python3 "$_ACCEPT" \
             --result-json "$RESULT_JSON_PATH" \
             --repo-dir    "$_REPO_DIR" \
             --database    "$(accept_database)"              --allow-missing-tables 2>&1)
    if [ $? -eq 0 ]; then
      echo "$_OUT"
      exit 0
    fi
  fi
fi
# ── end DacFx incongruence acceptance ───────────────────────────────────────
# ── PR fallback para bundles (SchemaSyncTool no abre PR en modo bundle) ────
# Si el sync exitoso dejó prUrl=null (bug bundle), abrirlo via ADO REST.
if [ -f "$RESULT_JSON_PATH" ]; then
  _PR_SCRIPT="$ROOT/open-pr-if-missing.py"
  if [ -f "$_PR_SCRIPT" ]; then
    python3 "$_PR_SCRIPT" \
      --result-json "$RESULT_JSON_PATH" \
      --repo-name   "${REPO_NAME:-}" >/dev/null 2>&1 || true
  fi
fi
# ── end PR fallback ─────────────────────────────────────────────────────────


exit "$exit_code"
