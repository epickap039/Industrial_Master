import 'package:fluent_ui/fluent_ui.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';

import 'screens/catalog.dart';

import 'screens/auditor.dart'; // Fase 12
import 'screens/arbitration.dart';
import 'screens/editor.dart';
import 'screens/settings.dart';
import 'screens/login.dart';
import 'screens/history.dart';
import 'screens/standardization.dart'; // Fase 18
import 'screens/materials_list.dart'; // Fase 20
import 'screens/project_management.dart';
import 'screens/bom_manager.dart';
import 'screens/vin_dossier.dart';
import 'screens/engineering_map.dart'; // v60.0: Mapa de Ingeniería
import 'screens/qa_dashboard.dart'; // Centro de QA
import 'screens/cad_scanner_screen.dart'; // Módulo CAD
import 'screens/lobby_screen.dart'; // Nuevo Lobby Rediseñado
import 'screens/impact_radar_screen.dart'; // Módulo Where-Used
import 'screens/mrp_screen.dart'; // MRP: Requerimiento de Materiales
import 'screens/analytics_screen.dart'; // Dashboard Analytics
import 'package:pasteboard/pasteboard.dart';
import 'package:flutter/services.dart';
import 'theme/app_themes.dart';
import 'screens/splash_screen.dart';
import 'config/app_config.dart';
import 'services/api_client.dart';
import 'services/arbitration_bridge.dart';
import 'services/main_nav.dart';
import 'widgets/constrained_app_body.dart';

const String API_URL = kApiBaseUrl;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  bool _isLoggedIn = false;
  bool _isLoadingAuth = true;
  String _userRole = 'USER';
  int topIndex = 0;
  int? targetRevisionId;
  List<AutoSuggestBoxItem<dynamic>> _searchItems = [];

  /// Compacto = solo íconos; open = barra ancha. El botón hamburguesa del AppBar alterna entre ambos.
  PaneDisplayMode _navPaneDisplayMode = PaneDisplayMode.compact;

  @override
  void initState() {
    super.initState();
    _checkLoginStatus();
  }

  Future<void> _checkLoginStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final isLoggedIn = prefs.getBool('isLoggedIn') ?? false;
    final loginDateStr = prefs.getString('loginDate');
    final storedRole = prefs.getString('rol') ?? 'USER';

    if (isLoggedIn && loginDateStr != null) {
      final loginDate = DateTime.parse(loginDateStr);
      final difference = DateTime.now().difference(loginDate).inDays;
      if (difference < 7) {
        setState(() {
          _isLoggedIn = true;
          _userRole = storedRole;
        });
      } else {
        // Caducó la sesión
        await prefs.setBool('isLoggedIn', false);
      }
    }
    setState(() {
      _isLoadingAuth = false;
    });
  }

  Future<void> _updateTheme(ThemeMode mode) async {
    appTheme.setTheme(
      mode == ThemeMode.dark
          ? AppThemeMode.industrialDark
          : AppThemeMode.corporateLight,
    );
  }

  void _onLoginSuccess() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _isLoggedIn = true;
      _userRole = prefs.getString('rol') ?? 'USER';
    });
  }

  void _showVINResult(dynamic vin) {
    showDialog(
      context: context,
      builder:
          (context) => ContentDialog(
            title: Text("Resumen de VIN: ${vin['vin']}"),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Tracto / Proyecto: ${vin['tracto']}"),
                Text("Tipo: ${vin['tipo']}"),
                Text("Versión: ${vin['version']}"),
                Text("Cliente: ${vin['cliente']}"),
                Text("Revisión: ${vin['numero_revision']}"),
                const SizedBox(height: 8),
                Text(
                  "Notas: ${vin['notas'] ?? 'Sin notas'}",
                  style: const TextStyle(fontStyle: FontStyle.italic),
                ),
              ],
            ),
            actions: [
              Button(
                child: const Text("Cerrar"),
                onPressed: () => Navigator.pop(context),
              ),
              FilledButton(
                child: const Text("Ir a la Lista"),
                onPressed: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    FluentPageRoute(
                      builder:
                          (context) => BOMManagerScreen(
                            idCliente: vin['id_cliente'],
                            clientName: vin['cliente'],
                          ),
                    ),
                  );
                },
              ),
            ],
          ),
    );
  }

  void _logout(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isLoggedIn', false);
    await prefs.remove('access_token');
    setState(() {
      _isLoggedIn = false;
    });
    Navigator.pushReplacementNamed(context, '/login');
  }

  void _showBugDialog(BuildContext context) {
    String modulo = "Otros";
    String gravedad = "Sugerencia";
    String descripcion = "";
    bool enviando = false;
    Uint8List? capturaBytes;
    String? capturaBase64;

    showDialog(
      context: context,
      builder:
          (context) => StatefulBuilder(
            builder: (context, setDState) {
              return Focus(
                autofocus: true,
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent &&
                      (HardwareKeyboard.instance.isControlPressed ||
                          HardwareKeyboard.instance.isMetaPressed) &&
                      event.logicalKey == LogicalKeyboardKey.keyV) {
                    Pasteboard.image.then((bytes) {
                      if (bytes != null) {
                        setDState(() {
                          capturaBytes = bytes;
                          capturaBase64 = base64Encode(bytes);
                        });
                      }
                    });
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: ContentDialog(
                  title: const Text("Reportar un Bug o Sugerencia"),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ComboBox<String>(
                        isExpanded: true,
                        value: modulo,
                        placeholder: const Text("¿Dónde ocurrió el error?"),
                        items:
                            [
                                  "BOM",
                                  "VINs",
                                  "Login",
                                  "Gestión Proyectos",
                                  "Importador Excel",
                                  "Otros",
                                ]
                                .map(
                                  (e) => ComboBoxItem(value: e, child: Text(e)),
                                )
                                .toList(),
                        onChanged:
                            (v) => setDState(() => modulo = v ?? "Otros"),
                      ),
                      const SizedBox(height: 12),
                      ComboBox<String>(
                        isExpanded: true,
                        value: gravedad,
                        placeholder: const Text("Nivel de gravedad"),
                        items: [
                          const ComboBoxItem(
                            value: "Crítico",
                            child: Text("Rojo: Crítico (Bloquea el uso)"),
                          ),
                          const ComboBoxItem(
                            value: "Visual",
                            child: Text("Amarillo: Visual o Menor"),
                          ),
                          const ComboBoxItem(
                            value: "Sugerencia",
                            child: Text("Azul: Sugerencia de mejora"),
                          ),
                        ],
                        onChanged:
                            (v) =>
                                setDState(() => gravedad = v ?? "Sugerencia"),
                      ),
                      const SizedBox(height: 12),
                      TextBox(
                        maxLines: 4,
                        placeholder:
                            "Describe qué pasó, pasos para reproducirlo...",
                        onChanged: (v) => descripcion = v,
                      ),
                      const SizedBox(height: 12),
                      const SizedBox(height: 12),
                      if (capturaBytes != null)
                        Container(
                          height: 220,
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey),
                          ),
                          child: Center(
                            child: Stack(
                              alignment: Alignment.topRight,
                              children: [
                                InteractiveViewer(
                                  panEnabled: true,
                                  minScale: 1.0,
                                  maxScale: 4.0,
                                  child: Center(
                                    child: Image.memory(
                                      capturaBytes!,
                                      fit: BoxFit.contain,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(
                                    FluentIcons.cancel,
                                    color: Color(0xFFE53935),
                                  ),
                                  onPressed:
                                      () => setDState(() {
                                        capturaBytes = null;
                                        capturaBase64 = null;
                                      }),
                                ),
                              ],
                            ),
                          ),
                        ),
                      Button(
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(FluentIcons.image_pixel),
                            SizedBox(width: 8),
                            Text("Adjuntar Captura"),
                          ],
                        ),
                        onPressed: () async {
                          final result = await FilePicker.platform.pickFiles(
                            type: FileType.image,
                          );
                          if (result != null &&
                              result.files.single.path != null) {
                            final bytes =
                                await result.files.single.xFile.readAsBytes();
                            setDState(() {
                              capturaBytes = bytes;
                              capturaBase64 = base64Encode(bytes);
                            });
                          }
                        },
                      ),
                      const SizedBox(height: 8),
                      Button(
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(FluentIcons.paste),
                            SizedBox(width: 8),
                            Text("Pegar del Portapapeles (Ctrl+V)"),
                          ],
                        ),
                        onPressed: () async {
                          final bytes = await Pasteboard.image;
                          if (bytes != null) {
                            setDState(() {
                              capturaBytes = bytes;
                              capturaBase64 = base64Encode(bytes);
                            });
                          }
                        },
                      ),
                      const SizedBox(height: 12),
                      if (enviando) const ProgressRing(),
                    ],
                  ),
                  actions: [
                    Button(
                      child: const Text("Cancelar"),
                      onPressed: () => Navigator.pop(context),
                    ),
                    FilledButton(
                      onPressed: () async {
                        if (descripcion.isEmpty) return;
                        setDState(() => enviando = true);
                        try {
                          final prefs = await SharedPreferences.getInstance();
                          final currentUser =
                              prefs.getString('username') ?? "Desconocido";

                          await ApiClient.post(
                            '/api/reportes/nuevo',
                            body: {
                              "usuario": currentUser,
                              "modulo": modulo,
                              "gravedad": gravedad,
                              "descripcion": descripcion,
                              "captura": capturaBase64,
                            },
                          );
                          Navigator.pop(context);
                          displayInfoBar(
                            context,
                            builder: (context, close) {
                              return InfoBar(
                                title: const Text('Éxito'),
                                content: const Text(
                                  'Reporte enviado. Gracias por ayudar a mejorar el sistema.',
                                ),
                                severity: InfoBarSeverity.success,
                                onClose: close,
                              );
                            },
                          );
                        } catch (e) {
                          setDState(() => enviando = false);
                        }
                      },
                      child: const Text("Enviar Reporte"),
                    ),
                  ],
                ),
              );
            },
          ),
    );
  }

  void _handleNavigation(int index, BuildContext navContext, {int? id}) async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (id != null) {
      targetRevisionId = id;
    }

    setState(() => topIndex = index);
    if (_userRole != 'QA' && index == kMainPaneImportarExcel) {
      ArbitrationBridge.notifyConsumePending();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingAuth) {
      return const FluentApp(home: Center(child: ProgressRing()));
    }

    return ListenableBuilder(
      listenable: appTheme,
      builder: (context, child) {
        return FluentApp(
          debugShowCheckedModeBanner: false,
          title: 'Industrial Master V135.0',
          theme: appTheme.currentTheme,
          initialRoute: '/',
          routes: {
            '/': (context) => const SplashScreen(),
            '/login': (context) => LoginScreen(onLoginSuccess: _onLoginSuccess),
            '/main': (context) => Builder(
                  builder: (navContext) {
                    MainNav.registerPaneNavigator(
                      (index) => _handleNavigation(index, navContext),
                    );
                    return NavigationView(
                    appBar: NavigationAppBar(
                      title: Builder(
                        builder: (appBarCtx) => Text(
                          'Industrial Master V135.0',
                          style: FluentTheme.of(appBarCtx).typography.caption,
                        ),
                      ),
                      automaticallyImplyLeading: false,
                      leading: Padding(
                        padding: const EdgeInsetsDirectional.only(start: 8.0),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Tooltip(
                              message:
                                  _navPaneDisplayMode == PaneDisplayMode.compact
                                      ? 'Expandir menú lateral'
                                      : 'Comprimir menú a íconos',
                              child: IconButton(
                                icon: Icon(
                                  _navPaneDisplayMode == PaneDisplayMode.compact
                                      ? FluentIcons.global_nav_button
                                      : FluentIcons.chrome_close,
                                ),
                                onPressed: () {
                                  setState(() {
                                    _navPaneDisplayMode =
                                        _navPaneDisplayMode ==
                                                PaneDisplayMode.compact
                                            ? PaneDisplayMode.open
                                            : PaneDisplayMode.compact;
                                  });
                                },
                              ),
                            ),
                            const Padding(
                              padding: EdgeInsetsDirectional.only(start: 4),
                              child: Icon(FluentIcons.factory),
                            ),
                          ],
                        ),
                      ),
                      actions: Padding(
                        padding: const EdgeInsets.only(right: 12.0),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const NetworkStatusIndicator(),
                            const SizedBox(width: 8),
                            IconButton(
                              icon: const Icon(FluentIcons.sign_out),
                              onPressed: () => _logout(navContext),
                            ),
                          ],
                        ),
                      ),
                    ),
                    pane: NavigationPane(
                      size: const NavigationPaneSize(openWidth: 220.0),
                      selected: topIndex,
                      onChanged: (index) => _handleNavigation(index, navContext),
                      onItemPressed: (index) =>
                          _handleNavigation(index, navContext),
                      displayMode: _navPaneDisplayMode,
                      // Un solo control de ancho: el IconButton del AppBar (sin segundo menú en rail compacto).
                      toggleable: false,
                      items: _userRole == 'QA'
                          ? [
                              PaneItem(
                                icon: const Icon(FluentIcons.database),
                                title: const Text('Catálogo Maestro'),
                                body: const CatalogScreen(),
                              ),
                            ]
                          : [
                              PaneItem(
                                icon: const Icon(FluentIcons.home),
                                title: const Text('Lobby Principal'),
                                body: ConstrainedAppBody(
                                  child: LobbyScreen(
                                    isAdmin: _userRole == 'ADMIN',
                                    onNavigate: (index) {
                                      _handleNavigation(index, navContext);
                                    },
                                  ),
                                ),
                              ),
                              PaneItemHeader(
                                header: const Text('Consultas rápidas'),
                              ),
                              PaneItem(
                                icon: const Icon(FluentIcons.database),
                                title: const Text('Catálogo Maestro'),
                                body: const CatalogScreen(),
                              ),
                              PaneItem(
                                icon: const Icon(FluentIcons.set_action),
                                title: const Text('Materiales Oficiales'),
                                body: const MaterialsListScreen(),
                              ),
                              PaneItem(
                                icon: const Icon(FluentIcons.map_layers),
                                title: const Text('Mapa de Ingeniería'),
                                body: EngineeringMapScreen(
                                  targetRevisionId: targetRevisionId,
                                ),
                              ),
                              PaneItem(
                                icon: const Icon(FluentIcons.build_issue),
                                title: const Text('Radar de Impacto'),
                                body: const ImpactRadarScreen(),
                              ),
                              PaneItemHeader(
                                header: const Text('Procesamiento de datos'),
                              ),
                              PaneItem(
                                icon: const Icon(FluentIcons.cube_shape),
                                title: const Text('Escáner CAD 3D/2D'),
                                body: const CADScannerScreen(),
                              ),
                              PaneItem(
                                icon: const Icon(FluentIcons.cloud),
                                title: const Text('Importar Excel'),
                                body: const ArbitrationScreen(),
                              ),
                              PaneItem(
                                icon: const Icon(FluentIcons.check_list),
                                title: const Text('Auditor de Archivos'),
                                body: const AuditorScreen(),
                              ),
                              PaneItem(
                                icon: const Icon(FluentIcons.filter),
                                title: const Text('Estandarización'),
                                body: ConstrainedAppBody(
                                  child: StandardizationScreen(),
                                ),
                              ),
                              PaneItemHeader(
                                header: const Text('Control de producción'),
                              ),
                              PaneItem(
                                icon: const Icon(FluentIcons.shopping_cart),
                                title: const Text('Requerimientos (MRP)'),
                                body: const MRPScreen(),
                              ),
                              PaneItem(
                                icon: const Icon(FluentIcons.fabric_folder),
                                title: const Text('Gestión de Proyectos'),
                                body: const ProjectManagementScreen(),
                              ),
                              PaneItem(
                                icon: const Icon(FluentIcons.car),
                                title: const Text('Expedientes VIN'),
                                body: VINDossierScreen(
                                  onNavigateToBOM: (id) {
                                    _handleNavigation(3, navContext, id: id);
                                  },
                                ),
                              ),
                              PaneItem(
                                icon: const Icon(FluentIcons.pie_single),
                                title: const Text('Dashboard Analytics'),
                                body: const ConstrainedAppBody(
                                  child: AnalyticsScreen(),
                                ),
                              ),
                              PaneItem(
                                icon: const Icon(FluentIcons.tablet),
                                title: const Text('Centro de QA'),
                                body: const ConstrainedAppBody(
                                  child: QADashboardScreen(),
                                ),
                              ),
                              PaneItem(
                                icon: const Icon(FluentIcons.history),
                                title: const Text('Historial de Cambios'),
                                body: const HistoryScreen(),
                              ),
                            ],
                      footerItems: [
                        PaneItemAction(
                          icon: const Icon(FluentIcons.color),
                          title: const Text('Tema visual'),
                          onTap: () => showAppThemePickerDialog(navContext),
                        ),
                        PaneItemAction(
                          icon: const Icon(FluentIcons.bug),
                          title: const Text("Reportar Bug"),
                          onTap: () => _showBugDialog(navContext),
                        ),
                        PaneItem(
                          icon: const Icon(FluentIcons.settings),
                          title: const Text('Configuración'),
                          body: const ConstrainedAppBody(
                            child: SettingsScreen(),
                          ),
                        ),
                      ],
                    ),
                  );
                  },
                ),
          },
        );
      },
    );
  }
}

class NetworkStatusIndicator extends StatefulWidget {
  const NetworkStatusIndicator({Key? key}) : super(key: key);

  @override
  State<NetworkStatusIndicator> createState() => _NetworkStatusIndicatorState();
}

class _NetworkStatusIndicatorState extends State<NetworkStatusIndicator> {
  Timer? _timer;
  bool _isConnected = true;

  @override
  void initState() {
    super.initState();
    _checkHealth();
    _timer = Timer.periodic(const Duration(seconds: 10), (timer) {
      _checkHealth();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _checkHealth() async {
    try {
      final response = await ApiClient.getUnvalidated(
        '/api/health',
        timeout: const Duration(seconds: 5),
      );
      if (response.statusCode == 200) {
        final data = response.decodeJson() as Map<String, dynamic>;
        if (mounted) {
          setState(() {
            _isConnected = data['status'] == 'ok' && data['db_connected'] == true;
          });
        }
      } else {
        if (mounted) setState(() => _isConnected = false);
      }
    } catch (e) {
      if (mounted) setState(() => _isConnected = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: _isConnected ? 'Servidor Principal Conectado' : 'Desconectado del Servidor Principal',
      child: Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _isConnected ? Colors.green : Colors.red,
        ),
      ),
    );
  }
}
