---
name: azure-finops-analyst-debugging
description: Aprendizajes de diagnostico reutilizables del agente azure-finops-analyst (fallas de Cost Management/Monitor/Advisor, permisos, datos faltantes).
metadata:
  type: project
---

# Depuración — azure-finops-analyst

Ningún incidente real registrado todavía (agente recién creado,
2026-09-03). Formato para futuras entradas:

- **Síntoma observado**: qué falló o qué se veía raro.
- **Causa raíz confirmada**: con evidencia (no una hipótesis).
- **Solución validada**: qué se hizo, sanitizado.
- **Comprobación segura**: cómo se confirmó sin exponer datos sensibles.
- **Falsos positivos**: intentos que no eran la causa real.

## Nota conocida de diseño (no es un incidente)

`Invoke-AzureCostQuery.ps1` nunca ve el código HTTP real de una falla
(401/403/429/5xx) — `Invoke-AzureCliJson` descarta stderr por completo
(`2>$null`), así que el script solo puede reportar "la consulta falló o
no devolvió datos" de forma genérica. Esto es intencional (nunca expone
headers/tokens), pero significa que para diagnosticar la causa real de
una falla (permiso faltante vs. throttling vs. servicio caído) hay que
reproducir el `az rest` a mano fuera de este flujo, no confiar en el
mensaje del script.
