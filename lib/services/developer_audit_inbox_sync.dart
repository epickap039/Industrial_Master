import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'app_role.dart';
import 'notification_inbox_service.dart';

/// Sondea [Tbl_Auditoria_Cambios] (import BOM, sync Excel, borrados, etc.) y
/// vuelca eventos nuevos al buzón local como avisos del sistema **del rol
/// desarrollador**.
///
/// Reglas (mayo 2026, ajuste por feedback de rendimiento):
///
/// - Las acciones rutinarias **por código** (`CREACION`, `MODIFICACION`,
///   `ACTUALIZACION_LINKS`, `EDICION_CATALOGO`, `UPDATE_MEDIDAS_CAD`, …)
///   se **consumen** del feed (para avanzar el cursor) pero **NO** crean
///   notificaciones: cargar 200 códigos en bloque generaba 200 entradas en
///   el buzón y alentaba la app.
/// - Solo emiten notificación las acciones consideradas **críticas/
///   destructivas o de auditoría general**: eliminaciones, borrados masivos,
///   purgas, restauraciones, importaciones BOM, cambios de roles, etc.
/// - Cuando una misma `(accion, usuario)` aparece varias veces en un mismo
///   ciclo de poll, se consolida en **una sola** entrada con conteo
///   ("Eliminación masiva (12 códigos)").
/// - El campo `usuario` del log se propaga como `assignedUser` para que el
///   buzón agrupe bajo el usuario real en vez de "Sin responsable".
class DeveloperAuditInboxSync {
  DeveloperAuditInboxSync._();

  static const String _sinceKey = 'dev_auditoria_since_id_v1';
  static const String _initKey = 'dev_auditoria_cursor_inited_v1';

  /// Acciones por-código rutinarias. Se consumen del feed pero NO generan
  /// notificación (evita una notificación por cada código que se sube).
  static const Set<String> _accionesIgnoradas = <String>{
    'CREACION',
    'MODIFICACION',
    'ACTUALIZACION_LINKS',
    'EDICION_CATALOGO',
    'UPDATE_MEDIDAS_CAD',
    'EDITAR_CATEGORIA_AYUDAS',
    'CREAR_CATEGORIA_AYUDAS',
  };

  /// Una acción se considera crítica (y por lo tanto, notificable) cuando su
  /// nombre menciona alguna de estas raíces. Cualquier otra acción no listada
  /// arriba como ignorada **también** se notifica (modo conservador), pero
  /// siempre consolidada por usuario.
  static bool _esCritica(String accion) {
    final a = accion.toUpperCase();
    const palabras = <String>[
      'ELIMIN',
      'BORR',
      'DELETE',
      'PURGA',
      'MASIV',
      'RESTORE',
      'RESTAUR',
      'IMPORT',
      'ROL',
      'PERMIS',
    ];
    for (final p in palabras) {
      if (a.contains(p)) return true;
    }
    return false;
  }

  /// Solo rol [AppRole.desarrollador]. Requiere token JWT en prefs.
  static Future<void> pollIfDeveloper(String effectiveRoleRaw) async {
    if (parseAppRole(effectiveRoleRaw) != AppRole.desarrollador) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final inited = prefs.getBool(_initKey) ?? false;
      var since = prefs.getInt(_sinceKey) ?? 0;

      final res = await ApiClient.getUnvalidated(
        '/api/dev/auditoria_delta',
        queryParameters: {'since_id': '$since'},
      );
      if (res.statusCode != 200) return;

      final decoded = res.decodeJsonLenient();
      if (decoded is! Map) return;
      final maxTable = int.tryParse('${decoded['max_id']}') ?? 0;
      final rawItems = decoded['items'];
      if (rawItems is! List) return;

      if (!inited) {
        await prefs.setInt(_sinceKey, maxTable);
        await prefs.setBool(_initKey, true);
        return;
      }

      var newSince = since;
      // Agrupado por (accion, usuario) → códigos involucrados en este poll.
      final agrupado = <String, List<String>>{};
      // Mantiene el id_log más alto visto para cada grupo (para id estable).
      final maxIdPorGrupo = <String, int>{};

      for (final raw in rawItems) {
        if (raw is! Map) continue;
        final idLog = int.tryParse('${raw['id_log']}') ?? 0;
        if (idLog <= 0) continue;
        if (idLog > newSince) newSince = idLog;

        final accion = '${raw['accion'] ?? ''}'.trim();
        final usuario = '${raw['usuario'] ?? ''}'.trim();
        final codigo = '${raw['codigo'] ?? ''}'.trim();

        if (accion.isEmpty) continue;

        final accionUpper = accion.toUpperCase();
        if (_accionesIgnoradas.contains(accionUpper)) continue;
        // Solo dejamos pasar acciones críticas (eliminaciones, purgas,
        // importaciones, cambios de rol/permisos…). El resto se consume del
        // cursor pero no notifica para mantener el buzón ligero.
        if (!_esCritica(accionUpper)) continue;

        final key = '$accionUpper|${usuario.toLowerCase()}';
        final lista = agrupado.putIfAbsent(key, () => <String>[]);
        if (codigo.isNotEmpty && !lista.contains(codigo)) {
          lista.add(codigo);
        }
        final prevMax = maxIdPorGrupo[key] ?? 0;
        if (idLog > prevMax) maxIdPorGrupo[key] = idLog;
      }

      for (final entry in agrupado.entries) {
        final parts = entry.key.split('|');
        final accion = parts.isNotEmpty ? parts[0] : 'CAMBIO';
        final usuarioLower = parts.length > 1 ? parts[1] : '';
        final codigos = entry.value;
        final idLog = maxIdPorGrupo[entry.key] ?? newSince;

        final usuarioMostrar = usuarioLower.isEmpty
            ? ''
            : _capitalizar(usuarioLower);

        final cuerpo = _formatearCuerpo(codigos);
        final titulo = _formatearTitulo(accion, codigos.length);

        await CmdInboxStore.instance.addSystemNoticeUniqueId(
          id: 'd_audit_grp_${idLog}_${entry.key.hashCode}',
          title: titulo,
          body: cuerpo,
          assignedUser: usuarioMostrar,
        );
      }

      if (newSince > since) {
        await prefs.setInt(_sinceKey, newSince);
      }
    } catch (_) {}
  }

  static String _capitalizar(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1);
  }

  static String _formatearTitulo(String accion, int n) {
    final pretty = accion
        .replaceAll('_', ' ')
        .toLowerCase()
        .split(' ')
        .where((p) => p.isNotEmpty)
        .map((p) => p[0].toUpperCase() + p.substring(1))
        .join(' ');
    if (n <= 1) return pretty;
    return '$pretty ($n códigos)';
  }

  static String _formatearCuerpo(List<String> codigos) {
    if (codigos.isEmpty) return 'Sin códigos asociados.';
    if (codigos.length == 1) return codigos.first;
    const max = 6;
    if (codigos.length <= max) return codigos.join(', ');
    final visibles = codigos.take(max).join(', ');
    return '$visibles … (+${codigos.length - max} más)';
  }
}
