import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'nav_destino_etiquetas.dart';
import 'nav_pane.dart';

/// Envío best-effort al servidor ([POST /api/app/telemetry/event]) para agregar uso por usuario.
class AppTelemetrySync {
  AppTelemetrySync._();

  static Future<void> _post(
    String tipo,
    String destinoCodigo,
    String destinoEtiqueta,
    String rolEfectivo,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if ((prefs.getString('access_token') ?? '').trim().isEmpty) {
        return;
      }
      final res = await ApiClient.postUnvalidated(
        '/api/app/telemetry/event',
        body: {
          'tipo': tipo,
          'destino_codigo': destinoCodigo,
          'destino_etiqueta': destinoEtiqueta,
          'rol_efectivo': rolEfectivo.trim(),
        },
      );
      if (res.statusCode == 401 || res.statusCode == 403) {
        return;
      }
    } catch (_) {}
  }

  static void reportNavPane({
    required NavPaneId paneId,
    required String roleRaw,
  }) {
    final codigo = paneId.name;
    final etiqueta = etiquetaNavPane(paneId);
    unawaited(_post('nav', codigo, etiqueta, roleRaw));
  }

  static void reportFeature({
    required String featureId,
    required String roleRaw,
  }) {
    final id = featureId.trim();
    if (id.isEmpty) return;
    final etiqueta = etiquetaFeatureUso(id);
    unawaited(_post('feature', id, etiqueta, roleRaw));
  }

  /// Tras login exitoso (token ya guardado en prefs).
  static void reportSesionInicio({required String rolEfectivo}) {
    unawaited(
      _post(
        'sesion',
        'login',
        'Inicio de sesión',
        rolEfectivo,
      ),
    );
  }
}
