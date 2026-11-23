# Patrones — windows-server-diagnoser

Categorías de fallo que ya usa el proceso de este agente (ver su
frontmatter/instrucciones): recursos del host (CPU, memoria, disco),
servicio de Windows caído (`Get-Service`), aplicativo específico (cuenta
de servicio, ruta de binario, dependencia — via `Get-CimInstance
Win32_Service`), red (`Get-NetTCPConnection`), Event Log
(`Get-WinEvent`), o configuración (tarea programada, archivo de config
con valor incorrecto). Patrones reales confirmados (qué causa raíz es
más frecuente en cada servidor puntual) se agregan solo cuando el agente
los confirme en diagnósticos reales — todavía no hay ninguno.
