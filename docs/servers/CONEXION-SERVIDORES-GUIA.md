# Guía de Conexión a Servidores - Stack Cursor

## Tabla de Contenidos
1. [Variables de Entorno](#variables-de-entorno)
2. [Conexión Linux (SSH)](#conexión-linux-ssh)
3. [Conexión Windows (WinRM)](#conexión-windows-winrm)
4. [Lecciones Aprendidas](#lecciones-aprendidas)
5. [Troubleshooting](#troubleshooting)

---

## Variables de Entorno

### Ubicación
- **Archivo**: `env/.env` (raíz del repositorio)
- **Permisos**: `chmod 600` (solo lectura/escritura para el propietario)
- **Versionado**: NO versionado (`.gitignore`)

### Cargar Variables Correctamente

#### ❌ INCORRECTO
```bash
source /home/cursor/stack-cursor/env/.env
# Las variables NO se exportan al contexto de Python o subprocesos
```

#### ✅ CORRECTO
```bash
set -a  # Habilitar auto-export
source /home/cursor/stack-cursor/env/.env
set +a  # Deshabilitar auto-export

# O en una sola línea al inicio de cada script
source /home/cursor/stack-cursor/env/.env && export $(cut -d= -f1 env/.env | grep -v '^#')
```

### Nomenclatura de Variables

Las variables siguen patrones específicos según el servidor:

#### Servidores Linux
```bash
# Patrón: NOMBRE_IP_TIPO
DEV_SRV_PASS=password                    # 172.16.2.43 (k3s dev)
LINUX_SRV_ADM_PASS=password             # 172.16.2.31 (k3s prod)
N8N_SRV_PASS=password                   # 172.16.2.60 (n8n)

# NVIDIA GPUs (nombre completo del servidor)
NVIDIA_SPARK_61_USER=tidesarrollo
NVIDIA_SPARK_61_PASS=password           # 172.16.2.61
NVIDIA_SPARK_63_USER=tidesarrollo
NVIDIA_SPARK_63_PASS=password           # 172.16.2.63

# eIntegra (nombre + número IP)
EPRAC_95_USER=eprac
EPRAC_95_PASS=password                  # 172.16.2.95

# OpenEdX (ruta a clave privada)
OPENEDX_KEY_PATH=/home/cursor/stack-cursor/env/keyopenedx.pem
```

#### Servidores Windows
```bash
# Patrón: HOSTNAME_IP_TIPO
LINUX_127_PASS=password                 # 172.16.2.127 (SRV-PRTG)

CRSRVSISRDP_76_USER=eprac
CRSRVSISRDP_76_PASS=password           # 172.16.2.76 (CRSRVSISRDP)

SRVUATRJ_243_USER=administrator.MCCL
SRVUATRJ_243_PASS=password             # 172.16.16.243 (SRV-UAT-RJ)
```

### Verificar Variables Cargadas

```bash
# Listar variables disponibles (sin mostrar valores)
env | grep -iE "(srv|spark|pass|user)" | grep -v "PATH\|HOME" | cut -d'=' -f1 | sort

# Verificar variable específica (sin mostrar valor)
[ -n "$NVIDIA_SPARK_61_PASS" ] && echo "✓ Definida" || echo "✗ NO definida"
```

---

## Conexión Linux (SSH)

### Con Contraseña (sshpass)

```bash
# Instalar sshpass si no existe
command -v sshpass &> /dev/null || sudo apt-get install -y sshpass

# Conexión básica
sshpass -p "$PASSWORD_VAR" ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no usuario@host "comando"

# Ejemplo real
sshpass -p "$NVIDIA_SPARK_61_PASS" ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no tidesarrollo@172.16.2.61 "hostname"
```

### Con Clave Privada

```bash
# Verificar existencia de clave
[ -f /home/cursor/stack-cursor/env/keyopenedx.pem ] || echo "Clave no encontrada"

# Verificar permisos (debe ser 600)
chmod 600 /home/cursor/stack-cursor/env/keyopenedx.pem

# Conexión
ssh -i /home/cursor/stack-cursor/env/keyopenedx.pem -o ConnectTimeout=3 -o StrictHostKeyChecking=no adminedx@135.119.204.153 "comando"
```

### Script de Validación Completo

```bash
#!/bin/bash
set -a
source /home/cursor/stack-cursor/env/.env
set +a

HOST="172.16.2.61"
USER="${NVIDIA_SPARK_61_USER}"
PASS="${NVIDIA_SPARK_61_PASS}"

echo "Probando conexión a $HOST como $USER..."

result=$(timeout 5 sshpass -p "$PASS" ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no ${USER}@${HOST} "hostname && whoami" 2>&1)

if echo "$result" | grep -q "spark-8bac"; then
    echo "✅ CONECTADO"
    echo "$result"
else
    echo "❌ FALLO"
    echo "$result"
fi
```

---

## Conexión Windows (WinRM)

### Verificar Puerto WinRM

```bash
# Verificar puerto 5985 (HTTP)
timeout 3 nc -zv 172.16.2.127 5985

# Verificar puerto 5986 (HTTPS) - opcional
timeout 3 nc -zv 172.16.2.127 5986
```

### Con Python (pywinrm)

```bash
# Instalar pywinrm si no existe
pip3 install pywinrm 2>/dev/null || sudo apt-get install -y python3-winrm
```

```python
#!/usr/bin/env python3
import winrm
import os

# Cargar variables de entorno en Python
# IMPORTANTE: Las variables deben estar exportadas con set -a antes de ejecutar Python

host = "172.16.2.127"
user = "administrator"
password = os.environ.get('LINUX_127_PASS', '')

if not password:
    print("❌ Variable LINUX_127_PASS no definida")
    exit(1)

try:
    # Crear sesión WinRM
    session = winrm.Session(
        f'http://{host}:5985/wsman',
        auth=(user, password),
        transport='ntlm',
        server_cert_validation='ignore'
    )
    
    # Ejecutar comando CMD
    result = session.run_cmd('hostname')
    
    if result.status_code == 0:
        print(f"✅ CONECTADO")
        print(f"Hostname: {result.std_out.decode().strip()}")
        
        # Ejecutar comando PowerShell
        result_ps = session.run_ps('whoami; Get-ComputerInfo | Select-Object CsName, OsName')
        if result_ps.status_code == 0:
            print(result_ps.std_out.decode())
    else:
        print(f"❌ Error código {result.status_code}")
        print(result.std_err.decode())
        
except Exception as e:
    error_name = type(e).__name__
    if 'InvalidCredentials' in error_name:
        print(f"❌ CREDENCIAL INVÁLIDA")
    elif 'ConnectionError' in str(e) or 'timeout' in str(e).lower():
        print(f"❌ NO ALCANZABLE (timeout/conexión rechazada)")
    else:
        print(f"❌ {error_name}: {str(e)[:100]}")
```

### Script Bash que llama Python (Recomendado)

```bash
#!/bin/bash
set -a
source /home/cursor/stack-cursor/env/.env
set +a

python3 << 'PYEOF'
import winrm, os, sys

host = "172.16.2.127"
user = "administrator"
password = os.environ.get('LINUX_127_PASS', '')

print(f"Variable LINUX_127_PASS: {'[DEFINIDA]' if password else '[NO DEFINIDA]'}")

if not password:
    sys.exit(1)

try:
    session = winrm.Session(f'http://{host}:5985/wsman', 
                           auth=(user, password), 
                           transport='ntlm', 
                           server_cert_validation='ignore')
    result = session.run_cmd('hostname')
    
    if result.status_code == 0:
        print(f"✅ CONECTADO: {result.std_out.decode().strip()}")
    else:
        print(f"❌ Error código {result.status_code}")
except Exception as e:
    print(f"❌ {type(e).__name__}")
PYEOF
```

---

## Lecciones Aprendidas

### ❌ Errores Comunes

1. **No exportar variables antes de usar Python/subprocesos**
   - Síntoma: Script bash lee la variable, Python no
   - Solución: Usar `set -a` antes de `source`

2. **Buscar variables con nombres incorrectos**
   - Síntoma: Script reporta "variable no definida"
   - Solución: Verificar nombres exactos en `env/.env`
   - Ejemplo: Buscar `NVIDIA_61_PASS` cuando el nombre real es `NVIDIA_SPARK_61_PASS`

3. **No verificar ping antes de SSH/WinRM**
   - Síntoma: Timeout en conexión
   - Solución: Siempre `ping -c 1 -W 2 $HOST` primero

4. **Asumir que servidor responde = puede conectar**
   - Síntoma: Puerto abierto pero credencial inválida
   - Solución: Ping y puerto abierto solo indican alcanzabilidad

5. **No validar credenciales después de actualizarlas**
   - Síntoma: Reportar como "sin credencial" cuando ya existe
   - Solución: Siempre recargar `.env` y probar

### ✅ Buenas Prácticas

1. **Validación en 3 capas**
   ```bash
   # Capa 1: Ping
   ping -c 1 -W 2 $HOST
   
   # Capa 2: Puerto (SSH 22 o WinRM 5985)
   nc -zv $HOST $PORT
   
   # Capa 3: Autenticación
   sshpass -p "$PASS" ssh ... "hostname"
   ```

2. **Timeouts progresivos**
   - Ping: 1-2 segundos
   - Puerto: 3-5 segundos
   - SSH/WinRM: 5-10 segundos

3. **Logs informativos**
   ```bash
   echo "Host: $HOST"
   echo "Usuario: $USER"
   echo "Variable: $([ -n "$PASS" ] && echo '[DEFINIDA]' || echo 'NO DEFINIDA')"
   ```

4. **Nunca mostrar passwords en logs**
   ```bash
   # ❌ MALO
   echo "Password: $PASS"
   
   # ✅ BUENO
   echo "Password: $([ -n "$PASS" ] && echo '[***]' || echo 'NO DEFINIDA')"
   ```

5. **Validar antes de reportar fallas**
   - Verificar que la variable existe en `.env`
   - Verificar que está exportada al entorno
   - Verificar que el servidor responde (ping)
   - Solo entonces probar autenticación

---

## Troubleshooting

### SSH: Permission Denied

**Causas posibles:**
1. Contraseña incorrecta
2. Usuario incorrecto
3. Autenticación por clave deshabilitada
4. Variable no exportada a subproceso

**Diagnóstico:**
```bash
# Verificar variable
echo "Pass definida: $([ -n "$NVIDIA_SPARK_61_PASS" ] && echo 'SÍ' || echo 'NO')"

# Probar con verbose
sshpass -p "$NVIDIA_SPARK_61_PASS" ssh -v tidesarrollo@172.16.2.61 "hostname" 2>&1 | grep -i "auth"
```

### WinRM: InvalidCredentialsError

**Causas posibles:**
1. Credencial incorrecta
2. Usuario requiere dominio (`DOMAIN\user`)
3. Servidor requiere HTTPS (puerto 5986)
4. TrustedHosts no configurado

**Diagnóstico:**
```bash
# Verificar puerto
nc -zv 172.16.2.76 5985

# Verificar usuario tiene dominio
echo "Usuario: ${CRSRVSISRDP_76_USER}"  # ¿Es eprac o CRSRVSISRDP\eprac?

# Intentar con servidor HTTPS
# Cambiar http:// por https:// y puerto 5985 por 5986
```

### Connection Timeout

**Causas posibles:**
1. Servidor apagado
2. Firewall bloqueando puerto
3. Subred no ruteada desde hub
4. Servidor reiniciándose

**Diagnóstico:**
```bash
# Ping primero
ping -c 3 -W 2 $HOST

# Traceroute si no responde
traceroute -m 10 $HOST

# Verificar desde otro servidor si es problema de ruta
```

### Variable "No Definida" pero Existe en .env

**Causa:** Variables no exportadas al subproceso (Python, scripts hijos)

**Solución:**
```bash
# Usar set -a SIEMPRE antes de source
set -a
source /home/cursor/stack-cursor/env/.env
set +a

# Verificar exportación
export | grep NVIDIA_SPARK_61
```

---

## Checklist de Validación

Antes de reportar un servidor como "no conectado", verificar:

- [ ] Variables cargadas con `set -a; source env/.env; set +a`
- [ ] Variable existe: `[ -n "$VAR" ] && echo OK`
- [ ] Nombre de variable correcto (ver catálogo)
- [ ] Ping responde: `ping -c 1 -W 2 $HOST`
- [ ] Puerto abierto: `nc -zv $HOST $PORT`
- [ ] Usuario correcto (verificar catálogo)
- [ ] Hostname esperado conocido (para validar conexión exitosa)
- [ ] Timeout adecuado (3-5 segundos mínimo)

---

## Referencias Rápidas

### Catálogos
- Linux: `docs/servers/servers.json`
- Windows: `docs/servers/windows/servers.json`

### Variables por Servidor

| Host | Usuario | Variables |
|------|---------|-----------|
| 172.16.2.43 | administrator | `DEV_SRV_PASS` |
| 172.16.2.31 | adm01 | `LINUX_SRV_ADM_PASS` |
| 172.16.2.60 | soporte | `N8N_SRV_PASS` |
| 172.16.2.61 | tidesarrollo | `NVIDIA_SPARK_61_USER`, `NVIDIA_SPARK_61_PASS` |
| 172.16.2.63 | tidesarrollo | `NVIDIA_SPARK_63_USER`, `NVIDIA_SPARK_63_PASS` |
| 172.16.2.95 | eprac | `EPRAC_95_USER`, `EPRAC_95_PASS` |
| 135.119.204.153 | adminedx | `keyopenedx.pem` |
| 172.16.2.127 | administrator | `LINUX_127_PASS` |
| 172.16.2.76 | eprac | `CRSRVSISRDP_76_USER`, `CRSRVSISRDP_76_PASS` |

---

**Fecha última actualización:** 2026-11-23  
**Autor:** Cursor Agent  
**Validado:** 9 de 13 servidores conectados exitosamente
