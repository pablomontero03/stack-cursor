# Memoria — azure-finops-analyst

## Propósito

Análisis FinOps de la suscripción Azure "Hospital Metropolitano"
(`69dc43ec-5f24-4203-9239-a8d0f8506d44`): costos, consumo, utilización,
anomalías, tendencias, pronósticos y oportunidades de optimización de
cualquier servicio. Nunca aplica cambios de infraestructura — prepara y
transfiere a `azure-operator`/`azure-reviewer`.

## Alcance de esta memoria

Patrones y aprendizajes de diagnóstico reutilizables sobre CÓMO analizar
costos de esta suscripción (metodologías validadas, nombres de reportes
recurrentes, gaps de datos confirmados). **Nunca** costos descargados
completos, tokens, credenciales, kubeconfigs, identificadores sensibles
de facturación, ni datos que deban vivir en `.local/`.

- Depuración: [[debugging]]
- Patrones: [[patterns]]

## Aprendizajes esenciales

- El MCP `azure` está diferido (ver
  `.cursor/rules/azure.mdc`) — este agente trabaja 100% con
  Azure CLI/`az rest`, vía los scripts de `.claude/skills/analyze-azure-costs/scripts/`.
- El endpoint de Cost Management Query/Forecast usa HTTP POST pero es de
  solo lectura — `azure-security-gate.ps1` lo clasifica como lectura
  automática únicamente para la suscripción `69dc43ec-...` y un esquema
  de `--body` exacto (ver `.cursor/rules/azure.mdc` § Caso
  especial). Cualquier otra suscripción/ruta/clave de body sigue
  preguntando.
- `az consumption reservation summary list` exige un `reservation-order-id`
  real — `Get-AzureCostRecommendations.ps1` no lo lista automáticamente
  (evita asumir cobertura sin evidencia); consultarlo puntualmente cuando
  el análisis lo requiera con un order id real.
- Formato Excel solo se genera si el módulo `ImportExcel` ya está
  instalado en la máquina — si no lo está, `New-AzureFinOpsReport.ps1`
  omite ese formato con una advertencia explícita, nunca instala nada
  automáticamente.

Última revisión: 2026-09-03 (creación inicial del agente).

## Regla operacional: no ejecutar setup.sh de Kiro
Confirmado en producción 2026-09-21. No ejecutar `setup-kiro.sh`. `./setup-cursor.sh` no reinicia el worker.

**Siempre usar en sesiones activas de Crew:**
```bash
set -a; source /home/cursor/stack-cursor/env/.env; set +a
export REPO_ROOT=/home/cursor/stack-cursor
```
O con el flag seguro: `set -a; source env/.env; set +a`

No ejecutar `source ./setup.sh`. Para variables: `set -a; source env/.env; set +a`.
