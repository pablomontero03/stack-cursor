# Patrones — cloudflare-diagnoser

## Convención de nombres DNS de apps `buklo-web` (frontends Nx/Angular)

Confirmado 2026-09-07 a partir de evidencia local (manifiestos K8s ya
generados por el dominio de Azure DevOps Pipelines para
`buklo-logistics-web`, y la memoria cross-dominio
`ado-buklo-web-frontend-deploy-pattern` de ese otro proyecto de agentes) —
no verificado todavía contra el estado real de Cloudflare en esa sesión
por falta de herramienta de ejecución (ver `debugging.md`).

- **Dev/UAT**: hostname `<nombre-app-sin-prefijo-'app-'>-web-{dev,uat}.gmontecristo.com`
  (ej. `logistics-web-dev.gmontecristo.com` para la app `app-logistics`,
  NO `app-logistics-web-dev.gmontecristo.com`). El prefijo `app-` del
  nombre de carpeta/pipeline se **descarta** en el hostname público.
- **Producción — el patrón real diverge de `grupomontecristo.com`**: las
  apps hermanas (`shell-web`, `hr-web`, `ontology-web`, `ticketing-web`,
  `app-logistics`) usan en Producción `<nombre>-web.buklo.dev`
  (`ingressClassName: internal-ingress`, no una IP pública de AKS
  directamente comparable a un registro `A` de `grupomontecristo.com`).
  Un pedido de zona/registro de Producción en `grupomontecristo.com` para
  una app `buklo-web` nueva **contradice la convención ya usada por sus 5
  apps hermanas** — reportarlo siempre como conflicto de nomenclatura
  explícito, nunca asumir cuál de los dos patrones es el correcto ni
  "corregirlo" silenciosamente en el reporte.
- Esta convención es específica de `buklo-web` (monorepo Angular/Nx,
  proyecto ADO `Buklo`/`DevOps`). No se confirmó (ni se debe asumir) que
  aplique a otros monorepos o dominios de aplicación.

## Segunda corroboración (`app-sso`, 2026-09-07) — mismo patrón, mismo conflicto

El pedido de descubrimiento para `app-sso` llegó con exactamente el mismo
patrón Dev/UAT (`sso-web-dev.gmontecristo.com`,
`sso-web-uat.gmontecristo.com` — coincide con la convención de arriba) y
el mismo tipo de pedido de Producción en `grupomontecristo.com`
(`sso-web.grupomontecristo.com`) que ya se había marcado como conflicto
de nomenclatura para `app-directory`. Sigue sin verificarse contra el
estado real de Cloudflare (ver `debugging.md` — recurrencia de falta de
`Bash`/MCP), pero la repetición del mismo pedido de Producción en la zona
"equivocada" para una segunda app en el mismo día sugiere que puede ser
una convención deliberada nueva del usuario para esta tanda de apps (o un
copy-paste del mismo template de intake) — no necesariamente un error
aislado. Igual criterio: reportar el conflicto explícito, nunca asumir
cuál de los dos patrones (`buklo.dev` de las apps hermanas vs.
`grupomontecristo.com` pedido ahora dos veces) es el correcto.
