# Workers, Pages y almacenamiento

Cargar en modo `workers-storage`. Cubre: Workers (rutas, custom domains,
versiones, secrets, bindings), Pages (deployments, dominios,
configuración), KV, R2, D1, Queues, Durable Objects, Vectorize y
Workflows, Load Balancing (pools, health monitors, steering).

## Lectura (automática)

Listar Workers y sus rutas/bindings (nombres, nunca valores de secrets),
versiones desplegadas, Pages projects y deployments, namespaces KV (sin
listar/leer valores de keys salvo que se pida explícitamente y se apruebe
esa lectura puntual), buckets R2 (metadatos, no objetos), bases D1
(esquema/metadatos, nunca datos vía este dominio salvo lectura explícita
aprobada), colas, Durable Object namespaces, índices Vectorize,
Workflows, pools de Load Balancing y sus health monitors.

## Escritura (aprobación del plan principal)

Desplegar/actualizar un Worker (`wrangler deploy` o `PUT` del script vía
REST), crear/actualizar un binding, crear un namespace KV, un bucket R2,
una base D1, una cola, configurar un pool o health monitor. `wrangler
d1 execute` con una sentencia de escritura (`INSERT`/`UPDATE`/`DELETE`/
`CREATE`/`ALTER`/`DROP`) sigue el mismo flujo de aprobación que cualquier
otra escritura de este dominio — **nunca** se ejecuta como si fuera
lectura solo porque el comando "parece" una consulta.

## Eliminación (aprobación separada)

Eliminar un Worker, una ruta, un custom domain (o desvincularlo), un
Pages project o deployment, un namespace/bucket/base/cola/Durable Object
namespace, un índice Vectorize, un Workflow, un pool o health monitor.

## Secrets de Worker — nunca se leen ni se respaldan en texto plano

- Los nombres de Worker secrets pueden inventariarse (`wrangler secret
  list`), nunca sus valores.
- Un respaldo antes de eliminar un Worker conserva script/versión/rutas/
  bindings/**nombres** de secrets — nunca sus valores.
- No descargar por defecto datos completos de R2, KV o D1 al hacer un
  respaldo — solo metadatos y configuración, salvo pedido explícito y
  aprobación puntual para leer datos concretos.
