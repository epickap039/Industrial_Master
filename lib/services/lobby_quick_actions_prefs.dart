import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_role.dart';
import 'nav_pane.dart';

class LobbyQuickActionMeta {
  const LobbyQuickActionMeta({
    required this.id,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.detail,
  });

  final NavPaneId id;
  final IconData icon;
  final String title;
  final String subtitle;
  final String detail;
}

class LobbyQuickActionsPrefs {
  LobbyQuickActionsPrefs._();

  static const String _keyPrefix = 'lobby_quick_nav_v1_';

  static const Map<NavPaneId, LobbyQuickActionMeta> catalog = {
    NavPaneId.escanerCad: LobbyQuickActionMeta(
      id: NavPaneId.escanerCad,
      icon: FluentIcons.cube_shape,
      title: 'Escáner CAD',
      subtitle: 'Escaneo y validación rápida',
      detail: 'Punto de entrada para carga y normalización de piezas.',
    ),
    NavPaneId.catalogoMaestro: LobbyQuickActionMeta(
      id: NavPaneId.catalogoMaestro,
      icon: FluentIcons.database,
      title: 'Catálogo Maestro',
      subtitle: 'Consulta código y material',
      detail: 'Validación inmediata de código, material y revisiones.',
    ),
    NavPaneId.ayudasVisuales: LobbyQuickActionMeta(
      id: NavPaneId.ayudasVisuales,
      icon: FluentIcons.page_list,
      title: 'Ayudas visuales',
      subtitle: 'Consulta de instructivos',
      detail: 'Acceso directo a PDFs por categoría y revisión.',
    ),
    NavPaneId.mapaIngenieria: LobbyQuickActionMeta(
      id: NavPaneId.mapaIngenieria,
      icon: FluentIcons.map_layers,
      title: 'Mapa de ingeniería',
      subtitle: 'Navega la estructura del producto',
      detail: 'Tracto, tipo, versión y revisión en una sola vista.',
    ),
    NavPaneId.gestionProyectos: LobbyQuickActionMeta(
      id: NavPaneId.gestionProyectos,
      icon: FluentIcons.fabric_folder,
      title: 'Gestión de proyectos',
      subtitle: 'Versiones y trazabilidad',
      detail: 'Control de tractos, tipos, versiones y clientes.',
    ),
    NavPaneId.importarExcel: LobbyQuickActionMeta(
      id: NavPaneId.importarExcel,
      icon: FluentIcons.cloud,
      title: 'Importar Excel',
      subtitle: 'Carga masiva de cambios',
      detail: 'Entrada rápida para actualización operativa del catálogo.',
    ),
    NavPaneId.radarImpacto: LobbyQuickActionMeta(
      id: NavPaneId.radarImpacto,
      icon: FluentIcons.build_issue,
      title: 'Radar de impacto',
      subtitle: 'Evalúa impacto y asigna tareas',
      detail: 'Cambios en BOM y misiones del centro.',
    ),
    NavPaneId.materialesOficiales: LobbyQuickActionMeta(
      id: NavPaneId.materialesOficiales,
      icon: FluentIcons.set_action,
      title: 'Materiales oficiales',
      subtitle: 'Consulta y copia descripciones',
      detail: 'Uso diario para estandarizar nombres de material.',
    ),
  };

  static List<NavPaneId> defaults(AppRole role) {
    final eng = role == AppRole.ingenieriaMetodos ||
        role == AppRole.desarrollador ||
        role == AppRole.administrador;
    if (eng) {
      return const [
        NavPaneId.escanerCad,
        NavPaneId.catalogoMaestro,
        NavPaneId.ayudasVisuales,
        NavPaneId.mapaIngenieria,
        NavPaneId.gestionProyectos,
        NavPaneId.importarExcel,
      ];
    }
    return const [
      NavPaneId.catalogoMaestro,
      NavPaneId.ayudasVisuales,
      NavPaneId.radarImpacto,
      NavPaneId.gestionProyectos,
      NavPaneId.materialesOficiales,
    ];
  }

  static String _keyForUser(String username) {
    final u = username.trim().toLowerCase();
    return '$_keyPrefix$u';
  }

  static bool _isVisibleForRole(NavPaneId id, AppRole role) {
    return navIndexForPane(id, role) >= 0;
  }

  static List<NavPaneId> sanitize(
    List<NavPaneId> ids,
    AppRole role,
  ) {
    final out = <NavPaneId>[];
    final seen = <NavPaneId>{};
    for (final id in ids) {
      if (!catalog.containsKey(id)) continue;
      if (!_isVisibleForRole(id, role)) continue;
      if (!seen.add(id)) continue;
      out.add(id);
    }
    if (out.isEmpty) {
      return defaults(role).where((id) => _isVisibleForRole(id, role)).toList();
    }
    return out;
  }

  static Future<List<NavPaneId>> load(
    String username,
    AppRole role,
  ) async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_keyForUser(username));
    if (raw == null || raw.trim().isEmpty) {
      return sanitize(defaults(role), role);
    }
    try {
      final arr = jsonDecode(raw);
      if (arr is List) {
        final ids = <NavPaneId>[];
        for (final item in arr) {
          final s = '$item'.trim();
          if (s.isEmpty) continue;
          for (final id in NavPaneId.values) {
            if (id.name == s) {
              ids.add(id);
              break;
            }
          }
        }
        return sanitize(ids, role);
      }
    } catch (_) {}
    return sanitize(defaults(role), role);
  }

  static Future<void> save(String username, List<NavPaneId> ids) async {
    final p = await SharedPreferences.getInstance();
    final list = ids.map((e) => e.name).toList(growable: false);
    await p.setString(_keyForUser(username), jsonEncode(list));
  }
}
