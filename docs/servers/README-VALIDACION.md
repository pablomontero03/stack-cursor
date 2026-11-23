# Validación de Servidores - Referencia Rápida

## 🚀 Validación Rápida

```bash
# Validar todos los servidores (resumen)
./scripts/validate-all-servers.sh

# Validar con detalle verbose
./scripts/validate-all-servers.sh --verbose
```

---

## 📚 Documentación Completa

| Documento | Propósito |
|-----------|-----------|
| `CONEXION-SERVIDORES-GUIA.md` | Guía completa de conexión SSH/WinRM |
| `LECCIONES-APRENDIDAS-2026-11-23.md` | Problemas encontrados y soluciones |
| `README-VALIDACION.md` | Este archivo - referencia rápida |

---

## ⚡ Validación Manual Rápida

### Linux con Password

```bash
# Cargar variables CORRECTAMENTE
set -a
source /home/cursor/stack-cursor/env/.env
set +a

# Probar conexión
sshpass -p "$NVIDIA_SPARK_61_PASS" ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no tidesarrollo@172.16.2.61 "hostname"
```

### Linux con Clave Privada

```bash
ssh -i /home/cursor/stack-cursor/env/keyopenedx.pem -o ConnectTimeout=3 -o StrictHostKeyChecking=no adminedx@135.119.204.153 "hostname"
```

### Windows con WinRM

```bash
# Cargar variables
set -a
source /home/cursor/stack-cursor/env/.env
set +a

# Probar con Python
python3 << 'PYEOF'
import winrm, os
session = winrm.Session('http://172.16.2.127:5985/wsman', 
                       auth=('administrator', os.environ.get('LINUX_127_PASS')), 
                       transport='ntlm', 
                       server_cert_validation='ignore')
result = session.run_cmd('hostname')
print(result.std_out.decode().strip())
PYEOF
```

---

## 🔑 Variables por Servidor

| Host | Usuario | Variables en env/.env |
|------|---------|------------------------|
| 172.16.2.43 | administrator | `DEV_SRV_PASS` |
| 172.16.2.31 | adm01 | `LINUX_SRV_ADM_PASS` |
| 172.16.2.60 | soporte | `N8N_SRV_PASS` |
| 172.16.2.61 | tidesarrollo | `NVIDIA_SPARK_61_USER`, `NVIDIA_SPARK_61_PASS` |
| 172.16.2.63 | tidesarrollo | `NVIDIA_SPARK_63_USER`, `NVIDIA_SPARK_63_PASS` |
| 172.16.2.95 | eprac | `EPRAC_95_USER`, `EPRAC_95_PASS` |
| 135.119.204.153 | adminedx | Archivo `keyopenedx.pem` |
| 172.16.2.127 | administrator | `LINUX_127_PASS` |
| 172.16.2.76 | eprac | `CRSRVSISRDP_76_USER`, `CRSRVSISRDP_76_PASS` |

---

## ⚠️ Regla de Oro

**SIEMPRE usar `set -a` antes de cargar variables para scripts que mezclan Bash y Python:**

```bash
set -a                                      # ← CRÍTICO
source /home/cursor/stack-cursor/env/.env
set +a

# Ahora Python puede acceder a las variables
python3 -c "import os; print(os.environ.get('NVIDIA_SPARK_61_PASS', 'NO DEFINIDA'))"
```

Sin `set -a`, las variables solo existen en el shell de Bash pero NO se exportan a subprocesos.

---

## 📊 Estado Actual

**Última validación:** 2026-11-23 20:27 UTC

| Categoría | Cantidad | % |
|-----------|----------|---|
| ✅ Conectados | 9 | 69% |
| ❌ Fallidos | 3 | 23% |
| 🔒 Deshabilitados | 1 | 8% |
| **Total** | **13** | **100%** |

---

## 🎯 Capacidades Disponibles

Con 9 servidores conectados:

✅ **Kubernetes**: 2 clusters (dev + prod)  
✅ **IA/ML**: 2x NVIDIA DGX GPU GB10 + Ollama  
✅ **Automatización**: n8n workflows + MCP  
✅ **Aplicaciones**: eIntegra PRD/QA  
✅ **CI/CD**: Agentes Linux + Windows  
✅ **Educación**: OpenEdX producción  

---

## 🆘 Troubleshooting

### "Variable no definida"
1. Verificar nombre exacto en `env/.env`: `grep NVIDIA env/.env`
2. Usar `set -a` antes de `source`
3. Listar variables: `env | grep NVIDIA`

### "Permission denied"
1. Verificar ping: `ping -c 1 $HOST`
2. Verificar puerto: `nc -zv $HOST 22`
3. Probar con `-v` para verbose

### "Connection timeout"
- Servidor apagado o subred no ruteada
- Verificar desde otro servidor si es problema de ruta

---

## 📁 Archivos Clave

```
stack-cursor/
├── env/
│   ├── .env                                    # Variables (chmod 600)
│   ├── keyopenedx.pem                         # Clave OpenEdX prod
│   └── keyopenedx-dev.pem                     # Clave OpenEdX dev (faltante)
├── docs/servers/
│   ├── servers.json                           # Catálogo Linux
│   ├── windows/servers.json                   # Catálogo Windows
│   ├── CONEXION-SERVIDORES-GUIA.md           # Guía completa
│   ├── LECCIONES-APRENDIDAS-2026-11-23.md    # Lecciones aprendidas
│   └── README-VALIDACION.md                   # Esta guía
└── scripts/
    └── validate-all-servers.sh                # Script de validación
```

---

**Última actualización:** 2026-11-23  
**Autor:** Cursor Agent  
**Validado con:** 9/13 servidores operativos
