import 'dart:convert';
import 'package:fluent_ui/fluent_ui.dart';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:open_file/open_file.dart';

import '../services/api_client.dart';
import '../services/app_role.dart';
import '../theme/ui_tokens.dart';
import '../widgets/compact_page_header.dart';

class QADashboardScreen extends StatefulWidget {
  const QADashboardScreen({super.key, required this.effectiveRole});

  final String effectiveRole;

  @override
  State<QADashboardScreen> createState() => _QADashboardScreenState();
}

class _QADashboardScreenState extends State<QADashboardScreen> {
  List<dynamic> _reportes = [];
  bool _isLoading = false;
  /// Reporte activo en el panel de detalle (izquierda, ~70%).
  dynamic _selectedReport;
  bool _showHistory = false;
  String _filtroTexto = '';
  String _filtroModulo = 'Todos';
  String _filtroGravedad = 'Todas';
  String _filtroTag = '';
  String _orden = 'Reciente';

  AppRole get _role => parseAppRole(widget.effectiveRole);

  @override
  void initState() {
    super.initState();
    _fetchReportes();
  }

  void _syncSelectionAfterFetch() {
    final visibles = _reportesVisibles();
    if (visibles.isEmpty) {
      _selectedReport = null;
      return;
    }
    final ids = visibles.map((r) => r['id']).toSet();
    final selId = _selectedReport?['id'];
    if (_selectedReport == null || !ids.contains(selId)) {
      _selectedReport = visibles.first;
    }
  }

  List<Map<String, dynamic>> _reportesVisibles() {
    final items = _reportes.whereType<Map>().map((r) {
      return Map<String, dynamic>.from(r.map((k, v) => MapEntry('$k', v)));
    }).toList();
    final txt = _filtroTexto.trim().toLowerCase();
    final tag = _filtroTag.trim().toLowerCase();
    final out = items.where((rep) {
      final modulo = (rep['modulo'] ?? '').toString();
      final gravedad = (rep['gravedad'] ?? '').toString();
      final descripcion = (rep['descripcion'] ?? '').toString();
      final tags = _extraerTags(descripcion).map((e) => e.toLowerCase()).toList();
      if (_filtroModulo != 'Todos' && modulo != _filtroModulo) return false;
      if (_filtroGravedad != 'Todas' && gravedad != _filtroGravedad) return false;
      if (txt.isNotEmpty) {
        final hay = [
          rep['id']?.toString() ?? '',
          modulo,
          gravedad,
          descripcion,
          rep['usuario']?.toString() ?? '',
        ].join(' ').toLowerCase().contains(txt);
        if (!hay) return false;
      }
      if (tag.isNotEmpty && !tags.any((t) => t.contains(tag))) return false;
      return true;
    }).toList();
    int fechaKey(Map<String, dynamic> r) =>
        DateTime.tryParse((r['fecha'] ?? '').toString())?.millisecondsSinceEpoch ?? 0;
    int gravedadKey(String g) {
      final n = g.toLowerCase();
      if (n.contains('cr')) return 0;
      if (n.contains('fal') || n.contains('vis')) return 1;
      return 2;
    }
    if (_orden == 'Reciente') {
      out.sort((a, b) => fechaKey(b).compareTo(fechaKey(a)));
    } else if (_orden == 'Antiguo') {
      out.sort((a, b) => fechaKey(a).compareTo(fechaKey(b)));
    } else if (_orden == 'Prioridad') {
      out.sort((a, b) => gravedadKey((a['gravedad'] ?? '').toString()).compareTo(
            gravedadKey((b['gravedad'] ?? '').toString()),
          ));
    }
    return out;
  }

  Future<void> _fetchReportes() async {
    setState(() => _isLoading = true);
    try {
      final endpoint = _showHistory ? '/api/reportes/historial' : '/api/reportes';
      final res = await ApiClient.getUnvalidated(endpoint);
      if (res.statusCode == 200) {
        setState(() {
          _reportes = res.decodeJson();
          _syncSelectionAfterFetch();
        });
      } else {
        _showError("Error al cargar reportes: ${res.statusCode}");
      }
    } catch (e) {
      _showError("Excepción al cargar: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _exportarExcel() async {
    setState(() => _isLoading = true);
    try {
      final bytes = await ApiClient.getBytes('/api/reportes/exportar');
      final dir = await getDownloadsDirectory();
      final filePath = '${dir?.path ?? "C:\\"}\\Centro_QA_Reportes.xlsx';
      final file = File(filePath);
      await file.writeAsBytes(bytes);

      if (!mounted) return;
      displayInfoBar(
        context,
        builder: (context, close) {
          return InfoBar(
            title: const Text('Exportado Correctamente'),
            content: Text('Guardado en: $filePath'),
            severity: InfoBarSeverity.success,
            action: Button(
              child: const Text("Abrir"),
              onPressed: () => OpenFile.open(filePath),
            ),
            onClose: close,
          );
        },
      );
    } on ApiException catch (_) {
      _showError("Error al exportar a Excel.");
    } catch (e) {
      _showError(e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showError(String message) {
    showDialog(
      context: context,
      builder:
          (context) => ContentDialog(
            title: const Text("Error"),
            content: Text(message),
            actions: [
              Button(
                child: const Text("Cerrar"),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
    );
  }

  Color _gravedadColor(dynamic rep, UiSurfacePalette palette) {
    if (rep['gravedad'] == 'Crítico') return palette.actionDanger;
    if (rep['gravedad'] == 'Falla' || rep['gravedad'] == 'Visual') {
      return palette.actionEdit;
    }
    if (rep['gravedad'] == 'Mejora' || rep['gravedad'] == 'Sugerencia') {
      return palette.actionInfo;
    }
    return palette.textSecondary;
  }

  List<String> _extraerTags(String descripcion) {
    return RegExp(r'#[a-zA-Z0-9_]+')
        .allMatches(descripcion)
        .map((m) => m.group(0) ?? '')
        .where((t) => t.isNotEmpty)
        .toSet()
        .toList();
  }

  Uint8List? _decodeCaptura(dynamic b64) {
    if (b64 == null) return null;
    try {
      return base64Decode(b64.toString());
    } catch (_) {
      return null;
    }
  }

  Widget _buildDetailPanel() {
    final palette = uiSurfacePaletteOf(context);
    if (_selectedReport == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              FluentIcons.touch_pointer,
              size: 64,
              color: palette.textSecondary.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 16),
            Text(
              'Selecciona un reporte en la lista de la derecha',
              style: TextStyle(
                fontSize: 18,
                color: palette.textSecondary,
              ),
            ),
          ],
        ),
      );
    }

    final rep = _selectedReport as Map;
    final bytes = _decodeCaptura(rep['captura_base64']);
    final gravedadColor = _gravedadColor(rep, palette);
    final tags = _extraerTags(rep['descripcion']?.toString() ?? '');

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Imagen grande + zoom (área que el usuario marcó como “vacía” útil)
          Expanded(
            flex: 5,
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: palette.surfaceCard,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: palette.borderSubtle,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: bytes != null
                  ? InteractiveViewer(
                      panEnabled: true,
                      boundaryMargin: const EdgeInsets.all(80),
                      minScale: 1.0,
                      maxScale: 6.0,
                      child: Center(
                        child: Image.memory(
                          bytes,
                          fit: BoxFit.contain,
                        ),
                      ),
                    )
                  : Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            FluentIcons.photo2,
                            size: 72,
                            color: palette.textSecondary.withValues(alpha: 0.55),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'Este reporte no incluye captura de pantalla',
                            style: TextStyle(fontSize: 16),
                          ),
                        ],
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 16),
          // Texto legible debajo de la imagen
          Expanded(
            flex: 2,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '#${rep['id']}',
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _chip(
                              rep['modulo']?.toString() ?? 'General',
                              palette.textPrimary,
                            ),
                            _chip(
                              rep['gravedad']?.toString().toUpperCase() ?? 'N/A',
                              Colors.white,
                              background: gravedadColor,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    rep['descripcion']?.toString() ?? 'Sin descripción',
                    style: const TextStyle(
                      fontSize: 18,
                      height: 1.45,
                    ),
                  ),
                  if (tags.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final t in tags)
                          _chip(t, palette.textPrimary, background: palette.surfaceElevated),
                      ],
                    ),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Icon(
                        FluentIcons.calendar,
                        size: 20,
                        color: fluentSecondaryTextColor(context)
                            .withValues(alpha: 0.9),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        rep['fecha']?.toString() ?? '—',
                        style: TextStyle(
                          fontSize: 16,
                          color: fluentSecondaryTextColor(context),
                        ),
                      ),
                      const SizedBox(width: 24),
                      Icon(
                        FluentIcons.contact_info,
                        size: 20,
                        color: fluentSecondaryTextColor(context)
                            .withValues(alpha: 0.9),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          rep['usuario']?.toString() ?? 'Desconocido',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Estado: ${rep['estado']?.toString() ?? 'Pendiente de revisión'}',
                    style: TextStyle(
                      fontSize: 15,
                      fontStyle: FontStyle.italic,
                      color: palette.actionEdit,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      if (!_showHistory) ...[
                        FilledButton(
                          onPressed: () => _resolverReporte(rep['id'] as int),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            child: Text('Completado (corregido)'),
                          ),
                        ),
                        Button(
                          onPressed: () => _rechazarReporte(rep['id'] as int),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            child: Text('Rechazado (duplicado / no aplica)'),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String text, Color? fg, {Color? background}) {
    final palette = uiSurfacePaletteOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: background ?? palette.surfaceElevated,
        border: Border.all(color: palette.borderSubtle.withValues(alpha: 0.9)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: fg ?? Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildMasterList() {
    final palette = uiSurfacePaletteOf(context);
    final visibles = _reportesVisibles();
    return Container(
      decoration: BoxDecoration(
        color: palette.surfaceBase,
        border: Border(
          left: BorderSide(
            color: palette.borderSubtle,
          ),
        ),
      ),
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(10, 8, 16, 16),
        itemCount: visibles.length,
        itemBuilder: (context, index) {
          final rep = visibles[index];
          final selected =
              _selectedReport != null && _selectedReport['id'] == rep['id'];
          final thumb = _decodeCaptura(rep['captura_base64']);
          final gravedadColor = _gravedadColor(rep, palette);

          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Card(
              padding: const EdgeInsets.all(10),
              backgroundColor: selected
                  ? FluentTheme.of(context).accentColor.withValues(alpha: 0.12)
                  : palette.surfaceCard,
              child: GestureDetector(
                onTap: () => setState(() => _selectedReport = rep),
                behavior: HitTestBehavior.opaque,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (thumb != null)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Image.memory(
                              thumb,
                              width: 56,
                              height: 56,
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                            ),
                          )
                        else
                          Container(
                            width: 56,
                            height: 56,
                            decoration: BoxDecoration(
                              color: palette.surfaceElevated,
                              border: Border.all(
                                color: palette.borderSubtle.withValues(alpha: 0.9),
                              ),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Icon(
                              FluentIcons.photo2,
                              color: palette.textSecondary.withValues(alpha: 0.6),
                            ),
                          ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    '#${rep['id']}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: gravedadColor,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      rep['gravedad']
                                              ?.toString()
                                              .toUpperCase() ??
                                          'N/A',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                        color: FluentTheme.of(
                                          context,
                                        ).typography.bodyStrong?.color,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                rep['modulo'] ?? 'General',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: palette.textSecondary,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                rep['descripcion'] ?? '',
                                style: const TextStyle(fontSize: 12),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          rep['fecha'] ?? '',
                          style: TextStyle(
                            fontSize: 11,
                            color: palette.textSecondary,
                          ),
                        ),
                        if (!_showHistory)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Tooltip(
                                message: 'Completado',
                                child: Button(
                                  onPressed: () => _resolverReporte(rep['id']),
                                  child: const Icon(
                                    FluentIcons.check_mark,
                                    size: 14,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              Tooltip(
                                message: 'Rechazado',
                                child: Button(
                                  onPressed: () => _rechazarReporte(rep['id']),
                                  child: Icon(
                                    FluentIcons.cancel,
                                    size: 14,
                                    color: palette.actionDanger,
                                  ),
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _resolverReporte(int id) async {
    setState(() => _isLoading = true);
    try {
      final res = await ApiClient.putUnvalidated('/api/reportes/$id/resolver');
      if (res.statusCode == 200) {
        await _fetchReportes();
      } else {
        _showError("Error al completar: ${res.statusCode}");
        if (mounted) setState(() => _isLoading = false);
      }
    } catch (e) {
      _showError("Excepción: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _rechazarReporte(int id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => ContentDialog(
        title: const Text('Rechazar reporte'),
        content: const Text(
          'Se marcará como rechazado (duplicado, no reproducible o fuera de alcance). '
          'Desaparecerá de la bandeja.',
        ),
        actions: [
          Button(
            child: const Text('Cancelar'),
            onPressed: () => Navigator.pop(ctx, false),
          ),
          FilledButton(
            child: const Text('Rechazar'),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _isLoading = true);
    try {
      final res = await ApiClient.putUnvalidated('/api/reportes/$id/rechazar');
      if (res.statusCode == 200) {
        await _fetchReportes();
      } else {
        _showError('Error al rechazar: ${res.statusCode}');
        if (mounted) setState(() => _isLoading = false);
      }
    } catch (e) {
      _showError('Excepción: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _dialogoLimpiarHistorialReportes() async {
    if (!_role.qaCanPurgeDb) return;
    final ctrl = TextEditingController();
    try {
      final masterPwd = await showDialog<String?>(
        context: context,
        builder: (ctx) => ContentDialog(
          title: const Text('Limpiar historial de reportes QA'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Se eliminan de la base los reportes en estado Cerrado o Rechazado. '
                'Los abiertos no se tocan.',
              ),
              const SizedBox(height: 12),
              TextBox(
                controller: ctrl,
                obscureText: true,
                placeholder: 'Contraseña maestra',
              ),
            ],
          ),
          actions: [
            Button(
              child: const Text('Cancelar'),
              onPressed: () => Navigator.pop(ctx),
            ),
            FilledButton(
              child: const Text('Borrar historial'),
              onPressed: () => Navigator.pop(ctx, ctrl.text),
            ),
          ],
        ),
      );
      if (masterPwd != null && masterPwd.isNotEmpty && mounted) {
        try {
          final body = await ApiClient.delete(
            '/api/reportes/limpiar_historial',
            headers: {ApiClient.adminMasterPasswordHeader: masterPwd},
          );
          final n =
              body is Map && body['borradas'] != null
                  ? body['borradas'].toString()
                  : '?';
          if (mounted) {
            displayInfoBar(
              context,
              builder: (c, close) => InfoBar(
                title: const Text('Historial QA'),
                content: Text('Filas eliminadas: $n'),
                severity: InfoBarSeverity.success,
                onClose: close,
              ),
            );
          }
        } catch (e) {
          if (mounted) _showError('$e');
        }
      }
    } finally {
      ctrl.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = uiSurfacePaletteOf(context);
    final visibles = _reportesVisibles();
    final modulos = <String>{
      'Todos',
      ..._reportes
          .map((e) => (e is Map ? e['modulo'] : null)?.toString() ?? '')
          .where((e) => e.isNotEmpty),
    }.toList()
      ..sort();
    final gravedades = <String>{
      'Todas',
      ..._reportes
          .map((e) => (e is Map ? e['gravedad'] : null)?.toString() ?? '')
          .where((e) => e.isNotEmpty),
    }.toList()
      ..sort();
    return ScaffoldPage(
      padding: const EdgeInsets.only(top: 8),
      header: CompactPageHeader(
        title: Text(
          "Centro de QA y Reportes",
          style: FluentTheme.of(context).typography.title,
        ),
        commandBar: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(FluentIcons.refresh),
              onPressed: _fetchReportes,
            ),
            const SizedBox(width: 8),
            ToggleSwitch(
              checked: _showHistory,
              content: Text(_showHistory ? 'Historial' : 'Abiertos'),
              onChanged: (v) {
                setState(() => _showHistory = v);
                _fetchReportes();
              },
            ),
            if (_role.qaCanPurgeDb) ...[
              const SizedBox(width: 4),
              Tooltip(
                message: 'Borrar reportes cerrados/rechazados en BD',
                child: IconButton(
                  icon: const Icon(FluentIcons.delete),
                  onPressed: _dialogoLimpiarHistorialReportes,
                ),
              ),
            ],
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _exportarExcel,
              child: const Row(
                children: [
                  Icon(FluentIcons.excel_document),
                  SizedBox(width: 8),
                  Text("Exportar a Excel"),
                ],
              ),
            ),
          ],
        ),
      ),
      content: Container(
        color: palette.surfaceBase,
        child:
            _isLoading
                ? const Center(child: ProgressRing())
                : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          SizedBox(
                            width: 260,
                            child: TextBox(
                              placeholder: 'Buscar por ID, usuario, texto...',
                              onChanged: (v) => setState(() {
                                _filtroTexto = v;
                                _syncSelectionAfterFetch();
                              }),
                            ),
                          ),
                          SizedBox(
                            width: 220,
                            child: ComboBox<String>(
                              isExpanded: true,
                              value: modulos.contains(_filtroModulo) ? _filtroModulo : 'Todos',
                              items: modulos
                                  .map((m) => ComboBoxItem(value: m, child: Text(m)))
                                  .toList(),
                              onChanged: (v) => setState(() {
                                _filtroModulo = v ?? 'Todos';
                                _syncSelectionAfterFetch();
                              }),
                            ),
                          ),
                          SizedBox(
                            width: 150,
                            child: ComboBox<String>(
                              isExpanded: true,
                              value: gravedades.contains(_filtroGravedad) ? _filtroGravedad : 'Todas',
                              items: gravedades
                                  .map((g) => ComboBoxItem(value: g, child: Text(g)))
                                  .toList(),
                              onChanged: (v) => setState(() {
                                _filtroGravedad = v ?? 'Todas';
                                _syncSelectionAfterFetch();
                              }),
                            ),
                          ),
                          SizedBox(
                            width: 180,
                            child: TextBox(
                              placeholder: 'Filtrar hashtag (#lento)',
                              onChanged: (v) => setState(() {
                                _filtroTag = v;
                                _syncSelectionAfterFetch();
                              }),
                            ),
                          ),
                          SizedBox(
                            width: 130,
                            child: ComboBox<String>(
                              value: _orden,
                              isExpanded: true,
                              items: const [
                                ComboBoxItem(value: 'Reciente', child: Text('Reciente')),
                                ComboBoxItem(value: 'Antiguo', child: Text('Antiguo')),
                                ComboBoxItem(value: 'Prioridad', child: Text('Prioridad')),
                              ],
                              onChanged: (v) => setState(() {
                                _orden = v ?? 'Reciente';
                                _syncSelectionAfterFetch();
                              }),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child:
                          visibles.isEmpty
                              ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      FluentIcons.party_leader,
                                      size: 80,
                                      color: const Color(0xFF22C55E),
                                    ),
                                    const SizedBox(height: 20),
                                    Text(
                                      _reportes.isEmpty
                                          ? (_showHistory
                                              ? 'Sin historial de reportes cerrados/rechazados.'
                                              : '¡Bandeja limpia! No hay reportes de QA pendientes.')
                                          : 'No hay reportes que coincidan con los filtros.',
                                      style: TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.w600,
                                        color: palette.textPrimary,
                                      ),
                                    ),
                                  ],
                                ),
                              )
                              : Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(
                                    flex: 7,
                                    child: _buildDetailPanel(),
                                  ),
                                  Expanded(
                                    flex: 3,
                                    child: _buildMasterList(),
                                  ),
                                ],
                              ),
                    ),
                  ],
                ),
      ),
    );
  }
}
