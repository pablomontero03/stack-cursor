#!/usr/bin/env bash
# sql-readonly-gate.sh — Regla de oro: las bases de datos SQL son solo lectura.
# Misma lista de patrones que el hook de Kiro.
# En Cursor responde JSON y sale 2 para bloquear (beforeShellExecution).

INPUT=$(cat)

COMMAND=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    cmd = data.get('command') or ''
    if not cmd:
        cmd = (data.get('tool_input') or {}).get('command') or ''
    if not cmd:
        cmd = (data.get('input') or {}).get('command') or ''
    if not cmd:
        cmd = str(data)
    print(cmd.upper())
except Exception:
    print('')
" 2>/dev/null)

SQL_WRITE_PATTERNS=(
    "INSERT INTO"
    "UPDATE .* SET"
    "DELETE FROM"
    "DROP TABLE"
    "DROP DATABASE"
    "DROP SCHEMA"
    "ALTER TABLE"
    "ALTER DATABASE"
    "TRUNCATE TABLE"
    "MERGE INTO"
    "CREATE TABLE"
    "CREATE DATABASE"
    "CREATE SCHEMA"
    "GRANT "
    "REVOKE "
    "SQLPACKAGE.*PUBLISH"
    "SQLPACKAGE.*DEPLOY"
    "/ACTION:PUBLISH"
    "/ACTION:DEPLOY"
    "TARGETCONNECTIONSTRING"
)

for pattern in "${SQL_WRITE_PATTERNS[@]}"; do
    if echo "$COMMAND" | grep -qiE "$pattern"; then
        echo "BLOQUEADO: intento de escritura SQL detectado ('$pattern'). Las bases de datos son solo lectura en este proyecto." >&2
        python3 -c 'import json; print(json.dumps({"permission":"deny","user_message":"Bloqueado: escritura SQL. Las bases de datos son solo lectura.","agent_message":"El hook sql-readonly-gate bloqueo el comando. Las bases de datos son solo lectura en este proyecto."}))'
        exit 2
    fi
done

echo '{ "permission": "allow" }'
exit 0
