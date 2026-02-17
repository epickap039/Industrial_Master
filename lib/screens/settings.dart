import 'dart:convert';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';

class SettingsScreen extends StatefulWidget {
  final bool isDarkMode;
  final Function(bool) onThemeChanged;

  const SettingsScreen({
    super.key,
    required this.isDarkMode,
    required this.onThemeChanged,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _connectionStatus = 'Verificando...';
  Color _statusColor = Colors.yellow;
  bool _isSyncing = false;

  @override
  void initState() {
    super.initState();
    _checkConnection();
  }

  Future<void> _checkConnection() async {
    try {
      final response = await http.get(Uri.parse('http://127.0.0.1:8001/docs'));
      if (response.statusCode == 200) {
        if (mounted) {
          setState(() {
            _connectionStatus = 'Conectado (Puerto 8001)';
            _statusColor = Colors.green;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _connectionStatus = 'Error: ${response.statusCode}';
            _statusColor = Colors.red;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _connectionStatus = 'Desconectado';
          _statusColor = Colors.red;
        });
      }
    }
  }

  Future<void> _syncDriveLinks() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
        dialogTitle: 'Selecciona Listado_PDFs_BD.xlsx',
      );

      if (result != null && result.files.single.path != null) {
        setState(() => _isSyncing = true);
        
        String filePath = result.files.single.path!;
        
        final response = await http.post(
          Uri.parse('http://127.0.0.1:8001/api/sync/drive'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({'excel_path': filePath}),
        );

        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          int count = data['updated_count'];
          
          if (mounted) {
            displayInfoBar(context, builder: (context, close) {
              return InfoBar(
                title: const Text('Sincronización Exitosa'),
                content: Text('Se actualizaron $count enlaces de Drive.'),
                severity: InfoBarSeverity.success,
                onClose: close,
              );
            });
          }
        } else {
          final error = json.decode(response.body)['detail'];
          if (mounted) {
            displayInfoBar(context, builder: (context, close) {
              return InfoBar(
                title: const Text('Error de Sincronización'),
                content: Text(error.toString()),
                severity: InfoBarSeverity.error,
                onClose: close,
              );
            });
          }
        }
      }
    } catch (e) {
      if (mounted) {
        displayInfoBar(context, builder: (context, close) {
          return InfoBar(
            title: const Text('Error Crítico'),
            content: Text(e.toString()),
            severity: InfoBarSeverity.error,
            onClose: close,
          );
        });
      }
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: const PageHeader(title: Text('Configuración')),
      content: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // Sección de Apariencia
          Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Apariencia',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 10),
                ToggleSwitch(
                  checked: widget.isDarkMode,
                  onChanged: widget.onThemeChanged,
                  content: Text(widget.isDarkMode ? 'Modo Oscuro' : 'Modo Claro'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Sección de Conexión
          Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Estado del Servidor',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: _statusColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(_connectionStatus),
                    const Spacer(),
                    Button(
                      onPressed: _checkConnection,
                      child: const Text('Comprobar'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          
          // Sección de Mantenimiento de Datos
          Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Mantenimiento de Datos',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 10),
                const Text('Sincronizar enlaces de archivos PDF/Drive desde Excel Maestro.'),
                const SizedBox(height: 10),
                _isSyncing 
                  ? const ProgressRing()
                  : Button(
                      onPressed: _syncDriveLinks,
                      child: const Text('Actualizar Enlaces Drive (Excel)'),
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
