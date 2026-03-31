import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as material;

import '../services/api_client.dart';
import '../widgets/compact_page_header.dart';

class ImpactRadarScreen extends StatefulWidget {
  const ImpactRadarScreen({super.key});

  @override
  State<ImpactRadarScreen> createState() => _ImpactRadarScreenState();
}

class _ImpactRadarScreenState extends State<ImpactRadarScreen> {
  final TextEditingController _searchController = TextEditingController();
  bool _isLoading = false;
  String _currentPiece = "";

  // Resultados agrupados: Map<Cliente, Map<Proyecto/Lista, List<Ensamble>>>
  Map<String, Map<String, List<dynamic>>> _groupedResults = {};
  
  // Tareas Globales
  bool _gPlano = false;
  bool _gPdfDxf = false;
  bool _gEdrawing = false;
  bool _gDrive = false;
  bool _afectaRelaciones = false;
  bool _simulando = false;
  bool _creandoTarea = false;
  Map<String, dynamic>? _simulacion;
  /// Minutos atribuibles por ensamble (panel derecho), desde última simulación.
  final Map<int, int> _minutosPorEnsamble = {};
  /// Piezas del análisis presentes en cada ensamble (última simulación).
  final Map<int, List<String>> _piezasPorEnsamble = {};
  /// Plano general por grupo Type (clave = tracto / proyecto / version (Rev…)).
  Map<String, bool> _planoGeneralPorGrupo = {};

  // Checklists Locales: Map<id_ensamble, Map<String, bool>>
  Map<int, Map<String, bool>> _localChecklists = {};

  void _syncGruposPlanoGeneralKeys() {
    final keys = <String>{};
    for (final m in _groupedResults.values) {
      keys.addAll(m.keys);
    }
    final next = <String, bool>{};
    for (final k in keys) {
      next[k] = _planoGeneralPorGrupo[k] ?? true;
    }
    _planoGeneralPorGrupo = next;
  }

  bool get _incluirPlanoGeneralSimulacion =>
      _planoGeneralPorGrupo.isEmpty ||
      _planoGeneralPorGrupo.values.any((v) => v);

  material.InputDecoration _inputDecTituloCambio(BuildContext ctx) {
    final border = material.OutlineInputBorder(
      borderRadius: material.BorderRadius.circular(12.0),
      borderSide: material.BorderSide(color: material.Theme.of(ctx).dividerColor),
    );
    return material.InputDecoration(
      labelText: 'Título del Cambio',
      hintText: 'Ej: Modificación de barrenos',
      contentPadding: const material.EdgeInsets.symmetric(
        vertical: 12.0,
        horizontal: 16.0,
      ),
      border: border,
      enabledBorder: border,
    );
  }

  Widget _radarFilled({
    required VoidCallback? onPressed,
    required Widget child,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: SizedBox(
        width: double.infinity,
        height: 44,
        child: FilledButton(
          onPressed: onPressed,
          child: child,
        ),
      ),
    );
  }

  List<String> _codigosPiezaDesdeCampo() {
    final seen = <String>{};
    final out = <String>[];
    for (final part in _searchController.text.split(',')) {
      final c = part.trim().toUpperCase();
      if (c.isEmpty || seen.contains(c)) continue;
      seen.add(c);
      out.add(c);
    }
    return out;
  }

  Future<void> _escanearImpacto() async {
    final codes = _codigosPiezaDesdeCampo();
    if (codes.isEmpty) return;

    setState(() {
      _isLoading = true;
      _currentPiece = codes.join(', ');
      _groupedResults = {};
      _localChecklists = {};
      _simulacion = null;
      _minutosPorEnsamble.clear();
      _piezasPorEnsamble.clear();
      _planoGeneralPorGrupo = {};
    });

    try {
      final tempGrouped = <String, Map<String, List<dynamic>>>{};

      for (final query in codes) {
        final List<dynamic> data =
            await ApiClient.get('/api/bom/where-used/$query') as List<dynamic>;

        for (var item in data) {
          final cliente = item['cliente'] as String;
          final proyLista =
              "${item['tracto']} / ${item['proyecto']} / ${item['version']} (${item['lista_bom']})";

          if (!tempGrouped.containsKey(cliente)) {
            tempGrouped[cliente] = {};
          }
          if (!tempGrouped[cliente]!.containsKey(proyLista)) {
            tempGrouped[cliente]![proyLista] = [];
          }

          if (!tempGrouped[cliente]![proyLista]!
              .any((e) => e['id_ensamble'] == item['id_ensamble'])) {
            tempGrouped[cliente]![proyLista]!.add(item);

            final idEns = item['id_ensamble'];
            if (!_localChecklists.containsKey(idEns)) {
              _localChecklists[idEns] = {
                'plano_ensamble': false,
                'pdf_ensamble': false,
                'drive': false,
              };
            }
          }
        }
      }

      setState(() {
        _groupedResults = tempGrouped;
        _syncGruposPlanoGeneralKeys();
      });
    } catch (e) {
      _showError("No se pudo conectar al servidor: $e");
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _limpiarPantalla() {
    setState(() {
      _searchController.clear();
      _currentPiece = "";
      _groupedResults = {};
      _localChecklists = {};
      _gPlano = false;
      _gPdfDxf = false;
      _gEdrawing = false;
      _gDrive = false;
      _afectaRelaciones = false;
      _simulacion = null;
      _minutosPorEnsamble.clear();
      _piezasPorEnsamble.clear();
      _planoGeneralPorGrupo = {};
    });
  }

  void _showError(String msg) {
    displayInfoBar(
      context,
      builder: (context, close) => InfoBar(
        title: const Text('Error'),
        content: Text(msg),
        severity: InfoBarSeverity.error,
        action: IconButton(icon: const Icon(FluentIcons.clear), onPressed: close),
      ),
    );
  }

  /// El [Checkbox] de fluent_ui une caja + [content] en un `Row(mainAxisSize: min)`,
  /// así el texto no recibe límite de ancho y overflow (p. ej. tema Cyberpunk con fuente ancha).
  /// Sin [content]: fila propia con [Expanded] para la etiqueta.
  Widget _globalTaskRow({
    required bool value,
    required ValueChanged<bool?> onChanged,
    required String label,
  }) {
    void toggle() => onChanged(!value);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Checkbox(
          checked: value,
          onChanged: onChanged,
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(left: 8, top: 2),
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: toggle,
              child: Text(
                label,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                softWrap: true,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGlobalTasks() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Tareas Globales de la Pieza',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 16),
            _globalTaskRow(
              value: _gPlano,
              onChanged: (v) => setState(() => _gPlano = v ?? false),
              label: 'Actualizar Plano de Pieza (.SLDDRW)',
            ),
            const SizedBox(height: 8),
            _globalTaskRow(
              value: _gPdfDxf,
              onChanged: (v) => setState(() => _gPdfDxf = v ?? false),
              label: 'Exportar nuevo PDF/DXF',
            ),
            const SizedBox(height: 8),
            _globalTaskRow(
              value: _gEdrawing,
              onChanged: (v) => setState(() => _gEdrawing = v ?? false),
              label: 'Exportar E-Drawing',
            ),
            const SizedBox(height: 8),
            _globalTaskRow(
              value: _gDrive,
              onChanged: (v) => setState(() => _gDrive = v ?? false),
              label: 'Reemplazar archivo en Drive',
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _evaluarImpacto() async {
    if (_currentPiece.isEmpty) return;
    setState(() => _simulando = true);
    try {
      final res = await ApiClient.post(
        '/api/bom/impacto/simular',
        body: {
          'codigo_pieza': _currentPiece,
          'afecta_relaciones': _afectaRelaciones,
          'incluir_plano_pieza': _gPlano,
          'incluir_plano_ensamble': true,
          'incluir_pdf_ensamble': _gPdfDxf,
          'incluir_plano_general': _incluirPlanoGeneralSimulacion,
          'incluir_subir_drive': _gDrive,
        },
      ) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _simulacion = res;
        _minutosPorEnsamble.clear();
        _piezasPorEnsamble.clear();
        for (final e in (res['resumen_ensambles'] as List<dynamic>? ?? [])) {
          final m = e as Map<String, dynamic>;
          final id = int.tryParse('${m['id_ensamble']}');
          if (id != null) {
            _minutosPorEnsamble[id] =
                int.tryParse('${m['minutos_estimados'] ?? 0}') ?? 0;
            final raw = m['piezas_especificas_encontradas'];
            if (raw is List) {
              _piezasPorEnsamble[id] = raw.map((x) => '$x').toList();
            }
          }
        }
      });
    } catch (e) {
      _showError('Simulación fallida: $e');
    } finally {
      if (mounted) setState(() => _simulando = false);
    }
  }

  Future<void> _generarTareaIngenieria() async {
    if (_simulacion == null) return;
    final tituloCtrl = material.TextEditingController();
    final ok = await material.showDialog<bool>(
      context: context,
      barrierColor: material.Theme.of(context).brightness == material.Brightness.dark
          ? const material.Color(0xFF121212)
          : material.Colors.white,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setLocal) {
            return material.AlertDialog(
              backgroundColor: material.Theme.of(context).brightness ==
                      material.Brightness.dark
                  ? const material.Color(0xFF121212)
                  : material.Colors.white,
              shape: material.RoundedRectangleBorder(
                borderRadius: material.BorderRadius.circular(20.0),
              ),
              title: const Text('Título del Cambio'),
              content: material.TextField(
                controller: tituloCtrl,
                autofocus: true,
                style: material.TextStyle(
                  color: material.Theme.of(context).textTheme.bodyLarge?.color,
                ),
                decoration: _inputDecTituloCambio(context),
                onChanged: (_) => setLocal(() {}),
              ),
              actions: [
                material.TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancelar'),
                ),
                material.FilledButton(
                  onPressed: tituloCtrl.text.trim().isEmpty
                      ? null
                      : () => Navigator.pop(ctx, true),
                  child: const Text('Continuar'),
                ),
              ],
            );
          },
        );
      },
    );
    if (ok != true) return;
    final tituloCambio = tituloCtrl.text.trim();
    if (tituloCambio.isEmpty) return;

    setState(() => _creandoTarea = true);
    try {
      final entregables = (_simulacion!['entregables'] as List<dynamic>? ?? [])
          .map(
            (e) => {
              'nombre': (e as Map<String, dynamic>)['nombre']?.toString() ?? 'Tarea',
              'minutos': (e)['minutos'] is int
                  ? e['minutos']
                  : int.tryParse('${e['minutos']}') ?? 0,
            },
          )
          .toList();
      await ApiClient.post(
        '/api/tareas/crear',
        body: {
          'tipo': 'RADAR',
          'titulo': tituloCambio,
          'descripcion': 'Generada desde simulación de Radar de Impacto',
          'codigo_pieza': _currentPiece,
          'minutos_estimados': _simulacion!['total_minutos'] ?? 0,
          'checklist': entregables,
          'meta': _simulacion,
          'titulo_cambio': tituloCambio,
        },
      );
      if (!mounted) return;
      displayInfoBar(
        context,
        builder: (c, close) => InfoBar(
          title: const Text('Listo'),
          content: const Text('Tarea de ingeniería creada en Gestor.'),
          severity: InfoBarSeverity.success,
          onClose: close,
        ),
      );
    } catch (e) {
      _showError('No se pudo crear la tarea: $e');
    } finally {
      if (mounted) setState(() => _creandoTarea = false);
    }
  }

  String _formatoTiempoTotal(int totalMin) {
    if (totalMin <= 0) return '0 min';
    final h = totalMin ~/ 60;
    final m = totalMin % 60;
    if (h == 0) return '$m min';
    if (m == 0) return '$h hrs';
    return '$h hrs $m min';
  }

  Widget _buildSimulacionCard() {
    if (_simulacion == null) return const SizedBox.shrink();
    final total = int.tryParse('${_simulacion!['total_minutos'] ?? 0}') ?? 0;
    final entregables = (_simulacion!['entregables'] as List<dynamic>? ?? []);
    final titleStyle = FluentTheme.of(context).typography.title;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Simulación de impacto',
              style: FluentTheme.of(context).typography.bodyStrong,
            ),
            const SizedBox(height: 12),
            Text(
              'Total: ${_formatoTiempoTotal(total)}',
              style: TextStyle(
                fontSize: (titleStyle?.fontSize ?? 22) + 4,
                fontWeight: FontWeight.w600,
                height: 1.2,
              ),
            ),
            const SizedBox(height: 12),
            ...entregables.take(12).map((e) {
              final map = e as Map<String, dynamic>;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text('- ${map['nombre']} (${map['minutos']} min)'),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildAssemblyCard(dynamic ensamble) {
    final int idEns = ensamble['id_ensamble'];
    final checks = _localChecklists[idEns]!;
    final minEns = _minutosPorEnsamble[idEns];

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: FluentTheme.of(context).cardColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: FluentTheme.of(context).resources.dividerStrokeColorDefault,
        ),
      ),
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
                      ensamble['nombre_ensamble'].toString(),
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (minEns != null && minEns > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'Tiempo estimado (ensamble): $minEns min',
                          style: TextStyle(
                            fontSize: 13,
                            color: FluentTheme.of(context).accentColor,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    Builder(
                      builder: (context) {
                        final list = _piezasPorEnsamble[idEns] ?? const <String>[];
                        if (list.isEmpty) {
                          return const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Text(
                              'Piezas detectadas: —',
                              style: TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                          );
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            'Piezas detectadas: ${list.join(', ')} (${list.length} total)',
                            style: const TextStyle(fontSize: 13),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: FluentTheme.of(context).accentColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text('Cant: ${ensamble['cantidad']}'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text('Checklist de Integración:'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              Checkbox(
                checked: checks['plano_ensamble'],
                onChanged: (v) => setState(() => _localChecklists[idEns]!['plano_ensamble'] = v ?? false),
                content: const Text('Plano de Ensamble'),
              ),
              Checkbox(
                checked: checks['pdf_ensamble'],
                onChanged: (v) => setState(() => _localChecklists[idEns]!['pdf_ensamble'] = v ?? false),
                content: const Text('PDF del Ensamble'),
              ),
              Checkbox(
                checked: checks['drive'],
                onChanged: (v) => setState(() => _localChecklists[idEns]!['drive'] = v ?? false),
                content: const Text('Subir a Drive'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildImpactTree() {
    if (_currentPiece.isEmpty && _groupedResults.isEmpty) {
      return const Center(
        child: Text("Ingresa un código de pieza para revelar su impacto estructural.", style: TextStyle(color: Colors.grey)),
      );
    }

    if (_groupedResults.isEmpty) {
       return const Center(child: Text("Pieza no encontrada en ninguna Lista de Materiales (Orphaneada o Error).", style: TextStyle(color: Colors.grey)));
    }

    List<Widget> clienteWidgets = [];
    _groupedResults.forEach((cliente, proyectosMap) {
      List<Widget> proyectoWidgets = [];
      proyectosMap.forEach((proyecto, ensambles) {
        proyectoWidgets.add(
          Padding(
            padding: const EdgeInsets.only(left: 16.0, top: 12.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(FluentIcons.fabric_folder, size: 16, color: Colors.blue),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        proyecto,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Checkbox(
                      checked: _planoGeneralPorGrupo[proyecto] ?? true,
                      content: const Text('Plano General'),
                      onChanged: (v) async {
                        setState(() => _planoGeneralPorGrupo[proyecto] = v ?? false);
                        if (_currentPiece.isNotEmpty && !_simulando) {
                          await _evaluarImpacto();
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(left: 24.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: ensambles.map((e) => _buildAssemblyCard(e)).toList(),
                  ),
                ),
              ],
            ),
          )
        );
      });

      clienteWidgets.add(
        Expander(
          initiallyExpanded: true,
          header: Row(
            children: [
              const Icon(FluentIcons.group, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  cliente,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: proyectoWidgets,
          ),
        )
      );
      clienteWidgets.add(const SizedBox(height: 16));
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: clienteWidgets,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      padding: const EdgeInsets.only(top: 8),
      header: CompactPageHeader(
        title: Text(
          'Radar de Impacto (Where-Used)',
          style: FluentTheme.of(context).typography.title,
        ),
        commandBar: CommandBar(
          mainAxisAlignment: MainAxisAlignment.end,
          primaryItems: [
            CommandBarButton(
              icon: const Icon(FluentIcons.clear),
              label: const Text('Limpiar Pantalla'),
              onPressed: _limpiarPantalla,
            ),
          ],
        ),
      ),
      content: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Panel Izquierdo (scroll completo)
            SizedBox(
              width: 300,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    InfoLabel(
                      label: "Código de Pieza a Analizar",
                      child: TextBox(
                        controller: _searchController,
                        placeholder: "Ej: JA-001, JA-002",
                        onSubmitted: (_) => _escanearImpacto(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _globalTaskRow(
                      value: _afectaRelaciones,
                      onChanged: (v) async {
                        setState(() => _afectaRelaciones = v ?? false);
                        if (_currentPiece.isNotEmpty && !_simulando) {
                          await _evaluarImpacto();
                        }
                      },
                      label: 'Afecta relaciones de posición (Efecto dominó)',
                    ),
                    const SizedBox(height: 16),
                    _radarFilled(
                      onPressed: _isLoading ? null : _escanearImpacto,
                      child: _isLoading
                          ? const ProgressRing(strokeWidth: 2)
                          : Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(FluentIcons.search, size: 18),
                                const SizedBox(width: 8),
                                const Text('Escanear Impacto'),
                              ],
                            ),
                    ),
                    const SizedBox(height: 24),
                    if (_currentPiece.isNotEmpty) _buildGlobalTasks(),
                    const SizedBox(height: 12),
                    _radarFilled(
                      onPressed: (_currentPiece.isEmpty || _simulando) ? null : _evaluarImpacto,
                      child: _simulando
                          ? const ProgressRing(strokeWidth: 2)
                          : Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(FluentIcons.calculator_percentage, size: 18),
                                const SizedBox(width: 8),
                                const Text('Evaluar Impacto'),
                              ],
                            ),
                    ),
                    const SizedBox(height: 12),
                    if (_simulacion != null)
                      _radarFilled(
                        onPressed: _creandoTarea ? null : _generarTareaIngenieria,
                        child: _creandoTarea
                            ? const ProgressRing(strokeWidth: 2)
                            : Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(FluentIcons.task_list, size: 18),
                                  const SizedBox(width: 8),
                                  const Text('Generar Tarea'),
                                ],
                              ),
                      ),
                    const SizedBox(height: 12),
                    _buildSimulacionCard(),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 32),
            // Panel Derecho (Radar Tree)
            Expanded(
              child: _isLoading 
                ? const Center(child: ProgressRing())
                : SingleChildScrollView(child: _buildImpactTree()),
            ),
          ],
        ),
      ),
    );
  }
}
