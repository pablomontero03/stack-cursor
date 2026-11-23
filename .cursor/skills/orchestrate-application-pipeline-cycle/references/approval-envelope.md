# Envolvente de aprobación

## Historial de esta sección (para no repetir la vuelta)

1. Versión original (2026-09-07): Aprobación 1 incluía crear
   definiciones **y** ejecutar Desarrollo/UAT, siguiendo literalmente
   las instrucciones del refactor.
2. Corrección (2026-09-08, durante la primera corrida real de
   `app-sso`): se encontró que eso contradecía una regla más estricta y
   preexistente en `.claude/rules/azure-devops-pipelines/authorization.md`
   ("Encolar el primer Build"/"crear una instancia de Release real"
   como aprobaciones siempre separadas) — se separó en Aprobación 1
   (solo definiciones) + Aprobación 1B (ejecución, por ambiente).
3. **Decisión final del usuario (2026-09-08, mismo día, después de ver
   la fricción real de pedir 2 aprobaciones extra en la misma corrida)**:
   volver a agrupar Desarrollo/UAT dentro de la Aprobación 1 — pero esta
   vez de la forma correcta: se actualizó la regla BASE del dominio
   (`azure-devops-pipelines/authorization.md` § "Preguntar una vez por
   operación atómica") para permitir explícitamente esta ampliación,
   aplicando **a todo el dominio**, no solo a este ciclo coordinador.
   Esto ya no es una excepción silenciosa del refactor — es la regla
   vigente del dominio.

## Aprobación 1 — plan no productivo (crear + ejecutar Desarrollo/UAT)

Una sola aprobación cubre exactamente lo que el plan consolidado
enumeró:

- Crear/reutilizar los DNS declarados, siempre que
  `Resolve-CloudflareDnsRecord.ps1` los haya clasificado `to_create` o
  `reuse` (nunca `conflict` sin resolución explícita).
- Crear las definiciones Build/Release/Task Group/Variable Group
  aprobadas para los 3 ambientes.
- Encolar el Build y ejecutar/crear la primera instancia real del
  Release para **Desarrollo**, monitorear hasta terminal y hacer
  readback en AKS — siempre que el plan haya enumerado explícitamente
  que esto va a pasar (no basta con haberlo hecho en silencio).
- Repetir lo anterior para **UAT**, una vez Desarrollo esté clasificado
  (no hace falta "completado" — un "incompleto" con causa identificada
  también puede justificar seguir, a criterio ya reflejado en el plan
  aprobado).
- Reintentar Desarrollo/UAT dentro de la misma envolvente (mismos
  recursos/alcance) sin pedir aprobación nueva — una corrección que
  cambia recursos, alcance, o requiere una eliminación sí la exige (ver
  `orchestration-flow.md` § Envolvente de corrección).
- Ejecutar el polling, los readbacks y los journals internos de todo lo
  anterior.

**Producción queda siempre excluida** — nunca cubierta por esta
aprobación, sin importar qué tan detallado esté el plan. Ver Aprobación
2 abajo.

Después de esta aprobación, **no** volver a preguntar por cada variable,
tarea, manifiesto, llamada POST/PUT, Build, Release o readback interno
que ya esté incluido — ni por Desarrollo ni por UAT por separado.

## Por qué una sola aprobación de `ExitPlanMode` alcanza para 3 dominios

Cada dominio (Azure DevOps Pipelines, Cloudflare, AKS) ya implementa su
propio mecanismo de "aprobación visible reutilizable" mediante un bloque
de código con nombre distinto dentro del plan aprobado por
`ExitPlanMode`:

| Dominio | Bloque | Hook que lo valida |
|---|---|---|
| Azure DevOps Pipelines | ```ado-apply-authorization``` | `ado-preparation-permission.ps1` / `ado-permission-common.ps1` |
| Cloudflare | ```cloudflare-apply-authorization``` / ```cloudflare-delete-authorization``` | `cloudflare-plan-authorization.ps1` / `cloudflare-permission-common.ps1` |
| AKS | Sin bloque visible — tarjeta nativa por nombre de `Apply-AksChangePlan.ps1` (ver `.claude/rules/aks/authorization.md`) | Permiso nativo de la herramienta |

Cada hook busca **su propio** nombre de bloque, sin exigir que sea el
único bloque presente en el texto del plan (confirmado leyendo
`cloudflare-permission-common.ps1`/`azure-permission-common.ps1`: el
regex de búsqueda está anclado al `$BlockName` exacto de ese hook, y solo
exige encontrar **una** ocurrencia de ese nombre — no le importa qué más
haya en el plan). Esto significa que un único `ExitPlanMode` de la skill
coordinadora puede incluir, en el mismo texto de plan:

```ado-apply-authorization
{ "version": 1, "commands": [ { "command": "...", "planSha256": "...", "inventorySha256": "..." } ] }
```

```cloudflare-apply-authorization
{ "version": 1, "commands": [ { "command": "...", "planSha256": "..." } ] }
```

y cada hook de dominio reconocerá y autorizará **su** comando exacto sin
pedir una tarjeta nueva — siempre que cada bloque cumpla íntegramente los
requisitos de ese dominio (comando literal en una sola línea, hashes
correctos, mismo transcript, vigencia ≤24h, sin reintento previo). AKS no
necesita bloque propio: su único script de escritura real
(`Apply-AksChangePlan.ps1`) se autoriza por la tarjeta nativa de
permisos de la herramienta al invocarlo por primera vez dentro del mismo
turno aprobado.

**Consecuencia práctica:** el plan presentado en el `ExitPlanMode` de la
Aprobación 1 debe incluir un bloque `ado-apply-authorization` (si hay
escrituras ADO) y un bloque `cloudflare-apply-authorization` (si hay
escrituras DNS) simultáneamente — nunca un solo bloque genérico
inventado para "todo el ciclo". Cada dominio sigue validando el suyo de
forma completamente independiente.

## Confirmación nativa adicional esperada: gate real de Producción del Release

Azure DevOps **rechaza** crear un environment de Release con
`preDeployApprovals.isAutomated=false` sin `approver` en el mismo POST de
creación (error 400 `VS402896`) — confirmado en el código de
`Set-AdoReleaseProductionApprovalGate`
(`manage-azure-devops-pipelines/scripts/New-AdoClassicUpdatePayload.ps1`).
Por eso, dejar el gate real de Producción (grupo `Release Executers`) es
**siempre** un proceso de 2 pasos, sin excepción posible:

1. Crear el Release con Producción automática (`isAutomated=true`, sin
   approver) — esto sí puede ir con hash pre-calculado dentro del bloque
   `ado-apply-authorization` de la Aprobación 1.
2. Un `Apply-AdoClassicPlan.ps1` **posterior**, tipo `update-release-definition`,
   que recién puede generarse (y por lo tanto hashearse) **después** de
   conocer el ID real del Release creado en el paso 1 — nunca puede
   quedar pre-autorizado en el mismo `ExitPlanMode` que crea el Release,
   sin importar qué tan detallado esté el plan.

Esto **no es una ampliación de alcance** ni un fallo del mecanismo de
aprobación — es una restricción real de la API de Azure DevOps. El plan
presentado en la Aprobación 1 debe advertir esto explícitamente (mismo
criterio que "Confirmaciones nativas adicionales esperadas" ya usado en
`docs/pipeline-cycles/app-sso.md` para el Release completo), para que la
tarjeta nativa que aparece para este segundo paso no se lea como una
aprobación nueva fuera de lo ya autorizado — es la continuación mecánica
de configurar el mismo gate estándar ya enumerado en el plan.

> **Aclaración importante (2026-09-10):** el "ID real del Release" del
> paso 2 es el del **Release DEFINITION** — que existe apenas se crea la
> definición en la Etapa 1 —, NO el de una instancia/ejecución del
> Release. Por lo tanto **la definición del Release se crea en la Etapa 1
> junto con el Build, sin esperar a que el Build se EJECUTE**. Crear el
> Release definition solo requiere que el Build definition exista (para el
> artifact source). El Build verde es requisito para *ejecutar una
> instancia* del Release, jamás para *crear su definición* ni para fijar
> su gate de Producción. No diferir la creación del Release a "después del
> Build verde": eso deja el pipeline a medias sin necesidad.

## Aprobación 2 — Producción

Siempre separada y posterior a Desarrollo y UAT estables. La tarjeta debe
mostrar: Build y Release exactos; rama `repository.branches.production` y
commit exacto; artifact e image tag/digest; DNS e IP de Producción;
clúster/namespace/node pool de `environments.production` ya validados;
diff final del manifiesto; aprobadores y condiciones del ambiente; estado
de Desarrollo y UAT; riesgo, impacto, rollback y readback.

Nunca aprobar ni ejecutar Producción automáticamente por el éxito de UAT.

## Eliminaciones

Mientras `execution.allow_deletions` sea `false`, el ciclo no autoriza
ninguna eliminación. Toda eliminación (Cloudflare, Azure DevOps, AKS,
artifacts, definiciones, variables, recursos Kubernetes o configuración)
usa el flujo destructivo separado de su propio dominio
(`Apply-CloudflareDeletePlan.ps1`, `New-AdoClassicDeletePlan.ps1` +
`Apply-AdoClassicPlan.ps1` Fase 6, o el flujo de eliminación de AKS) y
exige su propia aprobación explícita — aunque parezca necesaria para
completar el plan, y aunque la haya sugerido un diagnóstico.

## Alcance de la Aprobación 1 — qué NO cubre

No se extiende automáticamente a: otra base/aplicación; otro ambiente no
listado; un reintento tras `blocked-drift`/`ambiguous` (requiere
replanificar, no es un simple reintento dentro de la envolvente); la
familia contraria (AKS ↔ DACPAC en Azure DevOps); ejecutar Desarrollo o
UAT si el plan no lo enumeró explícitamente como parte de esta operación
(ver distinción en `.claude/rules/azure-devops-pipelines/authorization.md`
§ Terminología); ninguna eliminación; **Producción, siempre, sin
excepción**.

## Desviación del plan — detenerse, nunca improvisar

Si durante la ejecución cambia cualquier dato protegido (hash de export,
commit validado, FQDN/IP, clúster/contexto/namespace, node pool, alcance
de recursos) respecto del plan aprobado:

1. Detener únicamente la operación afectada — las demás secciones
   continúan si no dependen de ese dato.
2. No ampliar el plan aprobado automáticamente.
3. Registrar la desviación en el journal de la ejecución.
4. Readback del estado real.
5. Presentar un plan nuevo o una enmienda con hash nuevo.
6. Pedir aprobación de nuevo — nunca reutilizar la anterior.
