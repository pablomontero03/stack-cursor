# Patrones — ado-permissions-diagnoser

## Orden de diagnóstico recomendado

1. Confirmar que el PAT existe (booleano, nunca el valor).
2. Confirmar que el namespace "Git Repositories" se resuelve en vivo y
   que las acciones del catálogo existen exactamente una vez cada una.
3. Si falla resolución de scope/identidad: revisar
   `Descriptors/Get`/`subjectquery` primero (endpoints no verificados con
   ejemplo oficial).
4. Si `Apply-*` omite una operación: es "skipped" por drift de
   precondición, comportamiento esperado — confirmar con el usuario antes
   de sugerir regenerar el plan.
5. Si `Apply-*` falla una operación real: revisar el journal de ejecución
   en `.local/azure-devops-permissions/executions/` antes de cualquier
   reintento.
6. Si un `set-git-permissions-ace` reportó "applied" pero el grupo no
   aparece en el portal (Security tab del repo/proyecto): NO asumir que
   funcionó por el código HTTP. Verificar con un GET crudo sin
   `&descriptors=` o con el Audit Log de la organización antes de seguir
   — ver `MEMORY.md` § "INCIDENTE MAYOR" del builder.
