import 'package:fluent_ui/fluent_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import '../main.dart'; // Para API_URL

class CADScannerScreen extends StatefulWidget {
  const CADScannerScreen({Key? key}) : super(key: key);

  @override
  State<CADScannerScreen> createState() => _CADScannerScreenState();
}

class _CADScannerScreenState extends State<CADScannerScreen> {
  final TextEditingController _pathController = TextEditingController();
  
  String _status = 'idle';
  int _progress = 0;
  int _total = 0;
  String _excelPath = '';
  String _errorMessage = '';
  
  Timer? _statusTimer;

  @override
  void dispose() {
    _statusTimer?.cancel();
    _pathController.dispose();
    super.dispose();
  }

  void _startPolling() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      _fetchStatus();
    });
  }

  void _stopPolling() {
    _statusTimer?.cancel();
    _statusTimer = null;
  }

  Future<void> _fetchStatus() async {
    try {
      final response = await http.get(Uri.parse('$API_URL/api/cad/status'));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (mounted) {
          setState(() {
            _status = data['status'] ?? 'idle';
            _progress = data['progress'] ?? 0;
            _total = data['total'] ?? 0;
            _excelPath = data['excel_path'] ?? '';
            _errorMessage = data['error'] ?? '';
          });

          if (_status == 'completed' || _status == 'cancelled' || _status == 'error') {
            _stopPolling();
            if (_status == 'error') {
              displayInfoBar(context, builder: (context, close) {
                return InfoBar(
                  title: const Text('Error en escaneo'),
                  content: Text(_errorMessage),
                  severity: InfoBarSeverity.error,
                  onClose: close,
                );
              });
            } else if (_status == 'cancelled') {
              displayInfoBar(context, builder: (context, close) {
                return InfoBar(
                  title: const Text('Cancelado'),
                  content: const Text('El escaneo ha sido cancelado.'),
                  severity: InfoBarSeverity.warning,
                  onClose: close,
                );
              });
            }
          }
        }
      }
    } catch (e) {
      // Ignoramos errores de red durante el polling
    }
  }

  Future<void> _startScan() async {
    final rootPath = _pathController.text.trim();
    if (rootPath.isEmpty) {
      displayInfoBar(context, builder: (context, close) {
        return InfoBar(
          title: const Text('Ruta vacía'),
          content: const Text('Por favor, ingresa una ruta válida para escanear.'),
          severity: InfoBarSeverity.error,
          onClose: close,
        );
      });
      return;
    }

    setState(() {
      _status = 'scanning';
      _progress = 0;
      _excelPath = '';
      _errorMessage = '';
    });

    try {
      final response = await http.post(
        Uri.parse('$API_URL/api/cad/scan'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'root_path': rootPath}),
      );

      if (response.statusCode == 200) {
        _startPolling();
      } else {
        setState(() => _status = 'error');
        displayInfoBar(context, builder: (context, close) {
          return InfoBar(
            title: const Text('Error al iniciar'),
            content: Text('Código: ${response.statusCode}'),
            severity: InfoBarSeverity.error,
            onClose: close,
          );
        });
      }
    } catch (e) {
      setState(() => _status = 'error');
      displayInfoBar(context, builder: (context, close) {
        return InfoBar(
          title: const Text('Error de conexión'),
          content: Text(e.toString()),
          severity: InfoBarSeverity.error,
          onClose: close,
        );
      });
    }
  }

  Future<void> _cancelScan() async {
    try {
      await http.post(
        Uri.parse('$API_URL/api/cad/scan'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'root_path': 'cancel'}),
      );
      // El polling actualizará el estado a cancelled
    } catch (e) {
      displayInfoBar(context, builder: (context, close) {
        return InfoBar(
          title: const Text('Error al cancelar'),
          content: Text(e.toString()),
          severity: InfoBarSeverity.error,
          onClose: close,
        );
      });
    }
  }

  Future<void> _pickDirectory() async {
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Selecciona el directorio raíz de CAD',
    );

    if (selectedDirectory != null) {
      setState(() {
        _pathController.text = selectedDirectory;
      });
    }
  }

  Future<void> _downloadExcel() async {
    String? outputFile = await FilePicker.platform.saveFile(
      dialogTitle: 'Guardar Reporte',
      fileName: 'Reporte_CAD.xlsx',
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
    );

    if (outputFile == null) return;
    
    try {
      final response = await http.get(Uri.parse('$API_URL/api/cad/download'));
      if (response.statusCode == 200) {
        final file = File(outputFile);
        await file.writeAsBytes(response.bodyBytes);
        displayInfoBar(context, builder: (context, close) {
          return InfoBar(
            title: const Text('Descarga Completa'),
            content: Text('Guardado en:\n$outputFile'),
            severity: InfoBarSeverity.success,
            onClose: close,
          );
        });
      } else {
        throw Exception('Error al descargar: ${response.statusCode}');
      }
    } catch (e) {
      displayInfoBar(context, builder: (context, close) {
        return InfoBar(
          title: const Text('Error Descargando'),
          content: Text('$e'),
          severity: InfoBarSeverity.error,
          onClose: close,
        );
      });
    }
  }

  Future<void> _uploadModifiedExcel() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
      dialogTitle: 'Seleccionar Archivo Modificado',
    );

    if (result == null || result.files.single.path == null) return;
    String filePath = result.files.single.path!;
    
    // Mostrar que está cargando...
    bool isUploading = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return const ContentDialog(
          title: Text('Subiendo e Importando...'),
          content: Center(child: ProgressRing()),
        );
      }
    );

    try {
      var request = http.MultipartRequest('POST', Uri.parse('$API_URL/api/cad/upload'));
      request.files.add(await http.MultipartFile.fromPath('file', filePath));
      
      var response = await request.send();
      var responseData = await http.Response.fromStream(response);
      
      Navigator.pop(context); // Cerrar diálogo de carga
      isUploading = false;

      if (response.statusCode == 200) {
        final data = json.decode(responseData.body);
        int act = data['actualizadas'] ?? 0;
        int err = data['errores'] ?? 0;
        List<dynamic> det = data['detalles_errores'] ?? [];
        
        showDialog(
          context: context,
          builder: (context) {
            return ContentDialog(
              title: const Text('Resultado de la Actualización'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Piezas actualizadas correctamente: $act'),
                  Text('Filas con error o ignoradas: $err'),
                  if (det.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Text('Detalles de errores:', style: TextStyle(fontWeight: FontWeight.bold)),
                    Container(
                      height: 100,
                      decoration: BoxDecoration(border: Border.all(color: Colors.grey)),
                      child: ListView.builder(
                        itemCount: det.length,
                        itemBuilder: (context, idx) {
                          return Padding(
                            padding: const EdgeInsets.all(4.0),
                            child: Text('- ${det[idx]}'),
                          );
                        },
                      ),
                    )
                  ]
                ],
              ),
              actions: [
                Button(
                   child: const Text('Cerrar'), 
                   onPressed: () => Navigator.pop(context),
                )
              ],
            );
          }
        );
      } else {
        throw Exception('El servidor devolvió Error ${response.statusCode}: ${responseData.body}');
      }
    } catch (e) {
      if (isUploading) Navigator.pop(context);
      displayInfoBar(context, builder: (context, close) {
        return InfoBar(
          title: const Text('Error de subida'),
          content: Text(e.toString()),
          severity: InfoBarSeverity.error,
          onClose: close,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isScanning = _status == 'scanning' || _status == 'generating_excel';

    return ScaffoldPage(
      header: const PageHeader(
        title: Text('Escáner de Directorios CAD'),
      ),
      content: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Sección de Input
              const Text(
                'Ruta a escanear (Búsqueda Recursiva):',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextBox(
                    controller: _pathController,
                    placeholder: r'Ej. Z:\Ingenieria\SolidWorks',
                    enabled: !isScanning,
                  ),
                ),
                const SizedBox(width: 12),
                Tooltip(
                  message: 'Seleccionar Carpeta',
                  child: IconButton(
                    icon: const Icon(FluentIcons.folder_open, size: 20),
                    onPressed: isScanning ? null : _pickDirectory,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            
            // Botones de acción
            Row(
              children: [
                FilledButton(
                  onPressed: isScanning ? null : _startScan,
                  style: ButtonStyle(
                    backgroundColor: isScanning 
                      ? ButtonState.all(Colors.grey) 
                      : ButtonState.all(Colors.green),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text('Iniciar Escaneo', style: TextStyle(fontSize: 16)),
                  ),
                ),
                if (isScanning) ...[
                  const SizedBox(width: 16),
                  Button(
                    onPressed: _status == 'scanning' ? _cancelScan : null,
                    style: ButtonStyle(
                      backgroundColor: ButtonState.all(Colors.red.withOpacity(0.1)),
                      foregroundColor: ButtonState.all(Colors.red),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Text('Cancelar', style: TextStyle(fontSize: 16)),
                    ),
                  ),
                ],
              ],
            ),
            
            const SizedBox(height: 48),

            // Zona de Progreso
            if (isScanning) ...[
              const Text('Progreso del escaneo:'),
              const SizedBox(height: 8),
              if (_status == 'generating_excel') ...[
                const ProgressBar(),
                const SizedBox(height: 8),
                const Text('Generando reporte Excel...', style: TextStyle(fontStyle: FontStyle.italic)),
              ] else ...[
                if (_total > 0)
                  ProgressBar(value: (_progress / _total) * 100)
                else
                  const ProgressBar(), // Indeterminada
                const SizedBox(height: 8),
                Text(
                  'Escaneando... $_progress archivos encontrados',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ],

            // Zona de Resultados
            if (_status == 'completed') ...[
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.green),
                ),
                child: Column(
                  children: [
                    Icon(FluentIcons.completed_solid, size: 48, color: Colors.green),
                    const SizedBox(height: 16),
                    const Text(
                      '¡Escaneo Finalizado con Éxito!',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text('Se encontraron y procesaron $_progress archivos CAD únicos.'),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _downloadExcel,
                      style: ButtonStyle(
                        backgroundColor: ButtonState.all(Colors.blue),
                      ),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                        child: Text(
                          'Descargar Reporte Excel',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 48),

            // Tarjeta de actualización BD
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.05),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Actualizar Base de Datos',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  const Text('Sube el archivo Excel previament descargado con las columnas Largo_CAD y Ancho_CAD debidamente llenadas para actualizar el Catálogo Maestro.'),
                  const SizedBox(height: 16),
                  Button(
                    onPressed: isScanning ? null : _uploadModifiedExcel,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(FluentIcons.upload),
                          SizedBox(width: 8),
                          Text('Cargar Excel Modificado', style: TextStyle(fontSize: 16)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
