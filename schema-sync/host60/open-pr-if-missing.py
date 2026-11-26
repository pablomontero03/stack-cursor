#!/usr/bin/env python3
"""
open-pr-if-missing.py — abre un PR main→release en ADO si el sync hizo commit
pero el SchemaSyncTool no abrió el PR (bug en modo bundle: prUrl queda null).

Uso: python3 open-pr-if-missing.py --result-json <path> --repo-name <name>
     [--source-branch main] [--target-branch release]

Sale 0 siempre (no debe romper el flujo del run-sync.sh).
Modifica el result JSON en disco agregando prUrl si el PR se abre con éxito.
"""
import argparse, json, os, sys, urllib.request, urllib.error

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--result-json", required=True)
    ap.add_argument("--repo-name", required=True)
    ap.add_argument("--source-branch", default="main")
    ap.add_argument("--target-branch", default="release")
    ap.add_argument("--ado-org", default="Shared-Service-GM")
    ap.add_argument("--ado-project", default="Database-Administration-and-Monitoring")
    args = ap.parse_args()

    # Leer result JSON
    try:
        result = json.load(open(args.result_json, encoding="utf-8"))
    except Exception as e:
        print(f"[open-pr] No se pudo leer {args.result_json}: {e}", file=sys.stderr)
        return 0

    # Solo actuar si: success + commitSha + prUrl es null/vacío
    if result.get("status") != "success":
        return 0
    commit_sha = result.get("commitSha") or ""
    if not commit_sha:
        return 0
    if result.get("prUrl"):
        print(f"[open-pr] prUrl ya existe: {result[prUrl]}", file=sys.stderr)
        return 0

    pat = os.environ.get("AZDO_PAT", "")
    if not pat:
        print("[open-pr] AZDO_PAT no disponible, no se puede abrir PR.", file=sys.stderr)
        return 0

    import base64
    b64 = base64.b64encode(f":{pat}".encode()).decode()

    # Construir título desde database o bundleId
    db = result.get("database") or result.get("bundleId") or args.repo_name
    title = f"chore(schema): sync {db} from SQL MI"

    body = json.dumps({
        "title": title,
        "description": f"Sync automático desde el orquestador Schema Sync.\n\nCommit: `{commit_sha}`\n\nRevisar antes de mergear a `{args.target_branch}`.",
        "sourceRefName": f"refs/heads/{args.source_branch}",
        "targetRefName": f"refs/heads/{args.target_branch}",
        "reviewers": []
    }).encode("utf-8")

    url = (
        f"https://dev.azure.com/{args.ado_org}/{args.ado_project}"
        f"/_apis/git/repositories/{args.repo_name}/pullrequests?api-version=7.1"
    )

    req = urllib.request.Request(
        url, data=body, method="POST",
        headers={"Authorization": f"Basic {b64}", "Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            pr_data = json.loads(resp.read())
        pr_id = pr_data.get("pullRequestId")
        pr_url = (
            f"https://dev.azure.com/{args.ado_org}/{args.ado_project}"
            f"/_git/{args.repo_name}/pullrequest/{pr_id}"
        )
        print(f"[open-pr] PR abierto: {pr_url}", file=sys.stderr)
        # Actualizar result JSON con prUrl
        result["prUrl"] = pr_url
        with open(args.result_json, "w", encoding="utf-8") as f:
            json.dump(result, f, ensure_ascii=False, indent=4)
        # Imprimir resultado actualizado para que run-sync.sh lo recoja
        print(json.dumps(result, ensure_ascii=False))
    except urllib.error.HTTPError as e:
        body_err = e.read().decode(errors="replace")[:300]
        # 409 = PR ya existe entre esas ramas
        if e.code == 409:
            print(f"[open-pr] PR ya existe entre {args.source_branch}→{args.target_branch} (409), OK.", file=sys.stderr)
        else:
            print(f"[open-pr] Error HTTP {e.code} abriendo PR: {body_err}", file=sys.stderr)
    except Exception as e:
        print(f"[open-pr] Error abriendo PR: {e}", file=sys.stderr)

    return 0

if __name__ == "__main__":
    sys.exit(main())
