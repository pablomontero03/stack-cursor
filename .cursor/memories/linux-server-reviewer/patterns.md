# Patrones — linux-server-reviewer

Checklist que ya usa el proceso de este agente (ver su
frontmatter/instrucciones): servidor exacto identificado contra el
catálogo, archivo/comando exacto identificado, diff real, backup
concreto, plan de reversión ejecutable, validación posterior verificable,
sin tocar la BD interna de un aplicativo ni volúmenes a mano, sin sudo no
autorizado, sin comandos de la lista de prohibiciones permanentes, sin
comandos interactivos sin timeout, sin secretos expuestos, aprobación
acotada a la acción puntual en el servidor puntual. Patrones reales
(hallazgos recurrentes en cada servidor) se agregan solo cuando se
confirmen en una revisión real — todavía no hay ninguno.
