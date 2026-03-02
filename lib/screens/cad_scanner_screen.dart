import 'package:fluent_ui/fluent_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
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

  @override
  Widget build(BuildContext context) {
    final bool isScanning = _status == 'scanning' || _status == 'generating_excel';

    return ScaffoldPage(
      header: const PageHeader(
        title: Text('Escáner de Directorios CAD'),
      ),
      content: Padding(
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
                    const Icon(FluentIcons.completed_solid, size: 48, color: Colors.green),
                    const SizedBox(height: 16),
                    const Text(
                      '¡Escaneo Finalizado con Éxito!',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text('Se encontraron y procesaron $_progress archivos CAD únicos.'),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: () {
                        // Aquí se podría implementar la descarga del Excel
                        displayInfoBar(context, builder: (context, close) {
                          return InfoBar(
                            title: const Text('Descarga'),
                            content: Text('El archivo se encuentra en el servidor en la ruta:\n$_excelPath'),
                            severity: InfoBarSeverity.info,
                            onClose: close,
                          );
                        });
                      },
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
          ],
        ),
      ),
    );
  }
}
