import 'dart:ui';
import 'dart:io';
import 'dart:convert';
import 'package:fluent_ui/fluent_ui.dart';
import 'database_helper.dart';
import 'package:syncfusion_flutter_datagrid/datagrid.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import 'version.dart';
import 'catalog_screen.dart';
import 'arbitrator_screen.dart';
import 'theme_manager.dart';
import 'package:flutter/services.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: themeManager,
      builder: (context, _) {
        return FluentApp(
          title: 'INDUSTRIAL MASTER v$APP_VERSION - INTEGRITY SUITE',
          themeMode: themeManager.themeMode,
          theme: themeManager.lightTheme,
          darkTheme: themeManager.darkTheme,
          home: const KeyboardInterceptor(child: MainGlassPage()),
        );
      },
    );
  }
}

class KeyboardInterceptor extends StatelessWidget {
  final Widget child;
  const KeyboardInterceptor({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          // If any single letter is pressed without modifiers
          if (event.logicalKey.keyLabel.length == 1 &&
              !HardwareKeyboard.instance.isControlPressed &&
              !HardwareKeyboard.instance.isAltPressed) {
            
            final primaryFocus = FocusManager.instance.primaryFocus;
            final bool isInputFocused = primaryFocus != null && 
                (primaryFocus.context?.widget is EditableText || 
                 primaryFocus.context?.findAncestorWidgetOfExactType<EditableText>() != null);

                // If input is focused, let it pass (ignored means let standard processing happen)
                // Actually, if we want to DISABLE shortcuts while typing, we just let it pass.
                // The problem is when a shortcut is registered GLOBALLY.
                if (isInputFocused) {
                  return KeyEventResult.ignored;
                }
          }
        }
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }
}

class MainGlassPage extends StatefulWidget {
  const MainGlassPage({super.key});

  @override
  State<MainGlassPage> createState() => _MainGlassPageState();
}

class _MainGlassPageState extends State<MainGlassPage> {
  int topIndex = 0;
  bool isCollapsed = false;
  final DatabaseHelper db = DatabaseHelper();

  @override
  void initState() {
    super.initState();
    _checkInitialConnection();
  }

  Future<void> _checkInitialConnection() async {
    // VALIDACIÓN CRÍTICA: Verificar existencia de data_bridge.exe (NON-BLOCKING)
    if (!DatabaseHelper.validateCriticalFiles()) {
      if (mounted) {
        setState(() => topIndex = 6);
        displayInfoBar(
          context,
          builder: (context, close) {
            return InfoBar(
              title: const Text('⚠️ Backend No Detectado'),
              content: const Text(
                'No se encontró data_bridge.exe. Algunas funciones no estarán disponibles.\n'
                'Vaya a Diagnóstico SENTINEL para más detalles.',
              ),
              severity: InfoBarSeverity.error,
              isLong: true,
            );
          },
          duration: const Duration(seconds: 10),
        );
      }
      return;
    }

    final res = await db.testConnection();
    if (res['status'] != 'success') {
      setState(() => topIndex = 6);
      if (mounted) {
        displayInfoBar(
          context,
          builder: (context, close) {
            return InfoBar(
              title: const Text('Error de Conexión'),
              content: Text('No se pudo establecer conexión con el servidor: ${res['message']}'),
              severity: InfoBarSeverity.error,
            );
          },
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return NavigationView(
      appBar: NavigationAppBar(
        title: Text(
          'INDUSTRIAL MASTER v$APP_VERSION',
          style: const TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2),
        ),
        leading: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Image.asset(
            'assets/logo.png',
            errorBuilder: (c, o, s) => Icon(FluentIcons.app_icon_default, size: 24, color: Colors.blue),
          ),
        ),
        actions: Padding(
          padding: const EdgeInsets.only(right: 12.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Tooltip(
                message: 'Cambiar Tema',
                child: IconButton(
                  icon: Icon(
                    themeManager.isDarkMode ? FluentIcons.brightness : FluentIcons.lower_brightness,
                    size: 20,
                  ),
                  onPressed: () => themeManager.toggleTheme(),
                ),
              ),
            ],
          ),
        ),
        automaticallyImplyLeading: false,
      ),
      pane: NavigationPane(
        selected: topIndex,
        onChanged: (index) => setState(() => topIndex = index),
        displayMode: isCollapsed ? PaneDisplayMode.compact : PaneDisplayMode.open,
        items: [
          PaneItem(
            icon: const Icon(FluentIcons.home),
            title: const Text('Inicio'),
            body: HomeGlassPage(
              onGoToConfig: () => setState(() => topIndex = 6),
            ),
          ),
          PaneItem(
            icon: const Icon(FluentIcons.clipboard_list),
            title: const Text('Pendientes de Excel'),
            body: const HomologationTasksGlassPage(),
          ),
          PaneItem(
            icon: const Icon(FluentIcons.database),
            title: const Text('Catálogo Maestro'),
            body: const MasterCatalogGlassPage(),
          ),

          PaneItem(
            icon: const Icon(FluentIcons.warning),
            title: const Text('Árbitro de Conflictos'),
            body: const AuditGlassPage(),
          ),
          PaneItem(
            icon: const Icon(FluentIcons.history),
            title: const Text('Historial Resoluciones'),
            body: const ResolvedHistoryGlassPage(),
          ),
          PaneItem(
            icon: const Icon(FluentIcons.sync_occurence),
            title: const Text('Automatización'),
            body: const AutomationGlassPage(),
          ),
          PaneItemSeparator(),
          PaneItem(
            icon: const Icon(FluentIcons.settings),
            title: const Text('Configuración'),
            body: const ServerConfigGlassPage(),
          ),
        ],
        footerItems: [
          PaneItemAction(
            icon: Icon(
              isCollapsed ? FluentIcons.open_pane : FluentIcons.close_pane,
            ),
            onTap: () => setState(() => isCollapsed = !isCollapsed),
            title: const Text('Colapsar Menú'),
          ),
          PaneItemAction(
            icon: Icon(FluentIcons.help),
            onTap: () {
              showDialog(
                context: context,
                builder: (context) => const HelpDialog(),
              );
            },
            title: const Text('Manual de Usuario'),
          ),
        ],
      ),
    );
  }
}

class HomeGlassPage extends StatelessWidget {
  final VoidCallback onGoToConfig;
  const HomeGlassPage({super.key, required this.onGoToConfig});

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white.withOpacity(0.9) : Colors.black.withOpacity(0.87);
    final subtitleColor = isDark ? Colors.white.withOpacity(0.5) : Colors.black.withOpacity(0.54);

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E1E1E) : Colors.black.withOpacity(0.03),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: isDark ? const Color(0xFF333333) : Colors.black.withOpacity(0.05)),
            ),
            child: Column(
              children: [
                Text(
                  "JAES",
                  style: TextStyle(
                    fontSize: 100,
                    fontWeight: FontWeight.w900,
                    color: titleColor,
                    letterSpacing: 10,
                    fontFamily: 'Segoe UI Black',
                  ),
                ),
                Text(
                  "BASE DE DATOS INGENIERÍA",
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w300,
                    color: Colors.blue,
                    letterSpacing: 5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 30),
          Text(
            "Versión $APP_VERSION | Build: $BUILD_DATE",
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: subtitleColor,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 40),
          Button(
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(FluentIcons.settings, size: 18),
                  SizedBox(width: 8),
                  Text(
                    "Configurar Servidor",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
            onPressed: onGoToConfig,
          ),
        ],
      ),
    );
  }
}

class HelpDialog extends StatefulWidget {
  const HelpDialog({super.key});
  @override
  State<HelpDialog> createState() => _HelpDialogState();
}

class _HelpDialogState extends State<HelpDialog> {
  int index = 0;

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: const Text('Manual de Usuario v6.5'),
      content: SizedBox(
        width: 700,
        height: 500,
        child: TabView(
          currentIndex: index,
          onChanged: (i) => setState(() => index = i),
          tabs: [
            Tab(
              text: const Text('Inicio y Conexión'),
              body: Padding(
                padding: const EdgeInsets.all(12),
                child: ListView(
                  children: const [
                    Text(
                      'CONFIGURACIÓN INICIAL',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    SizedBox(height: 10),
                    Text(
                      'Al abrir la aplicación por primera vez, debe configurar la conexión al servidor.',
                    ),
                    SizedBox(height: 10),
                    Text(
                      '1. Servidor SQL: Se recomienda usar la IP fija "192.168.1.73,1433" para evitar problemas de resolución de nombres.',
                    ),
                    Text(
                      '2. Base de Datos: Por defecto es "DB_Materiales_Industrial".',
                    ),
                    Text(
                      '3. Autenticación: Use "Trusted Connection" si está en dominio, o desactívelo para usar usuario y contraseña SQL.',
                    ),
                    SizedBox(height: 10),
                    Text('IMPORTANTE:'),
                    Text(
                      'Pulse el botón "Probar Conexión" antes de salir. Si es exitosa (barra verde), la configuración se guardará automáticamente.',
                    ),
                  ],
                ),
              ),
            ),
            Tab(
              text: const Text('Tablero Principal'),
              body: Padding(
                padding: const EdgeInsets.all(12),
                child: ListView(
                  children: const [
                    Text(
                      'LECTURA DEL TABLERO',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    SizedBox(height: 10),
                    Text(
                      'El tablero muestra el Maestro de Materiales en tiempo real.',
                    ),
                    SizedBox(height: 10),
                    Text(
                      '• Búsqueda: Use las cajas de texto sobre cada columna para filtrar (ej. escriba "PLACA" en Descripción).',
                    ),
                    Text(
                      '• Ordenar: Haga clic en los encabezados para ordenar ascendente o descendentemente.',
                    ),
                    Text(
                      '• Ver Plano: Si una pieza tiene un icono de PDF a la izquierda, haga clic para abrir el plano automáticamente.',
                    ),
                    SizedBox(height: 10),
                    Text('COLORES DE ESTADO:'),
                    Text('• Fila Normal: Pieza validada.'),
                    Text(
                      '• Fila Roja (Conflictos): Hay discrepancias entre el Maestro y los archivos de ingeniería recientes. Requiere revisión.',
                    ),
                  ],
                ),
              ),
            ),
            Tab(
              text: const Text('Resolución de Conflictos'),
              body: Padding(
                padding: const EdgeInsets.all(12),
                child: ListView(
                  children: const [
                    Text(
                      '¿CÓMO USAR EL ÁRBITRO?',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    SizedBox(height: 10),
                    Text('• EDITAR: Si ve una diferencia pero quiere corregirla manualmente antes de guardar.'),
                    Text('• ACEPTAR: Si el dato de la derecha (Excel) es el correcto y quiere que se guarde en el Maestro.'),
                    SizedBox(height: 15),
                    Text(
                      'SIGNIFICADO DE COLORES',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    SizedBox(height: 10),
                    Text('🟢 VERDE: El registro se guardó correctamente en la Base de Datos.'),
                    Text('🟠 NARANJA: Existe una diferencia que requiere su atención.'),
                    Text('🔴 ROJO: Error crítico. No se pudo guardar o no hay conexión.'),
                  ],
                ),
              ),
            ),
            Tab(
              text: const Text('Conexión y Red'),
              body: Padding(
                padding: const EdgeInsets.all(12),
                child: ListView(
                  children: const [
                    Text(
                      'CONFIGURACIÓN SIMPLIFICADA',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    SizedBox(height: 10),
                    Text('• Botón Conectar: Configura automáticamente la IP de la Oficina Técnica (PC08).'),
                    Text('• IP del Servidor: Se encuentra en la etiqueta física de la CPU del servidor o solicitándola a TI (actualmente 192.168.1.73).'),
                    Text('• Diagnóstico SENTINEL: Indica si hay bloqueos de Firewall o falta de drivers.'),
                  ],
                ),
              ),
            ),
            Tab(
              text: const Text('Búsqueda de Planos'),
              body: Padding(
                padding: const EdgeInsets.all(12),
                child: ListView(
                  children: const [
                    Text(
                      'SISTEMA INTELIGENTE DE PLANOS',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    SizedBox(height: 10),
                    Text('El sistema busca planos PDF en dos ubicaciones:'),
                    Text('1. Ruta de Proyecto: Busca inteligentemente en subcarpetas de la ruta configurada.'),
                    Text('2. Genéricos: Ubicados en Z:\\5. PIEZAS GENERICAS\\JA\'S PDF.'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        Button(
          child: const Text('Entendido'),
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
  }
}

void showHelpDialog(BuildContext context) {
  // Deprecated shim, logic moved to HelpDialog widget
}

// -------------------- GLASS CONTAINER HELPER --------------------

class GlassCard extends StatelessWidget {
  final Widget child;
  final double blur;
  final double opacity;
  final Color? color;

  const GlassCard({
    super.key,
    required this.child,
    this.blur = 10,
    this.opacity = 0.05,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    // Fallback base color if none provided
    final baseColor = color ?? (isDark ? Colors.white : Colors.black);
    
    // DARK MODE PRO REDESIGN
    if (isDark) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E).withOpacity(0.7),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF4CC2FF).withOpacity(0.2)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.3),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: child,
          ),
        ),
      );
    }

    // Fluent/Office style: In light mode, prefer solid cards unless color specifically overridden
    if (color == null) {
      return Container(
        decoration: BoxDecoration(
          color: theme.cardColor,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
          border: Border.all(color: Colors.black.withOpacity(0.05)),
        ),
        child: child,
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          decoration: BoxDecoration(
            color: baseColor.withOpacity(opacity),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: baseColor.withOpacity(0.1), width: 1.5),
          ),
          child: child,
        ),
      ),
    );
  }
}

// MasterCatalogGlassPage and MasterDataSource moved to catalog_screen.dart


class AuditGlassPage extends StatefulWidget {
  const AuditGlassPage({super.key});

  @override
  State<AuditGlassPage> createState() => _AuditGlassPageState();
}

class _AuditGlassPageState extends State<AuditGlassPage> {
  final DatabaseHelper db = DatabaseHelper();

  List<Map<String, dynamic>> conflicts = [];

  bool loading = true;

  String? error;

  @override
  void initState() {
    super.initState();

    load();
  }

  Future<void> load() async {
    if (!mounted) return;

    setState(() {
      loading = true;
      error = null;
    });

    try {
      final res = await db.getConflicts();

      if (mounted)
        setState(() {
          conflicts = res;
          loading = false;
        });
    } catch (e) {
      if (mounted)
        setState(() {
          error = e.toString();
          loading = false;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: const PageHeader(title: Text('Árbitro de Conflictos')),

      content:
          loading
              ? const Center(child: ProgressRing())
              : error != null
              ? Center(
                child: GlassCard(
                  color: Colors.red,

                  opacity: 0.1,

                  child: Padding(
                    padding: const EdgeInsets.all(24),

                    child: Column(
                      mainAxisSize: MainAxisSize.min,

                      children: [
                        Icon(FluentIcons.error, color: Colors.red, size: 40),

                        const SizedBox(height: 16),

                        Text(
                          'Error en Árbitro: $error',
                          style: TextStyle(color: Colors.red),
                        ),

                        const SizedBox(height: 16),

                        Button(
                          onPressed: load,
                          child: const Text('Reintentar'),
                        ),
                      ],
                    ),
                  ),
                ),
              )
              : ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 24),

                itemCount: conflicts.length,

                itemBuilder:
                    (c, i) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),

                      child: GlassCard(
                        child: ListTile(
                          leading: Icon(
                            FluentIcons.warning,
                            color: Colors.orange,
                          ),

                          title: Text(
                            "Conflicto: ${conflicts[i]['Codigo_Pieza']}",
                          ),

                          subtitle: Text(
                            "Detectado en: ${conflicts[i]['Archivo']}",
                          ),

                          trailing: FilledButton(
                            child: const Text('Resolver'),

                            onPressed:
                                () => showResolveDialog(
                                  context,
                                  conflicts[i],
                                  load,
                                ),
                          ),
                        ),
                      ),
                    ),
              ),
    );
  }
}

// showResolveDialog and smartDiff moved to arbitrator_screen.dart


// showHomologationDialog moved to arbitrator_screen.dart





class ListCreatorGlassPage extends StatefulWidget {
  const ListCreatorGlassPage({super.key});

  @override
  State<ListCreatorGlassPage> createState() => _ListCreatorGlassPageState();
}

class _ListCreatorGlassPageState extends State<ListCreatorGlassPage> {
  final DatabaseHelper db = DatabaseHelper();

  List<Map<String, dynamic>> rows = [];

  @override
  void initState() {
    super.initState();

    for (int i = 0; i < 5; i++) {
      rows.add({
        'code': TextEditingController(),
        'desc': TextEditingController(),
        'qty': TextEditingController(text: '0'),
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: const PageHeader(title: Text('Creador de Listas v5.5')),

      content: Padding(
        padding: const EdgeInsets.all(24),

        child: Column(
          children: [
            GlassCard(
              color: Colors.blue,

              opacity: 0.15,

              child: Padding(
                padding: const EdgeInsets.all(16),

                child: Row(
                  children: [
                    Icon(FluentIcons.info, color: Colors.blue),

                    const SizedBox(width: 12),

                    const Expanded(
                      child: Text(
                        "GUÍA RÁPIDA: 1. Ingresa el Código. 2. Presiona ENTER para completar. 3. Define Cantidad y Exporta.",

                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 20),

            Expanded(
              child: ListView.builder(
                itemCount: rows.length,

                itemBuilder:
                    (c, i) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),

                      child: GlassCard(
                        child: Padding(
                          padding: const EdgeInsets.all(8),

                          child: Row(
                            children: [
                              Expanded(
                                flex: 2,
                                child: TextBox(
                                  controller: rows[i]['code'],
                                  placeholder: 'Paso 1: Código',
                                ),
                              ),

                              const SizedBox(width: 10),

                              Expanded(
                                flex: 4,
                                child: TextBox(
                                  controller: rows[i]['desc'],
                                  placeholder:
                                      'Paso 2: Desc (Enter para autollenado)',
                                ),
                              ),

                              const SizedBox(width: 10),

                              Expanded(
                                flex: 1,
                                child: TextBox(controller: rows[i]['qty']),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AutomationGlassPage extends StatefulWidget {
  const AutomationGlassPage({super.key});

  @override
  State<AutomationGlassPage> createState() => _AutomationGlassPageState();
}

class _AutomationGlassPageState extends State<AutomationGlassPage>
    with AutomaticKeepAliveClientMixin {
  final DatabaseHelper db = DatabaseHelper();
  List<String> logs = [];
  bool running = false;
  String? selectedFolder;

  @override
  bool get wantKeepAlive => true;

  Future<void> pickFolder() async {
    String? result = await FilePicker.platform.getDirectoryPath();
    if (result != null) {
      if (mounted) {
        setState(() {
          selectedFolder = result;
          logs.add("Carpeta seleccionada: $result\n");
        });
      }
    }
  }

  void runCarga() {
    if (selectedFolder == null) {
      setState(() => logs.add("ERROR: Seleccione una carpeta primero.\n"));
      return;
    }

    setState(() {
      logs.clear();
      running = true;
      logs.add("Iniciando escaneo en: $selectedFolder\n");
    });

    db
        .runImporter(folderPath: selectedFolder!)
        .listen(
          (data) {
            if (mounted) setState(() => logs.add(data));
          },
          onDone: () {
            if (mounted)
              setState(() {
                running = false;
                logs.add("\n--- PROCESO TERMINADO ---\n");
              });
          },
          onError: (e) {
            if (mounted)
              setState(() {
                logs.add("ERROR FATAL: $e");
                running = false;
              });
          },
        );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return ScaffoldPage(
      header: const PageHeader(
        title: Text('Automatización Industrial (Masiva)'),
      ),
      content: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            // Control Panel
            GlassCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Paso 1: Seleccionar Origen de Datos",
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Button(
                          onPressed: running ? null : pickFolder,
                          child: const Row(
                            children: [
                              Icon(FluentIcons.folder_open),
                              SizedBox(width: 8),
                              Text("Buscar Carpeta"),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextBox(
                            readOnly: true,
                            placeholder:
                                selectedFolder ??
                                'Ninguna carpeta seleccionada (Se requiere ruta válida)',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 20),

            SizedBox(
              width: double.infinity,
              height: 50,
              child: FilledButton(
                onPressed: running || selectedFolder == null ? null : runCarga,
                child: Text(
                  running ? 'PROCESANDO ARCHIVOS...' : 'INICIAR CARGA MASIVA',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),

            if (running)
              Padding(
                padding: const EdgeInsets.only(top: 10),

                child: ProgressBar(),
              ),

            const SizedBox(height: 20),

            Expanded(
              child: GlassCard(
                color: Colors.black,

                opacity: 0.8,

                child: Container(
                  width: double.infinity,

                  padding: const EdgeInsets.all(16),

                  child: SingleChildScrollView(
                    child: SelectionArea(
                      child: Text(
                        logs.join(''),

                        style: TextStyle(
                          fontFamily: 'Consolas',
                          fontSize: 13,
                          color: Colors.green,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class HomologationTasksGlassPage extends StatefulWidget {
  const HomologationTasksGlassPage({super.key});

  @override
  State<HomologationTasksGlassPage> createState() =>
      _HomologationTasksGlassPageState();
}

class _HomologationTasksGlassPageState
    extends State<HomologationTasksGlassPage> {
  final DatabaseHelper db = DatabaseHelper();

  List<Map<String, dynamic>> tasks = [];

  bool loading = true;

  @override
  void initState() {
    super.initState();

    load();
  }

  Future<void> load() async {
    if (!mounted) return;

    setState(() {
      loading = true;
    });

    try {
      // Use getPendingTasks to ensure Excel metadata is available
      final res = await db.getPendingTasks();

      if (mounted)
        setState(() {
          tasks = res;
          loading = false;
        });
    } catch (e) {
      if (mounted)
        setState(() {
          loading = false;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: PageHeader(
        title: const Text('Correcciones Pendientes en Excel'),

        commandBar: Button(
          child: const Row(
            children: [
              Icon(FluentIcons.refresh),
              SizedBox(width: 8),
              Text('Recargar'),
            ],
          ),

          onPressed: load,
        ),
      ),

      content: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),

        child:
            loading
                ? const Center(child: ProgressRing())
                : tasks.isEmpty
                ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,

                    children: [
                      Icon(
                        FluentIcons.check_mark,
                        size: 48,
                        color: Colors.green,
                      ),

                      const SizedBox(height: 16),

                      const Text(
                        "¡Todo al día! No hay correcciones pendientes.",
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                )
                : Builder(
                  builder: (context) {
                    // Grouping Logic

                    final Map<String, List<Map<String, dynamic>>> grouped = {};

                    for (var item in tasks) {
                      final code = item['codigo'] ?? 'DESCONOCIDO'; // Updated key

                      grouped.putIfAbsent(code, () => []);

                      grouped[code]!.add(item);
                    }

                    final keys = grouped.keys.toList()..sort();

                    return ListView.builder(
                      padding: const EdgeInsets.only(bottom: 24),

                      itemCount: keys.length,

                      itemBuilder: (context, index) {
                        final code = keys[index];

                        final items = grouped[code]!;

                        // Use the First item to get Official Description (assumed same for all with same code)

                        final officialDesc =
                            items.first['descripcion'] ?? // Updated key
                            'Sin Descripción en BD';

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Card(
                            padding: const EdgeInsets.all(12),
                            borderRadius: BorderRadius.circular(12),
                            child: Expander(
                              header: Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                    decoration: BoxDecoration(
                                      color: Colors.orange,
                                      borderRadius: BorderRadius.circular(6),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.orange.withOpacity(0.3),
                                          blurRadius: 4,
                                          offset: const Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                    child: Text(
                                      code,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          "Descripción BD",
                                          style: FluentTheme.of(context).typography.caption?.copyWith(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        Text(
                                          officialDesc,
                                          style: FluentTheme.of(context).typography.bodyStrong?.copyWith(
                                            fontSize: 14,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: Colors.red.withOpacity(0.9),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Text(
                                      "${items.length} errores",
                                      style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ],
                              ),
                              initiallyExpanded: true,
                              content: Column(
                                children: items.map((item) {
                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 8),
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: FluentTheme.of(context).cardColor,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: FluentTheme.of(context).brightness == Brightness.dark 
                                            ? Colors.white.withOpacity(0.08) 
                                            : Colors.black.withOpacity(0.05),
                                      ),
                                    ),
                                    child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        // Icono File
                                        Container(
                                          padding: const EdgeInsets.all(8),
                                          decoration: BoxDecoration(
                                            color: Colors.green.withOpacity(0.1),
                                            shape: BoxShape.circle,
                                          ),
                                          child: Icon(FluentIcons.excel_document, size: 16, color: Colors.green),
                                        ),
                                        const SizedBox(width: 14),
                                        // Info
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                item['archivo'] ?? 'Desconocido',
                                                style: FluentTheme.of(context).typography.bodyStrong,
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                "Fila: ${item['fila']} • Hoja: ${item['hoja']}",
                                                style: FluentTheme.of(context).typography.caption,
                                              ),
                                              const SizedBox(height: 6),
                                              Text(
                                                "Excel: ${item['desc_excel'] ?? '---'}",
                                                style: TextStyle(
                                                  color: Colors.orange,
                                                  fontFamily: 'Consolas',
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        // Action
                                        Button(
                                          child: const Text("Corregido"),
                                          onPressed: () async {
                                            await db.markTaskCorrected(item['id']);
                                            load();
                                          },
                                        ),
                                      ],
                                    ),
                                  );
                                }).toList(),
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
      ),
    );
  }
}

class ResolvedHistoryGlassPage extends StatefulWidget {
  const ResolvedHistoryGlassPage({super.key});
  @override
  State<ResolvedHistoryGlassPage> createState() =>
      _ResolvedHistoryGlassPageState();
}

class _ResolvedHistoryGlassPageState extends State<ResolvedHistoryGlassPage> {
  List<Map<String, dynamic>> tasks = [];
  bool loading = false;
  final DatabaseHelper db = DatabaseHelper();

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() => loading = true);
    final data = await db.getResolvedTasks();
    if (mounted)
      setState(() {
        tasks = data;
        loading = false;
      });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = FluentTheme.of(context).brightness == Brightness.dark;
    return ScaffoldPage(
      header: PageHeader(
        title: const Text('Historial de Resoluciones'),
        commandBar: Button(
          child: const Icon(FluentIcons.refresh),
          onPressed: load,
        ),
      ),
      content:
          loading
              ? const Center(child: ProgressRing())
              : tasks.isEmpty
              ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text("No hay historial de resoluciones."),
                    const SizedBox(height: 16),
                    Button(
                      child: const Text("Forzar Recarga"),
                      onPressed: () => load(),
                    ),
                  ],
                ),
              )
              : ListView.builder(
                padding: const EdgeInsets.only(bottom: 24, left: 24, right: 24),
                itemCount: tasks.length,
                itemBuilder: (context, index) {
                  final item = tasks[index];
                  final status = item['estado'] ?? '---';
                  Color statusColor =
                      status == 'CORREGIDO' ? Colors.green : Colors.orange;

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: GlassCard(
                      child: ListTile(
                        leading: Icon(
                          status == 'CORREGIDO'
                              ? FluentIcons.check_mark
                              : FluentIcons.remove_occurrence,
                          color: statusColor,
                        ),
                        title: Text(
                          "${item['codigo'] ?? 'N/A'} - ${item['descripcion'] ?? ''}",
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "Resolución: $status",
                              style: TextStyle(
                                color: statusColor,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              "Usuario: ${item['usuario']}",
                              style: TextStyle(
                                fontSize: 12,
                                color: isDark ? Colors.white.withOpacity(0.7) : Colors.black.withOpacity(0.6),
                              ),
                            ),
                            Text(
                              "📅 Fecha: ${item['fecha_fmt'] ?? 'Fecha desconocida'}",
                              style: TextStyle(
                                fontSize: 10,
                                color: isDark ? Colors.white.withOpacity(0.5) : Colors.black.withOpacity(0.4),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
    );
  }
}

class ServerConfigGlassPage extends StatefulWidget {
  const ServerConfigGlassPage({super.key});

  @override
  State<ServerConfigGlassPage> createState() => _ServerConfigGlassPageState();
}

class _ServerConfigGlassPageState extends State<ServerConfigGlassPage> {
  final db = DatabaseHelper();
  final serverController = TextEditingController(text: "192.168.1.73,1433");
  final dbController = TextEditingController(text: "DB_Materiales_Industrial");
  final userController = TextEditingController(text: "jaes_admin");
  final passController = TextEditingController(text: "Jaes2026*");
  final blueprintsController = TextEditingController();
  final genericsController = TextEditingController();
  bool isWindowsAuth = false;
  bool testing = false;

  @override
  void initState() {
    super.initState();
    load();
    if (genericsController.text.isEmpty) {
      genericsController.text = r"Z:\5. PIEZAS GENERICAS\JA'S PDF";
    }
  }

  Future<void> load() async {
    final cfg = await db.getConfig();
    setState(() {
      if (cfg['server']?.toString().isNotEmpty ?? false) serverController.text = cfg['server'];
      if (cfg['database']?.toString().isNotEmpty ?? false) dbController.text = cfg['database'];
      if (cfg['trusted_connection'] != null) {
        isWindowsAuth = cfg['trusted_connection'].toString().toLowerCase() == 'yes';
      }
      if (cfg['username']?.toString().isNotEmpty ?? false) userController.text = cfg['username'];
      if (cfg['password']?.toString().isNotEmpty ?? false) passController.text = cfg['password'];
      if (cfg['blueprints_path']?.toString().isNotEmpty ?? false) blueprintsController.text = cfg['blueprints_path'];
      if (cfg['generics_path']?.toString().isNotEmpty ?? false) {
        genericsController.text = cfg['generics_path'];
      } else {
        genericsController.text = r"Z:\5. PIEZAS GENERICAS\JA'S PDF";
      }
    });
  }

  Future<void> pickBlueprintsFolder() async {
    String? result = await FilePicker.platform.getDirectoryPath();
    if (result != null) setState(() => blueprintsController.text = result);
  }

  Future<void> save() async {
    final config = {
      "server": serverController.text,
      "database": dbController.text,
      "driver": "ODBC Driver 18 for SQL Server",
      "trusted_connection": isWindowsAuth ? "yes" : "no",
      "username": userController.text,
      "password": passController.text,
      "blueprints_path": blueprintsController.text,
      "generics_path": genericsController.text,
    };
    await db.saveConfig(config);
    if (mounted) {
      displayInfoBar(context, builder: (context, close) => const InfoBar(
        title: Text('Éxito'),
        content: Text('Configuración guardada correctamente.'),
        severity: InfoBarSeverity.success,
      ));
    }
  }

  Future<void> test() async {
    await save();
    setState(() => testing = true);
    try {
      final res = await db.testConnection();
      if (mounted) {
        displayInfoBar(context, builder: (context, close) => InfoBar(
          title: Text(res['status'] == 'success' ? 'Conexión Exitosa' : 'Error de Servidor'),
          content: SelectableText(res['message'] ?? 'Sin respuesta'),
          severity: res['status'] == 'success' ? InfoBarSeverity.success : InfoBarSeverity.error,
          action: IconButton(icon: const Icon(FluentIcons.clear), onPressed: close),
        ));
      }
    } finally {
      if (mounted) setState(() => testing = false);
    }
  }

  Future<void> diagnoseSystem() async {
    setState(() => testing = true);
    try {
      final result = await db.runDiagnostics();
      if (mounted) {
        await showDialog(
          context: context,
          builder: (ctx) => ContentDialog(
            title: const Text('Diagnóstico SENTINEL'),
            content: SelectableText(
              'Backend: ${result['backend'] == true ? '✅ OK' : '❌ FALTA'}\n'
              'Conexión BD: ${result['connection'] == true ? '✅ OK' : '❌ ERROR'}\n'
              'Mensaje: ${result['message']}\n'
              'Path: ${result['path'] ?? 'N/A'}'
            ),
            actions: [Button(child: const Text('Cerrar'), onPressed: () => Navigator.pop(ctx))],
          ),
        );
      }
    } finally {
      if (mounted) setState(() => testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: const PageHeader(title: Text('Configuración del Sistema')),
      content: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Column(
              children: [
                const SizedBox(height: 40),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: SizedBox(
                        height: 80,
                        child: FilledButton(
                          onPressed: testing ? null : test,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (testing) const SizedBox(width: 20, height: 20, child: ProgressRing())
                              else const Icon(FluentIcons.plug_connected, size: 24),
                              const SizedBox(width: 15),
                              const Text("Conectar a Base de Datos", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SizedBox(
                        height: 80,
                        child: Button(
                          onPressed: testing ? null : runSentinel,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(FluentIcons.health, size: 20, color: Colors.orange),
                              SizedBox(height: 4),
                              Text("Diagnóstico", style: TextStyle(fontSize: 12)),
                              Text("SENTINEL", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 10)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Expander(
                  header: const Text("⚙️ Opciones Avanzadas (Técnico)", style: TextStyle(fontWeight: FontWeight.bold)),
                  content: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      InfoLabel(
                        label: 'Servidor (IP, Puerto)',
                        child: Row(
                          children: [
                            Expanded(child: TextBox(controller: serverController)),
                            const SizedBox(width: 8),
                            Button(
                              onPressed: () => setState(() => serverController.text = r"localhost\SQLEXPRESS"),
                              child: const Row(
                                children: [
                                  Icon(FluentIcons.server, size: 16),
                                  SizedBox(width: 8),
                                  Text("Usar Localhost"),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      InfoLabel(label: 'Base de Datos', child: TextBox(controller: dbController)),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(child: InfoLabel(label: 'Usuario SQL', child: TextBox(controller: userController))),
                          const SizedBox(width: 12),
                          Expanded(child: InfoLabel(label: 'Password SQL', child: TextBox(controller: passController, obscureText: true))),
                        ],
                      ),
                      const SizedBox(height: 20),
                      const Divider(),
                      const SizedBox(height: 10),
                      const Text("Rutas de Archivos", style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 12),
                      InfoLabel(
                        label: 'Carpeta de Planos PDF (Red)',
                        child: Row(
                          children: [
                            Expanded(child: TextBox(controller: blueprintsController)),
                            const SizedBox(width: 8),
                            Button(onPressed: pickBlueprintsFolder, child: const Icon(FluentIcons.folder_open)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      InfoLabel(label: 'Carpeta de Genéricos', child: TextBox(controller: genericsController)),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: Button(onPressed: save, child: const Text("Guardar Configuración Técnica")),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 40),
                const Opacity(
                  opacity: 0.6,
                  child: Text(
                    "Las credenciales 'jaes_admin' son necesarias para la integridad de datos.\nSi necesita cambiar el servidor, consulte con el administrador.",
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> runSentinel() async {
    setState(() => testing = true);
    try {
      final report = await db.runSentinelDiagnostics();
      if (!mounted) return;
      
      // Adapt to new v10.5 flat structure if keys exist, else fallback (safe migration)
      final dbStatus = report['db_status'] ?? (report['steps']?['connection'] == 'ok') ?? false;
      final integStatus = report['integrity_status'] ?? (report['steps']?['tables'] == 'ok') ?? false;
      final logicStatus = report['logic_status'] ?? (report['steps']?['logic'] == 'ok') ?? false;
      final pathStatus = report['path_status'] ?? (report['steps']?['path'] == 'ok') ?? false;
      
      final rawLog = report['log'] ?? report['raw_log'] ?? 'Error: No se recibió respuesta del Backend (data_bridge.exe)';
      final bool hasCriticalError = rawLog.contains('❌') || rawLog.contains('Excepción') || rawLog.contains('Error');

      showDialog(
        context: context,
        builder: (context) {
          return ContentDialog(
            constraints: const BoxConstraints(maxWidth: 700, maxHeight: 800),
            title: const Text("🛡️ Diagnóstico SENTINEL PRO v10.5"),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildCheckItem("Conexión Base de Datos", dbStatus, false),
                _buildCheckItem("Integridad de Tablas/Columnas", integStatus, false),
                _buildCheckItem("Lógica de Negocio (Excel)", logicStatus, false),
                _buildCheckItem("Ruta de Planos", pathStatus, false),
                const SizedBox(height: 20),
                Row(
                  children: [
                    const Text("Log del Sistema:", style: TextStyle(fontWeight: FontWeight.bold)),
                    if (hasCriticalError)
                      Text(" (ERRORES DETECTADOS)", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.05),
                      border: Border.all(color: hasCriticalError ? Colors.red.withOpacity(0.5) : Colors.grey.withOpacity(0.3)),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText( // Changed to SelectableText for better UX
                        rawLog,
                        style: TextStyle(
                            fontFamily: 'Consolas', 
                            fontSize: 11,
                            color: hasCriticalError ? Colors.red : null
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              Button(
                child: const Text("Cerrar"),
                onPressed: () => Navigator.pop(context),
              ),
              FilledButton(
                child: const Text("Copiar Log"),
                onPressed: () {
                   Navigator.pop(context);
                },
              ),
            ],
          );
        }
      );
    } catch (e) {
      if (mounted) displayInfoBar(context, builder: (c, close) => InfoBar(title: const Text('Error'), content: Text(e.toString()), severity: InfoBarSeverity.error));
    } finally {
      if (mounted) setState(() => testing = false);
    }
  }

  Widget _buildCheckItem(String label, bool isOk, bool isWarning) {
    IconData icon;
    Color color;
    
    if (isOk) {
      icon = FluentIcons.check_mark;
      color = Colors.green;
    } else if (isWarning) {
      icon = FluentIcons.warning;
      color = Colors.orange;
    } else {
      icon = FluentIcons.error;
      color = Colors.red;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Text(label, style: const TextStyle(fontSize: 16)),
          if (isWarning) ...[
            const SizedBox(width: 8),
            Text("(Advertencia)", style: TextStyle(fontSize: 12, color: Colors.orange)),
          ]
        ],
      ),
    );
  }
}
