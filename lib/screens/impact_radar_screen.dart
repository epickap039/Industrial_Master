import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as material;
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api_client.dart';
import '../widgets/compact_page_header.dart';
import 'monitoreo/widgets/manual_mission_form_dialog.dart'
    show kResponsablesMisionFallback;
import 'monitoreo/widgets/task_display_utils.dart'
    show kGrupoImpactoMaterial, kGrupoJerarquiaIndefinida;

class ImpactRadarScreen extends StatefulWidget {
  const ImpactRadarScreen({super.key});

  @override
  State<ImpactRadarScreen> createState() => _ImpactRadarScreenState();
}

class _ImpactRadarScreenState extends State<ImpactRadarScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<String> _listaUsernames = List<String>.from(kResponsablesMisionFallback);
  String? _usuarioMisionSeleccionado;
  String _prefsUsername = '';
  bool _isLoading = false;
  String _currentPiece = "";

  // Resultados agrupados: Map<Cliente, Map<Proyecto/Lista, List<Ensamble>>>
  Map<String, Map<String, List<dynamic>>> _groupedResults = {};
  
  bool _afectaRelaciones = false;
  bool _simulando = false;
  bool _creandoTarea = false;
  Map<String, dynamic>? _simulacion;
  /// Minutos atribuibles por ensamble (panel derecho), desde última simulación.
  final Map<int, int> _minutosPorEnsamble = {};
  /// Piezas del análisis presentes en cada ensamble (última simulación).
  final Map<int, List<String>> _piezasPorEnsamble = {};
  final material.ScrollController _splitLeftScroll = material.ScrollController();
  final material.ScrollController _splitRightScroll = material.ScrollController();

  @override
  void initState() {
    super.initState();
    _usuarioMisionSeleccionado = _listaUsernames.first;
    _cargarUsuariosMision();
  }

  String? _defaultResponsableParaLista(List<String> names) {
    if (names.isEmpty) return null;
    if (_prefsUsername.isNotEmpty && names.contains(_prefsUsername)) {
      return _prefsUsername;
    }
    return names.first;
  }

  Future<void> _cargarUsuariosMision() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _prefsUsername = (prefs.getString('username') ?? '').trim();
      final raw = await ApiClient.get('/api/usuarios/lista');
      if (!mounted) return;
      List<String> names = List<String>.from(kResponsablesMisionFallback);
      if (raw is List && raw.isNotEmpty) {
        final fromApi = raw
            .map((e) => Map<String, dynamic>.from(e as Map))
            .map((u) => '${u['username'] ?? ''}'.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        if (fromApi.isNotEmpty) names = fromApi;
      }
      setState(() {
        _listaUsernames = names;
        _usuarioMisionSeleccionado = _defaultResponsableParaLista(names);
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _listaUsernames = List<String>.from(kResponsablesMisionFallback);
          _usuarioMisionSeleccionado =
              _defaultResponsableParaLista(_listaUsernames);
        });
      }
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _splitLeftScroll.dispose();
    _splitRightScroll.dispose();
    super.dispose();
  }

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
    if (codes.isEmpty) {
      displayInfoBar(
        context,
        builder: (c, close) => InfoBar(
          title: const Text('Código requerido'),
          content: const Text('Escriba al menos un código de pieza y pulse Escanear.'),
          severity: InfoBarSeverity.warning,
          action: IconButton(icon: const Icon(FluentIcons.clear), onPressed: close),
        ),
      );
      return;
    }

    setState(() {
      _isLoading = true;
      _currentPiece = codes.join(', ');
      _groupedResults = {};
      _simulacion = null;
      _minutosPorEnsamble.clear();
      _piezasPorEnsamble.clear();
    });

    try {
      final List<dynamic> data = await ApiClient.post(
        '/api/bom/where-used',
        body: {'codigo_pieza': codes.join(', ')},
      ) as List<dynamic>;

      final tempGrouped = <String, Map<String, List<dynamic>>>{};

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
        }
      }

      setState(() {
        _groupedResults = tempGrouped;
      });
    } catch (e) {
      _showError("No se pudo conectar al servidor: $e");
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _limpiarPantalla() {
    _searchController.clear();
    setState(() {
      _currentPiece = "";
      _groupedResults = {};
      _afectaRelaciones = false;
      _simulacion = null;
      _minutosPorEnsamble.clear();
      _piezasPorEnsamble.clear();
      _usuarioMisionSeleccionado =
          _defaultResponsableParaLista(_listaUsernames);
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

  Future<void> _abrirConfigTiemposRadar() async {
    Map<String, dynamic> cfg = {};
    try {
      final raw = await ApiClient.get('/api/bom/impacto/tiempos-config');
      if (raw is Map) {
        cfg = Map<String, dynamic>.from(raw);
      }
    } catch (e) {
      _showError('No se pudo cargar la configuración: $e');
      return;
    }
    if (!mounted) return;

    final ens = TextEditingController(
      text: '${cfg['minutos_plano_ensamble'] ?? 20}',
    );
    final pdf = TextEditingController(text: '${cfg['minutos_pdf'] ?? 5}');
    final rel = TextEditingController(
      text: '${cfg['minutos_por_relacion_unidad'] ?? 5}',
    );
    final eDraw = TextEditingController(
      text: '${cfg['minutos_e_drawings_por_proyecto'] ?? 30}',
    );
    final planoPieza = TextEditingController(
      text: '${cfg['minutos_plano_pieza'] ?? 5}',
    );
    final drive = TextEditingController(
      text: '${cfg['minutos_subir_drive'] ?? 10}',
    );

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return ContentDialog(
          title: const Text('Tiempos estimados (Radar de impacto)'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                InfoLabel(
                  label: 'Minutos por plano de ensamble',
                  child: TextBox(controller: ens),
                ),
                const SizedBox(height: 12),
                InfoLabel(
                  label: 'Minutos por PDF (referencia)',
                  child: TextBox(controller: pdf),
                ),
                const SizedBox(height: 8),
                Text(
                  'Relación de posición: si en la simulación activas «Afecta relaciones de posición», '
                  'a cada ensamble se le suma: minutos de arriba + (este valor × cantidad de piezas '
                  'en el ensamble, redondeada hacia arriba).',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.3,
                    color: FluentTheme.of(ctx).typography.body?.color?.withValues(alpha: 0.72),
                  ),
                ),
                const SizedBox(height: 12),
                InfoLabel(
                  label: 'Minutos por unidad de relación (solo con «Afecta relaciones»)',
                  child: TextBox(controller: rel),
                ),
                const SizedBox(height: 16),
                Text(
                  'Tiempos estándar globales (se suman al total estimado)',
                  style: FluentTheme.of(ctx).typography.bodyStrong?.copyWith(
                        fontSize: 13,
                      ),
                ),
                const SizedBox(height: 10),
                InfoLabel(
                  label: 'E-Drawings: minutos por proyecto distinto (tracto + tipo)',
                  child: TextBox(controller: eDraw),
                ),
                const SizedBox(height: 12),
                InfoLabel(
                  label: 'Plano de la pieza (una sola vez por análisis)',
                  child: TextBox(controller: planoPieza),
                ),
                const SizedBox(height: 12),
                InfoLabel(
                  label: 'Subir a Drive (una sola vez por análisis)',
                  child: TextBox(controller: drive),
                ),
              ],
            ),
          ),
          actions: [
            Button(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () async {
                final pe = int.tryParse(ens.text.trim()) ?? 0;
                final pp = int.tryParse(pdf.text.trim()) ?? 0;
                final pr = int.tryParse(rel.text.trim()) ?? 0;
                final ed = int.tryParse(eDraw.text.trim()) ?? 0;
                final ppz = int.tryParse(planoPieza.text.trim()) ?? 0;
                final dr = int.tryParse(drive.text.trim()) ?? 0;
                try {
                  await ApiClient.put(
                    '/api/bom/impacto/tiempos-config',
                    body: {
                      'minutos_plano_ensamble': pe,
                      'minutos_pdf': pp,
                      'minutos_por_relacion_unidad': pr,
                      'minutos_e_drawings_por_proyecto': ed,
                      'minutos_plano_pieza': ppz,
                      'minutos_subir_drive': dr,
                    },
                  );
                  if (ctx.mounted) Navigator.pop(ctx);
                  if (!mounted) return;
                  displayInfoBar(
                    context,
                    builder: (c, close) => InfoBar(
                      title: const Text('Guardado'),
                      content: Text(
                        _currentPiece.isEmpty
                            ? 'Valores guardados en el servidor.'
                            : 'Valores guardados; simulación actualizada.',
                      ),
                      severity: InfoBarSeverity.success,
                      action:
                          IconButton(icon: const Icon(FluentIcons.clear), onPressed: close),
                    ),
                  );
                  if (_currentPiece.isNotEmpty) await _evaluarImpacto();
                } catch (e) {
                  _showError('No se pudo guardar: $e');
                }
              },
              child: const Text('Guardar'),
            ),
          ],
        );
      },
    );
    ens.dispose();
    pdf.dispose();
    rel.dispose();
    eDraw.dispose();
    planoPieza.dispose();
    drive.dispose();
  }

  /// El [Checkbox] de fluent_ui une caja + [content] en un `Row(mainAxisSize: min)`,
  /// así el texto no recibe límite de ancho y overflow (p. ej. tema Cyberpunk con fuente ancha).
  /// Sin [content]: fila propia con [Expanded] para la etiqueta.
  Widget _globalTaskRow({
    required bool value,
    ValueChanged<bool?>? onChanged,
    required String label,
  }) {
    void toggle() {
      if (onChanged != null) onChanged(!value);
    }

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
                style: TextStyle(
                  color: onChanged == null ? material.Colors.grey : null,
                ),
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
        padding: const EdgeInsets.all(14),
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
            const SizedBox(height: 14),
            _globalTaskRow(
              value: _afectaRelaciones,
              onChanged: _simulacion == null ? null : (v) async {
                setState(() => _afectaRelaciones = v ?? false);
                if (_currentPiece.isNotEmpty && !_simulando) {
                  await _evaluarImpacto();
                }
              },
              label: 'Afecta relaciones de posición (efecto dominó)',
            ),
            if (_simulacion != null) ...[
              _buildTiemposEstandarBloque(),
              const SizedBox(height: 12),
              SizedBox(
                height: 46,
                child: FilledButton(
                  onPressed: _creandoTarea ? null : _generarTareaIngenieria,
                  style: ButtonStyle(
                    shape: WidgetStatePropertyAll(
                      RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  child: _creandoTarea
                      ? const ProgressRing(strokeWidth: 2)
                      : const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(FluentIcons.rocket, size: 16),
                            SizedBox(width: 8),
                            Text(
                              'Asignar tarea',
                              style: TextStyle(fontWeight: FontWeight.w700),
                            ),
                          ],
                        ),
                ),
              ),
            ],
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
      final sinVig = res['sin_bom_aprobada_vigente'] == true;
      final msg = '${res['mensaje_alerta'] ?? ''}'.trim();
      if (mounted && sinVig) {
        displayInfoBar(
          context,
          builder: (c, close) => InfoBar(
            title: const Text('Sin listas aprobadas vigentes'),
            content: Text(
              msg.isNotEmpty
                  ? msg
                  : 'No hay BOM con Estado Aprobada y Es_Vigente = 1 para estos códigos.',
            ),
            severity: InfoBarSeverity.warning,
            action: IconButton(icon: const Icon(FluentIcons.clear), onPressed: close),
          ),
        );
      }
    } catch (e) {
      _showError('Simulación fallida: $e');
    } finally {
      if (mounted) setState(() => _simulando = false);
    }
  }

  Future<void> _generarTareaIngenieria() async {
    if (_simulacion == null) return;
    final tituloCtrl = material.TextEditingController();
    final descCtrl = material.TextEditingController();

    String usrSel = _usuarioMisionSeleccionado ?? (_listaUsernames.isNotEmpty ? _listaUsernames.first : '');

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
              title: const Text('Asignar Tarea de Ingeniería'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  InfoLabel(
                    label: 'Responsable de la misión',
                    child: ComboBox<String>(
                      value: usrSel.isEmpty ? null : usrSel,
                      isExpanded: true,
                      placeholder: const Text('Seleccionar usuario'),
                      items: _listaUsernames
                          .map((e) => ComboBoxItem<String>(value: e, child: Text(e)))
                          .toList(),
                      onChanged: (v) => setLocal(() => usrSel = v ?? ''),
                    ),
                  ),
                  const SizedBox(height: 16),
                  material.TextField(
                    controller: tituloCtrl,
                    autofocus: true,
                    style: material.TextStyle(
                      color: material.Theme.of(context).textTheme.bodyLarge?.color,
                    ),
                    decoration: _inputDecTituloCambio(context),
                    onChanged: (_) => setLocal(() {}),
                  ),
                  const SizedBox(height: 12),
                  material.TextField(
                    controller: descCtrl,
                    maxLines: 3,
                    style: material.TextStyle(
                      color: material.Theme.of(context).textTheme.bodyLarge?.color,
                    ),
                    decoration: material.InputDecoration(
                      labelText: 'Descripción de la misión',
                      hintText: 'Contexto para el responsable (opcional)',
                      border: const material.OutlineInputBorder(),
                      labelStyle: material.TextStyle(
                        color: material.Theme.of(context).hintColor,
                      ),
                    ),
                    onChanged: (_) => setLocal(() {}),
                  ),
                ],
              ),
              actions: [
                material.TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancelar'),
                ),
                material.FilledButton(
                  onPressed: tituloCtrl.text.trim().isEmpty || usrSel.isEmpty
                      ? null
                      : () => Navigator.pop(ctx, true),
                  child: const Text('Confirmar Asignación'),
                ),
              ],
            );
          },
        );
      },
    );
    if (ok != true) {
      tituloCtrl.dispose();
      descCtrl.dispose();
      return;
    }
    final tituloCambio = tituloCtrl.text.trim();
    final descMision = descCtrl.text.trim();
    tituloCtrl.dispose();
    descCtrl.dispose();
    if (tituloCambio.isEmpty) return;

    setState(() => _creandoTarea = true);
    try {
      final entregables = (_simulacion!['entregables'] as List<dynamic>? ?? [])
          .where((raw) {
            final e = Map<String, dynamic>.from(raw as Map);
            final n = '${e['nombre'] ?? ''}'.toLowerCase();
            if (n.contains('e-drawing') || n.contains('edrawing')) return false;
            if (n.contains('drive')) return false;
            final t = n.trim();
            if (t == 'pdf' || t.startsWith('pdf ')) return false;
            return true;
          })
          .map((raw) {
            final e = Map<String, dynamic>.from(raw as Map);
            final g = e['grupo']?.toString().trim();
            final ts = e['texto_secundario']?.toString().trim() ?? '';
            return {
              'nombre': e['nombre']?.toString() ?? 'Tarea',
              'minutos': e['minutos'] is int
                  ? e['minutos']
                  : int.tryParse('${e['minutos']}') ?? 0,
              'grupo': (g != null && g.isNotEmpty) ? g : kGrupoJerarquiaIndefinida,
              if (ts.isNotEmpty) 'texto_secundario': ts,
            };
          })
          .toList();
      // Checklist global fijo para misiones Radar (no depende de ensambles puntuales).
      const extrasRadar = <String>[
        'E-Drawings',
        'Planos de ensamble',
        'Actualizar listas',
        'Subir a Drive',
        'Mandar correo',
      ];
      final ya = entregables
          .map((e) => '${e['nombre'] ?? ''}'.trim().toLowerCase())
          .where((s) => s.isNotEmpty)
          .toSet();
      for (final n in extrasRadar) {
        if (ya.contains(n.toLowerCase())) continue;
        entregables.add({
          'nombre': n,
          'minutos': 0,
          'grupo': kGrupoImpactoMaterial,
        });
      }
      await ApiClient.post(
        '/api/tareas/crear',
        body: {
          'tipo': 'RADAR',
          'titulo': tituloCambio,
          'descripcion': descMision.isNotEmpty
              ? descMision
              : 'Generada desde simulación de Radar de Impacto',
          'codigo_pieza': _currentPiece,
          'minutos_estimados': _simulacion!['total_minutos'] ?? 0,
          'checklist': entregables,
          'meta': _simulacion,
          'titulo_cambio': tituloCambio,
          'usuario_asignado': usrSel,
        },
      );
      if (!mounted) return;
      _limpiarPantalla();
      displayInfoBar(
        context,
        builder: (c, close) => InfoBar(
          title: const Text('Misión creada'),
          content: Text(
            '🚀 Misión Creada: $tituloCambio asignada a $usrSel',
          ),
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

  /// Vista con buscador + panel (no solo landing): basta con haber escaneado al menos un código.
  bool get _vistaDetalleRadar => _currentPiece.trim().isNotEmpty;

  Widget _directivoBadge(String emoji, int value, String shortLabel) {
    final stroke = FluentTheme.of(context).resources.controlStrokeColorDefault;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: FluentTheme.of(context).accentColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: stroke.withValues(alpha: 0.4)),
      ),
      child: Text(
        '$emoji $value $shortLabel',
        style: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          height: 1.15,
        ),
      ),
    );
  }

  Widget _buildHeroSimulacion() {
    if (_simulacion == null) return const SizedBox.shrink();
    final total = int.tryParse('${_simulacion!['total_minutos'] ?? 0}') ?? 0;
    final impactoMat = _simulacion!['impacto_material']?.toString() ?? '';
    final rd = _simulacion!['resumen_directivo'];
    final int tractos = rd is Map
        ? (int.tryParse('${rd['total_tractos'] ?? 0}') ?? 0)
        : 0;
    final int listas = rd is Map
        ? (int.tryParse('${rd['total_listas'] ?? 0}') ?? 0)
        : 0;
    final int ensambles = rd is Map
        ? (int.tryParse('${rd['total_ensambles'] ?? 0}') ?? 0)
        : 0;
    final int piezasTot = rd is Map
        ? (int.tryParse('${rd['total_piezas_fisicas'] ?? 0}') ?? 0)
        : 0;
    final accent = FluentTheme.of(context).accentColor;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: FluentTheme.of(context).cardColor,
          border: Border.all(
            color: accent.withValues(alpha: 0.55),
            width: 2,
          ),
          boxShadow: [
            BoxShadow(
              color: accent.withValues(alpha: 0.12),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(FluentIcons.chart, color: accent, size: 22),
                const SizedBox(width: 10),
                Text(
                  'Resumen de impacto',
                  style: FluentTheme.of(context).typography.subtitle?.copyWith(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              'Total estimado',
              style: TextStyle(
                fontSize: 12,
                color: FluentTheme.of(context).typography.body?.color?.withValues(alpha: 0.75),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _formatoTiempoTotal(total),
              style: TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w800,
                height: 1.05,
                color: accent,
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _directivoBadge('🚛', tractos, 'Proyectos'),
                _directivoBadge('📋', listas, 'Listas BOM'),
                _directivoBadge('⚙️', ensambles, 'Ensambles'),
                _directivoBadge('📦', piezasTot, 'Piezas totales'),
              ],
            ),
            if (impactoMat.isNotEmpty) ...[
              const SizedBox(height: 18),
              Text(
                'Impacto de material',
                style: FluentTheme.of(context).typography.bodyStrong?.copyWith(
                      fontSize: 14,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                impactoMat,
                style: const TextStyle(fontSize: 13, height: 1.35),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Desglose de E-Drawings / plano pieza / Drive (viene del backend en `tiempos_estandar_radar`).
  /// Solo en columna izquierda (junto a tareas globales) para no duplicar ni ocupar el resumen.
  Widget _buildTiemposEstandarBloque() {
    final raw = _simulacion?['tiempos_estandar_radar'];
    if (raw is! Map) return const SizedBox.shrink();
    final n = int.tryParse('${raw['proyectos_distintos'] ?? 0}') ?? 0;
    final me = int.tryParse('${raw['minutos_e_drawings_total'] ?? 0}') ?? 0;
    final mp = int.tryParse('${raw['minutos_plano_pieza'] ?? 0}') ?? 0;
    final md = int.tryParse('${raw['minutos_subir_drive'] ?? 0}') ?? 0;
    final mpp = int.tryParse('${raw['minutos_por_proyecto_e_drawings'] ?? 0}') ?? 0;
    const fs = 11.5;
    final sub = FluentTheme.of(context).typography.body?.color?.withValues(alpha: 0.78);
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: FluentTheme.of(context).accentColor.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: FluentTheme.of(context).resources.dividerStrokeColorDefault.withValues(alpha: 0.65),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(FluentIcons.clock, size: 15, color: FluentTheme.of(context).accentColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Tiempos estándar (sumados al total)',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'E-Drawings: $me min · $n proyecto(s) × $mpp min/proyecto',
              style: TextStyle(fontSize: fs, height: 1.35, color: sub),
            ),
            const SizedBox(height: 4),
            Text(
              'Plano pieza: $mp min (una vez)',
              style: TextStyle(fontSize: fs, height: 1.35, color: sub),
            ),
            const SizedBox(height: 4),
            Text(
              'Subir a Drive: $md min (una vez)',
              style: TextStyle(fontSize: fs, height: 1.35, color: sub),
            ),
          ],
        ),
      ),
    );
  }

  // Se quitó _buildFloatingMissionBar porque se convirtió en botón en el Header de Resultados
  Widget _buildCompactSearchRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: InfoLabel(
              label: 'Código de pieza',
              child: TextBox(
                controller: _searchController,
                placeholder: 'Ej: JA-001, JA-002',
                onSubmitted: (_) => _escanearImpacto(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionBarInline() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: FluentTheme.of(context).micaBackgroundColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: FluentTheme.of(context).resources.dividerStrokeColorDefault,
          ),
        ),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            Button(
              onPressed: _isLoading ? null : _abrirConfigTiemposRadar,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(FluentIcons.settings, size: 16),
                  SizedBox(width: 6),
                  Text('Configurar minutos'),
                ],
              ),
            ),
            if (_vistaDetalleRadar)
              Button(
                onPressed: _simulando ? null : _evaluarImpacto,
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(FluentIcons.calculator_percentage, size: 16),
                    SizedBox(width: 6),
                    Text('Evaluar impacto'),
                  ],
                ),
              ),
            Button(
              onPressed: _limpiarPantalla,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(FluentIcons.clear, size: 16),
                  SizedBox(width: 6),
                  Text('Limpiar'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLandingGoogle() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                FluentIcons.bullseye_target,
                size: 56,
                color: FluentTheme.of(context).accentColor.withValues(alpha: 0.85),
              ),
              const SizedBox(height: 20),
              Text(
                'Radar de impacto',
                style: FluentTheme.of(context).typography.title?.copyWith(
                      fontSize: 28,
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                'Busca por código de pieza en listas BOM aprobadas',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: FluentTheme.of(context)
                      .typography
                      .body
                      ?.color
                      ?.withValues(alpha: 0.72),
                ),
              ),
              const SizedBox(height: 36),
              TextBox(
                controller: _searchController,
                placeholder: 'Código de pieza…',
                style: const TextStyle(fontSize: 20, height: 1.3),
                onSubmitted: (_) => _escanearImpacto(),
              ),
              const SizedBox(height: 24),
              _radarFilled(
                onPressed: _isLoading ? null : _escanearImpacto,
                child: _isLoading
                    ? const ProgressRing(strokeWidth: 2)
                    : const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(FluentIcons.search, size: 20),
                          SizedBox(width: 10),
                          Text('Escanear impacto'),
                        ],
                      ),
              ),
              if (_currentPiece.isNotEmpty &&
                  !_isLoading &&
                  _groupedResults.isEmpty) ...[
                const SizedBox(height: 28),
                Text(
                  'Sin resultados en listas BOM aprobadas y vigentes para estos códigos.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.grey.withValues(alpha: 0.95),
                    fontSize: 14,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResultadosSplit() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 300,
          child: material.ScrollConfiguration(
            behavior: material.ScrollConfiguration.of(context)
                .copyWith(scrollbars: false),
            child: Scrollbar(
              controller: _splitLeftScroll,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _splitLeftScroll,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildGlobalTasks(),
                  ],
                ),
              ),
            ),
          ),
        ),
        Container(
          width: 1,
          color: FluentTheme.of(context).resources.dividerStrokeColorDefault,
        ),
        Expanded(
          child: _isLoading
              ? const Center(child: ProgressRing())
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_simulacion != null) const SizedBox(height: 10),
                    Expanded(
                      child: Scrollbar(
                        controller: _splitRightScroll,
                        thumbVisibility: true,
                        child: SingleChildScrollView(
                          controller: _splitRightScroll,
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                          child: _buildImpactTree(),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildAssemblyCard(dynamic ensamble) {
    final idRaw = ensamble['id_ensamble'];
    final int idEns = idRaw is int ? idRaw : int.tryParse('$idRaw') ?? 0;
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
      child: Row(
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
    );
  }

  Widget _buildImpactTree() {
    if (_currentPiece.isEmpty && _groupedResults.isEmpty) {
      return const Center(
        child: Text("Ingresa un código de pieza para revelar su impacto estructural.", style: TextStyle(color: Colors.grey)),
      );
    }

    if (_groupedResults.isEmpty) {
      return const Center(
        child: Text(
          'Sin resultados en listas BOM aprobadas y vigentes para estos códigos.',
          style: TextStyle(color: Colors.grey),
          textAlign: TextAlign.center,
        ),
      );
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
        title: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                'Gestor de Misiones — Quest Briefing',
                style: FluentTheme.of(context).typography.title,
              ),
            ),
          ],
        ),
      ),
      content: Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _vistaDetalleRadar
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildCompactSearchRow(),
                            _buildActionBarInline(),
                            if (_simulacion != null) _buildHeroSimulacion(),
                            Expanded(
                              child: Padding(
                                padding: EdgeInsets.zero,
                                child: _buildResultadosSplit(),
                              ),
                            ),
                          ],
                        )
                      : _buildLandingGoogle(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
