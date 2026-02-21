import 'package:fluent_ui/fluent_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/catalog.dart';

import 'screens/auditor.dart'; // Fase 12
import 'screens/arbitration.dart';
import 'screens/editor.dart';
import 'screens/settings.dart';
import 'screens/login.dart';
import 'screens/history.dart';
import 'screens/standardization.dart'; // Fase 18
import 'screens/materials_list.dart'; // Fase 20

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final isDarkMode = prefs.getBool('isDarkMode') ?? false;

  runApp(MyApp(isDarkMode: isDarkMode));
}

class MyApp extends StatefulWidget {
  final bool isDarkMode;
  const MyApp({super.key, required this.isDarkMode});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late ThemeMode _themeMode;
  bool _isLoggedIn = false;
  bool _isLoadingAuth = true;
  int topIndex = 0;

  @override
  void initState() {
    super.initState();
    _themeMode = widget.isDarkMode ? ThemeMode.dark : ThemeMode.light;
    _checkLoginStatus();
  }

  Future<void> _checkLoginStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final isLoggedIn = prefs.getBool('isLoggedIn') ?? false;
    final loginDateStr = prefs.getString('loginDate');

    if (isLoggedIn && loginDateStr != null) {
      final loginDate = DateTime.parse(loginDateStr);
      final difference = DateTime.now().difference(loginDate).inDays;
      if (difference < 7) {
        setState(() {
          _isLoggedIn = true;
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
    setState(() {
      _themeMode = mode;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isDarkMode', mode == ThemeMode.dark);
  }

  void _onLoginSuccess() {
    setState(() {
      _isLoggedIn = true;
    });
  }

  void _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isLoggedIn', false);
    setState(() {
      _isLoggedIn = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingAuth) {
      return const FluentApp(home: Center(child: ProgressRing()));
    }

    return FluentApp(
      debugShowCheckedModeBanner: false,
      title: 'BDIV-v38.0',
      themeMode: _themeMode,
      theme: FluentThemeData(
        brightness: Brightness.light,
        accentColor: Colors.blue,
      ),
      darkTheme: FluentThemeData(
        brightness: Brightness.dark,
        accentColor: Colors.blue,
      ),
      home: _isLoggedIn
          ? NavigationView(
              appBar: NavigationAppBar(
                title: const Text('BDIV-v38.0'),
                automaticallyImplyLeading: false,
                actions: Padding(
                  padding: const EdgeInsets.only(right: 12.0),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      icon: const Icon(FluentIcons.sign_out), 
                      onPressed: _logout,
                    ),
                  ),
                ),
              ),
              pane: NavigationPane(
                size: const NavigationPaneSize(openWidth: 220.0),
                selected: topIndex,
                onChanged: (index) => setState(() => topIndex = index),
                displayMode: PaneDisplayMode.auto,
                items: [
                  PaneItem(
                    icon: const Icon(FluentIcons.database),
                    title: const Text('Catálogo Maestro'),
                    body: const CatalogScreen(),
                  ),
                  PaneItem(
                    icon: const Icon(FluentIcons.excel_document),
                    title: const Text('Importar Excel'),
                    body: const ArbitrationScreen(),
                  ),
                  PaneItem(
                    icon: const Icon(FluentIcons.search_and_apps),
                    title: const Text('Auditor de Archivos'),
                    body: const AuditorScreen(), // Nueva pantalla Fase 12
                  ),
                  PaneItem(
                    icon: const Icon(FluentIcons.history),
                    title: const Text('Historial de Cambios'),
                    body: const HistoryScreen(),
                  ),
                  PaneItem(
                    icon: const Icon(FluentIcons.edit),
                    title: const Text('Estandarización'),
                    body: StandardizationScreen(),
                  ),
                  PaneItem(
                    icon: const Icon(FluentIcons.paste),
                    title: const Text('Materiales Oficiales'),
                    body: const MaterialsListScreen(),
                  ),
                ],
                footerItems: [
                  PaneItem(
                    icon: const Icon(FluentIcons.settings),
                    title: const Text('Configuración'),
                    body: SettingsScreen(
                      isDarkMode: _themeMode == ThemeMode.dark,
                      onThemeChanged: (isDark) => _updateTheme(isDark ? ThemeMode.dark : ThemeMode.light),
                    ),
                  ),
                ],
              ),
            )
          : LoginScreen(onLoginSuccess: _onLoginSuccess),
    );
  }
}
