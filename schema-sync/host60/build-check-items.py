#!/usr/bin/env python3
"""Genera la lista de <Build Include> para el wrapper de build-check.sh.

Solo para VALIDAR en Linux; nunca toca el repo:
  * Excluye ensamblados CLR (CREATE ASSEMBLY) y modulos que los usan (EXTERNAL NAME):
    el SDK Microsoft.Build.Sql en Linux los marca como corruptos (SQL70557).
  * Agrega stubs para objetos que el sync deja fuera a proposito y que otros objetos
    referencian: dueños de schema (AUTHORIZATION [usuario]) y credenciales con alcance de
    base de datos (CREDENTIAL = [x]). Los stubs viven solo en el directorio del wrapper.
Salida: imprime una ruta por linea (archivos a compilar) y escribe <out>/validation.json.
"""
import json, os, re, sys
from pathlib import Path

proj, sqlproj, wrapdir, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4])
BOM = "\ufeff"
text = sqlproj.read_text(encoding="utf-8-sig", errors="replace")
builds = [b.replace("\\", "/") for b in re.findall(r'<Build\s+Include="([^"]+)"', text)]

ASSEMBLY = re.compile(r"^\s*CREATE\s+ASSEMBLY\b", re.I | re.M)
EXTNAME = re.compile(r"\bEXTERNAL\s+NAME\s+\[", re.I)
OWNER = re.compile(r"\bAUTHORIZATION\s+\[([^\]]+)\]", re.I)
CRED_REF = re.compile(r"\bCREDENTIAL\s*=\s*\[([^\]]+)\]", re.I)
USER_DEF = re.compile(r"^\s*CREATE\s+USER\s+\[([^\]]+)\]", re.I | re.M)
ROLE_DEF = re.compile(r"^\s*CREATE\s+(?:APPLICATION\s+)?ROLE\s+\[([^\]]+)\]", re.I | re.M)
CRED_DEF = re.compile(r"^\s*CREATE\s+DATABASE\s+SCOPED\s+CREDENTIAL\s+\[([^\]]+)\]", re.I | re.M)
BUILTIN = {"dbo", "public", "sys", "guest", "information_schema"}

keep, skipped = [], []
owners, users, roles, creds_ref, creds_def = set(), set(), set(), set(), set()
for b in builds:
    f = proj / b
    if not f.is_file():
        continue
    t = f.read_text(encoding="utf-8-sig", errors="replace")
    if ASSEMBLY.search(t) or EXTNAME.search(t):
        skipped.append(b); continue
    keep.append(str(f))
    owners |= {o.lower() for o in OWNER.findall(t)}
    users |= {u.lower() for u in USER_DEF.findall(t)}
    roles |= {r.lower() for r in ROLE_DEF.findall(t)}
    creds_ref |= set(CRED_REF.findall(t))
    creds_def |= {c.lower() for c in CRED_DEF.findall(t)}

stub_users = sorted(o for o in owners if o not in BUILTIN and o not in users and o not in roles
                    and not o.startswith("db_"))
stub_creds = sorted({c for c in creds_ref if c.lower() not in creds_def})

# Si el proyecto ya tiene el archivo que define el objeto (fuera del build, ej. <None>), se usa
# ese archivo tal cual para validar: asi la definicion coincide con prod y DacFx no recrea los
# objetos que dependen de el (ej. External Data Sources por la IDENTITY de la credencial).
existing, has_master_key = [], False
in_build = {str(proj / b) for b in builds}
for f in proj.rglob("*.sql"):
    if str(f) in in_build or any(p.lower() in ("bin", "obj") for p in f.parts):
        continue
    t = f.read_text(encoding="utf-8-sig", errors="replace")
    hit = False
    for c in list(stub_creds):
        if re.search(r"^\s*CREATE\s+DATABASE\s+SCOPED\s+CREDENTIAL\s+\[" + re.escape(c) + r"\]", t, re.I | re.M):
            stub_creds.remove(c); hit = True
    for u in list(stub_users):
        if re.search(r"^\s*CREATE\s+USER\s+\[" + re.escape(u) + r"\]", t, re.I | re.M):
            stub_users.remove(u); hit = True
    if re.search(r"^\s*CREATE\s+MASTER\s+KEY\b", t, re.I | re.M):
        has_master_key = True
    if hit:
        existing.append(str(f))
stubs = list(existing)
if stub_users:
    p = wrapdir / "_validation_stub_users.sql"
    p.write_text("".join(f"CREATE USER [{u}] WITHOUT LOGIN;\nGO\n" for u in stub_users), encoding="utf-8")
    stubs.append(str(p))
if stub_creds or (existing and creds_ref and not has_master_key):
    p = wrapdir / "_validation_stub_credentials.sql"
    p.write_text("CREATE MASTER KEY;\nGO\n" + "".join(
        f"CREATE DATABASE SCOPED CREDENTIAL [{c}] WITH IDENTITY = N'validation-stub';\nGO\n" for c in stub_creds),
        encoding="utf-8")
    stubs.append(str(p))

json.dump({"skippedClr": skipped, "stubUsers": stub_users, "stubCredentials": stub_creds,
           "fromProjectOutsideBuild": [os.path.relpath(e, proj) for e in existing]},
          open(out / "validation.json", "w"), indent=1)
print("\n".join(keep + stubs))
