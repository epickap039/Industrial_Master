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
              : Padding(
                padding: const EdgeInsets.all(16.0),
                child: Card(
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

                      return Container(
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Colors.grey.withOpacity(0.3),
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      "#${rep['id']}",
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
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
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Text(
                                      rep['modulo'] ?? "General",
                                      style: TextStyle(
                                        color:
                                            FluentTheme.of(context).accentColor,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                                Text(
                                  rep['fecha'] ?? "",
                                  style: const TextStyle(
                                    color: Colors.grey,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(rep['descripcion'] ?? "Sin descripción"),
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  "Por: ${rep['usuario']}",
                                  style: const TextStyle(
                                    color: Colors.grey,
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
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
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
    );
  }
}
