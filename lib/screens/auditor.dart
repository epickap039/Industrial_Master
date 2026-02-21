import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

class AuditorScreen extends StatefulWidget {
  const AuditorScreen({super.key});

  @override
  State<AuditorScreen> createState() => _AuditorScreenState();
}

class _AuditorScreenState extends State<AuditorScreen> {
  bool _isProcessing = false;
  List<dynamic>? _errors; 
  List<dynamic>? _detailedReport;
  String? _fileName;
  String? _filePath;

  // 1. AUDITORÍA
  Future<void> _auditExcel() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
        dialogTitle: 'Seleccionar Archivo para Auditar (Excel)',
      );

      if (result == null || result.files.single.path == null) return;

      setState(() {
        _isProcessing = true;
        _errors = null;
        _fileName = result.files.single.name;
        _filePath = result.files.single.path!;
      });

      var request = http.MultipartRequest(
        'POST',
        Uri.parse('http://192.168.1.73:8001/api/excel/auditar'),
      );
      request.files.add(await http.MultipartFile.fromPath('file', _filePath!));

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _errors = data['errores'];
          _detailedReport = data['reporte_detallado'];
        });
      } else {
        throw Exception(response.body);
      }
    } catch (e) {
      _showErrorDialog("Error de Auditoría", e.toString());
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  // 2. AUTOCORRECCIÓN
  Future<void> _autoCorrect() async {
    if (_errors == null || _errors!.isEmpty || _filePath == null) return;

    // Confirmación
    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (c) => ContentDialog(
        title: const Text("Confirmar Autocorrección"),
        content: const Text(
          "El servidor analizará tu archivo y te devolverá una versión con las correcciones de base de datos aplicadas.\n\n¿Deseas continuar?"
        ),
        actions: [
          Button(child: const Text("Cancelar"), onPressed: () => Navigator.pop(c, false)),
          FilledButton(child: const Text("Corregir Archivo"), onPressed: () => Navigator.pop(c, true)),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isProcessing = true);

    try {
      var request = http.MultipartRequest(
        'POST',
        Uri.parse('http://192.168.1.73:8001/api/excel/corregir'),
      );
      
      request.files.add(await http.MultipartFile.fromPath('file', _filePath!));
      request.fields['correcciones'] = json.encode(_errors);

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        String? outputFile = await FilePicker.platform.saveFile(
          dialogTitle: 'Guardar Archivo Corregido',
          fileName: 'CORREGIDO_${_fileName ?? "archivo.xlsx"}',
          allowedExtensions: ['xlsx'],
        );

        if (outputFile != null) {
          if (!outputFile.endsWith('.xlsx')) outputFile += '.xlsx';
          final file = File(outputFile);
          await file.writeAsBytes(response.bodyBytes);

          if (mounted) {
            displayInfoBar(context, builder: (context, close) {
              return InfoBar(
                title: const Text('Corrección Exitosa'),
                content: Text("Archivo guardado en: $outputFile"),
                severity: InfoBarSeverity.success,
                action: Button(
                  onPressed: () => _openLocalFile(outputFile!), 
                  child: const Text('Abrir File'),
                ),
                onClose: close,
              );
            });
            setState(() => _errors = []); 
          }
        }
      } else {
        throw Exception(response.body);
      }
    } catch (e) {
      _showErrorDialog("Error al Corregir", e.toString());
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  // 3. ABRIR ARCHIVO
  Future<void> _openFile() async {
    if (_filePath == null) return;
    try {
      final response = await http.post(
        Uri.parse('http://192.168.1.73:8001/api/system/open_file'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'path': _filePath}),
      );
      if (response.statusCode != 200) {
         throw Exception(response.body);
      }
    } catch (e) {
      _showErrorDialog("Error al Abrir", e.toString());
    }
  }

  // 4. EXPORTAR REPORTE
  Future<void> _exportReport() async {
    if (_detailedReport == null || _detailedReport!.isEmpty) return;
    try {
      final response = await http.post(
        Uri.parse('http://192.168.1.73:8001/api/excel/exportar_reporte'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(_detailedReport),
      );

      if (response.statusCode == 200) {
        // Guardar archivo
        String? outputFile = await FilePicker.platform.saveFile(
          dialogTitle: 'Guardar Reporte',
          fileName: 'Reporte_Auditoria.xlsx',
          allowedExtensions: ['xlsx'],
        );

        if (outputFile != null) {
          if (!outputFile.endsWith('.xlsx')) outputFile += '.xlsx';
          final file = File(outputFile);
          await file.writeAsBytes(response.bodyBytes);
          
          if (mounted) {
             displayInfoBar(context, builder: (context, close) {
              return InfoBar(
                title: const Text('Reporte Exportado'),
                content: Text('Guardado en: $outputFile'),
                severity: InfoBarSeverity.success,
                action: Button(
                  onPressed: () => _openLocalFile(outputFile!), 
                  child: const Text('Abrir'),
                ),
                onClose: close,
              );
            });
          }
        }
      } else {
         throw Exception(response.body);
      }
    } catch (e) {
      _showErrorDialog("Error Exportando", e.toString());
    }
  }

  Future<void> _openLocalFile(String path) async {
      try {
        await http.post(
          Uri.parse('http://192.168.1.73:8001/api/system/open_file'),
          body: json.encode({'path': path}),
          headers: {'Content-Type': 'application/json'},
        );
      } catch (_) {}
  }

  void _showErrorDialog(String title, String message) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (c) => ContentDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
             Row(
               children: [
                 Expanded(child: SelectableText(message, style: TextStyle(color: Colors.red))),
                 IconButton(
                   icon: const Icon(FluentIcons.copy),
                   onPressed: () {
                     Clipboard.setData(ClipboardData(text: message));
                     displayInfoBar(c, duration: const Duration(seconds: 2), builder: (context, close) {
                       return InfoBar(
                         title: const Text('Copiado'),
                         content: const Text('Error copiado al portapapeles'),
                         severity: InfoBarSeverity.success,
                         onClose: close,
                       );
                     });
                   },
                 ),
               ],
             ),
          ],
        ),
        actions: [
          Button(child: const Text("Cerrar"), onPressed: () => Navigator.pop(c)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: const PageHeader(title: Text('Auditor de Archivos')),
      content: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // PANEL SUPERIOR
            Card(
              child: Column(
                children: [
                   if (_fileName == null) ...[
                      Icon(FluentIcons.excel_document, size: 40, color: Colors.green),
                      const SizedBox(height: 10),
                      const Text('Auditor Multicolumna: Descripción, Medida, Simetría, Procesos', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 20),
                   ],
                   
                   Row(
                     mainAxisAlignment: MainAxisAlignment.center,
                     children: [
                       if (_fileName != null) ...[
                         Text('📄 $_fileName', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                         const SizedBox(width: 10),
                         IconButton(
                           icon: const Icon(FluentIcons.folder_open), 
                           onPressed: _openFile,
                           style: ButtonStyle(foregroundColor: ButtonState.all(Colors.blue)),
                         ),
                         const SizedBox(width: 20),
                         Button(
                           onPressed: _auditExcel,
                           child: const Text('Analizar Otro Archivo'),
                         ),
                       ] else 
                         FilledButton(
                            onPressed: _auditExcel,
                            child: const Text('Seleccionar Archivo Excel'),
                         ),
                     ],
                   ),
                   
                   if (_isProcessing) ...[
                     const SizedBox(height: 20),
                     const ProgressRing(),
                     const SizedBox(height: 10),
                     const Text('Procesando...'),
                   ]
                ],
              ),
            ),
            const SizedBox(height: 20),

            // AREA RESULTADOS
            Expanded(child: _buildResultsArea()),
            
            // FOOTER ACCIONES
            if (_errors != null && _errors!.isNotEmpty && !_isProcessing)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Button(
                      onPressed: _exportReport,
                      child: const Row(
                        children: [
                          Icon(FluentIcons.download),
                          SizedBox(width: 8),
                          Text('Exportar Reporte'),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      onPressed: _autoCorrect,
                      style: ButtonStyle(backgroundColor: ButtonState.all(Colors.blue)),
                      child: const Row(
                        children: [
                          Icon(FluentIcons.repair, color: Colors.white),
                          SizedBox(width: 8),
                          Text('Corregir Archivo Excel'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultsArea() {
    if (_isProcessing) return const SizedBox.shrink();

    if (_errors == null) {
      return const Center(child: Text('Selecciona un archivo para comenzar.', style: TextStyle(color: Colors.grey)));
    }

    if (_errors!.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(FluentIcons.check_mark, size: 64, color: Colors.successPrimaryColor),
            const SizedBox(height: 10),
            Text(
              '✅ Archivo Íntegro', 
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.successPrimaryColor)
            ),
            const Text('Todos los campos analizados coinciden con la BD.'),
          ],
        ),
      );
    }

    // 1. Agrupación en Tiempo de Renderizado
    Map<String, List<dynamic>> discrepanciasAgrupadas = {};
    for (var disc in _errors!) {
      String codigo = disc['codigo'] ?? 'Sin Código';
      if (!discrepanciasAgrupadas.containsKey(codigo)) {
        discrepanciasAgrupadas[codigo] = [];
      }
      discrepanciasAgrupadas[codigo]!.add(disc);
    }

    final codigos = discrepanciasAgrupadas.keys.toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '⚠️ ${_errors!.length} discrepancias encontradas en ${codigos.length} códigos de pieza:',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.warningPrimaryColor),
        ),
        const SizedBox(height: 5),
        Expanded(
          // 2. Nueva Estructura de Tarjetas por Código
          child: ListView.builder(
            itemCount: codigos.length,
            itemBuilder: (context, index) {
              final codigo = codigos[index];
              final items = discrepanciasAgrupadas[codigo]!;

              return Padding(
                padding: const EdgeInsets.only(bottom: 12.0),
                child: Card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Encabezado de la Tarjeta (Código)
                      Row(
                        children: [
                          Icon(FluentIcons.database, size: 20, color: Colors.blue),
                          const SizedBox(width: 8),
                          Text(codigo, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.blue)),
                          const SizedBox(width: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(color: Colors.red.withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
                            child: Text('${items.length} errores', style: TextStyle(color: Colors.red, fontSize: 12)),
                          )
                        ],
                      ),
                      const SizedBox(height: 10),
                      const Divider(),
                      const SizedBox(height: 10),
                      
                      // 2. Agrupación Secundaria (Por "Firma del Error")
                      Builder(builder: (context) {
                        Map<String, List<int>> erroresUnicosMap = {};
                        // Guardar la primera ocurrencia completa del error para extraer 'campo', 'excel', 'bd' al dibujar
                        Map<String, dynamic> primeraInstancia = {};

                        for (var item in items) {
                          final campo = item['campo'] ?? 'N/A';
                          final valExcel = item['excel']?.toString() ?? 'null';
                          final valBd = item['bd']?.toString() ?? 'null';
                          
                          // Firma Única Combinada
                          final firma = "Col:$campo|Excel:$valExcel|BD:$valBd";
                          
                          if (!erroresUnicosMap.containsKey(firma)) {
                            erroresUnicosMap[firma] = [];
                            primeraInstancia[firma] = item;
                          }
                          erroresUnicosMap[firma]!.add(item['fila'] as int);
                        }

                        // 3. Bloque de Error Agrupado
                        return Column(
                          children: erroresUnicosMap.keys.map((firma) {
                            final filas = erroresUnicosMap[firma]!;
                            final itemRef = primeraInstancia[firma]!;
                            
                            // Unir números de fila únicos
                            filas.sort();
                            final filasStr = filas.join(', ');

                            return Padding(
                              padding: const EdgeInsets.only(bottom: 12.0),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Encabezado de Filas Combinadas
                                  Container(
                                    width: 100, // Un poco más ancho por si hay muchas filas
                                    padding: const EdgeInsets.all(4),
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(4)),
                                    child: Text(
                                      filas.length > 1 ? 'Filas $filasStr' : 'Fila $filasStr', 
                                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                  const SizedBox(width: 15),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(color: Colors.blue.withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
                                          child: Text(itemRef['campo'], style: TextStyle(color: Colors.blue, fontSize: 12)),
                                        ),
                                        const SizedBox(height: 5),
                                        // Comparación visual usando el registro de la primeraInstancia
                                        Row(
                                          children: [
                                            Expanded(child: SelectableText(itemRef['excel'].toString(), style: TextStyle(color: Colors.red))),
                                            const Padding(
                                              padding: EdgeInsets.symmetric(horizontal: 8.0),
                                              child: Icon(FluentIcons.forward, size: 14, color: Colors.grey),
                                            ),
                                            Expanded(child: SelectableText(itemRef['bd'].toString(), style: TextStyle(color: Colors.green))),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }).toList(),
                        );
                      }),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
