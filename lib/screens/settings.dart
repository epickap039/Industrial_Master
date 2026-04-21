import 'package:fluent_ui/fluent_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import '../config/app_config.dart';
import '../services/api_client.dart';
import '../services/app_role.dart';
import '../theme/ui_tokens.dart';
import '../widgets/compact_page_header.dart';
import 'configuracion_usuarios_screen.dart';
import '../widgets/dev_telemetry_settings_content.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

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

  // Rol del usuario QA (Fase RBAC)
  String _userRole = 'USER';

  @override
  void initState() {
    super.initState();
    _loadRole();
    _checkConnection(silent: true);
  }

  Future<void> _loadRole() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _userRole = prefs.getString('rol') ?? 'USER';
      });
    }
  }


  Future<void> _checkConnection({bool silent = false}) async {
    setState(() {
      _isChecking = true;
      _connectionStatus = 'Conectando...';
      _statusColor = Colors.blue;
    });

    try {
      final response = await ApiClient.getUnvalidated(
        '/api/catalog',
        queryParameters: {'limit': '1'},
        timeout: const Duration(seconds: 3),
      );

      if (response.statusCode == 200) {
        if (mounted) {
          setState(() {
            _connectionStatus = 'Conectado (Online)';
            _statusColor = Colors.successPrimaryColor;
          });

          if (!silent) {
            displayInfoBar(
              context,
              builder: (context, close) {
                return InfoBar(
                  title: const Text('Diagnóstico Exitoso'),
                  content: const Text(
                    '✅ El servidor SQL y la API están respondiendo correctamente.',
                  ),
                  severity: InfoBarSeverity.success,
                  onClose: close,
                );
              },
            );
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
          displayInfoBar(
            context,
            builder: (context, close) {
              return InfoBar(
                title: const Text('Fallo de Conexión'),
                content: Row(
                  children: [
                    Expanded(
                      child: SelectableText(
                        '❌ No se pudo conectar al servidor: $e',
                      ),
                    ),
                    IconButton(
                      icon: const Icon(FluentIcons.copy),
                      onPressed:
                          () => Clipboard.setData(
                            ClipboardData(
                              text: '❌ No se pudo conectar al servidor: $e',
                            ),
                          ),
                    ),
                  ],
                ),
                severity: InfoBarSeverity.error,
                onClose: close,
              );
            },
          );
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

      final data = await ApiClient.postMultipart(
        '/api/excel/actualizar_enlaces',
        files: {'file': await ApiClient.fileField('file', filePath)},
      ) as Map;

      if (mounted) {
        displayInfoBar(
          context,
          builder: (context, close) {
            return InfoBar(
              title: const Text('Sincronización Exitosa'),
              content: Text(
                'Se actualizaron ${data['actualizados']} enlaces desde "$fileName".',
              ),
              severity: InfoBarSeverity.success,
              onClose: close,
            );
          },
        );
      }
    } catch (e) {
      if (mounted) {
        displayInfoBar(
          context,
          builder: (context, close) {
            return InfoBar(
              title: const Text('Error de Sincronización'),
              content: Row(
                children: [
                  Expanded(child: SelectableText(e.toString())),
                  IconButton(
                    icon: const Icon(FluentIcons.copy),
                    onPressed:
                        () => Clipboard.setData(
                          ClipboardData(text: e.toString()),
                        ),
                  ),
                ],
              ),
              severity: InfoBarSeverity.error,
              onClose: close,
            );
          },
        );
      }
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final palette = uiSurfacePaletteOf(context);
    final role = parseAppRole(_userRole);
    final canManageUsers =
        role == AppRole.administrador || role == AppRole.desarrollador;
    final secondaryTextStyle = TextStyle(
      fontSize: 12,
      height: 1.35,
      color: theme.typography.caption?.color ??
          theme.resources.textFillColorSecondary,
    );
    final labelStyle = theme.typography.body?.copyWith(
          fontWeight: FontWeight.w600,
        ) ??
        TextStyle(
          fontWeight: FontWeight.w600,
          color: theme.resources.textFillColorPrimary,
        );
    final bodyStyle = theme.typography.body ??
        TextStyle(color: theme.resources.textFillColorPrimary);
    return ScaffoldPage(
      padding: const EdgeInsets.only(top: 8),
      header: CompactPageHeader(
        title: Text(
          'Configuración del Sistema',
          style: FluentTheme.of(context).typography.title,
        ),
      ),
      content: Container(
        color: palette.surfaceBase,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
          // 1. DIAGNÓSTICO DE RED
          Expander(
            header: Text(
              'Diagnóstico de Red',
              style: theme.typography.subtitle?.copyWith(
                    fontWeight: FontWeight.bold,
                  ) ??
                  const TextStyle(fontWeight: FontWeight.bold),
            ),
            initiallyExpanded: true,
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('Estado del Servidor:', style: labelStyle),
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: _statusColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    Text(_connectionStatus, style: bodyStyle),
                    Button(
                      // Acción modificada: usa la nueva lógica con feedback visual
                      onPressed:
                          _isChecking
                              ? null
                              : () => _checkConnection(silent: false),
                      child:
                          _isChecking
                              ? const ProgressRing(strokeWidth: 2.0)
                              : const Text('Ejecutar Diagnóstico'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  'Prueba la conexión con el servidor ($kApiBaseUrl) y la base de datos SQL.',
                  style: secondaryTextStyle,
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // 2. MANTENIMIENTO
          if (_userRole != 'QA') ...[
            Expander(
              header: Text(
                'Mantenimiento de Datos',
                style: theme.typography.subtitle?.copyWith(
                      fontWeight: FontWeight.bold,
                    ) ??
                    const TextStyle(fontWeight: FontWeight.bold),
              ),
              initiallyExpanded: true,
              content: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Sincronización de Enlaces (Drive/PDF)',
                    style: labelStyle,
                  ),
                  const SizedBox(height: 5),
                  Text(
                    'Carga un archivo Excel ("Listado_PDFs_BD.xlsx") para actualizar masivamente los enlaces de Google Drive en el Catálogo Maestro.',
                    style: secondaryTextStyle,
                  ),
                  const SizedBox(height: 15),
                  _isSyncing
                      ? const ProgressBar()
                      : Button(
                        onPressed: _syncDriveLinks,
                        child: const Text(
                          'Actualizar Enlaces Drive (Desde Excel)',
                        ),
                      ),
                ],
              ),
            ),
          ],
          if (canManageUsers) ...[
            const SizedBox(height: 10),
            Expander(
              header: Text(
                'Administración de usuarios',
                style: theme.typography.subtitle?.copyWith(
                      fontWeight: FontWeight.bold,
                    ) ??
                    const TextStyle(fontWeight: FontWeight.bold),
              ),
              initiallyExpanded: false,
              content: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Gestiona altas, bajas y roles de usuarios del sistema.',
                    style: secondaryTextStyle,
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    child: const Text('Abrir panel de usuarios'),
                    onPressed: () {
                      Navigator.of(context).push(
                        FluentPageRoute(
                          builder: (_) => const ConfiguracionUsuariosScreen(),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
          if (role == AppRole.desarrollador) ...[
            const SizedBox(height: 10),
            Expander(
              header: Text(
                'Telemetría de uso (todos los usuarios)',
                style: theme.typography.subtitle?.copyWith(
                      fontWeight: FontWeight.bold,
                    ) ??
                    const TextStyle(fontWeight: FontWeight.bold),
              ),
              initiallyExpanded: false,
              content: const DevTelemetrySettingsContent(),
            ),
          ],
          ],
        ),
      ),
    );
  }
}
