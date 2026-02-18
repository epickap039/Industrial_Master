import 'package:fluent_ui/fluent_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;



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
          ],
        ),
      ),
    );
  }


}
