import 'dart:convert';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as material;
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api_client.dart';
import '../widgets/compact_page_header.dart';

const String _kPrefsManualCambios = 'monitoreo_cambios_manuales_v1';

/// Fila alineada a la plantilla Excel de cambios (Centro de Monitoreo).
class _CambioManual {
  _CambioManual({
    required this.cambio,
    required this.dificultad,
    required this.equipos,
    required this.planos,
    required this.edrawing,
    required this.listas,
    required this.ensamble,
    required this.ayuda,
    this.completado = false,
    String? id,
  }) : id = id ?? '${cambio.hashCode}_${DateTime.now().microsecondsSinceEpoch}';

  final String id;
  final String cambio;
  final int dificultad;
  final String equipos;
  final bool planos;
  final bool edrawing;
  final bool listas;
  final bool ensamble;
  final bool ayuda;
  final bool completado;

  _CambioManual copyWith({
    String? cambio,
    int? dificultad,
    String? equipos,
    bool? planos,
    bool? edrawing,
    bool? listas,
    bool? ensamble,
    bool? ayuda,
    bool? completado,
  }) {
    return _CambioManual(
      id: id,
      cambio: cambio ?? this.cambio,
      dificultad: dificultad ?? this.dificultad,
      equipos: equipos ?? this.equipos,
      planos: planos ?? this.planos,
      edrawing: edrawing ?? this.edrawing,
      listas: listas ?? this.listas,
      ensamble: ensamble ?? this.ensamble,
      ayuda: ayuda ?? this.ayuda,
      completado: completado ?? this.completado,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'cambio': cambio,
        'dificultad': dificultad,
        'equipos': equipos,
        'planos': planos,
        'edrawing': edrawing,
        'listas': listas,
        'ensamble': ensamble,
        'ayuda': ayuda,
        'completado': completado,
      };

  static _CambioManual fromJson(Map<String, dynamic> m) {
    final cambio = '${m['cambio'] ?? ''}';
    final idRaw = m['id']?.toString();
    final idStable =
        (idRaw != null && idRaw.isNotEmpty) ? idRaw : 'legacy_${cambio.hashCode}';
    return _CambioManual(
      id: idStable,
      cambio: cambio,
      dificultad: int.tryParse('${m['dificultad'] ?? 1}') ?? 1,
      equipos: '${m['equipos'] ?? ''}',
      planos: m['planos'] == true || '${m['planos']}' == '1',
      edrawing: m['edrawing'] == true || '${m['edrawing']}' == '1',
      listas: m['listas'] == true || '${m['listas']}' == '1',
      ensamble: m['ensamble'] == true || '${m['ensamble']}' == '1',
      ayuda: m['ayuda'] == true || '${m['ayuda']}' == '1',
      completado: m['completado'] == true || '${m['completado']}' == '1',
    );
  }
}

/// Datos iniciales según plantilla Excel de cambios.
List<_CambioManual> _plantillaInicialExcel() {
  return [
    _CambioManual(
      id: 'seed_1',
      cambio: 'Quitar estribo de primer poste',
      dificultad: 1,
      equipos: 'R26',
      planos: true,
      edrawing: true,
      listas: true,
      ensamble: true,
      ayuda: false,
    ),
    _CambioManual(
      id: 'seed_2',
      cambio: 'Barrenos de plafonería',
      dificultad: 2,
      equipos: 'TODOS',
      planos: true,
      edrawing: true,
      listas: false,
      ensamble: true,
      ayuda: false,
    ),
    _CambioManual(
      id: 'seed_3',
      cambio: 'Topes de chaqueteros',
      dificultad: 1,
      equipos: 'TODOS',
      planos: true,
      edrawing: true,
      listas: false,
      ensamble: true,
      ayuda: false,
    ),
    _CambioManual(
      id: 'seed_4',
      cambio: 'Poste encamisado y 1/4" de espesor',
      dificultad: 3,
      equipos: 'HEAD RAMPS',
      planos: true,
      edrawing: true,
      listas: false,
      ensamble: true,
      ayuda: false,
    ),
    _CambioManual(
      id: 'seed_5',
      cambio: 'Nuevo modelo de lengüetas',
      dificultad: 4,
      equipos: 'TODOS',
      planos: true,
      edrawing: true,
      listas: true,
      ensamble: true,
      ayuda: false,
    ),
    _CambioManual(
      id: 'seed_8',
      cambio: 'Ayuda visual torque estándar',
      dificultad: 1,
      equipos: 'TODOS',
      planos: false,
      edrawing: false,
      listas: false,
      ensamble: false,
      ayuda: true,
    ),
  ];
}

class MonitoreoTareasScreen extends StatefulWidget {
  const MonitoreoTareasScreen({super.key});

  @override
  State<MonitoreoTareasScreen> createState() => _MonitoreoTareasScreenState();
}

class _MonitoreoTareasScreenState extends State<MonitoreoTareasScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _tareas = [];
  List<_CambioManual> _manualRows = [];

  @override
  void initState() {
    super.initState();
    _cargar();
    _cargarManual();
  }

  Future<void> _cargarManual() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kPrefsManualCambios);
      if (raw != null && raw.isNotEmpty) {
        final list = json.decode(raw) as List<dynamic>;
        setState(() {
          _manualRows = list
              .whereType<Map<String, dynamic>>()
              .map((m) => _CambioManual.fromJson(m))
              .toList();
        });
      } else {
        setState(() => _manualRows = _plantillaInicialExcel());
        await _guardarManual();
      }
    } catch (_) {
      setState(() => _manualRows = _plantillaInicialExcel());
    }
  }

  Future<void> _guardarManual() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kPrefsManualCambios,
        json.encode(_manualRows.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }

  bool _esTareaRadar(Map<String, dynamic> t) {
    final raw = t['tipo']?.toString().trim() ?? '';
    if (raw.isEmpty) return false;
    final u = raw.toUpperCase();
    if (u == 'RADAR') return true;
    return u.contains('RADAR');
  }

  Future<void> _cargar() async {
    setState(() => _loading = true);
    try {
      final data = await ApiClient.get('/api/tareas/lista');
      if (data is! List) {
        if (mounted) {
          displayInfoBar(
            context,
            builder: (context, close) => InfoBar(
              title: const Text('Error'),
              content: Text('Respuesta inválida del servidor (lista de tareas).'),
              severity: InfoBarSeverity.error,
              action: IconButton(icon: const Icon(FluentIcons.clear), onPressed: close),
            ),
          );
        }
        setState(() {
          _tareas = [];
          _loading = false;
        });
        return;
      }
      setState(() {
        _tareas = data.whereType<Map<String, dynamic>>().toList();
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        displayInfoBar(
          context,
          builder: (context, close) => InfoBar(
            title: const Text('Error'),
            content: Text('No se pudieron cargar las tareas: $e'),
            severity: InfoBarSeverity.error,
            action: IconButton(icon: const Icon(FluentIcons.clear), onPressed: close),
          ),
        );
      }
      setState(() {
        _tareas = [];
        _loading = false;
      });
    }
  }

  Color _colorDificultad(int d) {
    switch (d) {
      case 1:
        return const Color(0xFF2E7D32);
      case 2:
        return const Color(0xFF81C784);
      case 3:
        return const Color(0xFFFFF176);
      default:
        return const Color(0xFFEF5350);
    }
  }

  Color _colorTextoDificultad(int d) {
    if (d == 2 || d == 3) return const Color(0xFF1B1B1B);
    return Colors.white;
  }

  material.Widget _celdaMarca(bool v) {
    return Icon(
      v ? FluentIcons.check_mark : FluentIcons.clear,
      size: 16,
      color: v ? const Color(0xFF2E7D32) : const Color(0xFFBDBDBD),
    );
  }

  Future<void> _abrirChecklist(Map<String, dynamic> tarea) async {
    final checks = (tarea['checklist'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .toList();
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return ContentDialog(
          title: Text('Checklist: ${tarea['titulo'] ?? tarea['id_tarea']}'),
          content: SizedBox(
            width: 520,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: checks.length,
              itemBuilder: (context, i) {
                final c = checks[i];
                final done = '${c['completado']}'.toLowerCase() == 'true' ||
                    '${c['completado']}' == '1';
                return Checkbox(
                  checked: done,
                  content: Text('${c['nombre'] ?? 'Item'}'),
                  onChanged: (v) async {
                    await ApiClient.put(
                      '/api/tareas/check/${c['id_check']}',
                      body: {'completado': v ?? false},
                    );
                    if (!ctx.mounted) return;
                    Navigator.pop(ctx);
                    await _cargar();
                  },
                );
              },
            ),
          ),
          actions: [
            Button(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cerrar'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _dialogoAgregarCambio() async {
    final cambioCtrl = TextEditingController();
    final equiposCtrl = TextEditingController();
    int dificultad = 2;
    bool planos = false;
    bool edrawing = false;
    bool listas = false;
    bool ensamble = false;
    bool ayuda = false;

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setLocal) {
            return ContentDialog(
              title: const Text('Nuevo cambio manual'),
              content: SizedBox(
                width: 480,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      InfoLabel(
                        label: 'Cambio',
                        child: TextBox(
                          controller: cambioCtrl,
                          placeholder: 'Descripción del cambio',
                        ),
                      ),
                      const SizedBox(height: 12),
                      InfoLabel(
                        label: 'Dificultad (1–4)',
                        child: ComboBox<int>(
                          value: dificultad,
                          items: const [
                            ComboBoxItem(value: 1, child: Text('1 — Baja')),
                            ComboBoxItem(value: 2, child: Text('2 — Media-baja')),
                            ComboBoxItem(value: 3, child: Text('3 — Media-alta')),
                            ComboBoxItem(value: 4, child: Text('4 — Alta')),
                          ],
                          onChanged: (v) {
                            if (v != null) setLocal(() => dificultad = v);
                          },
                        ),
                      ),
                      const SizedBox(height: 12),
                      InfoLabel(
                        label: 'Equipos en que aplica',
                        child: TextBox(
                          controller: equiposCtrl,
                          placeholder: 'Ej: R26, TODOS, HEAD RAMPS…',
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text('Aplica en:', style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      Checkbox(
                        checked: planos,
                        content: const Text('Planos'),
                        onChanged: (v) => setLocal(() => planos = v ?? false),
                      ),
                      Checkbox(
                        checked: edrawing,
                        content: const Text('E-drawing'),
                        onChanged: (v) => setLocal(() => edrawing = v ?? false),
                      ),
                      Checkbox(
                        checked: listas,
                        content: const Text('Listas'),
                        onChanged: (v) => setLocal(() => listas = v ?? false),
                      ),
                      Checkbox(
                        checked: ensamble,
                        content: const Text('Ensamble'),
                        onChanged: (v) => setLocal(() => ensamble = v ?? false),
                      ),
                      Checkbox(
                        checked: ayuda,
                        content: const Text('Ayuda visual'),
                        onChanged: (v) => setLocal(() => ayuda = v ?? false),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                Button(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed: () {
                    final t = cambioCtrl.text.trim();
                    if (t.isEmpty) return;
                    final row = _CambioManual(
                      cambio: t,
                      dificultad: dificultad.clamp(1, 4),
                      equipos: equiposCtrl.text.trim().isEmpty
                          ? '—'
                          : equiposCtrl.text.trim(),
                      planos: planos,
                      edrawing: edrawing,
                      listas: listas,
                      ensamble: ensamble,
                      ayuda: ayuda,
                    );
                    setState(() => _manualRows = [..._manualRows, row]);
                    _guardarManual();
                    Navigator.pop(ctx);
                  },
                  child: const Text('Guardar'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _confirmarRestaurarPlantilla() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => ContentDialog(
        title: const Text('Restaurar plantilla'),
        content: const Text(
          'Se reemplazarán todas las filas por la plantilla Excel estándar. '
          'Las filas que agregaste se perderán.',
        ),
        actions: [
          Button(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Restaurar')),
        ],
      ),
    );
    if (ok == true) {
      setState(() => _manualRows = _plantillaInicialExcel());
      await _guardarManual();
      if (mounted) {
        displayInfoBar(
          context,
          builder: (c, close) => InfoBar(
            title: const Text('Listo'),
            content: const Text('Plantilla restaurada.'),
            severity: InfoBarSeverity.success,
            onClose: close,
          ),
        );
      }
    }
  }

  void _toggleCompletado(int index) {
    setState(() {
      final r = _manualRows[index];
      _manualRows[index] = r.copyWith(completado: !r.completado);
    });
    _guardarManual();
  }

  Widget _tabRadar() {
    if (_loading) return const Center(child: ProgressRing());
    final radar = _tareas.where(_esTareaRadar).toList();
    if (radar.isEmpty) return const Center(child: Text('Sin tareas de Radar.'));
    return ListView.builder(
      itemCount: radar.length,
      itemBuilder: (context, i) {
        final t = radar[i];
        final p = int.tryParse('${t['porcentaje_progreso'] ?? 0}') ?? 0;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t['titulo']?.toString() ?? 'Tarea',
                  style: FluentTheme.of(context).typography.bodyStrong,
                ),
                const SizedBox(height: 8),
                ProgressBar(value: p / 100),
                const SizedBox(height: 6),
                Text('Progreso: $p%'),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () => _abrirChecklist(t),
                  child: const Text('Abrir checklist'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _tabManual() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: _dialogoAgregarCambio,
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(FluentIcons.add, size: 16),
                    SizedBox(width: 8),
                    Text('Agregar cambio'),
                  ],
                ),
              ),
              Button(
                onPressed: _confirmarRestaurarPlantilla,
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(FluentIcons.refresh, size: 16),
                    SizedBox(width: 8),
                    Text('Restaurar plantilla Excel'),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Scrollbar(
            child: SingleChildScrollView(
              scrollDirection: Axis.vertical,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: material.DataTable(
                  headingRowColor: const material.WidgetStatePropertyAll(Color(0xFFFFC107)),
                  headingTextStyle: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF000000),
                    fontSize: 13,
                  ),
                  dataTextStyle: TextStyle(
                    fontSize: 13,
                    color: FluentTheme.of(context).typography.body?.color ?? const Color(0xFF000000),
                  ),
                  columns: const [
                    material.DataColumn(label: Text('Cambios')),
                    material.DataColumn(label: Text('Dificultad'), numeric: true),
                    material.DataColumn(label: Text('Equipos en que aplica')),
                    material.DataColumn(label: Text('Planos')),
                    material.DataColumn(label: Text('E-drawing')),
                    material.DataColumn(label: Text('Listas')),
                    material.DataColumn(label: Text('Ensamble')),
                    material.DataColumn(label: Text('Ayuda visual')),
                    material.DataColumn(label: Text('Completado')),
                  ],
                  rows: List.generate(_manualRows.length, (i) {
                    final r = _manualRows[i];
                    final d = r.dificultad.clamp(1, 4);
                    return material.DataRow(
                      color: r.completado
                          ? material.WidgetStatePropertyAll(
                              Colors.grey.withValues(alpha: 0.12),
                            )
                          : null,
                      cells: [
                        material.DataCell(
                          SizedBox(
                            width: 280,
                            child: Text(
                              r.cambio,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        material.DataCell(
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: _colorDificultad(d),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '$d',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: _colorTextoDificultad(d),
                              ),
                            ),
                          ),
                        ),
                        material.DataCell(SizedBox(width: 140, child: Text(r.equipos))),
                        material.DataCell(_celdaMarca(r.planos)),
                        material.DataCell(_celdaMarca(r.edrawing)),
                        material.DataCell(_celdaMarca(r.listas)),
                        material.DataCell(_celdaMarca(r.ensamble)),
                        material.DataCell(_celdaMarca(r.ayuda)),
                        material.DataCell(
                          Checkbox(
                            checked: r.completado,
                            content: const Text(''),
                            onChanged: (_) => _toggleCompletado(i),
                          ),
                        ),
                      ],
                    );
                  }),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return material.Material(
      child: material.DefaultTabController(
        length: 2,
        child: ScaffoldPage(
          header: CompactPageHeader(
            title: const Text('Centro de Monitoreo'),
            commandBar: IconButton(
              icon: const Icon(FluentIcons.refresh),
              onPressed: _loading ? null : _cargar,
            ),
          ),
          content: Column(
            children: [
              material.TabBar(
                tabs: const [
                  material.Tab(text: 'Tareas de Radar'),
                  material.Tab(text: 'Cambios Manuales (Excel)'),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: material.TabBarView(
                  children: [
                    _tabRadar(),
                    _tabManual(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
