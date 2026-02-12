import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

class DatabaseHelper {
  static String get pythonPath => 'python';

  /// Valida que data_bridge.exe exista (CRÍTICO)
  static bool validateCriticalFiles() {
    if (kIsWeb) return true;
    final String exePath = getScriptPath('data_bridge.exe');
    return File(exePath).existsSync();
  }

  /// Retorna el path del ejecutable crítico para diagnóstico
  static String getCriticalFilePath() {
    return getScriptPath('data_bridge.exe');
  }

  static String getScriptPath(String name) {
    if (kIsWeb) return '';

    // Release path logic: relative to the executable
    final String baseDir = p.dirname(Platform.resolvedExecutable);
    
    // 1. Try in 'scripts' subfolder (Preferred)
    final String scriptsPath = p.join(baseDir, 'scripts', name);
    if (File(scriptsPath).existsSync()) return scriptsPath;
    
    // 2. Try in root folder (Fallback)
    final String rootPath = p.join(baseDir, name);
    if (File(rootPath).existsSync()) return rootPath;

    // Debug path logic: look for scripts folder in project root (dev mode)
    // Also try root for dev mode just in case
    final String devScriptsPath = p.join('scripts', name);
    if (File(devScriptsPath).existsSync()) return devScriptsPath;

    return p.join('scripts', name); // Default to scripts folder structure
  }

  Future<dynamic> _runScript(
    String script,
    List<String> args, {
    String? stdinInput,
  }) async {
    try {
      // En modo Release usamos el ejecutable compilado; en Debug seguimos con Python
      final bool isRelease = kReleaseMode;
      final String executable =
          isRelease ? getScriptPath('data_bridge.exe') : pythonPath;

      final List<String> finalArgs =
          isRelease
              ? args // En release, ejecutamos el .exe directamente, sin "python" delante
              : [getScriptPath(script), ...args];

      String rawStdout = '';
      String rawStderr = '';
      int exitCode = 0;

      if (stdinInput != null) {
        final process = await Process.start(executable, finalArgs);
        process.stdin.writeln(stdinInput);
        await process.stdin.flush();
        await process.stdin.close();

        rawStdout = await process.stdout.transform(utf8.decoder).join();
        rawStderr = await process.stderr.transform(utf8.decoder).join();
        exitCode = await process.exitCode;
      } else {
        final result = await Process.run(executable, finalArgs);
        rawStdout = result.stdout.toString();
        rawStderr = result.stderr.toString();
        exitCode = result.exitCode;
      }

      rawStdout = rawStdout.trim();
      rawStderr = rawStderr.trim();

      if (exitCode != 0) {
        throw Exception("Python Exit $exitCode: $rawStderr");
      }

      if (rawStdout.isEmpty) return null;

      // Safe JSON decoding
      try {
        final data = jsonDecode(rawStdout);
        // If python returned an error object, throw it
        if (data is Map && data.containsKey('error')) {
          throw Exception(data['error']);
        }
        return data;
      } catch (e) {
        // Fallback: try to find the last valid JSON line
        final lines = rawStdout.split('\n');
        for (var line in lines.reversed) {
          try {
            final data = jsonDecode(line.trim());
            if (data is Map && data.containsKey('error')) {
              throw Exception(data['error']);
            }
            return data;
          } catch (_) {}
        }
        if (rawStdout.length > 500) {
          throw Exception("Error de formato en respuesta del backend (Dato demasiado grande o corrupto).");
        }
        throw Exception("Error de interpretación de datos (JSON Inválido).");
      }
    } catch (e) {
      throw Exception("$e");
    }
  }

  /// Ejecuta diagnóstico del sistema
  Future<Map<String, dynamic>> runDiagnostics() async {
    try {
      // Verificar existencia de data_bridge.exe
      final exePath = DatabaseHelper.getCriticalFilePath();
      final exeExists = File(exePath).existsSync();
      
      if (!exeExists) {
        return {
          'status': 'error',
          'message': 'CRÍTICO: data_bridge.exe no encontrado',
          'path': exePath,
          'backend': false,
          'connection': false,
        };
      }

      // Intentar conexión de prueba
      try {
        final connResult = await testConnection();
        return {
          'status': 'success',
          'message': 'Sistema operativo correctamente',
          'path': exePath,
          'backend': true,
          'connection': connResult['status'] == 'success',
          'connection_detail': connResult['message'] ?? '',
        };
      } catch (e) {
        return {
          'status': 'warning',
          'message': 'Backend OK, pero sin conexión a BD',
          'path': exePath,
          'backend': true,
          'connection': false,
          'error': e.toString(),
        };
      }
    } catch (e) {
      return {
        'status': 'error',
        'message': 'Error en diagnóstico: $e',
        'backend': false,
        'connection': false,
      };
    }
  }

  Future<List<Map<String, dynamic>>> getMaster() async {
    final res = await _runScript('data_bridge.py', ['get_all']);
    if (res is List) return List<Map<String, dynamic>>.from(res);
    return [];
  }

  Future<List<Map<String, dynamic>>> getConflicts() async {
    final res = await _runScript('data_bridge.py', ['conflicts']);
    if (res is List) return List<Map<String, dynamic>>.from(res);
    return [];
  }

  Future<List<Map<String, dynamic>>> getHistory(String code) async {
    final res = await _runScript('data_bridge.py', ['history', '--code', code]);
    if (res is List) return List<Map<String, dynamic>>.from(res);
    return [];
  }

  Future<Map<String, dynamic>?> fetchPart(String code) async {
    final res = await _runScript('data_bridge.py', ['fetch', '--code', code]);
    if (res is List && res.isNotEmpty) return res.first;
    return null;
  }

  Future<Map<String, dynamic>> updateMaster(
    String code,
    Map<String, dynamic> data, {
    bool forceResolve = false,
    String? resolutionStatus,
  }) async {
    final jsonString = jsonEncode(data);
    final base64Payload = base64Encode(utf8.encode(jsonString));

    // Using stdin instead of args for robustness
    final args = ['update', '--code', code, '--stdin'];
    if (forceResolve) args.add('--force_resolve');
    if (resolutionStatus != null) {
      args.addAll(['--status', resolutionStatus]);
    }
    
    final res = await _runScript(
      'data_bridge.py',
      args,
      stdinInput: base64Payload,
    );
    
    if (res != null && res['status'] == 'success') {
       return Map<String, dynamic>.from(res);
    }
    throw Exception(res?['message'] ?? 'Error desconocido al actualizar master');
  }

  Future<Map<String, dynamic>> deleteMaster(String code) async {
    final res = await _runScript('data_bridge.py', ['delete', '--code', code]);
    if (res != null && res['status'] == 'success') {
      return Map<String, dynamic>.from(res);
    }
    throw Exception(res?['message'] ?? 'Error al borrar pieza del maestro');
  }

  Future<bool> insertMaster(Map<String, dynamic> data) async {
    final jsonString = jsonEncode(data);
    final base64Payload = base64Encode(utf8.encode(jsonString));

    final res = await _runScript('data_bridge.py', [
      'insert',
      '--stdin',
    ], stdinInput: base64Payload);
    return res != null && res['status'] == 'success';
  }

  Future<bool> exportExcel(List<Map<String, dynamic>> data) async {
    final res = await _runScript('exporter.py', [
      '--payload',
      jsonEncode(data),
    ]);
    return res != null && res['status'] == 'success';
  }

  Stream<String> runImporter({required String folderPath}) async* {
    final path = getScriptPath('carga_inicial.py');
    final process = await Process.start(
      pythonPath,
      [path, '--folder', folderPath],
      environment: {'PYTHONIOENCODING': 'utf-8'},
    );

    yield* process.stdout.transform(const Utf8Decoder(allowMalformed: true));
    yield* process.stderr.transform(const Utf8Decoder(allowMalformed: true));
  }

  Future<List<Map<String, dynamic>>> getHomologation(String code) async {
    final res = await _runScript('data_bridge.py', [
      'homologation',
      '--code',
      code,
    ]);
    if (res is List) return List<Map<String, dynamic>>.from(res);
    return [];
  }

  Future<List<Map<String, dynamic>>> getResolvedTasks() async {
    final res = await _runScript('data_bridge.py', ['get_resolved']);
    if (res is List) return List<Map<String, dynamic>>.from(res);
    return [];
  }

  Future<String?> exportFullMaster() async {
    final res = await _runScript('data_bridge.py', ['export_master']);
    if (res != null && res['status'] == 'success') {
      return res['path'];
    }
    return null;
  }

  Future<List<Map<String, dynamic>>> getPendingTasks() async {
    final res = await _runScript('data_bridge.py', ['get_pending']);
    if (res is List) return List<Map<String, dynamic>>.from(res);
    return [];
  }

  Future<bool> markTaskCorrected(int id) async {
    final res = await _runScript('data_bridge.py', [
      'mark_corrected',
      '--id',
      id.toString(),
    ]);
    return res != null && res['status'] == 'success';
  }

  Future<Map<String, dynamic>> getConfig() async {
    try {
      final String baseDir = File(Platform.resolvedExecutable).parent.path;
      final String configPath = '$baseDir\\scripts\\config.json';
      final file =
          File(configPath).existsSync()
              ? File(configPath)
              : File('scripts\\config.json');

      if (!file.existsSync()) return {};
      return jsonDecode(await file.readAsString());
    } catch (e) {
      return {};
    }
  }

  Future<void> saveConfig(Map<String, dynamic> config) async {
    final String baseDir = File(Platform.resolvedExecutable).parent.path;
    final String releasePath = '$baseDir\\scripts\\config.json';
    final file =
        File(releasePath).existsSync()
            ? File(releasePath)
            : File('scripts\\config.json');

    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(config),
    );
  }

  Future<Map<String, dynamic>> testConnection() async {
    final res = await _runScript('data_bridge.py', ['test_connection']);
    if (res != null) return Map<String, dynamic>.from(res);
    return {'status': 'error', 'message': 'No response from script'};
  }

  Future<Map<String, dynamic>> findBlueprint(String code) async {
    final res = await _runScript('data_bridge.py', [
      'find_blueprint',
      '--code',
      code,
    ]);
    if (res != null) return Map<String, dynamic>.from(res);
    return {'status': 'error', 'message': 'Error al buscar plano'};
  }

  Future<Map<String, dynamic>> runSentinelDiagnostics() async {
    try {
      final res = await _runScript('data_bridge.py', ['diagnostic']);
      if (res != null) return Map<String, dynamic>.from(res);
      return {
        'steps': {},
        'raw_log': 'Error: No se recibió respuesta del módulo SENTINEL.',
      };
    } catch (e) {
      return {
        'steps': {},
        'raw_log': 'Excepción crítica ejecutando SENTINEL: $e',
      };
    }
  }
}
