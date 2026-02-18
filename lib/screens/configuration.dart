import 'package:fluent_ui/fluent_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';



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
            const Text('Actualizador de Hipervínculos', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            const Text(
              'Escanea la carpeta de ingeniería buscando archivos (PDF/JPG) que coincidan con los códigos de pieza y actualiza sus enlaces en la base de datos.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 15),
            Button(
              onPressed: _isScanning || _pathController.text.isEmpty ? null : _updateLinks,
              child: _isScanning 
                  ? const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ProgressRing(strokeWidth: 2),
                        SizedBox(width: 8),
                        Text('Escaneando archivos...'),
                      ],
                    )
                  : const Text('Escanear y Actualizar Hipervínculos'),
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
          ],
        ),
      ),
    );
  }

  bool _isScanning = false;

  Future<void> _updateLinks() async {
    setState(() {
      _isScanning = true;
    });

    try {
      final response = await http.post(
        Uri.parse('http://192.168.1.73:8001/api/config/update_links'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'root_path': _pathController.text}),
      ).timeout(const Duration(minutes: 5));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (mounted) {
           displayInfoBar(context, builder: (context, close) {
            return InfoBar(
              title: const Text('Escaneo Completado'),
              content: Text('Se actualizaron ${data['updated']} enlaces correctamente.'),
              severity: InfoBarSeverity.success,
              onClose: close,
            );
          });
        }
      } else {
        throw Exception("Error del servidor: ${response.body}");
      }
    } catch (e) {
      if (mounted) {
        _showErrorDialog("Error al escanear: $e");
      }
    } finally {
      if (mounted) {
        setState(() => _isScanning = false);
      }
    }
  }

  void _showErrorDialog(String msg) {
    showDialog(
      context: context,
      builder: (c) => ContentDialog(
        title: const Text("Error"),
        content: Text(msg),
        actions: [
          Button(child: const Text("Cerrar"), onPressed: () => Navigator.pop(c)),
        ],
      ),
    );
  }
}
