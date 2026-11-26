#!/bin/sh
# Fase 2 Schema Sync: main = BD de prod, siempre.
#   1. working tree limpio en origin/main (descarta lo que dejo el SchemaSyncTool sin subir)
#   2. Extract SOLO LECTURA de la BD a archivos (.sql por objeto, generados por el motor)
#   3. reconcile-from-extract.py: agrega / sobrescribe / borra objetos, ajusta el .sqlproj
#   4. build-check.sh: compila el proyecto (no toca la BD)
#   5. commit + push fast-forward a main SIEMPRE que haya cambios (nunca --force)
#   6. resultado JSON (ultima linea de stdout): status=success solo si compila y el push fue OK
# Variables: DATABASE REPO_NAME PROJECT_NAME SQL_SERVER WORK_ROOT ROOT RESULT_JSON_PATH (de run-sync.sh)
set -u
ROOT="${ROOT:-/home/soporte/schema-sync}"
REPO_DIR="$WORK_ROOT/$REPO_NAME"
STAGE="$WORK_ROOT/reconcile"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
rm -rf "$STAGE"; mkdir -p "$STAGE"

emit() {  # status message buildOk pushed sha
  python3 - "$@" <<'PY'
import json, os, sys
status, message, build_ok, pushed, sha = sys.argv[1:6]
rep = {}
p = os.path.join(os.environ["STAGE"], "report.json")
if os.path.exists(p):
    r = json.load(open(p))
    rep = {k: (len(r[k]) if isinstance(r[k], list) else r[k]) for k in ("added", "updated", "deleted", "unchanged")}
    if r.get("keptExistsInProdUnreadable"):
        rep["keptUnreadableInProd"] = r["keptExistsInProdUnreadable"]
errs = []
e = os.path.join(os.environ["STAGE"], "build", "errors.txt")
if os.path.exists(e):
    errs = [l.strip() for l in open(e) if l.strip()]
out = {"status": status, "database": os.environ["DATABASE"], "repo": os.environ["REPO_NAME"],
       "synced": pushed == "true", "hadDrift": bool(rep.get("added") or rep.get("updated") or rep.get("deleted")),
       "buildOk": build_ok == "true", "commitSha": sha or None, "prUrl": None,
       "pushedToMain": pushed == "true", "mode": "reconcile-from-extract",
       "reconcile": rep, "buildErrorCount": len(errs), "buildErrors": errs[:25],
       "message": message, "timestamp": os.environ["TS"]}
json.dump(out, open(os.environ["RESULT_JSON_PATH"], "w"))
print(json.dumps(out, ensure_ascii=False))
PY
}
export STAGE TS DATABASE REPO_NAME RESULT_JSON_PATH

[ -d "$REPO_DIR/.git" ] || { emit error "Reconcile: no existe la copia de trabajo $REPO_DIR" false false ""; exit 0; }
. "$ROOT/.env"
AUTH="Authorization: Basic $(printf ':%s' "$AZDO_PAT" | base64 -w0)"

# 1. working tree = origin/main
git -C "$REPO_DIR" -c http.extraHeader="$AUTH" fetch -q origin main 2>"$STAGE/git.err" || { emit error "Reconcile: git fetch fallo: $(head -c 300 "$STAGE/git.err")" false false ""; exit 0; }
git -C "$REPO_DIR" checkout -q -f -B main origin/main && git -C "$REPO_DIR" clean -q -fd -- . >/dev/null 2>&1

PROJ_DIR=$(dirname "$(find "$REPO_DIR" -name "${PROJECT_NAME}.sqlproj" -not -path '*/bin/*' -not -path '*/obj/*' | head -1)")
[ -f "$PROJ_DIR/${PROJECT_NAME}.sqlproj" ] || { emit error "Reconcile: no se encontro ${PROJECT_NAME}.sqlproj" false false ""; exit 0; }

# 2. Extract solo lectura
CS="Server=tcp:$SQL_SERVER,1433;Initial Catalog=$DATABASE;User ID=$SQL_USER;Password=$SQL_PASSWORD;Encrypt=True;TrustServerCertificate=False;ApplicationIntent=ReadOnly;Connect Timeout=60"
"$ROOT/sqlpackage/sqlpackage" /a:Extract /scs:"$CS" /tf:"$STAGE/extract" /p:ExtractTarget=SchemaObjectType /p:CommandTimeout=1800 > "$STAGE/extract.log" 2>&1 \
  || { emit error "Reconcile: Extract fallo: $(tail -3 "$STAGE/extract.log" | sed 's/Password=[^;]*/Password=***/g' | tr '\n' ' ' | head -c 400)" false false ""; exit 0; }

# 3. reconciliar. Si la pasada en seco va a borrar algo, se extrae tambien el DACPAC de prod
#    (solo lectura) para no borrar objetos que existen pero cuya definicion no se pudo leer.
REC_ARGS=""
python3 "$ROOT/reconcile-from-extract.py" --extract-dir "$STAGE/extract" --project-dir "$PROJ_DIR" --report "$STAGE/report-dry.json" --dry-run > "$STAGE/reconcile-dry.log" 2>&1 \
  || { emit error "Reconcile: script fallo (dry-run): $(tail -3 "$STAGE/reconcile-dry.log" | tr '\n' ' ')" false false ""; exit 0; }
NDEL=$(python3 -c "import json;print(len(json.load(open('$STAGE/report-dry.json'))['deleted']))")
if [ "$NDEL" -gt 0 ]; then
  "$ROOT/sqlpackage/sqlpackage" /a:Extract /scs:"$CS" /tf:"$STAGE/prod.dacpac" /p:CommandTimeout=1800 > "$STAGE/extract-dacpac.log" 2>&1 \
    || { emit error "Reconcile: Extract del DACPAC fallo, no se borra nada: $(tail -3 "$STAGE/extract-dacpac.log" | sed 's/Password=[^;]*/Password=***/g' | tr '\n' ' ' | head -c 400)" false false ""; exit 0; }
  REC_ARGS="--prod-dacpac $STAGE/prod.dacpac"
fi
python3 "$ROOT/reconcile-from-extract.py" --extract-dir "$STAGE/extract" --project-dir "$PROJ_DIR" --report "$STAGE/report.json" $REC_ARGS > "$STAGE/reconcile.log" 2>&1 \
  || { emit error "Reconcile: script fallo: $(tail -3 "$STAGE/reconcile.log" | tr '\n' ' ')" false false ""; exit 0; }

# 4. compilar
BUILD_OK=false
bash "$ROOT/build-check.sh" "$PROJ_DIR" "$STAGE/build" > "$STAGE/build.out" 2>&1 && BUILD_OK=true
NERR=$(wc -l < "$STAGE/build/errors.txt" 2>/dev/null || echo "?")

# 5. commit + push siempre que haya cambios
SHA=$(git -C "$REPO_DIR" rev-parse HEAD)
PUSHED=true; PUSHMSG="sin cambios: main ya estaba igual a la BD"
if [ -n "$(git -C "$REPO_DIR" status --porcelain)" ]; then
  git -C "$REPO_DIR" add -A
  git -C "$REPO_DIR" -c user.name=schema-sync-bot -c user.email=repo-sync@grupomontecristo.com \
      commit -q -m "chore(schema): sync $DATABASE from SQL MI (extract, main = prod) [$TS]"
  SHA=$(git -C "$REPO_DIR" rev-parse HEAD)
  if git -C "$REPO_DIR" -c http.extraHeader="$AUTH" push -q origin HEAD:refs/heads/main 2>"$STAGE/push.err"; then
    PUSHMSG="push a main OK"
  else
    PUSHED=false; PUSHMSG="git push a main fallo: $(head -c 300 "$STAGE/push.err" | tr '\n' ' ')"
  fi
fi

# 6. resultado
if [ "$PUSHED" = true ] && [ "$BUILD_OK" = true ]; then
  emit success "main = BD de prod. $PUSHMSG. Compila OK." true true "$SHA"
elif [ "$PUSHED" = true ]; then
  emit error "main = BD de prod ($PUSHMSG), pero el proyecto NO compila: $NERR error(s) en objetos de la BD. Revisar buildErrors." false true "$SHA"
else
  emit error "NO se pudo subir a main: $PUSHMSG" "$BUILD_OK" false "$SHA"
fi
exit 0
