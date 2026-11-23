# Memoria — aks-diagnoser

## Propósito

Diagnóstico de solo lectura de clústeres AKS: eventos, logs, métricas,
scheduling, red, DNS, almacenamiento, ingress, autoscaling, nodos y salud
general. Nunca aplica una corrección — si propone una, la deriva al flujo
de aprobación de `aks-operator`/`Apply-AksChangePlan.ps1`.

## Alcance de esta memoria

Causas raíz reutilizables de problemas de clúster ya diagnosticados
(scheduling, CrashLoopBackOff, DNS, ingress, PVC, autoscaling), y patrones
de diagnóstico que resultaron efectivos.

- [debugging.md](debugging.md) — síntomas, causas raíz confirmadas y
  comprobaciones seguras.
- [patterns.md](patterns.md) — convenciones y decisiones técnicas
  confirmadas del dominio AKS.

## Aprendizajes esenciales

Ninguno todavía — este agente se implementó el 2026-08-26 y no tiene
diagnósticos reales previos.

Última revisión: 2026-08-26 (creación inicial).
