import 'package:fluent_ui/fluent_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../services/api_client.dart';
import '../services/main_nav.dart';
import '../theme/page_title_style.dart';

class LobbyScreen extends StatefulWidget {
  final Function(int) onNavigate;
  final bool isAdmin;

  LobbyScreen({
    Key? key,
    required this.onNavigate,
    this.isAdmin = false,
  }) : super(key: key);

  @override
  State<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends State<LobbyScreen> {
  String _userName = 'Cargando...';
  String _userRole = '';

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

  @override
  void initState() {
    super.initState();
    _loadUser();
    _fetchAll();
  }

  Future<void> _loadUser() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _userName = prefs.getString('username') ?? 'Usuario';
        _userRole = prefs.getString('rol') ?? 'USER';
      });
    }
  }

  Future<void> _fetchAll() async {
    await Future.wait([_fetchKpis(), _fetchOperationalStats()]);
  }

  Future<void> _fetchKpis() async {
    try {
      final data = await ApiClient.get('/api/dashboard/kpi') as Map<String, dynamic>;
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

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final loading = isLoadingKpi || _loadingOps;

    return ScaffoldPage(
      padding: const EdgeInsets.only(top: 8),
      header: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Bienvenido, $_userName',
              style: pageTitleTextStyle(context, fontSize: 32).copyWith(
                fontWeight: FontWeight.w800,
                color: theme.typography.title?.color,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
            ),
            const SizedBox(height: 6),
            Text(
              'Panel de control | Rol: $_userRole',
              style: TextStyle(
                fontSize: 14,
                color: theme.typography.caption?.color?.withValues(alpha: 0.65),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Flujo de trabajo: Ingeniería → Gestión → Control → Administración',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: theme.accentColor.withValues(alpha: 0.95),
              ),
            ),
          ],
        ),
      ),
      content: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (kpiError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: InfoBar(
                  title: const Text('Backend no disponible (KPI)'),
                  content: Text(kpiError!),
                  severity: InfoBarSeverity.warning,
                  onClose: () => setState(() => kpiError = null),
                ),
              ),
            if (_opsError != null)
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
            else
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
                          () => widget.onNavigate(kPaneCadScanner),
                        ),
                        _chip(
                          FluentIcons.database,
                          'Catálogo',
                          () => widget.onNavigate(kPaneCatalogo),
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
                          () => widget.onNavigate(kPaneGestionProyectos),
                        ),
                        _chip(
                          FluentIcons.car,
                          'Expedientes VIN',
                          () => widget.onNavigate(kPaneVin),
                        ),
                      ],
                    ),
                    _areaCard(
                      theme: theme,
                      title: 'Control · Estadísticas',
                      accent: const Color(0xFF6A1B9A),
                      headline: '${totalLineasBom.toString()}',
                      headlineLabel: 'Piezas / líneas en BOM (volumen)',
                      footerLine: 'Salud global ${saludCad.toStringAsFixed(1)} %',
                      chips: [
                        _chip(
                          FluentIcons.pie_single,
                          'Dashboard Analytics',
                          () => widget.onNavigate(kPaneAnalytics),
                        ),
                        _chip(
                          FluentIcons.tablet,
                          'Centro de QA',
                          () => widget.onNavigate(kPaneQa),
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
                          () => widget.onNavigate(kPaneRadar),
                        ),
                        _chip(
                          FluentIcons.activity_feed,
                          'Centro de Monitoreo',
                          () => widget.onNavigate(kPaneMonitoreo),
                        ),
                      ],
                      badge: _misionesCentroPendientes > 0
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
      ),
    );
  }

  Widget _chip(
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    return Padding(
      padding: const EdgeInsets.only(right: 8, top: 6),
      child: Button(
        onPressed: onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(fontSize: 12.5)),
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
    final stroke = theme.resources.controlStrokeColorDefault;
    return Container(
      constraints: const BoxConstraints(minHeight: 200),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: stroke.withValues(alpha: 0.45)),
        boxShadow: [
          BoxShadow(
            color: theme.shadowColor.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 4,
                height: 22,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: theme.typography.body?.color,
                  ),
                ),
              ),
              if (badge != null)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE53935),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '$badge',
                    style: const TextStyle(
                      color: Color(0xFFFFFFFF),
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            headline,
            style: TextStyle(
              fontSize: 36,
              fontWeight: FontWeight.w800,
              height: 1.05,
              color: accent.withValues(alpha: 0.95),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            headlineLabel,
            style: TextStyle(
              fontSize: 13,
              color: theme.typography.caption?.color?.withValues(alpha: 0.85),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            footerLine,
            style: TextStyle(
              fontSize: 12,
              color: theme.typography.caption?.color?.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(children: chips),
        ],
      ),
    );
  }
}
