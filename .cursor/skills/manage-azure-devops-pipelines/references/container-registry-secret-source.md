# Fuente canónica de la contraseña del Container Registry

Este documento designa un nombre concreto sobre el mecanismo genérico ya
implementado en `.claude/rules/azure-devops-pipelines/security.md` §
"Referencias de secretos controladas (`${ADO_SECRET_*}`)" — no duplica ese
mecanismo, solo fija cuál variable de entorno es la fuente por defecto
para este secreto específico cuando lo usa
`orchestrate-application-pipeline-cycle` (o cualquier otro flujo de este
dominio que lo necesite).

## Convención

- Variable de entorno fuente: **`ADO_SECRET_CONTAINERREGISTRYPASSWORD`**.
- Se lee internamente desde el proceso actual (nunca se pide al usuario
  por chat).
- Se comprueba **solo por presencia** (`[bool][Environment]::GetEnvironmentVariable(...)`),
  nunca por valor.
- El nombre real de destino en el modelo canónico (Build/Release
  clásico) se resuelve desde el propio export — típicamente
  `containerRegistryPassword` en una tarea/conexión ACR, pero puede
  variar; no asumir el nombre sin confirmarlo contra el JSON canónico.
- Se pasa a `Invoke-AdoRest -SecretReferences @(@{ Path = '...'; EnvVarName = 'ADO_SECRET_CONTAINERREGISTRYPASSWORD' })`
  únicamente dentro de una escritura ya aprobada por
  `Apply-AdoClassicPlan.ps1` — nunca como argumento de línea de comandos,
  nunca incorporada al archivo del plan, nunca en errores.

### Dos lugares distintos — nunca confundirlos (bug real 2026-09-08, `app-sso`/Release 390)

El placeholder `${ADO_SECRET_CONTAINERREGISTRYPASSWORD}` va **solo** en
`environments[N].variables.containerRegistryPassword.value` (junto con
`isSecret: true`) — nunca en el `deployTaskGroupInputs` de la tarea. El
input de la tarea siempre usa la **macro nativa de Azure DevOps**
`$(containerRegistryPassword)`, que ADO resuelve en runtime desde esa
misma variable de ambiente:

```
environments[N].variables:
  containerRegistryUsername: { value: "<literal, ej. gmonhubacreastus20001>" }   # NO es secreto
  containerRegistryPassword: { value: "${ADO_SECRET_CONTAINERREGISTRYPASSWORD}", isSecret: true }

deployTaskGroupInputs:
  containerRegistryUsername: "$(containerRegistryUsername)"   # macro ADO, nunca literal ni placeholder
  containerRegistryPassword: "$(containerRegistryPassword)"   # macro ADO, nunca literal ni placeholder
```

Confundir estos dos (poner el placeholder `${ADO_SECRET_*}` directo en el
task input, u olvidar crear `containerRegistryUsername` como variable de
ambiente) rompe el `docker login` remoto en runtime sin ningún error
visible en el plan/Apply — el fallo solo aparece al ejecutar el
despliegue real. Ver memoria de proyecto
`ado-release-containerregistry-macro-bug` para el incidente completo.

`Set-AdoReleaseEnvironmentVariables` (splice en
`New-AdoClassicUpdatePayload.ps1`) es la función correcta para fijar
estas 2 variables de ambiente en un Release ya existente — llamarla para
**ambas**, nunca solo para una. La resolución real del placeholder vía
`-ReleaseSecretReferencesPath` en `Apply-AdoClassicPlan.ps1` sobre un
`update-release-definition` no quedó verificada como confiable en esa
misma corrida (el valor terminó vacío) — hasta confirmarlo con una prueba
controlada, preferir fijar el secreto real directamente desde la UI de
Azure DevOps para una corrección puntual sobre un Release existente.
- Si la variable fue creada con `setx` y la sesión actual del proceso no
  la ve todavía (limitación conocida de `setx`: solo aparece en procesos
  *nuevos*), pedir reiniciar la terminal/sesión de Claude una vez y
  volver a comprobar la presencia — nunca solicitar el valor por chat
  como sustituto.

## Cuándo es obligatoria

Cuando una tarea o Service Connection ACR del modelo canónico consuma
esta contraseña. Antes de darla por imprescindible, confirmar si ya existe
una alternativa sin secreto suelto (Docker Registry Service Connection ya
configurada, identidad administrada) — ver
`.claude/rules/azure-devops-pipelines/security.md` § "Antes de usar un
secreto real: buscar la alternativa segura".
