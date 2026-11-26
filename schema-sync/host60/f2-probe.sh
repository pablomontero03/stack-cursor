#!/bin/bash
# Prueba en COPIA de la fase 2 para una lista de bases. No sube nada ni toca work/ (solo lee su .git).
# Contra la BD solo hace Extract con ApplicationIntent=ReadOnly.
# Uso: f2-probe.sh <lista>   (lineas: "<flujo> <database> <repoName> <projectName>")
# Salida: /tmp/f2probe/<db>/summary.json y una linea por base en /tmp/f2probe/summary.jsonl
set -u
S=/home/soporte/schema-sync
OUTROOT=/tmp/f2probe
mkdir -p "$OUTROOT"
set -a; . "$S/.env"; set +a
SRV="${SQL_SERVER:-gmon-prod-sqlmi-eastus2-0001.15c9ad07b4c3.database.windows.net}"
AUTH="Authorization: Basic $(printf ':%s' "$AZDO_PAT" | base64 -w0)"
SP="$S/sqlpackage/sqlpackage"
while read -r FLOW DB REPO PROJ; do
  [ -n "${DB:-}" ] || continue
  T="$OUTROOT/$DB"; rm -rf "$T"; mkdir -p "$T/repo"
  START=$(date +%s)
  st="ok"; note=""
  W="$S/work/$REPO/$REPO"
  if [ ! -d "$W/.git" ]; then st="sin_copia_trabajo"; else
    git -C "$W" -c http.extraHeader="$AUTH" fetch -q origin main 2>"$T/git.err" || { st="git_fetch_fallo"; note=$(head -c 200 "$T/git.err"); }
  fi
  if [ "$st" = ok ]; then
    git -C "$W" archive origin/main | tar -x -C "$T/repo"
    PD=$(dirname "$(find "$T/repo" -name "$PROJ.sqlproj" -not -path '*/bin/*' | head -1)")
    [ -f "$PD/$PROJ.sqlproj" ] || { st="sin_sqlproj"; }
  fi
  if [ "$st" = ok ]; then
    CS="Server=tcp:$SRV,1433;Initial Catalog=$DB;User ID=$SQL_USER;Password=$SQL_PASSWORD;Encrypt=True;TrustServerCertificate=False;ApplicationIntent=ReadOnly;Connect Timeout=60"
    "$SP" /a:Extract /scs:"$CS" /tf:"$T/extract" /p:ExtractTarget=SchemaObjectType /p:CommandTimeout=1800 > "$T/x1.log" 2>&1 || { st="extract_fallo"; note=$(tail -2 "$T/x1.log" | sed 's/Password=[^;]*/Password=***/g' | tr '\n' ' ' | head -c 300); }
  fi
  if [ "$st" = ok ]; then
    "$SP" /a:Extract /scs:"$CS" /tf:"$T/prod.dacpac" /p:CommandTimeout=1800 > "$T/x2.log" 2>&1 || { st="extract_dacpac_fallo"; }
  fi
  if [ "$st" = ok ]; then
    python3 "$S/reconcile-from-extract.py" --extract-dir "$T/extract" --project-dir "$PD" --report "$T/report.json" > "$T/rec.log" 2>&1 || { st="reconcile_fallo"; note=$(tail -2 "$T/rec.log" | tr '\n' ' '); }
  fi
  BUILD=""; NERR=""; DIFFS=""
  if [ "$st" = ok ]; then
    if bash "$S/build-check.sh" "$PD" "$T/build" > "$T/build.out" 2>&1; then BUILD=true; else BUILD=false; fi
    NERR=$(wc -l < "$T/build/errors.txt" 2>/dev/null || echo 0)
    if [ "$BUILD" = true ]; then
      "$SP" /a:DeployReport /sf:"$T/build/bin/$PROJ.dacpac" /tf:"$T/prod.dacpac" /tdn:"$PROJ" /op:"$T/deployreport.xml" \
        /p:DropObjectsNotInSource=True /p:ExcludeObjectTypes="Users;Logins;RoleMembership;Permissions;DatabaseRoles;ApplicationRoles;DatabaseScopedCredentials;MasterKeys" \
        /p:IgnorePermissions=True /p:IgnoreRoleMembership=True /p:IgnoreUserSettingsObjects=True /p:AllowIncompatiblePlatform=True > "$T/dr.log" 2>&1 || true
      if [ -f "$T/deployreport.xml" ]; then DIFFS=$(grep -o '<Item Value=' "$T/deployreport.xml" | wc -l); else DIFFS=REPORT_FALLO; fi
    fi
  fi
  python3 - "$T" "$FLOW" "$DB" "$st" "$note" "$BUILD" "$NERR" "$DIFFS" "$(( $(date +%s) - START ))" <<'PY' >> "$OUTROOT/summary.jsonl"
import json, os, sys, re
T, flow, db, st, note, build, nerr, diffs, secs = sys.argv[1:10]
r = {}
p = os.path.join(T, "report.json")
if os.path.exists(p):
    rep = json.load(open(p))
    r = {k: len(rep[k]) for k in ("added", "updated", "deleted")}
    r["unchanged"] = rep["unchanged"]
    r["deletedSample"] = rep["deleted"][:8]
    r["dupsRemoved"] = rep.get("sqlprojDuplicatesRemoved", [])
diffitems = []
d = os.path.join(T, "deployreport.xml")
if os.path.exists(d):
    x = open(d).read()
    for name, body in re.findall(r'<Operation Name="(\w+)">(.*?)</Operation>', x, re.S):
        for v, t in re.findall(r'<Item Value="([^"]+)" Type="(\w+)"', body):
            diffitems.append(f"{name} {t} {v}")
out = {"flow": flow, "db": db, "status": st, "note": note, "build": build, "buildErrors": nerr,
       "diffsVsProd": diffs, "diffSample": diffitems[:10], "secs": int(secs), **r}
json.dump(out, open(os.path.join(T, "summary.json"), "w"))
print(json.dumps(out, ensure_ascii=False))
PY
  rm -rf "$T/repo" "$T/build/wrap" "$T/build/bin" 2>/dev/null
done < "$1"
echo FIN >> "$OUTROOT/summary.jsonl.done"
