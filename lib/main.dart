import 'package:fluent_ui/fluent_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

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

const String API_URL = "http://192.168.1.73:8001";

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
  List<AutoSuggestBoxItem<dynamic>> _searchItems = [];

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

  void _showVINResult(dynamic vin) {
    showDialog(
      context: context,
      builder: (context) => ContentDialog(
        title: Text("Resumen de VIN: ${vin['vin']}"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Tracto: ${vin['tracto']}"),
            Text("Tipo: ${vin['tipo']}"),
            Text("Versión: ${vin['version']}"),
            Text("Cliente: ${vin['cliente']}"),
            Text("Revisión: ${vin['numero_revision']}"),
            const SizedBox(height: 8),
            Text("Notas: ${vin['notas'] ?? 'Sin notas'}", style: const TextStyle(fontStyle: FontStyle.italic)),
          ],
        ),
        actions: [
          Button(child: const Text("Cerrar"), onPressed: () => Navigator.pop(context)),
          FilledButton(
            child: const Text("Ir a la Lista"),
            onPressed: () {
              Navigator.pop(context);
              // Cambiar a la pestaña de BOM Manager (índice 9 en la lista actual)
              setState(() {
                topIndex = 11; // 0-5 Ingeniería, 6 Header, 7 Proyecto, 8 BOM, pero recalculando índices...
                // Según PaneItem list:
                // 0: Header Ing.
                // 1: Catalogo
                // 2: Importar
                // 3: Auditor
                // 4: Historial
                // 5: Estandarizacion
                // 6: Materiales
                // 7: Header Estr.
                // 8: Gestión Proyectos
                // 9: Gestor BOM
              });
              // Para pasar parámetros dinámicos, necesitamos que BOMManagerScreen soporte navegación tipada o usar un GlobalKey/Provider.
              // Por ahora, como es un NavigationView simple, pasaremos los datos vía Navigator si es necesario, 
              // pero aquí el PaneItem ya está instanciado. 
              // Una mejor opción es usar Navigator.push si queremos pasar ID directamente.
              Navigator.push(context, FluentPageRoute(builder: (context) => BOMManagerScreen(
                idCliente: vin['id_cliente'],
                clientName: vin['cliente'],
              )));
            },
          ),
        ],
      ),
    );
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
                leading: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12.0),
                  child: Icon(FluentIcons.factory),
                ),
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
                  PaneItemHeader(header: const Text('Ingeniería')),
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
                  PaneItemHeader(header: const Text('Estructuras')),
                  PaneItem(
                    icon: const Icon(FluentIcons.org),
                    title: const Text('Gestión de Proyectos'),
                    body: const ProjectManagementScreen(),
                  ),
                  PaneItem(
                    icon: const Icon(FluentIcons.copy),
                    title: const Text('Gestor de Listas (BOM)'),
                    body: const BOMManagerScreen(),
                  ),
                  PaneItem(
                    icon: const Icon(FluentIcons.car),
                    title: const Text('Expedientes VIN'),
                    body: const VINDossierScreen(),
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
