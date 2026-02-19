import 'dart:convert';
import 'dart:io';
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
          "Se creará una copia de seguridad del archivo actual (con sufijo '-retirado') y se aplicarán todas las correcciones de la BD al archivo original.\n\n¿Deseas continuar?"
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
      request.fields['file_path'] = _filePath!;

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (mounted) {
          displayInfoBar(context, builder: (context, close) {
            return InfoBar(
              title: const Text('Corrección Exitosa'),
              content: Text("${data['mensaje']}"),
              severity: InfoBarSeverity.success,
              onClose: close,
            );
          });
          // Recargar auditoría para confirmar? O simplemente mostrar éxito?
          // Limpiamos errores para indicar que se solucionó
          setState(() => _errors = []); 
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
        content: SelectableText(message, style: TextStyle(color: Colors.red)),
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '⚠️ ${_errors!.length} discrepancias encontradas:',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.warningPrimaryColor),
        ),
        const SizedBox(height: 5),
        Expanded(
          child: ListView.builder(
            itemCount: _errors!.length,
            itemBuilder: (context, index) {
              final item = _errors![index];
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Container(
                      width: 60,
                      padding: const EdgeInsets.all(4),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(4)),
                      child: Text('Fila ${item['fila']}', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(width: 15),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(item['codigo'], style: const TextStyle(fontWeight: FontWeight.bold)),
                              const SizedBox(width: 10),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(color: Colors.blue.withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
                                child: Text(item['campo'], style: TextStyle(color: Colors.blue, fontSize: 12)),
                              ),
                            ],
                          ),
                          const SizedBox(height: 5),
                          Row(
                            children: [
                              Expanded(child: SelectableText(item['excel'], style: TextStyle(color: Colors.red))),
                              const Icon(FluentIcons.forward, size: 14, color: Colors.grey),
                              const SizedBox(width: 5),
                              Expanded(child: SelectableText(item['bd'], style: TextStyle(color: Colors.green))),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
