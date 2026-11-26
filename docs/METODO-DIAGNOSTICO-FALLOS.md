# Método de diagnóstico de fallos (infra-first)

> Disciplina para diagnosticar bugs y regresiones de forma ordenada, sin saltar a
> adivinar ni quedarse ciclando. Destilado del skill público
> `mattpocock/skills/diagnosing-bugs` (2026-10-02) y adaptado a este stack.
> **No instalamos el skill** — rescatamos el método.

## Principio

Primero conseguí **reproducir el fallo a voluntad**; recién entonces teorizás. Un buen
loop reproducible resuelve el 90% del problema. Lo contrario —leer manifests/código
para armar una teoría sin poder reproducir— es el error #1.

## Alcance en este stack

- Las fases **1-4 (loop → minimizar → hipótesis → instrumentar)** aplican a CUALQUIER
  diagnóstico: pods, pipelines ADO, DACPAC, DNS, VGs, n8n, servidores.
- Las fases **5-6 (fix + test de regresión)** aplican **solo cuando el bug es de
  INFRA** (manifest, recursos k8s, puerto, VG, Build/Release, ingress, DNS). Si el
  bug es de **código de la app** (lógica, SQL, bug de NestJS), se **reporta con
  evidencia, no se corrige** (regla `autofix_infra_errors_no_approval`).
- **Redactar secretos siempre** antes de mostrar comandos/outputs: `<REDACTED>`.
  Construir loops contra variables de entorno para que la credencial nunca aparezca.

---

## Fase 1 — Loop reproducible (ESTO es el método)

Un **comando** que corras una y otra vez y que se ponga **rojo** cuando el bug
aparece, verde cuando no. Debe:
- tocar el camino real del bug y afirmar el **síntoma exacto** que reportó el usuario
  (no "corre sin error"),
- ser **determinista** (mismo veredicto cada vez; para bugs intermitentes, subir la
  tasa de reproducción a loop ×100 / stress hasta que sea depurable),
- ser **rápido** (segundos, no minutos),
- correr **desatendido**.

Formas de construirlo, en orden: test que falla → script curl/HTTP contra el server →
CLI con fixture → script headless de browser → replay de una traza capturada → harness
mínimo (un servicio, deps mockeadas) → loop de fuzzing → harness de bisección →
loop diferencial (viejo vs nuevo). Para infra: `kubectl` en loop sobre el pod,
pod efímero que corre el mismo script, re-encolar un build con un cambio aislado.

> Lección propia: para un CronJob que falla y borra sus pods en segundos, usar un
> **pod efímero** (`kubectl run --restart=Never`) con el MISMO script en vez de
> perseguir `kubectl logs job/<x>`.

**Si NO podés construir un loop:** decílo explícitamente, listá lo que intentaste, y
pedí al usuario (a) acceso al entorno que lo reproduce, (b) un artefacto capturado
redactado, o (c) permiso para instrumentación temporal. **No teorices sin loop.**

## Fase 2 — Reproducir + minimizar

Corré el loop, vé el fallo. Confirmá que es **el síntoma del usuario** (no otro
cercano). Luego **achicá** el escenario al mínimo que sigue rojo: quitá inputs,
config, pasos **de a uno**, re-corriendo tras cada corte. Listo cuando **cada pieza
restante es imprescindible** (quitar cualquiera lo pone verde).

## Fase 3 — Hipótesis falsables (rankeadas)

Antes de tocar nada, enumerá **3-5 causas posibles rankeadas**, cada una con una
**predicción comprobable**:

> "Si la causa es X, entonces cambiar Y hace desaparecer el bug / cambiar Z lo empeora."

Si no podés enunciar la predicción, es corazonada: descartala o afilala. Mostrá la
lista rankeada al usuario antes de probar (puede re-rankear al instante: "justo
tocamos el VG ayer"). No bloquear si está ausente; seguí con tu ranking.

## Fase 4 — Instrumentar una variable a la vez

Cada sonda mapea a UNA predicción de la Fase 3. **Cambiá una sola cosa.** Preferir
debugger/REPL > logs en los límites que distinguen hipótesis > nunca "loguear todo y
grep". Taggear logs temporales con prefijo único (`[DEBUG-a4f2]`) para limpiarlos con
un grep. Para regresiones de **rendimiento**: medir baseline primero (timing/profiler/
query plan) y bisecar; los logs suelen ser el enfoque equivocado.

## Fase 4-bis — NO ciclar: ampliar el espacio de hipótesis

**Regla dura.** Si las 3-5 hipótesis iniciales se agotan sin resolver:
- **NO** re-probar las mismas ni insistir en el mismo enfoque con variaciones menores
  (eso es el loop de parcheo incremental que hay que evitar).
- **SÍ** usar la evidencia nueva que recogiste en las fases 2-4 para **generar
  hipótesis nuevas** que antes no veías.
- **SÍ** cambiar de enfoque de raíz: otra herramienta, otro punto de entrada, otra
  capa (de la app al nodo, del pod al VG, del pipeline al runner, de la red al DNS).
- Si tras un enfoque fallido dos veces no hay progreso, **diagnosticar la causa raíz
  del porqué el enfoque no funciona** antes de seguir — no acumular parches.
- **Escalar al usuario** solo ante un muro real: permiso que solo él concede, sistema
  que un humano debe operar, o decisión de una sola vía. La escalación es
  no-bloqueante: parqueá este ítem y seguí con otros.

El objetivo es **converger o cambiar de rumbo**, nunca orbitar las mismas 3 ideas.

## Fase 5 — Fix + test de regresión (solo bugs de INFRA)

Escribí el test de regresión **antes** del fix, si hay un **seam correcto** (que
ejercite el patrón real del bug en el call site). Si no hay seam correcto, **eso
mismo es el hallazgo** — anotalo. Con seam: repro mínimo → test que falla → fix →
test que pasa → re-correr el loop de Fase 1 sobre el escenario original completo.
En infra, el equivalente al "test" es el **readback**: PUT/patch → leer el estado
vivo y confirmar que el síntoma desapareció.

## Fase 6 — Cleanup

- [ ] El repro original ya no reproduce (re-correr el loop de Fase 1).
- [ ] Readback/test de regresión pasa (o se documenta la ausencia de seam).
- [ ] Instrumentación `[DEBUG-...]` removida (`grep` del prefijo).
- [ ] Prototipos descartables borrados.
- [ ] La hipótesis que resultó correcta queda escrita en el commit/PR/reporte, para
      el próximo que diagnostique.

---

## Fuente

- Skill `mattpocock/skills/diagnosing-bugs` (metodología genérica, agnóstica de lenguaje).
- Adaptado a infra-first + regla anti-ciclo + regla de oro del stack (código de app se
  reporta, no se corrige; secretos redactados).
