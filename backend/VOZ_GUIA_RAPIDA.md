# 🎤 Industrial Manager v15.5 - Voice-to-JSON Converter

## Descripción Rápida

Convierte transcripciones de voz informal en JSON estructurado para inserción automática en **Tbl_Gestor_Tareas**. Incluye:

- ✅ NER (Named Entity Recognition) para entidades industriales: áreas, piezas, usuarios
- ✅ Mapeo automático de prioridades (Urgente → 0, Importante → 1, Normal → 2)
- ✅ GPU-accelerated transcripción de audio (RTX 3060 con CUDA)
- ✅ Sin romper código existente - integración limpia en API

---

## 🚀 Instalación y Configuración

### 1. Instalar Dependencias

```bash
cd backend
pip install -r requirements.txt
```

Si tienes **GPU NVIDIA (RTX 3060)**, instala también:

```bash
pip install torch torchaudio  # CUDA 12.1 compatible
```

### 2. Verificar Instalación

```bash
# Prueba el módulo localmente
python voice_to_json_converter.py
```

Deberías ver salida como:

```
======================================================================
TESTS: Conversión Transcripción → JSON
======================================================================

[TEST 1] Transcripción:
  'Revisar los rodamientos del CNC para mañana, debe ser rápido'

  JSON Generado:
    Título: Rodamientos CNC
    Usuario: PENDIENTE
    Minutos: 15
    Prioridad: 1
    Válido: ✓
```

---

## 📡 Endpoints API

### 1️⃣ Procesar Transcripción (Texto → JSON)

**POST** `/api/tareas/voz/procesar`

Solo procesa texto sin crear tarea en BD. Útil para validación/preview.

**Request:**

```json
{
  "transcripcion": "Revisar los rodamientos del CNC para mañana, debe ser rápido",
  "minutos_base": 30,
  "incluir_metadata": true
}
```

**Response:**

```json
{
  "titulo": "Rodamientos CNC",
  "descripcion": "Revisar los rodamientos del CNC para mañana, debe ser rápido",
  "usuario_asignado": "PENDIENTE",
  "minutos_estimados": 15,
  "priority_rank": 1,
  "tipo_tarea": "MANUAL",
  "source_type": "VOZ_LOCAL",
  "meta_json": "{\"transcripcion_original\": \"...\", \"area_detectada\": \"CNC\", ...}",
  "transcripcion_procesada": "Revisar los rodamientos...",
  "entidades_detectadas": {
    "area": "CNC",
    "pieza": "Rodamientos",
    "usuario_detectado": "PENDIENTE"
  }
}
```

---

### 2️⃣ Crear Tarea desde Transcripción (One-Step)

**POST** `/api/tareas/voz/crear-desde-transcripcion`

Procesa transcripción **Y** crea la tarea en Tbl_Gestor_Tareas en un paso.

**Request:**

```json
{
  "transcripcion": "Urgente: revisar los sensores ESP8266 en ensamble, asignado a Juan",
  "minutos_base": 30,
  "incluir_metadata": true
}
```

**Response:**

```json
{
  "status": "ok",
  "id_tarea": 42,
  "titulo": "Sensores ESP8266 Ensamble",
  "usuario_asignado": "Juan",
  "priority_rank": 0,
  "message": "Tarea creada desde transcripción VOZ # 42"
}
```

---

### 3️⃣ Transcribir Audio (Whisper)

**POST** `/api/tareas/voz/transcribir-audio`

Transcribe archivo de audio (.mp3, .wav, .m4a) y retorna transcripción + JSON.

**⚠️ NOTA:** Primera llamada es lenta (~10-20 seg) porque carga el modelo Whisper (~2GB). Llamadas subsecuentes son rápidas.

**Con GPU (RTX 3060):** ~2-5 segundos por minuto de audio.

**Request:**

```json
{
  "ruta_archivo": "C:\\ruta\\grabacion.mp3",
  "idioma": "es",
  "minutos_base": 30
}
```

**Response:**

```json
{
  "status": "ok",
  "transcripcion": "Revisar rodamientos CNC para mañana...",
  "json_tarea": {
    "titulo": "Rodamientos CNC",
    "descripcion": "Revisar rodamientos...",
    "usuario_asignado": "PENDIENTE",
    "minutos_estimados": 15,
    "priority_rank": 1,
    "tipo_tarea": "MANUAL",
    "source_type": "VOZ_LOCAL",
    "meta_json": "..."
  },
  "caracteres": 125
}
```

---

## 🧠 Reglas de Mapeo (NER)

### Prioridades (Priority_Rank)

| Palabras Clave | Resultado | Ejemplo |
|---|---|---|
| "urgente", "crítico", "ya", "paro", "paro de línea" | **0** (Máxima) | "Urgente: revisar..." |
| "importante", "pronto", "mañana", "dentro de poco" | **1** (Normal) | "Para mañana..." |
| Ninguna | **2** (Baja) | "Revisar..." |

### Áreas Detectadas

- **CNC**: "cnc", "maquinado", "torno", "fresadora"
- **Ensamble**: "ensamble", "armado", "montaje"
- **Almacén**: "almacén", "bodega"
- **Prototipado**: "prototipado", "desarrollo", "lab", "laboratorio"

### Piezas Detectadas

- **NEMA**: "nema", "motor"
- **Rodamientos**: "rodamiento", "bearing"
- **Sensores ESP8266**: "sensor", "esp8266"
- **PLC**: "plc", "controlador"

### Usuarios Detectados

Patrones para detectar usuarios:

- "para **Juan**" → usuario="Juan"
- "asignado a **María**" → usuario="María"
- "responsable **Carlos**" → usuario="Carlos"

Si no detecta usuario → "PENDIENTE"

### Minutos Estimados

Heurística automática:

- Base: 30 minutos
- Si urgente/rápido → -50% (15 min)
- Si complejo/análisis → +50% (45 min)
- Si múltiples items → +25% (37.5 min)

---

## 💻 Uso desde Python

### Opción 1: Procesar Texto Directo

```python
from voice_to_json_converter import convertir_transcripcion_a_json

transcripcion = "Revisar los rodamientos CNC para mañana, urgente"

json_tarea = convertir_transcripcion_a_json(transcripcion, minutos_base=30)

print(json_tarea)
# {
#   "titulo": "Rodamientos CNC",
#   "usuario_asignado": "PENDIENTE",
#   "priority_rank": 0,
#   ...
# }
```

### Opción 2: Transcribir + Procesar Audio

```python
from voice_to_json_converter import (
    inicializar_whisper_gpu,
    transcribir_audio,
    convertir_transcripcion_a_json,
)

# Inicializar (primera vez es lenta)
inicializar_whisper_gpu()

# Transcribir
transcripcion = transcribir_audio("grabacion.mp3", idioma="es")

# Convertir
json_tarea = convertir_transcripcion_a_json(transcripcion)

print(f"Tarea: {json_tarea['titulo']}")
```

---

## 🔧 Troubleshooting

### Error: "faster-whisper no está instalado"

```bash
pip install faster-whisper
```

### Error: "No se pudo inicializar Whisper GPU"

Whisper intenta automáticamente usar **CUDA** primero, luego fallback a **CPU**.

Si quieres forzar GPU:

```python
from faster_whisper import WhisperModel

model = WhisperModel("large-v3", device="cuda", compute_type="float16")
segments, _ = model.transcribe("audio.mp3")
```

### Transcripción Lenta

- Primera ejecución: Carga modelo (~2GB) = 10-30 segundos
- Llamadas subsecuentes: 2-5 segundos/minuto de audio

Con **GPU (RTX 3060)**: Mucho más rápido.

### JSON Inválido

El módulo valida automáticamente. Si ves error:

```
JSON inválido: Campo faltante o nulo: ...
```

Revisa que la transcripción tenga al menos 10 caracteres.

---

## 📊 Ejemplo Completo: Flujo End-to-End

```python
# Archivo: backend/test_voz_completo.py

import requests
import json

API_BASE = "http://localhost:8001"

# Headers (simular autenticación)
headers = {
    "Authorization": "Bearer tu_token_aqui",
    "X-Usuario": "admin"
}

# PASO 1: Procesar transcripción (preview)
print("=== PASO 1: Procesar Transcripción ===")
response1 = requests.post(
    f"{API_BASE}/api/tareas/voz/procesar",
    json={
        "transcripcion": "Urgente: revisar los NEMA en CNC, asignado a Juan para mañana",
        "minutos_base": 30
    },
    headers=headers
)
print(response1.json())

# PASO 2: Crear tarea (directo a BD)
print("\n=== PASO 2: Crear Tarea ===")
response2 = requests.post(
    f"{API_BASE}/api/tareas/voz/crear-desde-transcripcion",
    json={
        "transcripcion": "Urgente: revisar los NEMA en CNC, asignado a Juan para mañana"
    },
    headers=headers
)
resultado = response2.json()
print(f"✓ Tarea creada: ID #{resultado['id_tarea']}")

# PASO 3: Transcribir audio
print("\n=== PASO 3: Transcribir Audio ===")
response3 = requests.post(
    f"{API_BASE}/api/tareas/voz/transcribir-audio",
    json={
        "ruta_archivo": "C:\\audio\\tarea_urgente.mp3",
        "idioma": "es"
    },
    headers=headers
)
print(f"Transcripción: {response3.json()['transcripcion']}")
```

---

## 🎯 Casos de Uso

### 1. Centro de Comando - Creación Rápida de Tareas por Voz

Operario en planta habla → Whisper transcribe → JSON → Tarea en BD

### 2. Integración WhatsApp/Telegram

Bot recibe audio → Transcribe → Crea tarea automáticamente

### 3. Reportes de Incidentes

Personal crea incidente hablando → Auto-categoriza por área/urgencia

### 4. Auditoría y Trazabilidad

Cada transcripción se guarda en `meta_json` → Auditoría completa

---

## 📝 Arquitectura

```
voice_to_json_converter.py
├── NER (Named Entity Recognition)
│   ├── extraer_prioridad()
│   ├── extraer_usuario()
│   ├── extraer_area()
│   └── extraer_pieza()
├── Procesamiento de Minutos
│   └── calcular_minutos_estimados()
├── Generación de Título
│   └── generar_titulo_tecnico()
├── Transcripción de Audio
│   ├── inicializar_whisper_gpu()
│   └── transcribir_audio()
└── Convertidor Principal
    └── convertir_transcripcion_a_json()

routers/gestor_tareas.py (NUEVOS ENDPOINTS)
├── POST /api/tareas/voz/procesar
├── POST /api/tareas/voz/crear-desde-transcripcion
└── POST /api/tareas/voz/transcribir-audio

models.py (NUEVOS MODELOS)
├── TranscripcionVozPayload
├── ArchivoAudioPayload
└── TareaDesdeVozResponse
```

---

## 🔐 Seguridad

- ✅ Validación de entrada (min_length, max_length)
- ✅ Auditoría en `registrar_log_global()`
- ✅ Headers de autenticación obligatorios
- ✅ Isolamiento de transcripción original en `meta_json`

---

## 📚 Referencias

- **Whisper**: https://github.com/openai/whisper
- **Faster-Whisper**: https://github.com/guillaumekln/faster-whisper
- **CUDA Setup**: https://docs.nvidia.com/cuda/cuda-toolkit-archive/

---

**Versión:** 1.0 (Industrial Manager v15.5)
**Fecha:** 2026-04-08
**Autor:** Ingeniero de Datos Industrial

