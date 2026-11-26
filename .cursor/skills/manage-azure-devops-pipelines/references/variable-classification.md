# Clasificación de variables al usar otro pipeline como fuente

Referenciado por `.cursor/rules/azure-devops.mdc`
§ "Clasificación automática y copia a un plan nuevo" y por la sección
de seguridad (secretos en archivos locales). Se usa al
comparar Builds/Releases/Variable Groups existentes (fuente) contra un
pipeline nuevo que se está planificando — típicamente al reutilizar la
configuración de pipelines AKS similares.

Antes de clasificar cualquier variable de una fuente, esa fuente ya tuvo
que presentarse y aprobarse una sola vez (pipeline/VG, proyecto, motivo,
tipo de información) según `authorization.md` — este documento no cambia
esa regla, solo qué hacer con lo ya leído.

## Las 9 categorías

1. **No secreta y reutilizable** — mismo significado en cualquier app
   (ej. `dockerRegistryUrl`, nombre del namespace por ambiente si sigue la
   misma convención). Puede copiarse automáticamente al plan nuevo sin
   preguntar.
2. **No secreta pero específica de otra aplicación** — el nombre es
   genérico pero el VALOR pertenece a la app origen (ej. un `appName` o
   `servicesname` con el nombre de la app vieja). Nunca se copia el valor
   tal cual; se presenta como recomendación ("esta variable existe en la
   fuente con valor `X`, para la app nueva probablemente deba ser `Y`")
   antes de que el usuario decida.
3. **Secreta** (`isSecret=true` en la fuente, o nombre coincide con la
   lista de nombres sensibles de `ado-secret-scan-lib.ps1`) — nunca se
   espera ni se intenta recuperar su valor real desde Azure DevOps (la
   API nunca lo devuelve para variables secretas; y aunque lo devolviera,
   ver la prohibición permanente de nunca copiar un secreto entre apps).
   Se conserva solo: nombre, alcance, `isSecret=true`, fuente (de dónde se
   vio esta variable). Ver más abajo "Manejo de secretas" para la lógica
   de reutilización.
4. **Referencia a Variable Group** — la variable no es un valor suelto,
   es el nombre de un Variable Group linkeado. Se registra el nombre del
   VG; evaluar si el mismo VG puede reutilizarse (linkearlo también en el
   pipeline nuevo) en vez de copiar sus variables una por una.
5. **Referencia a Key Vault** — variable cuyo origen real es un secreto de
   Azure Key Vault vinculado a un Variable Group. Se registra el nombre
   del Key Vault + nombre del secreto; mismo criterio de reutilización que
   la categoría 4.
6. **Variable propia del ambiente** — su valor cambia legítimamente por
   ambiente (Desarrollo/UAT/Producción) aunque el NOMBRE de la variable
   sea el mismo entre ambientes (ej. `aksClusterName`, `namespace`). Se
   documenta el valor por ambiente en la matriz, nunca se copia un solo
   valor para los tres ambientes.
7. **Variable que debería convertirse en ConfigMap** — valor no secreto
   pero que Kubernetes debería inyectar como ConfigMap en vez de como
   variable de pipeline (config de aplicación que cambia sin necesitar un
   nuevo deploy). Se marca como recomendación, no se ejecuta ningún
   cambio real sin aprobación aparte.
8. **Variable que debería convertirse en Kubernetes Secret** — igual que
   la 7 pero para valores sensibles que hoy son variable de pipeline y
   deberían vivir como `Secret` de Kubernetes en el namespace destino.
9. **Variable que debería sustituirse por una Service Connection** —
   típicamente credenciales de registry/nube (`containerRegistryPassword`
   y similares) donde existe una Service Connection ya configurada que
   elimina la necesidad del secreto suelto por completo — ver
   `security.md` § "Antes de usar un secreto real: buscar la alternativa
   segura".

## Qué se copia automáticamente y qué se presenta primero

| Categoría | Acción |
|-----------|--------|
| 1 | Copiar al plan sin preguntar. |
| 2 | Presentar recomendación; copiar solo si el usuario confirma el valor correcto para la app nueva. |
| 3 | Nunca copiar un valor (no existe valor que copiar). Ver "Manejo de secretas". |
| 4, 5 | Presentar como candidato a reutilización del mismo VG/Key Vault; no crear uno nuevo si el existente ya cubre el caso. |
| 6 | Copiar la ESTRUCTURA (nombre + que varía por ambiente) sin inventar valores por ambiente que no se confirmaron. |
| 7, 8, 9 | Nunca copiar directo — son recomendaciones de rediseño, se presentan para decisión del usuario, no se aplican solas. |

## Manejo de secretas (categoría 3)

- Intentar primero reutilizar: mismo Variable Group ya existente, mismo
  Key Vault, misma Service Connection, o mismo Kubernetes Secret — en ese
  orden de preferencia (ver `security.md` § "Alternativas a mantener el
  archivo de texto").
- No pedirle al usuario que vuelva a escribir un secreto que ya existe en
  un recurso compartido vinculable — vincular el recurso en vez de crear
  una variable nueva.
- Si el secreto NO existe todavía en ningún recurso reutilizable,
  reportar únicamente ese faltante puntual (nombre + alcance + dónde
  falta) — no bloquear la presentación del resto de la matriz por un solo
  secreto pendiente.
- Si hace falta un valor nuevo, seguir el flujo de
  `${ADO_SECRET_*}`/helper de archivo local ya documentado — nunca pedir
  que se pegue el valor en el chat.

## Formato de salida esperado

La matriz consolidada (ver `authorization.md` § "Administración de
Proyectos" en `CLAUDE.md` para el caso concreto en curso) debe incluir por
variable: nombre, fuente, valor (solo si no es secreta), `isSecret`,
alcance, categoría (1-9), y acción recomendada (reutilizar / adaptar /
ConfigMap / Secret / Variable Group / Service Connection). Presentar la
matriz completa antes de crear o modificar cualquier recurso real.
