---
name: azure-finops-analyst-patterns
description: Patrones reutilizables, convenciones y decisiones tecnicas confirmadas del agente azure-finops-analyst.
metadata:
  type: project
---

# Patrones — azure-finops-analyst

## Convenciones del dominio

- Suscripción objetivo fija: `69dc43ec-5f24-4203-9239-a8d0f8506d44`
  (Hospital Metropolitano). Todos los scripts la validan explícitamente
  antes de consultar — nunca confiar en la suscripción "activa" por
  defecto de la sesión `az`.
- Todo dato financiero real vive bajo `.local/azure/finops/{raw,
  normalized,reports,charts,executions}/` — nunca en `docs/`, memoria de
  agentes, ni archivos versionados.
- `New-AzureFinOpsReport.ps1` nunca suma valores de monedas distintas —
  si detecta más de una moneda en las filas, deja `total = null` y agrega
  una advertencia explícita en el manifiesto, en vez de calcular un total
  mezclado y potencialmente engañoso.
- Un `Timeframe` "a la fecha" (`MonthToDate`/`WeekToDate`/
  `BillingMonthToDate`) siempre se marca `isPartialPeriod = true` con una
  advertencia de comparabilidad — nunca comparar directamente contra un
  período completo sin normalizar.

## Gotcha de PowerShell 5.1 confirmado en este dominio (aplica a scripts futuros)

Asignar el resultado de un bloque `if/else` a una variable, cuando la
rama ejecutada produce un array de UN SOLO elemento vía `@(...)` interno,
"desenvuelve" ese array a su elemento escalar antes de la asignación —
PowerShell colecciona la salida completa del `if/else` y, si solo fluyó
UN objeto (aunque ese objeto sea en sí un array de 1), no lo vuelve a
envolver. Encontrado y corregido dos veces durante la construcción de
este dominio (`Invoke-AzureCostQuery.ps1` con `$currencies`,
`Get-AzureCostRecommendations.ps1` con `$advisorRecommendations`).

**Fix**: envolver TODO el `if/else` con un `@()` exterior, nunca solo la
rama interna:

```powershell
# MAL -- se puede desenvolver a escalar si la rama produce 1 elemento
$x = if ($cond) { @($items | ForEach-Object { ... }) } else { @() }

# BIEN -- @() exterior garantiza array sin importar cuantos elementos salgan
$x = @(if ($cond) { $items | ForEach-Object { ... } })
```

Relacionado con el "array unwrapping" ya documentado para otros dominios
de este repo (ver memoria de usuario `ado-e2e-rebuild-test-2026-08-26` y
`ado-classic-update-plan-encoding-bugs-2026-09-02`) — misma familia de
bug, disparador ligeramente distinto (aquí es el `if/else` como
expresión, no un pipeline directo).

## Excel sin dependencia forzada

`New-AzureFinOpsReport.ps1` solo genera `.xlsx` si `Get-Module
-ListAvailable -Name ImportExcel` encuentra el módulo ya instalado. Nunca
lo instala automáticamente (sería una instalación de software no
aprobada) — si falta, omite el formato y deja una advertencia clara en el
manifiesto. El CSV siempre está disponible como alternativa.

## Gráficos sin dependencias externas

Los gráficos (Línea, Barras, Pareto) se generan como SVG construido a
mano dentro de `New-AzureFinOpsReport.ps1` — sin librería ni módulo
adicional. Útil como patrón reutilizable para cualquier otro dominio de
este repo que necesite un gráfico simple sin agregar una dependencia
nueva.
