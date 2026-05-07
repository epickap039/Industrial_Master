#!/usr/bin/env pwsh
# Ejemplos cURL para probar endpoints de Voice-to-JSON (Industrial Manager v15.5)
#
# Uso en PowerShell:
#   .\test_voz_curl.ps1
#
# Esta versión es para Windows PowerShell con curl como alias de Invoke-WebRequest

$BASE_URL = "http://localhost:8001"

# Headers de autenticación (simular)
$headers = @{
    "Authorization" = "Bearer test_token"
    "X-Usuario" = "admin"
    "Content-Type" = "application/json"
}

function Print-Header {
    param($title)
    Write-Host "`n$('=' * 80)" -ForegroundColor Cyan
    Write-Host " $title" -ForegroundColor Cyan
    Write-Host "$('=' * 80)" -ForegroundColor Cyan
}

function Print-Response {
    param($response, $title)
    Write-Host "`n$title" -ForegroundColor Green
    $response | ConvertTo-Json -Depth 10 | Write-Host
}

# ==============================================================================
# TEST 1: Procesar Transcripción (Preview)
# ==============================================================================

Print-Header "TEST 1: POST /api/tareas/voz/procesar - Preview"

Write-Host "Enviando transcripción para preview (SIN crear en BD)..." -ForegroundColor Yellow

$body1 = @{
    transcripcion = "Urgente: revisar los rodamientos del CNC para mañana, debe ser rápido"
    minutos_base = 30
    incluir_metadata = $true
} | ConvertTo-Json

try {
    $response1 = Invoke-WebRequest `
        -Uri "$BASE_URL/api/tareas/voz/procesar" `
        -Method POST `
        -Headers $headers `
        -Body $body1

    Print-Response $response1.Content "✅ Respuesta:"
} catch {
    Write-Host "❌ Error: $_" -ForegroundColor Red
}

# ==============================================================================
# TEST 2: Crear Tarea desde Transcripción (One-Step)
# ==============================================================================

Print-Header "TEST 2: POST /api/tareas/voz/crear-desde-transcripcion - Create & BD"

Write-Host "Creando tarea desde transcripción (inserta en Tbl_Gestor_Tareas)..." -ForegroundColor Yellow

$body2 = @{
    transcripcion = "Urgente: revisar sensores ESP8266 en ensamble, asignado a Juan"
    minutos_base = 30
    incluir_metadata = $true
} | ConvertTo-Json

try {
    $response2 = Invoke-WebRequest `
        -Uri "$BASE_URL/api/tareas/voz/crear-desde-transcripcion" `
        -Method POST `
        -Headers $headers `
        -Body $body2

    Print-Response $response2.Content "✅ Tarea Creada:"

    # Extraer ID de tarea
    $responseObj = $response2.Content | ConvertFrom-Json
    if ($responseObj.id_tarea) {
        Write-Host "📌 ID Tarea Creada: $($responseObj.id_tarea)" -ForegroundColor Green
    }
} catch {
    Write-Host "❌ Error: $_" -ForegroundColor Red
}

# ==============================================================================
# TEST 3: Transcribir Audio (Whisper)
# ==============================================================================

Print-Header "TEST 3: POST /api/tareas/voz/transcribir-audio - Whisper GPU"

Write-Host "Transcribiendo archivo de audio..." -ForegroundColor Yellow
Write-Host "⚠️  Primera llamada puede tardar 10-30 segundos (carga modelo Whisper)" -ForegroundColor Yellow

# Usar un archivo de prueba si existe
$audio_file = "C:\test_audio.mp3"

if (Test-Path $audio_file) {
    $body3 = @{
        ruta_archivo = $audio_file
        idioma = "es"
        minutos_base = 30
    } | ConvertTo-Json

    try {
        $response3 = Invoke-WebRequest `
            -Uri "$BASE_URL/api/tareas/voz/transcribir-audio" `
            -Method POST `
            -Headers $headers `
            -Body $body3 `
            -TimeoutSec 60  # Timeout de 60 segundos para transcripción

        Print-Response $response3.Content "✅ Transcripción Completa:"
    } catch {
        Write-Host "❌ Error: $_" -ForegroundColor Red
    }
} else {
    Write-Host "⚠️  Archivo de prueba no encontrado: $audio_file" -ForegroundColor Yellow
    Write-Host "   Usa un archivo .mp3, .wav o .m4a para probar" -ForegroundColor Yellow
}

# ==============================================================================
# CASOS DE PRUEBA ADICIONALES
# ==============================================================================

Print-Header "CASOS DE PRUEBA ADICIONALES"

$test_casos = @(
    @{
        nombre = "Prioridad Urgente"
        transcripcion = "Urgente: paro de línea en CNC, revisar motores NEMA"
    },
    @{
        nombre = "Con Usuario Asignado"
        transcripcion = "Para María: análisis de sensores en prototipado"
    },
    @{
        nombre = "Área y Pieza Detectadas"
        transcripcion = "Revisar rodamientos en almacén, está dañado un bearing"
    },
    @{
        nombre = "Complejidad Alta"
        transcripcion = "Análisis completo del PLC en ensamble, va a tomar tiempo"
    }
)

foreach ($test in $test_casos) {
    Write-Host "`n🔹 $($test.nombre)" -ForegroundColor Cyan
    Write-Host "   Transcripción: '$($test.transcripcion)'" -ForegroundColor Gray

    $body = @{
        transcripcion = $test.transcripcion
        minutos_base = 30
        incluir_metadata = $false  # Sin metadata para output más limpio
    } | ConvertTo-Json

    try {
        $response = Invoke-WebRequest `
            -Uri "$BASE_URL/api/tareas/voz/procesar" `
            -Method POST `
            -Headers $headers `
            -Body $body `
            -ErrorAction Stop

        $obj = $response.Content | ConvertFrom-Json
        Write-Host "   ✓ Título: $($obj.titulo)" -ForegroundColor Green
        Write-Host "   ✓ Usuario: $($obj.usuario_asignado)" -ForegroundColor Green
        Write-Host "   ✓ Prioridad: $($obj.priority_rank) [$(@('URGENTE', 'IMPORTANTE', 'NORMAL')[$obj.priority_rank])]" -ForegroundColor Green
        Write-Host "   ✓ Minutos: $($obj.minutos_estimados)" -ForegroundColor Green
    } catch {
        Write-Host "   ❌ Error: $_" -ForegroundColor Red
    }
}

# ==============================================================================
# RESUMEN FINAL
# ==============================================================================

Print-Header "RESUMEN DE TESTS"

Write-Host "`n✅ Tests Completados:" -ForegroundColor Green
Write-Host "   1. POST /api/tareas/voz/procesar"
Write-Host "   2. POST /api/tareas/voz/crear-desde-transcripcion"
Write-Host "   3. POST /api/tareas/voz/transcribir-audio"
Write-Host "   4. Casos de Prueba Adicionales (4 casos)"

Write-Host "`n📊 Endpoints Disponibles:" -ForegroundColor Green
Write-Host "   • POST $BASE_URL/api/tareas/voz/procesar"
Write-Host "   • POST $BASE_URL/api/tareas/voz/crear-desde-transcripcion"
Write-Host "   • POST $BASE_URL/api/tareas/voz/transcribir-audio"

Write-Host "`n💡 Próximos Pasos:" -ForegroundColor Green
Write-Host "   1. Configurar API en PROD"
Write-Host "   2. Integrar con Flutter UI (Centro de Comando)"
Write-Host "   3. Conectar WhatsApp bot para crear tareas por audio"

Write-Host "`n" -ForegroundColor Gray
