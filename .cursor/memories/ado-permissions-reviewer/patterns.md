# Patrones — ado-permissions-reviewer

## Checklist rápido por plan

1. Grupo resuelto sin adivinar (reusa/crea/bloquea por ambigüedad).
2. Descripción `actual → deseado` coherente con `DescriptionMode`.
3. Membresía solo agrega, nunca resta.
4. Matriz exacta contra `references/permission-matrix.md` (All
   Repositories y por rama).
5. ACE preserva bits no administrados. Además (agregado 2026-09-02): cada
   clave del `acesDictionary` en el body de un `set-git-permissions-ace`
   tiene forma `Microsoft.TeamFoundation.Identity;S-1-9-...` (SID legado)
   — nunca un descriptor de Graph `vssgp.XXXX` crudo. Ver `MEMORY.md` de
   `ado-permissions-builder` § "INCIDENTE MAYOR".
6. Grupo nuevo → miembros/ACE en `deferredAfterCreation`, no en
   `approvedOperations`.
7. Guard de lockout resuelto o reconocido explícitamente.
8. Inventario fresco y con hash coincidente.
9. Sin secretos literales (excepto el token de seguridad Git, que no es
   secreto).
10. Una sola operación destructiva por plan de eliminación, nunca
    mezclada con un plan no destructivo.
11. (Agregado 2026-09-03) Si el plan crea o le agrega el primer miembro a
    `Development Team(s)`/`Code-Reviewers`, recordar que la matriz de
    este dominio NO administra "View project-level information"
    (namespace `Project`, distinto de "Git Repositories") — señalar como
    pendiente manual del usuario, nunca asumir que la matriz Git alcanza
    para que el proyecto sea visible. Esto SÍ es verificable por API (no
    hace falta pedirle al usuario que entre al portal) — ver
    `references/ado-security-api-map.md` § "Namespace 'Project'" para la
    receta exacta. Ver `MEMORY.md` de `ado-permissions-builder` § "Gap de
    cobertura real" (caso real: Edson Alvarez Obando, Buklo).

## Regla crítica: no procesar JSON grande inline en shell
**Causa de crashes del gateway confirmada en producción (2026-09-21).**

Procesar JSON de más de ~50KB directamente en el tool de shell (heredoc Python inline, `curl | python3`, `python3 -c "..."` con JSON grande) bloquea el ACP y tumba el gateway.

**Patrón correcto obligatorio:**
1. Descargar/guardar el JSON a un archivo en disco: `curl ... -o /tmp/data.json`
2. Procesar con un script `.py` separado que lee del archivo
3. Guardar el resumen en `/tmp/output.txt`
4. Leer y mostrar solo el `.txt` (que es corto)
5. Limpiar temporales: `rm -f /tmp/data.json /tmp/output.txt`

**Nunca:**
- Python inline con JSON de cientos de KB en el mismo comando
- `curl ... | python3 -c '...'` con respuesta grande
- Heredoc con JSON inline de cientos de líneas
- Usar `/tmp` directamente en bash sin verificar que existe

**Aplica a:** inventarios ADO, manifests Kubernetes, respuestas de API con listas largas, archivos de configuración grandes.

## Regla: no ejecutar setup.sh de Kiro
**Causa de crashes del gateway confirmada en producción (2026-09-21).**

No ejecutar `setup-kiro.sh` ni `source ./setup.sh`. Las variables se cargan con `set -a; source env/.env; set +a`. `./setup-cursor.sh` no reinicia el worker.

**Siempre usar `--no-restart` cuando se ejecuta desde una sesión activa de Crew:**
```bash
set -a; source env/.env; set +a
```

**Cuándo SÍ reiniciar (sin --no-restart):**
- Primera instalación en una máquina nueva
- Cuando el operador lo pide explícitamente
- Cuando se agregan nuevos agentes o skills que requieren recarga

**Cuándo NO reiniciar (usar --no-restart):**
- Cualquier vez que el agente ejecuta setup.sh para cargar variables de entorno
- Al inicio de scripts que solo necesitan `$REPO_ROOT`, `$AZURE_DEVOPS_PAT`, etc.
