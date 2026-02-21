import 'dart:convert';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';

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
  // Estado para Conexión
  String _connectionStatus = 'Sin verificar';
  Color _statusColor = Colors.grey;
  bool _isChecking = false;

  // Estado para Sincronización
  bool _isSyncing = false;

  // Estado Regla Espejo (Fase 19)
  bool _reglaEspejoActiva = true; 

  @override
  void initState() {
    super.initState();
    _checkConnection(silent: true);
    _fetchMirrorRuleStatus();
  }

  Future<void> _fetchMirrorRuleStatus() async {
    try {
      final response = await http.get(Uri.parse('http://192.168.1.73:8001/api/config/regla_espejo'));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (mounted) {
          setState(() {
            _reglaEspejoActiva = data['activa'] ?? true;
          });
        }
      }
    } catch (e) {
      print("Error fetching mirror rule: $e");
    }
  }

  Future<void> _toggleMirrorRule(bool value) async {
    // Optimistic UI Update
    setState(() => _reglaEspejoActiva = value);

    try {
      final response = await http.post(
        Uri.parse('http://192.168.1.73:8001/api/config/regla_espejo'),
        headers: {"Content-Type": "application/json"},
        body: json.encode({"activa": value}),
      );

      if (response.statusCode == 200) {
        if (mounted) {
           displayInfoBar(context, builder: (context, close) {
              return InfoBar(
                title: const Text('Configuración Actualizada'),
                content: Text(value ? 'Regla Espejo ACTIVADA' : 'Regla Espejo DESACTIVADA'),
                severity: InfoBarSeverity.success,
                onClose: close,
              );
            });
        }
      } else {
        // Revertir si falla
        setState(() => _reglaEspejoActiva = !value);
        throw Exception("Error ${response.statusCode}");
      }
    } catch (e) {
      // Revertir
      setState(() => _reglaEspejoActiva = !value);
      if (mounted) {
        displayInfoBar(context, builder: (context, close) {
          return InfoBar(
            title: const Text('Error'),
            content: Row(
              children: [
                Expanded(child: SelectableText("No se pudo actualizar la configuración: $e")),
                IconButton(icon: const Icon(FluentIcons.copy), onPressed: () => Clipboard.setData(ClipboardData(text: "No se pudo actualizar la configuración: $e"))),
              ],
            ),
            severity: InfoBarSeverity.error,
            onClose: close,
          );
        });
      }
    }
  }

  Future<void> _checkConnection({bool silent = false}) async {
    setState(() {
      _isChecking = true;
      _connectionStatus = 'Conectando...';
      _statusColor = Colors.blue;
    });

    try {
      final response = await http.get(Uri.parse('http://192.168.1.73:8001/api/catalog?limit=1')).timeout(const Duration(seconds: 3));
      
      if (response.statusCode == 200) {
        if (mounted) {
          setState(() {
            _connectionStatus = 'Conectado (Online)';
            _statusColor = Colors.successPrimaryColor;
          });
          
          if (!silent) {
            displayInfoBar(context, builder: (context, close) {
              return InfoBar(
                title: const Text('Diagnóstico Exitoso'),
                content: const Text('✅ El servidor SQL y la API están respondiendo correctamente.'),
                severity: InfoBarSeverity.success,
                onClose: close,
              );
            });
          }
        }
      } else {
        throw Exception("Error API: ${response.statusCode}");
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _connectionStatus = 'Sin Conexión';
          _statusColor = Colors.errorPrimaryColor;
        });

        if (!silent) {
           displayInfoBar(context, builder: (context, close) {
              return InfoBar(
                title: const Text('Fallo de Conexión'),
                content: Row(
                  children: [
                    Expanded(child: SelectableText('❌ No se pudo conectar al servidor: $e')),
                    IconButton(icon: const Icon(FluentIcons.copy), onPressed: () => Clipboard.setData(ClipboardData(text: '❌ No se pudo conectar al servidor: $e'))),
                  ],
                ),
                severity: InfoBarSeverity.error,
                onClose: close,
              );
            });
        }
      }
    } finally {
      if (mounted) setState(() => _isChecking = false);
    }
  }

  Future<void> _syncDriveLinks() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
        dialogTitle: 'Seleccionar Listado de Enlaces (Excel)',
      );

      if (result == null || result.files.single.path == null) return;

      setState(() => _isSyncing = true);
      
      final filePath = result.files.single.path!;
      final fileName = result.files.single.name;

      var request = http.MultipartRequest(
        'POST',
        Uri.parse('http://192.168.1.73:8001/api/excel/actualizar_enlaces'),
      );

      request.files.add(await http.MultipartFile.fromPath('file', filePath));

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (mounted) {
          displayInfoBar(context, builder: (context, close) {
            return InfoBar(
              title: const Text('Sincronización Exitosa'),
              content: Text('Se actualizaron ${data['actualizados']} enlaces desde "$fileName".'),
              severity: InfoBarSeverity.success,
              onClose: close,
            );
          });
        }
      } else {
        String errorDetail = response.body;
        try {
          final errorData = json.decode(response.body);
          if (errorData is Map && errorData.containsKey('detail')) {
            errorDetail = errorData['detail'].toString();
          }
        } catch (_) {}
        throw Exception("Error del servidor (${response.statusCode}): $errorDetail");
      }
    } catch (e) {
      if (mounted) {
        displayInfoBar(context, builder: (context, close) {
          return InfoBar(
            title: const Text('Error de Sincronización'),
            content: Row(
              children: [
                Expanded(child: SelectableText(e.toString())),
                IconButton(icon: const Icon(FluentIcons.copy), onPressed: () => Clipboard.setData(ClipboardData(text: e.toString()))),
              ],
            ),
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
      header: const PageHeader(title: Text('Configuración del Sistema')),
      content: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // 1. APARIENCIA
          Expander(
            header: const Text('Apariencia', style: TextStyle(fontWeight: FontWeight.bold)),
            initiallyExpanded: true,
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ToggleSwitch(
                  checked: widget.isDarkMode,
                  onChanged: widget.onThemeChanged,
                  content: Text(widget.isDarkMode ? 'Modo Oscuro Activado' : 'Modo Claro Activado'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // 2. DIAGNÓSTICO DE RED (Modificado)
          Expander(
            header: const Text('Diagnóstico de Red', style: TextStyle(fontWeight: FontWeight.bold)),
            initiallyExpanded: true,
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text('Estado del Servidor:', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(width: 10),
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(color: _statusColor, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 8),
                    Text(_connectionStatus),
                    const Spacer(),
                    Button(
                      // Acción modificada: usa la nueva lógica con feedback visual
                      onPressed: _isChecking ? null : () => _checkConnection(silent: false),
                      child: _isChecking ? const ProgressRing(strokeWidth: 2.0) : const Text('Ejecutar Diagnóstico'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const Text(
                  'Prueba la conexión con el servidor (192.168.1.73:8001) y la base de datos SQL.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // 3. REGLAS DE NEGOCIO (FASE 19)
          Expander(
            header: const Text('Reglas de Negocio', style: TextStyle(fontWeight: FontWeight.bold)),
            initiallyExpanded: true,
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ToggleSwitch(
                  checked: _reglaEspejoActiva,
                  onChanged: _toggleMirrorRule,
                  content: Text(_reglaEspejoActiva 
                    ? 'Regla Espejo ACTIVADA (Material = Descripción)' 
                    : 'Regla Espejo DESACTIVADA'),
                ),
                const SizedBox(height: 5),
                const Text(
                  'Si se activa, al crear o editar una pieza, el campo "Material" copiará automáticamente el valor de "Descripción".',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // 4. MANTENIMIENTO
          Expander(
            header: const Text('Mantenimiento de Datos', style: TextStyle(fontWeight: FontWeight.bold)),
            initiallyExpanded: true,
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Sincronización de Enlaces (Drive/PDF)', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 5),
                const Text(
                  'Carga un archivo Excel ("Listado_PDFs_BD.xlsx") para actualizar masivamente los enlaces de Google Drive en el Catálogo Maestro.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 15),
                _isSyncing 
                  ? const ProgressBar()
                  : Button(
                      onPressed: _syncDriveLinks,
                      child: const Text('Actualizar Enlaces Drive (Desde Excel)'),
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
