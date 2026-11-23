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
