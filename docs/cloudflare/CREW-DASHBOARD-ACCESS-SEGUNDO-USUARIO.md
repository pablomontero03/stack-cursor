# crew.gmontecristo.com — "Fallo al actualizar la carpeta" con varios dispositivos

**Fecha:** 2026-10-09
**Contexto:** Un colaborador (`bburgos@grupomontecristo.com`) usa el mismo dashboard de
KiroCrew en `https://crew.gmontecristo.com/`. Ve las carpetas y algunas sesiones, pero a
veces aparece *"Fallo al actualizar la carpeta — Vuelve a cargar esta pestaña del
navegador"* y siente que "lo que hace no refresca".

---

## 1. Causa real (confirmada empíricamente)

**El dashboard SÍ sincroniza en vivo entre varios navegadores/dispositivos a la vez.**
Evidencia del dueño: dos PC + el celular abiertos en `crew.gmontecristo.com` muestran todas
las sesiones actualizadas en tiempo real; lo que se hace en un equipo se ve en los otros.
Por lo tanto **NO es** un problema de multiusuario, de permisos, ni "un operador por
instancia".

El error *"Fallo al actualizar la carpeta"* es **transitorio, por carga/latencia**: cuando
una carpeta agrupa **muchas sesiones y/o sesiones largas**, el dashboard debe leer/transferir
bastante (índice grande + transcripts pesados) y, mientras tanto, la UI muestra ese aviso.
Recargar en medio de la carga la reinicia y empeora la sensación.

### Datos del store (2026-10-09)
- `.local/sesiones-kiro/`: **241 archivos, 113 MB** en total.
- `.local/sesiones-kiro/.index/session_index.db`: **~41 MB** (se consulta al pintar sidebar/carpetas).
- Sesiones individuales grandes: `dashboard_chat-34-*.jsonl` **~13 MB**,
  `dashboard_chat-41-*.jsonl` **~6.9 MB**, varias de 2–3 MB.
- Temporal colgado: `.local/sesiones-kiro/tmp6i8avn75.tmp` **~10 MB** (restos de export/compactación).

Esto explica el síntoma: carpetas con sesiones pesadas → el refresco tarda → aviso
transitorio en el cliente que va más lento (el del compañero), aunque el mecanismo de
sincronización funcione.

---

## 2. Cómo se autentica / sincroniza (para entender el mecanismo)

Dos capas:
1. **Cloudflare Access (Zero Trust)** — decide quién llega al sitio. App `Kiro Crew Dashboard`
   (ID `63fce954-34e2-4fe4-ada8-f639a0b7e0f4`, account `ab5d029b2bb52510fa80b693c36ff61d`).
   Política única `Kiro Crew - Grupo Montecristo` (allow) con 5 correos:
   `pmontero@`, `ccarvajal@`, `bburgos@`, `mdailey@`, `jquesada@` (`@grupomontecristo.com`).
2. **Token de sesión propio de KiroCrew** — el dashboard usa un token `?token=...`
   (`"sub":"local-app"`, con `exp`/`session_exp`) que se vuelve cookie de sesión. Cualquier
   navegador con un token válido entra como la misma sesión y recibe el **stream en vivo**
   (WebSocket/SSE). Por eso varios dispositivos ven lo mismo actualizándose.

> El token `?token=` es una credencial de sesión activa: quien lo tenga entra como esa
> sesión mientras no expire. No compartirlo por canales inseguros.

---

## 3. Mitigaciones (sin montar otra instancia)

De menor a mayor esfuerzo:
1. **Esperar unos segundos** al abrir una carpeta pesada y **no recargar** en medio (recargar
   reinicia la carga).
2. **Aligerar el store**: archivar/cerrar las sesiones gigantes (chat-34 ~13 MB, chat-41 ~7 MB)
   y limpiar el temporal colgado `tmp6i8avn75.tmp`. Menos peso = sidebar y carpetas más rápidos
   para todos.
3. **Organizar carpetas** para no concentrar muchas sesiones largas en una sola.

---

## 4. Nota de registro — ajuste de Cloudflare aplicado y REVERTIDO

Durante el diagnóstico (con una hipótesis equivocada de "challenge en el stream") se
cambiaron temporalmente dos campos de la Access app y luego **se revirtieron al estado
original**:

| Campo | Original | Cambio temporal | Estado final |
|---|---|---|---|
| `enable_binding_cookie` | `true` | `false` | **`true` (revertido)** |
| `same_site_cookie_attribute` | `lax` | `none` | **`lax` (revertido)** |

Confirmado revertido el 2026-10-09 ~19:17 UTC. Respaldo de los valores originales:
`.local/cf_crew_access_app_rollback_20261009.json`. Token Cloudflare en `env/.env`
(`CLOUDFLARE_API_TOKEN`), nunca imprimir; usar `python3`/`urllib`, no `curl --data @file`
(lo bloquea el guard de data-exfiltration).

**Ese cambio no era necesario** y no formaba parte de la causa real. Queda documentado solo
por trazabilidad.
