import 'package:fluent_ui/fluent_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/catalog.dart';
import 'screens/configuration.dart';
import 'screens/editor.dart';
import 'screens/settings.dart';
import 'screens/login.dart';

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
      title: 'Industrial Manager v15.5',
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
                title: const Text('Industrial Manager v15.5'),
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
                    icon: const Icon(FluentIcons.edit),
                    title: const Text('Editor de Datos'),
                    body: const EditorScreen(),
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
                  PaneItem( // Changed from NavigationPaneItem to PaneItem to match existing items
                    icon: const Icon(FluentIcons.settings),
                    title: const Text('Configuración'),
                    body: const ConfigurationScreen(),
                  ),
                ],
              ),
            )
          : LoginScreen(onLoginSuccess: _onLoginSuccess),
    );
  }
}
