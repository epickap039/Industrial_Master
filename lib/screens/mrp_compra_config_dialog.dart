import 'package:fluent_ui/fluent_ui.dart';
import '../services/api_client.dart';

/// Configuración global de compra por material oficial (misma lista que Materiales Oficiales).
class MrpCompraConfigDialog extends StatefulWidget {
  const MrpCompraConfigDialog({
    super.key,
    required this.mrpRows,
    required this.initialConfig,
    required this.formatos,
    required this.onSaved,
  });

  final List<Map<String, dynamic>> mrpRows;
  final Map<String, dynamic> initialConfig;
  final List<Map<String, dynamic>> formatos;
  final Future<void> Function() onSaved;

  static Future<void> show(
    BuildContext context, {
    required List<Map<String, dynamic>> mrpRows,
    required Map<String, dynamic> initialConfig,
    required List<Map<String, dynamic>> formatos,
    required Future<void> Function() onSaved,
  }) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => MrpCompraConfigDialog(
        mrpRows: mrpRows,
        initialConfig: initialConfig,
        formatos: formatos,
        onSaved: onSaved,
      ),
    );
  }

  @override
  State<MrpCompraConfigDialog> createState() => _MrpCompraConfigDialogState();
}

class _MrpCompraConfigDialogState extends State<MrpCompraConfigDialog> {
  late final Map<String, Map<String, dynamic>> _cfg;
  final Map<String, TextEditingController> _largoPies = {};
  final Map<String, TextEditingController> _anchoPies = {};
  final Map<String, TextEditingController> _distanciaM = {};
  final Map<String, TextEditingController> _textoManual = {};
  int _tab = 0;
  String _filtro = '';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _cfg = {};
    for (final row in widget.mrpRows) {
      final mat = _matKey(row);
      if (mat.isEmpty) continue;
      final prev = widget.initialConfig[mat];
      _cfg[mat] = Map<String, dynamic>.from(
        prev is Map ? prev : _defaultCfg(row, 'auto'),
      );
      _syncControllers(mat, _cfg[mat]!, _tipoRow(row));
    }
  }

  @override
  void dispose() {
    for (final c in [
      ..._largoPies.values,
      ..._anchoPies.values,
      ..._distanciaM.values,
      ..._textoManual.values,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  String _matKey(Map<String, dynamic> row) {
    final v = row['material_oficial'] ?? row['Material'];
    return v?.toString().trim().toUpperCase() ?? '';
  }

  String _matLabel(Map<String, dynamic> row) {
    final v = row['material_oficial'] ?? row['Material'];
    return v?.toString().trim() ?? '';
  }

  /// Tipo auto-detectado del backend (sin override de usuario).
  String _tipoRow(Map<String, dynamic> row) {
    final t = row['Tipo_Compra']?.toString();
    if (t == 'perfil' || t == 'placa') return t!;
    final u = _matLabel(row).toUpperCase();
    if (u.contains('HSS') || u.contains('PERFIL') || u.contains('TUBO') ||
        u.contains('BARRA') || u.contains('SOLERA') || u.contains('ANGULO') ||
        u.contains('CANAL') || u.contains('REDONDO') || u.contains('REDOND') ||
        u.contains('PTR') || u.contains('IPR') || u.contains('RIEL')) {
      return 'perfil';
    }
    return 'placa';
  }

  /// Tipo efectivo: override del usuario si está configurado, si no auto-detectado.
  String _tipoEfectivo(String mat, Map<String, dynamic> c) {
    final override = c['tipo_compra']?.toString() ?? '';
    if (override == 'placa' || override == 'perfil') return override;
    final row = widget.mrpRows.where((r) => _matKey(r) == mat).firstOrNull;
    if (row == null) return 'perfil';
    return _tipoRow(row);
  }

  Map<String, dynamic>? _formatoById(String id) {
    for (final f in widget.formatos) {
      if (f['id']?.toString() == id) return f;
    }
    return null;
  }

  Map<String, dynamic> _defaultCfg(
    Map<String, dynamic> row,
    String fmtId, {
    String? tipoOverride,
  }) {
    final tipo = tipoOverride ?? _tipoRow(row);
    final fmt = _formatoById(fmtId) ?? _formatoById('auto');
    final c = <String, dynamic>{
      'habilitado': true,
      'formato_id': fmtId,
      'tipo_compra': tipoOverride ?? '',
      'texto': '',
      'auto': row['Sugerencia_Compra_Auto']?.toString() ??
          row['Sugerencia_Compra']?.toString() ??
          '',
    };
    if (tipo == 'placa') {
      c['largo_pies'] = fmt?['largo_pies'] ?? 10.0;
      c['ancho_pies'] = fmt?['ancho_pies'] ?? 4.0;
    } else {
      c['distancia_metros'] = fmt?['distancia_metros'] ?? fmt?['longitud_m'] ?? 6.0;
    }
    return c;
  }

  void _syncControllers(String mat, Map<String, dynamic> c, String tipo) {
    _largoPies.putIfAbsent(
      mat,
      () => TextEditingController(
        text: _numStr(c['largo_pies']),
      ),
    );
    _anchoPies.putIfAbsent(
      mat,
      () => TextEditingController(
        text: _numStr(c['ancho_pies']),
      ),
    );
    _distanciaM.putIfAbsent(
      mat,
      () => TextEditingController(
        text: _numStr(c['distancia_metros']),
      ),
    );
    _textoManual.putIfAbsent(
      mat,
      () => TextEditingController(text: c['texto']?.toString() ?? ''),
    );
    if (tipo == 'placa') {
      _largoPies[mat]!.text = _numStr(c['largo_pies']);
      _anchoPies[mat]!.text = _numStr(c['ancho_pies']);
    } else {
      _distanciaM[mat]!.text = _numStr(c['distancia_metros']);
    }
  }

  String _numStr(dynamic v) {
    if (v == null) return '';
    if (v is num) {
      final d = v.toDouble();
      if (d == d.roundToDouble()) return '${d.toInt()}';
      return d.toString();
    }
    return v.toString();
  }

  double? _parseNum(String s) {
    final t = s.trim().replaceAll(',', '.');
    if (t.isEmpty) return null;
    return double.tryParse(t);
  }

  void _applyFormatoDefaults(String mat, String fmtId) {
    final row = widget.mrpRows.firstWhere((r) => _matKey(r) == mat);
    final c = _cfg[mat]!;
    final tipo = _tipoEfectivo(mat, c);
    final base = _defaultCfg(row, fmtId, tipoOverride: c['tipo_compra']?.toString());
    c['formato_id'] = fmtId;
    if (tipo == 'placa' && fmtId != 'manual' && fmtId != 'directa') {
      c['largo_pies'] = base['largo_pies'];
      c['ancho_pies'] = base['ancho_pies'];
      _largoPies[mat]!.text = _numStr(c['largo_pies']);
      _anchoPies[mat]!.text = _numStr(c['ancho_pies']);
    } else if (tipo == 'perfil' && fmtId != 'manual' && fmtId != 'directa') {
      c['distancia_metros'] = base['distancia_metros'];
      _distanciaM[mat]!.text = _numStr(c['distancia_metros']);
    }
    _cfg[mat] = c;
  }

  List<Map<String, dynamic>> _formatosForTipo(String tipo) {
    // "directa" y "manual" aparecen para todos los tipos.
    return widget.formatos.where((f) {
      final ft = f['tipo']?.toString() ?? '';
      if (ft == 'any' || ft == 'manual' || ft == 'directa') return true;
      return ft == tipo;
    }).toList();
  }

  List<Map<String, dynamic>> get _filteredRows {
    final q = _filtro.trim().toLowerCase();
    return widget.mrpRows.where((row) {
      final key = _matKey(row);
      final c = _cfg[key] ?? {};
      final tipo = _tipoEfectivo(key, c);
      if (_tab == 1 && tipo != 'placa') return false;
      if (_tab == 2 && tipo != 'perfil') return false;
      if (q.isEmpty) return true;
      return _matLabel(row).toLowerCase().contains(q);
    }).toList();
  }

  void _readControllersIntoCfg() {
    for (final e in _cfg.entries) {
      final k = e.key;
      final c = e.value;
      final tipo = _tipoEfectivo(k, c);
      if (tipo == 'placa') {
        c['largo_pies'] = _parseNum(_largoPies[k]?.text ?? '');
        c['ancho_pies'] = _parseNum(_anchoPies[k]?.text ?? '');
        c['distancia_metros'] = null;
      } else {
        c['distancia_metros'] = _parseNum(_distanciaM[k]?.text ?? '');
        c['largo_pies'] = null;
        c['ancho_pies'] = null;
      }
      c['texto'] = _textoManual[k]?.text.trim() ?? '';
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      _readControllersIntoCfg();
      final res = await ApiClient.putUnvalidated(
        '/api/mrp/compra-config',
        headers: {'Content-Type': 'application/json'},
        body: {
          'revision_id': 0,
          'config': _cfg,
        },
      );
      if (res.statusCode != 200) {
        throw Exception('Error ${res.statusCode}: ${res.rawBody}');
      }
      if (mounted) Navigator.pop(context);
      await widget.onSaved();
    } catch (e) {
      if (mounted) {
        displayInfoBar(
          context,
          builder: (context, close) => InfoBar(
            title: const Text('Error al guardar'),
            content: Text('$e'),
            severity: InfoBarSeverity.error,
            onClose: close,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _dimField({
    required String label,
    required String hint,
    required TextEditingController controller,
    required void Function(String) onChanged,
  }) {
    return Expanded(
      child: InfoLabel(
        label: label,
        child: TextBox(
          controller: controller,
          placeholder: hint,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: onChanged,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: const Text('Configurar sugerencias de compra'),
      constraints: const BoxConstraints(maxWidth: 820, maxHeight: 640),
      content: SizedBox(
        width: 780,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Materiales según descripción oficial del catálogo. La configuración '
              'se guarda de forma global para futuros cálculos MRP.\n'
              'Placas: largo y ancho en pies. Perfiles (HSS, tubo, ángulo, redondo): '
              'longitud del tramo en metros.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _tabChip('Todos', 0),
                const SizedBox(width: 6),
                _tabChip('Placas', 1),
                const SizedBox(width: 6),
                _tabChip('Perfiles / HSS', 2),
                const SizedBox(width: 12),
                Expanded(
                  child: TextBox(
                    placeholder: 'Buscar material...',
                    onChanged: (v) => setState(() => _filtro = v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: _filteredRows.length,
                itemBuilder: (context, i) {
                  final row = _filteredRows[i];
                  final key = _matKey(row);
                  final c = _cfg[key] ?? _defaultCfg(row, 'auto');
                  final tipoEf = _tipoEfectivo(key, c);
                  final tipoOverride = c['tipo_compra']?.toString() ?? '';
                  final formatos = _formatosForTipo(tipoEf);
                  final fmtId = c['formato_id']?.toString() ?? 'auto';
                  final isManual = fmtId == 'manual';
                  final isDirecta = fmtId == 'directa';
                  final isPlaca = tipoEf == 'placa' && !isDirecta && !isManual;

                  return Card(
                    padding: const EdgeInsets.all(10),
                    margin: const EdgeInsets.only(bottom: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                _matLabel(row),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            ToggleSwitch(
                              checked: c['habilitado'] != false,
                              onChanged: (v) => setState(() {
                                c['habilitado'] = v;
                                _cfg[key] = c;
                              }),
                              content: const Text('Incluir'),
                            ),
                          ],
                        ),
                        Text(
                          'Auto: ${c['auto'] ?? row['Sugerencia_Compra_Auto'] ?? '—'}',
                          style: TextStyle(
                            fontSize: 11,
                            color: FluentTheme.of(context)
                                .typography
                                .caption
                                ?.color,
                          ),
                        ),
                        const SizedBox(height: 6),
                        // ── Tipo de geometría (override manual) + Formato de compra ──
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            // Tipo de material
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Tipo de material',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: FluentTheme.of(context)
                                        .typography
                                        .caption
                                        ?.color,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                SizedBox(
                                  height: 36,
                                  child: ComboBox<String>(
                                    value: tipoOverride.isEmpty
                                        ? ''
                                        : tipoOverride,
                                    items: const [
                                      ComboBoxItem(
                                        value: '',
                                        child: Text('Auto (según nombre)'),
                                      ),
                                      ComboBoxItem(
                                        value: 'placa',
                                        child: Text('Placa / Lámina'),
                                      ),
                                      ComboBoxItem(
                                        value: 'perfil',
                                        child: Text('Perfil / Tramo'),
                                      ),
                                    ],
                                    onChanged: (v) => setState(() {
                                      final nuevo = v ?? '';
                                      c['tipo_compra'] = nuevo;
                                      // Reset formato si el tipo cambió para evitar valores inválidos
                                      c['formato_id'] = 'auto';
                                      _cfg[key] = c;
                                    }),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(width: 10),
                            // Formato de compra (filtrado según tipo efectivo)
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Formato de compra',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: FluentTheme.of(context)
                                          .typography
                                          .caption
                                          ?.color,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  SizedBox(
                                    height: 36,
                                    child: ComboBox<String>(
                                      isExpanded: true,
                                      value: formatos
                                              .any((f) => f['id'] == fmtId)
                                          ? fmtId
                                          : 'auto',
                                      items: formatos
                                          .map(
                                            (f) => ComboBoxItem(
                                              value: f['id']?.toString() ??
                                                  'auto',
                                              child: Text(
                                                f['etiqueta']?.toString() ??
                                                    f['id']?.toString() ??
                                                    '',
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          )
                                          .toList(),
                                      onChanged: (v) => setState(() {
                                        final id = v ?? 'auto';
                                        _applyFormatoDefaults(key, id);
                                      }),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (isDirecta) ...[
                          // Subensambles: compra directa por pieza (sin área)
                          InfoLabel(
                            label: 'Descripción en la orden (opcional)',
                            child: TextBox(
                              controller: _textoManual[key],
                              placeholder:
                                  'Ej. Seguro de resorte corto — se compra por pza.',
                              onChanged: (v) {
                                c['texto'] = v;
                                _cfg[key] = c;
                              },
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'La cantidad en la orden será igual a la demanda del BOM.',
                            style: TextStyle(
                              fontSize: 10,
                              fontStyle: FontStyle.italic,
                              color: FluentTheme.of(context)
                                  .typography
                                  .caption
                                  ?.color,
                            ),
                          ),
                        ] else if (isManual) ...[
                          InfoLabel(
                            label: 'Orden de compra (texto libre)',
                            child: TextBox(
                              controller: _textoManual[key],
                              placeholder: 'Ej. 12 pz HSS 3x2 3/16"',
                              onChanged: (v) {
                                c['texto'] = v;
                                _cfg[key] = c;
                              },
                            ),
                          ),
                        ] else if (isPlaca) ...[
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _dimField(
                                label: 'Largo (pies)',
                                hint: 'Ej. 10',
                                controller: _largoPies[key]!,
                                onChanged: (v) {
                                  c['largo_pies'] = _parseNum(v);
                                  _cfg[key] = c;
                                },
                              ),
                              const SizedBox(width: 10),
                              _dimField(
                                label: 'Ancho (pies)',
                                hint: 'Ej. 4',
                                controller: _anchoPies[key]!,
                                onChanged: (v) {
                                  c['ancho_pies'] = _parseNum(v);
                                  _cfg[key] = c;
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Área de placa = largo × ancho × 0.0929 m²/pie² '
                            '(usada para calcular cantidad y Excel).',
                            style: TextStyle(
                              fontSize: 10,
                              fontStyle: FontStyle.italic,
                              color: FluentTheme.of(context)
                                  .typography
                                  .caption
                                  ?.color,
                            ),
                          ),
                        ] else ...[
                          InfoLabel(
                            label: 'Distancia del tramo (metros)',
                            child: TextBox(
                              controller: _distanciaM[key]!,
                              placeholder: 'Ej. 12 (HSS) o 6',
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                              onChanged: (v) {
                                c['distancia_metros'] = _parseNum(v);
                                _cfg[key] = c;
                              },
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Cantidad de tramos = ⌈(longitud total BOM × 1.15) / metros⌉.',
                            style: TextStyle(
                              fontSize: 10,
                              fontStyle: FontStyle.italic,
                              color: FluentTheme.of(context)
                                  .typography
                                  .caption
                                  ?.color,
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        Button(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const ProgressRing(strokeWidth: 2)
              : const Text('Guardar y recalcular'),
        ),
      ],
    );
  }

  Widget _tabChip(String label, int index) {
    final selected = _tab == index;
    final accent = FluentTheme.of(context).accentColor;
    return Button(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (selected) return accent;
          return Colors.transparent;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (selected) return Colors.white;
          return null;
        }),
      ),
      onPressed: () => setState(() => _tab = index),
      child: Text(label),
    );
  }
}
