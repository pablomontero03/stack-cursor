# Plan de Implementación — NVIDIA DGX Spark

**Proyecto:** Entorno de Desarrollo Agéntico On-Premise  
**Estado:** 📋 Fase de comprensión (esperando accesos al server)  
**Última actualización:** 2026-10-08

---

## Resumen del Objetivo

Montar una IA privada en la DGX Spark para que los programadores la usen desde VS Code sin pagar por token y sin que el código salga de la red local.

---

## Fases de Implementación

### FASE 0: Preparación (antes de tocar el server)
> **Qué hacemos:** Reunir todo lo que necesitamos para no improvisar el día de la instalación.

| # | Tarea | Explicación simple | Estado |
|---|---|---|---|
| 0.1 | Obtener acceso SSH al DGX Spark | Credenciales para conectarnos al server por terminal. | ⬜ Pendiente |
| 0.2 | Confirmar IP del DGX en la red local | Saber a qué dirección apuntar (ej. `192.168.x.x`). | ⬜ Pendiente |
| 0.3 | Definir qué modelos vamos a correr | DeepSeek R1 70B + Qwen Coder (¿32B o 70B?). | ⬜ Pendiente |
| 0.4 | Saber cuántos devs lo van a usar al inicio | Para dimensionar la concurrencia del servidor. | ⬜ Pendiente |
| 0.5 | Decidir vLLM vs NVIDIA NIM | El "motor" que sirve los modelos. Lo vemos juntos. | ⬜ Pendiente |

---

### FASE 1: Verificar el Sistema Base
> **Qué hacemos:** Confirmar que la DGX está sana, con drivers y Docker listos.  
> **Analogía:** Revisar que el carro prende y tiene gasolina antes de un viaje.

| # | Tarea | Explicación simple | Estado |
|---|---|---|---|
| 1.1 | Conectarse por SSH y ver que responde | Primer contacto con el server. | ⬜ Pendiente |
| 1.2 | Verificar sistema operativo (DGX OS) | Ejecutar `cat /etc/os-release` para confirmar la versión. | ⬜ Pendiente |
| 1.3 | Verificar drivers NVIDIA | Ejecutar `nvidia-smi` — debe mostrar el chip GB10 y los 128 GB. | ⬜ Pendiente |
| 1.4 | Verificar Docker instalado | Ejecutar `docker --version`. Viene preinstalado en DGX OS. | ⬜ Pendiente |
| 1.5 | Verificar acceso a NVIDIA NGC | El "App Store" de NVIDIA de donde se bajan modelos y contenedores. | ⬜ Pendiente |
| 1.6 | Verificar espacio en disco | Ejecutar `df -h`. Necesitamos varios cientos de GB libres para modelos. | ⬜ Pendiente |

**Resultado esperado:** Un servidor que responde, con GPU reconocida y Docker listo.

---

### FASE 2: Descargar los Modelos
> **Qué hacemos:** Bajar los "cerebros" de IA al disco del DGX.  
> **Analogía:** Descargar los programas antes de instalarlos.

| # | Tarea | Explicación simple | Estado |
|---|---|---|---|
| 2.1 | Crear carpeta para modelos | Ej. `/models/` o `/data/models/`. | ⬜ Pendiente |
| 2.2 | Descargar DeepSeek R1 (70B, INT4) | El modelo "arquitecto que piensa". ~35-40 GB. | ⬜ Pendiente |
| 2.3 | Descargar Qwen Coder (32B o 70B) | El modelo "programador que escribe". ~20-40 GB. | ⬜ Pendiente |
| 2.4 | Descargar modelo de embeddings (BGE-M3) | Para la búsqueda de código (RAG). ~2 GB. | ⬜ Pendiente |
| 2.5 | Verificar integridad de las descargas | Checksums / que no estén corruptos. | ⬜ Pendiente |

**Resultado esperado:** Modelos en disco, listos para cargar.

---

### FASE 3: Levantar el Servidor de Inferencia
> **Qué hacemos:** Prender el "mesero" que recibe peticiones y las pasa a los modelos.  
> **Analogía:** Encender el motor del carro.

| # | Tarea | Explicación simple | Estado |
|---|---|---|---|
| 3.1 | Instalar/configurar vLLM o NIM | El software que carga el modelo y lo expone por red. | ⬜ Pendiente |
| 3.2 | Cargar DeepSeek R1 en el servidor | Verificar que cabe en memoria (debe usar ~35-40 GB de los 128). | ⬜ Pendiente |
| 3.3 | Cargar Qwen Coder en el servidor | Verificar memoria total usada (~70 GB entre ambos). | ⬜ Pendiente |
| 3.4 | Exponer el servidor en la red local | Puerto 8000 (u otro) accesible desde las laptops de los devs. | ⬜ Pendiente |
| 3.5 | Probar con un curl desde otra máquina | `curl http://<IP>:8000/v1/models` debe listar los modelos. | ⬜ Pendiente |

**Resultado esperado:** Un endpoint `http://<IP>:8000/v1` respondiendo.

---

### FASE 4: Montar la Base Vectorial (RAG)
> **Qué hacemos:** Darle a la IA la capacidad de "conocer" el código del proyecto.  
> **Analogía:** Darle un índice del libro para que busque rápido.

| # | Tarea | Explicación simple | Estado |
|---|---|---|---|
| 4.1 | Levantar Qdrant en Docker | `docker run qdrant/qdrant`. Base de datos vectorial. | ⬜ Pendiente |
| 4.2 | Configurar FastEmbed (BGE-M3) | Para convertir código en vectores buscables. | ⬜ Pendiente |
| 4.3 | Indexar un repositorio de prueba | Subir un proyecto pequeño y verificar que se busca. | ⬜ Pendiente |
| 4.4 | Conectar el RAG con el servidor de IA | Que las consultas pasen por la búsqueda vectorial. | ⬜ Pendiente |

**Resultado esperado:** Puedes preguntar "¿dónde está la función de login?" y la IA la encuentra.

---

### FASE 5: Conectar VS Code de los Desarrolladores
> **Qué hacemos:** Configurar las laptops de los devs para que usen la IA local.  
> **Analogía:** Conectar los teléfonos a la red WiFi nueva.

| # | Tarea | Explicación simple | Estado |
|---|---|---|---|
| 5.1 | Instalar extensión Roo Code o Cline | En el VS Code de cada dev. | ⬜ Pendiente |
| 5.2 | Configurar el endpoint local | Apuntar a `http://<IP>:8000/v1`. | ⬜ Pendiente |
| 5.3 | Configurar API Key ficticia | Poner `sk-local-dgx` (el server la ignora). | ⬜ Pendiente |
| 5.4 | Seleccionar los modelos en la extensión | DeepSeek para pensar, Qwen para programar. | ⬜ Pendiente |
| 5.5 | Probar una conversación simple | "Hola, ¿me escuchas?" → debe responder. | ⬜ Pendiente |

**Resultado esperado:** El dev escribe en VS Code y la IA local responde.

---

### FASE 6: Configurar el Flujo Spec-Driven (estilo Kiro)
> **Qué hacemos:** Enseñarle a la IA las reglas del juego (specs antes de código).  
> **Analogía:** Darle el manual de procedimientos al empleado nuevo.

| # | Tarea | Explicación simple | Estado |
|---|---|---|---|
| 6.1 | Crear carpeta `/specs/` en el proyecto | Donde vivirán las especificaciones. | ⬜ Pendiente |
| 6.2 | Crear archivo `.clinerules` | Las reglas que la IA debe seguir. | ⬜ Pendiente |
| 6.3 | Escribir una spec de prueba | Ej. `001-modulo-auth.md` con criterios de aceptación. | ⬜ Pendiente |
| 6.4 | Probar el ciclo completo | Spec → revisión → código → tests. | ⬜ Pendiente |

**Resultado esperado:** La IA sigue el flujo ordenado: primero spec, luego código.

---

### FASE 7: Afinación y Monitoreo
> **Qué hacemos:** Ajustar la concurrencia y poner métricas.  
> **Analogía:** Ajustar el motor después de los primeros kilómetros.

| # | Tarea | Explicación simple | Estado |
|---|---|---|---|
| 7.1 | Ajustar parámetros de concurrencia | Cuántas peticiones atiende a la vez. | ⬜ Pendiente |
| 7.2 | Configurar logs del servidor | Para ver quién pregunta qué y detectar problemas. | ⬜ Pendiente |
| 7.3 | Medir velocidad real (tokens/seg) | Confirmar que va rápido. | ⬜ Pendiente |
| 7.4 | Probar con varios devs a la vez | Carga real para ver si aguanta. | ⬜ Pendiente |
| 7.5 | Documentar configuración final | Para que quede registro. | ⬜ Pendiente |

**Resultado esperado:** Sistema estable, medido y documentado.

---

### FASE 8: Pruebas y Validación Final
> **Qué hacemos:** Verificar que todo funciona correctamente antes de declarar el sistema "listo para producción".  
> **Analogía:** La inspección final antes de entregar las llaves de una casa.

#### 8.1 Pruebas de Conectividad
| # | Prueba | Qué validamos | Estado |
|---|---|---|---|
| 8.1.1 | Ping al servidor desde cada laptop | Que la red local llega al DGX. | ⬜ Pendiente |
| 8.1.2 | Curl al endpoint `/v1/models` | Que el servidor de IA responde. | ⬜ Pendiente |
| 8.1.3 | Curl al endpoint de Qdrant | Que la base vectorial responde. | ⬜ Pendiente |

#### 8.2 Pruebas de Inferencia (los modelos responden)
| # | Prueba | Qué validamos | Estado |
|---|---|---|---|
| 8.2.1 | Chat simple con DeepSeek R1 | "Hola, ¿cuánto es 2+2?" → responde coherente. | ⬜ Pendiente |
| 8.2.2 | Chat simple con Qwen Coder | "Escribe un Hello World en Python" → código válido. | ⬜ Pendiente |
| 8.2.3 | Pregunta larga (contexto grande) | Pegar 2000+ tokens y que responda sin error. | ⬜ Pendiente |
| 8.2.4 | Medir velocidad de respuesta | Verificar que estamos arriba de 50 tokens/seg. | ⬜ Pendiente |

#### 8.3 Pruebas de RAG (búsqueda en código)
| # | Prueba | Qué validamos | Estado |
|---|---|---|---|
| 8.3.1 | Indexar un repo de prueba | Que Qdrant lo acepta sin errores. | ⬜ Pendiente |
| 8.3.2 | Buscar una función por nombre | "¿Dónde está la función X?" → la encuentra. | ⬜ Pendiente |
| 8.3.3 | Buscar por descripción semántica | "¿Dónde se validan los emails?" → resultado relevante. | ⬜ Pendiente |

#### 8.4 Pruebas de Concurrencia (varios devs a la vez)
| # | Prueba | Qué validamos | Estado |
|---|---|---|---|
| 8.4.1 | 2 devs preguntando al mismo tiempo | Ambos reciben respuesta sin timeout. | ⬜ Pendiente |
| 8.4.2 | 5 devs preguntando al mismo tiempo | El sistema no se cae ni se pone lento. | ⬜ Pendiente |
| 8.4.3 | Monitorear memoria durante carga | Que no se acerca al 100% de los 128 GB. | ⬜ Pendiente |

#### 8.5 Pruebas del Flujo Spec-Driven
| # | Prueba | Qué validamos | Estado |
|---|---|---|---|
| 8.5.1 | Crear una spec desde cero | La IA ayuda a redactar `/specs/test-feature.md`. | ⬜ Pendiente |
| 8.5.2 | Generar código desde la spec | La IA lee la spec y genera código que la cumple. | ⬜ Pendiente |
| 8.5.3 | Ciclo completo con tests | Spec → código → tests pasan. | ⬜ Pendiente |

#### 8.6 Pruebas de Resiliencia
| # | Prueba | Qué validamos | Estado |
|---|---|---|---|
| 8.6.1 | Reiniciar el servidor de IA | Que vuelve a levantar solo y los devs reconectan. | ⬜ Pendiente |
| 8.6.2 | Reiniciar el DGX completo | Que todo vuelve a funcionar tras un reboot. | ⬜ Pendiente |
| 8.6.3 | Simular pérdida de red temporal | Que el sistema se recupera sin intervención. | ⬜ Pendiente |

**Resultado esperado:** Todas las pruebas pasan ✅ y el sistema está listo para uso diario.

---

### FASE 9: Go-Live y Entrega
> **Qué hacemos:** Declarar el sistema listo, capacitar a los devs y cerrar el proyecto.  
> **Analogía:** Cortar el listón e inaugurar.

| # | Tarea | Explicación simple | Estado |
|---|---|---|---|
| 9.1 | Documentar configuración final | IP, puertos, modelos cargados, parámetros. | ⬜ Pendiente |
| 9.2 | Crear guía rápida para devs | "Cómo conectar tu VS Code en 5 minutos". | ⬜ Pendiente |
| 9.3 | Sesión de capacitación | Mostrarle a los devs cómo usarlo. | ⬜ Pendiente |
| 9.4 | Definir responsable de soporte | Quién atiende si algo falla. | ⬜ Pendiente |
| 9.5 | Declarar Go-Live | 🎉 Sistema en producción. | ⬜ Pendiente |

**Resultado esperado:** Devs usando la IA local en su día a día.

---

## Glosario Rápido

| Término | Qué significa en simple |
|---|---|
| **Modelo** | El "cerebro" de la IA (un archivo grande que se descarga). |
| **Inferencia** | Cada vez que la IA "piensa y responde" a una pregunta. |
| **Token** | Pedacito de texto (~1 palabra). En la nube pagas por cada uno. |
| **VRAM / Memoria unificada** | Donde el modelo tiene que caber para funcionar (128 GB). |
| **Servidor de inferencia** | El programa que mantiene el modelo "prendido" y lo expone por red. |
| **vLLM** | Un servidor de inferencia open source muy usado. |
| **NIM** | El servidor de inferencia "oficial" de NVIDIA (más enlatado). |
| **RAG** | Retrieval-Augmented Generation = darle a la IA acceso a buscar en tu código. |
| **Qdrant** | Base de datos vectorial (donde se guarda el índice de búsqueda). |
| **OpenAI-Compatible** | Formato estándar de comunicación (NO conexión con OpenAI). |

---

## Próximos Pasos

1. **Esperar el aviso** de que el server está listo y los accesos.
2. **Pablo me pasa los datos** de la Fase 0 (SSH, IP, devs, decisión vLLM/NIM).
3. **Arrancamos la Fase 1** juntos marcando los checks conforme avanzamos.

---

*Documento vivo — lo iremos actualizando conforme avancemos en la implementación.*
