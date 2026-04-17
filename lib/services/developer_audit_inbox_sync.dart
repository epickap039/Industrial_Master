import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'app_role.dart';
import 'notification_inbox_service.dart';

/// Sondea [Tbl_Auditoria_Cambios] (import BOM, sync Excel, borrados, etc.) y
/// vuelca eventos nuevos al buzón local como avisos del sistema.
class DeveloperAuditInboxSync {
  DeveloperAuditInboxSync._();

  static const String _sinceKey = 'dev_auditoria_since_id_v1';
  static const String _initKey = 'dev_auditoria_cursor_inited_v1';

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
      for (final raw in rawItems) {
        if (raw is! Map) continue;
        final idLog = int.tryParse('${raw['id_log']}') ?? 0;
        if (idLog <= 0) continue;
        final accion = '${raw['accion'] ?? ''}'.trim();
        final usuario = '${raw['usuario'] ?? ''}'.trim();
        final codigo = '${raw['codigo'] ?? ''}'.trim();
        var body = '$codigo';
        if (usuario.isNotEmpty) {
          body = body.isEmpty ? usuario : '$body · $usuario';
        }
        if (body.isEmpty) body = 'Evento de auditoría';
        if (body.length > 320) body = body.substring(0, 320);

        await CmdInboxStore.instance.addSystemNoticeUniqueId(
          id: 'd_audit_$idLog',
          title: accion.isEmpty ? 'Cambio en base de datos' : accion,
          body: body,
        );
        if (idLog > newSince) newSince = idLog;
      }
      if (newSince > since) {
        await prefs.setInt(_sinceKey, newSince);
      }
    } catch (_) {}
  }
}
