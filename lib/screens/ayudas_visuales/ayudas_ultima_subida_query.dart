import 'package:intl/intl.dart';

import '../../services/api_client.dart';
import 'ayudas_api_models.dart';

/// Consulta la ayuda visual más reciente (por fecha de subida) recorriendo categorías.
/// Usado por lobby Producción y por la campana de la barra (sin endpoint agregado).
class AyudasUltimaSubidaQuery {
  AyudasUltimaSubidaQuery._();

  static String? signatureFor(Map<String, dynamic>? m) {
    if (m == null) return null;
    final idA = ayudasIdAyuda(m);
    final idR = ayudasIdRevision(m);
    if (idA <= 0 || idR <= 0) return null;
    return '$idA:$idR';
  }

  static DateTime? _parseAyudaDate(Map<String, dynamic> m) {
    final raw = ayudasFechaSubida(m);
    if (raw == null) return null;
    if (raw is DateTime) return raw;
    final s = raw.toString().trim();
    if (s.isEmpty || s == '-') return null;
    return DateTime.tryParse(s) ??
        DateTime.tryParse(s.replaceFirst(' ', 'T')) ??
        DateFormat('dd/MM/yyyy HH:mm').tryParse(s) ??
        DateFormat('yyyy-MM-dd HH:mm').tryParse(s);
  }

  static int _categoriaId(Map<String, dynamic> cm) {
    final raw =
        cm['ID_Categoria'] ??
        cm['id_categoria'] ??
        cm['Id_Categoria'] ??
        cm['id'] ??
        cm['Id'];
    if (raw is int) return raw;
    return int.tryParse('$raw') ?? 0;
  }

  /// Devuelve el mapa del documento/revisión más reciente, o null si no hay datos.
  static Future<Map<String, dynamic>?> fetchLatest() async {
    try {
      final catsRaw = await ApiClient.get('/api/ayudas/categorias');
      final cats = catsRaw is List ? catsRaw : <dynamic>[];
      Map<String, dynamic>? latest;
      DateTime? latestDate;

      for (final c in cats) {
        if (c is! Map) continue;
        final cm = Map<String, dynamic>.from(
          c.map((k, v) => MapEntry('$k', v)),
        );
        final id = _categoriaId(cm);
        if (id <= 0) continue;
        List<dynamic> list = const [];
        try {
          final data = await ApiClient.get('/api/ayudas/lista/$id');
          list = data is List ? data : <dynamic>[];
        } catch (_) {
          list = const [];
        }
        for (final row in list) {
          if (row is! Map) continue;
          final m = Map<String, dynamic>.from(
            row.map((k, v) => MapEntry('$k', v)),
          );
          final d = _parseAyudaDate(m);
          if (d != null) {
            if (latestDate == null || d.isAfter(latestDate)) {
              latestDate = d;
              latest = m;
            }
          } else if (latest == null) {
            latest = m;
          }
        }
      }
      return latest;
    } catch (_) {
      return null;
    }
  }
}
