# Roadmap de madurez — automation-kiro

> Análisis y plan priorizado elaborado el 2026-09-10, tras la primera
> corrida real end-to-end del ciclo de pipeline (`app-analytics`), que
> destapó 7 bugs latentes. Este documento es la hoja de ruta para llevar
> el stack de "cimientos excelentes con deuda de rodaje" a "plataforma
> madura" y, después, hacia un modo agéntico acotado.

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
   equivalente vive en el **steering** (`.kiro/steering/*.md`), pero el
   agente lo busca en la ruta vieja y no lo encuentra. Confirmado en vivo
   esta y la sesión anterior: el agente terminó operando **sin las
   guardrails que creía tener**, reconstruyéndolas de memoria/steering por
   su cuenta. Es el riesgo más grave del stack: no es que falten las
   reglas (están en el steering), es que **el agente no las carga desde
   donde cree**. Cualquier agente menos cuidadoso operaría a ciegas.

### Puntuación honesta
- **~6.5/10 hacia una plataforma agéntica de referencia.**
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
      el contenido del steering vigente (`.kiro/steering/*.md`). Ventaja:
      no hay que tocar prompts. Riesgo: dos fuentes de verdad a mantener
      sincronizadas (steering + rules).
- [ ] **Vía B (preferida) — apuntar los prompts al steering real:**
      actualizar los prompts/instrucciones de los agentes y las
      referencias de skills para que digan "lee `.kiro/steering/<dominio>.md`"
      en vez de la ruta `.kiro/rules/...` inexistente. Una sola fuente de
      verdad (el steering). Requiere barrer todas las menciones.
- [ ] Barrer TODAS las referencias rotas a `.kiro/rules/` y a
      `authorization.md`/`security.md` en prompts de agentes, SKILL.md y
      referencias; dejarlas resolviendo a algo que existe.
- [ ] Verificar en vivo: un agente nuevo de cada dominio debe poder cargar
      sus guardrails sin improvisar.

### Fase 1 — Poner los tests a correr en Linux/CI
**Por qué:** sin esto, cada corrida futura repite el patrón de
hoy (bugs que solo aparecen al ejecutar). Es el multiplicador de confianza.

- [ ] Portar los test runners que invocan `powershell.exe` a `pwsh`
      (o shim `powershell`→`pwsh`). Afecta los 13 suites bajo
      `.kiro/skills/*/scripts/tests/` y `.claude/hooks/*/tests/` migrados.
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

- [ ] Decidir EXPLÍCITAMENTE, por dominio, si tendrá maquinaria
      plan/apply/test o se queda como guía de análisis (linux/windows
      operan sobre salidas ya obtenidas; schema-sync usa herramientas
      externas; skill-creator es meta — pueden quedarse como guía a
      propósito, pero debe estar declarado).
- [ ] Para los que sí escriben: llevarlos al patrón plan→validación→
      apply→readback con sus tests.

### Fase 4 — Higiene de secretos automática
- [ ] Pre-commit hook de escaneo de secretos (o `.gitignore` real para
      `.local/`/`env/` si no deben versionarse), en vez de depender del
      escaneo manual del workflow de logging.
- [ ] Revisar el historial git por secretos ya committeados (los 5 casos
      saneados fueron por sobre-escritura, no por reescritura de historia).

### Fase 5 — Modo agéntico acotado (solo tras Fases 1-4)
**Por qué al final:** requiere la confianza que dan los tests y el rodaje.
Referencia: `orchestrate-application-pipeline-cycle/references/agentic-mode-roadmap.md`.

- [ ] Ejecución desatendida del tramo NO productivo completo (DNS + VG +
      Build + Release + ejecución Desarrollo/UAT + readback), parando solo
      en Producción y eliminaciones. Las piezas existen (aprobación por
      hash, envolvente de corrección); falta el orquestador que las
      encadene sin intervención por paso.
- [ ] Readback estructurado que el sistema EXIGE y clasifica solo
      (hoy lo verifica el agente a mano).
- [ ] Auto-corrección real dentro de la envolvente (definida en papel;
      esta sesión mostró que en la práctica cada bug lo corrigió el agente
      con el humano mirando).

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

## 3. Regla de oro del roadmap

El orden importa y no es negociable en su arranque:

1. **Fase 0 primero, siempre** — mientras el agente no cargue sus
   guardrails desde donde cree, todo lo demás se construye sobre una base
   de seguridad rota. Es barato y es lo primero.
2. **Luego la Fase 1 (tests corriendo)** — es lo que convierte "confío en
   que funciona" en "sé que funciona". Sin ese salto, un modo agéntico
   autónomo (Fase 5) solo automatiza la propagación de los bugs que hoy el
   humano atrapa.
3. **La Fase 5 y la 7 (autonomía y triggers) van al final**, nunca antes
   de que 0-1 estén sólidas.
