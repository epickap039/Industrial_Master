import 'package:fluent_ui/fluent_ui.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:open_file/open_file.dart';

import '../services/api_client.dart';
import '../widgets/compact_page_header.dart';

class QADashboardScreen extends StatefulWidget {
  const QADashboardScreen({super.key});

  @override
  State<QADashboardScreen> createState() => _QADashboardScreenState();
}

class _QADashboardScreenState extends State<QADashboardScreen> {
  List<dynamic> _reportes = [];
  bool _isLoading = false;
  /// Reporte activo en el panel de detalle (izquierda, ~70%).
  dynamic _selectedReport;

  @override
  void initState() {
    super.initState();
    _fetchReportes();
  }

  void _syncSelectionAfterFetch() {
    if (_reportes.isEmpty) {
      _selectedReport = null;
      return;
    }
    final ids = _reportes.map((r) => r['id']).toSet();
    final selId = _selectedReport?['id'];
    if (_selectedReport == null || !ids.contains(selId)) {
      _selectedReport = _reportes.first;
    }
  }

  Future<void> _fetchReportes() async {
    setState(() => _isLoading = true);
    try {
      final res = await ApiClient.getUnvalidated('/api/reportes');
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

  Color _gravedadColor(dynamic rep) {
    if (rep['gravedad'] == 'Crítico') return Colors.red;
    if (rep['gravedad'] == 'Visual') return Colors.orange;
    if (rep['gravedad'] == 'Sugerencia') return Colors.blue;
    return Colors.grey;
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
    if (_selectedReport == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              FluentIcons.touch_pointer,
              size: 64,
              color: Colors.grey.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              'Selecciona un reporte en la lista de la derecha',
              style: TextStyle(
                fontSize: 18,
                color: Colors.grey.withValues(alpha: 0.9),
              ),
            ),
          ],
        ),
      );
    }

    final rep = _selectedReport as Map;
    final bytes = _decodeCaptura(rep['captura_base64']);
    final gravedadColor = _gravedadColor(rep);

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
                color: FluentTheme.of(context).cardColor,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: FluentTheme.of(context).resources.dividerStrokeColorDefault,
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
                            color: Colors.grey.withValues(alpha: 0.45),
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
                              FluentTheme.of(context).typography.body?.color,
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
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Icon(
                        FluentIcons.calendar,
                        size: 20,
                        color: Colors.grey.withValues(alpha: 0.85),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        rep['fecha']?.toString() ?? '—',
                        style: const TextStyle(
                          fontSize: 16,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(width: 24),
                      Icon(
                        FluentIcons.contact_info,
                        size: 20,
                        color: Colors.grey.withValues(alpha: 0.85),
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
                      color: Colors.orange,
                    ),
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: background ?? Colors.grey.withValues(alpha: 0.18),
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
    return Container(
      decoration: BoxDecoration(
        color: FluentTheme.of(context).micaBackgroundColor.withValues(alpha: 0.35),
        border: Border(
          left: BorderSide(
            color: FluentTheme.of(context).resources.dividerStrokeColorDefault,
          ),
        ),
      ),
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(10, 8, 16, 16),
        itemCount: _reportes.length,
        itemBuilder: (context, index) {
          final rep = _reportes[index];
          final selected =
              _selectedReport != null && _selectedReport['id'] == rep['id'];
          final thumb = _decodeCaptura(rep['captura_base64']);
          final gravedadColor = _gravedadColor(rep);

          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Card(
              padding: const EdgeInsets.all(10),
              backgroundColor: selected
                  ? FluentTheme.of(context).accentColor.withValues(alpha: 0.12)
                  : null,
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
                              color: Colors.grey.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Icon(
                              FluentIcons.photo2,
                              color: Colors.grey.withValues(alpha: 0.5),
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
                                  color: Colors.grey.withValues(alpha: 0.95),
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
                            color: Colors.grey.withValues(alpha: 0.9),
                          ),
                        ),
                        Tooltip(
                          message: "Marcar como resuelto",
                          child: FilledButton(
                            style: ButtonStyle(
                              padding: WidgetStateProperty.all(
                                const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                              ),
                              backgroundColor: WidgetStatePropertyAll(
                                Colors.green,
                              ),
                            ),
                            onPressed: () => _resolverReporte(rep['id']),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(FluentIcons.check_mark, size: 12),
                                SizedBox(width: 4),
                                Text("Resuelto", style: TextStyle(fontSize: 11)),
                              ],
                            ),
                          ),
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
        _showError("Error al resolver: ${res.statusCode}");
        if (mounted) setState(() => _isLoading = false);
      }
    } catch (e) {
      _showError("Excepción: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
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
      content:
          _isLoading
              ? const Center(child: ProgressRing())
              : _reportes.isEmpty
              ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      FluentIcons.party_leader,
                      size: 80,
                      color: Colors.green,
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      "¡Bandeja limpia! No hay reportes de QA pendientes.",
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              )
              : Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Detalle ~70% (izquierda): imagen grande + texto
                  Expanded(flex: 7, child: _buildDetailPanel()),
                  // Maestro ~30% (derecha): lista compacta
                  Expanded(flex: 3, child: _buildMasterList()),
                ],
              ),
    );
  }
}
