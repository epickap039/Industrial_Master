import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

enum AudioServiceStatus {
  idle,
  recording,
  processingPermission,
  permissionDenied,
  error,
}

/// Servicio de grabacion de audio usando el paquete [record].
/// Graba en formato AAC/M4A compatible con Whisper.
class AudioRecordingService {
  static const String _audioFileName = 'mision_voz.m4a';

  final AudioRecorder _recorder = AudioRecorder();

  bool _isRecording = false;
  String? _recordingPath;
  AudioServiceStatus _status = AudioServiceStatus.idle;
  String? _lastError;

  bool get isRecording => _isRecording;
  String? get recordingPath => _recordingPath;
  AudioServiceStatus get status => _status;
  String? get lastError => _lastError;

  Future<bool> requestMicrophonePermission() async {
    _status = AudioServiceStatus.processingPermission;
    try {
      final s = await Permission.microphone.request();
      if (s.isGranted) {
        _status = AudioServiceStatus.idle;
        return true;
      }
      _lastError = s.isPermanentlyDenied
          ? 'Permiso denegado permanentemente. Abre configuracion de la app.'
          : 'Permiso de microfono denegado.';
      _status = AudioServiceStatus.permissionDenied;
      if (s.isPermanentlyDenied) openAppSettings();
      return false;
    } catch (e) {
      _lastError = 'Error al solicitar permiso: $e';
      _status = AudioServiceStatus.error;
      return false;
    }
  }

  Future<String> _getTempPath() async {
    final dir = await getTemporaryDirectory();
    return '${dir.path}/$_audioFileName';
  }

  Future<bool> startRecording() async {
    try {
      if (!await Permission.microphone.isGranted) {
        final granted = await requestMicrophonePermission();
        if (!granted) return false;
      }

      if (_isRecording) return false;

      final path = await _getTempPath();
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
        ),
        path: path,
      );

      _recordingPath = path;
      _isRecording = true;
      _status = AudioServiceStatus.recording;
      _lastError = null;
      debugPrint('[AudioRecording] Grabacion iniciada: $path');
      return true;
    } catch (e) {
      _lastError = 'No se pudo iniciar la grabacion: $e';
      _status = AudioServiceStatus.error;
      _isRecording = false;
      debugPrint('[AudioRecording] Error al iniciar: $e');
      return false;
    }
  }

  Future<String?> stopRecording() async {
    try {
      if (!_isRecording) return null;
      final path = await _recorder.stop();
      _isRecording = false;
      _status = AudioServiceStatus.idle;
      debugPrint('[AudioRecording] Grabacion detenida: $path');
      return path;
    } catch (e) {
      _lastError = 'Error al detener grabacion: $e';
      _status = AudioServiceStatus.error;
      _isRecording = false;
      debugPrint('[AudioRecording] Error al detener: $e');
      return null;
    }
  }

  Future<void> cancelRecording() async {
    try {
      if (_isRecording) {
        await _recorder.cancel();
      }
      _isRecording = false;
      _status = AudioServiceStatus.idle;
      _recordingPath = null;
    } catch (e) {
      debugPrint('[AudioRecording] Error al cancelar: $e');
      _status = AudioServiceStatus.error;
    }
  }

  void dispose() {
    _recorder.dispose();
    _isRecording = false;
    _status = AudioServiceStatus.idle;
  }
}

final audioRecordingService = AudioRecordingService();
