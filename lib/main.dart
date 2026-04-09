import 'package:fluent_ui/fluent_ui.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';

import 'screens/bom_manager.dart';
import 'screens/login.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:flutter/services.dart';
import 'theme/app_themes.dart';
import 'theme/ui_tokens.dart';
import 'screens/splash_screen.dart';
import 'config/app_config.dart';
import 'services/api_client.dart';
import 'services/arbitration_bridge.dart';
import 'services/main_nav.dart';
import 'services/nav_pane.dart';
import 'main_layout.dart';
import 'screens/monitoreo/widgets/notification_inbox_panel.dart';
import 'services/notification_inbox_service.dart';

const String API_URL = kApiBaseUrl;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('es_ES', null);
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

  /// Solo admin: simula Calidad / Produccion / Ingenieria (UI). No cambia JWT.
  String? _simulatedRoleOverride;
  int topIndex = 0;

  String get _effectiveRole =>
      (_simulatedRoleOverride != null && _simulatedRoleOverride!.isNotEmpty)
          ? _simulatedRoleOverride!
          : _userRole;
  int? targetRevisionId;
  NavPaneId? _requestedPaneId;
  final List<AutoSuggestBoxItem<dynamic>> _searchItems = [];

  /// Barra ancha por defecto; el botón permite colapsar a modo íconos.
  PaneDisplayMode _navPaneDisplayMode = PaneDisplayMode.open;

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
        MainNav.registerRole(storedRole);
        MainNav.setSimulatedRole(null);
        setState(() {
          _isLoggedIn = true;
          _userRole = storedRole;
          _simulatedRoleOverride = null;
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
    final r = prefs.getString('rol') ?? 'USER';
    MainNav.registerRole(r);
    MainNav.setSimulatedRole(null);
    setState(() {
      _isLoggedIn = true;
      _userRole = r;
      _simulatedRoleOverride = null;
      topIndex = 0;
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
    MainNav.setSimulatedRole(null);
    setState(() {
      _isLoggedIn = false;
      _simulatedRoleOverride = null;
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

  void _handleNavigation(
    int index,
    BuildContext navContext, {
    int? id,
    NavPaneId? paneId,
  }) async {
    FocusManager.instance.primaryFocus?.unfocus();
    // Solo persistir revisión objetivo cuando el flujo la envía (p. ej. VIN → BOM).
    // Si el usuario elige una pestaña manualmente, limpiar para no reabrir el gestor al volver al mapa.
    if (id != null) {
      targetRevisionId = id;
    } else {
      targetRevisionId = null;
    }

    setState(() {
      topIndex = index;
      _requestedPaneId = paneId;
    });
    final ar = MainNav.currentRole;
    final pane = navPaneAtIndex(index, ar);
    if (pane == NavPaneId.importarExcel || paneId == NavPaneId.importarExcel) {
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
        final paneBg = shellNavChromeBackground(appTheme.currentTheme);
        final paneIsDark = paneBg.computeLuminance() < 0.45;
        final navChromeFg =
            paneIsDark ? const Color(0xFFF1F5F9) : const Color(0xFF15202B);
        final navChromeMuted =
            paneIsDark ? const Color(0xFFCBD5E1) : const Color(0xFF475569);
        return FluentApp(
          debugShowCheckedModeBanner: false,
          title: 'INGENIERIA IMv235',
          theme: appTheme.currentTheme,
          initialRoute: '/',
          routes: {
            '/': (context) => const SplashScreen(),
            '/login': (context) => LoginScreen(onLoginSuccess: _onLoginSuccess),
            '/main':
                (context) => Builder(
                  builder: (navContext) {
                    MainNav.registerPaneNavigator(
                      (index) => _handleNavigation(index, navContext),
                    );
                    MainNav.registerRole(_userRole);
                    MainNav.setSimulatedRole(_simulatedRoleOverride);
                    return SimulationModeShell(
                      active:
                          _simulatedRoleOverride != null &&
                          _simulatedRoleOverride!.isNotEmpty,
                      effectiveRoleLabel: _effectiveRole,
                      child: NavigationPaneTheme(
                        data: NavigationPaneThemeData(
                          backgroundColor: paneBg,
                          overlayBackgroundColor: paneBg,
                          tileColor: WidgetStateProperty.resolveWith((states) {
                            if (states.isPressed) {
                              return navChromeFg.withValues(alpha: 0.14);
                            }
                            if (states.isHovered) {
                              return navChromeFg.withValues(alpha: 0.09);
                            }
                            return const Color(0x00000000);
                          }),
                          itemHeaderTextStyle:
                              appTheme.currentTheme.typography.bodyStrong
                                  ?.copyWith(color: navChromeMuted),
                          unselectedIconColor:
                              WidgetStateProperty.all(navChromeFg),
                          selectedIconColor:
                              WidgetStateProperty.resolveWith((states) {
                            if (states.isPressed) return navChromeMuted;
                            return navChromeFg;
                          }),
                          unselectedTextStyle:
                              WidgetStateProperty.resolveWith((states) {
                            final b = appTheme.currentTheme.typography.body ??
                                const TextStyle();
                            return b.copyWith(
                              color: states.isDisabled
                                  ? navChromeMuted
                                  : navChromeFg,
                            );
                          }),
                          selectedTextStyle:
                              WidgetStateProperty.resolveWith((states) {
                            final b = appTheme.currentTheme.typography.body ??
                                const TextStyle();
                            return b.copyWith(
                              fontWeight: FontWeight.w600,
                              color: states.isPressed
                                  ? navChromeMuted
                                  : navChromeFg,
                            );
                          }),
                        ),
                        child: NavigationView(
                          appBar: NavigationAppBar(
                            height: 42,
                            backgroundColor: paneBg,
                            title: Builder(
                              builder: (appBarCtx) {
                                final cap =
                                    FluentTheme.of(appBarCtx).typography.caption;
                                return Text(
                                  'INGENIERIA IMv235',
                                  style: cap?.copyWith(color: navChromeFg) ??
                                      TextStyle(color: navChromeFg),
                                );
                              },
                            ),
                            automaticallyImplyLeading: false,
                            leading: IconTheme(
                              data: IconThemeData(
                                color: navChromeFg,
                                size: 18,
                              ),
                              child: Padding(
                                padding: const EdgeInsetsDirectional.only(
                                  start: 6.0,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Tooltip(
                                      message:
                                          _navPaneDisplayMode ==
                                                  PaneDisplayMode.compact
                                              ? 'Expandir menú lateral'
                                              : 'Comprimir menú a íconos',
                                      child: IconButton(
                                        icon: Icon(
                                          _navPaneDisplayMode ==
                                                  PaneDisplayMode.compact
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
                                      padding:
                                          EdgeInsetsDirectional.only(start: 4),
                                      child: Icon(FluentIcons.factory, size: 16),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            actions: IconTheme(
                              data: IconThemeData(
                                color: navChromeFg,
                                size: 18,
                              ),
                              child: DefaultTextStyle.merge(
                                style: TextStyle(color: navChromeFg),
                                child: Padding(
                                  padding: const EdgeInsets.only(right: 12.0),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      RoleSimulationAppBarControls(
                                        realRoleRaw: _userRole,
                                        simulatedRole: _simulatedRoleOverride,
                                        onChanged: (v) {
                                          setState(() {
                                            _simulatedRoleOverride = v;
                                            MainNav.setSimulatedRole(v);
                                            topIndex = 0;
                                          });
                                        },
                                      ),
                                      const SizedBox(width: 12),
                                      _AppBarNotificationInbox(
                                        onOpenMonitoring: () {
                                          final idx = navIndexForPane(
                                            NavPaneId.centroMonitoreo,
                                            MainNav.currentRole,
                                          );
                                          if (idx >= 0) {
                                            _handleNavigation(
                                              idx,
                                              navContext,
                                              paneId: NavPaneId.centroMonitoreo,
                                            );
                                          }
                                        },
                                      ),
                                      const SizedBox(width: 8),
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
                            ),
                          ),
                          pane: buildIndustrialNavigationPane(
                          selected: topIndex,
                          onPaneChanged:
                              (index) => _handleNavigation(
                                index,
                                navContext,
                                paneId: null,
                              ),
                          onItemPressed:
                              (index) => _handleNavigation(
                                index,
                                navContext,
                                paneId: null,
                              ),
                          displayMode: _navPaneDisplayMode,
                          toggleable: false,
                          targetRevisionId: targetRevisionId,
                          requestedPaneId: _requestedPaneId,
                          onNavigatePane: (id, {revisionId}) {
                            final idx = navIndexForPane(
                              id,
                              MainNav.currentRole,
                            );
                            if (idx >= 0) {
                              _handleNavigation(
                                idx,
                                navContext,
                                id: revisionId,
                                paneId: id,
                              );
                            }
                          },
                          userRole: _effectiveRole,
                          onThemeTap:
                              () => showAppThemePickerDialog(navContext),
                          onBugTap: () => _showBugDialog(navContext),
                        ),
                        ),
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

/// Campana de buzón (misiones asignadas) visible en toda la app desde la barra superior.
class _AppBarNotificationInbox extends StatefulWidget {
  const _AppBarNotificationInbox({required this.onOpenMonitoring});

  final VoidCallback onOpenMonitoring;

  @override
  State<_AppBarNotificationInbox> createState() =>
      _AppBarNotificationInboxState();
}

class _AppBarNotificationInboxState extends State<_AppBarNotificationInbox> {
  int _unread = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(_refresh());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final n = await CmdInboxStore.instance.unreadCount();
      if (mounted) setState(() => _unread = n);
    } catch (_) {
      if (mounted) setState(() => _unread = 0);
    }
  }

  Future<void> _open() async {
    await showNotificationInboxDialog(
      context,
      onChanged: () => unawaited(_refresh()),
      onOpenMonitoring: widget.onOpenMonitoring,
    );
    if (mounted) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return NotificationInboxButton(unreadCount: _unread, onOpen: _open);
  }
}

class NetworkStatusIndicator extends StatefulWidget {
  const NetworkStatusIndicator({super.key});

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
            _isConnected =
                data['status'] == 'ok' && data['db_connected'] == true;
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
      message:
          _isConnected
              ? 'Servidor Principal Conectado'
              : 'Desconectado del Servidor Principal',
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
