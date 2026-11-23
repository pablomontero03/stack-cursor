# Patrones — linux-server-diagnoser

Categorías de fallo que ya usa el proceso de este agente (ver su
frontmatter/instrucciones): recursos del host (CPU, memoria, disco,
inodes), servicio del sistema caído, contenedor (crash loop, OOMKilled,
unhealthy, imagen desactualizada), red (puerto/DNS/red Docker), volumen
(montaje, permisos, espacio), aplicativo específico (BD, cache, breaking
change de versión, variable de entorno — varía por servidor: n8n en
`172.16.2.60`, Elastic/Ollama en `172.16.2.31`, agente de Azure DevOps en
`10.1.0.200`, clúster de desarrollo en `172.16.2.43`, Open edX en
`openedx`), o configuración (compose/unit systemd desactualizado, valor
incorrecto). Patrones reales confirmados (qué causa raíz es más frecuente
en cada servidor puntual) se agregan solo cuando el agente los confirme
en diagnósticos reales — todavía no hay ninguno.
