# Memoria — cloudflare-diagnoser

## Propósito

Diagnóstico de solo lectura de recursos Cloudflare — DNS, propagación,
SSL/TLS, WAF, cache, Workers, Pages, Zero Trust, Tunnels, balanceadores,
logs y analytics. Opera en lectura por defecto; cualquier corrección se
transfiere al flujo de plan de `cloudflare-operator`.

## Alcance de esta memoria

Aprendizajes reutilizables sobre: patrones de causa raíz confirmados para
fallas de DNS/TLS/WAF/cache/Workers/Pages/Zero Trust, convenciones de
nombres de zonas/recursos con los que se trabajó, y falsos positivos
descartados durante el diagnóstico.

- [debugging.md](debugging.md) — diagnósticos y causas raíz confirmadas.
- [patterns.md](patterns.md) — convenciones y decisiones técnicas
  confirmadas del dominio Cloudflare.

## Aprendizajes esenciales

- Convención real de nombres DNS de apps `buklo-web`: Dev/UAT
  `<nombre-sin-'app-'>-web-{dev,uat}.gmontecristo.com`; Producción
  `<nombre>-web.buklo.dev` (NO `grupomontecristo.com` — un pedido en esa
  zona para Producción de una app `buklo-web` es un conflicto de
  nomenclatura, reportarlo siempre). Ver `patterns.md`.
- Esta sesión (2026-09-07) se ejecutó sin `Bash`/PowerShell/MCP
  disponibles — solo pudo diagnosticar con evidencia local de archivos,
  no con consultas reales a Cloudflare. Verificar disponibilidad de
  herramienta de ejecución al empezar cualquier invocación futura. Ver
  `debugging.md`.

Última revisión: 2026-09-07.
