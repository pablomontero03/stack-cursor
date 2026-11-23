# Definiciones financieras obligatorias

Todo reporte de este dominio debe distinguir explícitamente lo siguiente
— nunca presentar una cifra sin aclarar a cuál de estas categorías
pertenece.

## Tipo de costo

- **`ActualCost`**: costo facturado real, incluye créditos/reembolsos/
  ajustes aplicados. Es el número que concilia con la factura.
- **`AmortizedCost`**: costo de reservas/Savings Plans distribuido
  linealmente durante su período de vigencia, en vez del cargo puntual
  del momento de compra. Útil para comparar el costo "real de uso" mes a
  mes cuando hay reservas de por medio.
- **`Forecast`**: proyección de cierre — nunca se presenta como un hecho,
  siempre con la metodología y el margen de incertidumbre declarados
  (ver `Get-AzureCostRecommendations.ps1`/`Invoke-AzureCostQuery.ps1`
  `-Mode Forecast`).

Un mismo período puede tener cifras distintas de `ActualCost` y
`AmortizedCost` — nunca mezclarlas en la misma serie sin etiquetar cuál
es cuál.

## Moneda

Cada respuesta de Cost Management trae su propia moneda de facturación
(columna `Currency`/`BillingCurrency`). **Nunca sumar importes de
monedas distintas** — si un reporte cruza suscripciones o billing
accounts con monedas diferentes, agrupar y presentar por moneda por
separado, o convertir explícitamente con una tasa y fecha declaradas
(nunca una conversión silenciosa).

## Período y zona horaria

- Declarar siempre el período exacto consultado (`from`/`to`) y la zona
  horaria de esos límites (Cost Management usa UTC).
- **Mes acumulado (`MonthToDate`) vs. mes completo**: nunca comparar un
  mes parcial contra un mes completo sin normalizar (proyección lineal
  simple, o comparar contra el mismo día del mes anterior) o, como
  mínimo, indicarlo explícitamente en el reporte ("día 12 de septiembre
  vs. agosto completo").
- Declarar la fecha/hora de actualización de los datos (Cost Management
  típicamente tiene un rezago de horas; Actual Cost de días recientes
  puede no estar cerrado todavía).

## Precio y consumo

- **Precio unitario** (`UnitPrice`) vs. **precio efectivo**
  (`EffectivePrice`, después de descuentos/reservas) vs. **costo total**
  (`Cost`) — presentar el que la pregunta necesite, nunca confundirlos.
- Distinguir **consumo** (uso real) de **compras** (ej. una reserva
  comprada de una vez) — una compra grande en un día no significa que el
  consumo se disparó ese día.
- Reservas, Savings Plans, créditos, reembolsos y ajustes son líneas
  separadas del consumo bruto — declarar cuáles están incluidas en una
  cifra dada.
- Declarar si una cifra incluye impuestos o no, según lo que la fuente
  realmente entregue (Cost Management normalmente no incluye impuestos;
  no asumir que sí).

## Ahorro y recomendaciones

- Un ahorro estimado (de una recomendación de Advisor, un análisis de
  SKU, o una simulación de reserva) **nunca se presenta como garantizado**
  — siempre "ahorro potencial estimado", con la fórmula y los supuestos
  explícitos.
- Toda recomendación debe incluir: evidencia (datos que la sustentan),
  costo actual, ahorro estimado (mensual y anual), confianza (alta/media/
  baja y por qué), esfuerzo, riesgo, dependencias, impacto en
  disponibilidad, y método de validación posterior (qué métrica/costo se
  vuelve a mirar después de aplicar el cambio).

## Atribución no demostrable

Nunca inventar una cifra de costo por namespace, workload o deployment
individual cuando la fuente de facturación no lo entrega a ese nivel de
detalle. Si se necesita repartir un costo compartido (ej. un node pool de
AKS entre varios namespaces), la fórmula de reparto debe quedar explícita
y la cifra resultante marcada como **estimación**, nunca como el dato
facturado real.
