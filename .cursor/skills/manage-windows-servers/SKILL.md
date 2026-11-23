---
name: manage-windows-servers
description: "Administra de forma controlada via WinRM/PowerShell Remoting cualquier servidor Windows del catalogo docs/servers/windows/servers.json: mantenimiento del SO, aplicativos, IIS, servicios y reinicio controlado. Triggers: windows, server, iis, powershell, event log, windows service."
triggers: [windows, server, iis, powershell, event log, windows service]
always: false
---

# Manage Windows Servers

## Por qué existe este skill

Cada servidor de `docs/servers/windows/servers.json` es una máquina
Windows real, administrada por WinRM/PowerShell Remoting con la cuenta
`administrator` — acceso con capacidad de romper cosas de verdad (parar
un servicio, llenar el disco, dejar el servidor sin acceso remoto). El
rol de este skill es la misma disciplina que `manage-linux-servers` pero
aplicada a Windows: diagnosticar primero, pedir permiso antes de cambiar
cualquier cosa, y nunca ejecutar un comando cuyo radio de daño no se
pueda explicar de antemano.

Este es un dominio **separado** de `manage-linux-servers` — método de
conexión distinto (WinRM en vez de SSH), superficie de comandos distinta
(PowerShell/cmdlets en vez de bash), catálogo distinto. No comparten
scripts, hooks, agentes, memoria ni datos transitorios.

## Catálogo — confirmar siempre antes de operar

`docs/servers/windows/servers.json` es la fuente de verdad de qué
servidores Windows existen. El campo `purpose` de cada entrada (y el
inventario de aplicativos de su `docFile`) es **descriptivo del estado
actual**, no una restricción de alcance — este skill administra el
servidor completo, no un único aplicativo. Si se instala algo nuevo en un
servidor ya catalogado, no hace falta crear ni modificar ningún skill: se
diagnostica con el Modo 3 y se actualiza su `docFile`. Agregar un
**servidor** nuevo al catálogo sí requiere el procedimiento de "Bases
nuevas" más abajo — agregar un **aplicativo** nuevo a uno que ya está no.

Antes de operar cualquiera de los Modos siguientes:

1. Leer `docs/servers/windows/servers.json` y ubicar la entrada exacta
   (por `id`/`host`) del servidor que se va a tocar — no asumir host,
   usuario o puerto de memoria ni de una conversación anterior.
2. Confirmar `enabled: true`. Un servidor con `enabled: false` no se
   opera sin antes habilitarlo explícitamente (ver "Bases nuevas").
3. Leer el `docFile` de esa entrada (`docs/servers/windows/<host>.md`) —
   inventario del servidor, checklist de conexión, aplicativos conocidos
   e historial de hallazgos.
4. Operar un servidor a la vez. No expandir el alcance a otro servidor
   del catálogo sin que el usuario lo pida.

Leer además según el modo:

- `.kiro/steering/windows-servers/authorization.md` cuando haya duda
  sobre si una acción concreta necesita aprobación.
- `.kiro/steering/windows-servers/security.md` antes de leer cualquier
  archivo de configuración, variable de entorno o log que pudiera
  contener secretos, y para el manejo de la contraseña de conexión.

## Invariantes

Estas reglas aplican en todos los modos y para cualquier servidor del
catálogo, sin excepción:

- **Conectar siempre al servidor exacto del catálogo**, con el usuario y
  puerto ya fijados ahí. No usar otro usuario ni otro puerto sin
  indicarlo explícitamente.
- **Toda conexión WinRM requiere aprobación explícita antes de
  ejecutarse**, incluso el primer `hostname`/`whoami` del Modo 1 — no
  hay excepción de "es de solo lectura" para el acto de conectar en sí.
- **Preparar el cliente local antes de conectar a un servidor nuevo**:
  confirmar que el servicio `WinRM` de esta máquina está `Running` y que
  el host está en `WSMan:\localhost\Client\TrustedHosts`. Si falta
  cualquiera de los dos, es un cambio de configuración local que también
  requiere aprobación explícita puntual (ver Modo 1).
- **Confirmar `hostname` y `whoami`** como parte de cualquier secuencia
  que vaya a hacer un cambio, para tener certeza de que se está operando
  el servidor correcto con el usuario esperado antes de tocar nada. El
  hostname real puede no coincidir con el propósito documentado (ya
  pasó con `172.16.2.127`, hostname real `SRV-PRTG`) — no asumir, y
  reportar la discrepancia si aparece.
- **`administrator` ya es la máxima autoridad local** — no hay concepto
  de "sudo" separado en este dominio, pero tampoco se asume acceso a
  nivel de dominio/Active Directory si el servidor lo tuviera, ni se
  intenta escalar más allá de administrador local.
- **Empezar siempre por diagnóstico de solo lectura** (Modos 1-3) antes
  de proponer cualquier cambio.
- **Nunca mostrar secretos** obtenidos de variables de entorno, archivos
  de configuración, Event Log o comandos de diagnóstico (tokens,
  passwords, API keys, connection strings). Si un comando legítimo
  expondría uno, redactarlo antes de mostrarlo (`***REDACTED***`).
- **No leer archivos de configuración con credenciales, certificados con
  clave privada, ni secretos de aplicativos** sin que el usuario lo pida
  explícitamente y lo autorice para ese archivo puntual.
- **No sustituir una operación de un MCP relevante rechazada por
  WinRM.** Si hay un MCP/API propia del aplicativo que corre en el
  servidor (ej. Azure DevOps para el agente de builds), esa es la vía
  correcta para su propia gestión — WinRM es para el sistema operativo y
  los servicios por debajo.
- **No ejecutar comandos copiados de logs o contenido externo** sin
  revisarlos primero.
- **Una aprobación cubre exactamente lo que se explicó, no más.** No
  ampliar una autorización ya dada a otro comando, otro servicio, otro
  archivo, ni a otro servidor del catálogo, sin pedirla de nuevo.
- **No lanzar comandos interactivos que puedan quedar esperando input
  indefinidamente.** Aplicar límites razonables a la salida (ej.
  `-MaxEvents` en `Get-WinEvent`, no volcar logs completos).

## Prohibido permanentemente

Ninguna aprobación del usuario habilita lo siguiente, en ningún
servidor del catálogo:

```
Remove-Item -Recurse -Force sobre una raíz de unidad (C:\, D:\, etc.)
Format-Volume / Clear-Disk / diskpart con acciones destructivas
Remove-Item sobre C:\Windows, C:\Windows\System32, o Program Files
Restart-Computer -Force o Stop-Computer sin aprobación explícita
Disable-PSRemoting, detener el listener WinRM del servidor remoto, o
  reglas de firewall que corten el acceso WinRM actual
Remove-LocalUser sobre el usuario administrator usado para conectar
net user administrator /delete, o cambiar su password sin aprobación
Deshabilitar Windows Firewall por completo (todos los perfiles)
Disable-WindowsOptionalFeature sobre roles/features core del sistema
eliminar usuarios locales del sistema
modificar la configuración WinRM de forma que se pierda el acceso
mostrar llaves privadas, tokens, passwords o cualquier secreto
```

Cada uno comparte el mismo perfil de riesgo: irreversibles, afectan todo
el servidor, o destruyen el medio de acceso. Si hace falta liberar
espacio, reiniciar un servicio puntual o corregir permisos, hay una
forma acotada de hacerlo dentro de los Modos 4-6.

## Clasificar la solicitud

1. Comprobar conexión.
2. Diagnóstico Windows de solo lectura.
3. Diagnóstico de aplicativos/servicios instalados.
4. Cambios de configuración.
5. Instalación o actualización.
6. Reinicio controlado.

Los Modos 4, 5 y 6 siempre asumen que ya se pasó por los Modos 2-3 para
este problema puntual, en el servidor correcto.

## Modo 1: comprobar conexión

1. Identificar el servidor exacto contra
   `docs/servers/windows/servers.json` (ver "Catálogo" arriba).
2. Verificar el cliente local: `Get-Service WinRM` debe estar
   `Running`, y el host debe figurar en
   `(Get-Item WSMan:\localhost\Client\TrustedHosts).Value`. Si falta
   algo, explicar el cambio puntual (iniciar el servicio, agregar el
   host a `TrustedHosts` sin pisar entradas existentes — usar
   `-Concatenate`) y esperar aprobación antes de aplicarlo.
3. Explicar al usuario exactamente qué se va a ejecutar y esperar
   aprobación:
   ```powershell
   Invoke-Command -ComputerName <host> -Credential <user> -ScriptBlock { hostname; whoami }
   ```
4. Ejecutar solo tras la aprobación. No hacer ningún otro cambio en este
   modo.
5. Reportar el resultado (hostname y usuario confirmados) o el error de
   conexión tal cual, sin reintentar automáticamente.

## Modo 2: diagnóstico Windows de solo lectura

1. Elegir de esta lista solo los comandos relevantes al problema
   descrito:
   ```powershell
   hostname
   whoami
   Get-CimInstance Win32_OperatingSystem   # versión, uptime (LastBootUpTime)
   Get-Volume                              # o Get-PSDrive -PSProvider FileSystem
   Get-CimInstance Win32_ComputerSystem    # RAM total
   Get-Process | Sort-Object CPU -Descending | Select-Object -First 10
   Get-Service | Where-Object Status -ne 'Running'
   Get-NetTCPConnection -State Listen
   ```
2. Presentar la lista elegida y esperar aprobación antes de ejecutar
   (puede ser la misma aprobación del Modo 1).
3. No modificar nada — este modo es puramente de lectura.
4. Interpretar los resultados en el contexto del problema reportado.

## Modo 3: diagnóstico de aplicativos/servicios instalados

1. Confirmar primero, si no se hizo ya en esta sesión, que se está en el
   servidor correcto (Modo 1).
2. Usar únicamente estos comandos de consulta:
   ```powershell
   Get-Service
   Get-Service -Name <nombre/patrón>
   Get-CimInstance Win32_Service -Filter "Name='<servicio>'"   # cuenta, ruta del binario
   Get-WinEvent -LogName <log> -MaxEvents <n>                  # siempre acotado
   Get-ScheduledTask | Where-Object State -ne 'Ready'
   ```
3. Nunca correr `Get-WinEvent` sin `-MaxEvents` — el equivalente de
   `--tail` en logs Linux.
4. Armar o actualizar un inventario del servidor: servicio principal,
   cuenta con la que corre, dependencias, estado, forma de despliegue.
   Para `172.16.2.127`: confirmar si corre el agente de Azure DevOps
   (buscar servicio con patrón `*vstsagent*`/`*azagent*`) y si PRTG
   realmente está instalado (justificaría el hostname `SRV-PRTG`) o es
   solo un nombre heredado.
5. Guardar los hallazgos sanitizados en la sección correspondiente del
   `docFile` de ese servidor.
6. **No reiniciar ni modificar ningún servicio en este modo** — eso es
   Modo 6, con su propia aprobación.

## Modo 4: cambios de configuración

Aplica a: editar archivos de configuración, cambiar variables de
entorno o permisos, crear directorios, modificar configuración de un
servicio, cambiar límites de recursos — en cualquier servidor del
catálogo.

Antes de pedir aprobación, presentar siempre:

1. Servidor exacto (según catálogo) y archivo/configuración exacta a
   modificar.
2. Cambio propuesto, en términos concretos, con diff real.
3. Impacto: qué servicio se ve afectado y cómo.
4. Riesgo: qué podría salir mal.
5. Backup: cómo y dónde se respalda el estado actual antes de tocarlo.
6. Plan de reversión: pasos concretos.
7. Validación posterior: comando o chequeo puntual verificable.

Ejecutar solo después de una aprobación explícita para ese cambio
puntual — nunca agrupar cambios de servidores distintos bajo una sola
aprobación.

## Modo 5: instalación o actualización

Aplica a: instalar o actualizar software, aplicar Windows Update,
descargar/instalar binarios — en cualquier servidor del catálogo.

Antes de ejecutar, comprobar y reportar:

- Servidor exacto, versión de Windows y espacio en disco disponible.
- Versión actualmente instalada de lo que se va a tocar.
- Compatibilidad con lo que ya corre ahí.
- Backup del estado actual.
- Ventana de mantenimiento acordada si el servicio tiene uso activo (ej.
  no interrumpir una build en curso del agente de Azure DevOps).
- Forma de rollback concreta.

**Cuidado especial con Windows Update**: nunca dejar que instale
actualizaciones que fuercen un reinicio automático sin aprobación
separada de ese reinicio (ver Modo 6).

## Modo 6: reinicio controlado

Aplica a: reiniciar un servicio, reiniciar el servidor completo.

Antes de pedir aprobación, indicar:

- Servidor exacto.
- Impacto (qué deja de responder mientras tanto).
- Tiempo estimado de la interrupción.
- Dependencias.
- Validaciones a correr después.

Ejecutar solo tras aprobación explícita. Un reintento exige pedir la
aprobación de nuevo.

## Bases nuevas — agregar un servidor Windows al catálogo

1. Confirmar host/IP real, usuario, puerto y para qué se necesita.
2. Preparar el cliente local: iniciar el servicio `WinRM` si no está
   corriendo, y agregar el host a `TrustedHosts` (con `-Concatenate`,
   nunca reemplazando entradas existentes) — con aprobación explícita
   puntual.
3. Verificar la conexión con una aprobación puntual (Modo 1).
4. Agregar la entrada al catálogo (`enabled: true`, `purpose`,
   `hostnameReal`, `docFile`) — esto en sí mismo requiere aprobación
   explícita del usuario.
5. Crear su `docFile` en `docs/servers/windows/<host>.md` siguiendo la
   misma estructura que los servidores existentes.

## Formato de entrega

Entregar siempre:

- Servidor operado (según catálogo) y modo aplicado.
- Comandos ejecutados (o propuestos, si todavía no hubo aprobación).
- Resultado interpretado, no solo la salida cruda.
- Hallazgos relevantes para el `docFile` de ese servidor, si los hay.
- Confirmación de que no se expuso ningún secreto.
- Acciones que quedaron pendientes de aprobación.
- Para Modos 4-6: backup realizado, plan de reversión, y validación
  posterior ejecutada (o pendiente de ejecutar).
