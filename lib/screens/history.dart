import 'package:fluent_ui/fluent_ui.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_file/open_file.dart';
import '../config/app_config.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<dynamic> _history = [];
  bool _isLoading = false;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _fetchHistory();
  }

  Future<void> _fetchHistory({String? query}) async {
    setState(() {
      _isLoading = true;
    });

    try {
      String url = '$kApiBaseUrl/api/historial?limite=50';
      if (query != null && query.isNotEmpty) {
        url += '&busqueda=$query';
      }

      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        setState(() {
          _history = data;
        });
      } else {
        throw Exception('Error al cargar historial: ${response.statusCode}');
      }
    } catch (e) {
      _showErrorDialog(e.toString());
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (context) {
        return ContentDialog(
          title: const Text('Error'),
          content: Text(message),
          actions: [
            Button(
              child: const Text('Cerrar'),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        );
      },
    );
  }

  Color _getActionColor(String action) {
    if (action.toUpperCase().contains('CREACION') ||
        action.toUpperCase() == 'NUEVO') {
      return Colors.green;
    } else if (action.toUpperCase().contains('MODIFICACION') ||
        action.toUpperCase() == 'UPDATE') {
      return Colors.blue;
    } else if (action.toUpperCase().contains('ELIMINACION') ||
        action.toUpperCase() == 'DELETE') {
      return Colors.red;
    }
    return Colors.orange; // Default/Unknown
  }

  Widget _buildDiffView(
    dynamic oldData,
    dynamic newData,
    BuildContext context,
  ) {
    // 1. LÓGICA DE PARSEO INTELIGENTE
    Map<String, dynamic>? tryParseJson(dynamic data) {
      if (data == null) return null;
      if (data is Map<String, dynamic>) return data;
      if (data is String) {
        try {
          String sanitized = data
              .replaceAll('"', '\\"') // 1. Protege las pulgadas primero
              .replaceAll("'", '"') // 2. Convierte sintaxis Python a JSON
              .replaceAll("None", "null")
              .replaceAll("True", "true")
              .replaceAll("False", "false");
          final decoded = jsonDecode(sanitized);
          if (decoded is Map<String, dynamic>) return decoded;
        } catch (_) {}
      }
      return null;
    }

    final oldMap = tryParseJson(oldData);
    final newMap = tryParseJson(newData);

    final isDict = (oldMap != null || newMap != null);

    // 2. CONSTRUCCIÓN VISUAL DEL BLOQUE (MAPAS DESGLOSADOS)
    if (isDict) {
      final safeOld = oldMap ?? {};
      final safeNew = newMap ?? {};

      final allKeys = {...safeOld.keys, ...safeNew.keys}.toList();
      List<Widget> changes = [];

      for (var key in allKeys) {
        final oldVal = safeOld[key]?.toString() ?? 'N/A';
        final newVal = safeNew[key]?.toString() ?? 'N/A';
        // === TAREA 3: Colores explícitos independientes de TextTheme ===
        final isDark = FluentTheme.of(context).brightness == Brightness.dark;
        final labelColor = isDark ? Colors.white.withOpacity(0.7) : const Color(0xFF444444);

        if (oldVal != newVal) {
          changes.add(
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '$key: ',
                  style: TextStyle(fontWeight: FontWeight.bold, color: labelColor),
                ),
                Text(
                  oldVal,
                  style: TextStyle(
                    color: Colors.red,
                    decoration: TextDecoration.lineThrough,
                  ),
                ),
                Text(
                  ' ➔ ',
                  style: TextStyle(
                    color: isDark ? Colors.grey : Colors.grey[100],
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(newVal, style: TextStyle(color: Colors.green)),
              ],
            ),
          );
        }
      }

      if (changes.isEmpty) {
        return const Text(
          'Sin cambios identificados en estructura.',
          style: TextStyle(fontStyle: FontStyle.italic),
        );
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: changes,
      );
    } else {
      // 2B. CONSTRUCCIÓN VISUAL (TEXTO SIMPLE)
      // === TAREA 3: Colores explícitos para modo oscuro ===
      final isDark = FluentTheme.of(context).brightness == Brightness.dark;
      final labelColor = isDark ? Colors.white.withOpacity(0.7) : const Color(0xFF555555);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (oldData != null && oldData.toString().isNotEmpty)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Anterior: ', style: TextStyle(color: labelColor, fontWeight: FontWeight.bold)),
                Expanded(
                  child: Text(
                    oldData.toString(),
                    style: TextStyle(color: Colors.red),
                  ),
                ),
              ],
            ),
          if (newData != null && newData.toString().isNotEmpty) ...[
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Nuevo: ', style: TextStyle(color: labelColor, fontWeight: FontWeight.bold)),
                Expanded(
                  child: Text(
                    newData.toString(),
                    style: TextStyle(color: Colors.green),
                  ),
                ),
              ],
            ),
          ],
        ],
      );
    }
  }

  Future<void> _exportarBugs() async {
    setState(() => _isLoading = true);
    try {
      final response = await http.get(
        Uri.parse('$kApiBaseUrl/api/reportes/exportar_gemini'),
      );
      if (response.statusCode == 200) {
        final dir = await getDownloadsDirectory();
        final filePath =
            '${dir?.path ?? "C:\\"}\\Tbl_Reportes_Beta_Gemini.json';
        final file = File(filePath);
        await file.writeAsString(response.body);

        displayInfoBar(
          context,
          builder: (context, close) {
            return InfoBar(
              title: const Text('Exportado'),
              content: Text('Reporte JSON guardado en Descargas: $filePath'),
              severity: InfoBarSeverity.success,
              action: Button(
                child: const Text("Abrir"),
                onPressed: () {
                  OpenFile.open(filePath);
                },
              ),
              onClose: close,
            );
          },
        );
      } else {
        _showErrorDialog("Error al generar reporte de Bugs.");
      }
    } catch (e) {
      _showErrorDialog(e.toString());
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: const PageHeader(
        title: Text('Historial Global de Cambios'),
      ),
      content: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // BARRA DE BÚSQUEDA
            TextBox(
              controller: _searchController,
              placeholder: 'Buscar por Código o Usuario...',
              suffix: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_searchController.text.isNotEmpty)
                    IconButton(
                      icon: Icon(FluentIcons.clear),
                      onPressed: () {
                        _searchController.clear();
                        _fetchHistory();
                      },
                    ),
                  IconButton(
                    icon: Icon(FluentIcons.search),
                    onPressed:
                        () => _fetchHistory(query: _searchController.text),
                  ),
                  IconButton(
                    icon: Icon(FluentIcons.refresh),
                    onPressed:
                        () => _fetchHistory(query: _searchController.text),
                  ),
                ],
              ),
              onSubmitted: (value) => _fetchHistory(query: value),
            ),
            const SizedBox(height: 20),

            // LISTA DE RESULTADOS
            Expanded(
              child:
                  _isLoading
                      ? const Center(child: ProgressRing())
                      : _history.isEmpty
                      ? const Center(
                        child: Text('No se encontraron registros.'),
                      )
                      : ListView.builder(
                        itemCount: _history.length,
                        itemBuilder: (context, index) {
                          final item = _history[index];
                          final actionColor = _getActionColor(
                            item['accion'] ?? '',
                          );

                          return Card(
                            margin: const EdgeInsets.only(bottom: 10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Encabezado
                                Row(
                                  children: [
                                    Text(
                                      item['fecha'] ?? 'Sin fecha',
                                      style: TextStyle(
                                        fontSize: 12,
                                        // === TAREA 3: Color explícito en header ===
                                        color: FluentTheme.of(context).brightness == Brightness.dark
                                            ? Colors.white.withOpacity(0.54)
                                            : const Color(0xFF666666),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      '| Usuario: ${item['usuario'] ?? "Desconocido"}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        color: FluentTheme.of(context).brightness == Brightness.dark
                                            ? Colors.white
                                            : Colors.black.withOpacity(0.87),
                                      ),
                                    ),
                                    // 3. MEJORA DE BADGES (Etiqueta de Acción)
                                    const Spacer(),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.orange.withOpacity(
                                          0.2,
                                        ), // Naranja tenue
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        item['accion'] ?? 'ACCIÓN',
                                        style: TextStyle(
                                          color: Colors.orange,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),

                                // Título (Código)
                                SelectableText(
                                  item['codigo'] ?? 'SIN CÓDIGO',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    // === TAREA 3: Explícito para modo oscuro ===
                                    color: FluentTheme.of(context).brightness == Brightness.dark
                                        ? Colors.white
                                        : Colors.black,
                                  ),
                                ),
                                const SizedBox(height: 8),

                                // Cuerpo (Cambios - Diff View)
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color:
                                        FluentTheme.of(context).brightness ==
                                                Brightness.dark
                                            ? Colors.black.withOpacity(0.2)
                                            : Colors
                                                .grey[20], // Still using grey[20] as it seemed fine before, just non-const
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: _buildDiffView(
                                    item['valor_anterior'],
                                    item['valor_nuevo'],
                                    context,
                                  ),
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
