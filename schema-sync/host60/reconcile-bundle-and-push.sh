#!/bin/bash
# Fase 2 para un bundle (varios proyectos SSDT en un mismo repo), ej. core-workflow-global.
# Solo reconcilia los proyectos del bundle listados en reconcile-enabled.txt (por projectName),
# en el orden del bundle, con sus reglas (keepAsNone, skipClrAssemblies). Un solo commit y push.
# Proyectos con preserveSqlCmdRefs (workflow) todavia NO estan soportados: se rechazan.
# Variables: ROOT BUNDLE_JSON REPO_NAME SQL_SERVER WORK_ROOT RESULT_JSON_PATH (de run-sync.sh)
set -u
ROOT="${ROOT:-/home/soporte/schema-sync}"
REPO_DIR="$WORK_ROOT/$REPO_NAME"
STAGE="$WORK_ROOT/reconcile"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
rm -rf "$STAGE"; mkdir -p "$STAGE"
export STAGE TS REPO_NAME RESULT_JSON_PATH BUNDLE_JSON WORK_ROOT

emit() {  # status message pushed sha
  python3 - "$@" <<'PY'
import json, os, sys, glob
status, message, pushed, sha = sys.argv[1:5]
b = json.load(open(os.environ["BUNDLE_JSON"]))
projects = {}
for d in sorted(glob.glob(os.path.join(os.environ["STAGE"], "p-*"))):
    name = os.path.basename(d)[2:]
    info = {}
    if os.path.exists(f"{d}/report.json"):
        r = json.load(open(f"{d}/report.json"))
        info = {k: len(r[k]) for k in ("added", "updated", "deleted")}
        info["unchanged"] = r["unchanged"]
        if r.get("keptExistsInProdUnreadable"): info["keptUnreadableInProd"] = r["keptExistsInProdUnreadable"]
        if r.get("sqlcmdVars"):
            info["sqlcmdVarRefsWritten"] = r.get("sqlcmdVarRefsWritten")
            info["sqlcmdStringsNewLiteral"] = r.get("sqlcmdStringsNewLiteral")
    e = f"{d}/build/errors.txt"
    errs = [l.strip() for l in open(e) if l.strip()] if os.path.exists(e) else []
    info["buildOk"] = os.path.exists(f"{d}/build.ok")
    info["buildErrorCount"] = len(errs); info["buildErrors"] = errs[:15]
    projects[name] = info
# resultado del sync clasico del bundle (sigue cubriendo los proyectos que no estan en fase 2)
phase1 = {}
p1 = os.path.join(os.environ.get("WORK_ROOT", ""), "phase1-result.json")
if os.path.exists(p1):
    try:
        d = json.load(open(p1))
        phase1 = {"status": d.get("status"), "commitSha": d.get("commitSha"), "message": (d.get("message") or "")[:400]}
    except Exception:
        phase1 = {"status": "unknown"}
if phase1.get("status") == "error" and status == "success":
    status = "error"; message += " Sync clasico del bundle (proyectos fuera de fase 2) termino en error: " + phase1.get("message", "")[:200]
out = {"status": status, "database": b.get("database"), "bundleId": b.get("bundleId"), "repo": os.environ["REPO_NAME"],
       "phase1": phase1,
       "synced": pushed == "true", "hadDrift": any(p.get("added") or p.get("updated") or p.get("deleted") for p in projects.values()),
       "buildOk": all(p["buildOk"] for p in projects.values()) if projects else False,
       "commitSha": sha or None, "prUrl": None, "pushedToMain": pushed == "true",
       "mode": "reconcile-from-extract-bundle", "projects": projects, "message": message, "timestamp": os.environ["TS"]}
json.dump(out, open(os.environ["RESULT_JSON_PATH"], "w"))
print(json.dumps(out, ensure_ascii=False))
PY
}

[ -d "$REPO_DIR/.git" ] || { emit error "Bundle: no existe la copia de trabajo $REPO_DIR" false ""; exit 0; }
. "$ROOT/.env"
AUTH="Authorization: Basic $(printf ':%s' "$AZDO_PAT" | base64 -w0)"

# Proyectos habilitados, en orden, con sus reglas (una linea por proyecto: db|project|args|preserve)
PLAN=$(python3 - "$BUNDLE_JSON" "$ROOT/reconcile-enabled.txt" <<'PY'
import json, sys, shlex
b = json.load(open(sys.argv[1]))
enabled = {l.strip() for l in open(sys.argv[2]) if l.strip()}
for p in sorted(b["projects"], key=lambda x: x.get("order", 0)):
    if p["projectName"] not in enabled:
        continue
    args = []
    for f in p.get("keepAsNone", []): args += ["--keep-as-none", f]
    for a in p.get("skipClrAssemblies", []): args += ["--skip-assembly", a]
    for v in p.get("preserveSqlCmdRefs", []): args += ["--sqlcmd-var", v]   # excepcion: solo este bundle
    print("|".join([p["database"], p["projectName"], " ".join(shlex.quote(x) for x in args), ",".join(p.get("preserveSqlCmdRefs", []))]))
PY
)
[ -n "$PLAN" ] || { emit error "Bundle: ningun proyecto del bundle esta en reconcile-enabled.txt" false ""; exit 0; }

# 1. working tree = origin/main (ya incluye lo que subio el sync clasico del bundle)
git -C "$REPO_DIR" -c http.extraHeader="$AUTH" fetch -q origin main 2>"$STAGE/git.err" || { emit error "Bundle: git fetch fallo: $(head -c 300 "$STAGE/git.err")" false ""; exit 0; }
git -C "$REPO_DIR" checkout -q -f -B main origin/main && git -C "$REPO_DIR" clean -q -fd -- . >/dev/null 2>&1

FAIL=""
while IFS='|' read -r DB PROJ ARGS PRESERVE; do
  P="$STAGE/p-$PROJ"; mkdir -p "$P"
  case "$PRESERVE" in *,*) FAIL="$PROJ referencia mas de una base por SQLCMD ($PRESERVE): no soportado"; break;; esac
  PROJ_DIR=$(dirname "$(find "$REPO_DIR" -name "$PROJ.sqlproj" -not -path '*/bin/*' -not -path '*/obj/*' | head -1)")
  [ -f "$PROJ_DIR/$PROJ.sqlproj" ] || { FAIL="no se encontro $PROJ.sqlproj"; break; }
  CS="Server=tcp:$SQL_SERVER,1433;Initial Catalog=$DB;User ID=$SQL_USER;Password=$SQL_PASSWORD;Encrypt=True;TrustServerCertificate=False;ApplicationIntent=ReadOnly;Connect Timeout=60"
  "$ROOT/sqlpackage/sqlpackage" /a:Extract /scs:"$CS" /tf:"$P/extract" /p:ExtractTarget=SchemaObjectType /p:CommandTimeout=1800 > "$P/extract.log" 2>&1 \
    || { FAIL="Extract de $DB fallo: $(tail -3 "$P/extract.log" | sed 's/Password=[^;]*/Password=***/g' | tr '\n' ' ' | head -c 300)"; break; }
  eval python3 "$ROOT/reconcile-from-extract.py" --extract-dir "$P/extract" --project-dir "$PROJ_DIR" --report "$P/report-dry.json" --dry-run $ARGS > "$P/reconcile-dry.log" 2>&1 \
    || { FAIL="reconcile dry-run de $PROJ fallo"; break; }
  GUARD=""
  if [ "$(python3 -c "import json;print(len(json.load(open('$P/report-dry.json'))['deleted']))")" -gt 0 ]; then
    "$ROOT/sqlpackage/sqlpackage" /a:Extract /scs:"$CS" /tf:"$P/prod.dacpac" /p:CommandTimeout=1800 > "$P/extract-dacpac.log" 2>&1 \
      || { FAIL="Extract del DACPAC de $DB fallo, no se borra nada"; break; }
    GUARD="--prod-dacpac $P/prod.dacpac"
  fi
  eval python3 "$ROOT/reconcile-from-extract.py" --extract-dir "$P/extract" --project-dir "$PROJ_DIR" --report "$P/report.json" $ARGS $GUARD > "$P/reconcile.log" 2>&1 \
    || { FAIL="reconcile de $PROJ fallo: $(tail -3 "$P/reconcile.log" | tr '\n' ' ')"; break; }
  REFD=""
  if [ -n "$PRESERVE" ]; then
    # compilar contra la base referenciada: su DACPAC de esta corrida o, si no esta en fase 2,
    # compilado desde el repo solo para validar
    REFD="$STAGE/p-$PRESERVE/build/bin/$PRESERVE.dacpac"
    if [ ! -f "$REFD" ]; then
      RD=$(dirname "$(find "$REPO_DIR" -name "$PRESERVE.sqlproj" -not -path '*/bin/*' -not -path '*/obj/*' | head -1)")
      bash "$ROOT/build-check.sh" "$RD" "$STAGE/ref-$PRESERVE" > "$STAGE/ref-$PRESERVE.out" 2>&1 || true
      REFD="$STAGE/ref-$PRESERVE/bin/$PRESERVE.dacpac"
    fi
    [ -f "$REFD" ] || { FAIL="no se pudo compilar $PRESERVE para validar $PROJ"; break; }
  fi
  REF_DACPAC="$REFD" REF_VAR="$PRESERVE" bash "$ROOT/build-check.sh" "$PROJ_DIR" "$P/build" > "$P/build.out" 2>&1 && touch "$P/build.ok"
done <<< "$PLAN"
if [ -n "$FAIL" ]; then
  git -C "$REPO_DIR" checkout -q -f -B main origin/main; git -C "$REPO_DIR" clean -q -fd -- . >/dev/null 2>&1
  emit error "Bundle: $FAIL. No se subio nada de la fase 2 (main queda como lo dejo el sync clasico)." false ""; exit 0
fi

# commit + push una sola vez
SHA=$(git -C "$REPO_DIR" rev-parse HEAD); PUSHED=true; PUSHMSG="sin cambios: main ya estaba igual a la BD"
if [ -n "$(git -C "$REPO_DIR" status --porcelain)" ]; then
  git -C "$REPO_DIR" add -A
  git -C "$REPO_DIR" -c user.name=schema-sync-bot -c user.email=repo-sync@grupomontecristo.com \
      commit -q -m "chore(schema): sync bundle $(python3 -c "import json;print(json.load(open('$BUNDLE_JSON'))['bundleId'])") from SQL MI (extract, main = prod) [$TS]"
  SHA=$(git -C "$REPO_DIR" rev-parse HEAD)
  if git -C "$REPO_DIR" -c http.extraHeader="$AUTH" push -q origin HEAD:refs/heads/main 2>"$STAGE/push.err"; then PUSHMSG="push a main OK"
  else PUSHED=false; PUSHMSG="git push a main fallo: $(head -c 300 "$STAGE/push.err" | tr '\n' ' ')"; fi
fi
ALLOK=true; for d in "$STAGE"/p-*; do [ -f "$d/build.ok" ] || ALLOK=false; done
if [ "$PUSHED" = true ] && [ "$ALLOK" = true ]; then emit success "Bundle: proyectos en fase 2 = BD de prod. $PUSHMSG. Compila OK." true "$SHA"
elif [ "$PUSHED" = true ]; then emit error "Bundle: main = BD de prod ($PUSHMSG), pero algun proyecto NO compila. Revisar projects.*.buildErrors." true "$SHA"
else emit error "Bundle: NO se pudo subir a main: $PUSHMSG" false "$SHA"; fi
exit 0
