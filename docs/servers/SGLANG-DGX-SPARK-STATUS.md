# Estado de Infraestructura SGLang en Servidores DGX Spark

**Fecha de actualización:** 2026-10-23  
**Versión SGLang:** 0.5.22 (ambos servidores)

## Resumen Ejecutivo

Se han configurado dos servidores NVIDIA DGX Spark (arquitectura ARM64, GPU GB10 con 128GB de memoria unificada) para servir modelos de IA como backend de VS Code Chat y otras aplicaciones. Los modelos probados corren de forma fluida y rápida, con tiempos de respuesta excelentes para tareas de generación de código y embeddings.

---

## Servidores Disponibles

| Servidor | IP | Usuario | Hardware | Memoria Total |
|----------|-----|---------|----------|---------------|
| spark-8bac (IA NVIDIA #1) | 172.16.2.61 | tidesarrollo | DGX Spark, GPU GB10 | 128 GB |
| spark-0a57 (IA NVIDIA #2) | 172.16.2.63 | tidesarrollo | DGX Spark, GPU GB10 | 128 GB |

---

## Estado Actual de Modelos por Servidor

### Servidor .61 (spark-8bac) — "El Arquitecto"

| Modelo | Puerto | Estado | Contexto Máximo | Uso |
|--------|--------|--------|-----------------|-----|
| **gpt-oss-120b** (MoE 120B mxfp4) | 8000 | ✅ Activo | ~65,478 tokens | Modelo principal de arquitectura y razonamiento complejo |

**Memoria en uso:** ~94 GB de 128 GB  
**Memoria disponible:** ~31 GB

**Servicio systemd:**
```
sglang-gpt-oss.service (activo)
```

---

### Servidor .63 (spark-0a57) — "El Programador"

| Modelo | Puerto | Estado | Contexto Máximo | Uso |
|--------|--------|--------|-----------------|-----|
| **Qwen3-Coder-30B-A3B-Instruct** | 8000 | ✅ Activo | ~491,307 tokens | Generación de código, asistente de programación |
| **bge-m3** (BAAI) | 6335 | ✅ Activo | N/A | Embeddings multilingües |
| **Qwen2.5-Coder-1.5B-Instruct** | 8001 | ⏸️ Configurado (apagado) | 32,768 tokens | Autocompletado de baja latencia (<300ms) |
| **Qwen2-VL-7B** | — | ❌ No disponible | N/A | Análisis de imágenes (no hay memoria suficiente) |

**Memoria en uso:** ~96 GB de 128 GB  
**Memoria disponible:** ~29 GB (suficiente para el modelo 1.5B de ~3GB)

**Servicios systemd:**
```
sglang-qwen3-coder.service (activo)
sglang-bge-m3.service (activo)
sglang-autocomplete.service (deshabilitado, listo para activar)
sglang-qwen2-vl.service (deshabilitado, no viable por memoria)
```

---

## Implementaciones Realizadas

### 1. Optimización de KV Cache con FP8 (Servidor .63)

El modelo Qwen3-Coder-30B se configuró con `--kv-cache-dtype fp8_e5m2`, lo que permitió una **mejora de 184x en el contexto disponible**:

| Configuración | Contexto Máximo |
|---------------|-----------------|
| Sin FP8 (auto) | ~2,655 tokens |
| Con FP8 (fp8_e5m2) | ~491,307 tokens |

Esta optimización permite manejar archivos de código muy grandes y conversaciones extensas sin perder contexto.

### 2. Chat Template en Español (Servidor .63)

Se creó un chat template personalizado para que el modelo Qwen3-Coder responda en español por defecto:

**Archivo:** `/home/tidesarrollo/sglang/qwen3-coder-spanish.jinja`

El template inyecta un system prompt en español cuando el cliente no envía uno propio. Sin embargo, VS Code Chat envía su propio system prompt en inglés que tiene precedencia.

**Workaround:** Iniciar los mensajes con palabras claramente en español ("Hola, ", "Por favor, ") para que el modelo detecte el idioma.

### 3. Servicios Systemd User

Todos los modelos corren como servicios `systemd --user` con:
- Reinicio automático en caso de fallo
- Inicio automático al login del usuario
- Logs accesibles via `journalctl --user`

---

## Modelo Qwen2-VL-7B (Vision) — Estado: No Disponible

### Propósito
El modelo Qwen2-VL-7B es un modelo multimodal diseñado para **análisis y procesamiento de imágenes**. Permite:
- Describir contenido de imágenes
- Extraer texto de capturas de pantalla
- Analizar diagramas y gráficos
- Responder preguntas sobre contenido visual

### Razón de No Disponibilidad

El modelo Vision requiere aproximadamente **15-20 GB de memoria** para cargar los pesos más una reserva adicional para el KV cache. El error específico al intentar arrancarlo es:

```
ValueError: Loaded weights leave no GPU memory for the KV cache under 
--mem-fraction-static=0.4. Raise --mem-fraction-static above 0.603
```

**En el servidor .63:**
- El Programador (Qwen3-Coder-30B) + Embeddings (bge-m3) consumen ~96 GB
- Solo quedan ~29 GB libres
- El Vision necesita ~15-20 GB para pesos + reserva para KV cache
- La configuración actual de `mem-fraction-static=0.4` no deja suficiente espacio

**En el servidor .61:**
- El Arquitecto (gpt-oss-120b) consume ~94 GB
- Quedan ~31 GB libres
- Bajo carga pesada con múltiples usuarios, la memoria disponible puede reducirse
- Riesgo de inestabilidad si se agrega otro modelo

### Opciones Futuras
1. **Reducir memoria del Programador** bajando `mem-fraction-static` de 0.70 a 0.55 (sacrifica contexto)
2. **Mover Vision al .61** cuando se estabilice el uso del Arquitecto con más usuarios
3. **Servicio on-demand** que apague otro modelo temporalmente para usar Vision

---

## Limitaciones Actuales

### 1. Memoria Compartida GPU/CPU
La arquitectura DGX Spark usa memoria unificada (GPU y CPU comparten los 128 GB). Esto significa que:
- No hay VRAM dedicada separada
- Los modelos grandes compiten por el mismo pool de memoria
- El sistema operativo y otros procesos también consumen de este pool

### 2. Un Solo Modelo Grande por Servidor
Con modelos de 30B+ parámetros, solo cabe uno por servidor con contexto amplio. Modelos más pequeños (7B) pueden coexistir si hay espacio.

### 3. Contexto vs Cantidad de Modelos
Hay un trade-off entre:
- **Contexto amplio** (más tokens por conversación) → requiere más memoria para KV cache
- **Más modelos simultáneos** → cada uno con menos contexto

### 4. Idioma en VS Code Chat
VS Code Chat envía su propio system prompt en inglés que tiene precedencia sobre el template del servidor. El modelo responde en el idioma que detecta del primer mensaje del usuario.

---

## Rendimiento Observado

Los modelos configurados muestran excelente rendimiento:

| Aspecto | Observación |
|---------|-------------|
| **Tiempo de carga** | ~6-7 minutos para Qwen3-Coder-30B |
| **Latencia de respuesta** | Fluida, sin retrasos perceptibles |
| **Throughput** | Adecuado para uso simultáneo de 2-3 usuarios |
| **Estabilidad** | Sin caídas ni errores durante operación normal |

---

## Configuración de VS Code

Para conectar VS Code Chat a estos modelos, configurar en `settings.json`:

```json
{
  "chat.models": [
    {
      "id": "programador-local",
      "name": "Programador (Qwen3-Coder-30B)",
      "provider": "openai",
      "baseUrl": "http://172.16.2.63:8000/v1",
      "model": "Qwen/Qwen3-Coder-30B-A3B-Instruct"
    },
    {
      "id": "arquitecto-local", 
      "name": "Arquitecto (gpt-oss-120b)",
      "provider": "openai",
      "baseUrl": "http://172.16.2.61:8000/v1",
      "model": "openai/gpt-oss-120b"
    }
  ]
}
```

---

## Comandos Útiles de Administración

```bash
# Ver estado de servicios
systemctl --user status sglang-*

# Ver logs en tiempo real
journalctl --user -u sglang-qwen3-coder -f

# Reiniciar un servicio
systemctl --user restart sglang-qwen3-coder

# Ver memoria disponible
free -m

# Ver info del servidor SGLang
curl -s localhost:8000/get_server_info | python3 -m json.tool

# Health check
curl -s localhost:8000/health
```

---

---

## Análisis de Cumplimiento vs Requisitos del Proyecto

> Basado en la especificación `buklo-ai-infra-dgx-v1`

### Resumen de Estado

| Fase | Estado | Progreso |
|------|--------|----------|
| F0: Hardware/Provisioning | ✅ Completada | 100% |
| F1: Spike de Viabilidad | ✅ Completada | 100% |
| F2: Instalación del Motor | ✅ Completada | 100% |
| F3: Carga de Modelos | ✅ Completada | 100% (AC-3.3 configurado pero apagado) |
| F4: Configuración del Editor | 🔄 En progreso | 60% |
| F5: Piloto Medido | ⏳ Pendiente | 0% |
| F6: Escalonamiento y Junta | ⏳ Pendiente | 0% |

---

### Requisitos Cumplidos ✅

#### REQ-1: Spike de Viabilidad
| Criterio | Estado | Evidencia |
|----------|--------|-----------|
| AC-1.1 VS Code sin cuenta GitHub | ✅ | Panel de chat funciona con Custom Endpoint |
| AC-1.3 Funcionamiento sin internet | ✅ | Modelos corren 100% locales, sin llamadas externas |

#### REQ-2: Poner en Marcha los Servidores
| Criterio | Estado | Evidencia |
|----------|--------|-----------|
| AC-2.1 Servidores responden en LAN | ✅ | .61:8000 y .63:8000/6335 operativos |
| AC-2.2 Operan sin internet | ✅ | SGLang no requiere conexión externa |

#### REQ-3: Instalar Modelos de IA (Parcial)
| Criterio | Estado | Evidencia |
|----------|--------|-----------|
| AC-3.1 Modelo rápido para programación | ✅ | Qwen3-Coder-30B con 491K tokens de contexto |
| AC-3.2 Modelo de mayor capacidad | ✅ | gpt-oss-120b (Arquitecto) en .61 |
| AC-3.3 Modelo ligero para autocompletado | ✅ Configurado | Qwen2.5-Coder-1.5B en .63:8001 (servicio apagado, listo para activar) |
| AC-3.4 Búsqueda inteligente (embeddings) | ✅ | bge-m3 operativo en .63:6335 |

---

### Requisitos Pendientes o Parciales ⚠️

#### REQ-3: Modelo de Autocompletado (AC-3.3)
**Estado:** ✅ Configurado (servicio apagado)

El diseño original especificaba:
- **Qwen2.5-Coder-1.5B** dedicado para autocompletado con latencia <300ms TTFT
- Debía correr en un puerto separado (`:8001`) para no competir con el chat

**Situación actual:**
- ✅ Servicio `sglang-autocomplete.service` creado en el servidor .63
- ✅ Configurado en puerto 8001 con `--mem-fraction-static 0.08` (~3GB)
- ✅ Contexto de 32,768 tokens
- ⏸️ Servicio **deshabilitado** intencionalmente (no arranca automáticamente)
- Para activar: `systemctl --user enable --now sglang-autocomplete.service`

**Recurso de memoria:** El modelo de 1.5B solo requiere ~3GB, y hay ~29GB disponibles, por lo que **sí cabe** junto con el Programador y Embeddings.

#### REQ-4: Configuración del Editor (Parcial)
| Criterio | Estado | Notas |
|----------|--------|-------|
| AC-4.1 Sin sesión externa | ✅ | Confirmado que funciona |
| AC-4.2 Solo modelos locales visibles | 🔄 | Requiere configurar `chatLanguageModels.json` por usuario |
| AC-4.3 Chat + edición + autocompletado locales | ⚠️ | Chat ✅, Autocompletado pendiente (falta modelo 1.5B) |
| AC-4.4 Búsqueda vía buklo-kb | ⏳ | Embeddings listos, integración con buklo-kb pendiente |

**Documentación entregada:**
- `GUIA-INSTALACION-VSCODE.md` — Guía paso a paso para configurar VS Code

#### REQ-5: Piloto Medido
**Estado:** ⏳ Pendiente

Tareas específicas del piloto:

| # | Tarea | Estado | Descripción |
|---|-------|--------|-------------|
| 27 | [ARCH] Diseñar suite de tareas representativas | ⏳ Pendiente | Definir en AgDR las tareas típicas del loop Buklo para medir |
| 28 | Medir tasa de completitud end-to-end | ⏳ Pendiente | **Métrica primaria**: ≥85% de tareas completadas exitosamente |
| 29 | Medir tok/s y TTFT | ⏳ Pendiente | Tokens/segundo por rol y Time-To-First-Token del autocompletado (<300ms) |
| 30 | Medir concurrencia real | ⏳ Pendiente | Cuántos devs simultáneos puede sostener cada equipo con el loop intensivo |
| 31 | Prueba air-gapped completa | ⏳ Pendiente | Cortar WAN y confirmar que chat + agente + autocompletado siguen operativos |
| 32 | Monitorear tráfico saliente | ⏳ Pendiente | Confirmar 0 conexiones a dominios GitHub/Microsoft en sesión típica |
| 33 | Documentar resultados vs línea base | ⏳ Pendiente | Comparar métricas con el baseline de servicios en nube |

**Dependencias para iniciar el piloto:**
1. ✅ Modelos de chat funcionando (Arquitecto + Programador)
2. ✅ Embeddings operativos (bge-m3)
3. ⏸️ Modelo de autocompletado listo (Qwen2.5-Coder-1.5B configurado, solo falta activar)
4. ⚠️ Configurar Continue para autocompletado una vez activo el modelo
5. ⚠️ Integración buklo-kb con embeddings pendiente

#### REQ-6: Escalonamiento y Junta
**Estado:** ⏳ Pendiente (depende de REQ-5)

---

### Desviaciones del Diseño Original

#### 1. Reparto de Servidores (Cambio)

**Diseño original (design.md):**
```
DGX-1 (.61): Chat/Agente (Arquitecto + Programador) → :8000
DGX-2 (.63): Autocompletado (1.5B) + Embeddings → :8001 + Qdrant
```

**Implementación actual:**
```
DGX-1 (.61): Solo Arquitecto (gpt-oss-120b) → :8000
DGX-2 (.63): Programador (Qwen3-Coder-30B) + Embeddings (bge-m3) → :8000, :6335
             Vision (Qwen2-VL-7B) → :8001 (NO DISPONIBLE por memoria)
```

**Razón del cambio:** Se priorizó tener el Programador con máximo contexto (491K tokens con FP8) sobre seguir el reparto original. El Arquitecto quedó solo en el .61 para no competir por memoria.

#### 2. Modelo de Autocompletado No Instalado

**Diseño original:** Qwen2.5-Coder-1.5B en puerto :8001 del DGX-2  
**Realidad:** El puerto 8001 se asignó a Vision (modelo multimodal), que no pudo arrancar

**Impacto:** El autocompletado vía Continue no está configurado. Los desarrolladores tendrían que:
- Usar el Programador para autocompletado (mayor latencia)
- O esperar a que se instale el modelo de 1.5B

#### 3. Modelo Vision Agregado (Fuera de Alcance Original)

Se intentó agregar Qwen2-VL-7B para análisis de imágenes, que **no estaba en el diseño original**. Esto consumió el puerto 8001 y, al fallar por memoria, dejó ese puerto sin uso definido.

---

### Tareas Inmediatas Recomendadas

| Prioridad | Tarea | Estado | Impacto |
|-----------|-------|--------|---------|
| 🟢 Baja | Activar Qwen2.5-Coder-1.5B en :8001 | ⏸️ Configurado | Solo ejecutar `systemctl --user enable --now sglang-autocomplete` |
| 🟡 Media | Configurar Continue para autocompletado | ⏳ Pendiente | `tabAutocompleteModel` apuntando a .63:8001 |
| 🟡 Media | Verificar integración buklo-kb con bge-m3 | ⏳ Pendiente | Completa AC-3.4 para búsqueda semántica |
| 🟡 Media | Crear plantilla `chatLanguageModels.json` | ⏳ Pendiente | Facilita AC-4.2 para distribución a devs |
| 🟢 Baja | Diseñar suite de tareas para piloto | ⏳ Pendiente | Prepara REQ-5, requiere definición en AgDR |

---

### Limitaciones Actuales por Memoria

La arquitectura DGX Spark con memoria unificada (128GB compartidos entre CPU y GPU) impone restricciones:

| Servidor | Memoria Usada | Memoria Libre | Puede Agregar |
|----------|---------------|---------------|---------------|
| .61 | ~94 GB | ~31 GB | Qwen2.5-Coder-1.5B (~2GB) ✅ |
| .63 | ~96 GB | ~29 GB | Qwen2.5-Coder-1.5B (~2GB) ✅, Vision (~15GB) ❌ |

**Modelo Vision (Qwen2-VL-7B):** No viable con la configuración actual. Requeriría:
- Reducir contexto del Programador (de 491K a ~200K tokens)
- O mover embeddings al .61
- O esperar a que baje el uso de memoria del Arquitecto

---

## Historial de Cambios

| Fecha | Cambio |
|-------|--------|
| 2026-10-23 | Configurado Qwen2.5-Coder-1.5B para autocompletado en :8001 (servicio apagado) |
| 2026-10-23 | Agregado análisis de cumplimiento vs requisitos del proyecto |
| 2026-10-23 | Agregadas tareas detalladas del REQ-5 (Piloto Medido) |
| 2026-10-23 | Aplicado FP8 KV cache al Programador (184x más contexto) |
| 2026-10-23 | Creado chat template en español para Qwen3-Coder |
| 2026-10-23 | Deshabilitado Vision por falta de memoria |
| 2026-10-23 | Documentación inicial de la infraestructura |
