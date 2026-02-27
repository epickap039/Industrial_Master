import 'package:fluent_ui/fluent_ui.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:open_file/open_file.dart';

import '../main.dart';

class QADashboardScreen extends StatefulWidget {
  const QADashboardScreen({super.key});

  @override
  State<QADashboardScreen> createState() => _QADashboardScreenState();
}

class _QADashboardScreenState extends State<QADashboardScreen> {
  List<dynamic> _reportes = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _fetchReportes();
  }

  Future<void> _fetchReportes() async {
    setState(() => _isLoading = true);
    try {
      final res = await http.get(Uri.parse('$API_URL/api/reportes'));
      if (res.statusCode == 200) {
        setState(() {
          _reportes = json.decode(res.body);
        });
      } else {
        _showError("Error al cargar reportes: ${res.statusCode}");
      }
    } catch (e) {
      _showError("Excepción al cargar: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _exportarExcel() async {
    setState(() => _isLoading = true);
    try {
      final response = await http.get(
        Uri.parse('$API_URL/api/reportes/exportar'),
      );
      if (response.statusCode == 200) {
        final dir = await getDownloadsDirectory();
        final filePath = '${dir?.path ?? "C:\\"}\\Centro_QA_Reportes.xlsx';
        final file = File(filePath);
        await file.writeAsBytes(response.bodyBytes);

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
      } else {
        _showError("Error al exportar a Excel.");
      }
    } catch (e) {
      _showError(e.toString());
    } finally {
      setState(() => _isLoading = false);
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

  void _showImageDialog(String base64String) {
    try {
      final bytes = base64Decode(base64String);
      showDialog(
        context: context,
        builder:
            (context) => ContentDialog(
              title: const Text("Captura Adjunta"),
              content: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxHeight: 600,
                  maxWidth: 800,
                ),
                child: InteractiveViewer(child: Image.memory(bytes)),
              ),
              actions: [
                FilledButton(
                  child: const Text("Cerrar"),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
      );
    } catch (e) {
      _showError("No se pudo cargar la imagen: $e");
    }
  }

  Future<void> _resolverReporte(int id) async {
    setState(() => _isLoading = true);
    try {
      final res = await http.put(
        Uri.parse('$API_URL/api/reportes/$id/resolver'),
      );
      if (res.statusCode == 200) {
        _fetchReportes();
      } else {
        _showError("Error al resolver: ${res.statusCode}");
        setState(() => _isLoading = false);
      }
    } catch (e) {
      _showError("Excepción: $e");
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: PageHeader(
        title: const Text("Centro de QA y Reportes"),
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
              : Padding(
                padding: const EdgeInsets.all(16.0),
                child: ListView.builder(
                  itemCount: _reportes.length,
                  itemBuilder: (context, index) {
                    final rep = _reportes[index];
                    Color gravedadColor = Colors.grey;
                    if (rep['gravedad'] == 'Crítico')
                      gravedadColor = Colors.red;
                    if (rep['gravedad'] == 'Visual')
                      gravedadColor = Colors.orange;
                    if (rep['gravedad'] == 'Sugerencia')
                      gravedadColor = Colors.blue;

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12.0),
                      child: Card(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Fila 1: Cabecera
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      "#${rep['id']}",
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.grey.withOpacity(0.2),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        rep['modulo'] ?? "General",
                                        style: TextStyle(
                                          color:
                                              FluentTheme.of(
                                                context,
                                              ).typography.body?.color,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: gravedadColor,
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        rep['gravedad']
                                                ?.toString()
                                                .toUpperCase() ??
                                            'N/A',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                Text(
                                  rep['fecha'] ?? "",
                                  style: const TextStyle(
                                    color: Colors.grey,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            // Fila 2: Cuerpo
                            Text(
                              rep['descripcion'] ?? "Sin descripción",
                              style: const TextStyle(fontSize: 15.0),
                            ),
                            const SizedBox(height: 20),
                            // Fila 3: Footer
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    const Icon(
                                      FluentIcons.contact_info,
                                      color: Colors.grey,
                                      size: 16,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      rep['usuario'] ?? "Desconocido",
                                      style: const TextStyle(
                                        color: Colors.grey,
                                        fontWeight: FontWeight.w500,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ],
                                ),
                                Row(
                                  children: [
                                    if (rep['captura_base64'] != null)
                                      Tooltip(
                                        message: "Ver captura adjunta",
                                        child: IconButton(
                                          icon: Icon(
                                            FluentIcons.photo2,
                                            color: Colors.blue,
                                          ),
                                          onPressed:
                                              () => _showImageDialog(
                                                rep['captura_base64'],
                                              ),
                                        ),
                                      ),
                                    if (rep['captura_base64'] != null)
                                      const SizedBox(width: 8),
                                    Tooltip(
                                      message: "Marcar como resuelto",
                                      child: FilledButton(
                                        style: ButtonStyle(
                                          backgroundColor:
                                              WidgetStatePropertyAll(
                                                Colors.green,
                                              ),
                                        ),
                                        onPressed:
                                            () => _resolverReporte(rep['id']),
                                        child: const Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              FluentIcons.check_mark,
                                              size: 14,
                                            ),
                                            SizedBox(width: 6),
                                            Text("Resuelto"),
                                          ],
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
                    );
                  },
                ),
              ),
    );
  }
}
