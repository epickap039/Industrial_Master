import 'api_client.dart';

/// Dedupe y TTL en memoria para [GET /api/tareas/lista], compartido entre lobby,
/// campana del app bar, monitoreo y buzon modal, sin cambiar la forma en que cada
/// pantalla procesa la lista (prune, recordatorios, etc.).
class TareasListaCoordinator {
  TareasListaCoordinator._();
  static final TareasListaCoordinator instance = TareasListaCoordinator._();

  static const Duration _ttl = Duration(seconds: 10);

  List<Map<String, dynamic>>? _cache;
  DateTime? _fetchedAt;
  Future<void>? _inFlight;

  /// Invalida cache tras mutaciones en servidor (tareas).
  void invalidate() {
    _cache = null;
    _fetchedAt = null;
  }

  List<Map<String, dynamic>> _copyRows(List<Map<String, dynamic>> src) {
    return src.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  bool get _cacheFresh {
    if (_cache == null || _fetchedAt == null) return false;
    return DateTime.now().difference(_fetchedAt!) < _ttl;
  }

  /// [force] omite cache y TTL. Peticiones simultaneas comparten la misma espera en red.
  Future<List<Map<String, dynamic>>> fetchLista({bool force = false}) async {
    while (_inFlight != null) {
      try {
        await _inFlight!;
      } catch (_) {}
    }
    if (force) {
      invalidate();
    }
    if (!force && _cacheFresh && _cache != null) {
      return _copyRows(_cache!);
    }

    Future<void> runner() async {
      try {
        await _fetchFromNetwork();
      } finally {
        _inFlight = null;
      }
    }

    _inFlight = runner();
    try {
      await _inFlight!;
    } catch (e) {
      if (_cache != null) {
        return _copyRows(_cache!);
      }
      rethrow;
    }
    if (_cache == null) {
      throw StateError('Cache de tareas no inicializada tras red');
    }
    return _copyRows(_cache!);
  }

  Future<void> _fetchFromNetwork() async {
    final raw = await ApiClient.get('/api/tareas/lista');
    if (raw is! List) {
      throw StateError('Respuesta /api/tareas/lista no es lista');
    }
    final list = <Map<String, dynamic>>[];
    for (final e in raw) {
      if (e is Map) {
        list.add(Map<String, dynamic>.from(e.map((k, v) => MapEntry('$k', v))));
      }
    }
    _cache = list;
    _fetchedAt = DateTime.now();
  }
}
