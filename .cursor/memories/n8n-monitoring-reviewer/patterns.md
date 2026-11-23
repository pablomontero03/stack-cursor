# Patrones — n8n-monitoring-reviewer

Checklist que ya usa el proceso de este agente (ver su
frontmatter/instrucciones) al revisar un clon de pack: conteo dinámico
real (no asumido), `name` con la etiqueta destino, sin strings residuales
de `FROM_LABEL`/`FROM_IP`/`OLD_CRED_ID`, credencial nueva en todos los
nodos `microsoftSql`, `active:false` en la creación, `staticData:null`,
schedule acordado, sin reutilizar credencial de producción, sin API key ni
credencial SQL en texto plano. Al revisar un cambio masivo de
timeouts/parámetros: valores contra el doc de referencia (no inventados),
backup previo al PUT, diff acotado a los campos indicados, `settings` del
PUT limitado a keys permitidas por la API. Patrones reales (hallazgos
recurrentes) se agregan solo cuando se confirmen en una revisión real.
