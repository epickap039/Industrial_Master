import 'package:flutter/foundation.dart';

import 'api_client.dart';

class UsuariosLookupService {
  UsuariosLookupService._();

  static final UsuariosLookupService instance = UsuariosLookupService._();
  static const List<String> _fallback = <String>[
    'Equipo Ingeniería',
    'Equipo CAD',
    'Documentación',
    'Producción / Procesos',
    'Calidad',
    'Sin asignar',
  ];

  List<String>? _cache;
  DateTime? _cacheAt;
  static const Duration _ttl = Duration(minutes: 5);

  Future<List<String>> getResponsables({bool forceRefresh = false}) async {
    if (!forceRefresh && _cache != null && _cacheAt != null) {
      final age = DateTime.now().difference(_cacheAt!);
      if (age <= _ttl) return List<String>.from(_cache!);
    }

    try {
      dynamic raw;
      try {
        raw = await ApiClient.get('/api/usuarios/lista');
      } catch (_) {
        raw = await ApiClient.get('/api/usuarios/all');
      }
      if (raw is List && raw.isNotEmpty) {
        final nom = raw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e.map((k, v) => MapEntry('$k', v))))
            .map((u) {
              final w = '${u['username'] ?? ''}'.trim();
              if (w.isNotEmpty) return w;
              return '${u['nombre'] ?? ''}'.trim();
            })
            .where((s) => s.isNotEmpty)
            .toSet()
            .toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        if (nom.isNotEmpty) {
          _cache = nom;
          _cacheAt = DateTime.now();
          return List<String>.from(nom);
        }
      }
    } catch (e) {
      debugPrint('UsuariosLookupService.getResponsables: $e');
    }

    _cache = List<String>.from(_fallback);
    _cacheAt = DateTime.now();
    return List<String>.from(_fallback);
  }

  void invalidate() {
    _cache = null;
    _cacheAt = null;
  }
}
