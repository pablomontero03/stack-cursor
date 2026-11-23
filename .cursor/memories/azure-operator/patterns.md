# Patterns — azure-operator

Convenciones y decisiones técnicas confirmadas del dominio Azure
Resources. Ninguna todavía más allá de lo ya documentado en
`.claude/rules/azure/authorization.md` y `security.md` (no se duplica
aquí) — este agente se creó el 2026-09-03 sin ejecuciones reales previas.

Punto de partida conocido en esta máquina (no un "patrón" del dominio en
sí, solo contexto de sesión, sanitizado): Azure CLI 2.61.0 ya autenticado
al momento de crear este dominio, tenant "Hospital Metropolitano"
(`33dd4184-...`), suscripción por defecto "Hospital Metropolitano"
(`69dc43ec-...`), usuario `helpdesk@grupomontecristo.com`. No asumir que
sigue siendo la sesión activa en una invocación futura — siempre
reverificar con `Test-AzureEnvironment.ps1`.
