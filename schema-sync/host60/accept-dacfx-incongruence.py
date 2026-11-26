#!/usr/bin/env python3
"""Post-proceso de SchemaSyncTool cuando termina en error.

Regla vigente (2026-11-09, Pablo): main SIEMPRE debe quedar como esta la BD de prod.
Si el sync deja diferencias, se hace commit + push a main de lo que el tool dejo en
disco y el resultado queda en status=error con la lista de pendientes. Ningun caso
se reescribe como success: nada queda escondido.

Casos:
  * pace.* (bug DacFx conocido)      -> commit+push, status=error, marcado como conocido.
  * Falta tabla (hueco DacFx)         -> con --allow-missing-tables: commit+push, status=error.
  * Cualquier otra incongruencia      -> con --push-on-incongruence: commit+push, status=error.
  * Sin flag aplicable                -> exit 1, sin commit (comportamiento anterior).
El push nunca usa --force; si git lo rechaza, se reporta el error de git.
"""
import argparse, base64, json, os, re, subprocess, sys
from datetime import datetime

INCONGRUENCE = re.compile(r"incongruencia", re.IGNORECASE)
BRACKET_SCHEMA = re.compile(r"\[([A-Za-z0-9_]+)\]\s*\.\s*\[")
SCHEMA_OBJECT = re.compile(r"\bSchema\s+\[([A-Za-z0-9_]+)\]", re.IGNORECASE)
FALTA_TABLA = re.compile(r"Falta tabla ([^\s\n→]+)")
LEFTOVER = re.compile(r"-\s+((?:Add|Change|Delete)\s+\w+\s+\[[^\]]+\](?:\.\[[^\]]+\])*)")


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--result-json", required=True)
    p.add_argument("--repo-dir", required=True)
    p.add_argument("--database", required=True)
    p.add_argument("--allow-missing-tables", action="store_true",
                   help="Hueco DacFx (Falta tabla): commit+push a main, status=error")
    p.add_argument("--push-on-incongruence", action="store_true",
                   help="Cualquier incongruencia BD vs repo: commit+push a main, status=error")
    return p.parse_args()


def get_pat(result_json_path):
    env = os.path.join(os.path.dirname(os.path.dirname(result_json_path)), ".env")
    if not os.path.exists(env):
        return None
    for line in open(env):
        line = line.strip()
        if line.startswith("AZDO_PAT="):
            return line.split("=", 1)[1].strip().strip('"\x27')
    return None


def listed_schemas(msg):
    return BRACKET_SCHEMA.findall(msg) + SCHEMA_OBJECT.findall(msg)


def is_known_pace_incongruence(msg):
    """True solo cuando todo objeto listado en el leftover es del schema pace."""
    if not msg or not INCONGRUENCE.search(msg):
        return False
    if "Falta tabla" in msg:
        return False
    schemas = listed_schemas(msg)
    if not schemas:
        return False
    return all(name.lower() == "pace" for name in schemas)


def is_missing_tables_gap(msg):
    return bool(msg) and "Falta tabla" in msg


def is_incongruence(msg):
    return bool(msg) and bool(INCONGRUENCE.search(msg))


def extract_missing_tables(msg):
    return FALTA_TABLA.findall(msg)


def extract_leftover(msg):
    return LEFTOVER.findall(msg or "")


def commit_label(cli_database, result):
    for key in ("database", "bundleId", "repo"):
        val = (result.get(key) or "").strip()
        if val:
            return val
    return cli_database


def commit_push(repo_dir, database, pat):
    """Commit de lo que el tool dejo en disco y push fast-forward a main.
    Devuelve (sha, push_ok, detalle). Nunca fuerza."""
    branch = run(["git", "-C", repo_dir, "branch", "--show-current"]).stdout.strip()
    if branch != "main":
        return None, False, f"la copia de trabajo esta en '{branch}', no en main; no se sube"
    if run(["git", "-C", repo_dir, "status", "--porcelain"]).stdout.strip():
        run(["git", "-C", repo_dir, "add", "-A"])
        ts = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S")
        c = run(["git", "-C", repo_dir, "-c", "user.name=schema-sync-bot",
                 "-c", "user.email=repo-sync@grupomontecristo.com",
                 "commit", "-m", f"chore(schema): sync {database} from SQL MI [{ts} UTC]"])
        if c.returncode != 0:
            return None, False, "git commit fallo: " + (c.stderr or c.stdout).strip()[:300]
    sha = run(["git", "-C", repo_dir, "rev-parse", "HEAD"]).stdout.strip()
    if not pat:
        return sha, False, "sin AZDO_PAT en .env; commit local sin push"
    b64 = base64.b64encode(f":{pat}".encode()).decode()
    run(["git", "-C", repo_dir, "config", "http.extraHeader", f"Authorization: Basic {b64}"])
    try:
        p = run(["git", "-C", repo_dir, "push", "origin", "HEAD:refs/heads/main"])
    finally:
        run(["git", "-C", repo_dir, "config", "--unset", "http.extraHeader"])
    if p.returncode != 0:
        return sha, False, "git push a main fallo: " + (p.stderr or p.stdout).strip()[:300]
    return sha, True, "push a main OK"


def finish(result, args, kind, pending):
    label = commit_label(args.database, result)
    sha, pushed, detail = commit_push(args.repo_dir, label, get_pat(args.result_json))
    original = (result.get("message") or "").strip()
    head = {
        "pace": "Main actualizado con la BD; quedan diferencias del bug DacFx conocido en pace.*",
        "missing": f"Main actualizado con la BD; faltan {len(pending)} tabla(s) en el .sqlproj (hueco DacFx)",
        "incongruence": f"Main actualizado con la BD; quedan {len(pending)} diferencia(s) que el sync no pudo escribir",
    }[kind]
    if not pushed:
        head = f"NO se pudo subir a main ({detail}). " + head.replace("Main actualizado con la BD; ", "")
    result.update({
        "status": "error",
        "synced": bool(pushed),
        "hadDrift": True,
        "commitSha": sha,
        "pushedToMain": bool(pushed),
        "pushDetail": detail,
        "pendingKind": kind,
        "pendingDifferences": pending,
        "message": f"{head}. Detalle original: {original}"[:4000],
    })
    if kind == "missing":
        result["missingTables"] = pending
    json.dump(result, open(args.result_json, "w"))
    print(json.dumps(result))
    sys.exit(0)


def main():
    args = parse_args()
    result = json.load(open(args.result_json))
    if result.get("status") != "error":
        print(f"status={result.get('status')}, nothing to do")
        sys.exit(0)
    msg = result.get("message", "") or ""

    if is_known_pace_incongruence(msg):
        finish(result, args, "pace", extract_leftover(msg))
    if args.allow_missing_tables and is_missing_tables_gap(msg):
        finish(result, args, "missing", extract_missing_tables(msg))
    if args.push_on_incongruence and is_incongruence(msg):
        finish(result, args, "incongruence", extract_leftover(msg))

    print("Error sin caso aplicable; no se hace commit", file=sys.stderr)
    sys.exit(1)


def self_test():
    core = ("Error en schema-sync: Quedó incongruencia de esquema BD vs repo después del sync "
            "(no se marca éxito): - Delete Schema [external] - Add Table [external].[tra_invoice]")
    pace = ("Error en schema-sync: Quedó incongruencia de esquema BD vs repo después del sync "
            "(no se marca éxito): - Add Table [pace].[cat_pace_forecast] - Add ForeignKey [pace].[fk_x]")
    mixed = pace + " - Delete Schema [aseguradora]"
    cotiz = ("Error en schema-sync: Quedó incongruencia de esquema BD vs repo después del sync "
             "(no se marca éxito):  - Add Table [dbo].[quotes]  - Add DefaultConstraint [dbo].[quotes_createdAt_df]"
             "  - Add UniqueConstraint [dbo].[quotes_publicId_key]")
    ia_gap = ("Error en schema-sync: El sync dejó el proyecto incompleto vs la BD (hueco DacFx). "
              "No se omite en silencio:  - Falta tabla IA.agent -> IA/Tables/agent.sql"
              "  - Falta tabla IA.agent_decision_snapshot -> IA/Tables/agent_decision_snapshot.sql")
    net = "Error de red/conectividad hacia SQL MI. Detalle: timeout"
    checks = [
        (not is_known_pace_incongruence(core), "core compare no es pace"),
        (is_known_pace_incongruence(pace), "pace-only sigue reconocido"),
        (not is_known_pace_incongruence(mixed), "mixed no es pace"),
        (not is_known_pace_incongruence("Error en schema-sync: Quedó incongruencia sin objetos"),
         "incongruencia sin objetos no es pace"),
        (commit_label("OpsObservability", {"database": "sqldb_core_global+sqldb_core_workflow"})
         == "sqldb_core_global+sqldb_core_workflow", "label usa la database del result"),
        (is_missing_tables_gap(ia_gap), "IA gap detectado"),
        (not is_missing_tables_gap(core), "core no es gap"),
        (len(extract_missing_tables(ia_gap)) == 2, "2 tablas faltantes en IA gap"),
        (is_incongruence(cotiz), "cotizadores es incongruencia"),
        (len(extract_leftover(cotiz)) == 3, "3 pendientes en cotizadores"),
        (extract_leftover(cotiz)[0] == "Add Table [dbo].[quotes]", "primer pendiente = quotes"),
        (not is_incongruence(net), "error de red puro no es incongruencia (no se sube)"),
    ]
    failed = [text for ok, text in checks if not ok]
    if failed:
        print("SELFTEST_ACCEPT_FAIL")
        for text in failed:
            print(text)
        return 1
    print("SELFTEST_ACCEPT_OK")
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        sys.exit(self_test())
    main()
