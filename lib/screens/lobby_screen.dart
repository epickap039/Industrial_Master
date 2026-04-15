import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' as material;
import 'package:fluent_ui/fluent_ui.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';
import '../services/api_client.dart';
import '../services/app_role.dart';
import '../services/main_nav.dart';
import '../services/nav_pane.dart';
import '../services/notification_inbox_service.dart';
import '../services/user_avatar_service.dart';
import '../services/lobby_quick_actions_prefs.dart';
import '../theme/page_title_style.dart';
import '../theme/ui_tokens.dart';
import 'monitoreo/widgets/notification_inbox_panel.dart';
import 'ayudas_visuales/ayudas_api_models.dart';
import 'ayudas_visuales/ayudas_layout_helpers.dart';

String _roleLabel(AppRole r) {
  return switch (r) {
    AppRole.administrador => 'Administrador',
    AppRole.desarrollador => 'Desarrollador',
    AppRole.calidad => 'Calidad',
    AppRole.produccion => 'Producción',
    AppRole.ingenieriaMetodos => 'Ingeniería / Métodos',
    AppRole.gestion => 'Gestión',
    AppRole.compras => 'Compras',
    AppRole.direccion => 'Dirección',
    AppRole.qaLegacy => 'QA',
    AppRole.userLegacy => 'Usuario',
    AppRole.otro => 'Usuario',
  };
}

class _AyudaCategoriaStat {
  final int id;
  final String nombre;
  final int count;
  const _AyudaCategoriaStat({
    required this.id,
    required this.nombre,
    required this.count,
  });
}

class LobbyScreen extends StatefulWidget {
  /// Rol efectivo (sesión + simulación "Ver como" del administrador).
  final String effectiveRole;
  final void Function(NavPaneId id, {int? revisionId}) onNavigatePane;
  final bool isAdmin;

  const LobbyScreen({
    super.key,
    required this.effectiveRole,
    required this.onNavigatePane,
    this.isAdmin = false,
  });

  @override
  State<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends State<LobbyScreen> {
  String _userName = 'Cargando...';
  String _userRole = '';
  String _userGender = '';
  String _loginUsername = '';
  Uint8List? _avatarBytes;
  bool _avatarLoading = false;

  // KPIs /api/dashboard/kpi
  int totalLineasBom = 0;
  double saludCad = 0.0;
  int totalVersiones = 0;
  bool isLoadingKpi = true;
  String? kpiError;

  // Operación
  int _tractosActivos = 0;
  int _reportesQaAbiertos = 0;
  int _misionesCentroPendientes = 0;
  bool _loadingOps = true;
  String? _opsError;
  Map<String, dynamic>? _ultimaAyudaVisual;

  /// Lobby operativo (Calidad / Métodos / Producción): piezas recientes + ayudas por categoría.
  bool _loadingLobbyOperativo = true;
  String? _lobbyOperativoError;
  List<Map<String, dynamic>> _ultimasPiezasCatalogo = [];
  List<_AyudaCategoriaStat> _ayudasPorCategoria = [];
  int _totalArchivosAyudas = 0;
  int _notificacionesNoLeidas = 0;
  List<CmdInboxEntry> _notificacionesPreview = [];
  List<NavPaneId> _quickNavIds = [];

  @override
  void initState() {
    super.initState();
    _userRole = widget.effectiveRole;
    _bootstrap();
  }

  @override
  void didUpdateWidget(LobbyScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.effectiveRole != widget.effectiveRole) {
      _userRole = widget.effectiveRole;
      _loadQuickActionsPrefs();
      _fetchAll();
    }
  }

  Future<void> _bootstrap() async {
    await _loadUser();
    if (!mounted) return;
    await _loadQuickActionsPrefs();
    if (!mounted) return;
    await _fetchAll();
  }

  Future<void> _loadUser() async {
    final prefs = await SharedPreferences.getInstance();
    final prefUsername = (prefs.getString('username') ?? '').trim();
    final prefDisplayName = (prefs.getString('display_name') ?? '').trim();
    final prefGender = (prefs.getString('user_gender') ?? '').trim();
    final prefLogin = (prefs.getString('username') ?? '').trim();
    final userId = prefs.getInt('user_id');
    if (mounted) {
      setState(() {
        _userName = prefDisplayName.isNotEmpty
            ? prefDisplayName
            : (prefUsername.isNotEmpty ? prefUsername : 'Usuario');
        _userGender = prefGender;
        _loginUsername = prefLogin;
        _userRole = widget.effectiveRole;
      });
    }
    await _reloadLobbyAvatar(silent: true);
    // Sincroniza el nombre visible con el perfil real (si se cambió en backend).
    try {
      final raw = await ApiClient.get('/api/usuarios/all');
      if (raw is! List) return;
      Map<String, dynamic>? matched;
      for (final e in raw) {
        if (e is! Map) continue;
        final m = Map<String, dynamic>.from(e.map((k, v) => MapEntry('$k', v)));
        final rowId = int.tryParse('${m['id'] ?? m['Id'] ?? ''}');
        final rowLogin = '${m['username'] ?? m['Usuario'] ?? ''}'.trim();
        if (userId != null && userId > 0 && rowId == userId) {
          matched = m;
          break;
        }
        if (matched == null &&
            prefUsername.isNotEmpty &&
            rowLogin.toLowerCase() == prefUsername.toLowerCase()) {
          matched = m;
        }
      }
      if (matched == null) return;
      final displayName = _displayNameFromUserRow(matched);
      final newLogin = '${matched['username'] ?? matched['Usuario'] ?? ''}'.trim();
      if (displayName.isNotEmpty && mounted) {
        setState(() => _userName = displayName);
      }
      if (displayName.isNotEmpty) {
        await prefs.setString('display_name', displayName);
      }
      final gender = _genderFromUserRow(matched);
      if (gender.isNotEmpty) {
        await prefs.setString('user_gender', gender);
        if (mounted) {
          setState(() => _userGender = gender);
        }
      }
      if (newLogin.isNotEmpty && newLogin != prefUsername) {
        await prefs.setString('username', newLogin);
      }
    } catch (_) {}
  }

  Future<void> _loadQuickActionsPrefs() async {
    final role = parseAppRole(_userRole);
    final username = _loginUsername.trim().isNotEmpty
        ? _loginUsername.trim()
        : _userName.trim();
    final ids = await LobbyQuickActionsPrefs.load(username, role);
    if (!mounted) return;
    setState(() => _quickNavIds = ids);
  }

  Future<void> _openQuickActionsDialog() async {
    final role = parseAppRole(_userRole);
    final available = LobbyQuickActionsPrefs.catalog.keys
        .where((id) => navIndexForPane(id, role) >= 0)
        .toList();
    var local = List<NavPaneId>.from(_quickNavIds);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return ContentDialog(
          title: const Text('Personalizar accesos rápidos'),
          content: SizedBox(
            width: 520,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final id in available)
                  Checkbox(
                    checked: local.contains(id),
                    onChanged: (v) {
                      if (v == true && !local.contains(id)) {
                        local.add(id);
                      } else if (v != true) {
                        local.remove(id);
                      }
                      (ctx as Element).markNeedsBuild();
                    },
                    content: Text(
                      LobbyQuickActionsPrefs.catalog[id]?.title ?? id.name,
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            Button(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            Button(
              onPressed: () {
                local = LobbyQuickActionsPrefs.defaults(role);
                (ctx as Element).markNeedsBuild();
              },
              child: const Text('Restaurar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Guardar'),
            ),
          ],
        );
      },
    );
    if (ok != true) return;
    final safe = LobbyQuickActionsPrefs.sanitize(local, role);
    final username = _loginUsername.trim().isNotEmpty
        ? _loginUsername.trim()
        : _userName.trim();
    await LobbyQuickActionsPrefs.save(username, safe);
    if (!mounted) return;
    setState(() => _quickNavIds = safe);
  }

  Future<void> _reloadLobbyAvatar({bool silent = false}) async {
    final uname = _loginUsername.trim();
    if (uname.isEmpty) return;
    if (mounted) setState(() => _avatarLoading = true);
    try {
      final fresh = await UserAvatarService.instance.refreshAvatarFromServer(uname);
      if (!mounted) return;
      setState(() => _avatarBytes = fresh);
      if (!silent) {
        _showTopBarInfo(
          'Foto de perfil',
          fresh == null ? 'No hay foto de perfil para este usuario.' : 'Foto recargada.',
          InfoBarSeverity.success,
        );
      }
    } catch (e) {
      if (!silent) {
        _showTopBarInfo('Foto de perfil', '$e', InfoBarSeverity.error);
      }
    } finally {
      if (mounted) setState(() => _avatarLoading = false);
    }
  }

  Future<void> _pickLobbyAvatar() async {
    final uname = _loginUsername.trim();
    if (uname.isEmpty) return;
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
      allowMultiple: false,
    );
    if (picked == null || picked.files.isEmpty) return;
    Uint8List? bytes = picked.files.single.bytes;
    final path = picked.files.single.path;
    if (bytes == null && path != null && path.isNotEmpty) {
      bytes = await File(path).readAsBytes();
    }
    if (bytes == null || bytes.isEmpty) return;
    await UserAvatarService.instance.saveAvatarForUser(uname, bytes);
    if (!mounted) return;
    setState(() => _avatarBytes = bytes);
    _showTopBarInfo('Foto de perfil', 'Foto actualizada.', InfoBarSeverity.success);
  }

  void _showTopBarInfo(String title, String msg, InfoBarSeverity severity) {
    if (!mounted) return;
    displayInfoBar(
      context,
      builder:
          (c, close) => InfoBar(
            title: Text(title),
            content: Text(msg),
            severity: severity,
            onClose: close,
          ),
    );
  }

  String _displayNameFromUserRow(Map<String, dynamic> row) {
    final keys = <String>[
      'nombre',
      'Nombre',
      'nombre_completo',
      'Nombre_Completo',
      'display_name',
      'full_name',
      'username',
      'Usuario',
    ];
    for (final k in keys) {
      final v = row[k];
      final s = v == null ? '' : v.toString().trim();
      if (s.isNotEmpty) return s;
    }
    return 'Usuario';
  }

  String _genderFromUserRow(Map<String, dynamic> row) {
    final keys = <String>[
      'genero',
      'Genero',
      'género',
      'Género',
      'sexo',
      'Sexo',
      'gender',
      'Gender',
    ];
    for (final k in keys) {
      final v = row[k];
      final s = v == null ? '' : v.toString().trim().toLowerCase();
      if (s.isNotEmpty) return s;
    }
    return '';
  }

  String _welcomeWord() {
    final g = _userGender.trim().toLowerCase();
    if (g == 'f' ||
        g == 'femenino' ||
        g == 'mujer' ||
        g == 'female') {
      return 'Bienvenida';
    }
    if (g == 'm' || g == 'masculino' || g == 'hombre' || g == 'male') {
      return 'Bienvenido';
    }
    final names = _userName
        .split(RegExp(r'\s+|[_\-\.]'))
        .where((e) => e.trim().isNotEmpty)
        .map((e) => e.trim().toLowerCase())
        .toList();
    if (names.isNotEmpty && names.first.endsWith('a')) {
      return 'Bienvenida';
    }
    return 'Bienvenido(a)';
  }

  Future<void> _fetchAll() async {
    final ar = parseAppRole(_userRole);
    if (ar.showsLobbyOperativoAyudasCatalogo) {
      await _fetchLobbyOperativoAyudasCatalogo();
      await _fetchInboxPreview();
      return;
    }
    await Future.wait([
      _fetchKpis(),
      _fetchOperationalStats(),
      _fetchAyudasVisualesStats(),
      _fetchInboxPreview(),
    ]);
  }

  Future<void> _fetchInboxPreview() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final inboxUser = (prefs.getString('username') ?? '').trim();
      if (inboxUser.isNotEmpty) {
        try {
          final data = await ApiClient.get('/api/tareas/lista');
          if (data is List) {
            final taskRows =
                data.whereType<Map<String, dynamic>>().toList();
            await CmdInboxStore.instance.pruneMissionInboxAgainstTaskList(
              taskRows,
              inboxUser,
            );
          }
        } catch (_) {}
      }
      final all = await CmdInboxStore.instance.loadAll();
      final unread = all.where((n) => !n.leido).length;
      if (!mounted) return;
      setState(() {
        _notificacionesNoLeidas = unread;
        _notificacionesPreview = all.take(3).toList();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _notificacionesNoLeidas = 0;
        _notificacionesPreview = const [];
      });
    }
  }

  Future<void> _openInboxFromLobby() async {
    await showNotificationInboxDialog(
      context,
      onChanged: () {
        _fetchInboxPreview();
      },
      onOpenMonitoring: () {
        widget.onNavigatePane(NavPaneId.centroMonitoreo);
      },
    );
    if (mounted) await _fetchInboxPreview();
  }

  Widget _lobbyFilledAction({required String label, required VoidCallback? onPressed}) {
    return FilledButton(
      onPressed: onPressed,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Text(label),
      ),
    );
  }

  /// Menú compacto (tablet): biblioteca + abrir último documento sin ocupar dos botones anchos.
  Widget _lobbyAyudasOverflowActions({
    required VoidCallback onIrBiblioteca,
    VoidCallback? onAbrirUltimo,
  }) {
    final hasLast = onAbrirUltimo != null;
    return material.Material(
      color: material.Colors.transparent,
      child: material.PopupMenuButton<int>(
        tooltip: 'Acciones de ayudas visuales',
        onSelected: (v) {
          if (v == 0) onIrBiblioteca();
          if (v == 1) {
            final abrir = onAbrirUltimo;
            if (abrir != null) abrir();
          }
        },
        itemBuilder: (ctx) => [
          const material.PopupMenuItem<int>(
            value: 0,
            child: material.Text('Ir a biblioteca de ayudas'),
          ),
          if (hasLast)
            const material.PopupMenuItem<int>(
              value: 1,
              child: material.Text('Abrir último documento'),
            ),
        ],
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Icon(FluentIcons.more_vertical, size: 20),
        ),
      ),
    );
  }

  DateTime? _parseCatalogDate(dynamic v) {
    if (v == null) return null;
    if (v == '-') return null;
    if (v is DateTime) return v;
    final s = v.toString().trim();
    if (s.isEmpty || s == '-') return null;
    return DateTime.tryParse(s) ?? DateTime.tryParse(s.replaceFirst(' ', 'T'));
  }

  int _comparePiezasRecientes(Map<String, dynamic> a, Map<String, dynamic> b) {
    final da = _catalogLastUpdate(a);
    final db = _catalogLastUpdate(b);
    if (da != null && db != null) return db.compareTo(da);
    if (da != null) return -1;
    if (db != null) return 1;
    final ca = '${a['Codigo_Pieza'] ?? a['Codigo'] ?? ''}';
    final cb = '${b['Codigo_Pieza'] ?? b['Codigo'] ?? ''}';
    return cb.compareTo(ca);
  }

  DateTime? _catalogLastUpdate(Map<String, dynamic> row) {
    return _parseCatalogDate(row['Ultima_Actualizacion']) ??
        _parseCatalogDate(row['Fecha_Modificacion']) ??
        _parseCatalogDate(row['Fecha_Actualizacion']) ??
        _parseCatalogDate(row['Fecha_Creacion']);
  }

  String _catalogMaterial(Map<String, dynamic> row) {
    final keys = <String>[
      'Material',
      'Material_Oficial',
      'Descripcion_Material',
      'Descripción_Material',
      'Descripcion',
    ];
    for (final k in keys) {
      final v = row[k];
      final s = v == null ? '' : v.toString().trim();
      if (s.isNotEmpty && s != '-') return s;
    }
    return 'Sin material';
  }

  int _ayudaCategoriaId(Map<String, dynamic> cm) {
    final raw =
        cm['ID_Categoria'] ??
        cm['id_categoria'] ??
        cm['Id_Categoria'] ??
        cm['id'] ??
        cm['Id'];
    if (raw is int) return raw;
    return int.tryParse('$raw') ?? 0;
  }

  String _ayudaCategoriaNombre(Map<String, dynamic> cm, int id) {
    final raw =
        cm['Nombre_Categoria'] ??
        cm['nombre_categoria'] ??
        cm['Categoria'] ??
        cm['categoria'] ??
        cm['nombre'];
    final name = '${raw ?? ''}'.trim();
    return name.isEmpty ? 'Categoría $id' : name;
  }

  Future<void> _fetchLobbyOperativoAyudasCatalogo() async {
    if (mounted) {
      setState(() {
        _loadingLobbyOperativo = true;
        _lobbyOperativoError = null;
      });
    }
    try {
      final catF = ApiClient.get('/api/catalog');
      final catsF = ApiClient.get('/api/ayudas/categorias');
      final catalogRaw = await catF;
      final catsRaw = await catsF;

      final list = catalogRaw is List ? catalogRaw : <dynamic>[];
      final rows = <Map<String, dynamic>>[];
      for (final e in list) {
        if (e is Map) {
          rows.add(
            Map<String, dynamic>.from(e.map((k, v) => MapEntry('$k', v))),
          );
        }
      }
      rows.sort(_comparePiezasRecientes);
      final ultimas = rows.take(5).toList();

      final cats = catsRaw is List ? catsRaw : <dynamic>[];
      final stats = <_AyudaCategoriaStat>[];
      Map<String, dynamic>? latest;
      DateTime? latestDate;
      var totalArch = 0;

      for (final c in cats) {
        if (c is! Map) continue;
        final cm = Map<String, dynamic>.from(
          c.map((k, v) => MapEntry('$k', v)),
        );
        final id = _ayudaCategoriaId(cm);
        if (id <= 0) continue;
        final nombre = _ayudaCategoriaNombre(cm, id);
        List<dynamic> docList = const [];
        try {
          final data = await ApiClient.get('/api/ayudas/lista/$id');
          docList = data is List ? data : <dynamic>[];
        } catch (_) {
          // Una categoría puntual no debe romper el resumen del Lobby.
          docList = const [];
        }
        final n = docList.length;
        totalArch += n;
        stats.add(
          _AyudaCategoriaStat(
            id: id,
            nombre: nombre,
            count: n,
          ),
        );
        for (final row in docList) {
          if (row is! Map) continue;
          final m = Map<String, dynamic>.from(
            row.map((k, v) => MapEntry('$k', v)),
          );
          final d = _safeAyudaDate(m);
          if (d != null) {
            if (latestDate == null || d.isAfter(latestDate)) {
              latestDate = d;
              latest = m;
            }
          } else if (latest == null) {
            // Fallback: mostrar al menos un documento si viene sin fecha parseable.
            latest = m;
          }
        }
      }
      stats.sort((a, b) => b.count.compareTo(a.count));

      if (mounted) {
        setState(() {
          _ultimasPiezasCatalogo = ultimas;
          _ayudasPorCategoria = stats;
          _totalArchivosAyudas = totalArch;
          _ultimaAyudaVisual = latest;
          _loadingLobbyOperativo = false;
        });
      }
    } catch (e) {
      debugPrint('Lobby operativo (catálogo/ayudas): $e');
      if (mounted) {
        setState(() {
          _loadingLobbyOperativo = false;
          _lobbyOperativoError =
              'No se pudieron cargar el catálogo o las ayudas visuales.';
        });
      }
    }
  }

  DateTime? _safeAyudaDate(Map<String, dynamic> m) {
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

  Future<void> _fetchAyudasVisualesStats() async {
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
        final id = _ayudaCategoriaId(cm);
        if (id <= 0) continue;
        List<dynamic> list = const [];
        try {
          final data = await ApiClient.get('/api/ayudas/lista/$id');
          list = data is List ? data : <dynamic>[];
        } catch (_) {
          // Ignorar categoría con error y continuar con las demás.
          list = const [];
        }
        for (final row in list) {
          if (row is! Map) continue;
          final m = Map<String, dynamic>.from(
            row.map((k, v) => MapEntry('$k', v)),
          );
          final d = _safeAyudaDate(m);
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
      if (mounted) {
        setState(() {
          _ultimaAyudaVisual = latest;
        });
      }
    } catch (_) {}
  }

  void _openLatestAyuda() {
    final m = _ultimaAyudaVisual;
    if (m == null) return;
    final idAyuda = ayudasIdAyuda(m);
    final idRevision = ayudasIdRevision(m);
    if (idAyuda <= 0 || idRevision <= 0) return;
    if (navIndexForPane(NavPaneId.ayudasVisuales, MainNav.currentRole) < 0) {
      return;
    }
    MainNav.requestOpenAyudaLobby(
      AyudasLobbyOpenIntent(
        idAyuda: idAyuda,
        idRevision: idRevision,
        tituloDocumento: ayudasTituloDocumento(m),
      ),
    );
    widget.onNavigatePane(NavPaneId.ayudasVisuales);
  }

  Future<void> _fetchKpis() async {
    try {
      final data =
          await ApiClient.get('/api/dashboard/kpi') as Map<String, dynamic>;
      if (mounted) {
        setState(() {
          totalLineasBom = (data['total_lineas_bom'] ?? 0).toInt();
          totalVersiones = (data['total_versiones'] ?? 0).toInt();
          saludCad = (data['salud_cad'] ?? 0.0).toDouble();
          isLoadingKpi = false;
        });
      }
    } catch (e) {
      debugPrint('Error fetching KPIs: $e');
      if (mounted) {
        setState(() {
          isLoadingKpi = false;
          kpiError =
              'Sin conexión con el servidor.\nVerifica el backend en $kApiBaseUrl';
        });
      }
    }
  }

  int _countMisionesCentroPendientes(List<dynamic> raw) {
    int n = 0;
    for (final e in raw) {
      if (e is! Map) continue;
      final t = Map<String, dynamic>.from(e.map((k, v) => MapEntry('$k', v)));
      final tipo = '${t['tipo'] ?? ''}'.toUpperCase();
      if (!tipo.contains('RADAR') && !tipo.contains('MANUAL')) continue;
      final p = int.tryParse('${t['porcentaje_progreso'] ?? 0}') ?? 0;
      if (p >= 100) continue;
      final est = '${t['estado'] ?? t['Estado'] ?? ''}'.toLowerCase();
      if (est.contains('cancel')) continue;
      if (est.contains('terminad')) continue;
      n++;
    }
    return n;
  }

  Future<void> _fetchOperationalStats() async {
    try {
      final tractosF = ApiClient.get('/api/proyectos/tractos');
      final reportesF = ApiClient.get('/api/reportes');
      final tareasF = ApiClient.get('/api/tareas/lista');

      final tractos = await tractosF;
      final reportes = await reportesF;
      final tareas = await tareasF;

      final tList = tractos is List ? tractos : <dynamic>[];
      final rList = reportes is List ? reportes : <dynamic>[];
      final mList = tareas is List ? tareas : <dynamic>[];

      if (mounted) {
        setState(() {
          _tractosActivos = tList.length;
          _reportesQaAbiertos = rList.length;
          _misionesCentroPendientes = _countMisionesCentroPendientes(mList);
          _loadingOps = false;
          _opsError = null;
        });
      }
    } catch (e) {
      debugPrint('Lobby ops: $e');
      if (mounted) {
        setState(() {
          _loadingOps = false;
          _opsError = 'No se pudieron cargar métricas operativas.';
        });
      }
    }
  }

  bool get _lobbyOperativoAyudas =>
      parseAppRole(_userRole).showsLobbyOperativoAyudasCatalogo;

  bool get _cargandoLobby {
    if (_lobbyOperativoAyudas) return _loadingLobbyOperativo;
    return isLoadingKpi || _loadingOps;
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final palette = uiSurfacePaletteOf(context);
    final dark = theme.brightness == Brightness.dark;
    final loading = _cargandoLobby;
    final rolLabel = _roleLabel(parseAppRole(_userRole));

    return ScaffoldPage(
      padding: const EdgeInsets.only(top: 8),
      header: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: UiTokens.pageHPadding,
          vertical: 10,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${_welcomeWord()}, $_userName',
                    style: pageTitleTextStyle(context, fontSize: 28).copyWith(
                      fontWeight: FontWeight.w700,
                      color: theme.typography.title?.color,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Panel de control | Rol: $rolLabel',
                    style: TextStyle(
                      fontSize: 14,
                      color: theme.typography.caption?.color?.withValues(alpha: 0.65),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _lobbyOperativoAyudas
                        ? 'Piezas recientes y ayudas por categoría'
                        : 'Atajos, documentación y estado del sistema',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: theme.typography.caption?.color?.withValues(alpha: 0.92),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: theme.inactiveColor.withValues(alpha: 0.45),
                      width: 1.4,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child:
                      _avatarLoading
                          ? const Center(child: ProgressRing(strokeWidth: 2))
                          : (_avatarBytes != null
                              ? Image.memory(_avatarBytes!, fit: BoxFit.cover)
                              : Center(
                                child: Text(
                                  (_userName.isEmpty ? 'U' : _userName.substring(0, 1))
                                      .toUpperCase(),
                                  style: const TextStyle(fontWeight: FontWeight.w700),
                                ),
                              )),
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Tooltip(
                      message: 'Editar foto',
                      child: IconButton(
                        icon: const Icon(FluentIcons.camera),
                        onPressed: _pickLobbyAvatar,
                      ),
                    ),
                    Tooltip(
                      message: 'Recargar foto',
                      child: IconButton(
                        icon: const Icon(FluentIcons.refresh),
                        onPressed: () => _reloadLobbyAvatar(),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
      content: Container(
        decoration: dark
            ? const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF141B28), Color(0xFF191F2C)],
                  stops: [0.0, 1.0],
                ),
              )
            : BoxDecoration(color: palette.surfaceBase),
        child: SingleChildScrollView(
          padding: pagePadding(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildQuickActions(theme),
              const SizedBox(height: UiTokens.sectionGap),
              if (!_lobbyOperativoAyudas && kpiError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: InfoBar(
                    title: const Text('Backend no disponible (KPI)'),
                    content: Text(kpiError!),
                    severity: InfoBarSeverity.warning,
                    onClose: () => setState(() => kpiError = null),
                  ),
                ),
              if (_lobbyOperativoAyudas && _lobbyOperativoError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: InfoBar(
                    title: const Text('Lobby operativo'),
                    content: Text(_lobbyOperativoError!),
                    severity: InfoBarSeverity.warning,
                    onClose: () => setState(() => _lobbyOperativoError = null),
                  ),
                ),
              if (!_lobbyOperativoAyudas && _opsError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: InfoBar(
                    title: const Text('Métricas operativas'),
                    content: Text(_opsError!),
                    severity: InfoBarSeverity.info,
                    onClose: () => setState(() => _opsError = null),
                  ),
                ),
              if (loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Center(
                    child: Column(
                      children: [
                        ProgressRing(),
                        SizedBox(height: 16),
                        Text('Cargando indicadores…'),
                      ],
                    ),
                  ),
                )
              else if (_lobbyOperativoAyudas)
                _buildLobbyOperativoAyudasCatalogo(theme)
              else
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _ayudasSpotlightCard(theme),
                    const SizedBox(height: 12),
                    _notificationsSummaryCard(theme),
                    const SizedBox(height: 12),
                    LayoutBuilder(
                      builder: (context, c) {
                        final wide = c.maxWidth > 900;
                        final gap = 16.0;
                        final cards = [
                          _areaCard(
                            theme: theme,
                            title: 'Ingeniería · Estandarización',
                            accent: const Color(0xFF1565C0),
                            headline: '${saludCad.toStringAsFixed(1)} %',
                            headlineLabel: 'Salud CAD (plano vinculado)',
                            footerLine:
                                '${totalLineasBom.toString()} líneas en listas BOM',
                            chips: [
                              _chip(
                                FluentIcons.cube_shape,
                                'Escáner CAD',
                                () => widget.onNavigatePane(NavPaneId.escanerCad),
                              ),
                              _chip(
                                FluentIcons.database,
                                'Catálogo',
                                () => widget.onNavigatePane(
                                  NavPaneId.catalogoMaestro,
                                ),
                              ),
                            ],
                          ),
                          _areaCard(
                            theme: theme,
                            title: 'Gestión · Trazabilidad',
                            accent: const Color(0xFF00695C),
                            headline: '$_tractosActivos',
                            headlineLabel: 'Proyectos (tractos) activos',
                            footerLine:
                                '$totalVersiones versiones de ingeniería registradas',
                            chips: [
                              _chip(
                                FluentIcons.fabric_folder,
                                'Proyectos',
                                () => widget.onNavigatePane(
                                  NavPaneId.gestionProyectos,
                                ),
                              ),
                              _chip(
                                FluentIcons.car,
                                'Expedientes VIN',
                                () => widget.onNavigatePane(
                                  NavPaneId.expedientesVin,
                                ),
                              ),
                            ],
                          ),
                          _areaCard(
                            theme: theme,
                            title: 'Control · Estadísticas',
                            accent: const Color(0xFF6A1B9A),
                            headline: totalLineasBom.toString(),
                            headlineLabel: 'Piezas / líneas en BOM (volumen)',
                            footerLine:
                                'Salud global ${saludCad.toStringAsFixed(1)} %',
                            chips: [
                              _chip(
                                FluentIcons.pie_single,
                                'Estadísticas',
                                () => widget.onNavigatePane(
                                  NavPaneId.dashboardAnalytics,
                                ),
                              ),
                              _chip(
                                FluentIcons.tablet,
                                'Centro de QA',
                                () => widget.onNavigatePane(NavPaneId.centroQa),
                              ),
                            ],
                          ),
                          _areaCard(
                            theme: theme,
                            title: 'Operaciones · Monitoreo',
                            accent: const Color(0xFFE65100),
                            headline: '$_misionesCentroPendientes',
                            headlineLabel: 'Misiones Radar/Manual pendientes',
                            footerLine:
                                '$_reportesQaAbiertos reportes de bug / QA abiertos',
                            chips: [
                              _chip(
                                FluentIcons.build_issue,
                                'Radar de Impacto',
                                () =>
                                    widget.onNavigatePane(NavPaneId.radarImpacto),
                              ),
                              _chip(
                                FluentIcons.activity_feed,
                                'Centro de Monitoreo',
                                () => widget.onNavigatePane(
                                  NavPaneId.centroMonitoreo,
                                ),
                              ),
                            ],
                            badge:
                                _misionesCentroPendientes > 0
                                    ? _misionesCentroPendientes
                                    : null,
                          ),
                        ];
                        if (wide) {
                          return Column(
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(child: cards[0]),
                                  SizedBox(width: gap),
                                  Expanded(child: cards[1]),
                                ],
                              ),
                              SizedBox(height: gap),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(child: cards[2]),
                                  SizedBox(width: gap),
                                  Expanded(child: cards[3]),
                                ],
                              ),
                            ],
                          );
                        }
                        return Column(
                          children: [
                            for (var i = 0; i < cards.length; i++) ...[
                              if (i > 0) SizedBox(height: gap),
                              cards[i],
                            ],
                          ],
                        );
                      },
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  static const List<Color> _kLobbyChartColors = [
    Color(0xFF42A5F5),
    Color(0xFF66BB6A),
    Color(0xFFFFA726),
    Color(0xFFAB47BC),
    Color(0xFF26A69A),
    Color(0xFF78909C),
    Color(0xFFEF5350),
    Color(0xFF8D6E63),
  ];

  String _etiquetaCorta(String s, int maxChars) {
    final t = s.trim();
    if (t.length <= maxChars) return t;
    return '${t.substring(0, math.max(0, maxChars - 1))}…';
  }

  Widget _buildLobbyOperativoAyudasCatalogo(FluentThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ayudasSpotlightCardOperativo(theme),
        const SizedBox(height: 16),
        _notificationsSummaryCard(theme),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth > 960;
            final gap = 16.0;
            if (wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 5, child: _cardUltimasPiezasCatalogo(theme)),
                  SizedBox(width: gap),
                  Expanded(flex: 6, child: _cardAyudasGraficas(theme)),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _cardUltimasPiezasCatalogo(theme),
                SizedBox(height: gap),
                _cardAyudasGraficas(theme),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _ayudasSpotlightCardOperativo(FluentThemeData theme) {
    final latest = _ultimaAyudaVisual;
    final latestTitle =
        latest == null
            ? 'Sin ayudas visuales recientes'
            : ayudasTituloDocumento(latest);
    final latestDate = latest == null ? null : _safeAyudaDate(latest);
    final latestUser =
        latest == null
            ? ''
            : '${latest['Usuario_Subida'] ?? latest['usuario_subida'] ?? ''}'
                .trim();
    final nCat = _ayudasPorCategoria.length;
    final lobbyAyudasCompact =
        ayudasLobbyAyudasCompacto(MediaQuery.sizeOf(context).width);
    return Container(
      padding: EdgeInsets.all(
        lobbyAyudasCompact ? 8 : UiTokens.cardPadding + 2,
      ),
      decoration: elevatedCardDecoration(theme),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  'Ayudas visuales · Resumen',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF0D6EFD),
                  ),
                ),
              ),
              if (lobbyAyudasCompact)
                _lobbyAyudasOverflowActions(
                  onIrBiblioteca: () =>
                      widget.onNavigatePane(NavPaneId.ayudasVisuales),
                  onAbrirUltimo: latest != null ? _openLatestAyuda : null,
                ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              _chip(
                FluentIcons.library,
                '$_totalArchivosAyudas archivos en todas las categorías',
                () => widget.onNavigatePane(NavPaneId.ayudasVisuales),
              ),
              _chip(
                FluentIcons.folder_list,
                '$nCat categorías',
                () => widget.onNavigatePane(NavPaneId.ayudasVisuales),
              ),
              _chip(
                FluentIcons.database,
                'Catálogo maestro',
                () => widget.onNavigatePane(NavPaneId.catalogoMaestro),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: theme.accentColor.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: theme.resources.controlStrokeColorDefault.withValues(
                  alpha: 0.7,
                ),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  FluentIcons.picture_center,
                  color: Color(0xFF1565C0),
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Última subida',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: theme.typography.caption?.color,
                        ),
                      ),
                      Text(
                        latestTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        latestUser.isEmpty
                            ? _fmtDateTime(latestDate)
                            : 'Usuario: $latestUser · ${_fmtDateTime(latestDate)}',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.typography.caption?.color,
                        ),
                      ),
                    ],
                  ),
                ),
                if (latest != null && !lobbyAyudasCompact)
                  _lobbyFilledAction(
                    label: 'Ver documento',
                    onPressed: _openLatestAyuda,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _cardUltimasPiezasCatalogo(FluentThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(UiTokens.cardPadding + 2),
      decoration: elevatedCardDecoration(theme),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Últimas piezas en catálogo maestro',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: const Color(0xFF1565C0),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Top 5 por última modificación. Vista rápida: Código de pieza, material y fecha.',
            style: TextStyle(
              fontSize: 12,
              color: theme.typography.caption?.color,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 14),
          if (_ultimasPiezasCatalogo.isEmpty)
            Text(
              'No hay datos de catálogo.',
              style: TextStyle(color: theme.typography.caption?.color),
            )
          else
            ...List.generate(_ultimasPiezasCatalogo.length, (i) {
              final row = _ultimasPiezasCatalogo[i];
              final cod =
                  '${row['Codigo_Pieza'] ?? row['Codigo'] ?? ''}'.trim();
              final material = _catalogMaterial(row);
              final fecha = _fmtDateTime(_catalogLastUpdate(row));
              return Padding(
                padding: EdgeInsets.only(
                  bottom: i == _ultimasPiezasCatalogo.length - 1 ? 0 : 10,
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: theme.accentColor.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: theme.resources.controlStrokeColorDefault
                          .withValues(alpha: 0.65),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            '${i + 1}. ',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: theme.typography.caption?.color,
                              fontSize: 13,
                            ),
                          ),
                          Expanded(
                            child: Text(
                              cod.isEmpty ? '—' : cod,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 14,
                              ),
                            ),
                          ),
                          Text(
                            fecha,
                            style: TextStyle(
                              fontSize: 11,
                              color: theme.typography.caption?.color,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Material: ${_etiquetaCorta(material, 120)}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.25,
                          color: theme.typography.body?.color?.withValues(
                            alpha: 0.9,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _cardAyudasGraficas(FluentThemeData theme) {
    final stats = _ayudasPorCategoria;
    final maxY =
        stats.isEmpty
            ? 1.0
            : math.max(
              1.0,
              stats.map((e) => e.count).reduce(math.max).toDouble(),
            );
    final oscuro = theme.brightness == Brightness.dark;
    final accent = theme.accentColor;
    final nonZero = stats.where((s) => s.count > 0).toList();
    final pieTotal = nonZero.fold<int>(0, (a, b) => a + b.count);

    return Container(
      padding: const EdgeInsets.all(UiTokens.cardPadding + 2),
      decoration: elevatedCardDecoration(theme),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Archivos por categoría',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: const Color(0xFF00695C),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Incluye categorías sin archivos (0). Gráfica de barras y reparto entre categorías con al menos un archivo.',
            style: TextStyle(
              fontSize: 12,
              color: theme.typography.caption?.color,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 14),
          if (stats.isEmpty)
            Text(
              'No hay categorías configuradas.',
              style: TextStyle(color: theme.typography.caption?.color),
            )
          else ...[
            LayoutBuilder(
              builder: (ctx, cons) {
                final chartW = math.max(cons.maxWidth, stats.length * 44.0);
                return SizedBox(
                  height: math.min(360, 40.0 + stats.length * 28.0),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: chartW,
                      child: BarChart(
                        BarChartData(
                          alignment: BarChartAlignment.spaceAround,
                          maxY: maxY * 1.15,
                          minY: 0,
                          barTouchData: BarTouchData(
                            enabled: true,
                            touchTooltipData: BarTouchTooltipData(
                              getTooltipColor:
                                  (_) =>
                                      oscuro
                                          ? const Color(0xFF37474F)
                                          : const Color(0xFFECEFF1),
                              getTooltipItem: (group, gi, rod, ri) {
                                final i = group.x.toInt();
                                if (i < 0 || i >= stats.length) return null;
                                final s = stats[i];
                                return BarTooltipItem(
                                  '${s.nombre}\n',
                                  TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color:
                                        oscuro
                                            ? Colors.white
                                            : const Color(0xFF0D0D0D),
                                  ),
                                  children: [
                                    TextSpan(
                                      text: '${s.count} archivo(s)',
                                      style: TextStyle(
                                        color: accent,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                          titlesData: FlTitlesData(
                            show: true,
                            topTitles: const AxisTitles(
                              sideTitles: SideTitles(showTitles: false),
                            ),
                            rightTitles: const AxisTitles(
                              sideTitles: SideTitles(showTitles: false),
                            ),
                            leftTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                reservedSize: 32,
                                interval: maxY <= 6 ? 1 : null,
                                getTitlesWidget:
                                    (v, m) => Text(
                                      v == v.roundToDouble()
                                          ? '${v.toInt()}'
                                          : '',
                                      style: const TextStyle(fontSize: 10),
                                    ),
                              ),
                            ),
                            bottomTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                reservedSize: 52,
                                getTitlesWidget: (v, meta) {
                                  final i = v.toInt();
                                  if (i < 0 || i >= stats.length) {
                                    return const SizedBox.shrink();
                                  }
                                  return Padding(
                                    padding: const EdgeInsets.only(top: 6),
                                    child: Transform.rotate(
                                      alignment: Alignment.topCenter,
                                      angle: -0.45,
                                      child: Text(
                                        _etiquetaCorta(stats[i].nombre, 14),
                                        style: TextStyle(
                                          fontSize: 9,
                                          color:
                                              oscuro
                                                  ? const Color(0xFFB0BEC5)
                                                  : const Color(0xFF455A64),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                          gridData: FlGridData(
                            show: true,
                            drawVerticalLine: false,
                            horizontalInterval:
                                maxY <= 6 ? 1 : (maxY / 4).ceilToDouble(),
                            getDrawingHorizontalLine:
                                (value) => FlLine(
                                  color:
                                      oscuro
                                          ? const Color(0xFF455A64)
                                          : const Color(0xFFE0E0E0),
                                  strokeWidth: 1,
                                ),
                          ),
                          borderData: FlBorderData(show: false),
                          barGroups: List.generate(stats.length, (i) {
                            final n = stats[i].count.toDouble();
                            return BarChartGroupData(
                              x: i,
                              barRods: [
                                BarChartRodData(
                                  toY: n,
                                  color:
                                      _kLobbyChartColors[i %
                                          _kLobbyChartColors.length],
                                  width: 22,
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(6),
                                  ),
                                ),
                              ],
                            );
                          }),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 20),
            Text(
              'Distribución (categorías con archivos)',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: theme.typography.body?.color,
              ),
            ),
            const SizedBox(height: 8),
            if (pieTotal <= 0)
              Text(
                'Todas las categorías están en 0 archivos.',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.typography.caption?.color,
                ),
              )
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 160,
                    height: 160,
                    child: PieChart(
                      PieChartData(
                        sectionsSpace: 1,
                        centerSpaceRadius: 28,
                        sections: List.generate(nonZero.length, (i) {
                          final s = nonZero[i];
                          final pct = (s.count / pieTotal * 100);
                          return PieChartSectionData(
                            color:
                                _kLobbyChartColors[i %
                                    _kLobbyChartColors.length],
                            value: s.count.toDouble(),
                            title: pct >= 8 ? '${pct.round()}%' : '',
                            radius: 52,
                            titleStyle: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color:
                                  oscuro
                                      ? Colors.white
                                      : const Color(0xFF212121),
                            ),
                          );
                        }),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var i = 0; i < nonZero.length; i++) ...[
                          if (i > 0) const SizedBox(height: 4),
                          Row(
                            children: [
                              Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  color:
                                      _kLobbyChartColors[i %
                                          _kLobbyChartColors.length],
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  _etiquetaCorta(nonZero[i].nombre, 28),
                                  style: const TextStyle(fontSize: 11),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Text(
                                '${nonZero[i].count}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 12),
            Text(
              'Listado completo',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: theme.typography.body?.color,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final s in stats)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: theme.accentColor.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: theme.resources.controlStrokeColorDefault
                            .withValues(alpha: 0.6),
                      ),
                    ),
                    child: Text(
                      '${_etiquetaCorta(s.nombre, 36)}: ${s.count}',
                      style: const TextStyle(fontSize: 11.5),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _fmtDateTime(DateTime? d) {
    if (d == null) return 'Sin fecha';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  Widget _ayudasSpotlightCard(FluentThemeData theme) {
    final dark = theme.brightness == Brightness.dark;
    final latest = _ultimaAyudaVisual;
    final latestTitle =
        latest == null
            ? 'Sin documentos recientes'
            : ayudasTituloDocumento(latest);
    final latestDate = latest == null ? null : _safeAyudaDate(latest);
    final latestUser =
        latest == null
            ? ''
            : '${latest['Usuario_Subida'] ?? latest['usuario_subida'] ?? ''}'
                .trim();
    final pdfTint =
        dark ? theme.accentColor.withValues(alpha: 0.9) : const Color(0xFF1565C0);
    final lobbyAyudasCompact =
        ayudasLobbyAyudasCompacto(MediaQuery.sizeOf(context).width);
    return Container(
      padding: EdgeInsets.all(
        lobbyAyudasCompact ? 8 : UiTokens.cardPadding + 2,
      ),
      decoration: elevatedCardDecoration(theme),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Documentación reciente',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: theme.typography.body?.color,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Última ayuda visual en el sistema y acceso a la biblioteca.',
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.25,
                        color: theme.typography.caption?.color?.withValues(
                          alpha: 0.88,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (!lobbyAyudasCompact) ...[
                const SizedBox(width: 12),
                Button(
                  onPressed: () =>
                      widget.onNavigatePane(NavPaneId.ayudasVisuales),
                  child: const Text('Ver ayudas'),
                ),
              ] else
                _lobbyAyudasOverflowActions(
                  onIrBiblioteca: () =>
                      widget.onNavigatePane(NavPaneId.ayudasVisuales),
                  onAbrirUltimo: latest != null ? _openLatestAyuda : null,
                ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 4,
            runSpacing: 0,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              HyperlinkButton(
                child: Text('Proyectos activos ($_tractosActivos)'),
                onPressed: () =>
                    widget.onNavigatePane(NavPaneId.gestionProyectos),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: theme.accentColor.withValues(alpha: dark ? 0.1 : 0.07),
              borderRadius: BorderRadius.circular(10),
              border:
                  dark
                      ? null
                      : Border.all(
                        color: theme.resources.controlStrokeColorDefault
                            .withValues(alpha: 0.55),
                      ),
            ),
            child: Row(
              children: [
                Icon(FluentIcons.pdf, color: pdfTint, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        latestTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        latestUser.isEmpty
                            ? _fmtDateTime(latestDate)
                            : 'Usuario: $latestUser · ${_fmtDateTime(latestDate)}',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.typography.caption?.color,
                        ),
                      ),
                    ],
                  ),
                ),
                if (latest != null && !lobbyAyudasCompact)
                  _lobbyFilledAction(
                    label: 'Ver documento',
                    onPressed: _openLatestAyuda,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActions(FluentThemeData theme) {
    final role = parseAppRole(_userRole);
    final fallback = LobbyQuickActionsPrefs.defaults(role);
    final ids = LobbyQuickActionsPrefs.sanitize(
      _quickNavIds.isEmpty ? fallback : _quickNavIds,
      role,
    );
    final cards = ids
        .where((id) => LobbyQuickActionsPrefs.catalog[id] != null)
        .map((id) {
          final meta = LobbyQuickActionsPrefs.catalog[id]!;
          return _quickActionCard(
            theme: theme,
            icon: meta.icon,
            title: meta.title,
            subtitle: meta.subtitle,
            detail: meta.detail,
            onTap: () => widget.onNavigatePane(id),
          );
        })
        .toList();
    return Container(
      padding: const EdgeInsets.all(UiTokens.cardPadding - 2),
      decoration: elevatedCardDecoration(theme),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Accesos rápidos',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: theme.typography.body?.color,
                  ),
                ),
              ),
              Button(
                onPressed: _openQuickActionsDialog,
                child: const Text('Personalizar'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, c) {
              final estimatedPerCard = c.maxWidth > 1400 ? 250.0 : 230.0;
              final columns =
                  (c.maxWidth / estimatedPerCard).floor().clamp(1, 5);
              final cardWidth =
                  ((c.maxWidth - ((columns - 1) * 10)) / columns).clamp(
                    215.0,
                    280.0,
                  );
              return Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final card in cards)
                    SizedBox(
                      width: cardWidth,
                      child: card,
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _notificationsSummaryCard(FluentThemeData theme) {
    final empty = _notificacionesPreview.isEmpty;
    return Container(
      padding: const EdgeInsets.all(UiTokens.cardPadding + 2),
      decoration: elevatedCardDecoration(theme),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Notificaciones',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF1565C0),
                  ),
                ),
              ),
              _lobbyFilledAction(
                label: 'Abrir buzón',
                onPressed: _openInboxFromLobby,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Pendientes: $_notificacionesNoLeidas',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: theme.typography.body?.color?.withValues(alpha: 0.92),
            ),
          ),
          const SizedBox(height: 8),
          if (empty)
            Text(
              'No hay notificaciones recientes.',
              style: TextStyle(color: theme.typography.caption?.color),
            )
          else
            ..._notificacionesPreview.map((n) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: n.leido
                        ? theme.resources.subtleFillColorSecondary
                        : theme.accentColor.withValues(alpha: 0.09),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: theme.resources.controlStrokeColorDefault
                          .withValues(alpha: 0.6),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        FluentIcons.ringer,
                        size: 14,
                        color: n.leido ? theme.typography.caption?.color : theme.accentColor,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${n.title} · ${n.body}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12.2, height: 1.25),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _fmtDateTime(n.fecha),
                        style: TextStyle(
                          fontSize: 10.5,
                          color: theme.typography.caption?.color,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _quickActionCard({
    required FluentThemeData theme,
    required IconData icon,
    required String title,
    required String subtitle,
    required String detail,
    required VoidCallback onTap,
  }) {
    final cap = theme.typography.caption?.color?.withValues(alpha: 0.82);
    return Button(
      style: roundedFilledButtonStyle(),
      onPressed: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20),
            const SizedBox(height: 8),
            Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 13.5,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: 12,
                height: 1.25,
                fontWeight: FontWeight.w500,
                color: theme.typography.body?.color?.withValues(alpha: 0.9),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              detail,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                height: 1.2,
                color: cap,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(IconData icon, String label, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8, bottom: 6),
      child: Button(
        onPressed: onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14),
            const SizedBox(width: 6),
            Text(label),
          ],
        ),
      ),
    );
  }

  Widget _areaCard({
    required FluentThemeData theme,
    required String title,
    required Color accent,
    required String headline,
    required String headlineLabel,
    required String footerLine,
    required List<Widget> chips,
    int? badge,
  }) {
    return Container(
      padding: const EdgeInsets.all(UiTokens.cardPadding + 2),
      decoration: elevatedCardDecoration(theme),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: theme.typography.bodyStrong?.color,
                  ),
                ),
              ),
              if (badge != null && badge > 0)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '$badge',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: accent,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            headline,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: theme.typography.title?.color,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            headlineLabel,
            style: TextStyle(
              fontSize: 13,
              color: theme.typography.body?.color?.withValues(alpha: 0.75),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            footerLine,
            style: TextStyle(
              fontSize: 12,
              color: theme.typography.caption?.color,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(spacing: 0, runSpacing: 0, children: chips),
        ],
      ),
    );
  }
}
