import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as material;
import 'package:table_calendar/table_calendar.dart';

import '../screens/monitoreo/widgets/task_display_utils.dart';
import '../services/monitoreo_reporte_pdf.dart';
import '../theme/app_themes.dart';

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
    Color(0xFF00897B),
    Color(0xFF6A1B9A),
    Color(0xFFC62828),
    Color(0xFFE65100),
    Color(0xFF2E7D32),
    Color(0xFFAD1457),
    Color(0xFF00695C),
    Color(0xFF3949AB),
    Color(0xFF0277BD),
    Color(0xFF7B1FA2),
    Color(0xFF5D4037),
    Color(0xFF558B2F),
    Color(0xFFD84315),
    Color(0xFF00838F),
    Color(0xFF4527A0),
    Color(0xFFBF360C),
    Color(0xFF33691E),
    Color(0xFF880E4F),
    Color(0xFF37474F),
  ];
  var hash = 0;
  for (final c in user.codeUnits) {
    hash = (hash * 31 + c) & 0xFFFFFFFF;
  }
  return palette[hash.abs() % palette.length];
}

Color _colorPorTituloBitacora(String raw, {required bool oscuro}) {
  final seed = raw.trim().isEmpty ? '?' : raw.trim();
  var h = 1;
  for (final c in seed.codeUnits) {
    h = (h * 31 + c) & 0x7FFFFFFF;
  }
  final hue = (h % 360).toDouble();
  return material.HSVColor.fromAHSV(
    1,
    hue,
    oscuro ? 0.55 : 0.62,
    oscuro ? 0.58 : 0.82,
  ).toColor();
}

/// Color de indicador / tarjeta por misión (calendario y panel del día).
Color colorBarraBitacoraParaTarea(
  Map<String, dynamic> t, {
  required bool oscuro,
}) {
  if (esCancelada(t)) {
    return oscuro ? const Color(0xFF8D6E63) : const Color(0xFFBCAAA4);
  }
  final users = _usuariosAsignadosBitacora(t);
  final titulo = tituloMision(t);
  if (users.isEmpty ||
      (users.length == 1 &&
          (users.first == 'Sin asignar' || users.first.trim().isEmpty))) {
    return _colorPorTituloBitacora(titulo, oscuro: oscuro);
  }
  if (users.length > 1) {
    return _colorPorTituloBitacora(
      '${users.join("|")}|$titulo',
      oscuro: oscuro,
    );
  }
  final base = _colorUsuarioBitacora(users.first);
  final tint = _colorPorTituloBitacora(
    '${users.first}|$titulo',
    oscuro: oscuro,
  );
  return Color.lerp(base, tint, 0.42) ?? base;
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
    this.generadoPor = '',
    this.rolGeneradoPor = '',
  });

  final List<Map<String, dynamic>> tareasHistorial;
  final List<Map<String, dynamic>> tareasActivasParaProyeccion;
  final void Function(Map<String, dynamic> tarea) onTapTarea;
  final Future<void> Function(Map<String, dynamic> tarea)? onReactivarTarea;
  final Future<void> Function(Map<String, dynamic> tarea)? onEliminarTarea;

  /// Usuario que aparece como autor en el PDF de informe mensual.
  final String generadoPor;

  /// Rol efectivo al momento de generar el informe PDF.
  final String rolGeneradoPor;

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
              generadoPor: widget.generadoPor,
              rolGeneradoPor: widget.rolGeneradoPor,
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
  final fill = colorBarraBitacoraParaTarea(t, oscuro: oscuro);
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

/// Colores vivos para pastel / leyendas (quién cerró).
const List<Color> _kPiePastel = <Color>[
  Color(0xFF42A5F5),
  Color(0xFF66BB6A),
  Color(0xFFAB47BC),
  Color(0xFFFF7043),
  Color(0xFF26C6DA),
  Color(0xFFFFCA28),
  Color(0xFF5C6BC0),
  Color(0xFF8D6E63),
  Color(0xFFEC407A),
  Color(0xFF29B6F6),
  Color(0xFF7CB342),
  Color(0xFFFFA726),
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

/// Misiones en lista activas sin cierre, contadas por asignado principal.
List<MapEntry<String, int>> _conteoActivasPendientesPorUsuario(
  List<Map<String, dynamic>> activas,
) {
  final byUser = <String, int>{};
  for (final t in activas) {
    if (fechaCierreHistorialDate(t) != null) continue;
    final u = asignadoMision(t).trim();
    if (u.isEmpty || u == 'Sin asignar') continue;
    byUser[u] = (byUser[u] ?? 0) + 1;
  }
  final out = byUser.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  return out;
}

Color? _colorDesdeHexUsuario(String? raw) {
  if (raw == null) return null;
  var s = raw.trim();
  if (s.isEmpty || s == 'null') return null;
  if (!s.startsWith('#')) s = '#$s';
  return UserColorPalette.getColorByHex(s) ?? _colorArgbHex6(s);
}

Color? _colorArgbHex6(String hexWithHash) {
  final clean = hexWithHash.replaceFirst('#', '').trim().toUpperCase();
  if (!RegExp(r'^[0-9A-F]{6}$').hasMatch(clean)) return null;
  final v = int.tryParse(clean, radix: 16);
  if (v == null) return null;
  return Color(0xFF000000 | v);
}

/// Colores configurados en Tbl_Usuarios (viene en payload de tareas).
Map<String, Color> _mapaColoresUsuarioDesdeTareas(
  List<Map<String, dynamic>> historial,
  List<Map<String, dynamic>> activas,
) {
  final out = <String, Color>{};
  void absorb(Map<String, dynamic> t) {
    final uc = t['usuarios_colores'];
    if (uc is Map) {
      for (final e in uc.entries) {
        final n = '${e.key}'.trim();
        if (n.isEmpty) continue;
        final c = _colorDesdeHexUsuario('${e.value}');
        if (c != null) out[n.toLowerCase()] = c;
      }
    }
    final asig = asignadoMision(t).trim();
    if (asig.isNotEmpty && asig != 'Sin asignar') {
      final c = _colorDesdeHexUsuario('${t['usuario_color_hex']}');
      if (c != null) out[asig.toLowerCase()] = c;
    }
  }
  for (final t in historial) absorb(t);
  for (final t in activas) absorb(t);
  return out;
}

Color _colorBarraUsuarioPreferente(
  String nombre,
  Map<String, Color> porUsuario,
  int indiceFallback,
) {
  final c = porUsuario[nombre.trim().toLowerCase()];
  if (c != null) return c;
  return _kPiePastel[indiceFallback % _kPiePastel.length];
}

bool _finEstimadoLaboralDentroDeMes(
  Map<String, dynamic> t,
  DateTime mesPrimerDia,
) {
  final rem = minutosRestantesEstimados(t);
  if (rem == null || rem <= 0) return false;
  final fin = finLaboralDesde(DateTime.now(), rem);
  if (fin == null) return false;
  final inicio = DateTime(mesPrimerDia.year, mesPrimerDia.month, 1);
  final finEx = DateTime(mesPrimerDia.year, mesPrimerDia.month + 1, 1);
  return !fin.isBefore(inicio) && fin.isBefore(finEx);
}

/// Activas sin cierre que entran al donut "Estado del mes": sin estimacion
/// o con fin laboral estimado dentro del mes seleccionado.
bool _activaCuentaPendienteEstadoMes(
  Map<String, dynamic> t,
  DateTime mesPrimerDia,
) {
  if (fechaCierreHistorialDate(t) != null) return false;
  if (manualSinTiempoEstimado(t)) return true;
  final rem = minutosRestantesEstimados(t);
  if (rem == null || rem <= 0) return true;
  return _finEstimadoLaboralDentroDeMes(t, mesPrimerDia);
}

int _pendientesEstadoMesCount(
  List<Map<String, dynamic>> activas,
  DateTime mesPrimerDia,
) {
  var n = 0;
  for (final t in activas) {
    if (_activaCuentaPendienteEstadoMes(t, mesPrimerDia)) n++;
  }
  return n;
}

Map<String, ({int ok, int pend})> _completadasVsFaltantesPorUsuario(
  _MesAgg mesAgg,
  List<Map<String, dynamic>> activas,
) {
  final mesRef = mesAgg.mes;
  final m = <String, ({int ok, int pend})>{};
  for (final r in mesAgg.filasResp) {
    m[r.usuario] = (ok: r.cerradas, pend: 0);
  }
  for (final t in activas) {
    if (!_activaCuentaPendienteEstadoMes(t, mesRef)) continue;
    final u = asignadoMision(t).trim();
    if (u.isEmpty || u == 'Sin asignar') continue;
    final cur = m[u] ?? (ok: 0, pend: 0);
    m[u] = (ok: cur.ok, pend: cur.pend + 1);
  }
  return m;
}

int? _idTareaBitacora(Map<String, dynamic> t) {
  final v = t['id_tarea'];
  if (v is int) return v;
  return int.tryParse('$v');
}

/// Lista PDF: pendientes por usuario; mision con varios responsables una sola vez
/// (bajo [asignadoMision] principal), linea con todos los nombres.
List<MonitoreoInformePendientesUsuario> _listaPendientesPdfPorUsuario(
  List<Map<String, dynamic>> activas,
) {
  final placedIds = <int>{};
  final porUsuario = <String, List<String>>{};

  for (final t in activas) {
    if (fechaCierreHistorialDate(t) != null) continue;
    final id = _idTareaBitacora(t);
    if (id == null) continue;
    if (placedIds.contains(id)) continue;

    final tit = tituloMision(t).trim();
    if (tit.isEmpty || tit == 'Mision sin titulo') continue;

    final asigs = responsablesTareaParaMatch(t);
    if (asigs.isEmpty) continue;

    final canon = List<String>.from(asigs)
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final prim = asignadoMision(t).trim();

    final owner = canon.length == 1
        ? canon.first
        : canon.firstWhere(
            (x) => prim.isNotEmpty && x.toLowerCase() == prim.toLowerCase(),
            orElse: () => canon.first,
          );

    final linea = canon.length <= 1
        ? tit
        : '$tit (Responsables: ${canon.join(', ')})';

    placedIds.add(id);
    porUsuario.putIfAbsent(owner, () => <String>[]).add(linea);
  }

  for (final list in porUsuario.values) {
    list.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  final keys = porUsuario.keys.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

  return [
    for (final k in keys)
      MonitoreoInformePendientesUsuario(
        usuario: k,
        lineas: List<String>.from(porUsuario[k]!),
      ),
  ];
}

class _BitacoraEstadisticasPanelStateful extends StatefulWidget {
  const _BitacoraEstadisticasPanelStateful({
    required this.tareas,
    this.tareasActivas = const [],
    this.generadoPor = '',
    this.rolGeneradoPor = '',
  });

  final List<Map<String, dynamic>> tareas;
  final List<Map<String, dynamic>> tareasActivas;
  final String generadoPor;
  final String rolGeneradoPor;

  @override
  State<_BitacoraEstadisticasPanelStateful> createState() =>
      _BitacoraEstadisticasPanelStatefulState();
}

/// Agregado mensual: cifras solo del mes seleccionado (para informes).
class _MesAgg {
  const _MesAgg({
    required this.mes,
    required this.creadas,
    required this.cerradas,
    required this.canceladas,
    required this.terminadas,
    required this.activasFinMes,
    required this.manualCerradas,
    required this.radarCerradas,
    required this.leadHorasProm,
    required this.muestrasLeadTime,
    required this.cerradasPorDia,
    required this.creadasPorDia,
    required this.cerradasPorDiaSemana,
    required this.topRespMes,
    required this.filasResp,
    required this.misionesCerradasPorUsuario,
  });

  final DateTime mes; // primer día del mes (local).
  final int creadas;
  final int cerradas;
  final int canceladas;
  final int terminadas;
  final int activasFinMes;
  final int manualCerradas;
  final int radarCerradas;
  final double? leadHorasProm;
  final int muestrasLeadTime;
  final Map<int, int> cerradasPorDia;
  final Map<int, int> creadasPorDia;
  final Map<int, int> cerradasPorDiaSemana; // 1..7 (lun..dom)
  final List<MapEntry<String, int>> topRespMes;
  final List<MonitoreoInformeFilaResponsable> filasResp;

  /// Misiones no canceladas cerradas en el mes, por quien figura en el cierre.
  final Map<String, List<String>> misionesCerradasPorUsuario;

  int get diasMes => DateTime(mes.year, mes.month + 1, 0).day;

  int get cerradasYterminadas => terminadas;

  double get tasaCumplimiento {
    final universo = terminadas + canceladas;
    if (universo <= 0) return 0;
    return (terminadas / universo) * 100.0;
  }
}

_MesAgg _calcularMesAgg(
  List<Map<String, dynamic>> historial,
  List<Map<String, dynamic>> activas,
  DateTime mesRef,
) {
  final inicio = DateTime(mesRef.year, mesRef.month, 1);
  final finExclusivo = DateTime(mesRef.year, mesRef.month + 1, 1);
  bool dentro(DateTime d) =>
      !d.isBefore(inicio) && d.isBefore(finExclusivo);

  final cerradasPorDia = <int, int>{};
  final creadasPorDia = <int, int>{};
  final cerradasPorDiaSemana = <int, int>{};
  final leads = <int>[]; // minutos
  final respCount = <String, int>{};
  final respLead = <String, List<int>>{};
  final respCerradasPorUser = <String, int>{};
  final respCreadasPorUser = <String, int>{};
  final respCanceladasPorUser = <String, int>{};
  final misionesPorUser = <String, List<String>>{};

  var creadas = 0;
  var cerradas = 0;
  var canceladas = 0;
  var manualCer = 0;
  var radarCer = 0;
  var activasFinMes = 0;

  for (final t in historial) {
    final ini = fechaInicioHistorialDate(t);
    final fin = fechaCierreHistorialDate(t);
    final asig = asignadoMision(t);
    final uCierre = usuarioCompletoHistorialLegible(t);
    final userKey = (uCierre.isNotEmpty ? uCierre : asig).trim();

    if (ini != null && dentro(ini)) {
      creadas++;
      creadasPorDia[ini.day] = (creadasPorDia[ini.day] ?? 0) + 1;
      if (userKey.isNotEmpty && userKey != 'Sin asignar') {
        respCreadasPorUser[userKey] =
            (respCreadasPorUser[userKey] ?? 0) + 1;
      }
    }
    if (fin != null && dentro(fin)) {
      cerradas++;
      cerradasPorDia[fin.day] = (cerradasPorDia[fin.day] ?? 0) + 1;
      cerradasPorDiaSemana[fin.weekday] =
          (cerradasPorDiaSemana[fin.weekday] ?? 0) + 1;
      if (esCancelada(t)) {
        canceladas++;
        if (userKey.isNotEmpty && userKey != 'Sin asignar') {
          respCanceladasPorUser[userKey] =
              (respCanceladasPorUser[userKey] ?? 0) + 1;
        }
      } else {
        if (esManualSource(t)) {
          manualCer++;
        } else {
          radarCer++;
        }
        if (userKey.isNotEmpty && userKey != 'Sin asignar') {
          respCount[userKey] = (respCount[userKey] ?? 0) + 1;
          respCerradasPorUser[userKey] =
              (respCerradasPorUser[userKey] ?? 0) + 1;
          final tit = tituloMision(t).trim();
          if (tit.isNotEmpty && tit != 'Mision sin titulo') {
            final L = misionesPorUser.putIfAbsent(userKey, () => []);
            if (!L.contains(tit) && L.length < 120) {
              L.add(tit);
            }
          }
        }
        if (ini != null && !fin.isBefore(ini)) {
          final min = fin.difference(ini).inMinutes;
          leads.add(min);
          if (userKey.isNotEmpty && userKey != 'Sin asignar') {
            (respLead[userKey] ??= <int>[]).add(min);
          }
        }
      }
    }
  }

  // Activas al cierre del mes: iniciadas en o antes del último segundo del mes,
  // sin cierre registrado o con cierre posterior al cierre del mes.
  final ultimoDiaMes = DateTime(mesRef.year, mesRef.month + 1, 0, 23, 59, 59);
  final activasFinPorUser = <String, int>{};
  for (final t in [...historial, ...activas]) {
    final ini = fechaInicioHistorialDate(t);
    if (ini == null) continue;
    if (ini.isAfter(ultimoDiaMes)) continue;
    final fin = fechaCierreHistorialDate(t);
    if (fin == null || fin.isAfter(ultimoDiaMes)) {
      activasFinMes++;
      final asig = asignadoMision(t).trim();
      if (asig.isNotEmpty && asig != 'Sin asignar') {
        activasFinPorUser[asig] = (activasFinPorUser[asig] ?? 0) + 1;
      }
    }
  }

  final minutosPendientesActivasPorUser = <String, int>{};
  for (final t in activas) {
    if (fechaCierreHistorialDate(t) != null) continue;
    final asig = asignadoMision(t).trim();
    if (asig.isEmpty || asig == 'Sin asignar') continue;
    final rem = minutosRestantesEstimados(t);
    if (rem != null && rem > 0) {
      minutosPendientesActivasPorUser[asig] =
          (minutosPendientesActivasPorUser[asig] ?? 0) + rem;
    }
  }

  double? prom;
  if (leads.isNotEmpty) {
    prom = leads.reduce((a, b) => a + b) / leads.length / 60.0;
  }

  final top = respCount.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  // Filas para tabla PDF: todos los responsables con al menos 1 evento en el mes
  final todosUsers = <String>{};
  todosUsers.addAll(respCerradasPorUser.keys);
  todosUsers.addAll(respCreadasPorUser.keys);
  todosUsers.addAll(respCanceladasPorUser.keys);
  todosUsers.addAll(activasFinPorUser.keys);
  todosUsers.addAll(minutosPendientesActivasPorUser.keys);
  final filas = todosUsers.map((u) {
    final leadU = respLead[u] ?? const <int>[];
    double promU = double.nan;
    if (leadU.isNotEmpty) {
      promU = leadU.reduce((a, b) => a + b) / leadU.length / 60.0;
    }
    final minPend = minutosPendientesActivasPorUser[u] ?? 0;
    final finLab = minPend > 0
        ? (estimadoFinLaboralDesdeAhoraEtiqueta(minPend) ?? '-')
        : '-';
    return MonitoreoInformeFilaResponsable(
      usuario: u,
      creadas: respCreadasPorUser[u] ?? 0,
      cerradas: respCerradasPorUser[u] ?? 0,
      canceladas: respCanceladasPorUser[u] ?? 0,
      activasFinMes: activasFinPorUser[u] ?? 0,
      leadTimeHorasProm: promU,
      misionesCerradasMes: List<String>.from(misionesPorUser[u] ?? const []),
      finEstimadoLaboral: finLab,
    );
  }).toList()
    ..sort((a, b) => b.cerradas.compareTo(a.cerradas));

  return _MesAgg(
    mes: inicio,
    creadas: creadas,
    cerradas: cerradas,
    canceladas: canceladas,
    terminadas: cerradas - canceladas,
    activasFinMes: activasFinMes,
    manualCerradas: manualCer,
    radarCerradas: radarCer,
    leadHorasProm: prom,
    muestrasLeadTime: leads.length,
    cerradasPorDia: cerradasPorDia,
    creadasPorDia: creadasPorDia,
    cerradasPorDiaSemana: cerradasPorDiaSemana,
    topRespMes: top.take(8).toList(),
    filasResp: filas,
    misionesCerradasPorUsuario: misionesPorUser,
  );
}

const List<String> _kNombresMes = [
  '',
  'Enero',
  'Febrero',
  'Marzo',
  'Abril',
  'Mayo',
  'Junio',
  'Julio',
  'Agosto',
  'Septiembre',
  'Octubre',
  'Noviembre',
  'Diciembre',
];

const List<String> _kDiasSemanaCortos = [
  '',
  'Lun',
  'Mar',
  'Mié',
  'Jue',
  'Vie',
  'Sáb',
  'Dom',
];

List<DateTime> _construirMesesDisponibles(
  List<Map<String, dynamic>> historial,
) {
  final set = <String>{};
  final res = <DateTime>[];
  void add(DateTime d) {
    final k =
        '${d.year}-${d.month.toString().padLeft(2, '0')}';
    if (set.add(k)) {
      res.add(DateTime(d.year, d.month, 1));
    }
  }

  final ahora = DateTime.now();
  add(DateTime(ahora.year, ahora.month, 1));
  for (final t in historial) {
    final fi = fechaInicioHistorialDate(t);
    if (fi != null) add(fi);
    final fc = fechaCierreHistorialDate(t);
    if (fc != null) add(fc);
  }
  // Garantizar los 6 meses anteriores visibles aun sin datos
  for (var i = 1; i <= 6; i++) {
    final d = DateTime(ahora.year, ahora.month - i, 1);
    add(d);
  }
  res.sort((a, b) => b.compareTo(a));
  return res;
}

class _BitacoraEstadisticasPanelStatefulState
    extends State<_BitacoraEstadisticasPanelStateful> {
  final material.ScrollController _statsScroll = material.ScrollController();

  late DateTime _mesSeleccionado;
  bool _exportando = false;

  final GlobalKey _keyKpis = GlobalKey();
  final GlobalKey _keyChartCreadasVsCerradas = GlobalKey();
  final GlobalKey _keyChartEstadoMes = GlobalKey();
  final GlobalKey _keyChartRespMes = GlobalKey();
  final GlobalKey _keyChartDiaSemana = GlobalKey();
  final GlobalKey _keyChartAcumulado = GlobalKey();
  final GlobalKey _keyChart12Meses = GlobalKey();
  final GlobalKey _keyChartResponsablesAnual = GlobalKey();
  final GlobalKey _keyChartActivasPendientes = GlobalKey();
  final GlobalKey _keyChartMinutosRestantesActivas = GlobalKey();
  final GlobalKey _keyChartMiniPiesUsuario = GlobalKey();

  @override
  void initState() {
    super.initState();
    final ahora = DateTime.now();
    _mesSeleccionado = DateTime(ahora.year, ahora.month, 1);
  }

  @override
  void dispose() {
    _statsScroll.dispose();
    super.dispose();
  }

  String _etiquetaMesLargo(DateTime d) =>
      '${_kNombresMes[d.month]} ${d.year}';

  Future<void> _exportarPdf(_MesAgg mes, _BitacoraAgg agg) async {
    if (_exportando) return;
    setState(() => _exportando = true);
    try {
      final hist = widget.tareas;
      final histConCierre =
          hist.where((t) => fechaCierreHistorialDate(t) != null).length;
      final graficas = <MonitoreoInformeGrafica>[];
      Future<void> agregar(
        GlobalKey key,
        String titulo,
        String descripcion,
      ) async {
        final png = await capturaRepaintBoundaryPng(key);
        if (png != null) {
          graficas.add(
            MonitoreoInformeGrafica(
              titulo: titulo,
              descripcion: descripcion,
              imagenPng: png,
            ),
          );
        }
      }

      await agregar(
        _keyChartCreadasVsCerradas,
        'Creadas vs cerradas por día (${_etiquetaMesLargo(mes.mes)})',
        'Compara cuántas misiones nacieron y cuántas se cerraron cada día del mes.',
      );
      await agregar(
        _keyChartAcumulado,
        'Cierres acumulados del mes',
        'Curva acumulada de misiones cerradas dentro del mes seleccionado.',
      );
      await agregar(
        _keyChartEstadoMes,
        'Distribución por estado (mes)',
        'Terminadas, canceladas y pendientes (activas sin cierre con fin estimado en el mes o sin estimacion).',
      );
      await agregar(
        _keyChartDiaSemana,
        'Cierres por día de la semana (mes)',
        'En qué días suele haber más cierres.',
      );
      await agregar(
        _keyChartRespMes,
        'Top responsables del mes',
        'Quién cerró más misiones durante el mes seleccionado.',
      );
      await agregar(
        _keyChartActivasPendientes,
        'Misiones activas pendientes por responsable',
        'Conteo en el panel de activas (sin cierre), por asignado.',
      );
      await agregar(
        _keyChartMinutosRestantesActivas,
        'Tiempo estimado restante por responsable (activas)',
        'Suma de minutos pendientes según progreso y presupuesto; orden por carga.',
      );
      await agregar(
        _keyChartMiniPiesUsuario,
        'Cerradas en el mes vs pendientes (activas filtradas)',
        'Mini pastel por responsable: cierres no cancelados del mes frente a pendientes con fin en el mes o sin estimacion.',
      );
      await agregar(
        _keyChart12Meses,
        'Cierres mensuales - últimos 12 meses',
        'Tendencia anual de cierres para contexto.',
      );
      await agregar(
        _keyChartResponsablesAnual,
        'Top responsables - histórico (12 meses)',
        'Acumulado histórico visible en la bitácora.',
      );

      final kpis = <({String titulo, String valor, String? pie})>[
        (
          titulo: 'Historial (cargado)',
          valor: '${hist.length}',
          pie: 'Misiones en esta vista',
        ),
        (
          titulo: 'Con cierre (datos)',
          valor: '$histConCierre',
          pie: 'Todo el tiempo en lista',
        ),
        (
          titulo: 'Misiones cerradas',
          valor: '${mes.cerradas}',
          pie: mes.creadas > 0 ? 'Creadas: ${mes.creadas}' : null,
        ),
        (
          titulo: 'Terminadas',
          valor: '${mes.terminadas}',
          pie: mes.terminadas > 0
              ? '${mes.tasaCumplimiento.toStringAsFixed(0)} % cumplimiento'
              : null,
        ),
        (
          titulo: 'Canceladas',
          valor: '${mes.canceladas}',
          pie: mes.canceladas > 0 ? 'Revisar causas' : 'Sin cancelaciones',
        ),
        (
          titulo: 'Lead time promedio',
          valor: mes.leadHorasProm != null
              ? _fmtHoras(mes.leadHorasProm!)
              : 's/d',
          pie: mes.muestrasLeadTime > 0
              ? 'Sobre ${mes.muestrasLeadTime} misión(es)'
              : null,
        ),
        (
          titulo: 'Manual',
          valor: '${mes.manualCerradas}',
          pie: null,
        ),
        (
          titulo: 'Radar',
          valor: '${mes.radarCerradas}',
          pie: null,
        ),
      ];

      final resumen = <String>[];
      resumen.add(
        'Contexto: ${hist.length} mision(es) en el historial cargado; '
        '$histConCierre con fecha de cierre. En ${_etiquetaMesLargo(mes.mes).toLowerCase()}: '
        '${mes.cerradas} cierre(s) registrados.',
      );
      resumen.add(
        'Durante ${_etiquetaMesLargo(mes.mes).toLowerCase()} se cerraron ${mes.cerradas} misión(es): '
        '${mes.terminadas} terminada(s) y ${mes.canceladas} cancelada(s).',
      );
      if (mes.creadas > 0) {
        resumen.add(
          'Se iniciaron ${mes.creadas} misión(es) nueva(s) dentro del mes.',
        );
      }
      if (mes.leadHorasProm != null) {
        resumen.add(
          'Tiempo promedio desde inicio del ciclo hasta cierre: '
          '${_fmtHoras(mes.leadHorasProm!)} (sobre ${mes.muestrasLeadTime} caso/s).',
        );
      }
      if (mes.topRespMes.isNotEmpty) {
        final top = mes.topRespMes.first;
        resumen.add(
          'Responsable con más cierres del mes: ${top.key} (${top.value}).',
        );
      }
      final nActPend = widget.tareasActivas
          .where((t) => fechaCierreHistorialDate(t) == null)
          .length;
      if (nActPend > 0) {
        resumen.add(
          'En el panel de activas hay $nActPend mision(es) sin cierre; '
          'las graficas y la columna "Fin est. laboral" usan tiempo estimado cuando existe.',
        );
      }
      if (agg.leadHorasMediana != null) {
        resumen.add(
          'Referencia histórica: mediana de lead time ${_fmtHoras(agg.leadHorasMediana!)} '
          'sobre ${agg.muestrasLeadTime} misión(es) acumuladas.',
        );
      }

      final payload = MonitoreoInformeMensualPayload(
        mes: mes.mes,
        generadoPor: widget.generadoPor.isEmpty ? 'Sistema' : widget.generadoPor,
        rolGeneradoPor: widget.rolGeneradoPor,
        kpis: kpis,
        responsables: mes.filasResp,
        resumenTextual: resumen,
        graficas: graficas,
        historialTotalMisiones: hist.length,
        historialCerradasConFecha: histConCierre,
        pendientesLista: _listaPendientesPdfPorUsuario(widget.tareasActivas),
      );

      final ruta = await generarInformeMensualMonitoreoPdf(payload);
      if (!mounted) return;
      if (ruta == null) {
        await displayInfoBar(
          context,
          builder: (ctx, close) => InfoBar(
            title: const Text('No se pudo generar el PDF'),
            severity: InfoBarSeverity.error,
            onClose: close,
          ),
        );
      } else {
        await displayInfoBar(
          context,
          builder: (ctx, close) => InfoBar(
            title: const Text('Informe PDF listo'),
            content: Text('Guardado en: $ruta'),
            severity: InfoBarSeverity.success,
            onClose: close,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      await displayInfoBar(
        context,
        builder: (ctx, close) => InfoBar(
          title: const Text('Error al exportar'),
          content: Text('$e'),
          severity: InfoBarSeverity.error,
          onClose: close,
        ),
      );
    } finally {
      if (mounted) setState(() => _exportando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tareas = widget.tareas;
    final theme = FluentTheme.of(context);
    final oscuro = theme.brightness == Brightness.dark;
    final agg = _calcularAgg(tareas);
    final cargaActiva = _cargaActivaPorUsuario(widget.tareasActivas);
    final mesesDisponibles = _construirMesesDisponibles(tareas);

    if (mesesDisponibles.isNotEmpty &&
        !mesesDisponibles.any((d) =>
            d.year == _mesSeleccionado.year &&
            d.month == _mesSeleccionado.month)) {
      _mesSeleccionado = mesesDisponibles.first;
    }
    final mesAgg = _calcularMesAgg(
      widget.tareas,
      widget.tareasActivas,
      _mesSeleccionado,
    );

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
    final colorPorUsuario =
        _mapaColoresUsuarioDesdeTareas(tareas, widget.tareasActivas);

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
              _buildEncabezadoInforme(
                context: context,
                theme: theme,
                oscuro: oscuro,
                accent: accent,
                mesesDisponibles: mesesDisponibles,
                mesAgg: mesAgg,
                agg: agg,
                historialTotal: tareas.length,
                historialConCierre: tareas
                    .where((t) => fechaCierreHistorialDate(t) != null)
                    .length,
              ),
              const SizedBox(height: 16),
              RepaintBoundary(
                key: _keyKpis,
                child: _buildKpiGrid(
                  context: context,
                  theme: theme,
                  oscuro: oscuro,
                  accent: accent,
                  mesAgg: mesAgg,
                ),
              ),
              const SizedBox(height: 18),
              _buildTituloSeccion(
                oscuro: oscuro,
                titulo: 'Vista del mes · ${_etiquetaMesLargo(mesAgg.mes)}',
                subtitulo:
                    'Gráficas pensadas para un informe mensual. '
                    'Se incluyen en el PDF de exportación.',
              ),
              const SizedBox(height: 10),
              RepaintBoundary(
                key: _keyChartCreadasVsCerradas,
                child: _buildChartCreadasVsCerradas(
                  theme: theme,
                  oscuro: oscuro,
                  accent: accent,
                  mesAgg: mesAgg,
                ),
              ),
              const SizedBox(height: 14),
              RepaintBoundary(
                key: _keyChartAcumulado,
                child: _buildChartAcumulado(
                  theme: theme,
                  oscuro: oscuro,
                  accent: accent,
                  mesAgg: mesAgg,
                ),
              ),
              const SizedBox(height: 14),
              LayoutBuilder(
                builder: (context, c) {
                  final narrow = c.maxWidth < 760;
                  final a = RepaintBoundary(
                    key: _keyChartEstadoMes,
                    child: _buildPieEstadoMes(
                      theme: theme,
                      oscuro: oscuro,
                      mesAgg: mesAgg,
                      activas: widget.tareasActivas,
                    ),
                  );
                  final b = RepaintBoundary(
                    key: _keyChartDiaSemana,
                    child: _buildChartDiaSemana(
                      theme: theme,
                      oscuro: oscuro,
                      accent: accent,
                      mesAgg: mesAgg,
                    ),
                  );
                  if (narrow) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        a,
                        const SizedBox(height: 14),
                        b,
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: a),
                      const SizedBox(width: 14),
                      Expanded(child: b),
                    ],
                  );
                },
              ),
              const SizedBox(height: 14),
              RepaintBoundary(
                key: _keyChartRespMes,
                child: _buildChartResponsablesMes(
                  theme: theme,
                  oscuro: oscuro,
                  accent: accent,
                  mesAgg: mesAgg,
                  colorPorUsuario: colorPorUsuario,
                ),
              ),
              const SizedBox(height: 14),
              _buildTituloSeccion(
                oscuro: oscuro,
                titulo: 'Activas pendientes (panel actual)',
                subtitulo:
                    'Solo misiones en la lista de activas sin cierre. '
                    'Se exportan al PDF junto al resumen del mes.',
              ),
              const SizedBox(height: 10),
              RepaintBoundary(
                key: _keyChartActivasPendientes,
                child: _buildChartActivasPendientesPorUsuario(
                  theme: theme,
                  oscuro: oscuro,
                  accent: accent,
                  activas: widget.tareasActivas,
                  colorPorUsuario: colorPorUsuario,
                ),
              ),
              const SizedBox(height: 14),
              RepaintBoundary(
                key: _keyChartMinutosRestantesActivas,
                child: _buildChartMinutosRestantesActivas(
                  theme: theme,
                  oscuro: oscuro,
                  accent: accent,
                  activas: widget.tareasActivas,
                  colorPorUsuario: colorPorUsuario,
                ),
              ),
              const SizedBox(height: 14),
              RepaintBoundary(
                key: _keyChartMiniPiesUsuario,
                child: _buildWrapMiniPiesUsuario(
                  theme: theme,
                  oscuro: oscuro,
                  accent: accent,
                  mesAgg: mesAgg,
                  activas: widget.tareasActivas,
                  colorPorUsuario: colorPorUsuario,
                ),
              ),
              const SizedBox(height: 12),
              _buildListaMisionesCerradasMes(
                theme: theme,
                oscuro: oscuro,
                mesAgg: mesAgg,
              ),
              const SizedBox(height: 18),
              _buildTituloSeccion(
                oscuro: oscuro,
                titulo: 'Contexto histórico (12 meses)',
                subtitulo:
                    'Tendencia global más allá del mes seleccionado; útil para comparar.',
              ),
              const SizedBox(height: 10),
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
              RepaintBoundary(
                key: _keyChart12Meses,
                child: Card(
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
              ),
              if (agg.topResponsables.isNotEmpty) ...[
                const SizedBox(height: 14),
                RepaintBoundary(
                  key: _keyChartResponsablesAnual,
                  child: Card(
                  child: ColoredBox(
                    color: _statsSurface(oscuro),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 16, 14, 18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Cierres por responsable (12 meses)',
                            style: theme.typography.bodyStrong?.copyWith(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Builder(
                            builder: (ctx) {
                              final totalPie = agg.topResponsables.fold<int>(
                                0,
                                (a, e) => a + e.value,
                              );
                              return Text(
                                'Donut con porcentajes y leyenda con totales. '
                                'Suma de cierres en el grafico: $totalPie.',
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.3,
                                  color: oscuro
                                      ? const Color(0xFF90A4AE)
                                      : const Color(0xFF607D8B),
                                ),
                              );
                            },
                          ),
                          const SizedBox(height: 12),
                          Builder(
                            builder: (ctx) {
                              final totalPie = agg.topResponsables.fold<int>(
                                0,
                                (a, e) => a + e.value,
                              );
                              final nPie = agg.topResponsables.length;
                              final chartH =
                                  (132.0 + nPie * 52.0).clamp(300.0, 560.0);
                              final pieRadius = chartH >= 420 ? 62.0 : 54.0;
                              final centerR = chartH >= 420 ? 62.0 : 56.0;
                              return SizedBox(
                                height: chartH,
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Expanded(
                                      flex: 12,
                                      child: Stack(
                                        alignment: Alignment.center,
                                        children: [
                                          PieChart(
                                            PieChartData(
                                              sectionsSpace: 2,
                                              centerSpaceRadius: centerR,
                                              startDegreeOffset: -90,
                                              sections: [
                                                for (var i = 0;
                                                    i <
                                                        agg.topResponsables
                                                            .length;
                                                    i++)
                                                  PieChartSectionData(
                                                    color: _kPiePastel[
                                                        i %
                                                            _kPiePastel
                                                                .length],
                                                    value: agg
                                                        .topResponsables[i]
                                                        .value
                                                        .toDouble(),
                                                    title: totalPie > 0 &&
                                                            (agg.topResponsables[
                                                                        i]
                                                                    .value /
                                                                totalPie) >=
                                                                0.05
                                                        ? '${((agg.topResponsables[i].value / totalPie) * 100).round()}%'
                                                        : '',
                                                    radius: pieRadius,
                                                    titlePositionPercentageOffset:
                                                        0.62,
                                                    titleStyle: TextStyle(
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.w800,
                                                      color: material
                                                          .Colors.white,
                                                      shadows: const [
                                                        Shadow(
                                                          color: Color(0x66000000),
                                                          blurRadius: 2,
                                                        ),
                                                      ],
                                                    ),
                                                    borderSide: BorderSide(
                                                      color: _statsSurface(
                                                        oscuro,
                                                      ),
                                                      width: 2.2,
                                                    ),
                                                  ),
                                              ],
                                              pieTouchData: PieTouchData(
                                                enabled: true,
                                              ),
                                            ),
                                          ),
                                          IgnorePointer(
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(
                                                  '$totalPie',
                                                  style: TextStyle(
                                                    fontSize: 22,
                                                    fontWeight: FontWeight.w900,
                                                    color: oscuro
                                                        ? const Color(
                                                            0xFFECEFF1,
                                                          )
                                                        : const Color(
                                                            0xFF0D47A1,
                                                          ),
                                                  ),
                                                ),
                                                Text(
                                                  'cierres\n(top ${agg.topResponsables.length})',
                                                  textAlign: TextAlign.center,
                                                  style: TextStyle(
                                                    fontSize: 9.5,
                                                    fontWeight:
                                                        FontWeight.w600,
                                                    height: 1.15,
                                                    color: oscuro
                                                        ? const Color(
                                                            0xFF90A4AE,
                                                          )
                                                        : const Color(
                                                            0xFF607D8B,
                                                          ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      flex: 10,
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          for (var i = 0;
                                              i <
                                                  agg.topResponsables.length;
                                              i++)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                bottom: 7,
                                              ),
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 10,
                                                  vertical: 8,
                                                ),
                                                decoration: BoxDecoration(
                                                  gradient: LinearGradient(
                                                    colors: [
                                                      _kPiePastel[i %
                                                              _kPiePastel
                                                                  .length]
                                                          .withValues(
                                                        alpha: oscuro
                                                            ? 0.24
                                                            : 0.14,
                                                      ),
                                                      _statsSurface(oscuro),
                                                    ],
                                                  ),
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                    10,
                                                  ),
                                                  border: Border.all(
                                                    color: _kPiePastel[i %
                                                            _kPiePastel.length]
                                                        .withValues(
                                                      alpha: 0.5,
                                                    ),
                                                  ),
                                                ),
                                                child: Row(
                                                  children: [
                                                    Container(
                                                      width: 6,
                                                      height: 34,
                                                      decoration: BoxDecoration(
                                                        color: _kPiePastel[i %
                                                            _kPiePastel
                                                                .length],
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(
                                                          4,
                                                        ),
                                                      ),
                                                    ),
                                                    const SizedBox(width: 10),
                                                    Expanded(
                                                      child: Text(
                                                        agg.topResponsables[i]
                                                            .key,
                                                        maxLines: 2,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: TextStyle(
                                                          fontSize: 12,
                                                          fontWeight:
                                                              FontWeight.w700,
                                                          color: oscuro
                                                              ? const Color(
                                                                  0xFFECEFF1,
                                                                )
                                                              : const Color(
                                                                  0xFF212121,
                                                                ),
                                                        ),
                                                      ),
                                                    ),
                                                    Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .end,
                                                      children: [
                                                        Text(
                                                          '${agg.topResponsables[i].value}',
                                                          style: TextStyle(
                                                            fontSize: 14,
                                                            fontWeight:
                                                                FontWeight.w900,
                                                            color: accent,
                                                          ),
                                                        ),
                                                        if (totalPie > 0)
                                                          Text(
                                                            '${((agg.topResponsables[i].value / totalPie) * 100).round()}%',
                                                            style: TextStyle(
                                                              fontSize: 10,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w600,
                                                              color: oscuro
                                                                  ? const Color(
                                                                      0xFFB0BEC5,
                                                                    )
                                                                  : const Color(
                                                                      0xFF546E7A,
                                                                    ),
                                                            ),
                                                          ),
                                                      ],
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ],
                      ),
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

  // ----- helpers del nuevo diseño -----

  Widget _buildTituloSeccion({
    required bool oscuro,
    required String titulo,
    required String subtitulo,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 4,
              height: 18,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: oscuro
                    ? const Color(0xFF64B5F6)
                    : const Color(0xFF1565C0),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Flexible(
              child: Text(
                titulo,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: oscuro
                      ? const Color(0xFFF5F5F5)
                      : const Color(0xFF0D47A1),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Text(
            subtitulo,
            style: TextStyle(
              fontSize: 12,
              color: oscuro
                  ? const Color(0xFF90A4AE)
                  : const Color(0xFF607D8B),
              height: 1.3,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEncabezadoInforme({
    required BuildContext context,
    required FluentThemeData theme,
    required bool oscuro,
    required Color accent,
    required List<DateTime> mesesDisponibles,
    required _MesAgg mesAgg,
    required _BitacoraAgg agg,
    required int historialTotal,
    required int historialConCierre,
  }) {
    final itemsMes = mesesDisponibles
        .map(
          (d) => ComboBoxItem<DateTime>(
            value: d,
            child: Text(
              _etiquetaMesLargo(d),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        )
        .toList();

    final gradStart = oscuro
        ? const Color(0xFF1B2430)
        : const Color(0xFFE3F2FD);
    final gradEnd = oscuro
        ? const Color(0xFF0F1620)
        : const Color(0xFFBBDEFB);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [gradStart, gradEnd],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: oscuro
              ? const Color(0xFF37474F)
              : const Color(0xFF90CAF9),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, c) {
          final narrow = c.maxWidth < 680;
          final encabezado = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    FluentIcons.b_i_dashboard,
                    size: 22,
                    color: oscuro
                        ? const Color(0xFF90CAF9)
                        : const Color(0xFF0D47A1),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Informe de actividad',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        color: oscuro
                            ? const Color(0xFFFAFAFA)
                            : const Color(0xFF0D47A1),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Selecciona el mes para enfocar los indicadores del informe. '
                'El total acumulado del historial es ${agg.total} misión(es) '
                '(${agg.terminadas} terminadas, ${agg.canceladas} canceladas).',
                style: TextStyle(
                  fontSize: 12.5,
                  color: oscuro
                      ? const Color(0xFFB0BEC5)
                      : const Color(0xFF263238),
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _chipAlcanceHistorial(
                    oscuro: oscuro,
                    titulo: 'Todo el tiempo (datos cargados)',
                    principal: '$historialTotal',
                    secundario: '$historialConCierre con cierre',
                  ),
                  _chipAlcanceHistorial(
                    oscuro: oscuro,
                    titulo: 'Mes del informe',
                    principal: '${mesAgg.cerradas}',
                    secundario: 'cierres en mes',
                  ),
                ],
              ),
            ],
          );

          final controles = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: oscuro
                      ? const Color(0xFF263238)
                      : material.Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: oscuro
                        ? const Color(0xFF455A64)
                        : const Color(0xFFB0BEC5),
                  ),
                ),
                child: ComboBox<DateTime>(
                  value: _mesSeleccionado,
                  items: itemsMes,
                  onChanged: (d) {
                    if (d == null) return;
                    setState(() {
                      _mesSeleccionado = DateTime(d.year, d.month, 1);
                    });
                  },
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed:
                    _exportando ? null : () => _exportarPdf(mesAgg, agg),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_exportando) ...[
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: ProgressRing(strokeWidth: 2),
                        ),
                        const SizedBox(width: 8),
                        const Text('Exportando...'),
                      ] else ...[
                        const Icon(FluentIcons.pdf, size: 16),
                        const SizedBox(width: 8),
                        const Text('Exportar informe PDF'),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          );

          if (narrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                encabezado,
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: controles,
                ),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: encabezado),
              const SizedBox(width: 12),
              controles,
            ],
          );
        },
      ),
    );
  }

  Widget _chipAlcanceHistorial({
    required bool oscuro,
    required String titulo,
    required String principal,
    required String secundario,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: oscuro
            ? const Color(0xFF263238).withValues(alpha: 0.95)
            : material.Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: oscuro
              ? const Color(0xFF455A64)
              : const Color(0xFF90CAF9),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            titulo,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: oscuro
                  ? const Color(0xFFB0BEC5)
                  : const Color(0xFF546E7A),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            principal,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w900,
              height: 1.05,
              color: oscuro
                  ? const Color(0xFFFAFAFA)
                  : const Color(0xFF0D47A1),
            ),
          ),
          Text(
            secundario,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: oscuro
                  ? const Color(0xFF90CAF9)
                  : const Color(0xFF1565C0),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildKpiGrid({
    required BuildContext context,
    required FluentThemeData theme,
    required bool oscuro,
    required Color accent,
    required _MesAgg mesAgg,
  }) {
    final tiles = <_KpiTileData>[
      _KpiTileData(
        titulo: 'Historial (lista)',
        valor: '${widget.tareas.length}',
        sub: 'Con cierre: ${widget.tareas.where((t) => fechaCierreHistorialDate(t) != null).length}',
        icon: FluentIcons.history,
        color: const Color(0xFF455A64),
      ),
      _KpiTileData(
        titulo: 'Cerradas del mes',
        valor: '${mesAgg.cerradas}',
        sub: mesAgg.creadas > 0 ? '${mesAgg.creadas} creadas' : null,
        icon: FluentIcons.check_list,
        color: accent,
      ),
      _KpiTileData(
        titulo: 'Terminadas',
        valor: '${mesAgg.terminadas}',
        sub: mesAgg.terminadas > 0 || mesAgg.canceladas > 0
            ? '${mesAgg.tasaCumplimiento.toStringAsFixed(0)} % cumplimiento'
            : null,
        icon: FluentIcons.completed,
        color: const Color(0xFF2E7D32),
      ),
      _KpiTileData(
        titulo: 'Canceladas',
        valor: '${mesAgg.canceladas}',
        sub: mesAgg.canceladas > 0
            ? 'Revisar causas'
            : 'Sin cancelaciones',
        icon: FluentIcons.cancel,
        color: const Color(0xFFE65100),
      ),
      _KpiTileData(
        titulo: 'Lead time promedio',
        valor: mesAgg.leadHorasProm != null
            ? _fmtHoras(mesAgg.leadHorasProm!)
            : 's/d',
        sub: mesAgg.muestrasLeadTime > 0
            ? 'Sobre ${mesAgg.muestrasLeadTime} caso(s)'
            : null,
        icon: FluentIcons.timer,
        color: const Color(0xFF00897B),
      ),
      _KpiTileData(
        titulo: 'Manual',
        valor: '${mesAgg.manualCerradas}',
        sub: 'Origen manual',
        icon: FluentIcons.page_list,
        color: const Color(0xFF1565C0),
      ),
      _KpiTileData(
        titulo: 'Radar',
        valor: '${mesAgg.radarCerradas}',
        sub: 'Origen radar',
        icon: FluentIcons.bullseye_target,
        color: const Color(0xFF6A1B9A),
      ),
    ];

    return LayoutBuilder(
      builder: (context, c) {
        int cols;
        if (c.maxWidth >= 1120) {
          cols = 6;
        } else if (c.maxWidth >= 860) {
          cols = 3;
        } else if (c.maxWidth >= 520) {
          cols = 2;
        } else {
          cols = 1;
        }
        const gap = 10.0;
        final tileWidth = (c.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final t in tiles)
              SizedBox(
                width: tileWidth,
                child: _kpiTile(
                  data: t,
                  oscuro: oscuro,
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _kpiTile({
    required _KpiTileData data,
    required bool oscuro,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: _statsSurface(oscuro),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: oscuro
              ? const Color(0xFF37474F)
              : const Color(0xFFE0E0E0),
        ),
        boxShadow: [
          BoxShadow(
            color: data.color.withValues(alpha: oscuro ? 0.18 : 0.10),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: data.color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(data.icon, size: 16, color: data.color),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  data.titulo,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                    color: oscuro
                        ? const Color(0xFFB0BEC5)
                        : const Color(0xFF546E7A),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            data.valor,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              height: 1.05,
              color: oscuro
                  ? const Color(0xFFFAFAFA)
                  : const Color(0xFF0D0D0D),
            ),
          ),
          if (data.sub != null) ...[
            const SizedBox(height: 2),
            Text(
              data.sub!,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: data.color,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildChartCreadasVsCerradas({
    required FluentThemeData theme,
    required bool oscuro,
    required Color accent,
    required _MesAgg mesAgg,
  }) {
    final dias = mesAgg.diasMes;
    final maxY = [
      ...List.generate(dias, (i) => mesAgg.creadasPorDia[i + 1] ?? 0),
      ...List.generate(dias, (i) => mesAgg.cerradasPorDia[i + 1] ?? 0),
    ].fold<int>(1, math.max);
    final colorCreadas = const Color(0xFF1565C0);
    final colorCerradas = const Color(0xFF2E7D32);

    return Card(
      child: ColoredBox(
        color: _statsSurface(oscuro),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Creadas vs cerradas por día',
                      style: theme.typography.bodyStrong?.copyWith(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  _legendDot(colorCreadas, 'Creadas', oscuro),
                  const SizedBox(width: 10),
                  _legendDot(colorCerradas, 'Cerradas', oscuro),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Detecta días pico y días sin actividad dentro del mes seleccionado.',
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
                    maxY: math.max(maxY * 1.15, 1),
                    minY: 0,
                    barTouchData: BarTouchData(
                      enabled: true,
                      touchTooltipData: BarTouchTooltipData(
                        getTooltipColor: (_) => oscuro
                            ? const Color(0xFF37474F)
                            : const Color(0xFFECEFF1),
                        getTooltipItem: (group, gi, rod, ri) {
                          final dia = group.x.toInt() + 1;
                          final cre = mesAgg.creadasPorDia[dia] ?? 0;
                          final cer = mesAgg.cerradasPorDia[dia] ?? 0;
                          return BarTooltipItem(
                            'Día $dia\n',
                            TextStyle(
                              fontWeight: FontWeight.w700,
                              color: oscuro
                                  ? material.Colors.white
                                  : const Color(0xFF0D0D0D),
                            ),
                            children: [
                              TextSpan(
                                text: 'Creadas: $cre  ',
                                style: TextStyle(color: colorCreadas),
                              ),
                              TextSpan(
                                text: 'Cerradas: $cer',
                                style: TextStyle(color: colorCerradas),
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
                          interval: maxY <= 4 ? 1 : null,
                          getTitlesWidget: (v, m) => Text(
                            v == v.roundToDouble() ? '${v.toInt()}' : '',
                            style: const TextStyle(fontSize: 10),
                          ),
                        ),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 22,
                          interval: 1,
                          getTitlesWidget: (v, meta) {
                            final i = v.toInt();
                            if (i < 0 || i >= dias) {
                              return const SizedBox.shrink();
                            }
                            final dia = i + 1;
                            final mostrar = dias <= 20 ||
                                dia == 1 ||
                                dia == dias ||
                                dia % 5 == 0;
                            if (!mostrar) return const SizedBox.shrink();
                            return Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                '$dia',
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
                      getDrawingHorizontalLine: (v) => FlLine(
                        color: oscuro
                            ? const Color(0xFF455A64)
                            : const Color(0xFFE0E0E0),
                        strokeWidth: 1,
                      ),
                    ),
                    borderData: FlBorderData(show: false),
                    barGroups: List.generate(dias, (i) {
                      final dia = i + 1;
                      final cre =
                          (mesAgg.creadasPorDia[dia] ?? 0).toDouble();
                      final cer =
                          (mesAgg.cerradasPorDia[dia] ?? 0).toDouble();
                      return BarChartGroupData(
                        x: i,
                        barsSpace: 2,
                        barRods: [
                          BarChartRodData(
                            toY: cre,
                            color: colorCreadas,
                            width: 5.5,
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(3),
                            ),
                          ),
                          BarChartRodData(
                            toY: cer,
                            color: colorCerradas,
                            width: 5.5,
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(3),
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
    );
  }

  Widget _buildChartAcumulado({
    required FluentThemeData theme,
    required bool oscuro,
    required Color accent,
    required _MesAgg mesAgg,
  }) {
    final dias = mesAgg.diasMes;
    var acum = 0;
    final puntos = <FlSpot>[];
    for (var d = 1; d <= dias; d++) {
      acum += mesAgg.cerradasPorDia[d] ?? 0;
      puntos.add(FlSpot(d.toDouble(), acum.toDouble()));
    }
    final maxY = math.max(acum, 1);

    return Card(
      child: ColoredBox(
        color: _statsSurface(oscuro),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Cierres acumulados del mes',
                style: theme.typography.bodyStrong?.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Curva que muestra cómo avanzó el mes respecto al total final ($acum).',
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
                height: 200,
                child: LineChart(
                  LineChartData(
                    minX: 1,
                    maxX: dias.toDouble(),
                    minY: 0,
                    maxY: (maxY * 1.15).clamp(1, 1e9),
                    gridData: FlGridData(
                      show: true,
                      drawVerticalLine: false,
                      getDrawingHorizontalLine: (v) => FlLine(
                        color: oscuro
                            ? const Color(0xFF455A64)
                            : const Color(0xFFE0E0E0),
                        strokeWidth: 1,
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
                          interval: maxY <= 4 ? 1 : null,
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
                          reservedSize: 22,
                          interval: (dias / 6).ceilToDouble(),
                          getTitlesWidget: (v, meta) {
                            final i = v.toInt();
                            if (i < 1 || i > dias) {
                              return const SizedBox.shrink();
                            }
                            return Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                '$i',
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
                    borderData: FlBorderData(show: false),
                    lineBarsData: [
                      LineChartBarData(
                        spots: puntos,
                        isCurved: true,
                        color: accent,
                        barWidth: 3,
                        dotData: FlDotData(
                          show: dias <= 15,
                          getDotPainter: (p, _, __, ___) =>
                              FlDotCirclePainter(
                            radius: 3,
                            color: accent,
                            strokeWidth: 0,
                          ),
                        ),
                        belowBarData: BarAreaData(
                          show: true,
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              accent.withValues(alpha: 0.35),
                              accent.withValues(alpha: 0.02),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPieEstadoMes({
    required FluentThemeData theme,
    required bool oscuro,
    required _MesAgg mesAgg,
    required List<Map<String, dynamic>> activas,
  }) {
    final term = mesAgg.terminadas;
    final canc = mesAgg.canceladas;
    final pend = _pendientesEstadoMesCount(activas, mesAgg.mes);
    final totalPie = term + canc + pend;
    final colorTerm = const Color(0xFF2E7D32);
    final colorCanc = const Color(0xFFE65100);
    final colorPend = const Color(0xFF78909C);

    String pctEtiqueta(int slice) {
      if (totalPie <= 0 || slice <= 0) return '';
      final p = (slice / totalPie) * 100.0;
      return p >= 5 ? '${p.round()} %' : '';
    }

    final cuerpo = totalPie == 0
        ? Center(
            child: Text(
              'Sin cierres ni pendientes que entren en este mes.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                color: oscuro
                    ? const Color(0xFFB0BEC5)
                    : const Color(0xFF546E7A),
              ),
            ),
          )
        : Row(
            children: [
              Expanded(
                flex: 11,
                child: PieChart(
                  PieChartData(
                    sectionsSpace: 1.5,
                    centerSpaceRadius: 44,
                    startDegreeOffset: -90,
                    sections: [
                      if (term > 0)
                        PieChartSectionData(
                          value: term.toDouble(),
                          color: colorTerm,
                          radius: 56,
                          title: pctEtiqueta(term),
                          titleStyle: const TextStyle(
                            color: material.Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 11,
                          ),
                        ),
                      if (canc > 0)
                        PieChartSectionData(
                          value: canc.toDouble(),
                          color: colorCanc,
                          radius: 56,
                          title: pctEtiqueta(canc),
                          titleStyle: const TextStyle(
                            color: material.Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 11,
                          ),
                        ),
                      if (pend > 0)
                        PieChartSectionData(
                          value: pend.toDouble(),
                          color: colorPend,
                          radius: 56,
                          title: pctEtiqueta(pend),
                          titleStyle: const TextStyle(
                            color: material.Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 9,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _legendDot(colorTerm, 'Terminadas ($term)', oscuro),
                    const SizedBox(height: 6),
                    _legendDot(colorCanc, 'Canceladas ($canc)', oscuro),
                    const SizedBox(height: 6),
                    _legendDot(
                      colorPend,
                      'Pendientes ($pend)${totalPie > 0 ? ' · ${((pend / totalPie) * 100).round()} %' : ''}',
                      oscuro,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Cumplimiento (sobre cerradas): '
                      '${mesAgg.tasaCumplimiento.toStringAsFixed(0)} %',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: oscuro
                            ? const Color(0xFFECEFF1)
                            : const Color(0xFF263238),
                      ),
                    ),
                    Text(
                      'Pendientes: activas sin cierre con fin laboral estimado '
                      'en el mes o sin tiempo estimado.',
                      style: TextStyle(
                        fontSize: 10.5,
                        height: 1.25,
                        color: oscuro
                            ? const Color(0xFF90A4AE)
                            : const Color(0xFF607D8B),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );

    return Card(
      child: ColoredBox(
        color: _statsSurface(oscuro),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Estado del mes',
                style: theme.typography.bodyStrong?.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Terminadas, canceladas y pendientes del panel activas '
                '(pendientes: fin estimado en el mes o sin estimacion).',
                style: TextStyle(
                  fontSize: 12,
                  color: oscuro
                      ? const Color(0xFF90A4AE)
                      : const Color(0xFF607D8B),
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(height: 200, child: cuerpo),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWrapMiniPiesUsuario({
    required FluentThemeData theme,
    required bool oscuro,
    required Color accent,
    required _MesAgg mesAgg,
    required List<Map<String, dynamic>> activas,
    required Map<String, Color> colorPorUsuario,
  }) {
    final raw = _completadasVsFaltantesPorUsuario(mesAgg, activas);
    final entries =
        raw.entries.where((e) => e.value.ok > 0 || e.value.pend > 0).toList()
          ..sort((a, b) {
            final ta = a.value.ok + a.value.pend;
            final tb = b.value.ok + b.value.pend;
            if (tb != ta) return tb.compareTo(ta);
            return a.key.toLowerCase().compareTo(b.key.toLowerCase());
          });
    final top = entries.take(8).toList();
    if (top.isEmpty) {
      return const SizedBox.shrink();
    }

    return Card(
      child: ColoredBox(
        color: _statsSurface(oscuro),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Cerradas en el mes vs pendientes (por responsable)',
                style: theme.typography.bodyStrong?.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Mini pastel por usuario: cierres no cancelados del mes frente a '
                'pendientes (misma regla que el donut). Colores = configuracion de usuario.',
                style: TextStyle(
                  fontSize: 12,
                  color: oscuro
                      ? const Color(0xFF90A4AE)
                      : const Color(0xFF607D8B),
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (var i = 0; i < top.length; i++)
                    _miniPieUsuarioCard(
                      usuario: top[i].key,
                      completadas: top[i].value.ok,
                      faltantes: top[i].value.pend,
                      userColor: _colorBarraUsuarioPreferente(
                        top[i].key,
                        colorPorUsuario,
                        i,
                      ),
                      oscuro: oscuro,
                      accent: accent,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _miniPieUsuarioCard({
    required String usuario,
    required int completadas,
    required int faltantes,
    required Color userColor,
    required bool oscuro,
    required Color accent,
  }) {
    final total = completadas + faltantes;
    final colorFalta = oscuro
        ? const Color(0xFF455A64)
        : const Color(0xFFB0BEC5);

    Widget graf;
    if (total <= 0) {
      graf = Center(
        child: Text(
          'Sin datos',
          style: TextStyle(
            fontSize: 11,
            color: oscuro
                ? const Color(0xFF90A4AE)
                : const Color(0xFF607D8B),
          ),
        ),
      );
    } else {
      graf = PieChart(
        PieChartData(
          sectionsSpace: 1,
          centerSpaceRadius: 22,
          startDegreeOffset: -90,
          sections: [
            if (completadas > 0)
              PieChartSectionData(
                value: completadas.toDouble(),
                color: userColor,
                radius: 38,
                title: total > 0
                    ? '${((completadas / total) * 100).round()}%'
                    : '',
                titleStyle: TextStyle(
                  color: material.Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 10,
                  shadows: const [
                    Shadow(color: Color(0x66000000), blurRadius: 2),
                  ],
                ),
              ),
            if (faltantes > 0)
              PieChartSectionData(
                value: faltantes.toDouble(),
                color: colorFalta,
                radius: 38,
                title: total > 0
                    ? '${((faltantes / total) * 100).round()}%'
                    : '',
                titleStyle: TextStyle(
                  color: material.Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 10,
                  shadows: const [
                    Shadow(color: Color(0x66000000), blurRadius: 2),
                  ],
                ),
              ),
          ],
        ),
      );
    }

    return Container(
      width: 158,
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
      decoration: BoxDecoration(
        color: oscuro ? const Color(0xFF2C313A) : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: userColor.withValues(alpha: oscuro ? 0.45 : 0.55),
          width: 1.1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            usuario,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: oscuro
                  ? const Color(0xFFECEFF1)
                  : const Color(0xFF263238),
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(height: 112, child: graf),
          const SizedBox(height: 6),
          Text(
            'Ok $completadas · Falta $faltantes',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: accent.withValues(alpha: 0.95),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChartDiaSemana({
    required FluentThemeData theme,
    required bool oscuro,
    required Color accent,
    required _MesAgg mesAgg,
  }) {
    final valores =
        List.generate(7, (i) => mesAgg.cerradasPorDiaSemana[i + 1] ?? 0);
    final maxY = valores.fold<int>(1, math.max);

    return Card(
      child: ColoredBox(
        color: _statsSurface(oscuro),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Cierres por día de la semana',
                style: theme.typography.bodyStrong?.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Identifica los días con más actividad productiva dentro del mes.',
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
                height: 200,
                child: BarChart(
                  BarChartData(
                    alignment: BarChartAlignment.spaceBetween,
                    maxY: math.max(maxY * 1.2, 1),
                    minY: 0,
                    barTouchData: BarTouchData(
                      enabled: true,
                      touchTooltipData: BarTouchTooltipData(
                        getTooltipColor: (_) => oscuro
                            ? const Color(0xFF37474F)
                            : const Color(0xFFECEFF1),
                        getTooltipItem: (group, gi, rod, ri) {
                          final i = group.x.toInt();
                          return BarTooltipItem(
                            '${_kDiasSemanaCortos[i + 1]}: ${valores[i]}',
                            TextStyle(
                              fontWeight: FontWeight.w700,
                              color: oscuro
                                  ? material.Colors.white
                                  : const Color(0xFF0D0D0D),
                            ),
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
                          reservedSize: 28,
                          interval: maxY <= 4 ? 1 : null,
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
                          reservedSize: 22,
                          getTitlesWidget: (v, meta) {
                            final i = v.toInt();
                            if (i < 0 || i > 6) {
                              return const SizedBox.shrink();
                            }
                            return Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                _kDiasSemanaCortos[i + 1],
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
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
                      getDrawingHorizontalLine: (v) => FlLine(
                        color: oscuro
                            ? const Color(0xFF455A64)
                            : const Color(0xFFE0E0E0),
                        strokeWidth: 1,
                      ),
                    ),
                    borderData: FlBorderData(show: false),
                    barGroups: List.generate(7, (i) {
                      final v = valores[i].toDouble();
                      return BarChartGroupData(
                        x: i,
                        barRods: [
                          BarChartRodData(
                            toY: v,
                            color: i >= 5
                                ? accent.withValues(alpha: 0.6)
                                : accent,
                            width: 18,
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(5),
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
    );
  }

  Widget _buildListaMisionesCerradasMes({
    required FluentThemeData theme,
    required bool oscuro,
    required _MesAgg mesAgg,
  }) {
    final bloques = <Widget>[];
    for (final e in mesAgg.topRespMes) {
      final lista = mesAgg.misionesCerradasPorUsuario[e.key] ?? const [];
      if (lista.isEmpty) continue;
      const maxList = 8;
      final shown = lista.take(maxList).toList();
      final mas = lista.length - shown.length;
      bloques.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    FluentIcons.contact,
                    size: 14,
                    color: theme.accentColor,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      e.key,
                      style: theme.typography.bodyStrong?.copyWith(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text(
                    '${lista.length} mision(es)',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: theme.accentColor,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              for (final m in shown)
                Padding(
                  padding: const EdgeInsets.only(left: 8, bottom: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '• ',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: oscuro
                              ? const Color(0xFF90CAF9)
                              : const Color(0xFF1565C0),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          m,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            height: 1.25,
                            color: oscuro
                                ? const Color(0xFFECEFF1)
                                : const Color(0xFF37474F),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (mas > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 8, top: 2),
                  child: Text(
                    'y $mas mas...',
                    style: TextStyle(
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                      color: oscuro
                          ? const Color(0xFF90A4AE)
                          : const Color(0xFF78909C),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }
    if (bloques.isEmpty) return const SizedBox.shrink();
    return Card(
      child: ColoredBox(
        color: _statsSurface(oscuro),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Titulos cerrados en el mes',
                style: theme.typography.bodyStrong?.copyWith(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Listado breve por responsable (misiones no canceladas).',
                style: TextStyle(
                  fontSize: 11.5,
                  color: oscuro
                      ? const Color(0xFF90A4AE)
                      : const Color(0xFF607D8B),
                  height: 1.25,
                ),
              ),
              const SizedBox(height: 10),
              ...bloques,
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChartActivasPendientesPorUsuario({
    required FluentThemeData theme,
    required bool oscuro,
    required Color accent,
    required List<Map<String, dynamic>> activas,
    required Map<String, Color> colorPorUsuario,
  }) {
    final filas = _conteoActivasPendientesPorUsuario(activas).take(8).toList();
    final maxX = filas.fold<int>(1, (p, e) => math.max(p, e.value));

    return Card(
      child: ColoredBox(
        color: _statsSurface(oscuro),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Activas pendientes por responsable',
                style: theme.typography.bodyStrong?.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Misiones sin cierre en el panel de activas, por asignado.',
                style: TextStyle(
                  fontSize: 12,
                  color: oscuro
                      ? const Color(0xFF90A4AE)
                      : const Color(0xFF607D8B),
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 10),
              if (filas.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    'No hay misiones activas pendientes o todas sin asignar.',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: oscuro
                          ? const Color(0xFFB0BEC5)
                          : const Color(0xFF546E7A),
                    ),
                  ),
                )
              else
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < filas.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _barraResponsable(
                          rank: i + 1,
                          nombre: filas[i].key,
                          valor: filas[i].value,
                          maxValor: maxX,
                          color: _colorBarraUsuarioPreferente(
                            filas[i].key,
                            colorPorUsuario,
                            i,
                          ),
                          accent: accent,
                          oscuro: oscuro,
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChartMinutosRestantesActivas({
    required FluentThemeData theme,
    required bool oscuro,
    required Color accent,
    required List<Map<String, dynamic>> activas,
    required Map<String, Color> colorPorUsuario,
  }) {
    final filas = _cargaActivaPorUsuario(activas).take(8).toList();
    final maxX = filas.fold<int>(1, (p, e) => math.max(p, e.value));

    return Card(
      child: ColoredBox(
        color: _statsSurface(oscuro),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Tiempo estimado restante (activas)',
                style: theme.typography.bodyStrong?.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Suma de minutos pendientes (presupuesto y progreso). '
                'La barra usa minutos; a la derecha, horas.',
                style: TextStyle(
                  fontSize: 12,
                  color: oscuro
                      ? const Color(0xFF90A4AE)
                      : const Color(0xFF607D8B),
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 10),
              if (filas.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    'Sin estimacion de tiempo en las misiones activas.',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: oscuro
                          ? const Color(0xFFB0BEC5)
                          : const Color(0xFF546E7A),
                    ),
                  ),
                )
              else
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < filas.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _barraResponsable(
                          rank: i + 1,
                          nombre: filas[i].key,
                          valor: filas[i].value,
                          maxValor: maxX,
                          color: _colorBarraUsuarioPreferente(
                            filas[i].key,
                            colorPorUsuario,
                            i,
                          ),
                          accent: accent,
                          oscuro: oscuro,
                          valorLegible:
                              '${(filas[i].value / 60.0).toStringAsFixed(1)} h',
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChartResponsablesMes({
    required FluentThemeData theme,
    required bool oscuro,
    required Color accent,
    required _MesAgg mesAgg,
    required Map<String, Color> colorPorUsuario,
  }) {
    final filas = mesAgg.topRespMes;
    final maxX = filas.fold<int>(1, (p, e) => math.max(p, e.value));

    return Card(
      child: ColoredBox(
        color: _statsSurface(oscuro),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Top responsables del mes',
                style: theme.typography.bodyStrong?.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Quién cerró más misiones dentro de ${_etiquetaMesLargo(mesAgg.mes).toLowerCase()}.',
                style: TextStyle(
                  fontSize: 12,
                  color: oscuro
                      ? const Color(0xFF90A4AE)
                      : const Color(0xFF607D8B),
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 10),
              if (filas.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    'Sin cierres por responsable en el mes.',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: oscuro
                          ? const Color(0xFFB0BEC5)
                          : const Color(0xFF546E7A),
                    ),
                  ),
                )
              else
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < filas.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _barraResponsable(
                          rank: i + 1,
                          nombre: filas[i].key,
                          valor: filas[i].value,
                          maxValor: maxX,
                          color: _colorBarraUsuarioPreferente(
                            filas[i].key,
                            colorPorUsuario,
                            i,
                          ),
                          accent: accent,
                          oscuro: oscuro,
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _barraResponsable({
    required int rank,
    required String nombre,
    required int valor,
    required int maxValor,
    required Color color,
    required Color accent,
    required bool oscuro,
    String? valorLegible,
  }) {
    final pct = maxValor <= 0 ? 0.0 : valor / maxValor;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 20,
          child: Text(
            '$rank.',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: oscuro
                  ? const Color(0xFFB0BEC5)
                  : const Color(0xFF546E7A),
            ),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                nombre,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: oscuro
                      ? const Color(0xFFECEFF1)
                      : const Color(0xFF263238),
                ),
              ),
              const SizedBox(height: 4),
              LayoutBuilder(
                builder: (context, c) {
                  return Stack(
                    children: [
                      Container(
                        height: 10,
                        decoration: BoxDecoration(
                          color: oscuro
                              ? const Color(0xFF263238)
                              : const Color(0xFFECEFF1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      FractionallySizedBox(
                        widthFactor: pct.clamp(0.0, 1.0),
                        child: Container(
                          height: 10,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                color,
                                accent.withValues(alpha: 0.85),
                              ],
                            ),
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Text(
          valorLegible ?? '$valor',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: accent,
          ),
        ),
      ],
    );
  }

  Widget _legendDot(Color c, String txt, bool oscuro) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: c,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          txt,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            color: oscuro
                ? const Color(0xFFCFD8DC)
                : const Color(0xFF37474F),
          ),
        ),
      ],
    );
  }
}

class _KpiTileData {
  const _KpiTileData({
    required this.titulo,
    required this.valor,
    required this.icon,
    required this.color,
    this.sub,
  });
  final String titulo;
  final String valor;
  final IconData icon;
  final Color color;
  final String? sub;
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
                        final barColor =
                            colorBarraBitacoraParaTarea(t, oscuro: oscuro);
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
