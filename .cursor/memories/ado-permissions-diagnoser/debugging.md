# Diagnóstico — ado-permissions-diagnoser

Este subagente en sí no fue invocado todavía como proceso separado (todo
el diagnóstico real hasta el 2026-09-02 lo hizo la sesión principal
directamente). Todos los incidentes reales de este dominio — incluido el
mayor (descriptor SID vs Graph en `acesDictionary`, ver resumen en
`MEMORY.md` de este mismo agente) — están documentados en
`debugging.md` de `ado-permissions-builder`, que es la fuente completa;
no se duplica el detalle acá.
