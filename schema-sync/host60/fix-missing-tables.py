#!/usr/bin/env python3
"""
fix-missing-tables.py v2 — Parche universal para hueco DacFx en SchemaSyncTool.

Qué hace:
  1. Lee result.json y extrae tablas faltantes reportadas por el audit.
  2. Parsea model.xml del DACPAC: columnas, PKs y FKs de cada tabla faltante.
  3. Genera el CREATE TABLE + ALTER TABLE FK/PK (formato SSDT inline).
  4. Escribe los .sql y actualiza el .sqlproj.
  5. También aplica FKs faltantes a tablas que ya EXISTEN en el proyecto
     (cuando el error reporta solo "Change ForeignKeyConstraint").
  6. (Opción --drop-removed) Elimina del proyecto .sql de objetos que ya no
     están en la BD (tablas/SPs/vistas que el DACPAC no incluye).
"""
import argparse, json, os, re, sys, zipfile
from pathlib import Path

SQL_TYPES_WITH_LEN = {"nvarchar","varchar","char","nchar","varbinary","binary"}
SQL_TYPES_WITH_PS  = {"decimal","numeric"}
SQL_TYPES_WITH_P   = {"float","real"}


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--dacpac",       required=True)
    p.add_argument("--project-dir",  required=True)
    p.add_argument("--result-json",  required=True)
    p.add_argument("--drop-removed", action="store_true",
                   help="Remove .sql files for objects no longer in the BD")
    p.add_argument("--dry-run",      action="store_true")
    return p.parse_args()


def extract_missing_tables(result):
    msg = result.get("message","") or ""
    pat = re.compile(
        r"Falta tabla\s+(\w+)\.(\w+)\s*[\u2192\-\u2013>]+\s*([\w/]+\.sql)",
        re.UNICODE)
    return [{"schema":m.group(1),"table":m.group(2),"rel_path":m.group(3)}
            for m in pat.finditer(msg)]


def balanced_element(xml, start):
    depth=0; i=start; n=len(xml)
    while i<n:
        lt=xml.find('<',i)
        if lt<0: break
        if xml[lt:lt+2]=='</':
            gt=xml.find('>',lt); depth-=1
            if depth==0: return xml[start:gt+1]
            i=gt+1 if gt>=0 else n
        elif xml[lt:lt+4] in ('<!--','<!['):
            gt=xml.find('>',lt); i=gt+1 if gt>=0 else n
        else:
            gt=xml.find('>',lt)
            if gt<0: break
            if xml[gt-1]!='/': depth+=1
            i=gt+1
    return xml[start:]


def parse_type(ts_xml):
    m=re.search(r'<References[^>]*\s+Name="\[([^\]]+)\]"',ts_xml)
    if not m: return "nvarchar(max)"
    t=m.group(1).lower()
    lm=re.search(r'<Property Name="Length"\s+Value="([^"]+)"',ts_xml)
    pm=re.search(r'<Property Name="Precision"\s+Value="([^"]+)"',ts_xml)
    sm=re.search(r'<Property Name="Scale"\s+Value="([^"]+)"',ts_xml)
    im=re.search(r'<Property Name="IsMax"\s+Value="[Tt]rue"',ts_xml)
    if im: return f"{t}(max)"
    if t in SQL_TYPES_WITH_LEN and lm: return f"{t}({lm.group(1)})"
    if t in SQL_TYPES_WITH_PS and pm and sm: return f"{t}({pm.group(1)},{sm.group(1)})"
    if t in SQL_TYPES_WITH_P and pm: return f"{t}({pm.group(1)})"
    return t


def parse_col(col_xml):
    nm=re.search(r'Name="\[[^\]]+\]\.\[[^\]]+\]\.\[([^\]]+)\]"',col_xml)
    if not nm: return None
    name=nm.group(1)
    is_comp='Type="SqlComputedColumn"' in col_xml[:120]
    null_m=re.search(r'<Property Name="IsNullable"\s+Value="([^"]+)"',col_xml)
    nullable=null_m.group(1).lower()!="false" if null_m else True
    id_m=re.search(r'<Property Name="IsIdentity"\s+Value="([^"]+)"',col_xml)
    is_id=bool(id_m and id_m.group(1).lower()=="true")
    sm=re.search(r'<Property Name="IdentitySeed"\s+Value="([^"]+)"',col_xml)
    im=re.search(r'<Property Name="IdentityIncrement"\s+Value="([^"]+)"',col_xml)
    ts=re.search(r'<Relationship Name="TypeSpecifier">(.*?)</Relationship>',col_xml,re.DOTALL)
    col_type=parse_type(ts.group(1)) if ts else "nvarchar(max)"
    expr=None
    if is_comp:
        em=re.search(r'<Property Name="ExpressionScript"[^>]*>\s*<Value[^>]*><!\[CDATA\[(.*?)\]\]>',col_xml,re.DOTALL)
        if not em: em=re.search(r'<Property Name="ExpressionScript"[^>]*>\s*<Value[^>]*>(.*?)</Value>',col_xml,re.DOTALL)
        if em: expr=em.group(1).strip()
    default=None
    dm=re.search(r'<Property Name="DefaultExpressionScript"[^>]*>\s*<Value[^>]*><!\[CDATA\[(.*?)\]\]>',col_xml,re.DOTALL)
    if not dm: dm=re.search(r'<Property Name="DefaultExpressionScript"[^>]*>\s*<Value[^>]*>(.*?)</Value>',col_xml,re.DOTALL)
    if dm: default=dm.group(1).strip()
    return {"name":name,"type":col_type,"nullable":nullable,"identity":is_id,
            "identity_seed":sm.group(1) if sm else "1","identity_incr":im.group(1) if im else "1",
            "computed":is_comp,"computed_expr":expr,"default":default}


def parse_dacpac(dacpac_path, needed_tables):
    """
    Returns:
      table_defs: {(schema,table): {columns, pk_cols, fks}}
      all_fks_by_table: {(schema,table): [{name,local_cols,foreign_schema,foreign_table,foreign_cols}]}
      dacpac_tables: set of (schema,table) present in the DACPAC
    """
    needed_set={(t["schema"],t["table"]) for t in needed_tables}

    with zipfile.ZipFile(dacpac_path) as z:
        with z.open("model.xml") as f:
            content=f.read().decode("utf-8")

    # --- Parse all FK elements for all schemas (not just needed tables) ---
    all_fks_by_table={}  # (schema,table) -> list of FK dicts
    fk_pattern=re.compile(r'<Element Type="SqlForeignKeyConstraint" Name="\[([^\]]+)\]\.\[([^\]]+)\]"')
    for fm in fk_pattern.finditer(content):
        fk_schema,fk_name=fm.group(1),fm.group(2)
        fk_el_start=content.rfind("<Element",0,fm.start()+5)
        fk_xml=balanced_element(content,fk_el_start)

        # DefiningTable
        dt=re.search(r'<Relationship Name="DefiningTable">.*?<References Name="\[([^\]]+)\]\.\[([^\]]+)\]"',fk_xml,re.DOTALL)
        if not dt: continue
        def_schema,def_table=dt.group(1),dt.group(2)

        # Local columns
        cols_block=re.search(r'<Relationship Name="Columns">(.*?)</Relationship>',fk_xml,re.DOTALL)
        local_cols=re.findall(r'<References Name="\[[^\]]+\]\.\[[^\]]+\]\.\[([^\]]+)\]"',cols_block.group(1)) if cols_block else []

        # ForeignTable
        ft=re.search(r'<Relationship Name="ForeignTable">.*?<References Name="\[([^\]]+)\]\.\[([^\]]+)\]"',fk_xml,re.DOTALL)
        if not ft: continue
        fref_schema,fref_table=ft.group(1),ft.group(2)

        # Foreign columns
        fcols_block=re.search(r'<Relationship Name="ForeignColumns">(.*?)</Relationship>',fk_xml,re.DOTALL)
        foreign_cols=re.findall(r'<References Name="\[[^\]]+\]\.\[[^\]]+\]\.\[([^\]]+)\]"',fcols_block.group(1)) if fcols_block else []

        key=(def_schema,def_table)
        if key not in all_fks_by_table: all_fks_by_table[key]=[]
        all_fks_by_table[key].append({
            "name":fk_name,
            "local_cols":local_cols,
            "foreign_schema":fref_schema,
            "foreign_table":fref_table,
            "foreign_cols":foreign_cols,
        })

    # --- Parse all table names in DACPAC ---
    dacpac_tables=set(re.findall(r'<Element Type="SqlTable" Name="\[([^\]]+)\]\.\[([^\]]+)\]"',content))

    # --- Parse table columns/PK for needed tables only ---
    table_defs={}
    for schema,table in needed_set:
        marker=f'Type="SqlTable" Name="[{schema}].[{table}]"'
        idx=content.find(marker)
        if idx<0:
            print(f"  WARN: [{schema}].[{table}] no en model.xml"); continue
        el_start=content.rfind("<Element",0,idx)
        if el_start<0: continue
        table_xml=balanced_element(content,el_start)

        # columns
        col_pat=re.compile(
            r'<Element Type="Sql(?:Simple|Computed)Column" Name="\['
            +re.escape(schema)+r'\]\.\['+re.escape(table)+r'\]\.\[[^\]]+\]"')
        columns=[]
        for cm in col_pat.finditer(table_xml):
            col_xml=balanced_element(table_xml,cm.start())
            c=parse_col(col_xml)
            if c: columns.append(c)

        # PK
        pk_cols=[]
        pk_m=re.search(r'<Element Type="SqlPrimaryKeyConstraint"[^>]*>(.*?)</Element>',table_xml,re.DOTALL)
        if pk_m:
            pk_cols=re.findall(r'<References[^>]*Name="\[[^\]]+\]\.\[[^\]]+\]\.\[([^\]]+)\]"',pk_m.group(1))

        table_defs[(schema,table)]={
            "columns":columns,"pk_cols":pk_cols,
            "fks":all_fks_by_table.get((schema,table),[])
        }
        print(f"  {schema}.{table}: {len(columns)} cols, PK={pk_cols}, {len(all_fks_by_table.get((schema,table),[]))} FKs")

    return table_defs, all_fks_by_table, dacpac_tables


def col_ddl(col):
    n=f"[{col['name']}]"
    if col.get("computed") and col.get("computed_expr"):
        return f"    {n} AS {col['computed_expr']}"
    parts=[f"    {n}",col["type"]]
    if col.get("identity"):
        parts.append(f"IDENTITY({col.get('identity_seed','1')},{col.get('identity_incr','1')})")
    parts.append("NOT NULL" if not col.get("nullable") else "NULL")
    if col.get("default"):
        parts.append(f"DEFAULT {col['default']}")
    return " ".join(parts)


def generate_ddl(schema, table, tdef):
    cols=tdef["columns"]; pk=tdef["pk_cols"]; fks=tdef["fks"]
    lines=[f"CREATE TABLE [{schema}].[{table}]","("]
    col_lines=[col_ddl(c) for c in cols]
    lines.append(",\n".join(col_lines))
    lines.append(");\n")

    # PK
    if pk:
        pk_str=", ".join(f"[{c}] ASC" for c in pk)
        lines.append("GO")
        lines.append(f"ALTER TABLE [{schema}].[{table}]")
        lines.append(f"    ADD CONSTRAINT [PK_{table}] PRIMARY KEY CLUSTERED ({pk_str});")
        lines.append("GO\n")

    # FKs
    for fk in fks:
        local=", ".join(f"[{c}]" for c in fk["local_cols"])
        fcols=", ".join(f"[{c}]" for c in fk["foreign_cols"])
        lines.append("GO")
        lines.append(f"ALTER TABLE [{schema}].[{table}]")
        lines.append(f"    ADD CONSTRAINT [{fk['name']}] FOREIGN KEY ({local})")
        lines.append(f"        REFERENCES [{fk['foreign_schema']}].[{fk['foreign_table']}] ({fcols});")
        lines.append("GO\n")

    return "\n".join(lines)+"\n"


def patch_existing_table_fks(sql_path, fks, dry_run):
    """Add missing ALTER TABLE FK stmts to an existing table .sql file."""
    with open(sql_path) as f:
        existing=f.read()
    to_add=[]
    for fk in fks:
        if fk["name"] not in existing:
            local=", ".join(f"[{c}]" for c in fk["local_cols"])
            fcols=", ".join(f"[{c}]" for c in fk["foreign_cols"])
            stmt=(f"\nGO\nALTER TABLE [{fk.get('def_schema','')}].[{fk.get('def_table','')}]\n"
                  f"    ADD CONSTRAINT [{fk['name']}] FOREIGN KEY ({local})\n"
                  f"        REFERENCES [{fk['foreign_schema']}].[{fk['foreign_table']}] ({fcols});\nGO\n")
            to_add.append(stmt)
    if not to_add:
        return False
    if not dry_run:
        with open(sql_path,"a") as f:
            for stmt in to_add:
                f.write(stmt)
    return True


def update_sqlproj(path, new_includes, dry_run):
    with open(path) as f: content=f.read()
    to_add=[i.replace("/","\\") for i in new_includes
            if i.replace("/","\\") not in content and i not in content]
    if not to_add: return
    block="".join(f'    <Build Include="{i}" />\n' for i in to_add)
    pos=content.rfind("</ItemGroup>")
    if pos<0: pos=content.rfind("</Project>")
    new=content[:pos]+block+content[pos:]
    if not dry_run:
        with open(path,"w") as f: f.write(new)
        print(f"  .sqlproj: +{len(to_add)} entradas")
        for i in to_add: print(f"    + {i}")
    else:
        print(f"  [DRY-RUN] .sqlproj +{len(to_add)}")
        for i in to_add: print(f"    + {i}")


def remove_sqlproj_include(path, rel_path, dry_run):
    """Remove a Build Include entry from .sqlproj."""
    with open(path) as f: content=f.read()
    win=rel_path.replace("/","\\")
    tag=f'    <Build Include="{win}" />\n'
    if tag not in content: return False
    if not dry_run:
        with open(path,"w") as f: f.write(content.replace(tag,""))
    return True


def drop_removed_objects(proj_dir, dacpac_tables, sqlproj_path, dry_run):
    """
    Remove .sql files for tables that no longer exist in the DACPAC.
    Only applies to Tables/ subdirectories.
    """
    proj=Path(proj_dir)
    removed=[]
    for sql_file in proj.rglob("Tables/*.sql"):
        # Skip trigger files
        if "Trigger" in str(sql_file): continue
        rel=str(sql_file.relative_to(proj))
        parts=rel.replace("\\","/").split("/")
        if len(parts)<3: continue
        schema=parts[0]; fname=parts[2]  # schema/Tables/table.sql
        table=fname[:-4]
        if (schema,table) not in dacpac_tables:
            print(f"  DROP (no longer in BD): {rel}")
            if not dry_run:
                sql_file.unlink()
                remove_sqlproj_include(str(sqlproj_path), rel, dry_run=False)
            removed.append(rel)
    return removed


def main():
    args=parse_args(); dry=args.dry_run
    result=json.load(open(args.result_json))
    missing=extract_missing_tables(result)

    proj=Path(args.project_dir)
    sqlproj=next(proj.glob("*.sqlproj"),None)
    if not sqlproj:
        print(f"ERROR: sin .sqlproj en {proj}"); sys.exit(2)

    if not missing:
        # May still have FK-only issues — parse all FKs and patch existing tables
        print("Sin tablas faltantes. Verificando FKs en tablas existentes...")
        missing=[]

    print(f"Tablas a resolver: {len(missing)}")
    for t in missing: print(f"  {t['schema']}.{t['table']}")

    print(f"\nParsing DACPAC...")
    defs, all_fks, dacpac_tables=parse_dacpac(args.dacpac, missing)

    resolved=[]; unresolved=[]; includes=[]

    # --- Fix missing tables ---
    for t in missing:
        key=(t["schema"],t["table"])
        if key not in defs:
            print(f"  ! {key}: no en DACPAC"); unresolved.append(t); continue
        sql_path=proj/t["schema"]/"Tables"/f"{t['table']}.sql"
        ddl=generate_ddl(t["schema"],t["table"],defs[key])
        if dry:
            print(f"\n  [DRY-RUN] {sql_path.relative_to(proj)}")
            print(ddl[:600])
        else:
            sql_path.parent.mkdir(parents=True,exist_ok=True)
            sql_path.write_text(ddl)
            n_fks=len(defs[key]["fks"])
            print(f"  Escrito: {sql_path.relative_to(proj)} "
                  f"({len(defs[key]['columns'])} cols, {n_fks} FKs)")
        includes.append(str(sql_path.relative_to(proj)))
        resolved.append(t)

    # --- Patch FKs on existing tables that have the "Change ForeignKeyConstraint" error ---
    # Check all pace tables that already exist and may be missing FKs
    patched_fks=0
    for (schema,table),fks in all_fks.items():
        if not fks: continue
        # Only patch if table .sql exists and is not in the new-file list
        sql_path=proj/schema/"Tables"/f"{table}.sql"
        if not sql_path.exists(): continue
        if (schema,table) in {(t["schema"],t["table"]) for t in resolved}: continue
        # Add schema/table to fk dicts for the ALTER TABLE statement
        for fk in fks:
            fk["def_schema"]=schema
            fk["def_table"]=table
        patched=patch_existing_table_fks(str(sql_path),fks,dry)
        if patched:
            patched_fks+=1
            print(f"  FK patch: {schema}.{table} (+{len(fks)} FKs)")

    update_sqlproj(str(sqlproj),includes,dry)

    # --- Drop removed objects ---
    dropped=[]
    if args.drop_removed:
        print(f"\nChecking for objects removed from BD...")
        dropped=drop_removed_objects(str(proj),set(dacpac_tables),str(sqlproj),dry)
        if dropped:
            print(f"  {len(dropped)} .sql files removed from project")

    # Update result.json
    if (resolved or patched_fks or dropped) and not dry:
        n=len(resolved); f2=patched_fks; d=len(dropped)
        result["status"]="fixed" if not unresolved else "error"
        result["message"]=(
            f"fix-missing-tables v2: {n} tabla(s) creada(s), "
            f"{f2} tabla(s) con FK patched, {d} objeto(s) eliminados. "
            "Relanzar SchemaSyncTool para continuar."
        ) if not unresolved else result.get("message","")
        json.dump(result,open(args.result_json,"w"))
        print(f"\nresult.json → status={result['status']}")

    print(f"\n✓ Tablas nuevas: {len(resolved)}  FK patches: {patched_fks}  "
          f"Drops: {len(dropped)}  ✗ No resueltas: {len(unresolved)}")
    sys.exit(0 if not unresolved else 1)

if __name__=="__main__":
    main()
