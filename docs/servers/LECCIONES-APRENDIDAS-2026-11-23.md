# Lecciones Aprendidas - Validación de Servidores
**Fecha:** 2026-11-23  
**Sesión:** Validación completa de catálogo de servidores

## Resumen Ejecutivo

Durante la validación del catálogo de 13 servidores (10 Linux + 3 Windows), se identificaron y resolvieron múltiples problemas de conectividad que resultaron en una mejora del 15% al 69% de servidores conectados.

---

## Problema Principal: Variables de Entorno No Exportadas

### Contexto
El agente reportaba consistentemente que las credenciales para los servidores NVIDIA GPU (172.16.2.61, 172.16.2.63) y eIntegra (172.16.2.95) no existían, cuando en realidad estaban correctamente definidas en `env/.env`.

### Causa Raíz
```bash
# ❌ Método incorrecto usado inicialmente
source /home/cursor/stack-cursor/env/.env

# Las variables se cargaban en el shell de Bash,
# pero NO se exportaban a subprocesos (Python, scripts heredoc)
```

### Solución
```bash
# ✅ Método correcto
set -a  # Habilitar auto-export de todas las variables
source /home/cursor/stack-cursor/env/.env
set +a  # Deshabilitar auto-export

# Ahora Python y subprocesos pueden acceder a las variables
```

### Lección Clave
**Al trabajar con scripts que mezclan Bash y Python (via heredoc), SIEMPRE usar `set -a` antes de cargar variables de entorno.**

---

## Problema Secundario: Nomenclatura de Variables

### Contexto
El agente buscaba variables con nombres genéricos como:
- `NVIDIA_61_PASS`
- `TIDESARROLLO_PASS`
- `EPRAC_PASS`

Cuando los nombres reales en `env/.env` eran:
- `NVIDIA_SPARK_61_PASS`
- `NVIDIA_SPARK_63_PASS`
- `EPRAC_95_PASS`

### Causa Raíz
Falta de documentación clara sobre el patrón de nomenclatura de variables.

### Solución
Documentar el patrón sistemático:
- **Servidores genéricos**: `PROPOSITO_IP_TIPO` (ej: `DEV_SRV_PASS`)
- **NVIDIA GPUs**: `NVIDIA_SPARK_IP_TIPO` (incluye modelo del servidor)
- **Servidores específicos**: `NOMBRE_IP_TIPO` (ej: `EPRAC_95_PASS`)
- **Windows con hostname largo**: `HOSTNAME_IP_TIPO` (ej: `CRSRVSISRDP_76_PASS`)

### Lección Clave
**Siempre consultar el archivo `env/.env` directamente o listar variables disponibles antes de asumir nombres.**

```bash
# Listar variables disponibles
env | grep -iE "(srv|spark|eprac|pass)" | cut -d'=' -f1 | sort
```

---

## Problema Terciario: Validación Prematura

### Contexto
El agente reportaba servidores como "sin credencial" sin verificar primero:
1. Si las variables existían en el archivo
2. Si estaban correctamente exportadas
3. Si el servidor era alcanzable por red

### Causa Raíz
Proceso de validación inadecuado que saltaba pasos de diagnóstico.

### Solución - Proceso de Validación en 4 Pasos

```bash
# Paso 1: Verificar existencia de variable
[ -n "$NVIDIA_SPARK_61_PASS" ] && echo "✓ Existe" || echo "✗ No existe"

# Paso 2: Verificar alcanzabilidad (ping)
ping -c 1 -W 2 172.16.2.61 >/dev/null 2>&1 && echo "✓ Responde" || echo "✗ No responde"

# Paso 3: Verificar puerto SSH/WinRM
nc -zv 172.16.2.61 22 2>&1 | grep -q "succeeded" && echo "✓ Puerto abierto"

# Paso 4: Intentar autenticación
sshpass -p "$NVIDIA_SPARK_61_PASS" ssh ... "hostname"
```

### Lección Clave
**Nunca reportar un servidor como "no conectado" sin completar los 4 pasos de validación.**

---

## Descubrimientos Positivos

### 1. Servidor n8n Recuperado
- **Host**: 172.16.2.60
- **Estado anterior**: Credencial inválida
- **Estado actual**: Conectado ✓
- **Acción**: La credencial `N8N_SRV_PASS` fue actualizada entre validaciones
- **Impacto**: Acceso completo a workflows n8n y MCP n8n-interno

### 2. Tres Servidores Nuevos Conectados
Los servidores NVIDIA GPU y eIntegra estaban funcionales desde el inicio, solo faltaba el método correcto de validación:

#### NVIDIA DGX Spark GPU #1 (172.16.2.61)
- Hostname: `spark-8bac`
- Ubuntu 24.04.5 LTS (ARM64)
- GPU NVIDIA GB10
- Uptime: 4+ semanas
- Estado: Disponible (2% RAM, 37°C)

#### NVIDIA DGX Spark GPU #2 (172.16.2.63)
- Hostname: `spark-0a57`
- Ubuntu 24.04.4 LTS (ARM64)
- GPU NVIDIA GB10
- Uptime: 4+ semanas
- Estado: En uso (76% RAM, 56.8°C, load 3.0)

#### eIntegra Core (172.16.2.95)
- Hostname: `crsrvapipampa01`
- Ubuntu 24.04.3 LTS
- Uptime: 8+ semanas
- Puertos activos: 8080 (QA), 8090 (PRD)

### 3. Patrón de Estabilidad
Servidores con uptime >4 semanas demuestran:
- Configuración estable
- Sin problemas críticos de hardware
- Administración efectiva
- Baja necesidad de intervención

---

## Problemas Sin Resolver

### 1. Windows eFlow (172.16.2.76)
- **Estado**: Credencial rechazada + no responde a ping
- **Causa probable**: Servidor apagado o reiniciado
- **Próximo paso**: Verificar con administrador Windows

### 2. OpenEdX Desarrollo (10.2.1.132)
- **Estado**: Connection timeout
- **Causa probable**: Servidor apagado o subred 10.2.1.x no ruteada
- **Próximo paso**: Verificar rutas de red desde hub

### 3. Windows UAT (172.16.16.243)
- **Estado**: No ruteado desde hub
- **Causa**: Subred 172.16.16.x sin ruta desde 10.1.0.200 (por diseño)
- **Solución**: Acceso solo desde PC con ruta a esa subred

---

## Métricas de Mejora

| Métrica | Inicial | Final | Mejora |
|---------|---------|-------|--------|
| Servidores conectados | 2 | 9 | +350% |
| Cobertura | 15% | 69% | +54 pp |
| Linux conectados | 2 | 8 | +300% |
| Windows conectados | 0 | 1 | N/A |
| Tiempo validación completa | ~30 min | ~15 min | -50% |

---

## Recomendaciones para el Futuro

### 1. Automatización
Crear script `validate-all-servers.sh` que:
- Cargue variables correctamente (`set -a`)
- Valide los 4 pasos para cada servidor
- Genere reporte consolidado en 1 minuto

### 2. Monitoreo Proactivo
- Validación diaria automática de conectividad
- Alertas cuando un servidor deja de responder
- Dashboard de estado en tiempo real

### 3. Documentación
- Mantener `CONEXION-SERVIDORES-GUIA.md` actualizado
- Documentar cambios de credenciales
- Registrar cambios en hostnames o IPs

### 4. Nomenclatura Consistente
Al agregar nuevos servidores:
- Seguir patrón establecido de variables
- Documentar inmediatamente en guía
- Validar nombre antes de agregar al catálogo

---

## Checklist de Validación Reutilizable

Antes de reportar un servidor como "no conectado":

```
[ ] Variables cargadas con set -a
[ ] Variable existe: [ -n "$VAR" ]
[ ] Nombre de variable correcto (consultar env/.env)
[ ] Ping responde (1-2 segundos)
[ ] Puerto abierto (SSH 22 o WinRM 5985)
[ ] Usuario correcto (consultar catálogo)
[ ] Hostname conocido para validar éxito
[ ] Timeout >= 3 segundos
[ ] Error específico capturado (Permission denied vs Timeout)
[ ] Logs NO muestran passwords
```

---

## Código Reutilizable

### Script de Validación Individual

```bash
#!/bin/bash
# validate-server.sh <host> <user> <pass_var> <expected_hostname>

set -a
source /home/cursor/stack-cursor/env/.env
set +a

HOST=$1
USER=$2
PASS_VAR=$3
EXPECTED=$4

echo "Validando $HOST..."

# Paso 1: Variable
PASS="${!PASS_VAR}"
[ -n "$PASS" ] && echo "✓ Variable $PASS_VAR definida" || { echo "✗ Variable no definida"; exit 1; }

# Paso 2: Ping
ping -c 1 -W 2 $HOST >/dev/null 2>&1 && echo "✓ Ping OK" || { echo "✗ No responde"; exit 1; }

# Paso 3: Puerto
nc -zv $HOST 22 2>&1 | grep -q "succeeded" && echo "✓ Puerto SSH abierto" || { echo "✗ Puerto cerrado"; exit 1; }

# Paso 4: Conexión
result=$(timeout 5 sshpass -p "$PASS" ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no ${USER}@${HOST} "hostname" 2>&1)
if echo "$result" | grep -q "$EXPECTED"; then
    echo "✅ CONECTADO a $result"
    exit 0
else
    echo "❌ FALLO: $result"
    exit 1
fi
```

### Uso
```bash
./validate-server.sh 172.16.2.61 tidesarrollo NVIDIA_SPARK_61_PASS spark-8bac
```

---

## Impacto en Capacidades Operativas

Con 9 servidores conectados (69%), ahora disponibles:

✅ **Kubernetes**: 2 clusters (dev + prod)  
✅ **IA/ML**: 2 GPUs NVIDIA GB10 + Ollama  
✅ **Automatización**: n8n workflows + MCP  
✅ **Aplicaciones**: eIntegra PRD/QA activas  
✅ **CI/CD**: Agentes Linux + Windows  
✅ **Educación**: OpenEdX producción  

---

**Conclusión**: La mayoría de problemas de conectividad no eran credenciales faltantes, sino errores en el proceso de validación. Con el método correcto (`set -a`), el 69% del catálogo está operativo.
