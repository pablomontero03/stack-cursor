# Patrones — n8n-monitoring-diagnoser

Categorías de fallo que ya usa el proceso de este agente (ver su
frontmatter/instrucciones): timeout SQL en el SP de monitoreo, credencial
SQL incorrecta o apuntando al host equivocado, red/DNS transitorio,
payload Teams inválido o webhook con 403 transitorio, bug de
transformación (FOR XML, BOM UTF-8, helper de texto), timeout de
Embeddings/Chat Model en el workflow MAIA, configuración de retry/maxTries
insuficiente. Patrones reales confirmados (qué causa raíz es más frecuente
en qué categoría) se agregan solo cuando el agente los confirme en
diagnósticos reales.
