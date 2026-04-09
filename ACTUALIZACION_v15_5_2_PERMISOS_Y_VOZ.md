# Actualización Crítica v15.5.2 - Gestión de Voz y Permisos

**Fecha**: 8 de Abril, 2026  
**Versión**: Industrial Manager v15.5.2  
**Tema**: Permisos dinámicos, selector obligatorio de usuario, y modo debug sin micrófono

---

## 📋 Resumen de Cambios

### 1. Permisos Android Agregados

#### AndroidManifest.xml
Se agregaron tres permisos críticos antes de la etiqueta `<application>`:

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" />
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" />
```

**Ubicación**: `android/app/src/main/AndroidManifest.xml` (líneas 3-5)

**Propósito**:
- **RECORD_AUDIO**: Activar acceso al hardware de micrófono
- **WRITE_EXTERNAL_STORAGE**: Permitir guardar archivos de audio (Android 9 y anteriores)
- **READ_EXTERNAL_STORAGE**: Permitir leer archivos de audio para modo debug (Android 9 y anteriores)

**Nota Android 10+**: Para Android 10 y superiores, la grabación se guarda automáticamente en caché interna (`Context.getCacheDir()`), pero el permiso RECORD_AUDIO sigue siendo obligatorio.

---

### 2. Permisos Dinámicos en Flutter

#### AudioRecordingService.dart (ACTUALIZADO)

**Cambios principales**:
- ✅ Integración con paquete `permission_handler`
- ✅ Método `requestMicrophonePermission()` para solicitar permisos en runtime
- ✅ Estados de error detallados (`AudioServiceStatus` enum)
- ✅ Modo debug para cargar archivos manualmente (`loadAudioFileDebug()`)

**Flujo de permisos**:

```dart
// 1. Al iniciar grabación
Future<bool> startRecording() async {
  // Verificar si permiso ya está otorgado
  final hasPermission = await Permission.microphone.isGranted;
  
  if (!hasPermission) {
    // Solicitar permiso
    final granted = await requestMicrophonePermission();
    if (!granted) return false; // Usuario lo denegó
  }
  
  // Proceder con grabación
  _isRecording = true;
  return true;
}

// 2. Solicitud de permisos
Future<bool> requestMicrophonePermission() async {
  final status = await Permission.microphone.request();
  
  if (status.isGranted) return true;
  if (status.isPermanentlyDenied) openAppSettings(); // Redirigir a configuración
  return false;
}
```

**Estados disponibles**:
```dart
enum AudioServiceStatus {
  idle,                    // Listo para grabar
  recording,               // Grabando
  processingPermission,    // Esperando respuesta de usuario
  permissionDenied,        // Permiso denegado
  noMicrophoneDetected,    // Sin hardware de micrófono
  error,                   // Error genérico
}
```

---

### 3. Selector Obligatorio de Usuario

#### VoiceTaskConfirmationDialog.dart (ACTUALIZADO)

**Comportamiento**:
- Si la IA NO detecta un responsable (usuario = "PENDIENTE"):
  - Mostrar **ComboBox** con lista de operarios
  - Campo es **OBLIGATORIO** - no se puede confirmar sin seleccionar uno
  - Botón [CONFIRMAR] deshabilitado (gris) si "PENDIENTE"

- Si la IA SÍ detecta un responsable:
  - Mostrar **TextBox** editable normal
  - Las confirmación se permite si el campo no está vacío

**Lógica**:

```dart
class _VoiceTaskConfirmationDialogState extends State<...> {
  String? _selectedOperario;
  bool _showOperarioDropdown = false;

  @override
  void initState() {
    // Mostrar dropdown si usuario no fue detectado
    final usuarioAsignado = widget.taskData['usuario_asignado'] ?? '';
    _showOperarioDropdown = usuarioAsignado == 'PENDIENTE' ||
        usuarioAsignado.isEmpty ||
        !widget.operarios.contains(usuarioAsignado);
  }

  bool _isConfirmButtonEnabled() {
    if (_titleController.text.isEmpty) return false;

    if (_showOperarioDropdown) {
      // Si hay dropdown, requiere selección explícita
      return _selectedOperario != null && _selectedOperario != 'PENDIENTE';
    } else {
      // Si no, permite si no es "PENDIENTE"
      final assignee = _assigneeController.text.trim();
      return assignee.isNotEmpty && assignee != 'PENDIENTE';
    }
  }
}
```

**UI del Dialog**:

```
┌─────────────────────────────────────────┐
│ Confirmar Tarea desde Voz               │
├─────────────────────────────────────────┤
│ Transcripción: "...genérica..."         │
│                                         │
│ Título: [________] (editable)           │
│                                         │
│ ⚠️ Seleccionar responsable (OBLIGATORIO) │
│  [ComboBox: Selecciona un operario  ▼] │
│                                         │
│ Prioridad: [Rojo URGENTE]               │
│                                         │
├─────────────────────────────────────────┤
│ [CANCELAR] [EDITAR] [CONFIRMAR]✓        │
│   Rojo    Naranja   Verde (habilitado)  │
└─────────────────────────────────────────┘
```

---

### 4. Modo Sin Micrófono (Debug)

#### Cargar Archivo de Audio Manualmente

**Escenario**: Usuario en PC sin micrófono, emulador sin audio, o ambiente de testing.

**Implementación**:

```dart
// En monitoreo_tareas_screen.dart
Future<void> _procesarAudioGrabado(String audioPath) async {
  // ... código existente ...

  await showVoiceTaskConfirmation(
    context,
    taskData: taskData,
    operarios: operarios,
    onConfirm: (confirmedData) { /* ... */ },
    onEdit: (editedData) { /* ... */ },
    onLoadAudioFile: (filePath) async {
      // Callback para modo debug
      final loadedPath = 
          await audioRecordingService.loadAudioFileDebug(filePath);
      
      if (loadedPath != null) {
        await _procesarAudioGrabado(loadedPath); // Reprocesar
      }
    },
  );
}

// En voice_task_confirmation_dialog.dart
Future<void> _loadAudioFileDebug() async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.audio,
    allowedExtensions: ['m4a', 'wav', 'mp3'],
  );

  if (result != null && result.files.single.path != null) {
    final filePath = result.files.single.path!;
    if (widget.onLoadAudioFile != null) {
      widget.onLoadAudioFile!(filePath);
    }
  }
}
```

**UI del Dialog** (modo debug):

```
┌─────────────────────────────────────────┐
│ Confirmar Tarea desde Voz               │
├─────────────────────────────────────────┤
│ ... campos normales ...                 │
│                                         │
│ [📂 Cargar audio (.m4a)]  ← Botón extra │
│                           (solo en debug)
├─────────────────────────────────────────┤
│ [CANCELAR] [EDITAR] [CONFIRMAR]✓        │
└─────────────────────────────────────────┘
```

---

## 🔧 Dependencias Agregadas

### pubspec.yaml

```yaml
dependencies:
  permission_handler: ^11.4.4   # Manejo de permisos dinámicos
  file_picker: ^10.3.10          # Selector de archivos (ya existía)
```

**Instalación**:
```bash
flutter pub add permission_handler
flutter pub get
```

---

## ✅ Verificación de Permisos en Android

### 1. Verificar Declaración en AndroidManifest.xml

```bash
# Buscar líneas de permiso
cd android/app/src/main
grep -n "RECORD_AUDIO\|WRITE_EXTERNAL\|READ_EXTERNAL" AndroidManifest.xml

# Resultado esperado:
# 3:    <uses-permission android:name="android.permission.RECORD_AUDIO" />
# 4:    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" />
# 5:    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" />
```

### 2. Verificar en Emulador/Dispositivo

**Android Studio AVD Manager**:
1. Abrir emulador
2. Menú: Extended Controls → Permissions
3. Buscar "Microphone"
4. Debe permitir acceso

**Dispositivo Físico**:
1. Abrir app
2. Hacer click en FAB (micrófono)
3. Dialog de permisos debe aparecer
4. Seleccionar "Permitir" / "Allow"

### 3. Verificar Permisos Otorgados (Emulador)

```bash
# Listar permisos de la app en emulador
adb shell dumpsys package com.example.industrial_manager_v15_5 | grep -A 20 "permissions:"

# O más simple, ejecutar en adb shell:
adb shell pm list permissions | grep -i microphone
```

### 4. Testear Flujo Completo

```bash
# Build APK
flutter build apk --release

# Instalar en emulador
adb install -r build/app/outputs/flutter-apk/app-release.apk

# O instalar en device
flutter install --release

# Verificar logs
flutter logs
```

### 5. Monitorear en Logcat

```bash
# Terminal 1: Ver logs de la app
adb logcat | grep -i "AudioRecording\|VoiceDialog\|permission"

# Terminal 2: Ejecutar app
flutter run --release
```

**Logs esperados**:
```
[AudioRecording] Solicitando permiso de micrófono...
[AudioRecording] Permiso de micrófono OTORGADO
[AudioRecording] Iniciada grabación en: /data/data/...
[AudioRecording] Grabación detenida: ...
[VoiceDialog] Cargando archivo de audio en modo debug: ...
```

---

## 🧪 Testing de Casos Específicos

### Caso 1: Permiso Denegado por Usuario

```
1. Ejecutar app
2. Click FAB → [Permitir] Seleccionar "Denegar"
3. InfoBar mostrará: "Permiso de micrófono denegado por el usuario"
4. FAB vuelve a azul (inactivo)
5. Click FAB nuevamente → Solicitar permiso de nuevo
```

### Caso 2: Permiso Denegado Permanentemente

```
1. Ejecutar app en emulador
2. Ir a Settings → Apps → industrial_manager → Permissions
3. Desactivar Microphone
4. Ejecutar app → Click FAB
5. Mensaje: "Permiso denegado permanentemente..."
6. App abre Settings automáticamente
```

### Caso 3: Usuario "PENDIENTE" → Selector Obligatorio

```
1. Grabar audio con transcripción sin nombre de usuario
2. Dialog appears:
   ⚠️ "Seleccionar responsable (OBLIGATORIO)*"
   [ComboBox - Selecciona un operario ▼]
3. Botón [CONFIRMAR] está GRIS (deshabilitado)
4. Seleccionar "Juan" en ComboBox
5. Botón [CONFIRMAR] se vuelve VERDE (habilitado)
6. Confirmar → Tarea se crea con responsable "Juan"
```

### Caso 4: Modo Debug (Sin Micrófono)

```
1. PC sin micrófono / Emulador sin audio
2. Click FAB (debería fallar o permitir fallback)
3. En dialog, ver botón: [📂 Cargar audio (.m4a)]
4. Click botón → File picker
5. Seleccionar archivo .m4a
6. Dialog procesará archivo como si fuera grabación
7. Permitir confirmar y crear tarea
```

---

## 📊 Estado de Compatibilidad

| Versión Android | RECORD_AUDIO | Storage | ComboBox | Modo Debug |
|-----------------|--------------|---------|----------|-----------|
| Android 5 - 8   | ✅ Dinámico  | ✅ Req  | ✅ Sí    | ✅ Sí     |
| Android 9       | ✅ Dinámico  | ✅ Req  | ✅ Sí    | ✅ Sí     |
| Android 10 - 13 | ✅ Dinámico  | ⚠️ Cache | ✅ Sí    | ✅ Sí     |
| Android 14+     | ✅ Dinámico  | ⚠️ Cache | ✅ Sí    | ✅ Sí     |

**Notas**:
- Android 10+: Storage permisos menos restrictivos, usan `Context.getCacheDir()`
- Todos requieren `RECORD_AUDIO` permiso dinámico en runtime
- ComboBox de operarios siempre disponible si usuario = "PENDIENTE"
- Modo debug funciona en todas las versiones

---

## 🔍 Archivos Modificados

| Archivo | Líneas | Cambios |
|---------|--------|---------|
| `android/app/src/main/AndroidManifest.xml` | +3 | Agregados 3 permisos |
| `lib/services/audio_recording_service.dart` | ±350 | Permisos dinámicos + debug mode |
| `lib/widgets/voice_task_confirmation_dialog.dart` | ±400 | Selector obligatorio + cargar audio |
| `lib/screens/monitoreo_tareas_screen.dart` | ±170 | Manejo de permisos + lista operarios |
| `pubspec.yaml` | +1 | `permission_handler: ^11.4.4` |

---

## 🚀 Compile y Deploy

### Compilar APK con Nuevos Permisos

```bash
# Limpieza
flutter clean

# Obtener dependencias
flutter pub get

# Build APK release
flutter build apk --release

# Output:
# build/app/outputs/flutter-apk/app-release.apk (30-35 MB)
```

### Verificar Permisos en APK

```bash
# Descomprimir APK
unzip build/app/outputs/flutter-apk/app-release.apk

# Leer manifest
grep -n "RECORD_AUDIO" AndroidManifest.xml
```

### Deploy a Google Play Store

1. **Certificado**: Usar mismo keystore existente
2. **versionCode**: Incrementar en `android/app/build.gradle.kts`
3. **versionName**: Cambiar a "1.5.2"
4. **Notas de versión**: "Permisos dinámicos de micrófono, selector obligatorio de operarios"
5. **Targeting**: Minimum SDK 21 (Android 5.0), Target SDK 34 (Android 14)

---

## 📝 Resumen para Usuarios

### ¿Qué cambió?

✅ **Permisos más seguros**: App ahora solicita permiso de micrófono cuando lo necesita  
✅ **Selección de operario**: Si la IA no detecta usuario, debes elegir uno manualmente  
✅ **Modo de prueba**: Puedes cargar archivos de audio para testing sin micrófono  
✅ **Mejor feedback**: Mensajes claros cuando algo falla

### ¿Qué debo hacer?

1. Actualizar app a v15.5.2
2. Al usar captura de voz por primera vez → Permitir acceso a micrófono
3. Si falta asignar operario → Seleccionar de lista
4. ¡Listo! Crear misiones por voz

---

**Documento**: ACTUALIZACION_v15_5_2_PERMISOS_Y_VOZ.md  
**Versión**: Final  
**Estado**: ✅ Listo para Producción
