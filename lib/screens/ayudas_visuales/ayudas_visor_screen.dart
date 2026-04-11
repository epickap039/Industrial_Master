import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' as material;
import 'package:fluent_ui/fluent_ui.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

import '../../config/app_config.dart';
import '../../services/api_client.dart';
import '../../widgets/contextual_bug_report.dart';
import 'ayudas_api_models.dart';

String _pdfUrlForRevision(int idRevision) {
  final base = kApiBaseUrl.endsWith('/')
      ? kApiBaseUrl.substring(0, kApiBaseUrl.length - 1)
      : kApiBaseUrl;
  return '$base/api/ayudas/ver/$idRevision';
}

/// Pantalla 3: PDF (≈80%) + línea de tiempo de revisiones (≈20%).
class AyudasVisorScreen extends StatefulWidget {
  const AyudasVisorScreen({
    super.key,
    required this.idAyuda,
    required this.tituloDocumento,
    required this.idRevisionInicial,
    required this.canUpload,
    this.allowRevisionHistory = true,
  });

  final int idAyuda;
  final String tituloDocumento;
  final int idRevisionInicial;
  final bool canUpload;

  /// Si es false (p. ej. rol Producción), solo se muestra la revisión vigente sin panel de historial.
  final bool allowRevisionHistory;

  @override
  State<AyudasVisorScreen> createState() => _AyudasVisorScreenState();
}

class _AyudasVisorScreenState extends State<AyudasVisorScreen> {
  static const double _kSidebarWidth = 280;

  bool _loadingHist = true;
  String? _errorHist;
  List<dynamic> _historial = [];
  late int _idRevisionSeleccionada;
  Map<String, String> _pdfHeaders = {};
  bool _sidebarColapsada = false;

  @override
  void initState() {
    super.initState();
    _idRevisionSeleccionada = widget.idRevisionInicial;
    _cargarHeaders();
    if (widget.allowRevisionHistory) {
      _cargarHistorial();
    } else {
      _historial = [];
      _loadingHist = false;
    }
  }

  Future<void> _cargarHeaders() async {
    final prefs = await SharedPreferences.getInstance();
    final t = prefs.getString('access_token');
    final h = <String, String>{};
    if (t != null && t.isNotEmpty) {
      h['Authorization'] = 'Bearer $t';
    }
    if (mounted) setState(() => _pdfHeaders = h);
  }

  Future<void> _cargarHistorial() async {
    setState(() {
      _loadingHist = true;
      _errorHist = null;
    });
    try {
      final data = await ApiClient.get('/api/ayudas/historial/${widget.idAyuda}');
      setState(() {
        _historial = data is List ? data : [];
        _loadingHist = false;
      });
    } catch (e) {
      setState(() {
        _errorHist = e.toString();
        _loadingHist = false;
      });
    }
  }

  Future<void> _dialogoSubirRevision() async {
    final revCtrl = TextEditingController(text: 'B');
    final vinCtrl = TextEditingController();
    String? pathPdf;

    await showDialog<void>(
      context: context,
      barrierColor: material.Theme.of(context).brightness == material.Brightness.dark
          ? const material.Color(0xFF121212)
          : material.Colors.white,
      builder: (ctx) {
        return material.AlertDialog(
          backgroundColor: material.Theme.of(context).brightness ==
                  material.Brightness.dark
              ? const material.Color(0xFF121212)
              : material.Colors.white,
          shape: material.RoundedRectangleBorder(
            borderRadius: material.BorderRadius.circular(20.0),
          ),
          title: const Text('Subir nueva revisión'),
          content: StatefulBuilder(
            builder: (context, setLocal) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('VINs aplicables (separados por coma)'),
                  const SizedBox(height: 6),
                  material.TextField(
                    controller: vinCtrl,
                    style: material.TextStyle(
                      color: material.Theme.of(
                        context,
                      ).textTheme.bodyLarge?.color,
                    ),
                    decoration: material.InputDecoration(
                      labelText: 'VINs aplicables',
                      contentPadding: const material.EdgeInsets.symmetric(
                        vertical: 12.0,
                        horizontal: 16.0,
                      ),
                      border: material.OutlineInputBorder(
                        borderRadius: material.BorderRadius.circular(12.0),
                        borderSide: material.BorderSide(
                          color: material.Colors.grey.shade400,
                        ),
                      ),
                      enabledBorder: material.OutlineInputBorder(
                        borderRadius: material.BorderRadius.circular(12.0),
                        borderSide: material.BorderSide(
                          color: material.Colors.grey.shade400,
                        ),
                      ),
                      hintText: 'Ej: 3N1AB7AP1HY123456, 1HGCM82633A004352',
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text('Número de revisión'),
                  const SizedBox(height: 6),
                  material.TextField(
                    controller: revCtrl,
                    style: material.TextStyle(
                      color: material.Theme.of(
                        context,
                      ).textTheme.bodyLarge?.color,
                    ),
                    decoration: material.InputDecoration(
                      labelText: 'Numero de revision',
                      contentPadding: const material.EdgeInsets.symmetric(
                        vertical: 12.0,
                        horizontal: 16.0,
                      ),
                      border: material.OutlineInputBorder(
                        borderRadius: material.BorderRadius.circular(12.0),
                        borderSide: material.BorderSide(
                          color: material.Colors.grey.shade400,
                        ),
                      ),
                      enabledBorder: material.OutlineInputBorder(
                        borderRadius: material.BorderRadius.circular(12.0),
                        borderSide: material.BorderSide(
                          color: material.Colors.grey.shade400,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  material.OutlinedButton(
                    child: Text(
                      pathPdf == null
                          ? 'Seleccionar PDF…'
                          : pathPdf!.split(RegExp(r'[\\/]')).last,
                    ),
                    onPressed: () async {
                      final r = await FilePicker.platform.pickFiles(
                        type: FileType.custom,
                        allowedExtensions: ['pdf'],
                      );
                      if (r != null && r.files.single.path != null) {
                        setLocal(() => pathPdf = r.files.single.path);
                      }
                    },
                  ),
                ],
              );
            },
          ),
          actions: [
            material.TextButton(
              child: const Text('Cancelar'),
              onPressed: () => Navigator.pop(ctx),
            ),
            material.ElevatedButton(
              child: const Text('Subir'),
              onPressed: () async {
                if (pathPdf == null) return;
                final prefs = await SharedPreferences.getInstance();
                final user = prefs.getString('username')?.trim() ?? 'Operador';
                if (!mounted) return;
                showDialog<void>(
                  context: context,
                  barrierDismissible: false,
                  builder: (lc) => const ContentDialog(
                    title: Text('Subiendo…'),
                    content: Center(
                      child: SizedBox(
                        height: 80,
                        child: ProgressRing(),
                      ),
                    ),
                  ),
                );
                try {
                  final fields = <String, String>{
                    'id_ayuda': '${widget.idAyuda}',
                    'numero_revision': revCtrl.text.trim(),
                    'usuario': user,
                  };
                  final v = vinCtrl.text.trim();
                  if (v.isNotEmpty) fields['vin'] = v;
                  final res = await ApiClient.postMultipart(
                    '/api/ayudas/subir',
                    fields: fields,
                    files: {
                      'file': await ApiClient.fileField('file', pathPdf!),
                    },
                  ) as Map<String, dynamic>;
                  if (!mounted) return;
                  Navigator.of(context, rootNavigator: true).pop();
                  Navigator.of(context, rootNavigator: true).pop();
                  final newId = res['id_revision'];
                  if (newId != null) {
                    setState(() {
                      _idRevisionSeleccionada = newId is int
                          ? newId
                          : int.tryParse('$newId') ?? _idRevisionSeleccionada;
                    });
                  }
                  await _cargarHistorial();
                  if (mounted) {
                    displayInfoBar(context, builder: (c, close) {
                      return InfoBar(
                        title: const Text('Listo'),
                        content: const Text('Revisión registrada.'),
                        severity: InfoBarSeverity.success,
                        onClose: close,
                      );
                    });
                  }
                } catch (e) {
                  if (!mounted) return;
                  Navigator.of(context, rootNavigator: true).pop();
                  showAyudasUploadError(context, e);
                }
              },
            ),
          ],
        );
      },
    );

    revCtrl.dispose();
    vinCtrl.dispose();
  }

  Future<void> _borrarRevision(int idRevision) async {
    final passCtrl = TextEditingController();
    try {
      await showDialog<void>(
        context: context,
        builder: (dCtx) {
          return material.AlertDialog(
            title: const Text('Eliminar revisión'),
            content: material.TextField(
              controller: passCtrl,
              obscureText: true,
              decoration: const material.InputDecoration(
                labelText: 'Clave maestra',
              ),
            ),
            actions: [
              material.TextButton(
                onPressed: () => Navigator.pop(dCtx),
                child: const Text('Cancelar'),
              ),
              material.TextButton(
                onPressed: () async {
                  Navigator.pop(dCtx);
                  try {
                    final prefs = await SharedPreferences.getInstance();
                    final user = prefs.getString('username')?.trim() ?? 'Operador';
                    await ApiClient.delete(
                      '/api/ayudas/revision/$idRevision',
                      headers: {
                        'X-Usuario': user,
                        ApiClient.adminMasterPasswordHeader: passCtrl.text.trim(),
                      },
                    );
                    await _cargarHistorial();
                    if (!mounted) return;
                    if (_historial.isEmpty) {
                      Navigator.of(context).pop();
                      return;
                    }
                    final ids = _historial
                        .map((e) => ayudasIdRevision(e as Map<String, dynamic>))
                        .toList();
                    if (!ids.contains(_idRevisionSeleccionada) &&
                        ids.isNotEmpty) {
                      setState(() {
                        _idRevisionSeleccionada = ids.first;
                      });
                    }
                    if (mounted) {
                      displayInfoBar(context, builder: (c, close) {
                        return InfoBar(
                          title: const Text('Listo'),
                          content: const Text('Revisión eliminada.'),
                          severity: InfoBarSeverity.success,
                          onClose: close,
                        );
                      });
                    }
                  } catch (e) {
                    if (mounted) showAyudasUploadError(context, e);
                  }
                },
                child: const Text('Eliminar'),
              ),
            ],
          );
        },
      );
    } finally {
      passCtrl.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = _pdfUrlForRevision(_idRevisionSeleccionada);

    return material.Scaffold(
      appBar: material.AppBar(
        toolbarHeight: 44,
        titleSpacing: 6,
        leading: material.IconButton(
          icon: const material.Icon(material.Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: material.Text(
          widget.tituloDocumento,
          style: const material.TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          material.IconButton(
            icon: const material.Icon(material.Icons.bug_report_outlined),
            onPressed: () => showContextualBugReportDialog(
              context,
              modulo: 'Ayudas Visuales',
              contextoPantalla: 'ayudas_visor',
            ),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, c) {
          final narrow = c.maxWidth < 800;
          if (narrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 3,
                  child: _PdfPane(
                    key: ValueKey<int>(_idRevisionSeleccionada),
                    url: url,
                    headers: _pdfHeaders,
                    revisionKey: _idRevisionSeleccionada,
                  ),
                ),
                if (widget.allowRevisionHistory) ...[
                  const Divider(),
                  SizedBox(
                    height: 220,
                    child: _TimelinePane(
                      loading: _loadingHist,
                      error: _errorHist,
                      historial: _historial,
                      idSeleccionada: _idRevisionSeleccionada,
                      canUpload: widget.canUpload,
                      onSelect: (id) =>
                          setState(() => _idRevisionSeleccionada = id),
                      onSubir: _dialogoSubirRevision,
                      onDeleteRevision: _borrarRevision,
                    ),
                  ),
                ],
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    Positioned.fill(
                      child: _PdfPane(
                        key: ValueKey<int>(_idRevisionSeleccionada),
                        url: url,
                        headers: _pdfHeaders,
                        revisionKey: _idRevisionSeleccionada,
                      ),
                    ),
                    if (widget.allowRevisionHistory)
                      Positioned(
                        top: 8,
                        right: 0,
                        child: material.Material(
                          elevation: 2,
                          borderRadius: const material.BorderRadius.horizontal(
                            left: material.Radius.circular(10),
                          ),
                          child: material.InkWell(
                            borderRadius: const material.BorderRadius.horizontal(
                              left: material.Radius.circular(10),
                            ),
                            onTap: () => setState(
                              () => _sidebarColapsada = !_sidebarColapsada,
                            ),
                            child: Padding(
                              padding: const material.EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 10,
                              ),
                              child: Icon(
                                _sidebarColapsada
                                    ? material.Icons.chevron_left
                                    : material.Icons.chevron_right,
                                size: 22,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (widget.allowRevisionHistory &&
                  !_sidebarColapsada)
                SizedBox(
                  width: _kSidebarWidth,
                  child: _TimelinePane(
                    loading: _loadingHist,
                    error: _errorHist,
                    historial: _historial,
                    idSeleccionada: _idRevisionSeleccionada,
                    canUpload: widget.canUpload,
                    onSelect: (id) =>
                        setState(() => _idRevisionSeleccionada = id),
                    onSubir: _dialogoSubirRevision,
                    onDeleteRevision: _borrarRevision,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _PdfPane extends StatefulWidget {
  const _PdfPane({
    super.key,
    required this.url,
    required this.headers,
    required this.revisionKey,
  });

  final String url;
  final Map<String, String> headers;
  final int revisionKey;

  @override
  State<_PdfPane> createState() => _PdfPaneState();
}

class _PdfPaneState extends State<_PdfPane> {
  late final PdfViewerController _pdfController = PdfViewerController();

  @override
  void dispose() {
    _pdfController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: material.Card(
        margin: material.EdgeInsets.zero,
        clipBehavior: material.Clip.antiAlias,
        elevation: 0,
        child: SfPdfViewer.network(
          widget.url,
          key: ValueKey<int>(widget.revisionKey),
          headers: widget.headers.isEmpty ? null : widget.headers,
          controller: _pdfController,
          pageLayoutMode: PdfPageLayoutMode.single,
          maxZoomLevel: 5,
          canShowScrollHead: true,
          canShowScrollStatus: true,
          interactionMode: PdfInteractionMode.pan,
        ),
      ),
    );
  }
}

class _TimelinePane extends StatelessWidget {
  const _TimelinePane({
    required this.loading,
    required this.error,
    required this.historial,
    required this.idSeleccionada,
    required this.canUpload,
    required this.onSelect,
    required this.onSubir,
    required this.onDeleteRevision,
  });

  final bool loading;
  final String? error;
  final List<dynamic> historial;
  final int idSeleccionada;
  final bool canUpload;
  final void Function(int id) onSelect;
  final VoidCallback onSubir;
  final void Function(int idRevision) onDeleteRevision;

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('yyyy-MM-dd HH:mm');

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (canUpload)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: FilledButton(
                  onPressed: onSubir,
                  child: const Text('Subir nueva revisión'),
                ),
              ),
            const Text(
              'Revisiones',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: loading
                  ? const Center(child: ProgressRing())
                  : error != null
                      ? Center(child: Text(error!, style: TextStyle(color: Colors.red)))
                      : ListView.builder(
                          itemCount: historial.length,
                          itemBuilder: (context, i) {
                            final m = historial[i] as Map<String, dynamic>;
                            final id = ayudasIdRevision(m);
                            final vig = ayudasEsVigente(m);
                            final numR = ayudasNumeroRevision(m);
                            final fecha = ayudasFechaSubida(m);
                            String fechaStr = '';
                            if (fecha != null) {
                              try {
                                fechaStr = df.format(DateTime.parse(
                                    fecha.toString()));
                              } catch (_) {
                                fechaStr = fecha.toString();
                              }
                            }
                            final usuario =
                                (m['Usuario_Subida'] ?? '').toString();
                            final sel = id == idSeleccionada;
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: material.Material(
                                      color: Colors.transparent,
                                      child: material.InkWell(
                                        onTap: () => onSelect(id),
                                        child: Container(
                                          padding: const EdgeInsets.all(8),
                                          decoration: BoxDecoration(
                                            borderRadius:
                                                BorderRadius.circular(4),
                                            border: Border.all(
                                              color: sel
                                                  ? FluentTheme.of(context).accentColor
                                                  : FluentTheme.of(context)
                                                      .resources
                                                      .controlStrongStrokeColorDefault,
                                              width: sel ? 2 : 1,
                                            ),
                                            color: vig
                                                ? FluentTheme.of(context)
                                                    .accentColor
                                                    .withValues(alpha: 0.14)
                                                : FluentTheme.of(context)
                                                    .resources
                                                    .controlFillColorDefault,
                                          ),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                'Rev. $numR',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  color: vig
                                                      ? FluentTheme.of(context)
                                                          .accentColor
                                                      : FluentTheme.of(context)
                                                          .typography
                                                          .caption
                                                          ?.color,
                                                ),
                                              ),
                                              if (fechaStr.isNotEmpty)
                                                Text(
                                                  fechaStr,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    color: material.Theme.of(
                                                          context,
                                                        ).textTheme.bodySmall?.color,
                                                  ),
                                                ),
                                              if (usuario.isNotEmpty)
                                                Text(
                                                  usuario,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    color: material.Theme.of(
                                                          context,
                                                        ).textTheme.bodySmall?.color,
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  material.IconButton(
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(
                                      minWidth: 36,
                                      minHeight: 36,
                                    ),
                                    iconSize: 22,
                                    icon: const Icon(material.Icons.delete),
                                    color: material.Colors.red.shade700,
                                    onPressed: () => onDeleteRevision(id),
                                  ),
                                ],
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
