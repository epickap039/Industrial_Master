import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' show SelectionArea;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api_client.dart';
import '../theme/ui_tokens.dart';
import '../widgets/compact_page_header.dart';

class _BomRevisionOption {
  const _BomRevisionOption({required this.id, required this.label});

  final int id;
  final String label;
}

int _porTipoFromMap(dynamic pt, String key) {
  if (pt is! Map) return 0;
  final v = pt[key];
  if (v is int) return v;
  return int.tryParse('$v') ?? 0;
}

/// Reconciliación: CSV exportado desde SolidWorks (macro) vs BOM en BD.
class BomDespieceScreen extends StatefulWidget {
  const BomDespieceScreen({super.key});

  @override
  State<BomDespieceScreen> createState() => _BomDespieceScreenState();
}

class _BomDespieceScreenState extends State<BomDespieceScreen> {
  final TextEditingController _revisionFilterController = TextEditingController();
  List<_BomRevisionOption> _revisionOptions = [];
  bool _loadingRevisions = false;
  String? _revisionListError;
  int? _selectedRevisionId;

  /// Incluir suprimido=1 (árbol completo). Desactivado por defecto: menos carga y menos filas en diff.
  bool _includeSuppressed = false;
  static const int _maxMuestraFilasApi = 200;
  String? _pickedPath;
  List<int>? _fileBytes;
  String _fileName = '';

  bool _busy = false;
  String? _error;
  Map<String, dynamic>? _result;
  /// Índice del panel lateral de resultados (0=Resumen, 1=mismatch, 2=solo SW, 3=solo lista).
  int _resultSideIndex = 0;
  /// Filas agrupadas por tipo (muestra API acotada); se reconstruye al comparar.
  Map<String, List<Map<String, dynamic>>> _filasPorTipo = {};

  @override
  void initState() {
    super.initState();
    _revisionFilterController.addListener(() {
      if (mounted) setState(() {});
    });
    _loadRevisionPicker();
  }

  @override
  void dispose() {
    _revisionFilterController.dispose();
    super.dispose();
  }

  Future<void> _loadRevisionPicker() async {
    setState(() {
      _loadingRevisions = true;
      _revisionListError = null;
    });
    try {
      final res = await ApiClient.getUnvalidated('/api/mapa/jerarquia');
      if (res.statusCode != 200) {
        throw Exception('HTTP ${res.statusCode}');
      }
      final raw = res.decodeJson();
      if (raw is! List<dynamic>) {
        throw Exception('Formato de jerarquía inesperado.');
      }
      final options = <_BomRevisionOption>[];
      for (final t in raw) {
        if (t is! Map) continue;
        final tracto = t['nombre']?.toString() ?? '?';
        final tipos = t['tipos'];
        if (tipos is! List) continue;
        for (final tp in tipos) {
          if (tp is! Map) continue;
          final tipo = tp['nombre']?.toString() ?? '?';
          final versiones = tp['versiones'];
          if (versiones is! List) continue;
          for (final v in versiones) {
            if (v is! Map) continue;
            final ver = v['nombre']?.toString() ?? '?';
            final revs = v['revisiones'];
            if (revs is! List) continue;
            for (final r in revs) {
              if (r is! Map) continue;
              final id = r['id_revision'];
              final idInt = id is int ? id : int.tryParse(id?.toString() ?? '');
              if (idInt == null || idInt < 1) continue;
              final numRev = r['numero_revision']?.toString() ?? '?';
              final cliente = r['cliente']?.toString() ?? '';
              final label =
                  '$tracto › $tipo › $ver · Rev $numRev · $cliente (ID $idInt)';
              options.add(_BomRevisionOption(id: idInt, label: label));
            }
          }
        }
      }
      options.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
      if (!mounted) return;
      setState(() => _revisionOptions = options);
    } catch (e) {
      if (mounted) {
        setState(() {
          _revisionListError =
              'No se pudo cargar el listado de revisiones: $e';
        });
      }
    } finally {
      if (mounted) setState(() => _loadingRevisions = false);
    }
  }

  List<_BomRevisionOption> _visiblePickerOptions() {
    final q = _revisionFilterController.text.trim().toLowerCase();
    List<_BomRevisionOption> list;
    if (q.isEmpty) {
      list = List<_BomRevisionOption>.from(_revisionOptions);
    } else {
      list = _revisionOptions.where((e) {
        return e.label.toLowerCase().contains(q) ||
            e.id.toString().contains(q);
      }).toList();
    }
    if (_selectedRevisionId != null) {
      final idx = _revisionOptions.indexWhere((e) => e.id == _selectedRevisionId);
      if (idx >= 0) {
        final sel = _revisionOptions[idx];
        if (!list.any((e) => e.id == sel.id)) {
          list = <_BomRevisionOption>[sel, ...list];
        }
      }
    }
    return list;
  }

  Future<String> _prefsUsername() async {
    final prefs = await SharedPreferences.getInstance();
    final u = prefs.getString('username')?.trim();
    return (u != null && u.isNotEmpty) ? u : 'Operador';
  }

  Future<void> _pickCsv() async {
    final r = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['csv'],
      withData: true,
    );
    if (r == null || r.files.isEmpty) return;
    final f = r.files.single;
    setState(() {
      _pickedPath = f.path;
      _fileName = f.name;
      _fileBytes = f.bytes?.toList();
      _error = null;
    });
    if (_fileBytes == null && f.path != null) {
      try {
        final b = await File(f.path!).readAsBytes();
        setState(() => _fileBytes = b);
      } catch (e) {
        setState(() => _error = 'No se pudo leer el archivo: $e');
      }
    }
  }

  Future<void> _compare() async {
    final id = _selectedRevisionId;
    if (id == null || id < 1) {
      setState(() => _error = 'Seleccione la lista de materiales (revisión aprobada) en el desplegable.');
      return;
    }
    final bytes = _fileBytes;
    if (bytes == null || bytes.isEmpty) {
      setState(() => _error = 'Seleccione un CSV exportado desde SolidWorks.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });

    try {
      final user = await _prefsUsername();
      final j = await ApiClient.postMultipart(
        '/api/bom/despiece/compare',
        fields: {
          'id_revision': '$id',
          'include_suppressed': _includeSuppressed ? 'true' : 'false',
          'max_muestra_filas': '$_maxMuestraFilasApi',
        },
        files: {
          'file': http.MultipartFile.fromBytes(
            'file',
            bytes,
            filename: _fileName.isNotEmpty ? _fileName : 'sw_bom.csv',
          ),
        },
        headers: {'X-Usuario': user},
      );
      if (j is Map<String, dynamic>) {
        setState(() {
          _result = j;
          _rebuildFilasPorTipo(j);
          _resultSideIndex = _pickInitialDespieceTab(j);
        });
      } else {
        setState(() => _error = 'Respuesta inesperada del servidor.');
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copyMacro() async {
    try {
      final s = await rootBundle.loadString('assets/sw_bom/export_bom_solidworks.bas');
      await Clipboard.setData(ClipboardData(text: s));
      if (!mounted) return;
      displayInfoBar(
        context,
        builder: (c, close) {
          return InfoBar(
            title: const Text('Listo'),
            content: const Text('Macro copiada al portapapeles. Pégala en el editor VBA de SolidWorks.'),
            severity: InfoBarSeverity.success,
            onClose: close,
          );
        },
      );
    } catch (e) {
      if (!mounted) return;
      displayInfoBar(
        context,
        builder: (c, close) {
          return InfoBar(
            title: const Text('Error'),
            content: Text('No se pudo cargar la macro: $e'),
            severity: InfoBarSeverity.error,
            onClose: close,
          );
        },
      );
    }
  }

  Future<void> _downloadReportCsv() async {
    final id = _selectedRevisionId;
    if (id == null || id < 1) {
      setState(() => _error = 'Seleccione la lista de materiales (revisión aprobada) en el desplegable.');
      return;
    }
    final bytes = _fileBytes;
    if (bytes == null || bytes.isEmpty) {
      setState(() => _error = 'Seleccione el mismo CSV usado para comparar.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final user = await _prefsUsername();
      final out = await ApiClient.postMultipartBytes(
        '/api/bom/despiece/reporte-csv',
        fields: {
          'id_revision': '$id',
          'include_suppressed': _includeSuppressed ? 'true' : 'false',
        },
        files: {
          'file': http.MultipartFile.fromBytes(
            'file',
            bytes,
            filename: _fileName.isNotEmpty ? _fileName : 'sw_bom.csv',
          ),
        },
        headers: {'X-Usuario': user},
      );

      final suggested = 'despiece_rev$id.csv';
      final target = await FilePicker.platform.saveFile(
        dialogTitle: 'Guardar informe de discrepancias',
        fileName: suggested,
        type: FileType.custom,
        allowedExtensions: const ['csv'],
      );
      if (target == null) return;
      var path = target;
      if (!path.toLowerCase().endsWith('.csv')) {
        path = '$path.csv';
      }
      await File(path).writeAsBytes(out, flush: true);
      if (!mounted) return;
      displayInfoBar(
        context,
        builder: (c, close) {
          return InfoBar(
            title: const Text('Guardado'),
            content: Text(path),
            severity: InfoBarSeverity.success,
            onClose: close,
          );
        },
      );
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showAyudaAuditoria(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) {
        return ContentDialog(
          title: const Text('Ayuda — Auditoría de lista de materiales'),
          content: SizedBox(
            width: 520,
            height: 420,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Objetivo',
                    style: FluentTheme.of(ctx).typography.subtitle,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Esta pestaña sirve para auditar la lista de materiales aprobada en el sistema '
                    'frente al despiece exportado desde SolidWorks (CSV de la macro). '
                    'Cada discrepancia muestra cantidades: Lista (BOM) vs Ensamble (CSV), con códigos normalizados.',
                    style: FluentTheme.of(ctx).typography.body,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Incluir componentes suprimidos del CSV',
                    style: FluentTheme.of(ctx).typography.subtitle,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'El CSV incluye la columna suprimido (0 o 1) según el componente esté suprimido '
                    'en el ensamble al exportar.\n\n'
                    '• Desactivado (predeterminado): las filas con suprimido = 1 no se suman en el “ensamble” '
                    'ni entran en la comparación. Así el resultado refleja sobre todo el modelo “activo”, '
                    'alineado con piezas que no están suprimidas en esa configuración.\n\n'
                    '• Activado: también se cuentan las filas suprimidas. Útil si la macro exportó casi todo '
                    'el árbol con suprimido = 1 y sin esto casi no hay filas usables, o si necesita cotejar '
                    'contra un criterio que incluya esas piezas.\n\n'
                    'La opción no cambia la lista aprobada en base de datos; solo define qué filas del CSV '
                    'participan en el diff.',
                    style: FluentTheme.of(ctx).typography.body,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Informe y muestra',
                    style: FluentTheme.of(ctx).typography.subtitle,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'La pantalla puede mostrar una muestra de discrepancias; el botón “Descargar informe CSV” '
                    'genera el listado completo para archivo o Excel.',
                    style: FluentTheme.of(ctx).typography.body,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            FilledButton(
              child: const Text('Cerrar'),
              onPressed: () => Navigator.pop(ctx),
            ),
          ],
        );
      },
    );
  }

  Future<void> _loadSpec() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final j = await ApiClient.get('/api/bom/despiece/spec');
      if (!mounted) return;
      final pretty = const JsonEncoder.withIndent('  ').convert(j);
      await showDialog(
        context: context,
        builder: (c) {
          return ContentDialog(
            title: const Text('Contrato CSV / macro'),
            content: SizedBox(
              width: 520,
              height: 420,
              child: SingleChildScrollView(
                child: SelectableText(pretty),
              ),
            ),
            actions: [
              Button(
                child: const Text('Cerrar'),
                onPressed: () => Navigator.pop(c),
              ),
            ],
          );
        },
      );
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  int _porTipoCount(String key) {
    return _porTipoFromMap(_result?['por_tipo'], key);
  }

  /// Primera vista con filas: cantidad distinta → nuevo en ensamble → solo lista → resumen.
  static int _pickInitialDespieceTab(Map<String, dynamic> j) {
    if (_porTipoFromMap(j['por_tipo'], 'CANTIDAD_MISMATCH') > 0) return 1;
    if (_porTipoFromMap(j['por_tipo'], 'SW_SIN_LISTA') > 0) return 2;
    if (_porTipoFromMap(j['por_tipo'], 'LISTA_SIN_SW') > 0) return 3;
    return 0;
  }

  void _rebuildFilasPorTipo(Map<String, dynamic> j) {
    final out = <String, List<Map<String, dynamic>>>{
      'CANTIDAD_MISMATCH': [],
      'SW_SIN_LISTA': [],
      'LISTA_SIN_SW': [],
    };
    final filas = j['filas'];
    if (filas is List) {
      for (final e in filas) {
        if (e is! Map) continue;
        final row = Map<String, dynamic>.from(e);
        final t = row['tipo']?.toString() ?? '';
        out.putIfAbsent(t, () => []).add(row);
      }
    }
    _filasPorTipo = out;
  }

  Widget _buildAuditoriaSetupBar(BuildContext context) {
    final theme = FluentTheme.of(context);
    final accent = theme.accentColor;
    return Container(
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.resources.controlStrokeColorDefault,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(FluentIcons.check_list, size: 22, color: accent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Origen de la auditoría',
                      style: theme.typography.subtitle?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Lista aprobada + CSV del ensamble (macro). '
                      'En desarrollo — acceso restringido a Ingeniería y Desarrollador. '
                      'Ayuda: suprimidos y criterios.',
                      style: theme.typography.caption,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextBox(
            controller: _revisionFilterController,
            placeholder: 'Filtrar revisión por tracto, versión, cliente o ID…',
          ),
          const SizedBox(height: 8),
          if (_loadingRevisions)
            const Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: ProgressRing(strokeWidth: 2),
              ),
            )
          else
            ComboBox<int>(
              placeholder: const Text(
                'Elija la lista / revisión a auditar…',
                overflow: TextOverflow.ellipsis,
              ),
              value: _selectedRevisionId,
              isExpanded: true,
              items: _visiblePickerOptions().map((o) {
                return ComboBoxItem<int>(
                  value: o.id,
                  child: Tooltip(
                    message: o.label,
                    child: Text(
                      o.label,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                );
              }).toList(),
              onChanged: _busy
                  ? null
                  : (v) {
                      setState(() {
                        _selectedRevisionId = v;
                        _error = null;
                      });
                    },
            ),
          if (_revisionListError != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _revisionListError!,
                style: TextStyle(
                  color: theme.resources.systemFillColorCritical,
                  fontSize: 12,
                ),
              ),
            ),
          if (!_loadingRevisions &&
              _revisionOptions.isEmpty &&
              _revisionListError == null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'No hay revisiones en la jerarquía.',
                style: theme.typography.caption,
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: HyperlinkButton(
              onPressed: _busy || _loadingRevisions ? null : _loadRevisionPicker,
              child: const Text('Actualizar revisiones'),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Button(
                onPressed: _busy ? null : _pickCsv,
                child: const Text('Elegir CSV del ensamble…'),
              ),
              FilledButton(
                onPressed: _busy ? null : _compare,
                child: const Text('Ejecutar auditoría'),
              ),
              Button(
                onPressed: _busy ? null : _downloadReportCsv,
                child: const Text('Descargar informe CSV'),
              ),
            ],
          ),
          if (_pickedPath != null || _fileName.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SelectableText(
                'CSV: ${_fileName.isNotEmpty ? _fileName : _pickedPath}',
                style: theme.typography.caption,
              ),
            ),
          const SizedBox(height: 8),
          Checkbox(
            checked: _includeSuppressed,
            content: const Text(
              'Incluir en el CSV las filas con suprimido = 1',
            ),
            onChanged: _busy
                ? null
                : (v) => setState(() => _includeSuppressed = v ?? false),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              HyperlinkButton(
                onPressed: _busy ? null : _copyMacro,
                child: const Text('Copiar macro VBA'),
              ),
              HyperlinkButton(
                onPressed: _busy ? null : _loadSpec,
                child: const Text('Contrato API / columnas CSV'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAuditoriaEmptyState(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.resources.controlStrokeColorDefault),
        color: theme.resources.cardBackgroundFillColorDefault.withValues(
          alpha: 0.35,
        ),
      ),
      alignment: Alignment.center,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 420,
                minWidth: constraints.maxWidth > 420 ? 420 : constraints.maxWidth,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    FluentIcons.document_search,
                    size: 36,
                    color: theme.accentColor.withValues(alpha: 0.85),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Auditoría lista vs ensamble',
                    textAlign: TextAlign.center,
                    style: theme.typography.subtitle?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Seleccione la revisión, el CSV de SolidWorks y pulse Ejecutar auditoría. '
                    'Aquí verá resumen y discrepancias (Lista vs Ensamble).',
                    textAlign: TextAlign.center,
                    style: theme.typography.body,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: CompactPageHeader(
        title: const Text('Auditoría lista · SolidWorks'),
        commandBar: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message: 'Qué audita esta pantalla, suprimidos en el CSV e informes',
              child: Button(
                onPressed: () => _showAyudaAuditoria(context),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(FluentIcons.info, size: 16),
                    SizedBox(width: 6),
                    Text('Ayuda'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      content: Padding(
        padding: const EdgeInsets.fromLTRB(
          UiTokens.pageHPadding,
          0,
          UiTokens.pageHPadding,
          16,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildAuditoriaSetupBar(context),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: ProgressBar(),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: InfoBar(
                  title: const Text('Error'),
                  content: Text(_error!),
                  severity: InfoBarSeverity.error,
                ),
              ),
            const SizedBox(height: 10),
            Expanded(
              child: _result == null
                  ? _buildAuditoriaEmptyState(context)
                  : _DespieceResultPane(
                      result: _result!,
                      tabIndex: _resultSideIndex,
                      onTabChanged: (i) => setState(() => _resultSideIndex = i),
                      porTipoCount: _porTipoCount,
                      filasPorTipo: _filasPorTipo,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Panel de resultados: cabecera clara + pestañas horizontales (sin ComboBox).
class _DespieceResultPane extends StatelessWidget {
  const _DespieceResultPane({
    required this.result,
    required this.tabIndex,
    required this.onTabChanged,
    required this.porTipoCount,
    required this.filasPorTipo,
  });

  final Map<String, dynamic> result;
  final int tabIndex;
  final ValueChanged<int> onTabChanged;
  final int Function(String key) porTipoCount;
  final Map<String, List<Map<String, dynamic>>> filasPorTipo;

  Widget _tabButton(
    BuildContext context, {
    required int index,
    required String label,
    required int badge,
    required bool showBadge,
  }) {
    final theme = FluentTheme.of(context);
    final selected = tabIndex == index;
    final suffix = showBadge && badge > 0 ? ' ($badge)' : '';
    final child = Text('$label$suffix', overflow: TextOverflow.ellipsis);
    return Padding(
      padding: const EdgeInsets.only(right: 8, bottom: 6),
      child: selected
          ? FilledButton(
              onPressed: () => onTabChanged(index),
              child: child,
            )
          : Button(
              onPressed: () => onTabChanged(index),
              child: child,
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final trunc = result['filas_truncamiento'];
    final nM = porTipoCount('CANTIDAD_MISMATCH');
    final nSw = porTipoCount('SW_SIN_LISTA');
    final nLi = porTipoCount('LISTA_SIN_SW');
    final nAll = nM + nSw + nLi;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.resources.controlStrokeColorDefault,
          width: 1.5,
        ),
        color: theme.resources.cardBackgroundFillColorDefault,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            decoration: BoxDecoration(
              color: theme.accentColor.withValues(alpha: 0.09),
              border: Border(
                bottom: BorderSide(
                  color: theme.resources.controlStrokeColorDefault,
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Comparación: lista aprobada vs ensamble (CSV)',
                  style: theme.typography.subtitle?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  nAll > 0
                      ? '$nAll hallazgos en esta auditoría (muestra limitada en listas; totales en Resumen).'
                      : 'Sin discrepancias en esta ejecución.',
                  style: theme.typography.caption,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Text(
              'Vista',
              style: theme.typography.caption?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _tabButton(
                    context,
                    index: 0,
                    label: 'Resumen',
                    badge: nAll,
                    showBadge: true,
                  ),
                  _tabButton(
                    context,
                    index: 1,
                    label: 'Cantidad distinta',
                    badge: nM,
                    showBadge: true,
                  ),
                  _tabButton(
                    context,
                    index: 2,
                    label: 'Nuevo en ensamble',
                    badge: nSw,
                    showBadge: true,
                  ),
                  _tabButton(
                    context,
                    index: 3,
                    label: 'No en ensamble',
                    badge: nLi,
                    showBadge: true,
                  ),
                ],
              ),
            ),
          ),
          if (trunc is Map && trunc['truncado'] == true)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
              child: InfoBar(
                title: const Text('Muestra acotada'),
                content: Text(
                  'Se listan ${trunc['mostradas']} de ${trunc['total']} filas de discrepancia. '
                  'Los totales del resumen son completos; descargue el informe CSV para todo el detalle.',
                ),
                severity: InfoBarSeverity.info,
              ),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: theme.resources.controlStrokeColorDefault
                        .withValues(alpha: 0.65),
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: _buildTabBody(context),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBody(BuildContext context) {
    switch (tabIndex) {
      case 1:
        return _DespieceFilasListView(
          vacio: 'Sin diferencias de cantidad entre lista y ensamble.',
          filas: filasPorTipo['CANTIDAD_MISMATCH'] ?? const [],
          builder: (m) => SelectableText(
            _despieceLineaUsuario(m),
            style: FluentTheme.of(context).typography.body,
          ),
        );
      case 2:
        return _DespieceFilasListView(
          vacio: 'Sin piezas nuevas solo en el ensamble.',
          filas: filasPorTipo['SW_SIN_LISTA'] ?? const [],
          builder: (m) => SelectableText(
            _despieceLineaUsuario(m),
            style: FluentTheme.of(context).typography.body,
          ),
        );
      case 3:
        return _DespieceFilasListView(
          vacio: 'Sin piezas solo en la lista.',
          filas: filasPorTipo['LISTA_SIN_SW'] ?? const [],
          builder: (m) => SelectableText(
            _despieceLineaUsuario(m),
            style: FluentTheme.of(context).typography.body,
          ),
        );
      default:
        return _DespieceResumenLite(result: result);
    }
  }
}

class _DespieceFilasListView extends StatelessWidget {
  const _DespieceFilasListView({
    required this.vacio,
    required this.filas,
    required this.builder,
  });

  final String vacio;
  final List<Map<String, dynamic>> filas;
  final Widget Function(Map<String, dynamic> m) builder;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    if (filas.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            vacio,
            textAlign: TextAlign.center,
            style: theme.typography.body,
          ),
        ),
      );
    }
    // SelectableText dentro de scroll en Windows necesita SelectionArea (si no, puede pintar vacío o fallar).
    return SelectionArea(
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
        itemCount: filas.length,
        separatorBuilder: (_, __) => const SizedBox(height: 6),
        itemBuilder: (context, i) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: theme.resources.controlFillColorDefault.withValues(
                alpha: 0.35,
              ),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: theme.resources.controlStrokeColorDefault
                    .withValues(alpha: 0.8),
              ),
            ),
            child: builder(filas[i]),
          );
        },
      ),
    );
  }
}

class _DespieceResumenLite extends StatelessWidget {
  const _DespieceResumenLite({required this.result});

  final Map<String, dynamic> result;

  @override
  Widget build(BuildContext context) {
    final rs = result['resumen'];
    final cob = result['cobertura_por_estacion'];
    int ri(String k) {
      if (rs is! Map) return 0;
      final v = rs[k];
      if (v is int) return v;
      return int.tryParse('$v') ?? 0;
    }

    final inclSup = result['include_suppressed'] == true;
    final csvTotal = ri('csv_filas_total');
    final csvSup = ri('csv_filas_suprimidas');
    final lineasUsadas = ri('lineas_sw_usadas');
    final cobRows = cob is List
        ? cob.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
        : <Map<String, dynamic>>[];

    return ListView(
      padding: const EdgeInsets.only(right: 8),
      children: [
        Text(
          'Totales de la auditoría. El detalle por código (Lista vs Ensamble) está en las pestañas '
          'Cantidad distinta, Nuevo en ensamble y No en ensamble.',
          style: FluentTheme.of(context).typography.caption,
        ),
        const SizedBox(height: 10),
        if (csvTotal > 0 && !inclSup && csvSup > 50 && csvSup > lineasUsadas * 2)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: InfoBar(
              title: const Text('Muchas filas suprimidas en el CSV'),
              content: Text(
                '$csvSup de $csvTotal filas con suprimido=1; solo $lineasUsadas usadas en el diff. '
                'Marque “Incluir en el CSV las filas con suprimido = 1” si debe contar también esas piezas.',
              ),
              severity: InfoBarSeverity.warning,
            ),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (csvTotal > 0) ...[
              _StatTile(title: 'Filas CSV ensamble', value: '$csvTotal'),
              _StatTile(title: 'Suprimidas (CSV)', value: '$csvSup'),
            ],
            _StatTile(title: 'Filas ensamble usadas', value: '${ri('lineas_sw_usadas')}'),
            _StatTile(title: 'Líneas lista', value: '${ri('lineas_lista')}'),
            _StatTile(title: 'Códigos ensamble', value: '${ri('codigos_sw_unicos')}'),
            _StatTile(title: 'Códigos lista', value: '${ri('codigos_lista_unicos')}'),
            _StatTile(
              title: 'Coinciden',
              value: '${ri('codigos_coinciden_cantidades')}',
              color: const Color(0xFF107C10),
            ),
            _StatTile(title: 'Conflicto cant.', value: '${ri('codigos_conflicto_cantidades')}'),
            _StatTile(title: 'Solo ensamble', value: '${ri('codigos_solo_en_sw')}'),
            _StatTile(title: 'Solo lista', value: '${ri('codigos_solo_en_lista')}'),
            _StatTile(title: 'Discrep. (filas)', value: '${ri('discrepancias')}'),
          ],
        ),
        if (cobRows.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Resumen de cobertura', style: FluentTheme.of(context).typography.subtitle),
          const SizedBox(height: 6),
          ...cobRows.map(
            (r) => ListTile(
              title: Text('${r['estacion'] ?? ''}'),
              subtitle: Text(
                'En lista: ${r['codigos_en_lista']} · OK CSV: ${r['coinciden_sw']} · '
                'Cant. distinta: ${r['cantidad_distinta']} · No en CSV: ${r['no_aparece_en_csv']}',
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.title,
    required this.value,
    this.color,
  });

  final String title;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? FluentTheme.of(context).accentColor;
    return Container(
      width: 168,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: FluentTheme.of(context).resources.controlStrokeColorDefault,
        ),
        color: c.withValues(alpha: 0.12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: FluentTheme.of(context).typography.caption),
          const SizedBox(height: 4),
          Text(
            value,
            style: FluentTheme.of(context).typography.title?.copyWith(
                  color: c,
                  fontWeight: FontWeight.w700,
                ),
          ),
        ],
      ),
    );
  }
}

String _fmtQty(dynamic v) {
  if (v == null) return '';
  if (v is num) {
    if (v == v.roundToDouble()) return '${v.toInt()}';
    return v.toString();
  }
  return v.toString();
}

/// Una sola línea según convención de usuario:
/// - Normal / cantidad distinta: `COD  Lista n vs Ensamble m`
/// - Solo en ensamble: `COD(nuevo)  Lista = 0 vs Ensamble m`
/// - Solo en lista: `COD  Lista n vs Ensamble = 0`
String _despieceLineaUsuario(Map<String, dynamic> m) {
  num q(dynamic x) {
    if (x is num) return x;
    return num.tryParse('$x') ?? 0;
  }

  final cod = m['codigo']?.toString() ?? '';
  final tipo = m['tipo']?.toString() ?? '';
  final lista = q(m['cantidad_lista']);
  final ens = q(m['cantidad_sw']);

  final codPart = tipo == 'SW_SIN_LISTA' ? '$cod(nuevo)' : cod;

  if (tipo == 'SW_SIN_LISTA') {
    return '$codPart  Lista = ${_fmtQty(lista)} vs Ensamble ${_fmtQty(ens)}';
  }
  if (tipo == 'LISTA_SIN_SW') {
    return '$codPart  Lista ${_fmtQty(lista)} vs Ensamble = ${_fmtQty(ens)}';
  }
  // CANTIDAD_MISMATCH y otros
  return '$codPart  Lista ${_fmtQty(lista)} vs Ensamble ${_fmtQty(ens)}';
}
