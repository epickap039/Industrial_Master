import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as material;
import 'package:table_calendar/table_calendar.dart';

import '../screens/monitoreo/widgets/task_display_utils.dart';

List<String> _usuariosAsignadosBitacora(Map<String, dynamic> t) {
  final raw = t['usuarios_asignados'];
  final out = <String>[];
  final seen = <String>{};
  if (raw is List) {
    for (final item in raw) {
      final u = '${item ?? ''}'.trim();
      if (u.isEmpty) continue;
      final k = u.toLowerCase();
      if (seen.contains(k)) continue;
      seen.add(k);
      out.add(u);
    }
  }
  if (out.isEmpty) {
    final u = asignadoMision(t).trim();
    if (u.isNotEmpty && u != 'Sin asignar') out.add(u);
  }
  return out;
}

Color _colorUsuarioBitacora(String user) {
  const palette = <Color>[
    Color(0xFF1565C0),
    Color(0xFF0D47A1),
    Color(0xFF6A1B9A),
    Color(0xFF4527A0),
    Color(0xFFAD1457),
    Color(0xFFC2185B),
    Color(0xFFE65100),
    Color(0xFF8E24AA),
    Color(0xFF0277BD),
  ];
  var hash = 0;
  for (final c in user.codeUnits) {
    hash = (hash * 31 + c) & 0xFFFFFFFF;
  }
  return palette[hash.abs() % palette.length];
}

/// Color de indicador / tarjeta por misión (calendario y panel del día).
Color colorBarraBitacoraParaTarea(Map<String, dynamic> t) {
  final users = _usuariosAsignadosBitacora(t);
  if (users.length > 1) {
    // Multiusuario: neutral para no privilegiar un color concreto.
    return const Color(0xFF394B63);
  }
  if (users.length == 1) return _colorUsuarioBitacora(users.first);
  if (esCancelada(t)) return const Color(0xFF6D4C41);
  return const Color(0xFF455A64);
}

/// Bitacora Pro: calendario de misiones finalizadas/canceladas + panel del dia.
/// La lista debe venir ya filtrada (p. ej. solo Radar/Manual por tipo o SourceType en el padre).
class BitacoraCalendarioPanel extends StatefulWidget {
  const BitacoraCalendarioPanel({
    super.key,
    required this.tareasHistorial,
    required this.onTapTarea,
    this.tareasActivasParaProyeccion = const [],
    this.onReactivarTarea,
    this.onEliminarTarea,
  });

  final List<Map<String, dynamic>> tareasHistorial;
  final List<Map<String, dynamic>> tareasActivasParaProyeccion;
  final void Function(Map<String, dynamic> tarea) onTapTarea;
  final Future<void> Function(Map<String, dynamic> tarea)? onReactivarTarea;
  final Future<void> Function(Map<String, dynamic> tarea)? onEliminarTarea;

  @override
  State<BitacoraCalendarioPanel> createState() =>
      _BitacoraCalendarioPanelState();
}

class _BitacoraCalendarioPanelState extends State<BitacoraCalendarioPanel> {
  late DateTime _focusedDay;
  DateTime? _selectedDay;
  int _vista = 0;
  CalendarFormat _calendarFormat = CalendarFormat.month;

  @override
  void initState() {
    super.initState();
    final n = DateTime.now();
    _focusedDay = DateTime(n.year, n.month, n.day);
    _selectedDay = _focusedDay;
  }

  @override
  void didUpdateWidget(BitacoraCalendarioPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tareasHistorial != widget.tareasHistorial) {
      setState(() {});
    }
  }

  /// Cada dia incluido en [inicio, fin] de la mision lista esa mision.
  Map<DateTime, List<Map<String, dynamic>>> _porDia() {
    final m = <DateTime, List<Map<String, dynamic>>>{};
    for (final t in widget.tareasHistorial) {
      final r = rangoHistorialCalendario(t);
      if (r == null) continue;
      var d = r.start;
      while (!d.isAfter(r.end)) {
        final k = DateTime(d.year, d.month, d.day);
        m.putIfAbsent(k, () => []).add(t);
        d = d.add(const Duration(days: 1));
      }
    }
    for (final e in m.entries) {
      final kDay = e.key;
      e.value.sort((a, b) {
        int rank(Map<String, dynamic> t) {
          if (esCritica(t)) return 0;
          if (esPausada(t)) return 1;
          return 2;
        }

        final rc = rank(a).compareTo(rank(b));
        if (rc != 0) return rc;
        bool unDiaEnK(Map<String, dynamic> t) {
          final r = rangoHistorialCalendario(t);
          return r != null && r.start == r.end && r.start == kDay;
        }

        if (unDiaEnK(a) && unDiaEnK(b)) {
          final ta = minutosDesdeMedianocheInicioCiclo(a);
          final tb = minutosDesdeMedianocheInicioCiclo(b);
          if (ta != tb) return ta.compareTo(tb);
        }
        final fa = fechaCierreHistorialLegible(a);
        final fb = fechaCierreHistorialLegible(b);
        return fa.compareTo(fb);
      });
    }
    return m;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.tareasHistorial.isEmpty) {
      return Center(
        child: Text(
          'Sin misiones en historial para mostrar en calendario.',
          style: TextStyle(
            fontSize: 14,
            color: FluentTheme.of(context).brightness == Brightness.dark
                ? const Color(0xFFB0BEC5)
                : const Color(0xFF37474F),
          ),
        ),
      );
    }

    final porDia = _porDia();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Bitácora Pro',
                      style: FluentTheme.of(context).typography.subtitle?.copyWith(
                            fontWeight: FontWeight.w800,
                            fontSize: 17,
                          ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Etiquetas de color por misión ese día; toca la fecha para ver el detalle.',
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.25,
                        color: FluentTheme.of(context).brightness ==
                                Brightness.dark
                            ? const Color(0xFF90A4AE)
                            : const Color(0xFF607D8B),
                      ),
                    ),
                  ],
                ),
              ),
              ToggleSwitch(
                checked: _vista == 1,
                content: Text(_vista == 0 ? 'Calendario' : 'Estadísticas'),
                onChanged: (v) => setState(() => _vista = v ? 1 : 0),
              ),
            ],
          ),
        ),
        if (_vista == 1)
          Expanded(
            child: _BitacoraEstadisticasPanelStateful(
              tareas: widget.tareasHistorial,
              tareasActivas: widget.tareasActivasParaProyeccion,
            ),
          )
        else
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) {
                final narrow = c.maxWidth < 900;
                final oscuro =
                    FluentTheme.of(context).brightness == Brightness.dark;
                Widget cal = material.Material(
                  color: material.Colors.transparent,
                  child: material.Container(
                    decoration: BoxDecoration(
                      color: oscuro
                          ? const Color(0xFF252830)
                          : const Color(0xFFF7F9FC),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: oscuro
                            ? const Color(0xFF3D4550)
                            : const Color(0xFFE2E8F0),
                      ),
                    ),
                    padding: const EdgeInsets.fromLTRB(6, 8, 6, 10),
                    child: TableCalendar(
                      locale: 'es_ES',
                      firstDay: DateTime(2020, 1, 1),
                      lastDay: DateTime(2035, 12, 31),
                      focusedDay: _focusedDay,
                      calendarFormat: _calendarFormat,
                      availableCalendarFormats: const {
                        CalendarFormat.month: 'Mes',
                        CalendarFormat.week: 'Semana',
                      },
                      rowHeight:
                          _calendarFormat == CalendarFormat.week ? 72 : 82,
                      daysOfWeekHeight: 26,
                      shouldFillViewport:
                          _calendarFormat == CalendarFormat.month,
                      onFormatChanged: (f) =>
                          setState(() => _calendarFormat = f),
                      selectedDayPredicate: (d) =>
                          _selectedDay != null &&
                          d.year == _selectedDay!.year &&
                          d.month == _selectedDay!.month &&
                          d.day == _selectedDay!.day,
                      startingDayOfWeek: StartingDayOfWeek.monday,
                      eventLoader: (day) {
                        final k = DateTime(day.year, day.month, day.day);
                        return porDia[k] ?? [];
                      },
                      onDaySelected: (sel, foc) {
                        setState(() {
                          _selectedDay =
                              DateTime(sel.year, sel.month, sel.day);
                          _focusedDay =
                              DateTime(foc.year, foc.month, foc.day);
                        });
                      },
                      onPageChanged: (f) => setState(
                        () => _focusedDay =
                            DateTime(f.year, f.month, f.day),
                      ),
                      calendarStyle: CalendarStyle(
                        outsideDaysVisible: true,
                        markersMaxCount: 8,
                        markersAlignment: Alignment.bottomCenter,
                        markersOffset: const PositionedOffset(bottom: 18),
                        markerMargin: EdgeInsets.zero,
                        cellMargin: const EdgeInsets.symmetric(
                          horizontal: 2,
                          vertical: 2,
                        ),
                        cellAlignment: Alignment.topCenter,
                        cellPadding: const EdgeInsets.only(top: 4),
                        defaultDecoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: material.Colors.transparent,
                        ),
                        weekendDecoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: material.Colors.transparent,
                        ),
                        outsideDecoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: material.Colors.transparent,
                        ),
                        weekendTextStyle: TextStyle(
                          color: oscuro
                              ? const Color(0xFF90CAF9)
                              : const Color(0xFF1565C0),
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                        todayDecoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: oscuro
                              ? const Color(0xFF006064)
                                  .withValues(alpha: 0.12)
                              : const Color(0xFFB2DFDB)
                                  .withValues(alpha: 0.22),
                          border: Border.all(
                            color: oscuro
                                ? const Color(0xFF26A69A)
                                : const Color(0xFF00897B),
                            width: 1.25,
                          ),
                        ),
                        todayTextStyle: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: oscuro
                              ? const Color(0xFF80CBC4)
                              : const Color(0xFF00695C),
                        ),
                        selectedDecoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          color: oscuro
                              ? const Color(0xFF5C6BC0)
                                  .withValues(alpha: 0.28)
                              : const Color(0xFF3949AB)
                                  .withValues(alpha: 0.16),
                          border: Border.all(
                            color: oscuro
                                ? const Color(0xFF9FA8DA)
                                : const Color(0xFF3949AB),
                            width: 1.25,
                          ),
                        ),
                        selectedTextStyle: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: oscuro
                              ? const Color(0xFFE8EAF6)
                              : const Color(0xFF1A237E),
                        ),
                        defaultTextStyle: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: oscuro
                              ? const Color(0xFFECEFF1)
                              : const Color(0xFF37474F),
                        ),
                      ),
                      calendarBuilders: CalendarBuilders(
                        markerBuilder: (ctx, day, events) =>
                            _marcadoresCeldaBitacora(ctx, events),
                      ),
                      headerStyle: const HeaderStyle(
                        formatButtonVisible: true,
                        titleCentered: true,
                        formatButtonShowsNext: false,
                      ),
                    ),
                  ),
                );
                if (_calendarFormat == CalendarFormat.week) {
                  cal = material.SizedBox(
                    height: 232,
                    child: cal,
                  );
                }

                final sel = _selectedDay != null
                    ? DateTime(
                        _selectedDay!.year,
                        _selectedDay!.month,
                        _selectedDay!.day,
                      )
                    : null;
                final delDia =
                    sel != null ? (porDia[sel] ?? []) : <Map<String, dynamic>>[];

                final panel = _DiaDetallePanel(
                  tareas: delDia,
                  onTapTarea: widget.onTapTarea,
                  fecha: _selectedDay,
                  onReactivarTarea: widget.onReactivarTarea,
                  onEliminarTarea: widget.onEliminarTarea,
                );

                if (narrow) {
                  final panelH = (c.maxHeight * 0.48).clamp(340.0, 620.0);
                  return material.SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        cal,
                        const SizedBox(height: 12),
                        SizedBox(height: panelH, child: panel),
                      ],
                    ),
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 3, child: cal),
                    const SizedBox(width: 12),
                    Expanded(flex: 2, child: panel),
                  ],
                );
              },
            ),
          ),
      ],
    );
  }
}

String _etiquetaCortaTagMision(Map<String, dynamic> t) {
  final s = tituloMision(t).trim();
  if (s.isEmpty) return '·';
  if (s.length <= 5) return s;
  return '${s.substring(0, 5)}…';
}

/// Mini etiquetas de color por misión (sin barras multi-día).
Widget _marcadoresCeldaBitacora(BuildContext context, List<dynamic> events) {
  final list = <Map<String, dynamic>>[
    for (final e in events)
      if (e is Map<String, dynamic>) e
      else if (e is Map)
        Map<String, dynamic>.from(
          e.map((k, v) => MapEntry('$k', v)),
        )
      else
        <String, dynamic>{},
  ].where((m) => m.isNotEmpty).toList();

  if (list.isEmpty) return const SizedBox.shrink();

  final oscuro = FluentTheme.of(context).brightness == Brightness.dark;
  const maxTags = 6;
  final n = list.length;

  return Positioned(
    left: 1,
    right: 1,
    bottom: 18,
    height: 30,
    child: Center(
      child: Wrap(
        spacing: 2,
        runSpacing: 2,
        alignment: WrapAlignment.center,
        children: [
          for (var i = 0; i < n && i < maxTags; i++)
            _tagActividadBitacora(list[i], oscuro),
          if (n > maxTags)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                color: oscuro ? const Color(0xFF455A64) : const Color(0xFFECEFF1),
              ),
              child: Text(
                '+${n - maxTags}',
                style: TextStyle(
                  fontSize: 7.5,
                  fontWeight: FontWeight.w800,
                  color: oscuro
                      ? const Color(0xFFECEFF1)
                      : const Color(0xFF37474F),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

Widget _tagActividadBitacora(Map<String, dynamic> t, bool oscuro) {
  final fill = colorBarraBitacoraParaTarea(t);
  final crit = esCritica(t);
  final fg = fill.computeLuminance() > 0.55
      ? const Color(0xFF263238)
      : const Color(0xFFFFFFFF);
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
    decoration: BoxDecoration(
      color: fill,
      borderRadius: BorderRadius.circular(4),
      border: Border.all(
        width: crit ? 1.1 : 0.65,
        color: crit
            ? const Color(0xFFC62828)
            : (oscuro
                ? const Color(0x28000000)
                : const Color(0x1F000000)),
      ),
      boxShadow: [
        BoxShadow(
          color: fill.withValues(alpha: 0.28),
          blurRadius: 2,
          offset: const Offset(0, 1),
        ),
      ],
    ),
    constraints: const BoxConstraints(maxWidth: 54),
    child: Text(
      _etiquetaCortaTagMision(t),
      maxLines: 1,
      overflow: TextOverflow.clip,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: 7.5,
        fontWeight: FontWeight.w800,
        height: 1.05,
        color: fg,
      ),
    ),
  );
}

/// Resumen agregado para la pestaña Estadísticas (sin datos sensibles).
class _BitacoraAgg {
  const _BitacoraAgg({
    required this.total,
    required this.terminadas,
    required this.canceladas,
    required this.manual,
    required this.radar,
    required this.leadHorasPromedio,
    required this.leadHorasMediana,
    required this.muestrasLeadTime,
    required this.minutosPresupuestadosSuma,
    required this.conPresupuesto,
    required this.mesesOrden,
    required this.cierresPorMes,
    required this.topResponsables,
  });

  final int total;
  final int terminadas;
  final int canceladas;
  final int manual;
  final int radar;
  final double? leadHorasPromedio;
  final double? leadHorasMediana;
  final int muestrasLeadTime;
  final int minutosPresupuestadosSuma;
  final int conPresupuesto;
  final List<String> mesesOrden;
  final Map<String, int> cierresPorMes;
  final List<MapEntry<String, int>> topResponsables;
}

_BitacoraAgg _calcularAgg(List<Map<String, dynamic>> tasks) {
  if (tasks.isEmpty) {
    return _BitacoraAgg(
      total: 0,
      terminadas: 0,
      canceladas: 0,
      manual: 0,
      radar: 0,
      leadHorasPromedio: null,
      leadHorasMediana: null,
      muestrasLeadTime: 0,
      minutosPresupuestadosSuma: 0,
      conPresupuesto: 0,
      mesesOrden: [],
      cierresPorMes: {},
      topResponsables: [],
    );
  }
  var cancel = 0;
  var man = 0;
  var rad = 0;
  final leadMin = <int>[];
  var sumMin = 0;
  var conPres = 0;
  final responsableCount = <String, int>{};

  for (final t in tasks) {
    if (esCancelada(t)) {
      cancel++;
    }
    if (esManualSource(t)) {
      man++;
    } else {
      rad++;
    }
    final uCierre = usuarioCompletoHistorialLegible(t);
    final u = uCierre.isNotEmpty ? uCierre : asignadoMision(t);
    if (u.isNotEmpty && u != 'Sin asignar') {
      responsableCount[u] = (responsableCount[u] ?? 0) + 1;
    }
    if (!esCancelada(t)) {
      final a = fechaInicioHistorialDate(t);
      final b = fechaCierreHistorialDate(t);
      if (a != null && b != null && !b.isBefore(a)) {
        leadMin.add(b.difference(a).inMinutes);
      }
    }
    final mp = totalMinutosPresupuestoCombinado(t);
    if (mp != null && mp > 0 && !manualSinTiempoEstimado(t)) {
      sumMin += mp;
      conPres++;
    }
  }

  final total = tasks.length;
  final termin = total - cancel;
  leadMin.sort();
  double? prom;
  double? med;
  if (leadMin.isNotEmpty) {
    prom = leadMin.reduce((a, b) => a + b) / leadMin.length / 60.0;
    final mid = leadMin.length ~/ 2;
    if (leadMin.length.isOdd) {
      med = leadMin[mid] / 60.0;
    } else {
      med = (leadMin[mid - 1] + leadMin[mid]) / 2.0 / 60.0;
    }
  }

  final now = DateTime.now();
  final mesesOrden = <String>[];
  final cierresPorMes = <String, int>{};
  for (var i = 11; i >= 0; i--) {
    final d = DateTime(now.year, now.month - i);
    final k =
        '${d.year}-${d.month.toString().padLeft(2, '0')}';
    mesesOrden.add(k);
    cierresPorMes[k] = 0;
  }
  for (final t in tasks) {
    final fd = fechaCierreHistorialDate(t);
    if (fd == null) continue;
    final k =
        '${fd.year}-${fd.month.toString().padLeft(2, '0')}';
    if (cierresPorMes.containsKey(k)) {
      cierresPorMes[k] = (cierresPorMes[k] ?? 0) + 1;
    }
  }

  final top = responsableCount.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  return _BitacoraAgg(
    total: total,
    terminadas: termin,
    canceladas: cancel,
    manual: man,
    radar: rad,
    leadHorasPromedio: prom,
    leadHorasMediana: med,
    muestrasLeadTime: leadMin.length,
    minutosPresupuestadosSuma: sumMin,
    conPresupuesto: conPres,
    mesesOrden: mesesOrden,
    cierresPorMes: cierresPorMes,
    topResponsables: top.take(8).toList(),
  );
}

/// Colores pastel para gráfico de pastel (quién cerró).
const List<Color> _kPiePastel = <Color>[
  Color(0xFF90CAF9),
  Color(0xFFA5D6A7),
  Color(0xFFCE93D8),
  Color(0xFFFFAB91),
  Color(0xFF80DEEA),
  Color(0xFFFFE082),
  Color(0xFF9FA8DA),
  Color(0xFFBCAAA4),
];

String _etiquetaMes(String yyyymm) {
  const meses = [
    '',
    'ene',
    'feb',
    'mar',
    'abr',
    'may',
    'jun',
    'jul',
    'ago',
    'sep',
    'oct',
    'nov',
    'dic',
  ];
  final p = yyyymm.split('-');
  if (p.length != 2) return yyyymm;
  final y = int.tryParse(p[0]) ?? 0;
  final m = int.tryParse(p[1]) ?? 0;
  if (m < 1 || m > 12) return yyyymm;
  return '${meses[m]} ${y % 100}';
}

String _fmtHoras(double h) {
  if (h < 1) return '${(h * 60).round()} min';
  return '${h.toStringAsFixed(1)} h';
}

List<MapEntry<String, int>> _cargaActivaPorUsuario(
  List<Map<String, dynamic>> tasks,
) {
  final byUser = <String, int>{};
  for (final t in tasks) {
    final u = asignadoMision(t);
    if (u.trim().isEmpty || u == 'Sin asignar') continue;
    final rem = minutosRestantesEstimados(t);
    if (rem == null || rem <= 0) continue;
    byUser[u] = (byUser[u] ?? 0) + rem;
  }
  final out = byUser.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return out;
}

class _BitacoraEstadisticasPanelStateful extends StatefulWidget {
  const _BitacoraEstadisticasPanelStateful({
    required this.tareas,
    this.tareasActivas = const [],
  });

  final List<Map<String, dynamic>> tareas;
  final List<Map<String, dynamic>> tareasActivas;

  @override
  State<_BitacoraEstadisticasPanelStateful> createState() =>
      _BitacoraEstadisticasPanelStatefulState();
}

class _BitacoraEstadisticasPanelStatefulState
    extends State<_BitacoraEstadisticasPanelStateful> {
  final material.ScrollController _statsScroll = material.ScrollController();

  @override
  void dispose() {
    _statsScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tareas = widget.tareas;
    final theme = FluentTheme.of(context);
    final oscuro = theme.brightness == Brightness.dark;
    final agg = _calcularAgg(tareas);
    final cargaActiva = _cargaActivaPorUsuario(widget.tareasActivas);

    if (agg.total == 0) {
      return Center(
        child: Text(
          'Sin misiones en historial para estadísticas.',
          style: TextStyle(
            fontSize: 14,
            color: oscuro ? const Color(0xFFB0BEC5) : const Color(0xFF37474F),
          ),
        ),
      );
    }

    final accent = theme.accentColor;
    final maxY = agg.mesesOrden
        .map((k) => agg.cierresPorMes[k] ?? 0)
        .fold<int>(1, math.max);

    return Scrollbar(
      controller: _statsScroll,
      thumbVisibility: true,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: true),
        child: SingleChildScrollView(
          controller: _statsScroll,
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Resumen de tu Bitácora',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: oscuro ? const Color(0xFFF5F5F5) : const Color(0xFF0D0D0D),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Cifras de las misiones que ves en esta pestaña (terminadas o canceladas). '
                'Abajo: cuánto tardan en cerrarse y un gráfico por mes.',
                style: TextStyle(
                  fontSize: 13,
                  color: oscuro ? const Color(0xFFB0BEC5) : const Color(0xFF455A64),
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _statChip(
                    icon: FluentIcons.check_list,
                    titulo: 'Total',
                    valor: '${agg.total}',
                    color: accent,
                    oscuro: oscuro,
                  ),
                  _statChip(
                    icon: FluentIcons.completed,
                    titulo: 'Terminadas',
                    valor: '${agg.terminadas}',
                    color: const Color(0xFF2E7D32),
                    oscuro: oscuro,
                  ),
                  _statChip(
                    icon: FluentIcons.cancel,
                    titulo: 'Canceladas',
                    valor: '${agg.canceladas}',
                    color: const Color(0xFFE65100),
                    oscuro: oscuro,
                  ),
                  _statChip(
                    icon: FluentIcons.page_list,
                    titulo: 'Manual',
                    valor: '${agg.manual}',
                    color: const Color(0xFF1565C0),
                    oscuro: oscuro,
                  ),
                  _statChip(
                    icon: FluentIcons.bullseye_target,
                    titulo: 'Radar',
                    valor: '${agg.radar}',
                    color: const Color(0xFF6A1B9A),
                    oscuro: oscuro,
                  ),
                ],
              ),
              if (cargaActiva.isNotEmpty) ...[
                const SizedBox(height: 16),
                Card(
                  child: ColoredBox(
                    color: _statsSurface(oscuro),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Estimado de fin por responsable (activas)',
                            style: theme.typography.bodyStrong?.copyWith(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 8),
                          for (final e in cargaActiva.take(8)) ...[
                            Text(
                              (() {
                                final fin = estimadoFinLaboralDesdeAhoraEtiqueta(e.value);
                                if (fin == null) return '${e.key} - sin estimación';
                                return '${e.key} - finaliza sus actividades el $fin';
                              })(),
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: oscuro ? const Color(0xFFECEFF1) : const Color(0xFF263238),
                                height: 1.35,
                              ),
                            ),
                            const SizedBox(height: 4),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Card(
                child: ColoredBox(
                  color: _statsSurface(oscuro),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '¿Cuánto tardan en cerrarse?',
                          style: theme.typography.bodyStrong?.copyWith(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Desde el inicio del ciclo hasta el cierre (solo misiones no canceladas, con fechas válidas).',
                          style: TextStyle(
                            fontSize: 12,
                            color: oscuro
                                ? const Color(0xFF90A4AE)
                                : const Color(0xFF607D8B),
                            height: 1.3,
                          ),
                        ),
                        const SizedBox(height: 14),
                        if (agg.muestrasLeadTime > 0) ...[
                          Row(
                            children: [
                              Expanded(
                                child: _statsBigNumber(
                                  etiqueta: 'Promedio',
                                  valor: _fmtHoras(agg.leadHorasPromedio!),
                                  oscuro: oscuro,
                                  color: const Color(0xFF1565C0),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: _statsBigNumber(
                                  etiqueta: 'Mediana',
                                  valor: _fmtHoras(agg.leadHorasMediana!),
                                  oscuro: oscuro,
                                  color: const Color(0xFF00897B),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Basado en ${agg.muestrasLeadTime} misión(es).',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: oscuro
                                  ? const Color(0xFFB0BEC5)
                                  : const Color(0xFF455A64),
                            ),
                          ),
                        ] else
                          Text(
                            'No hay suficientes fechas de inicio y cierre para calcular tiempos.',
                            style: TextStyle(
                              fontSize: 13,
                              color: oscuro
                                  ? const Color(0xFFE0E0E0)
                                  : const Color(0xFF424242),
                              height: 1.35,
                            ),
                          ),
                        const SizedBox(height: 14),
                        material.Divider(
                          height: 1,
                          color: oscuro
                              ? const Color(0xFF455A64)
                              : const Color(0xFFE0E0E0),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Tiempo estimado en datos',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: oscuro
                                ? const Color(0xFFECEFF1)
                                : const Color(0xFF263238),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          agg.conPresupuesto > 0
                              ? 'Suma de minutos presupuestados: '
                                  '${(agg.minutosPresupuestadosSuma / 60).toStringAsFixed(1)} h '
                                  '(${agg.conPresupuesto} misión(es) con estimación).'
                              : 'Ninguna misión del historial trae minutos estimados.',
                          style: TextStyle(
                            fontSize: 12,
                            color: oscuro
                                ? const Color(0xFFB0BEC5)
                                : const Color(0xFF546E7A),
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Card(
                child: ColoredBox(
                  color: _statsSurface(oscuro),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 16, 14, 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Misiones cerradas por mes',
                          style: theme.typography.bodyStrong?.copyWith(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Últimos 12 meses. Pasa el ratón o toca una barra para ver el número exacto.',
                          style: TextStyle(
                            fontSize: 12,
                            color: oscuro
                                ? const Color(0xFF90A4AE)
                                : const Color(0xFF607D8B),
                            height: 1.3,
                          ),
                        ),
                        const SizedBox(height: 10),
                      SizedBox(
                        height: 240,
                        child: BarChart(
                          BarChartData(
                            alignment: BarChartAlignment.spaceBetween,
                            maxY: math.max(maxY * 1.12, 1),
                            minY: 0,
                            barTouchData: BarTouchData(
                              enabled: true,
                              touchTooltipData: BarTouchTooltipData(
                                getTooltipColor: (_) => oscuro
                                    ? const Color(0xFF37474F)
                                    : const Color(0xFFECEFF1),
                                getTooltipItem: (group, gi, rod, ri) {
                                  final i = group.x.toInt();
                                  if (i < 0 ||
                                      i >= agg.mesesOrden.length) {
                                    return null;
                                  }
                                  final k = agg.mesesOrden[i];
                                  return BarTooltipItem(
                                    '${agg.cierresPorMes[k] ?? 0} cierres\n',
                                    TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: oscuro
                                          ? material.Colors.white
                                          : const Color(0xFF0D0D0D),
                                    ),
                                    children: [
                                      TextSpan(
                                        text: _etiquetaMes(k),
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
                                  reservedSize: 34,
                                  interval: maxY <= 5 ? 1 : null,
                                  getTitlesWidget: (v, m) => Text(
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
                                  reservedSize: 28,
                                  getTitlesWidget: (v, meta) {
                                    final i = v.toInt();
                                    if (i < 0 ||
                                        i >= agg.mesesOrden.length) {
                                      return const SizedBox.shrink();
                                    }
                                    final k = agg.mesesOrden[i];
                                    return Padding(
                                      padding: const EdgeInsets.only(top: 6),
                                      child: Text(
                                        _etiquetaMes(k),
                                        style: TextStyle(
                                          fontSize: 9,
                                          color: oscuro
                                              ? const Color(0xFFB0BEC5)
                                              : const Color(0xFF455A64),
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
                                  maxY <= 5 ? 1 : (maxY / 4).ceilToDouble(),
                              getDrawingHorizontalLine: (value) => FlLine(
                                color: oscuro
                                    ? const Color(0xFF455A64)
                                    : const Color(0xFFE0E0E0),
                                strokeWidth: 1,
                              ),
                            ),
                            borderData: FlBorderData(show: false),
                            barGroups: List.generate(agg.mesesOrden.length, (i) {
                              final k = agg.mesesOrden[i];
                              final n = (agg.cierresPorMes[k] ?? 0).toDouble();
                              return BarChartGroupData(
                                x: i,
                                barRods: [
                                  BarChartRodData(
                                    toY: n,
                                    color: accent,
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
                    ],
                  ),
                ),
              ),
            ),
              if (agg.topResponsables.isNotEmpty) ...[
                const SizedBox(height: 14),
                Card(
                  child: ColoredBox(
                    color: _statsSurface(oscuro),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 16, 14, 18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Quién cerró más misiones',
                            style: theme.typography.bodyStrong?.copyWith(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Pastel por conteo. Se usa quien figura como cierre; '
                            'si falta, el responsable asignado.',
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.3,
                              color: oscuro
                                  ? const Color(0xFF90A4AE)
                                  : const Color(0xFF607D8B),
                            ),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            height: 220,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Expanded(
                                  flex: 11,
                                  child: PieChart(
                                    PieChartData(
                                      sectionsSpace: 1.5,
                                      centerSpaceRadius: 46,
                                      startDegreeOffset: -90,
                                      sections: [
                                        for (var i = 0;
                                            i < agg.topResponsables.length;
                                            i++)
                                          PieChartSectionData(
                                            color: _kPiePastel[
                                                i % _kPiePastel.length],
                                            value: agg.topResponsables[i].value
                                                .toDouble(),
                                            title: '${agg.topResponsables[i].value}',
                                            radius: 58,
                                            titleStyle: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w800,
                                              color: oscuro
                                                  ? material.Colors.white
                                                  : const Color(0xFF263238),
                                              shadows: [
                                                Shadow(
                                                  color: material.Colors.black
                                                      .withValues(alpha: 0.22),
                                                  blurRadius: 2,
                                                ),
                                              ],
                                            ),
                                          ),
                                      ],
                                      pieTouchData: PieTouchData(
                                        enabled: true,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  flex: 10,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      for (var i = 0;
                                          i < agg.topResponsables.length;
                                          i++)
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(bottom: 8),
                                          child: Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                    top: 3),
                                                child: Container(
                                                  width: 10,
                                                  height: 10,
                                                  decoration: BoxDecoration(
                                                    color: _kPiePastel[
                                                        i %
                                                            _kPiePastel
                                                                .length],
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            2),
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: Text(
                                                  agg.topResponsables[i].key,
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w600,
                                                    height: 1.2,
                                                    color: oscuro
                                                        ? const Color(
                                                            0xFFEEEEEE)
                                                        : const Color(
                                                            0xFF212121),
                                                  ),
                                                ),
                                              ),
                                              Text(
                                                '${agg.topResponsables[i].value}',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w800,
                                                  color: accent,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

Color _statsSurface(bool oscuro) =>
    oscuro ? const Color(0xFF2E3238) : const Color(0xFFFFFFFF);

Widget _statsBigNumber({
  required String etiqueta,
  required String valor,
  required bool oscuro,
  required Color color,
}) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: oscuro ? const Color(0xFF252830) : const Color(0xFFF5F7FA),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: color.withValues(alpha: 0.5)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          etiqueta,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: oscuro ? const Color(0xFFB0BEC5) : const Color(0xFF607D8B),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          valor,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: color,
          ),
        ),
      ],
    ),
  );
}

Widget _statChip({
  required IconData icon,
  required String titulo,
  required String valor,
  required Color color,
  required bool oscuro,
}) {
  return Container(
    width: 124,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    decoration: BoxDecoration(
      color: _statsSurface(oscuro),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(
        color: oscuro ? const Color(0xFF546E7A) : const Color(0xFFCFD8DC),
      ),
      boxShadow: [
        BoxShadow(
          color: material.Colors.black.withValues(alpha: oscuro ? 0.25 : 0.06),
          blurRadius: 8,
          offset: const Offset(0, 2),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(height: 8),
        Text(
          titulo,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
            color: oscuro ? const Color(0xFFB0BEC5) : const Color(0xFF546E7A),
          ),
        ),
        Text(
          valor,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
            height: 1.1,
            color: oscuro ? const Color(0xFFFAFAFA) : const Color(0xFF0D0D0D),
          ),
        ),
      ],
    ),
  );
}

class _DiaDetallePanel extends StatelessWidget {
  const _DiaDetallePanel({
    required this.tareas,
    required this.onTapTarea,
    required this.fecha,
    this.onReactivarTarea,
    this.onEliminarTarea,
  });

  final List<Map<String, dynamic>> tareas;
  final void Function(Map<String, dynamic> tarea) onTapTarea;
  final DateTime? fecha;
  final Future<void> Function(Map<String, dynamic> tarea)? onReactivarTarea;
  final Future<void> Function(Map<String, dynamic> tarea)? onEliminarTarea;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final oscuro = theme.brightness == Brightness.dark;
    final colorTitulo =
        oscuro ? const Color(0xFFF5F5F5) : const Color(0xFF0D47A1);
    final colorCuerpo =
        oscuro ? const Color(0xFFE8E8E8) : const Color(0xFF212121);
    final colorMeta =
        oscuro ? const Color(0xFFB0BEC5) : const Color(0xFF546E7A);
    final titulo = fecha == null
        ? 'Seleccione un día'
        : '${fecha!.day}/${fecha!.month}/${fecha!.year}';

    final kSel = fecha != null
        ? DateTime(fecha!.year, fecha!.month, fecha!.day)
        : null;
    final sorted = List<Map<String, dynamic>>.from(tareas)
      ..sort((a, b) {
        int rank(Map<String, dynamic> t) {
          if (esCritica(t)) return 0;
          if (esPausada(t)) return 1;
          return 2;
        }

        final rc = rank(a).compareTo(rank(b));
        if (rc != 0) return rc;
        if (kSel != null) {
          bool unDia(Map<String, dynamic> t) {
            final r = rangoHistorialCalendario(t);
            return r != null && r.start == r.end && r.start == kSel;
          }

          if (unDia(a) && unDia(b)) {
            final ta = minutosDesdeMedianocheInicioCiclo(a);
            final tb = minutosDesdeMedianocheInicioCiclo(b);
            if (ta != tb) return ta.compareTo(tb);
          }
        }
        return tituloMision(a).compareTo(tituloMision(b));
      });

    return Card(
      child: ColoredBox(
        color: _statsSurface(oscuro),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: Text(
                titulo,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: colorTitulo,
                  height: 1.2,
                ),
              ),
            ),
            const Divider(),
            Expanded(
              child: sorted.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          'Sin misiones que incluyan este día en su franja (inicio → cierre).',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 14,
                            color: colorMeta,
                            height: 1.35,
                          ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                      itemCount: sorted.length,
                      itemBuilder: (context, i) {
                        final t = sorted[i];
                        final tit = tituloMision(t);
                        final desc = descripcionMision(t);
                        final r = rangoHistorialCalendario(t);
                        final rangoTxt = r == null
                            ? ''
                            : 'Franja: ${r.start.day}/${r.start.month} – ${r.end.day}/${r.end.month}';
                        final soloUnDia = r != null &&
                            kSel != null &&
                            r.start == r.end &&
                            r.start == kSel;
                        final horaIni =
                            soloUnDia ? etiquetaHoraInicioCiclo(t) : '';
                        final barColor = colorBarraBitacoraParaTarea(t);
                        final src = esManualSource(t) ? 'MANUAL' : 'RADAR';
                        final lead = etiquetaLeadTimeTarjeta(t);
                        final asignado = asignadoMision(t);
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: HoverButton(
                            onPressed: () => onTapTarea(t),
                            builder: (context, states) {
                              return material.Material(
                                color: material.Colors.transparent,
                                child: Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: oscuro
                                        ? const Color(0xFF35383E)
                                        : const Color(0xFFFFFFFF),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: barColor.withValues(alpha: 0.35),
                                    width: 1,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: material.Colors.black
                                          .withValues(alpha: oscuro ? 0.2 : 0.06),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Container(
                                          width: 38,
                                          height: 38,
                                          decoration: BoxDecoration(
                                            color: barColor.withValues(alpha: 0.2),
                                            borderRadius: BorderRadius.circular(10),
                                          ),
                                          alignment: Alignment.center,
                                          child: material.Icon(
                                            material.Icons.monitor_outlined,
                                            size: 22,
                                            color: barColor,
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Expanded(
                                                    child: Text(
                                                      tit,
                                                      maxLines: 2,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                        fontSize: 15,
                                                        fontWeight:
                                                            FontWeight.w800,
                                                        color: oscuro
                                                            ? const Color(
                                                                0xFFF5F5F5)
                                                            : const Color(
                                                                0xFF0D0D0D),
                                                      ),
                                                    ),
                                                  ),
                                                  if (esCritica(t)) ...[
                                                    const SizedBox(width: 6),
                                                    Container(
                                                      width: 8,
                                                      height: 8,
                                                      margin:
                                                          const EdgeInsets.only(
                                                              top: 5),
                                                      decoration:
                                                          const BoxDecoration(
                                                        color: Color(0xFFD32F2F),
                                                        shape: BoxShape.circle,
                                                      ),
                                                    ),
                                                  ],
                                                  const SizedBox(width: 6),
                                                  Container(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                            horizontal: 8,
                                                            vertical: 3),
                                                    decoration: BoxDecoration(
                                                      color: oscuro
                                                          ? const Color(
                                                              0xFF4A148C)
                                                          : const Color(
                                                              0xFFEDE7F6),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                              20),
                                                    ),
                                                    child: Text(
                                                      src,
                                                      style: TextStyle(
                                                        fontSize: 10,
                                                        fontWeight:
                                                            FontWeight.w800,
                                                        color: oscuro
                                                            ? const Color(
                                                                0xFFB39DDB)
                                                            : const Color(
                                                                0xFF5E35B1),
                                                        letterSpacing: 0.4,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 6),
                                              Text(
                                                [
                                                  if (rangoTxt.isNotEmpty)
                                                    rangoTxt,
                                                  if (horaIni.isNotEmpty)
                                                    'Inicio: $horaIni',
                                                  asignado,
                                                ].where((s) => s.isNotEmpty).join(' · '),
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  color: colorMeta,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                              if (lead.isNotEmpty) ...[
                                                const SizedBox(height: 4),
                                                Text(
                                                  lead,
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w700,
                                                    color: theme.accentColor,
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                    if (desc.isNotEmpty) ...[
                                      const SizedBox(height: 10),
                                      Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.all(10),
                                        decoration: BoxDecoration(
                                          color: oscuro
                                              ? const Color(0xFF1E1E22)
                                              : const Color(0xFFECEFF1),
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        child: Text(
                                          desc,
                                          maxLines: 4,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 13,
                                            height: 1.35,
                                            color: colorCuerpo,
                                          ),
                                        ),
                                      ),
                                    ],
                                    if (onReactivarTarea != null || onEliminarTarea != null) ...[
                                      const SizedBox(height: 10),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: [
                                          if (onReactivarTarea != null)
                                            Button(
                                              onPressed: () => onReactivarTarea!(t),
                                              child: const Text('Reactivar'),
                                            ),
                                          if (onEliminarTarea != null)
                                            FilledButton(
                                              style: ButtonStyle(
                                                backgroundColor: WidgetStateProperty.all(
                                                  const Color(0xFFB71C1C),
                                                ),
                                              ),
                                              onPressed: () => onEliminarTarea!(t),
                                              child: const Text('Eliminar'),
                                            ),
                                        ],
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      );
                    },
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
