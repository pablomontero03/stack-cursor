# DNS y certificados

Cargar en modo `dns-tls`. Cubre: dominios y configuración de zona, DNS,
registros, DNSSEC, analytics de DNS, proxy de Cloudflare y configuración
de origen, SSL/TLS, certificados, Origin CA y mTLS.

## Lectura (automática)

Listar zonas y su estado, registros DNS (nombre/tipo/proxied/TTL, sin
valores de secretos), configuración DNSSEC, modo SSL/TLS de la zona,
certificados instalados (metadatos: emisor, vigencia, hostnames — nunca la
clave privada), configuración mTLS (nombres de certificados de cliente
confiables, no su contenido).

## Escritura (aprobación del plan principal)

Crear/modificar un registro DNS, activar/desactivar proxy (naranja/gris),
cambiar modo SSL/TLS de la zona, habilitar DNSSEC, subir un certificado
personalizado (nunca generar la clave privada del lado de Claude — el
usuario la provee o se usa Origin CA), configurar mTLS. Cada operación
sigue el esquema de `change-workflow.md`.

## Eliminación (aprobación separada)

Borrar un registro DNS, deshabilitar DNSSEC, eliminar un certificado
personalizado o Origin CA, remover una zona completa. La eliminación de
una zona completa es especialmente sensible — tratarla igual que un
Resource Group completo en Azure: nunca compartir lote de aprobación con
otra eliminación.

## Secretos — siempre `ask`, evitar si no es indispensable

- Descargar la clave privada de un Origin CA certificate.
- Mostrar el contenido de un certificado de cliente mTLS con clave
  privada.
- Cualquier endpoint que devuelva material criptográfico privado.

Nunca se guarda una clave privada en un respaldo, plan, inventario, log ni
memoria de agente (ver `.cursor/rules/cloudflare.mdc`).

## Resolución determinista de un registro (`Resolve-CloudflareDnsRecord.ps1`)

Script de solo lectura, usado también por `orchestrate-application-pipeline-cycle`,
que opera sobre el estado real vía `Invoke-CloudflareApiRequest` (nunca
escribe):

1. Resuelve la zona correcta por el FQDN: coincidencia de sufijo más larga
   entre las zonas de la cuenta (una zona hija como `dev.example.com` gana
   sobre `example.com` si ambas son sufijo válido).
2. Busca un registro existente con ese nombre exacto y tipo.
3. Representa TTL `Auto` como el entero `1` (nunca la cadena `'auto'`),
   igual que la API vigente.
4. Clasifica: `to_create` (no existe), `reuse` (existe y coincide en
   tipo/contenido/proxied/TTL) o `conflict` (existe y difiere en algún
   campo — nunca sugiere sobrescribir en silencio; el diff exacto queda en
   `diffFields`).
5. El comentario propuesto usa siempre el nombre de clúster **confirmado**
   pasado en `-ClusterName`, nunca un `cluster_candidate` sin confirmar —
   esto es correcto para **Producción**. Para **Desarrollo/UAT**, la
   convención real observada (confirmada en vivo 2026-09-07 contra
   `directory-web`/`hr-web`/`logistics-web`) usa un comentario fijo
   (`172.16.2.43-ambiente-desarrollo`), no el nombre del clúster —
   pasar ese valor fijo como `-ClusterName` para esos 2 ambientes en vez
   del nombre de clúster real.

Este script no decide si crear/reutilizar — solo informa la clasificación
para que el plan la incluya. La escritura real sigue el flujo normal de
`change-workflow.md` con su propia aprobación.

## Convención real de zona/proxy en Producción (buklo-web)

Confirmado en vivo 2026-09-07 contra la cuenta real: coexisten 2 patrones
de Producción para apps de `buklo-web`, no uno solo — nunca asumir cuál
aplica sin confirmarlo:

| Grupo | Zona | `proxied` | Apps reales ya desplegadas |
|---|---|---|---|
| A (**default** desde 2026-09-07, salvo indicación explícita) | `grupomontecristo.com` | `false` | `directory-web`, `logistics-web` |
| B | `buklo.dev` | `true` | `hr-web`, `ontology-web`, `shell-web`, `ticketing-web` |

Ambos grupos usan la misma IP de Producción y el mismo comentario
(nombre del clúster). Ninguna app aparece en ambas zonas — es una
categorización deliberada. Para una app nueva, usar el Grupo A por
defecto; usar el Grupo B únicamente cuando el usuario lo indique
explícitamente para esa app puntual (ver memoria de proyecto
`pipeline-cycle-production-dns-convention`).
