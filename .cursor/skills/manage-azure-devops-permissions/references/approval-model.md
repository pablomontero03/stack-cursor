# Modelo de aprobación — resumen operativo

Fuente de verdad completa: `.claude/rules/azure-devops-permissions/authorization.md`.
Este archivo es un resumen para consulta rápida durante el flujo, no la
reemplaza.

## Sin aprobación adicional

Lecturas, inventarios, generación de planes, dry-runs, validaciones y
pruebas offline. `Export-AdoPermissionsSecurityInventory.ps1`,
`New-AdoPermissionsPlan.ps1`, `Test-AdoPermissionsPlan.ps1`,
`New-AdoPermissionsDeletePlan.ps1`, `Test-AdoPermissionsDeletePlan.ps1` y
el arnés de tests corren sin pedir nada.

## Una tarjeta para el plan no destructivo completo

1. Presentar el plan completo: proyectos, grupos (crear/reusar/bloqueado),
   descripciones `actual → deseado`, miembros a agregar, matriz aplicada
   por repositorio/rama, advertencias de herencia y de lockout.
2. Invocar `Apply-AdoPermissionsPlan.ps1` en el mismo turno — el hook
   fuerza una única tarjeta de aprobación nativa para ESE plan
   (identificado por su `validationHash`).
3. Ninguna pregunta adicional por operación individual dentro de esa
   corrida.

La aprobación cubre únicamente el plan por su hash exacto — no otro
proyecto, no un reintento tras regenerar el plan, ninguna eliminación.

## Eliminaciones — siempre aparte

`New-AdoPermissionsDeletePlan.ps1` → `Test-AdoPermissionsDeletePlan.ps1` →
`Apply-AdoPermissionsDeletePlan.ps1` (tarjeta separada, respaldo de solo
lectura obligatorio antes del DELETE). Nunca se agrupa con el plan
principal ni con otra eliminación.

## Grupos nuevos: la creación no arrastra su membresía/ACE

Cuando un plan crea un grupo nuevo, sus miembros y ACE quedan en
`deferredAfterCreation` — no forman parte de la aprobación de ESE plan.
Completar ese grupo exige un plan nuevo (con su propia aprobación) después
de confirmar el descriptor real por readback. Ver "Limitación de diseño
deliberada" en `SKILL.md`.
