import 'dart:async';
import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:fl_chart/fl_chart.dart';

import '../services/api_client.dart';

/// Contenido del Expander «Telemetría de uso» en Configuración (solo desarrollador).
class DevTelemetrySettingsContent extends StatefulWidget {
  const DevTelemetrySettingsContent({super.key});

  @override
  State<DevTelemetrySettingsContent> createState() =>
      _DevTelemetrySettingsContentState();
}

class _DevTelemetrySettingsContentState extends State<DevTelemetrySettingsContent> {
  int _days = 14;
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _data;

  static const int _activosMinutes = 10;
  bool _loadingActivos = true;
  String? _errorActivos;
  List<Map<String, dynamic>> _activos = const [];
  Timer? _activosTimer;

  @override
  void initState() {
    super.initState();
    _reload();
    _reloadActivos();
    _activosTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _reloadActivos(),
    );
  }

  @override
  void dispose() {
    _activosTimer?.cancel();
    super.dispose();
  }

  Future<void> _reloadActivos() async {
    if (mounted) {
      setState(() {
        _loadingActivos = _activos.isEmpty;
      });
    }
    try {
      final raw = await ApiClient.get(
        '/api/dev/telemetry/activos',
        queryParameters: {'minutes': '$_activosMinutes'},
      );
      final usuarios = (raw is Map && raw['usuarios'] is List)
          ? (raw['usuarios'] as List)
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(
                    e.map((k, v) => MapEntry('$k', v)),
                  ))
              .toList()
          : <Map<String, dynamic>>[];
      if (!mounted) return;
      setState(() {
        _activos = usuarios;
        _errorActivos = null;
        _loadingActivos = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorActivos = '$e';
        _loadingActivos = false;
      });
    }
  }

  String _haceTexto(int seg) {
    if (seg < 60) return 'ahora mismo';
    final min = seg ~/ 60;
    if (min < 60) return 'hace $min min';
    final h = min ~/ 60;
    return 'hace $h h';
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await ApiClient.get(
        '/api/dev/telemetry/resumen',
        queryParameters: {'days': '$_days'},
      );
      if (raw is Map) {
        if (!mounted) return;
        setState(() {
          _data = Map<String, dynamic>.from(
            raw.map((k, v) => MapEntry('$k', v)),
          );
          _loading = false;
        });
      } else {
        throw StateError('Respuesta inválida');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
        _data = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final secondary = TextStyle(
      fontSize: 12,
      height: 1.35,
      color: theme.typography.caption?.color ??
          theme.resources.textFillColorSecondary,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Eventos de navegación y de producto enviados por todos los usuarios con sesión '
          'válida. Los nombres coinciden con las etiquetas del menú lateral y módulos.',
          style: secondary,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('Periodo:', style: theme.typography.bodyStrong),
            ComboBox<int>(
              value: _days,
              items: const [
                ComboBoxItem(value: 7, child: Text('7 días')),
                ComboBoxItem(value: 14, child: Text('14 días')),
                ComboBoxItem(value: 30, child: Text('30 días')),
              ],
              onChanged: _loading
                  ? null
                  : (v) {
                      if (v == null) return;
                      setState(() => _days = v);
                      _reload();
                    },
            ),
            FilledButton(
              onPressed: _loading ? null : _reload,
              child:
                  _loading
                      ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: ProgressRing(strokeWidth: 2),
                      )
                      : const Text('Actualizar'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _usuariosConectados(theme, secondary),
        const SizedBox(height: 16),
        if (_error != null)
          InfoBar(
            title: const Text('No se pudo cargar la telemetría'),
            content: Text(_error!),
            severity: InfoBarSeverity.warning,
          ),
        if (_loading && _data == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: ProgressRing()),
          )
        else if (_data != null) ...[
          _totalsRow(theme, _data!),
          const SizedBox(height: 20),
          Text(
            'Destinos más frecuentes (etiqueta de pantalla)',
            style: theme.typography.bodyStrong,
          ),
          const SizedBox(height: 8),
          SizedBox(height: 220, child: _TopDestinosBarChart(data: _data!)),
          const SizedBox(height: 20),
          Text(
            'Actividad por día',
            style: theme.typography.bodyStrong,
          ),
          const SizedBox(height: 8),
          SizedBox(height: 200, child: _PorDiaLineChart(data: _data!)),
          const SizedBox(height: 20),
          Text(
            'Usuarios con más eventos registrados',
            style: theme.typography.bodyStrong,
          ),
          const SizedBox(height: 8),
          SizedBox(height: 200, child: _TopUsuariosBarChart(data: _data!)),
          const SizedBox(height: 12),
          Text(
            'La tabla `Tbl_App_Uso_Eventos` se crea automáticamente en SQL Server la primera vez. '
            'Para liberar espacio, un administrador de base de datos puede purgar filas antiguas.',
            style: secondary,
          ),
        ],
      ],
    );
  }

  Widget _usuariosConectados(FluentThemeData theme, TextStyle secondary) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.resources.cardBackgroundFillColorDefault,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.resources.controlStrokeColorDefault.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: const BoxDecoration(
                  color: Color(0xFF2ECC71),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'Usuarios conectados',
                style: theme.typography.bodyStrong,
              ),
              const SizedBox(width: 8),
              Text(
                '(${_activos.length} · últimos $_activosMinutes min)',
                style: secondary,
              ),
              const Spacer(),
              if (_loadingActivos)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: ProgressRing(strokeWidth: 2),
                )
              else
                IconButton(
                  icon: const Icon(FluentIcons.refresh, size: 14),
                  onPressed: _reloadActivos,
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Quién tiene la app abierta y qué módulo está viendo (presencia en tiempo real).',
            style: secondary,
          ),
          const SizedBox(height: 10),
          if (_errorActivos != null)
            InfoBar(
              title: const Text('No se pudo cargar la presencia'),
              content: Text(_errorActivos!),
              severity: InfoBarSeverity.warning,
            )
          else if (_activos.isEmpty && !_loadingActivos)
            Text('Nadie con actividad en los últimos $_activosMinutes minutos.',
                style: secondary)
          else
            Column(
              children: [
                for (final u in _activos) _filaActivo(theme, secondary, u),
              ],
            ),
        ],
      ),
    );
  }

  Widget _filaActivo(
    FluentThemeData theme,
    TextStyle secondary,
    Map<String, dynamic> u,
  ) {
    final usuario = '${u['usuario_login'] ?? ''}';
    final rol = '${u['rol_efectivo'] ?? ''}';
    final viendo = '${u['viendo'] ?? ''}';
    final seg = (u['hace_segundos'] is num)
        ? (u['hace_segundos'] as num).toInt()
        : int.tryParse('${u['hace_segundos']}') ?? 0;
    final reciente = seg < 180;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: reciente ? const Color(0xFF2ECC71) : const Color(0xFFF1C40F),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  usuario.isEmpty ? '—' : usuario,
                  style: theme.typography.body?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                if (rol.isNotEmpty)
                  Text(rol, style: secondary, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 4,
            child: Row(
              children: [
                Icon(FluentIcons.red_eye,
                    size: 12, color: theme.typography.caption?.color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    viendo.isEmpty ? 'En la aplicación' : viendo,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(_haceTexto(seg), style: secondary),
        ],
      ),
    );
  }

  Widget _totalsRow(FluentThemeData theme, Map<String, dynamic> data) {
    final t = data['totales'];
    final ev = t is Map ? (t['eventos'] ?? 0) : 0;
    final us = t is Map ? (t['usuarios_distintos'] ?? 0) : 0;
    return Row(
      children: [
        _chipStat(theme, 'Eventos', '$ev'),
        const SizedBox(width: 12),
        _chipStat(theme, 'Usuarios distintos', '$us'),
      ],
    );
  }

  Widget _chipStat(FluentThemeData theme, String k, String v) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.accentColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.resources.controlStrokeColorDefault.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(k, style: TextStyle(fontSize: 11, color: theme.typography.caption?.color)),
          Text(v, style: theme.typography.bodyStrong?.copyWith(fontSize: 18)),
        ],
      ),
    );
  }
}

class _TopDestinosBarChart extends StatelessWidget {
  const _TopDestinosBarChart({required this.data});
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final raw = data['top_destinos'];
    final list = raw is List ? raw : const <dynamic>[];
    if (list.isEmpty) {
      return const Center(child: Text('Sin datos en el periodo.'));
    }
    final items = list.take(10).toList();
    final maxY = items.fold<double>(
      1,
      (m, e) {
        if (e is! Map) return m;
        final n = (e['n'] is num) ? (e['n'] as num).toDouble() : double.tryParse('${e['n']}') ?? 0;
        return n > m ? n : m;
      },
    );

    return BarChart(
      BarChartData(
        maxY: maxY * 1.15,
        gridData: FlGridData(show: true, drawVerticalLine: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 36,
              getTitlesWidget: (v, m) => Text(
                '${v.toInt()}',
                style: TextStyle(fontSize: 10, color: theme.typography.caption?.color),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (v, m) {
                final i = v.toInt();
                if (i < 0 || i >= items.length) return const SizedBox.shrink();
                final e = items[i];
                if (e is! Map) return const SizedBox.shrink();
                final lab = '${e['destino_etiqueta'] ?? ''}';
                final short = lab.length > 14 ? '${lab.substring(0, 12)}…' : lab;
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Transform.rotate(
                    angle: -0.55,
                    child: Text(
                      short,
                      style: TextStyle(fontSize: 9, color: theme.typography.caption?.color),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        borderData: FlBorderData(show: false),
        barGroups: [
          for (var i = 0; i < items.length; i++)
            if (items[i] is Map)
              BarChartGroupData(
                x: i,
                barRods: [
                  BarChartRodData(
                    toY: ((items[i] as Map)['n'] is num)
                        ? ((items[i] as Map)['n'] as num).toDouble()
                        : double.tryParse('${(items[i] as Map)['n']}') ?? 0,
                    width: 14,
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                    color: theme.accentColor.withValues(alpha: 0.85),
                  ),
                ],
              ),
        ],
      ),
    );
  }
}

class _PorDiaLineChart extends StatelessWidget {
  const _PorDiaLineChart({required this.data});
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final raw = data['por_dia'];
    final list = raw is List ? raw : const <dynamic>[];
    if (list.isEmpty) {
      return const Center(child: Text('Sin serie diaria.'));
    }
    final spots = <FlSpot>[];
    double maxY = 1;
    for (var i = 0; i < list.length; i++) {
      final e = list[i];
      if (e is! Map) continue;
      final n = (e['n'] is num) ? (e['n'] as num).toDouble() : double.tryParse('${e['n']}') ?? 0;
      if (n > maxY) maxY = n;
      spots.add(FlSpot(i.toDouble(), n));
    }

    return LineChart(
      LineChartData(
        minY: 0,
        maxY: maxY * 1.1,
        gridData: FlGridData(show: true, drawVerticalLine: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 32,
              getTitlesWidget: (v, m) => Text(
                '${v.toInt()}',
                style: TextStyle(fontSize: 10, color: theme.typography.caption?.color),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: math.max(1, (list.length / 6).ceil()).toDouble(),
              getTitlesWidget: (v, m) {
                final i = v.toInt();
                if (i < 0 || i >= list.length) return const SizedBox.shrink();
                final e = list[i];
                if (e is! Map) return const SizedBox.shrink();
                final f = '${e['fecha'] ?? ''}';
                final short = f.length >= 10 ? f.substring(5, 10) : f;
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    short,
                    style: TextStyle(fontSize: 9, color: theme.typography.caption?.color),
                  ),
                );
              },
            ),
          ),
        ),
        borderData: FlBorderData(show: false),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: theme.accentColor,
            barWidth: 2.5,
            dotData: FlDotData(show: list.length <= 20),
            belowBarData: BarAreaData(
              show: true,
              color: theme.accentColor.withValues(alpha: 0.12),
            ),
          ),
        ],
      ),
    );
  }
}

class _TopUsuariosBarChart extends StatelessWidget {
  const _TopUsuariosBarChart({required this.data});
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final raw = data['top_usuarios'];
    final list = raw is List ? raw : const <dynamic>[];
    if (list.isEmpty) {
      return const Center(child: Text('Sin datos de usuarios.'));
    }
    final items = list.take(10).toList();
    final maxY = items.fold<double>(
      1,
      (m, e) {
        if (e is! Map) return m;
        final n = (e['n'] is num) ? (e['n'] as num).toDouble() : double.tryParse('${e['n']}') ?? 0;
        return n > m ? n : m;
      },
    );

    return BarChart(
      BarChartData(
        maxY: maxY * 1.12,
        gridData: FlGridData(show: true, drawVerticalLine: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 36,
              getTitlesWidget: (v, m) => Text(
                '${v.toInt()}',
                style: TextStyle(fontSize: 10, color: theme.typography.caption?.color),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (v, m) {
                final i = v.toInt();
                if (i < 0 || i >= items.length) return const SizedBox.shrink();
                final e = items[i];
                if (e is! Map) return const SizedBox.shrink();
                final u = '${e['usuario_login'] ?? ''}';
                final short = u.length > 12 ? '${u.substring(0, 10)}…' : u;
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Transform.rotate(
                    angle: -0.45,
                    child: Text(
                      short,
                      style: TextStyle(fontSize: 9, color: theme.typography.caption?.color),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        borderData: FlBorderData(show: false),
        barGroups: [
          for (var i = 0; i < items.length; i++)
            if (items[i] is Map)
              BarChartGroupData(
                x: i,
                barRods: [
                  BarChartRodData(
                    toY: ((items[i] as Map)['n'] is num)
                        ? ((items[i] as Map)['n'] as num).toDouble()
                        : double.tryParse('${(items[i] as Map)['n']}') ?? 0,
                    width: 12,
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                    color: const Color(0xFF00897B).withValues(alpha: 0.85),
                  ),
                ],
              ),
        ],
      ),
    );
  }
}
