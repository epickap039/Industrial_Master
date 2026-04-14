import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';

class AyudasOfflineCacheService {
  AyudasOfflineCacheService._();

  static final AyudasOfflineCacheService instance = AyudasOfflineCacheService._();

  static const String _kCategoriasSnapshot = 'ayudas_cache_categorias_v1';
  static const String _kCategoriaListaPrefix = 'ayudas_cache_lista_categoria_';
  static const String _kAyudaHistorialPrefix = 'ayudas_cache_historial_';
  static const String _kPdfIndex = 'ayudas_cache_pdf_index_v1';
  static const int _kMaxPdfCacheBytes = 180 * 1024 * 1024;

  Future<SharedPreferences> get _prefs async => SharedPreferences.getInstance();

  Future<void> saveCategoriasSnapshot(List<dynamic> categorias) async {
    final p = await _prefs;
    await p.setString(_kCategoriasSnapshot, jsonEncode(categorias));
  }

  Future<List<dynamic>?> readCategoriasSnapshot() async {
    final p = await _prefs;
    final raw = p.getString(_kCategoriasSnapshot);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is List ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveCategoriaListaSnapshot(int idCategoria, List<dynamic> docs) async {
    final p = await _prefs;
    await p.setString('$_kCategoriaListaPrefix$idCategoria', jsonEncode(docs));
  }

  Future<List<dynamic>?> readCategoriaListaSnapshot(int idCategoria) async {
    final p = await _prefs;
    final raw = p.getString('$_kCategoriaListaPrefix$idCategoria');
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is List ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveHistorialSnapshot(int idAyuda, List<dynamic> historial) async {
    final p = await _prefs;
    await p.setString('$_kAyudaHistorialPrefix$idAyuda', jsonEncode(historial));
  }

  Future<List<dynamic>?> readHistorialSnapshot(int idAyuda) async {
    final p = await _prefs;
    final raw = p.getString('$_kAyudaHistorialPrefix$idAyuda');
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is List ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List> fetchAndCachePdfBytes(int idRevision) async {
    final bytes = await ApiClient.getBytes('/api/ayudas/ver/$idRevision');
    await _storePdfBytes(idRevision, bytes);
    return bytes;
  }

  Future<Uint8List?> readCachedPdfBytes(int idRevision) async {
    final index = await _loadPdfIndex();
    final key = '$idRevision';
    final row = index[key];
    if (row == null) return null;
    final path = (row['path'] ?? '').toString();
    if (path.isEmpty) return null;
    final file = File(path);
    if (!await file.exists()) {
      index.remove(key);
      await _savePdfIndex(index);
      return null;
    }
    final bytes = await file.readAsBytes();
    row['lastAccess'] = DateTime.now().millisecondsSinceEpoch;
    index[key] = row;
    await _savePdfIndex(index);
    return bytes;
  }

  Future<void> _storePdfBytes(int idRevision, Uint8List bytes) async {
    final dir = await _pdfCacheDir();
    final file = File('${dir.path}/rev_$idRevision.pdf');
    await file.writeAsBytes(bytes, flush: true);

    final index = await _loadPdfIndex();
    index['$idRevision'] = {
      'path': file.path,
      'size': bytes.lengthInBytes,
      'lastAccess': DateTime.now().millisecondsSinceEpoch,
    };
    await _prunePdfCache(index);
  }

  Future<Directory> _pdfCacheDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/ayudas_pdf_cache');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<Map<String, Map<String, dynamic>>> _loadPdfIndex() async {
    final p = await _prefs;
    final raw = p.getString(_kPdfIndex);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final out = <String, Map<String, dynamic>>{};
      for (final entry in decoded.entries) {
        final k = '${entry.key}';
        final v = entry.value;
        if (v is Map) {
          out[k] = Map<String, dynamic>.from(v);
        }
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<void> _savePdfIndex(Map<String, Map<String, dynamic>> index) async {
    final p = await _prefs;
    await p.setString(_kPdfIndex, jsonEncode(index));
  }

  Future<void> _prunePdfCache(Map<String, Map<String, dynamic>> index) async {
    var totalBytes = index.values.fold<int>(0, (acc, row) {
      final n = row['size'];
      if (n is int) return acc + n;
      return acc + (int.tryParse('$n') ?? 0);
    });
    if (totalBytes <= _kMaxPdfCacheBytes) {
      await _savePdfIndex(index);
      return;
    }
    final items = index.entries.toList()
      ..sort((a, b) {
        final aa = int.tryParse('${a.value['lastAccess'] ?? 0}') ?? 0;
        final bb = int.tryParse('${b.value['lastAccess'] ?? 0}') ?? 0;
        return aa.compareTo(bb);
      });
    for (final item in items) {
      if (totalBytes <= _kMaxPdfCacheBytes) break;
      final path = (item.value['path'] ?? '').toString();
      if (path.isNotEmpty) {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      }
      final size = int.tryParse('${item.value['size'] ?? 0}') ?? 0;
      totalBytes -= size;
      index.remove(item.key);
    }
    await _savePdfIndex(index);
  }
}
