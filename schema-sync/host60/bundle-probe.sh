#!/bin/bash
# Prueba en COPIA de la fase 2 para un proyecto del bundle core-workflow-global. No sube nada.
# Uso: bundle-probe.sh <proyecto: sqldb_core_global|sqldb_core_workflow> [<dacpac de global ya compilado>]
set -u
S=/home/soporte/schema-sync
PROJ="$1"; REFDAC="${2:-}"
REPO=project-qldb_core_workflow-sqldb_core_global
BUNDLE=$S/bundles/core-workflow-global.json
T=/tmp/bprobe/$PROJ; rm -rf "$T"; mkdir -p "$T/repo"
set -a; . "$S/.env"; set +a
SRV=gmon-prod-sqlmi-eastus2-0001.15c9ad07b4c3.database.windows.net
AUTH="Authorization: Basic $(printf ':%s' "$AZDO_PAT" | base64 -w0)"
SP=$S/sqlpackage/sqlpackage
W=$S/work/$REPO/$REPO
git -C "$W" -c http.extraHeader="$AUTH" fetch -q origin main
git -C "$W" archive origin/main | tar -x -C "$T/repo"
PD="$T/repo/databases/$PROJ"
CS="Server=tcp:$SRV,1433;Initial Catalog=$PROJ;User ID=$SQL_USER;Password=$SQL_PASSWORD;Encrypt=True;TrustServerCertificate=False;ApplicationIntent=ReadOnly;Connect Timeout=60"
echo "extract $(date +%H:%M:%S)"
"$SP" /a:Extract /scs:"$CS" /tf:"$T/extract" /p:ExtractTarget=SchemaObjectType /p:CommandTimeout=1800 > "$T/x1.log" 2>&1 || { echo EXTRACT_FALLO; tail -3 "$T/x1.log" | sed 's/Password=[^;]*/Password=***/g'; exit 1; }
"$SP" /a:Extract /scs:"$CS" /tf:"$T/prod.dacpac" /p:CommandTimeout=1800 > "$T/x2.log" 2>&1 || { echo EXTRACT_DACPAC_FALLO; exit 1; }
# reglas del bundle para este proyecto
ARGS=$(python3 - "$BUNDLE" "$PROJ" <<'PY'
import json, sys, shlex
b = json.load(open(sys.argv[1])); p = [x for x in b["projects"] if x["projectName"] == sys.argv[2]][0]
out = []
for f in p.get("keepAsNone", []): out += ["--keep-as-none", f]
for a in p.get("skipClrAssemblies", []): out += ["--skip-assembly", a]
for v in p.get("preserveSqlCmdRefs", []): out += ["--sqlcmd-var", v]
print(" ".join(shlex.quote(x) for x in out))
PY
)
echo "reglas: $ARGS"
refcount() {  # archivos y apariciones de la variable / del nombre literal en el proyecto
  python3 - "$1" <<'PY'
import os, re, sys
v = "sqldb_core_global"; files_var = n_var = files_lit = n_lit = 0; lines_trw = 0
lit = re.compile(r"\[" + v + r"\](?=\s*\.)|(?<![\w\[(@#$])" + v + r"(?=\s*\.)", re.I)
for root, _, fs in os.walk(sys.argv[1]):
    for f in fs:
        if not f.lower().endswith(".sql") or "/scripts" in root.lower(): continue
        t = open(os.path.join(root, f), encoding="utf-8-sig", errors="replace").read()
        a = t.count("[$(" + v + ")]"); b = len(lit.findall(t))
        files_var += a > 0; n_var += a; files_lit += b > 0; n_lit += b
        if f == "tra_workflow.sql": lines_trw = t.count("\n")
print(f"var: {files_var} archivos / {n_var} refs | literal: {files_lit} archivos / {n_lit} refs | tra_workflow.sql: {lines_trw} lineas")
PY
}
echo "ANTES   $(refcount "$PD")"
eval python3 "$S/reconcile-from-extract.py" --extract-dir "$T/extract" --project-dir "$PD" --report "$T/report.json" --prod-dacpac "$T/prod.dacpac" $ARGS
echo "DESPUES $(refcount "$PD")"
echo "PROD    $(refcount "$T/extract")"
echo "build $(date +%H:%M:%S)"
REF_DACPAC="$REFDAC" bash "$S/build-check.sh" "$PD" "$T/build" | tail -2
if [ -f "$T/build/bin/$PROJ.dacpac" ]; then
  "$SP" /a:DeployReport /sf:"$T/build/bin/$PROJ.dacpac" /tf:"$T/prod.dacpac" /tdn:"$PROJ" /op:"$T/deployreport.xml" \
    /p:DropObjectsNotInSource=True /p:ExcludeObjectTypes="Users;Logins;RoleMembership;Permissions;DatabaseRoles;ApplicationRoles;DatabaseScopedCredentials;MasterKeys" \
    /p:IgnorePermissions=True /p:IgnoreRoleMembership=True /p:AllowIncompatiblePlatform=True /v:sqldb_core_global=sqldb_core_global > "$T/dr.log" 2>&1
  [ -f "$T/deployreport.xml" ] || { echo REPORT_FALLO; tail -3 "$T/dr.log"; }
fi
python3 - "$T" <<'PY'
import json, re, sys, os
T = sys.argv[1]
r = json.load(open(f"{T}/report.json"))
print("reconcile:", {k: len(r[k]) for k in ("added", "updated", "deleted")}, "unchanged", r["unchanged"],
      "| None actualizados:", r.get("keptAsNoneUpdated"), "| excluidos CLR:", [e for e in r["excluded"] if e.lower().startswith("assembl")])
print("deleted:", r["deleted"][:10]); print("added:", r["added"][:10])
print("refs con variable escritas:", r.get("sqlcmdVarRefsWritten"), "| conservados (existen en prod):", r.get("keptExistsInProdUnreadable"))
print("schemas None redirigidos al build:", r.get("keepAsNoneRedirectedToBuild"))
print("updated (muestra):", r["updated"][:12])
e = f"{T}/build/errors.txt"
if os.path.exists(e):
    L = [l.strip() for l in open(e) if l.strip()]
    print("errores build:", len(L)); [print("  ", l[:200]) for l in L[:8]]
v = f"{T}/build/validation.json"
if os.path.exists(v): print("validacion:", json.load(open(v)))
d = f"{T}/deployreport.xml"
if os.path.exists(d):
    x = open(d).read(); items = []
    for name, body in re.findall(r'<Operation Name="(\w+)">(.*?)</Operation>', x, re.S):
        items += [f"{name} {t} {v}" for v, t in re.findall(r'<Item Value="([^"]+)" Type="(\w+)"', body)]
    print("diferencias vs prod:", len(items)); [print("  ", i) for i in items[:25]]
PY
echo FIN
