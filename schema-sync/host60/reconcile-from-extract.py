#!/usr/bin/env python3
"""Reconcilia un proyecto SSDT contra un Extract de prod (sqlpackage /p:ExtractTarget=SchemaObjectType).

La BD manda: el proyecto queda con los mismos objetos que la BD.
  * agrega los objetos que estan en la BD y faltan en el proyecto
  * sobrescribe los que difieren (comparacion normalizada: BOM, fin de linea, espacios, GO final)
  * borra del proyecto los objetos que ya no existen en la BD (quedan en el historial de git)
  * actualiza los <Build Include> del .sqlproj

No se conecta a ninguna BD: solo lee el directorio del Extract y escribe archivos del proyecto.
Fuera de alcance (politica vigente del sync): usuarios, roles, membresias y permisos (Security/*
que no sea CREATE SCHEMA), scripts de datos (scripts/), Properties/, bin/, obj/ y todo lo que no
sea <Build Include> en el .sqlproj.
"""
import argparse, json, os, re, sys
from pathlib import Path

BOM = "\ufeff"
SKIP_TOP = {"scripts", "properties", "bin", "obj"}
# Nombres de carpeta del Extract -> convencion SSDT (BySchemaAndSchemaType). Se usa solo si el
# proyecto todavia no tiene una carpeta equivalente (la del proyecto tiene prioridad).
KNOWN_MAP = {
    "storedprocedures": "Stored Procedures",
    "userdefinedtypes": "User Defined Types",
    "userdefineddatatypes": "User Defined Types",
    "userdefinedtabletypes": "User Defined Types",
    "xmlschemacollections": "XML Schema Collections",
    "databasetriggers": "Database Triggers",
}
SCHEMA_DDL = re.compile(r"^\s*CREATE\s+SCHEMA\b", re.IGNORECASE)
GO_LINE = re.compile(r"^\s*GO\s*;?\s*$", re.IGNORECASE)


def eol_of(text):
    return "\r\n" if "\r\n" in text else "\n"


def clean(text, keep_eol=False):
    """Texto del Extract tal cual (cuerpo intacto), sin BOM y sin GO/lineas en blanco al
    final ni al principio. Con keep_eol conserva el fin de linea original del Extract: en
    modulos (SP, funciones, vistas, triggers) el CRLF es parte del texto que guarda la BD
    y cambiarlo hace que DacFx/Schema Compare los marque como modificados."""
    eol = eol_of(text)
    text = text.lstrip(BOM).replace("\r\n", "\n").replace("\r", "\n")
    lines = text.split("\n")
    while lines and (not lines[-1].strip() or GO_LINE.match(lines[-1])):
        lines.pop()
    while lines and not lines[0].strip():
        lines.pop(0)
    return (eol if keep_eol else "\n").join(lines)


_LEADING_BLANK = re.compile(r"\A(?:[ \t]*\r?\n)+")
_TRAILING_GO = re.compile(r"(?:\r?\n|\A)[ \t]*(?:GO[ \t]*;?[ \t]*)?\Z", re.IGNORECASE)


def exact(text):
    """Texto exacto del objeto: sin BOM, sin lineas en blanco al principio y sin GO/lineas en
    blanco al final. NO toca nada del medio: los fines de linea quedan tal cual (pueden ser
    mixtos en la BD, ej. CRLF en todo el SP salvo el final en LF)."""
    t = _LEADING_BLANK.sub("", text.lstrip(BOM))
    while True:
        n = _TRAILING_GO.sub("", t)
        if n == t:
            return t
        t = n


def last_eol(text):
    i = text.rfind("\n")
    return "\r\n" if i > 0 and text[i - 1] == "\r" else "\n"


def first_block(text):
    """Primer bloque (hasta el primer GO): en Security/<schema>.sql es el CREATE SCHEMA."""
    return re.split(r"(?im)^\s*GO\s*;?\s*$", clean(text), maxsplit=1)[0]


def is_schema_file(rel):
    parts = rel.replace("\\", "/").split("/")
    return len(parts) == 2 and parts[0].lower() == "security"


def norm(text):
    """Comparacion: ignora BOM, fin de linea, blancos y el orden de los bloques separados por GO
    (el Extract ordena indices/constraints distinto al proyecto, sin diferencia de esquema)."""
    blocks = []
    for blk in re.split(r"(?im)^\s*GO\s*;?\s*$", clean(text)):
        lines = [l.rstrip() for l in blk.split("\n") if l.strip()]
        if lines:
            blocks.append("\n".join(lines))
    return "\n--GO--\n".join(sorted(blocks))


def read(p):
    return p.read_text(encoding="utf-8-sig", errors="replace")


def read_raw(p):
    """Texto sin traducir fines de linea (read_text con newline='' conserva el CRLF)."""
    with open(p, encoding="utf-8-sig", errors="replace", newline="") as f:
        return f.read()


def key(rel):
    """Clave de comparacion: sin distinguir mayusculas y sin espacios SOLO en las carpetas
    ('Stored Procedures' == 'StoredProcedures'). El nombre del archivo se respeta tal cual:
    'presup uesto.sql' y 'presupuesto.sql' son archivos distintos."""
    parts = rel.replace("\\", "/").lower().split("/")
    return "/".join([p.replace(" ", "") for p in parts[:-1]] + [parts[-1]])


def in_scope(rel, text):
    parts = rel.replace("\\", "/").split("/")
    if parts[0].lower() in SKIP_TOP:
        return False
    # scripts de migracion/datos del equipo (<schema>/Scripts/...): no son objetos de la BD
    if any(p.lower() == "scripts" for p in parts[:-1]):
        return False
    if parts[0].lower() == "security":
        return bool(SCHEMA_DDL.search(text.lstrip(BOM)))
    return True


def load_sqlproj(path):
    content = read_raw(path)
    builds = re.findall(r'<Build\s+Include="([^"]+)"', content)
    return content, builds


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--extract-dir", required=True)
    ap.add_argument("--project-dir", required=True, help="carpeta que contiene el .sqlproj")
    ap.add_argument("--report", required=True)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--keep-as-none", action="append", default=[],
                    help="archivo (ruta del proyecto) que debe seguir como <None>: se actualiza su texto pero no entra al build")
    ap.add_argument("--skip-assembly", action="append", default=[],
                    help="ensamblado que el proyecto maneja como <Reference> a un .dll: no se agrega su CREATE ASSEMBLY")
    ap.add_argument("--prod-dacpac", default="",
                    help="DACPAC extraido de prod: antes de borrar un objeto se confirma que no exista en prod "
                         "(el Extract a archivos omite sin avisar objetos cuya definicion no se puede leer)")
    ap.add_argument("--sqlcmd-var", action="append", default=[],
                    help="SOLO bundles (preserveSqlCmdRefs): base referenciada con variable SQLCMD. Al comparar, "
                         "[$(var)] y el nombre literal valen lo mismo; al escribir se usa siempre [$(var)]")
    a = ap.parse_args()
    # Variables SQLCMD (solo bundles con preserveSqlCmdRefs). Prod tiene el nombre literal de la
    # base; el repo usa la variable. Reglas:
    #   * comparar: $(var) y el nombre literal valen lo mismo (se respeta si lleva corchetes o no)
    #   * escribir, en codigo y comentarios: [var].x -> [$(var)].x   y   var.x -> $(var).x
    #     (misma forma que prod, asi al resolver la variable el texto queda identico a prod)
    #   * dentro de strings ('...') nunca se convierte: si el string ya existe en el repo se usa
    #     la version del repo (con o sin variable); si es nuevo queda igual que en prod.
    var_names = list(a.sqlcmd_var)
    var_hits = {v: 0 for v in var_names}
    var_stats = {"stringsFromRepo": 0, "stringsNewLiteral": []}
    lit_pats = {v: (re.compile(r"\[" + re.escape(v) + r"\](?=\s*\.)", re.I),
                    re.compile(r"(?<![\w\[(@#$])" + re.escape(v) + r"(?=\s*\.)", re.I)) for v in var_names}

    canon_pats = {v: re.compile(r"\[\$\(" + re.escape(v) + r"\)\]|\$\(" + re.escape(v) + r"\)"
                                r"|\[" + re.escape(v) + r"\](?=\s*\.)|(?<![\w\[(@#$])" + re.escape(v) + r"(?=\s*\.)", re.I)
                  for v in var_names}

    def canon(t):
        """Para comparar: [$(var)], $(var), [var] y var (seguidos de '.') valen lo mismo."""
        for v, p in canon_pats.items():
            t = p.sub("\x00" + v + "\x00", t)
        return t

    def sql_segments(t):
        """Parte el texto en ('code'|'str', texto). Comentarios e [identificadores] quedan en code."""
        out, i, n, start = [], 0, len(t), 0
        while i < n:
            c = t[i]
            if c == "'":
                j = i + 1
                while j < n:
                    if t[j] == "'":
                        if j + 1 < n and t[j + 1] == "'":
                            j += 2; continue
                        break
                    j += 1
                out.append(("code", t[start:i])); out.append(("str", t[i:j + 1]))
                i = j + 1; start = i; continue
            if t.startswith("--", i):
                j = t.find("\n", i); i = n if j < 0 else j; continue
            if t.startswith("/*", i):
                depth, j = 1, i + 2
                while j < n and depth:
                    if t.startswith("/*", j): depth += 1; j += 2
                    elif t.startswith("*/", j): depth -= 1; j += 2
                    else: j += 1
                i = j; continue
            if c == "[":
                j = t.find("]", i + 1)
                while j != -1 and j + 1 < n and t[j + 1] == "]":
                    j = t.find("]", j + 2)
                i = n if j < 0 else j + 1; continue
            i += 1
        out.append(("code", t[start:]))
        return out

    def render(prod_text, repo_text, rel_for_report):
        """Texto a escribir: el de prod con la variable en el codigo y los strings del repo."""
        if not var_names:
            return prod_text
        repo_strings = {}
        if repo_text:
            for kind, s in sql_segments(repo_text):
                if kind == "str":
                    repo_strings.setdefault(canon(s), s)
        out = []
        for kind, s in sql_segments(prod_text):
            if kind == "str":
                r = repo_strings.get(canon(s))
                if r is not None:
                    if r != s and "$(" in r: var_stats["stringsFromRepo"] += 1
                    out.append(r)
                else:
                    if any(p[1].search(s) or p[0].search(s) for p in lit_pats.values()):
                        var_stats["stringsNewLiteral"].append(rel_for_report)
                    out.append(s)
            else:
                # SSDT solo acepta la referencia con corchetes: [$(var)].schema.objeto
                for v, (brk, bare) in lit_pats.items():
                    s = brk.sub(f"[$({v})]", s)
                    s = bare.sub(f"[$({v})]", s)
                out.append(s)
        return "".join(out)

    def count_var_writes(t):
        for v in var_names:
            var_hits[v] += len(re.findall(r"\$\(" + re.escape(v) + r"\)", t, re.I))
    prod_names = None
    if a.prod_dacpac:
        import zipfile
        model_xml = zipfile.ZipFile(a.prod_dacpac).read("model.xml").decode("utf-8", "replace")
        prod_names = {n.lower() for n in re.findall(r'<Element Type="\w+" Name="([^"]+)"', model_xml)}
    keep_none = {key(r) for r in a.keep_as_none}
    skip_asm = {n.lower() for n in a.skip_assembly}
    ASM_RE = re.compile(r"^\s*CREATE\s+ASSEMBLY\s+\[([^\]]+)\]", re.I | re.M)

    xdir, pdir = Path(a.extract_dir), Path(a.project_dir)
    sqlproj = next((p for p in pdir.glob("*.sqlproj")), None)
    if not sqlproj:
        print("ERROR: sin .sqlproj en", pdir); sys.exit(2)
    content, builds = load_sqlproj(sqlproj)
    build_keys = {key(b): b for b in builds}

    # Objetos del proyecto en alcance (solo <Build Include> existentes en disco)
    proj = {}
    for b in builds:
        f = pdir / b.replace("\\", "/")
        if f.is_file() and f.suffix.lower() == ".sql":
            rel = b.replace("\\", "/")
            if in_scope(rel, read(f)):
                proj[key(rel)] = rel

    # Mapa de carpetas existentes del proyecto (sin espacios, minusculas) -> nombre real
    proj_dirs = {}
    for d in pdir.rglob("*"):
        if d.is_dir():
            proj_dirs.setdefault(d.name.lower().replace(" ", ""), d.name)

    def to_ssdt(rel):
        parts = rel.split("/")
        out = []
        for i, part in enumerate(parts[:-1]):
            k = part.lower().replace(" ", "")
            out.append(proj_dirs.get(k) or (KNOWN_MAP.get(k) if i > 0 else None) or part)
        out.append(parts[-1])
        return "/".join(out)

    # Objetos de la BD (Extract) en alcance
    prod, excluded, renamed = {}, [], {}
    for f in sorted(xdir.rglob("*.sql")):
        rel_x = str(f.relative_to(xdir)).replace("\\", "/")
        text = read_raw(f)
        if not in_scope(rel_x, text):
            excluded.append(rel_x); continue
        m_asm = ASM_RE.search(text.lstrip(BOM))
        if m_asm and m_asm.group(1).lower() in skip_asm:
            excluded.append(rel_x); continue
        rel = to_ssdt(rel_x)
        if rel != rel_x:
            renamed[rel_x] = rel
        prod[key(rel)] = (rel, text)

    # Objetos que el Extract ubica en otra carpeta que el proyecto (ej. triggers en la raiz):
    # si el nombre de archivo existe UNA sola vez en el proyecto y no tiene par en el Extract,
    # se usa la ubicacion del proyecto en vez de moverlo.
    by_name = {}
    for pk, prel in proj.items():
        by_name.setdefault(pk.rsplit("/", 1)[-1], []).append(pk)
    moved = {}
    for k in list(prod):
        if k in proj:
            continue
        top = k.split("/")[0] if "/" in k else None   # None = archivo en la raiz del Extract
        cands = [c for c in by_name.get(k.rsplit("/", 1)[-1], [])
                 if c not in prod and (top is None or c.split("/")[0] == top)]
        if len(cands) == 1:
            rel, text = prod.pop(k)
            prod[cands[0]] = (proj[cands[0]], text)
            moved[rel] = proj[cands[0]]

    # keep-as-none + schema duplicado: si prod define un schema que el proyecto ya tiene en el BUILD
    # con otro nombre de archivo (ej. Security/external_1.sql en build y Security/external.sql como
    # <None>), se actualiza el archivo del build y la copia <None> no se toca. Solo aplica a
    # archivos --keep-as-none (bundles); el resto de las bases no pasa por aca.
    SCHEMA_NAME = re.compile(r"^\s*CREATE\s+SCHEMA\s+\[([^\]]+)\]", re.I | re.M)
    redirected = {}
    for k in list(prod):
        if k not in keep_none:
            continue
        rel, text = prod[k]
        m = SCHEMA_NAME.search(text.lstrip(BOM))
        if not m:
            continue
        for pk, prel in proj.items():
            if pk in prod or not is_schema_file(prel):
                continue
            mm = SCHEMA_NAME.search(read(pdir / prel).lstrip(BOM))
            if mm and mm.group(1).lower() == m.group(1).lower():
                prod.pop(k)
                prod[pk] = (prel, text)
                redirected[rel] = prel
                break

    added, updated, unchanged, deleted = [], [], [], []
    none_updated, none_unchanged = [], []
    for k in list(prod):
        if k in keep_none:
            # Sigue como <None>: se actualiza el texto si cambio, sin tocar el .sqlproj
            rel, text = prod.pop(k)
            dest_rel = next(r for r in a.keep_as_none if key(r) == k).replace("\\", "/")
            dest = pdir / dest_rel
            cur = read_raw(dest) if dest.is_file() else None
            if cur is not None and exact(canon(cur)) == exact(canon(text)):
                none_unchanged.append(dest_rel); continue
            text = render(text, cur, dest_rel)
            none_updated.append(dest_rel)
            if not a.dry_run:
                count_var_writes(text)
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_text(BOM + exact(text) + last_eol(exact(text)), encoding="utf-8", newline="")
    for k, (rel, text) in prod.items():
        dest_rel = proj.get(k, rel)
        dest = pdir / dest_rel
        schema_file = k in proj and is_schema_file(dest_rel)
        if k not in proj:
            added.append(dest_rel)
        elif schema_file:
            # Security/<schema>.sql: solo manda el CREATE SCHEMA; GRANTs del repo se conservan
            cur = read(dest)
            if norm(first_block(cur)) == norm(first_block(text)):
                unchanged.append(dest_rel); continue
            updated.append(dest_rel)
            rest = re.split(r"(?im)^\s*GO\s*;?\s*$", clean(cur), maxsplit=1)
            text = first_block(text) + ("\nGO" + rest[1] if len(rest) > 1 else "")
        elif exact(canon(read_raw(dest))) != exact(canon(text)):
            updated.append(dest_rel)
        else:
            unchanged.append(dest_rel); continue
        if not schema_file:
            # sin --sqlcmd-var render() devuelve el texto de prod sin tocar
            text = render(text, read_raw(dest) if dest.is_file() else None, dest_rel)
        if not a.dry_run:
            count_var_writes(text)
            if schema_file:
                body = clean(text, keep_eol=True) + eol_of(text)
            else:
                body = exact(text) + last_eol(exact(text))
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text(BOM + body, encoding="utf-8", newline="")
    kept_unreadable = []
    for k, rel in proj.items():
        if k not in prod:
            if prod_names is not None:
                parts = rel.split("/")
                stem = parts[-1][:-4] if parts[-1].lower().endswith(".sql") else parts[-1]
                obj = f"[{stem}]" if parts[0].lower() == "security" or len(parts) == 1 else f"[{parts[0]}].[{stem}]"
                if obj.lower() in prod_names:
                    # existe en prod pero el Extract no pudo leer su definicion: no se borra
                    kept_unreadable.append(rel); continue
            deleted.append(rel)
            if not a.dry_run:
                (pdir / rel).unlink()

    # .sqlproj: quitar Build duplicados (mismo archivo dos veces -> SQL71508 en VS)
    new_content = content
    seen, dups = set(), []
    for m in list(re.finditer(r'[ \t]*<Build\s+Include="([^"]+)"\s*/>\r?\n', content)):
        k = key(m.group(1))
        if k in seen:
            dups.append(m.group(0))
        seen.add(k)
    for d in dups:
        i = new_content.rfind(d)
        new_content = new_content[:i] + new_content[i + len(d):]
    # .sqlproj: quitar Build de borrados, agregar Build de nuevos
    for rel in deleted:
        inc = build_keys.get(key(rel))
        if inc:
            new_content = re.sub(r'[ \t]*<Build\s+Include="' + re.escape(inc) + r'"\s*/>\r?\n?', "", new_content)
    to_add = [r.replace("/", "\\") for r in added if key(r) not in build_keys]
    if to_add:
        m = re.search(r'([ \t]*)<Build\s+Include="[^"]+"\s*/>', new_content)
        indent = m.group(1) if m else "    "
        nl = "\r\n" if "\r\n" in new_content else "\n"
        block = "".join(f'{indent}<Build Include="{r}" />{nl}' for r in to_add)
        if m:
            last = list(re.finditer(r'[ \t]*<Build\s+Include="[^"]+"\s*/>\r?\n', new_content))[-1]
            new_content = new_content[:last.end()] + block + new_content[last.end():]
        else:
            pos = new_content.rfind("</Project>")
            new_content = new_content[:pos] + f"  <ItemGroup>{nl}{block}  </ItemGroup>{nl}" + new_content[pos:]
    if not a.dry_run and new_content != content:
        had_bom = sqlproj.read_bytes().startswith(b"\xef\xbb\xbf")
        with open(sqlproj, "w", encoding="utf-8-sig" if had_bom else "utf-8", newline="") as f:
            f.write(new_content)

    rep = {"dryRun": a.dry_run, "added": sorted(added), "updated": sorted(updated),
           "deleted": sorted(deleted), "unchanged": len(unchanged), "excluded": sorted(excluded),
           "folderMap": renamed, "keptProjectLocation": moved, "sqlprojBuildAdded": to_add,
           "keptAsNoneUpdated": none_updated, "keptAsNoneUnchanged": none_unchanged,
           "keptExistsInProdUnreadable": kept_unreadable, "prodDacpacChecked": prod_names is not None,
           "sqlcmdVars": a.sqlcmd_var, "sqlcmdVarRefsWritten": var_hits,
           "sqlcmdStringsFromRepo": var_stats["stringsFromRepo"],
           "sqlcmdStringsNewLiteral": sorted(set(var_stats["stringsNewLiteral"])),
           "keepAsNoneRedirectedToBuild": redirected,
           "sqlprojDuplicatesRemoved": [re.search(r'Include="([^"]+)"', d).group(1) for d in dups]}
    json.dump(rep, open(a.report, "w"), indent=1, ensure_ascii=False)
    print(f"added={len(added)} updated={len(updated)} deleted={len(deleted)} unchanged={len(unchanged)} "
          f"excluded={len(excluded)} renamedFolders={len(renamed)}")


if __name__ == "__main__":
    main()
