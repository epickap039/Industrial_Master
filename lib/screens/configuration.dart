import 'package:fluent_ui/fluent_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:io';
import 'dart:convert';
import 'arbitration.dart';

class ConfigurationScreen extends StatefulWidget {
  const ConfigurationScreen({super.key});

  @override
  State<ConfigurationScreen> createState() => _ConfigurationScreenState();
}

class _ConfigurationScreenState extends State<ConfigurationScreen> {
  final TextEditingController _pathController = TextEditingController();
  String _statusMessage = '';
  Color _statusColor = Colors.grey;
  bool _isChecking = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _pathController.text = prefs.getString('ingenieria_path') ?? r'Z:\Ingenieria';
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ingenieria_path', _pathController.text);
    if (mounted) {
      displayInfoBar(context, builder: (context, close) {
        return InfoBar(
          title: const Text('Guardado'),
          content: const Text('Configuración actualizada correctamente'),
          severity: InfoBarSeverity.success,
          onClose: close,
        );
      });
    }
  }

  Future<void> _pickFolder() async {
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Seleccionar Carpeta de Ingeniería',
      initialDirectory: _pathController.text,
    );

    if (selectedDirectory != null) {
      setState(() {
        _pathController.text = selectedDirectory;
      });
      _saveSettings();
    }
  }

  Future<void> _runDiagnostics() async {
    setState(() {
      _isChecking = true;
      _statusMessage = 'Verificando conectividad...';
      _statusColor = Colors.blue;
    });

    try {
      // 1. Verificar Backend (Puerto 8001)
      final response = await http.get(Uri.parse('http://192.168.1.73:8001/docs')).timeout(const Duration(seconds: 5));
      
      if (response.statusCode == 200) {
        // 2. Verificar SQL (Indirectamente via Backend)
        // Podríamos agregar un endpoint específico, pero por ahora asumimos que si el backend responde, es buen inicio.
        // Idealmente: await http.get('.../api/health')
        
        setState(() {
          _statusMessage = 'Conexión EXITOSA (Backend 8001 OK)';
          _statusColor = Colors.successPrimaryColor;
        });
      } else {
        setState(() {
          _statusMessage = 'Error Backend: ${response.statusCode}';
          _statusColor = Colors.warningPrimaryColor;
        });
      }
    } catch (e) {
      setState(() {
        _statusMessage = 'FALLO DE CONEXIÓN: $e';
        _statusColor = Colors.errorPrimaryColor;
      });
    } finally {
      setState(() {
        _isChecking = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: const PageHeader(title: Text('Configuración del Sistema')),
      content: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Ruta Base de Ingeniería', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextBox(
                    controller: _pathController,
                    placeholder: r'Z:\Ingenieria',
                    readOnly: true, // Para obligar a usar el picker
                  ),
                ),
                const SizedBox(width: 10),
                Button(
                  onPressed: _pickFolder,
                  child: const Text('Examinar...'),
                ),
              ],
            ),
            const SizedBox(height: 30),
            const Divider(),
            const SizedBox(height: 30),
            const Text('Diagnóstico de Red', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Button(
              onPressed: _isChecking ? null : _runDiagnostics,
              child: _isChecking 
                  ? const ProgressRing(strokeWidth: 2) 
                  : const Text('Ejecutar Diagnóstico (8001/1433)'),
            ),
            const SizedBox(height: 30),
            const Text('Importación de Datos', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Row(
              children: [
                Button(
                  onPressed: _isChecking ? null : _processExcelBOM,
                  child: _isChecking 
                      ? const ProgressRing(strokeWidth: 2) 
                      : const Text('Importar BOM Excel (Recalcular Conflictos)'),
                ),
                const SizedBox(width: 10),
                if (_lastProcessedResult != null)
                   Text("Último escaneo: ${_lastProcessedResult?['conflictos']?.length ?? 0} conflictos"),
              ],
            ),
            const SizedBox(height: 15),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: _statusColor.withOpacity(0.1),
                border: Border.all(color: _statusColor),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                children: [
                  Icon(
                    _statusColor == Colors.successPrimaryColor ? FluentIcons.check_mark : FluentIcons.error,
                    color: _statusColor,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _statusMessage.isEmpty ? 'Listo para diagnosticar o importar' : _statusMessage,
                      style: TextStyle(color: _statusColor, fontWeight: FontWeight.bold),
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

  // Resultado temporal para mostrar en UI
  Map<String, dynamic>? _lastProcessedResult;

  Future<void> _processExcelBOM() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
      dialogTitle: 'Seleccionar BOM de Ingeniería',
    );

    if (result == null || result.files.single.path == null) return;

    setState(() {
      _isChecking = true;
      _statusMessage = 'Procesando Excel (Esto puede tardar)...';
      _statusColor = Colors.blue;
    });

    try {
      final file = File(result.files.single.path!);
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('http://192.168.1.73:8001/api/excel/procesar'), // Ajustar IP si es necesario
      );
      
      request.files.add(await http.MultipartFile.fromPath('file', file.path));
      
      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final jsonResponse = json.decode(response.body);
        setState(() {
          _lastProcessedResult = jsonResponse;
          _statusMessage = jsonResponse['mensaje'];
          _statusColor = Colors.successPrimaryColor;
          _isChecking = false;
        });

        // Navegar a Arbitraje si hay conflictos
        final List<dynamic> conflictos = jsonResponse['conflictos'] ?? [];
        if (conflictos.isNotEmpty) {
           Navigator.push(
            context, 
            FluentPageRoute(builder: (context) => ArbitrationScreen(
              conflicts: conflictos,
              totalProcessed: jsonResponse['total_leidos'] ?? 0,
            ))
          );
        } else {
           _showDialog("Perfecto", "No se encontraron discrepancias entre Excel y SQL.");
        }

      } else {
        throw Exception('Error Backend: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      setState(() {
        _statusMessage = 'Error Procesando: $e';
        _statusColor = Colors.errorPrimaryColor;
        _isChecking = false;
      });
    }
  }

  void _showDialog(String title, String content) {
    showDialog(context: context, builder: (c) => ContentDialog(
      title: Text(title),
      content: Text(content),
      actions: [Button(child: const Text('Ok'), onPressed: () => Navigator.pop(c))],
    ));
  }
}
