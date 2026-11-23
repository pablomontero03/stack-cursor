# Hoja de ruta — modo agéntico (background/desatendido)

Documento de planificación, **no implementado todavía**. Registra la
brecha identificada el 2026-09-07 entre lo que este dominio ya hace y lo
que haría falta para operar el ciclo de forma desatendida. No cambia
ningún comportamiento actual; se referencia desde `SKILL.md` para no
perder la idea hasta que se decida invertir en ella.

## Qué ya es "agéntico" hoy — no es esto lo que falta

Dentro de una sesión activa, el ciclo ya ejecuta de forma autónoma y
multi-paso todo lo cubierto por la Aprobación 1 (DNS, Build, Release,
Desarrollo, UAT, correcciones dentro del límite) sin volver a preguntar.
Esto es maduro y no necesita rediseño — ver `orchestration-flow.md` y
`approval-envelope.md`.

## La brecha real: operación desatendida

Hoy, todo el monitoreo activo (`status_poll_interval_seconds`, esperar
Build/Release/rollout) requiere una sesión de Claude Code sostenida de
punta a punta. No existe:

1. Un mecanismo que envuelva el polling (`Wait-AdoClassicRun.ps1`,
   readback de AKS) en un loop de background/programado, para que la
   espera no dependa de una conversación activa.
2. Persistencia de estado entre "despertares" (qué app, qué plan/hash,
   en qué fase, último estado observado) si el proceso se corta o se
   reanuda más tarde.
3. Notificación al usuario únicamente en los puntos que importan
   (Aprobación 1, Aprobación 2, un error que exige replanificar) en vez
   de requerir que alguien esté mirando todo el tiempo.

## Piezas de la plataforma ya disponibles para esto

No hace falta inventar infraestructura nueva de scheduling — ya existen
primitivas genéricas de la plataforma que se podrían adaptar a este
dominio:

- Agentes en la nube programados por cron (skill `schedule` /
  `CronCreate`) para una corrida recurrente o de larga duración.
- Loops dinámicos que se autoprograman (skill `loop` / `ScheduleWakeup`)
  para el patrón "despertar cada N minutos, chequear estado, seguir
  esperando o notificar".
- Notificación al usuario en el punto de decisión (`PushNotification`).

## Alcance estimado del trabajo pendiente

Es una **capa de orquestación adicional**, no un rediseño de los
dominios existentes — ningún plan, hook, script `Apply-*` ni regla de
aprobación cambiaría. Comparable en esfuerzo a uno de los 3 gaps de
dominio que se llenaron en el refactor de 2026-09-07 (capacidad AKS, DNS
determinista, polling ADO), no a todo ese refactor.

Piezas concretas a construir cuando se decida avanzar:

1. Un formato de "estado del ciclo" persistente (JSON, por ejecución) que
   capture: `INPUT` resuelto, hash del plan aprobado, fase actual,
   último estado observado por dominio, timestamps. Requiere revisar la
   decisión actual en
   `.claude/rules/orchestrate-application-pipeline-cycle/security.md` §
   "Archivos locales de este dominio" (hoy dice explícitamente que este
   dominio no tiene su propio `.local/` — habría que decidir si esto
   amerita crear uno, o si el estado vive junto al archivo de
   `docs/pipeline-cycles/<app>.md` correspondiente).
2. Un wrapper que, en cada "despertar" programado, llame una sola vez a
   `Wait-AdoClassicRun.ps1` / al readback de AKS correspondiente, compare
   contra el estado persistido, y decida: seguir esperando, avanzar de
   fase, o notificar.
3. Definir explícitamente qué notifica y qué no — nunca una notificación
   por cada poll intermedio, solo en cambios de fase o en las 2
   aprobaciones.
4. Mantener sin excepción el modelo de aprobación actual: esta capa
   nunca ejecuta Producción ni una eliminación sin la aprobación
   separada correspondiente — el modo agéntico cambia **cuándo se
   interrumpe al usuario**, nunca **si se le pide permiso**.

## Conclusiones de la primera corrida real (`app-sso`, 2026-09-07/08)

Corrimos el ciclo completo de punta a punta (DNS, Fase 1/2 de ADO,
Desarrollo y UAT reales, ambos `Despliegue completado` confirmado en
AKS) para validar tiempos reales antes de invertir en esta hoja de ruta.
El resultado **matiza la prioridad**, no solo confirma la brecha.

### Desglose real de tiempo

- **Espera real de máquinas (lo único que "modo agéntico" ahorra)**: baja.
  4 Builds reales, ~3 min cada uno; los 2 despliegues reales
  (Desarrollo/UAT) terminaron en 1-2 ciclos de polling (≤120-240s) cada
  uno. Total aproximado: **15-20 minutos** de espera genuina en
  sistemas externos.
- **Descubrimiento, depuración y decisiones humanas**: alta —
  claramente la mayor parte del tiempo total de la sesión. Se
  encontraron y corrigieron 3 bugs reales de la plataforma (ver memorias
  `orchestrator-approval1-execution-bundling-bug`,
  `ado-canonical-model-family-mismatch`,
  `ado-release-containerregistry-macro-bug`), más 2 decisiones que
  **exigían criterio humano real**, no automatizable: a qué grupo de DNS
  de Producción pertenece la app (`grupomontecristo.com` vs
  `buklo.dev` — sin señal técnica), y confirmar de qué app real venía el
  modelo canónico equivocado.

### Implicación — dónde el modo agéntico realmente rinde

**No es "onboarding de una app nueva desde cero"** — ese caso siempre va
a tener puntos de decisión que un humano debe resolver (convención de
DNS, secretos reales pendientes, confirmar familia del modelo), y el
tiempo de espera de máquinas es una fracción menor del total. Automatizar
eso en background no ahorraría mucho, y arriesgaría tomar una decisión
de producto sin criterio humano.

**El caso con mejor retorno es el reuso de un pipeline ya probado y
correcto** — redesplegar una app que YA tiene su Build/Release
funcionando (ej. una corrida futura de `app-sso` una vez tenga su
`.env` real, o cualquier otra de las 6 hermanas ya construidas): ahí
prácticamente todo el tiempo es espera de Build/Release/rollout sin
ningún punto de decisión, exactamente el patrón que un loop de
background puede manejar solo, notificando únicamente al final o ante
un fallo real.

### Gaps confirmados en esta misma corrida (no hipotéticos)

- Los agentes `-diagnoser` (AKS/Cloudflare/ADO) confirmaron 3 veces en
  esta sesión que no tienen `Bash`/`PowerShell`/MCP — un loop de
  background necesita un agente con herramientas en vivo garantizadas
  (`-operator`, o la sesión principal), nunca un `-diagnoser`, para la
  fase de polling.
- Las piezas concretas que ese loop llamaría **ya existen y están
  probadas contra infraestructura real** gracias a esta corrida:
  `Wait-AdoClassicRun.ps1`, `Get-AdoClassicLatestRelease.ps1`,
  `Get-AdoClassicReleaseInstance.ps1`. No hace falta construirlas — ya
  están.

### Recomendación revisada

1. No priorizar automatizar el *onboarding* de apps nuevas en
   background — ese caso seguirá necesitando un humano en el loop por
   las decisiones de producto que aparecen, no solo por limitaciones
   técnicas.
2. Si se avanza con modo agéntico, empezar acotado al caso de
   **redeploy de una app ya configurada y sin cambios de alcance** —
   ahí sí el ahorro es real y el riesgo de decisión equivocada es bajo.
3. Dejar pasar 1-2 corridas reales más de onboarding (quedan 4 apps de
   `buklo-web` sin pipeline, según memoria) antes de confiar en que el
   camino "sin bugs nuevos" es lo bastante estable para dejarlo
   desatendido, aunque sea solo para el caso de redeploy.

## Decisión pendiente del usuario

Este documento no autoriza ni programa nada. Antes de implementarlo,
decidir explícitamente: qué tan larga puede ser una corrida desatendida
sin supervisión, dónde vive el estado persistido, y si aplica a los 3
dominios (ADO/Cloudflare/AKS) o se empieza solo por el más lento
(Build/Release/rollout de Azure DevOps + AKS).
