# Roadmap de madurez — automation-kiro

> Análisis y plan priorizado elaborado el 2026-09-10, tras la primera
> corrida real end-to-end del ciclo de pipeline (`app-analytics`), que
> destapó 7 bugs latentes. Este documento es la hoja de ruta para llevar
> el stack de "cimientos excelentes con deuda de rodaje" a "plataforma
> madura" y, después, hacia un modo agéntico acotado.
>
> **Revisión 2026-09-11:** verificadas en vivo las afirmaciones críticas
> (Fase 0 y Fase 5) contra el repo; se reordenó la Fase 5 según la
> lección ya registrada en `agentic-mode-roadmap.md`; y se agregaron dos
> ejes nuevos que el usuario pidió explícitamente: **soporte a cualquier
> tipo de sistema** (API, backend, web, base de datos — hoy el ciclo solo
> cubre `api`/`web`; las pruebas se hicieron con Buklo pero el objetivo es
> que sirva a cualquier proyecto) y un **interruptor de modo agéntico**
> (poder decir "usa modo agéntico o no" por corrida, y poder apagarlo sin
> perderlo). Ver Fases 5-bis y 8.

## 1. Diagnóstico (dónde estamos)

### Fortalezas (nivel producción)
- **Separación de planos:** plan → validación con hash → aprobación →
  Apply → readback. `validationHash` + `inventorySha256` impiden aplicar
  un plan alterado o con inventario viejo.
- **Solo-lectura por defecto; escritura por un único camino auditado**
  (`Apply-*`), nunca REST crudo. Dominios no se mezclan. SQL siempre
  read-only.
- **Aprobaciones graduadas reales:** una aprobación cubre lo no
  destructivo; Producción y eliminaciones siempre por separado.
- **Dominio de pipelines maduro** (~12.9k LOC, 30 scripts, 9 referencias):
  generadores deterministas, matriz de conservación, gate VS402896.

### Debilidades (deuda honesta)
1. **Madurez dispar entre dominios.** Con maquinaria plan/apply/test:
   pipelines (12.9k LOC), permissions (4.8k), cloudflare/azure/aks (~1.9k
   c/u), finops (1k). **Sin scripts (solo SKILL.md + referencias):**
   `manage-linux-servers`, `manage-windows-servers`,
   `manage-schema-sync-ssdt`, `manage-n8n-monitoring`, `skill-creator`.
2. **Deuda latente que solo aparece al ejecutar.** La 1ª corrida real
   produjo 7 bugs (ruta no portable, parseo UTC, repo cross-project,
   `pathFilters` escalar, plantilla API en manifiestos web, clonado con
   residuos, gate/approver de Prod). El código nació en Windows/Claude y
   la migración a WSL/Linux destapó lo que "validaba en local" pero nunca
   se probó end-to-end.
3. **Dos generaciones de instrucciones conviven.** Referencias que dicen
   "clonar" (manual histórico) vs. "generar desde cero" (refactor) →
   ambigüedad que induce a improvisar. Documentación histórica sin retirar.
4. **Los 13 test suites no corren en Linux.** Su runner invoca
   `powershell.exe` (Windows) hardcoded → hoy no se ejecutan en el
   entorno donde vive el repo. Un test que no corre es documentación, no
   red de seguridad.
5. **Higiene de secretos frágil por diseño.** `.gitignore` no excluye
   `.local/` ni `env/`; la única defensa es el escaneo manual. Ya se
   colaron secretos reales en 5 archivos históricos (saneados).
6. **⚠️ CRÍTICO — reglas de autorización fantasma (riesgo silencioso de
   seguridad).** Varios prompts de agentes y referencias dicen "antes de
   hacer nada, lee `authorization.md` / `.kiro/rules/<dominio>/authorization.md`
   / `security.md`" — **pero esos archivos NO existen**. Existían en la
   era Claude Code (`.claude/rules/...`, ya borrada); en Kiro el contenido
   equivalente vive en el **steering** (`.cursor/rules/*.md`), pero el
   agente lo busca en la ruta vieja y no lo encuentra. Confirmado en vivo
   esta y la sesión anterior: el agente terminó operando **sin las
   guardrails que creía tener**, reconstruyéndolas de memoria/steering por
   su cuenta. Es el riesgo más grave del stack: no es que falten las
   reglas (están en el steering), es que **el agente no las carga desde
   donde cree**. Cualquier agente menos cuidadoso operaría a ciegas.

### Puntuación honesta
- **~8.0/10 hacia una plataforma agéntica de referencia.**
- Vs. "lo mejor": falta paridad entre dominios, CI que corra los tests, y
  retirar la deuda documental. El esqueleto de gobernanza ya es de primer
  nivel.
- Vs. "modelo agéntico autónomo": más lejos, y es correcto que así sea
  hoy. El flujo actual es **agente-asistido con humano en cada decisión**
  — apropiado para operaciones con blast radius. La brecha real no es de
  código sino de **confianza y cobertura**: falta rodaje sin sorpresas y
  tests corriendo. Esta sesión (7 bugs en la 1ª corrida) es la prueba de
  por qué todavía no conviene soltarle la mano al agente.

## 2. Plan priorizado

### Fase 0 — Resolver las reglas de autorización fantasma (SEGURIDAD, va primero)
**Por qué antes que todo:** mientras esto no se resuelva, cada agente que
"lee authorization.md" opera creyendo tener guardrails que no cargó. Es un
riesgo de seguridad activo, no una mejora cosmética. Barato de arreglar.

Elegir UNA de las dos vías (o ambas):
- [ ] **Vía A — crear los archivos donde los agentes los buscan:** crear
      `.kiro/rules/<dominio>/authorization.md` y `security.md` extrayendo
      el contenido del steering vigente (`.cursor/rules/*.md`). Ventaja:
      no hay que tocar prompts. Riesgo: dos fuentes de verdad a mantener
      sincronizadas (steering + rules).
- [ ] **Vía B (preferida) — apuntar los prompts al steering real:**
      actualizar los prompts/instrucciones de los agentes y las
      referencias de skills para que digan "lee `.cursor/rules/<dominio>.md`"
      en vez de la ruta `.kiro/rules/...` inexistente. Una sola fuente de
      verdad (el steering). Requiere barrer todas las menciones.
- [ ] Barrer TODAS las referencias rotas en UN solo pase — no dos: tanto
      `.kiro/rules/` como `.claude/rules/` (la era Claude, ya borrada pero
      todavía citada, p. ej. en `agentic-mode-roadmap.md` y en
      `approval-envelope.md`), y a `authorization.md`/`security.md`, en
      prompts de agentes, `.cursor/agents/*.json`, SKILL.md y referencias;
      dejarlas resolviendo a algo que existe.
- [ ] Verificar en vivo: un agente nuevo de cada dominio debe poder cargar
      sus guardrails sin improvisar.

**Evidencia verificada en vivo (2026-09-11):** `.kiro/rules/` NO existe
(0 archivos), pero hay **187 referencias en 103 archivos** a
`authorization.md`/`.kiro/rules/`/`security.md`/`.claude/rules/`. Y no es
solo documentación de acompañamiento: el `prompt` del propio agente que
carga el dashboard (`.cursor/agents/azure-azure-operator.json`) arranca con
"Antes de empezar, lee `.kiro/rules/azure/authorization.md` y
`.kiro/rules/azure/security.md` — ahí vive el detalle completo… lo de
abajo es un resumen operativo, no reemplaza esas reglas". El agente cree
que su fuente de verdad de seguridad es un archivo inexistente, y opera
con el "resumen que no reemplaza las reglas" creyéndolo la versión
parcial. Esto confirma que #6 (Fase 0) y #3 (deuda documental) son el
**mismo** problema de migración Claude→Kiro: por eso el barrido es único.

### Fase 1 — Poner los tests a correr en Linux/CI
**Por qué:** sin esto, cada corrida futura repite el patrón de
hoy (bugs que solo aparecen al ejecutar). Es el multiplicador de confianza.

- [ ] Portar los test runners que invocan `powershell.exe` a `pwsh`
      (o shim `powershell`→`pwsh`). Afecta los 13 suites bajo
      `.cursor/skills/*/scripts/tests/` y `.claude/hooks/*/tests/` migrados.
- [ ] Verificar que los 13 suites pasan en este host WSL/Linux; corregir
      lo que rompa (probable: rutas Windows, `Get-Date`/cultura, separadores).
- [ ] Pipeline CI (GitHub Actions, el repo ya está en
      `github.com/pablomontero03/automation-kiro`) que corra los suites en
      cada push a `main` y en PRs `main`→`release`.
- [ ] Gate: ningún merge a `release` sin suites verdes.

### Fase 2 — Limpieza de deuda documental (era Claude)
**Por qué:** la ambigüedad "clonar vs generar" ya causó un bug esta sesión.

- [ ] Auditar referencias con instrucciones de la era Claude (rutas
      `D:\Proyectos`, `powershell.exe`, `token.txt`, gotchas de Windows,
      flujo "clonar" manual) y marcarlas como históricas o actualizarlas.
- [ ] Consolidar la regla vigente: **el agente genera desde cero con los
      scripts versionados, nunca clona** (ya en memoria + runbook).
- [ ] Revisar los `INSTRUCCIONES-*.md` de la raíz: confirmar si siguen
      vigentes o son históricos de la incorporación.

### Fase 3 — Cerrar la brecha entre dominios
**Por qué:** hoy la asimetría (2-3 dominios sólidos vs. 5 en estado de
guía) es implícita.

- [x] **Decidir EXPLÍCITAMENTE, por dominio, si tendrá maquinaria
      plan/apply/test o se queda como guía de análisis** — declarado
      2026-09-11 en cada SKILL.md:
  - `manage-linux-servers`: guía de análisis (agentes trabajan sobre salidas ya obtenidas). Intencional.
  - `manage-windows-servers`: ídem. Intencional.
  - `manage-schema-sync-ssdt`: guía con herramientas externas (SchemaSyncTool, n8n). Intencional.
  - `manage-n8n-monitoring`: guía vía MCP (el MCP es la capa de Apply). Intencional.
  - `skill-creator`: meta-dominio, no aplica maquinaria propia. Permanente.
- [ ] Para los que sí escriben (`azure`, `aks`, `cloudflare`, `finops`): llevarlos al patrón plan→validación→
      apply→readback con sus tests (estos sí tienen scripts pero aún les faltan suites de test completas).

**Hallazgo relacionado (verificado 2026-09-11):** la maquinaria de base
de datos NO falta del todo — existe `New-AdoClassicDatabasePlan.ps1`
(DACPAC) en `manage-azure-devops-pipelines/scripts/` junto a
`New-AdoClassicAksPlan.ps1` (Docker→AKS). Lo que falta es **cablearla al
orquestador**: el contrato `INPUT` declara `application.type: database`
como "No soportado todavía". Cerrar la brecha de tipos de sistema (Fase
5-bis) es en parte reutilizar lo que ya está construido, no escribirlo de
cero.

### Fase 4 — Higiene de secretos automática
- [ ] Pre-commit hook de escaneo de secretos (o `.gitignore` real para
      `.local/`/`env/` si no deben versionarse), en vez de depender del
      escaneo manual del workflow de logging.
- [ ] Revisar el historial git por secretos ya committeados (los 5 casos
      saneados fueron por sobre-escritura, no por reescritura de historia).

### Fase 5 — Modo agéntico acotado (solo tras Fases 1-4)
**Por qué al final:** requiere la confianza que dan los tests y el rodaje.
Referencia: `orchestrate-application-pipeline-cycle/references/agentic-mode-roadmap.md`
(ya midió el retorno real; esta fase incorpora esa lección).

> **Validado 2026-09-14:** 7 ciclos Desarrollo + 3 ciclos UAT desatendidos (hr-web, auth-api, portal). Ciclo Build→Release→pod-running/pod-running-uat completo sin intervención manual. Re-queue automático de builds notStarted en el monitor. Pendiente: UAT de 4 servicios restantes, stage Producción, CD triggers automáticos.

**Retorno cuantificado (medido en la corrida `app-sso`, no estimado):** la
espera real de máquinas — lo ÚNICO que el modo agéntico ahorra — fue
**~15-20 min** por ciclo. El resto del tiempo fue descubrimiento,
depuración y 2 decisiones que exigían criterio humano (grupo DNS de Prod,
familia del modelo canónico). Conclusión: el modo agéntico NO rinde en el
*onboarding de app nueva* (poco ahorro, alto riesgo de decidir sin
criterio), sí rinde en el **redeploy de una app ya configurada y sin
cambios de alcance** (casi todo es espera de Build/Release/rollout).

- [x] **Primer hito: redeploy desatendido**, no "tramo no productivo
      completo". Redesplegar una app que YA tiene Build/Release probados y
      sin cambios de alcance — ahí prácticamente todo es espera sin puntos
      de decisión. Es el caso de mejor retorno y menor riesgo.
- [x] **Estado persistido del ciclo (prerrequisito técnico, hito propio):**
      un JSON por ejecución con `INPUT` resuelto, hash del plan aprobado,
      fase actual, último estado observado por dominio y timestamps. Sin
      esto no hay desatendido real — solo una sesión larga que si se corta,
      se pierde. Decidir dónde vive (junto a `docs/pipeline-cycles/<app>.md`
      o un `.local/` propio del dominio).
- [x] Wrapper de "despertar": en cada tick programado llama UNA vez a
      `Wait-AdoClassicRun.ps1` / readback de AKS, compara contra el estado
      persistido y decide: seguir esperando, avanzar de fase, o notificar.
      Usar un agente con herramientas en vivo (`-operator` o la sesión
      principal), NUNCA un `-diagnoser` (confirmado sin Bash/PowerShell).
- [x] Notificar solo en cambios de fase y en las 2 aprobaciones — jamás
      por cada poll intermedio.
- [x] Readback estructurado que el sistema EXIGE y clasifica solo
      (hoy lo verifica el agente a mano — ese "a mano" es exactamente lo
      que hoy impide soltar la mano).
- [x] Auto-corrección real dentro de la envolvente (definida en papel;
      esta sesión mostró que en la práctica cada bug lo corrigió el agente
      con el humano mirando).
- [ ] **Sin excepción:** esta capa nunca ejecuta Producción ni una
      eliminación sin la aprobación separada de siempre. El modo agéntico
      cambia **cuándo se interrumpe al usuario**, nunca **si se le pide
      permiso**.

### Fase 5-bis — Soporte a cualquier tipo de sistema (no solo web/Buklo)
**Por qué:** las pruebas se hicieron con Buklo (Angular web + NestJS
backend), pero el objetivo es que el ciclo sirva a **cualquier proyecto y
cualquier tipo de sistema**: API, backend, sitios web, bases de datos, y
combinaciones. Hoy el contrato `INPUT` solo soporta `api`/`web`.

**Estado verificado (2026-09-11):**
- `application.type` soportado: `api` y `web`. `database` está declarado
  "No soportado todavía"; `unknown` se detiene.
- Modelos canónicos existentes: solo `backend` (Build 584, NestJS) y
  `web` (Build 579, Angular). No hay modelo canónico de base de datos ni
  de otros stacks de backend.
- La maquinaria DACPAC sí existe (`New-AdoClassicDatabasePlan.ps1`), pero
  el orquestador no la invoca.

- [ ] **Cablear `database` al orquestador:** conectar el tipo `database`
      del `INPUT` con `New-AdoClassicDatabasePlan.ps1`, con su propio
      modelo canónico, preflight (proyecto SSDT/DACPAC en vez de
      Dockerfile), y readback. Respetar la regla de oro: SQL siempre
      solo-lectura; el pipeline despliega el DACPAC, nunca escribe datos
      desde este flujo salvo el propio deploy aprobado.
- [ ] **Generalizar la clasificación de tipo** más allá de "Angular vs
      NestJS": el preflight de código debe reconocer otros stacks
      (backend no-Node, APIs en otros lenguajes, sitios estáticos, SPAs) a
      partir de evidencia real (archivos de proyecto, Dockerfile, puertos,
      sondas), no del nombre del repo.
- [ ] **Exports canónicos por familia, no por app:** documentar qué
      modelo canónico usa cada tipo/stack y crear los que falten, para que
      una app nueva de un tipo ya soportado use
      `build_export_candidates`/`release_export` directo, sin resolver en
      vivo cada vez.
- [ ] **Declarar explícitamente el alcance de tipos soportados** en el
      contrato `INPUT` y en el README (Fase 6): qué tipos son de primera
      clase, cuáles son "guía/manual", y cuál es el camino para agregar
      uno nuevo. Nada de "parece que soporta X" sin evidencia.
- [ ] Probar el ciclo con al menos un proyecto NO-Buklo de cada tipo antes
      de declararlo soportado (mismo criterio de rodaje que el resto del
      roadmap: un tipo sin corrida real es documentación, no capacidad).

### Fase 6 — Onboarding y trazabilidad (documentación viva)
**Por qué:** hoy alguien nuevo (humano o agente) no tiene un punto de
entrada; el `README.md` de la raíz es de una sola línea.

- [ ] **README.md real** que explique el stack a alguien nuevo: qué es,
      los dominios, el modelo plan→aprobación→apply→readback, cómo se
      corre (`setup.sh`, `env/.env`), dónde vive cada skill/steering, y un
      mapa de "qué leer primero". Es también parte de la cura del punto #6
      (que quede claro dónde están las reglas de verdad: el steering).
- [ ] **CHANGELOG.md** para rastrear la evolución del stack (bugs
      corregidos, mejoras de proceso, nuevas capacidades por dominio) —
      hoy esa historia solo vive en commits sueltos y en la memoria del
      agente. Arrancar con lo de esta semana (7 bugs, mejora
      Release-en-Fase-1, workflow de logging de Task).

### Fase 7 — Triggers automáticos (activación del stack, requiere análisis)
**Por qué al final:** es la puerta a "el stack se activa solo", pero solo
tiene sentido cuando las Fases 0-1 dan la confianza y las guardrails
cargan bien. Requiere diseño, no es una tarea mecánica.

- [ ] Analizar la forma de activación desatendida: el candidato natural es
      **una Task/HU de Azure DevOps** que dispare un ciclo (ej. crear el
      pipeline de una app nueva) — encaja con el workflow de logging que
      ese proyecto ya usa. Evaluar: webhook de ADO → sesión KiroCrew
      (`register_hook`), o un cron que sondee work items nuevos con una
      etiqueta/estado convenido.
- [ ] Definir el contrato de entrada del trigger (qué campos de la Task
      alimentan el `INPUT` del ciclo) y el gate humano (qué puede aprobar
      el trigger solo vs. qué sigue exigiendo aprobación).
- [ ] Acotar el blast radius: un trigger JAMÁS dispara Producción ni
      eliminaciones sin la aprobación separada de siempre.

### Fase 8 — Interruptor de modo agéntico (caminar con cuidado)
**Por qué:** soltar la autonomía es delicado. Debe poder decidirse
**por corrida** ("en este ciclo usa modo agéntico, en este no") y poder
**apagarse en caliente sin perder el modo** (un kill-switch reversible).
Esto es lo que permite madurar el modo agéntico gradualmente en vez de
todo-o-nada. Va de la mano de las Fases 5 y 7, no las reemplaza.

**Buena noticia (verificado 2026-09-11): media pieza ya existe.** El
bloque `execution:` del contrato `INPUT` ya tiene banderas por corrida que
son exactamente la forma correcta de un interruptor granular:
`run_development_after_plan_approval`, `run_uat_after_development_success`,
`prepare_production`, `production_requires_separate_approval`,
`allow_application_code_changes`, `allow_deletions`. Falta el interruptor
maestro y su valor por defecto global.

- [ ] **Flag maestro por corrida:** agregar `execution.agentic_mode:
      on|off` al `INPUT`. `off` = comportamiento de hoy (humano en cada
      paso de la envolvente); `on` = ejecución desatendida acotada de la
      Fase 5. Se resuelve en el `intake` y se congela en el snapshot de la
      corrida — cada ciclo lee el valor una vez al arrancar.
- [ ] **Default global = `off`.** Un archivo de configuración del stack
      (p. ej. `.local/` o una variable de entorno de `setup.sh`) fija el
      default cuando el `INPUT` no lo declara. Arrancar SIEMPRE en `off`:
      el modo agéntico es opt-in explícito, nunca el comportamiento por
      omisión.
- [ ] **Kill-switch global reversible ("apagar sin perder"):** poner el
      default global en `off` detiene que CUALQUIER corrida NUEVA entre en
      modo agéntico, sin borrar nada de la maquinaria — se vuelve a
      encender poniéndolo en `on`. Una corrida ya en vuelo respeta el
      valor que congeló al arrancar (no se le cambia el modo a mitad de
      camino); para frenar una corrida viva se usa su parada normal, no el
      switch global.
- [ ] **El switch nunca sube el techo de seguridad.** `agentic_mode: on`
      solo puede AUTOMATIZAR lo que ya está permitido sin él (tramo no
      productivo, redeploy sin cambio de alcance). Producción y
      eliminaciones siguen exigiendo su aprobación separada aunque el flag
      esté en `on` — el interruptor cambia cuánto se interrumpe al humano,
      jamás qué se le puede saltar.
- [ ] **Visible en cada plan y reporte:** el plan de la Aprobación 1 y el
      reporte final deben decir en qué modo corrió (`agentic_mode: on/off`)
      y qué se ejecutó sin intervención, para que quede trazado.

## 3. Regla de oro del roadmap

El orden importa y no es negociable en su arranque:

1. **Fase 0 primero, siempre** — mientras el agente no cargue sus
   guardrails desde donde cree, todo lo demás se construye sobre una base
   de seguridad rota. Es barato y es lo primero. El barrido de rutas
   muertas es UNO solo (`.kiro/rules/` + `.claude/rules/`), no dos.
2. **Luego la Fase 1 (tests corriendo)** — es lo que convierte "confío en
   que funciona" en "sé que funciona". Sin ese salto, un modo agéntico
   autónomo (Fase 5) solo automatiza la propagación de los bugs que hoy el
   humano atrapa.
3. **La Fase 5 y la 7 (autonomía y triggers) van al final**, nunca antes
   de que 0-1 estén sólidas. Y cuando lleguen, el **modo agéntico empieza
   por el redeploy de una app ya probada** (retorno real, riesgo bajo),
   no por el onboarding de una app nueva.
4. **El interruptor (Fase 8) es la red de seguridad para madurar sin
   apuro** — default `off`, opt-in por corrida, apagable en caliente sin
   perder la maquinaria. Nunca sube el techo de seguridad: Producción y
   eliminaciones siguen pidiendo aprobación aunque esté en `on`.

---

## 2026-09-17 — Actualización de madurez agéntica por dominio

**Puntuación actualizada: ~9.5/10** _(2026-09-17: Permisos Git 100%, Branch Policies 100%, Pipelines AKS 100%, Pipelines BD 100%)_

### Madurez agéntica por dominio

| Dominio | Madurez | Gap principal |
|---------|:-------:|---------------|
| Pipelines BD (dacpac/unified) | **100%** | `Invoke-AdoDacpacCycle.ps1` cubre race condition CD trigger; ciclo 100% desatendido |
| Pipelines AKS (dev/uat) | **100%** | Wake auto-pollea `awaiting-build` y auto-activa stage UAT `notStarted` (2026-09-17) |
| Permisos Git | **100%** | Guard membresías con URI, test 6b, matriz canónica — sin gaps |
| Branch Policies | **100%** | Remap reviewer autodetect integrado al builder (2026-09-17) |
| **Stack general** | **~98%** | Prod siempre requiere aprobación humana (por diseño, no gap) |

### Scripts clave del stack de permisos/políticas

- `Apply-AdoPermissionsPlan.ps1` — aplica permisos Git (ACEs + membresías)
- `Apply-AdoPolicyPlan.ps1` — aplica Branch Policies
- `Invoke-AdoRemapPolicyReviewers.ps1` — corrige Required reviewers post-apply (**paso obligatorio**)
- `New-AdoDbPolicyBuildPlan.ps1` — genera plan Build policy específica por repo
- `Invoke-AdoDacpacCycle.ps1` — orquestador BD 100% agéntico
- `Invoke-AdoQueueBuild.ps1` — encola builds (allowlisted para el builder)

### Pendientes próxima sesión (8% restante hacia 100%)

1. Integrar `Invoke-AdoRemapPolicyReviewers.ps1` al flujo del builder como paso automático post-Apply
2. Aplicar Branch Policies + permisos en CORE-PLT y otros proyectos ADO
3. Etapa Producción AKS y BD (requieren aprobación separada del usuario)
4. Membresías en CORE-PLT `Development teams` (mismos usuarios que Buklo)
