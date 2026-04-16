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
import 'config/app_branding.dart';
import 'config/app_config.dart';
import 'services/api_client.dart';
import 'services/arbitration_bridge.dart';
import 'services/app_role.dart';
import 'services/chat_windows_notification_service.dart';
import 'services/main_nav.dart';
import 'services/nav_pane.dart';
import 'services/navigation_usage_service.dart';
import 'main_layout.dart';
import 'screens/monitoreo/widgets/notification_inbox_panel.dart';
import 'screens/ayudas_visuales/ayudas_api_models.dart';
import 'screens/ayudas_visuales/ayudas_ultima_subida_query.dart';
import 'services/notification_inbox_service.dart';
import 'services/produccion_ayuda_novedad_prefs.dart';

const String API_URL = kApiBaseUrl;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('es_ES', null);
  await ChatWindowsNotificationService.instance.init();
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
  NavPaneId? _activeLeafPane;
  final List<AutoSuggestBoxItem<dynamic>> _searchItems = [];

  /// Barra ancha por defecto; el botón permite colapsar a modo íconos.
  PaneDisplayMode _navPaneDisplayMode = PaneDisplayMode.open;

  bool _isSectionHubPane(NavPaneId? pane) {
    return pane == NavPaneId.operacionHub ||
        pane == NavPaneId.ingenieriaHub ||
        pane == NavPaneId.seguimientoHub ||
        pane == NavPaneId.datosHub;
  }

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
          _activeLeafPane = null;
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
      _activeLeafPane = null;
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
      _activeLeafPane = null;
    });
    Navigator.pushReplacementNamed(context, '/login');
  }

  List<String> _modulosReportablesPorRol(AppRole role) {
    final mods = <String>[
      'General',
      if (role.showsNavLobby) 'Lobby principal',
      if (role.showsNavMonitoreo) 'Centro de monitoreo',
      if (role.showsNavMonitoreo) 'Centro de monitoreo > Misiones activas',
      if (role.showsNavMonitoreo) 'Centro de monitoreo > Historial',
      if (role.showsNavMonitoreo) 'Centro de monitoreo > Alta manual',
      if (role.showsNavAyudas) 'Ayudas visuales',
      if (role.showsNavChatInterno) 'Chat interno',
      if (role.showsNavRadar) 'Radar de impacto',
      if (role.showsNavCatalogo) 'Catálogo maestro',
      if (role.showsNavGeneradorCodigo) 'Generador de Código',
      if (role.showsNavMateriales) 'Materiales oficiales',
      if (role.showsNavCadScanner) 'Escáner CAD',
      if (role.showsNavImportarExcel) 'Importar Excel',
      if (role.showsNavAuditor) 'Auditor de archivos',
      if (role.showsNavEstandarizacion) 'Estandarización',
      if (role.showsNavGestionProyectos) 'Gestión de proyectos',
      if (role.showsNavVin) 'Expedientes VIN',
      if (role.showsNavMapaIngenieria) 'Mapa de ingeniería',
      if (role.showsNavHistorialCambios) 'Historial de cambios',
      if (role.showsNavQa) 'Centro de QA',
      if (role.showsNavQa) 'Centro de QA > Historial',
      if (role.showsNavQa) 'Centro de QA > Notas de versión',
      if (role.showsNavAnalytics) 'Estadísticas',
      if (role.showsNavMrp) 'Requerimientos (MRP)',
      if (role.showsNavMrp) 'Requerimientos (MRP) > Materia prima / Placas',
      if (role.showsNavMrp) 'Requerimientos (MRP) > Componentes comerciales',
      if (role.showsNavMrp) 'Requerimientos (MRP) > Auditoría / Huérfanos',
      if (role.showsNavCatalogo) 'Gestor de listas (BOM)',
      'Login',
      'Otros',
    ];
    return mods.toSet().toList()..sort();
  }

  String _normalizarHashtag(String raw) {
    var t = raw.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '_');
    t = t.replaceAll(RegExp(r'[^a-z0-9_#]'), '');
    if (t.isEmpty) return '';
    if (!t.startsWith('#')) t = '#$t';
    return t;
  }

  void _showBugDialog(BuildContext context) {
    final role = parseAppRole(_effectiveRole);
    final modulosDisponibles = _modulosReportablesPorRol(role);
    String modulo =
        modulosDisponibles.contains('General')
            ? 'General'
            : modulosDisponibles.first;
    String gravedad = "Mejora";
    String descripcion = "";
    bool enviando = false;
    Uint8List? capturaBytes;
    String? capturaBase64;
    final hashtagCtrl = TextEditingController();
    final hashtags = <String>{};
    const frecuentes = <String>[
      '#no_se_ve',
      '#no_conecta',
      '#se_traba',
      '#lento',
      '#dato_incorrecto',
      '#permiso',
    ];

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
                        items: modulosDisponibles
                            .map(
                              (e) => ComboBoxItem(value: e, child: Text(e)),
                            )
                            .toList(),
                        onChanged:
                            (v) => setDState(() => modulo = v ?? modulo),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: gravedad == 'Mejora'
                                ? FilledButton(
                                    style: ButtonStyle(
                                      backgroundColor: WidgetStateProperty.all(
                                        const Color(0xFF2979FF),
                                      ),
                                    ),
                                    onPressed: () {},
                                    child: const Text('Mejora'),
                                  )
                                : Button(
                                    onPressed: () => setDState(() => gravedad = 'Mejora'),
                                    child: const Text('Mejora'),
                                  ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: gravedad == 'Falla'
                                ? FilledButton(
                                    style: ButtonStyle(
                                      backgroundColor: WidgetStateProperty.all(
                                        const Color(0xFFF9A825),
                                      ),
                                    ),
                                    onPressed: () {},
                                    child: const Text('Falla'),
                                  )
                                : Button(
                                    onPressed: () => setDState(() => gravedad = 'Falla'),
                                    child: const Text('Falla'),
                                  ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: gravedad == 'Crítico'
                                ? FilledButton(
                                    style: ButtonStyle(
                                      backgroundColor: WidgetStateProperty.all(
                                        const Color(0xFFC62828),
                                      ),
                                    ),
                                    onPressed: () {},
                                    child: const Text('Crítico'),
                                  )
                                : Button(
                                    onPressed: () => setDState(() => gravedad = 'Crítico'),
                                    child: const Text('Crítico'),
                                  ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextBox(
                        maxLines: 4,
                        placeholder:
                            "Describe qué pasó, pasos para reproducirlo...",
                        onChanged: (v) => descripcion = v,
                      ),
                      const SizedBox(height: 12),
                      TextBox(
                        controller: hashtagCtrl,
                        placeholder: "Agregar hashtag (ej. #no_se_ve) y Enter",
                        onSubmitted: (v) {
                          final t = _normalizarHashtag(v);
                          if (t.isEmpty) return;
                          setDState(() {
                            hashtags.add(t);
                            hashtagCtrl.clear();
                          });
                        },
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final h in frecuentes)
                            Button(
                              onPressed: () => setDState(() => hashtags.add(h)),
                              child: Text(h),
                            ),
                        ],
                      ),
                      if (hashtags.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final h in hashtags)
                              GestureDetector(
                                onTap: () => setDState(() => hashtags.remove(h)),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF334155),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(h),
                                ),
                              ),
                          ],
                        ),
                      ],
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
                              "hashtags": hashtags.toList(),
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
      final ar = MainNav.currentRole;
      final directPane = paneId ?? navPaneAtIndex(index, ar);
      if (_isSectionHubPane(directPane)) {
        if (paneId != null && !_isSectionHubPane(paneId)) {
          _activeLeafPane = paneId;
        }
      } else {
        _activeLeafPane = directPane;
      }
    });
    final ar = MainNav.currentRole;
    final pane = navPaneAtIndex(index, ar);
    final paneForTelemetry = paneId ?? pane;
    if (paneForTelemetry != null) {
      unawaited(
        NavigationUsageService.instance.record(
          paneId: paneForTelemetry,
          roleRaw: _effectiveRole,
        ),
      );
    }
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
          title: kAppChromeTitle,
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
                    final navNarrowRailSelectedLabel =
                        _navPaneDisplayMode == PaneDisplayMode.compact;
                    final shellW = MediaQuery.sizeOf(navContext).width;
                    final compactShellChrome = shellW < 1100;
                    return SimulationModeShell(
                      active:
                          _simulatedRoleOverride != null &&
                          _simulatedRoleOverride!.isNotEmpty,
                      effectiveRoleLabel: _effectiveRole,
                      child: NavigationPaneTheme(
                        data: NavigationPaneThemeData(
                          backgroundColor: paneBg,
                          overlayBackgroundColor: paneBg,
                          iconPadding: navNarrowRailSelectedLabel
                              ? const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 2,
                                )
                              : null,
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
                            height: compactShellChrome ? 36 : 42,
                            backgroundColor: paneBg,
                            title: Builder(
                              builder: (appBarCtx) {
                                final cap =
                                    FluentTheme.of(appBarCtx).typography.caption;
                                return Text(
                                  kAppChromeTitle,
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
                                          navNarrowRailSelectedLabel
                                              ? 'Expandir menú (ancho completo con títulos)'
                                              : 'Menú estrecho: solo iconos (nombre en tooltip al pasar el ratón)',
                                      child: IconButton(
                                        icon: Icon(
                                          navNarrowRailSelectedLabel
                                              ? FluentIcons.global_nav_button
                                              : FluentIcons.chrome_close,
                                        ),
                                        onPressed: () {
                                          setState(() {
                                            _navPaneDisplayMode =
                                                navNarrowRailSelectedLabel
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
                                      _AppBarManualInfoButton(
                                        currentPane:
                                            _activeLeafPane ??
                                            navPaneAtIndex(
                                              topIndex,
                                              MainNav.currentRole,
                                            ),
                                        effectiveRoleRaw: _effectiveRole,
                                      ),
                                      if (parseAppRole(_effectiveRole)
                                          .showsNavChatInterno) ...[
                                        const SizedBox(width: 8),
                                        _AppBarChatButton(
                                          onOpenChat: () {
                                            final idx = navIndexForPane(
                                              NavPaneId.chatInterno,
                                              MainNav.currentRole,
                                            );
                                            if (idx >= 0) {
                                              _handleNavigation(
                                                idx,
                                                navContext,
                                                paneId: NavPaneId.chatInterno,
                                              );
                                            }
                                          },
                                        ),
                                      ],
                                      const SizedBox(width: 8),
                                      _AppBarNotificationInbox(
                                        effectiveRoleRaw: _effectiveRole,
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
                                        onNavigateAyudasVisuales: () {
                                          final idx = navIndexForPane(
                                            NavPaneId.ayudasVisuales,
                                            MainNav.currentRole,
                                          );
                                          if (idx >= 0) {
                                            _handleNavigation(
                                              idx,
                                              navContext,
                                              paneId: NavPaneId.ayudasVisuales,
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
                          displayMode: navNarrowRailSelectedLabel
                              ? PaneDisplayMode.open
                              : _navPaneDisplayMode,
                          narrowRailSelectedLabelOnly:
                              navNarrowRailSelectedLabel,
                          toggleable: false,
                          targetRevisionId: targetRevisionId,
                          requestedPaneId: _requestedPaneId,
                          onActiveLeafPaneChanged: (pane) {
                            if (_activeLeafPane == pane) return;
                            setState(() => _activeLeafPane = pane);
                          },
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

class _AppBarManualInfoButton extends StatelessWidget {
  const _AppBarManualInfoButton({
    required this.currentPane,
    required this.effectiveRoleRaw,
  });

  final NavPaneId? currentPane;
  final String effectiveRoleRaw;

  AppRole get _role => parseAppRole(effectiveRoleRaw);

  bool get _canEdit {
    return _role.isAdminRail || _role == AppRole.ingenieriaMetodos;
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Información y guía de uso',
      child: IconButton(
        icon: const Icon(FluentIcons.info),
        onPressed: () {
          showDialog(
            context: context,
            builder: (_) => _ManualInfoDialog(
              currentPane: currentPane,
              canEdit: _canEdit,
              role: _role,
            ),
          );
        },
      ),
    );
  }
}

class _ManualInfoDialog extends StatefulWidget {
  const _ManualInfoDialog({
    required this.currentPane,
    required this.canEdit,
    required this.role,
  });

  final NavPaneId? currentPane;
  final bool canEdit;
  final AppRole role;

  @override
  State<_ManualInfoDialog> createState() => _ManualInfoDialogState();
}

class _ManualInfoDialogState extends State<_ManualInfoDialog> {
  bool _loading = true;
  String _selected = 'general';
  String _activeGuideSection = 'pasos';
  final Map<String, Map<String, String>> _entries = {};

  static const Map<String, Map<String, String>> _fallback = {
    'general': {
      'titulo': 'Guía general',
      'contenido':
          'Usa el menú lateral para cambiar de módulo y el icono de información para consultar esta guía.\n'
              '• Campana: abre el buzón de tareas y permite saltar a monitoreo.\n'
              '• Indicador de red: confirma conexión backend.\n'
              '• Cerrar sesión: finaliza tu sesión actual.\n'
              'Antes de aplicar cambios en datos, valida permisos y contexto del rol activo.',
    },
    'catalogo_maestro': {
      'titulo': 'Catálogo maestro',
      'contenido':
          'Sincroniza stock PT cuando sea necesario, revisa huérfanos y valida filtros/ordenamiento '
              'antes de exportar a Excel.',
    },
    'chat_interno': {
      'titulo': 'Chat interno',
      'contenido':
          'Selecciona un usuario en la columna izquierda para abrir conversación.\n'
              '• Enter envía el mensaje.\n'
              '• Zumbido solicita atención inmediata (con límite anti-spam).\n'
              '• Los mensajes y zumbidos pueden mostrar notificación nativa de Windows.',
    },
    'centro_monitoreo': {
      'titulo': 'Centro de monitoreo',
      'contenido':
          'Gestiona tareas activas con prioridades, checklist y bitácora.\n'
              '• Alta manual: crea misiones con responsable, tiempo y evidencia.\n'
              '• Historial: reactivar o eliminar misiones cerradas con control administrativo.\n'
              '• Buzón: revisa asignaciones pendientes y marca notificaciones como leídas.\n'
              'Colores en la tarjeta (barra vertical izquierda):\n'
              '• Rojo: primer puesto del orden (crítico).\n'
              '• Naranja: segundo puesto (alta).\n'
              '• Azul: resto de puestos y prioridad normal por defecto.\n'
              'Estados visuales: contorno más intenso indica foco; tarjeta sombreada y etiqueta SUSPENDIDA si hubo pausa por prioridad urgente; etiqueta de usuario usa color identificador; la barra de progreso refleja el checklist.\n'
              'En cada tarjeta, el icono de información (i relleno) abre nombre, descripción y datos técnicos de la misión.',
    },
    'ayudas_visuales': {
      'titulo': 'Ayudas visuales',
      'contenido':
          'Consulta o publica instructivos PDF por categoría.\n'
              '• Buscador superior: filtra por título, VIN y etiquetas.\n'
              '• Nueva categoría: crea grupo para organizar documentos.\n'
              '• Editar imagen categoría: actualiza icono Fluent o PNG de la tarjeta.',
    },
    'centro_qa': {
      'titulo': 'Centro QA',
      'contenido':
          'Gestiona reportes abiertos, cierra con Completado/Rechazado y registra ajustes en notas de versión.',
    },
    'materiales_oficiales': {
      'titulo': 'Materiales oficiales',
      'contenido':
          'Consulta materiales autorizados y su estado vigente.\n'
              'Verifica especificación, proceso y trazabilidad antes de liberar cambios.',
    },
    'radar_impacto': {
      'titulo': 'Radar de impacto',
      'contenido':
          'Evalúa el impacto de cambios por tracto, proyecto y versión.\n'
              'Úsalo para priorizar misiones con mayor riesgo operativo.',
    },
    'notas_version': {
      'titulo': 'Notas de versión',
      'contenido':
          'Muestra historial de cambios entregados por build.\n'
              'Valida qué correcciones están incluidas antes de pruebas QA.',
    },
    'generador_codigo': {
      'titulo': 'Generador de Código',
      'contenido':
          'Permite dar de alta piezas nuevas de forma individual en catálogo maestro.\n'
              '• Captura manual de código (temporal).\n'
              '• Valida duplicados antes de guardar.\n'
              '• Incluye procesos, material oficial, dimensiones y simetría.',
    },
  };

  @override
  void initState() {
    super.initState();
    _selected = _moduleKey(widget.currentPane);
    _load();
  }

  String _moduleKey(NavPaneId? pane) {
    return switch (pane) {
      NavPaneId.catalogoMaestro => 'catalogo_maestro',
      NavPaneId.centroMonitoreo => 'centro_monitoreo',
      NavPaneId.ayudasVisuales => 'ayudas_visuales',
      NavPaneId.chatInterno => 'chat_interno',
      NavPaneId.materialesOficiales => 'materiales_oficiales',
      NavPaneId.radarImpacto => 'radar_impacto',
      NavPaneId.notasVersion => 'notas_version',
      NavPaneId.generadorCodigo => 'generador_codigo',
      NavPaneId.centroQa => 'centro_qa',
      _ => 'general',
    };
  }

  String _moduleLabel(String key) {
    return switch (key) {
      'general' => 'Guia general',
      'catalogo_maestro' => 'Catalogo maestro',
      'chat_interno' => 'Chat interno',
      'centro_monitoreo' => 'Centro de monitoreo',
      'ayudas_visuales' => 'Ayudas visuales',
      'centro_qa' => 'Centro QA',
      'materiales_oficiales' => 'Materiales oficiales',
      'radar_impacto' => 'Radar de impacto',
      'notas_version' => 'Notas de version',
      'generador_codigo' => 'Generador de codigo',
      _ => key.replaceAll('_', ' '),
    };
  }

  IconData _moduleIcon(String key) {
    return switch (key) {
      'general' => FluentIcons.info,
      'catalogo_maestro' => FluentIcons.table,
      'chat_interno' => FluentIcons.chat,
      'centro_monitoreo' => FluentIcons.task_logo,
      'ayudas_visuales' => FluentIcons.picture,
      'centro_qa' => FluentIcons.test_plan,
      'materiales_oficiales' => FluentIcons.product_release,
      'radar_impacto' => FluentIcons.analytics_view,
      'notas_version' => FluentIcons.history,
      'generador_codigo' => FluentIcons.cube_shape,
      _ => FluentIcons.page,
    };
  }

  List<String> _visibleModules(List<String> sortedKeys) {
    if (widget.role != AppRole.calidad && widget.role != AppRole.produccion) {
      return sortedKeys;
    }
    const allowedForQualityAndProduction = <String>{
      'general',
      'catalogo_maestro',
      'ayudas_visuales',
    };
    final filtered = sortedKeys.where(allowedForQualityAndProduction.contains).toList();
    if (!filtered.contains('general')) {
      filtered.insert(0, 'general');
    }
    return filtered;
  }

  List<String> _contentParagraphs(String text) {
    return text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  Widget _buildFormattedManual(String text) {
    final paragraphs = _contentParagraphs(text);
    if (paragraphs.isEmpty) {
      return const Text('Sin contenido para este modulo.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final p in paragraphs)
          if (p.startsWith('•') || p.startsWith('-'))
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Icon(FluentIcons.circle_ring, size: 10),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      p.replaceFirst(RegExp(r'^[•\-]\s*'), ''),
                      style: const TextStyle(fontSize: 14, height: 1.45),
                    ),
                  ),
                ],
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                p,
                style: const TextStyle(fontSize: 14, height: 1.5),
              ),
            ),
      ],
    );
  }

  List<String> _defaultStepsFor(String module) {
    return switch (module) {
      'catalogo_maestro' => const [
        'Define filtros por código, medida, material y proceso antes de empezar.',
        'Ajusta columnas visibles para priorizar Material y datos críticos.',
        'Ordena por Código o Material para ubicar rápidamente la pieza objetivo.',
        'Revisa consistencia visual entre descripción, medida y proceso primario.',
        'Si aplica, valida stock PT y ejecuta sincronización desde el flujo autorizado.',
        'Solo exporta cuando la vista final coincida con la consulta requerida.',
      ],
      'chat_interno' => const [
        'Abre una conversación individual o el chat grupal.',
        'Escribe el mensaje y presiona Enter o Enviar.',
        'Usa Zumbido solo cuando necesites atención inmediata.',
        'Confirma respuesta en panel y notificación de Windows.',
      ],
      'centro_monitoreo' => const [
        'Crea misión manual con responsables, prioridad y tiempo estimado.',
        'Define checklist base y agrega evidencia inicial cuando corresponda.',
        'Da seguimiento en tarjetas activas y actualiza estatus por avance real.',
        'Valida notificaciones/buzón para tareas asignadas al usuario actual.',
        'Reactiva o cierra misión respetando trazabilidad en historial.',
      ],
      'ayudas_visuales' => const [
        'Selecciona una categoría existente o crea una categoría nueva.',
        'Carga el documento con nombre claro, versión y contexto de uso.',
        'Configura icono de categoría (Fluent o PNG) según estándar visual.',
        'Valida permisos del rol antes de editar, reemplazar o publicar.',
        'Confirma apertura correcta del archivo en visor y su metadato.',
      ],
      'centro_qa' => const [
        'Filtra reportes abiertos por módulo/prioridad.',
        'Reproduce y documenta evidencia del hallazgo.',
        'Cierra con Completado o Rechazado.',
        'Registra nota breve en notas de versión.',
      ],
      'materiales_oficiales' => const [
        'Busca material por código o descripción.',
        'Valida especificación y estado vigente.',
        'Confirma proceso asociado y trazabilidad.',
      ],
      'radar_impacto' => const [
        'Selecciona proyecto o tracto a evaluar.',
        'Revisa impacto por ensamble y prioridad.',
        'Genera acciones/misiones para alto riesgo.',
      ],
      'notas_version' => const [
        'Revisa build y fecha de despliegue.',
        'Confirma que el fix esperado esté listado.',
        'Comunica a QA qué validar en pruebas.',
      ],
      'generador_codigo' => const [
        'Captura el código manualmente y valida que no exista.',
        'Define procesos y material oficial antes de guardar.',
        'Completa medidas y simetría si están disponibles.',
        'Confirma la vista previa de cómo quedará en catálogo.',
      ],
      _ => const [
        'Entra al módulo desde menú lateral según tu rol.',
        'Revisa estado de red/notificaciones antes de operar.',
        'Aplica cambios solo con contexto y permisos correctos.',
        'Confirma resultado en pantalla antes de cerrar sesión.',
      ],
    };
  }

  List<String> _defaultButtonsFor(String module) {
    return switch (module) {
      'catalogo_maestro' => const [
        'Filtros: acota registros por código, texto y campos clave.',
        'Columnas: muestra u oculta campos según objetivo de revisión.',
        'Orden: cambia prioridad para análisis rápido de resultados.',
        'Exportar: genera archivo con la vista activa validada.',
      ],
      'chat_interno' => const [
        'Enviar: publica mensaje en conversación activa.',
        'Zumbido: alerta inmediata con anti-spam.',
        'Chat grupal: sala común para avisos rápidos.',
      ],
      'centro_monitoreo' => const [
        'Nueva misión: alta manual de tarea.',
        'Editar: ajusta responsable, tiempo o evidencia.',
        'Buzón: abre asignaciones y marca leídas.',
      ],
      'ayudas_visuales' => const [
        'Nueva categoría: crea agrupador visual.',
        'Subir documento: adjunta instructivo.',
        'Editar icono: cambia Fluent icon o PNG.',
        'Buscar: localiza por título, categoría o contenido relacionado.',
      ],
      'centro_qa' => const [
        'Completar: cierra bug corregido.',
        'Rechazar: descarta no reproducible/no aplica.',
        'Limpiar historial: elimina cerrados con clave maestra.',
      ],
      'generador_codigo' => const [
        'Registrar código: alta de pieza al catálogo maestro.',
        'Limpiar: reinicia captura para una nueva pieza.',
      ],
      _ => const [
        'Recargar: actualiza datos de la pantalla.',
        'Editar: modifica contenido permitido por tu rol.',
      ],
    };
  }

  List<String> _defaultErrorsFor(String module) {
    return switch (module) {
      'catalogo_maestro' => const [
        'No mezcles columnas ocultas con filtros que dependan de ellas.',
        'Si falta información, limpia filtros y vuelve a consultar.',
        'Si stock no coincide, ejecuta sincronización autorizada y recarga.',
      ],
      'chat_interno' => const [
        'Si no carga usuarios, valida backend y sesión activa.',
        'Si no llega zumbido, revisa anti-spam y conexión WS.',
      ],
      'centro_monitoreo' => const [
        'No cerrar misión sin checklist mínimo completo.',
        'Si notificación no aparece, revisa permisos de Windows.',
      ],
      'ayudas_visuales' => const [
        'Carga solo PNG/JPG/PDF válidos y tamaño moderado.',
        'Si falla subida, valida extensión, peso y conexión backend.',
        'Si persiste, confirma estructura de tablas/campos en backend.',
      ],
      'centro_qa' => const [
        'No dejar fixes en estado Abierto tras resolver.',
        'Al cerrar reportes, agrega nota corta de versión.',
      ],
      'generador_codigo' => const [
        'Si falla guardado, revisa que el código no exista ya.',
        'Valida al menos un proceso y material oficial seleccionado.',
      ],
      _ => const [
        'Si hay error de red, recarga módulo y revisa backend.',
        'Antes de escalar, captura evidencia y pasos de reproducción.',
      ],
    };
  }

  List<String> _defaultAcronymsFor(String module) {
    const common = <String>[
      'ECR: Engineering Change Request (solicitud formal para iniciar un cambio de ingeniería).',
      'BOM: Bill of Materials (lista/estructura de componentes de una pieza o ensamble).',
      'MRP: Material Requirements Planning (planeación de requerimientos de material).',
      'VIN: Vehicle Identification Number (identificador único del vehículo/unidad).',
      'QA: Quality Assurance (aseguramiento de calidad y gestión de reportes).',
      'PT: Producto Terminado (inventario de piezas/prod. terminados).',
      'CAD: Computer-Aided Design (diseño asistido por computadora; planos/modelos).',
      'DXF: Drawing Exchange Format (formato de intercambio de dibujos CAD).',
      'PDF: Portable Document Format (formato de documento para instructivos/evidencia).',
      'WS: WebSocket (canal en tiempo real para chat/eventos).',
      'API: Application Programming Interface (servicios backend consumidos por la app).',
      'KPI: Key Performance Indicator (indicador clave de desempeño).',
    ];
    return switch (module) {
      'catalogo_maestro' => const [
        'ECR: inicio formal de cambio para crear/editar ramas de ingeniería por versión o cliente.',
        'BOM: lista técnica de materiales/componentes por revisión.',
        'CAD: datos de diseño (largo, ancho, espesor, etc.).',
        'DXF: archivo de trazo/plano para procesos de corte.',
        'PT: stock de producto terminado sincronizado desde inventario.',
        'SKU: código único de referencia del artículo en inventarios/listados.',
      ],
      'chat_interno' => const [
        'WS: WebSocket para entrega de mensajes en tiempo real.',
        'API: endpoints REST para usuarios, conversaciones y mensajes.',
      ],
      'centro_monitoreo' => const [
        'KPI: métricas de carga/avance operativo mostradas en panel.',
        'ADN (VIN): historial de eventos técnicos y operativos del expediente.',
      ],
      'ayudas_visuales' => const [
        'PDF: formato principal para instructivos y ayudas publicadas.',
        'PNG/JPG: formatos de imagen para iconos y material visual.',
      ],
      _ => common,
    };
  }

  Widget _buildGuideList(List<String> items) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Icon(FluentIcons.checkbox_composite, size: 13),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item,
                    style: const TextStyle(fontSize: 14, height: 1.45),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildGuideSectionContent(Map<String, String> entry) {
    if (_activeGuideSection == 'que_hace') {
      return _buildFormattedManual(entry['contenido'] ?? '');
    }
    if (_activeGuideSection == 'botones') {
      return _buildGuideList(_defaultButtonsFor(_selected));
    }
    if (_activeGuideSection == 'errores') {
      return _buildGuideList(_defaultErrorsFor(_selected));
    }
    if (_activeGuideSection == 'siglas') {
      return _buildGuideList(_defaultAcronymsFor(_selected));
    }
    return _buildGuideList(_defaultStepsFor(_selected));
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final raw = await ApiClient.get('/api/config/manual');
      final parsed = <String, Map<String, String>>{};
      if (raw is List) {
        for (final item in raw) {
          if (item is! Map) continue;
          final m = Map<String, dynamic>.from(item.map((k, v) => MapEntry('$k', v)));
          final key = (m['modulo'] ?? '').toString().trim().toLowerCase();
          if (key.isEmpty) continue;
          parsed[key] = {
            'titulo': (m['titulo'] ?? '').toString(),
            'contenido': (m['contenido'] ?? '').toString(),
          };
        }
      }
      _entries
        ..clear()
        ..addAll(_fallback)
        ..addAll(parsed);
    } catch (_) {
      _entries
        ..clear()
        ..addAll(_fallback);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _editCurrent() async {
    final current = _entries[_selected] ?? _fallback['general']!;
    final titleCtrl = TextEditingController(text: current['titulo'] ?? '');
    final bodyCtrl = TextEditingController(text: current['contenido'] ?? '');
    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => ContentDialog(
          title: const Text('Editar contenido del manual'),
          content: SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextBox(controller: titleCtrl, placeholder: 'Título'),
                const SizedBox(height: 8),
                TextBox(controller: bodyCtrl, placeholder: 'Contenido', maxLines: 10),
              ],
            ),
          ),
          actions: [
            Button(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Guardar')),
          ],
        ),
      );
      if (ok != true) return;
      await ApiClient.put(
        '/api/config/manual/$_selected',
        body: {
          'titulo': titleCtrl.text.trim(),
          'contenido': bodyCtrl.text.trim(),
        },
      );
      if (!mounted) return;
      await _load();
    } finally {
      titleCtrl.dispose();
      bodyCtrl.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final allKeys = _entries.keys.toList()..sort();
    final keys = _visibleModules(allKeys);
    if (!keys.contains(_selected)) _selected = keys.isEmpty ? 'general' : keys.first;
    final entry = _entries[_selected] ?? _fallback['general']!;
    final size = MediaQuery.sizeOf(context);
    final dialogWidth = (size.width - 10) > 620 ? (size.width - 10) : 620.0;
    final dialogHeight = (size.height - 10) > 420 ? (size.height - 10) : 420.0;
    final leftPaneWidth = dialogWidth * 0.26;
    return ContentDialog(
      constraints: BoxConstraints(
        maxWidth: dialogWidth + 36,
        minWidth: dialogWidth + 36,
        maxHeight: dialogHeight + 90,
      ),
      title: Row(
        children: [
          const Icon(FluentIcons.info, size: 18),
          const SizedBox(width: 8),
          Text(
            'Guia de uso por modulo',
            style: FluentTheme.of(context).typography.subtitle,
          ),
        ],
      ),
      content: SizedBox(
        width: dialogWidth,
        height: dialogHeight - 120,
        child: _loading
            ? const Center(child: ProgressRing())
            : Row(
                children: [
                  Container(
                    width: leftPaneWidth,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: FluentTheme.of(context).resources.cardBackgroundFillColorDefault,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: FluentTheme.of(context).resources.controlStrokeColorDefault,
                      ),
                    ),
                    child: ListView(
                      children: [
                        Text(
                          'Modulos',
                          style: FluentTheme.of(context).typography.bodyStrong,
                        ),
                        const SizedBox(height: 8),
                        for (final k in keys)
                          ListTile.selectable(
                            selected: k == _selected,
                            leading: Icon(_moduleIcon(k), size: 16),
                            title: Text(
                              _moduleLabel(k),
                              style: const TextStyle(fontSize: 13),
                            ),
                            onPressed: () {
                              setState(() {
                                _selected = k;
                                _activeGuideSection = 'pasos';
                              });
                            },
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
                      decoration: BoxDecoration(
                        color: FluentTheme.of(context).resources.cardBackgroundFillColorDefault,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: FluentTheme.of(context).resources.controlStrokeColorDefault,
                        ),
                      ),
                      child: ListView(
                        children: [
                          Text(
                            entry['titulo'] ?? '',
                            style: FluentTheme.of(context).typography.title,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Referencia operativa del modulo seleccionado.',
                            style: FluentTheme.of(context).typography.caption,
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              _guideSectionBtn('Que hace', 'que_hace'),
                              _guideSectionBtn('Pasos', 'pasos'),
                              _guideSectionBtn('Botones', 'botones'),
                              _guideSectionBtn('Errores comunes', 'errores'),
                              _guideSectionBtn('Siglas', 'siglas'),
                            ],
                          ),
                          const SizedBox(height: 14),
                          const Divider(size: 1),
                          const SizedBox(height: 14),
                          _buildGuideSectionContent(entry),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        if (widget.canEdit) Button(onPressed: _editCurrent, child: const Text('Editar')),
        Button(onPressed: _load, child: const Text('Recargar')),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Cerrar')),
      ],
    );
  }

  Widget _guideSectionBtn(String label, String id) {
    final selected = _activeGuideSection == id;
    if (selected) {
      return FilledButton(
        onPressed: () => setState(() => _activeGuideSection = id),
        child: Text(label),
      );
    }
    return Button(
      onPressed: () => setState(() => _activeGuideSection = id),
      child: Text(label),
    );
  }
}

class _AppBarChatButton extends StatelessWidget {
  const _AppBarChatButton({required this.onOpenChat});

  final VoidCallback onOpenChat;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Chat interno',
      child: IconButton(
        icon: const Icon(FluentIcons.chat),
        onPressed: onOpenChat,
      ),
    );
  }
}

/// Campana de buzón: misiones (roles generales) o solo novedades de ayudas visuales (Producción).
class _AppBarNotificationInbox extends StatefulWidget {
  const _AppBarNotificationInbox({
    required this.effectiveRoleRaw,
    required this.onOpenMonitoring,
    required this.onNavigateAyudasVisuales,
  });

  final String effectiveRoleRaw;
  final VoidCallback onOpenMonitoring;
  final VoidCallback onNavigateAyudasVisuales;

  @override
  State<_AppBarNotificationInbox> createState() =>
      _AppBarNotificationInboxState();
}

class _AppBarNotificationInboxState extends State<_AppBarNotificationInbox> {
  int _unread = 0;
  Timer? _timer;
  bool _primedUnreadBaseline = false;
  DateTime? _lastAyudaPollForProd;
  bool _hasCompletedProdAyudaBadgeOnce = false;

  void _onProdAckChangeSignal() {
    if (!mounted) return;
    if (parseAppRole(widget.effectiveRoleRaw) != AppRole.produccion) return;
    _lastAyudaPollForProd = null;
    unawaited(_refresh());
  }

  @override
  void initState() {
    super.initState();
    ProduccionAyudaNovedadPrefs.ackChangeSignal.addListener(
      _onProdAckChangeSignal,
    );
    unawaited(_refresh());
    _timer = Timer.periodic(kCmdInboxPollInterval, (_) {
      unawaited(_refresh());
    });
  }

  @override
  void dispose() {
    ProduccionAyudaNovedadPrefs.ackChangeSignal.removeListener(
      _onProdAckChangeSignal,
    );
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _AppBarNotificationInbox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.effectiveRoleRaw != widget.effectiveRoleRaw) {
      _lastAyudaPollForProd = null;
      _hasCompletedProdAyudaBadgeOnce = false;
      unawaited(_refresh());
    }
  }

  Future<void> _refresh() async {
    try {
      final role = parseAppRole(widget.effectiveRoleRaw);
      if (role == AppRole.produccion) {
        final now = DateTime.now();
        if (_hasCompletedProdAyudaBadgeOnce &&
            _lastAyudaPollForProd != null &&
            now.difference(_lastAyudaPollForProd!) <
                const Duration(seconds: 45)) {
          return;
        }
        _lastAyudaPollForProd = now;

        final latest = await AyudasUltimaSubidaQuery.fetchLatest();
        final sig = AyudasUltimaSubidaQuery.signatureFor(latest);
        await ProduccionAyudaNovedadPrefs.ensureBaselined(sig);
        final ack = await ProduccionAyudaNovedadPrefs.readAckSignature();
        final n =
            (sig != null && sig.isNotEmpty && sig != (ack ?? '')) ? 1 : 0;
        final prev = _unread;
        if (_primedUnreadBaseline && n > prev && latest != null) {
          await ChatWindowsNotificationService.instance.showMessage(
            title: 'Nueva ayuda visual',
            body: ayudasTituloDocumento(latest),
          );
        }
        _hasCompletedProdAyudaBadgeOnce = true;
        _primedUnreadBaseline = true;
        if (mounted) setState(() => _unread = n);
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      final inboxUser = (prefs.getString('username') ?? '').trim();
      if (inboxUser.isNotEmpty) {
        try {
          final data = await ApiClient.get('/api/tareas/lista');
          if (data is List) {
            final taskRows =
                data.whereType<Map<String, dynamic>>().toList();
            await CmdInboxStore.instance.pruneMissionInboxAgainstTaskList(
              taskRows,
              inboxUser,
            );
          }
        } catch (_) {}
      }
      final all = await CmdInboxStore.instance.loadAll();
      final n = all.where((e) => !e.leido).length;
      if (_primedUnreadBaseline && n > _unread) {
        CmdInboxEntry? newestUnread;
        for (final item in all) {
          if (!item.leido) {
            newestUnread = item;
            break;
          }
        }
        if (newestUnread != null) {
          await ChatWindowsNotificationService.instance.showMessage(
            title: newestUnread.title,
            body: newestUnread.body,
          );
        }
      }
      _primedUnreadBaseline = true;
      if (mounted) setState(() => _unread = n);
    } catch (_) {
      if (mounted) setState(() => _unread = 0);
    }
  }

  Future<void> _openProduccionAyudaBuzon() async {
    final latest = await AyudasUltimaSubidaQuery.fetchLatest();
    final sig = AyudasUltimaSubidaQuery.signatureFor(latest);
    final ack = await ProduccionAyudaNovedadPrefs.readAckSignature();
    final hayNueva = sig != null && sig.isNotEmpty && sig != (ack ?? '');
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return ContentDialog(
          title: Text(
            hayNueva ? 'Nueva ayuda visual' : 'Notificaciones',
          ),
          content: SingleChildScrollView(
            child: Text(
              latest == null
                  ? 'No hay ayudas visuales publicadas todavía.'
                  : hayNueva
                      ? 'Hay un documento nuevo: ${ayudasTituloDocumento(latest)}'
                      : 'No hay ayudas nuevas desde la última vez que marcaste como vista.',
            ),
          ),
          actions: [
            Button(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cerrar'),
            ),
            if (latest != null && sig != null && sig.isNotEmpty)
              Button(
                onPressed: () async {
                  await ProduccionAyudaNovedadPrefs.writeAckSignature(sig);
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                child: const Text('Marcar como vista'),
              ),
            if (latest != null)
              FilledButton(
                onPressed: () {
                  final idAyuda = ayudasIdAyuda(latest);
                  final idRev = ayudasIdRevision(latest);
                  if (idAyuda > 0 && idRev > 0) {
                    MainNav.requestOpenAyudaLobby(
                      AyudasLobbyOpenIntent(
                        idAyuda: idAyuda,
                        idRevision: idRev,
                        tituloDocumento: ayudasTituloDocumento(latest),
                      ),
                    );
                  }
                  Navigator.pop(ctx);
                  widget.onNavigateAyudasVisuales();
                  if (sig != null && sig.isNotEmpty) {
                    unawaited(
                      ProduccionAyudaNovedadPrefs.writeAckSignature(sig),
                    );
                  }
                },
                child: const Text('Ver documento'),
              ),
          ],
        );
      },
    );
  }

  Future<void> _open() async {
    if (parseAppRole(widget.effectiveRoleRaw) == AppRole.produccion) {
      await _openProduccionAyudaBuzon();
      if (mounted) await _refresh();
      return;
    }
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
