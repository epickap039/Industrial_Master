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
import 'standards_screen.dart';
import 'sources_screen.dart'; // v13.1
import 'home_screen.dart';
import 'server_config_glass.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  MyApp({Key? key}) : super(key: key);

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
          home: KeyboardInterceptor(child: MainGlassPage()),
        );
      },
    );
  }
}

class KeyboardInterceptor extends StatelessWidget {
  final Widget child;
  KeyboardInterceptor({Key? key, required this.child}) : super(key: key);

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
  MainGlassPage({super.key});

  @override
  State<MainGlassPage> createState() => _MainGlassPageState();
}

class _MainGlassPageState extends State<MainGlassPage> with WidgetsBindingObserver {
  int topIndex = 0;
  bool isCollapsed = false;
  final DatabaseHelper db = DatabaseHelper();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkInitialConnection();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    db.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      db.dispose();
    }
  }

  Future<void> _checkInitialConnection() async {
    // 1. VALIDACIÓN CRÍTICA: data_bridge.exe
    if (!DatabaseHelper.validateCriticalFiles()) {
      if (mounted) {
        // Redirigir a Config de forma limpia
        Navigator.push(context, FluentPageRoute(builder: (c) => ServerConfigGlassPage()));
        displayInfoBar(
          context,
          builder: (context, close) => InfoBar(
            title: Text('⚠️ Backend No Detectado'),
            content: Text('No se encontró data_bridge.exe. Reinstale la aplicación.'),
            severity: InfoBarSeverity.error,
          ),
        );
      }
      return;
    }

    // 2. VALIDACIÓN CONFIGURACIÓN: ¿Existe config.json?
    final config = await db.getConfig();
    final hasServer = config['server']?.toString().isNotEmpty ?? false;
    
    // Si NO hay configuración, no intentamos conectar (evita error 18456 loop)
    if (!hasServer) {
       if (mounted) {
        Navigator.push(context, FluentPageRoute(builder: (c) => ServerConfigGlassPage()));
        displayInfoBar(
          context,
          builder: (context, close) => InfoBar(
            title: Text('Bienvenido a Industrial Master'),
            content: Text('Por favor, configure la conexión al servidor para comenzar.'),
            severity: InfoBarSeverity.info,
          ),
        );
      }
      return;
    }

    // 3. INTENTO DE CONEXIÓN
    final res = await db.testConnection();
    if (res['status'] != 'success') {
      if (mounted) {
        displayInfoBar(
          context,
          builder: (context, close) {
            return InfoBar(
              title: Text('Error de Conexión'),
              content: Text('No se pudo establecer conexión: ${res['message']}'),
              severity: InfoBarSeverity.error,
              action: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Button(
                    child: Text('Reintentar'),
                    onPressed: _checkInitialConnection,
                  ),
                  SizedBox(width: 8),
                  Button(
                    child: Text('Ir a Configuración'),
                    onPressed: () {
                      Navigator.push(context, FluentPageRoute(builder: (c) => ServerConfigGlassPage()));
                    },
                  ),
                ],
              ),
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
          style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2),
        ),
        leading: Padding(
          padding: EdgeInsets.all(8.0),
          child: Image.asset(
            'assets/logo.png',
            errorBuilder: (c, o, s) => Icon(FluentIcons.app_icon_default, size: 24, color: Colors.blue),
          ),
        ),
        actions: Padding(
          padding: EdgeInsets.only(right: 12.0),
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
        onChanged: (index) async {
          if (hasUnsavedChanges) {
            final bool? proceed = await showDialog<bool>(
              context: context,
              builder: (c) => ContentDialog(
                title: Text('⚠️ Cambios sin guardar'),
                content: Text('Tiene cambios en el Catálogo Maestro que no se han guardado. ¿Desea salir de todos modos? Se perderán los cambios.'),
                actions: [
                  Button(
                    child: Text('Continuar Editando'),
                    onPressed: () => Navigator.pop(c, false),
                  ),
                  FilledButton(
                    style: ButtonStyle(backgroundColor: WidgetStateProperty.all(Colors.red)),
                    child: Text('Salir y Perder Cambios'),
                    onPressed: () => Navigator.pop(c, true),
                  ),
                ],
              ),
            );
            if (proceed == true) {
              hasUnsavedChanges = false;
              setState(() => topIndex = index);
            }
          } else {
            setState(() => topIndex = index);
          }
        },
        displayMode: isCollapsed ? PaneDisplayMode.compact : PaneDisplayMode.open,
        items: [
          PaneItem(
            icon: Icon(FluentIcons.home),
            title: Text('Inicio'),
            body: HomeGlassPage(
              onNavigate: (index) => setState(() => topIndex = index),
            ),
          ),
          PaneItemHeader(header: Text('OPERACIÓN DIARIA')),
          PaneItem(
            icon: Icon(FluentIcons.clipboard_list),
            title: Text('📝 Corrección de Excel'),
            body: HomologationTasksGlassPage(),
          ),
          PaneItem(
            icon: Icon(FluentIcons.warning),
            title: Text('⚖️ Validación de Conflictos'),
            body: AuditGlassPage(),
          ),
          PaneItemHeader(header: Text('BIBLIOTECA')),
          PaneItem(
            icon: Icon(FluentIcons.database),
            title: Text('📦 Catálogo Maestro'),
            body: MasterCatalogGlassPage(),
          ),
          PaneItem(
            icon: Icon(FluentIcons.list),
            title: Text('📘 Estándares Materiales'),
            body: StandardsGlassPage(),
          ),
          PaneItemHeader(header: Text('SISTEMA')),
          PaneItem(
            icon: Icon(FluentIcons.history),
            title: Text('📜 Auditoría'),
            body: ResolvedHistoryGlassPage(),
          ),
          PaneItem(
            icon: Icon(FluentIcons.folder_open),
            title: Text('📍 Fuentes de Datos'),
            body: const SourcesPage(),
          ),
          PaneItem(
            icon: Icon(FluentIcons.settings),
            title: Text('⚙️ Configuración'),
            body: ServerConfigGlassPage(),
          ),
        ],
        footerItems: [
          PaneItemAction(
            icon: Icon(
              isCollapsed ? FluentIcons.open_pane : FluentIcons.close_pane,
            ),
            onTap: () => setState(() => isCollapsed = !isCollapsed),
            title: Text('Colapsar Menú'),
          ),
          PaneItemAction(
            icon: Icon(FluentIcons.help),
            onTap: () {
              showDialog(
                context: context,
                builder: (context) => HelpDialog(),
              );
            },
            title: Text('Manual de Usuario'),
          ),
        ],
      ),
    );
  }
}


class HelpDialog extends StatefulWidget {
  HelpDialog({super.key});
  @override
  State<HelpDialog> createState() => _HelpDialogState();
}

class _HelpDialogState extends State<HelpDialog> {
  int index = 0;

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: Text('Manual de Usuario v13.0 - USER CENTRIC'),
      content: SizedBox(
        width: 700,
        height: 500,
        child: TabView(
          currentIndex: index,
          onChanged: (i) => setState(() => index = i),
          tabs: [
            Tab(
              text: Text('Inicio y Conexión'),
              body: Padding(
                padding: EdgeInsets.all(12),
                child: ListView(
                  children: [
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
              text: Text('Tablero Principal'),
              body: Padding(
                padding: EdgeInsets.all(12),
                child: ListView(
                  children: [
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
              text: Text('Resolución de Conflictos'),
              body: Padding(
                padding: EdgeInsets.all(12),
                child: ListView(
                  children: [
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
              text: Text('Conexión y Red'),
              body: Padding(
                padding: EdgeInsets.all(12),
                child: ListView(
                  children: [
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
              text: Text('Búsqueda de Planos'),
              body: Padding(
                padding: EdgeInsets.all(12),
                child: ListView(
                  children: [
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
            Tab(
              text: Text('Smart Homologator (IA)'),
              body: Padding(
                padding: EdgeInsets.all(12),
                child: ListView(
                  children: [
                    Text(
                      'FLUJO DE TRABAJO v12.1',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    SizedBox(height: 10),
                    Text('Para lograr una integridad total de datos, siga estos pasos:'),
                    SizedBox(height: 15),
                    Text(
                      'PASO 1: Homologación Inteligente',
                      style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF4CC2FF)),
                    ),
                    Text('• Diríjase a "Correcciones Pendientes".'),
                    Text('• Use el botón ✨ (IA) para ver sugerencias automáticas.'),
                    Text('• Guarde la corrección para limpiar el dato en el reporte auditado.'),
                    SizedBox(height: 15),
                    Text(
                      'PASO 2: Resolución de Conflictos',
                      style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF4CC2FF)),
                    ),
                    Text('• Vaya al "Tablero Principal" y abra el "Árbitro de Conflictos" (filas rojas).'),
                    Text('• Notará que el dato de Excel ahora es el que usted corrigió en el Paso 1.'),
                    Text('• Presione "Aceptar Cambios" para actualizar el Maestro de Materiales permanentemente.'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        Button(
          child: Text('Entendido'),
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

  GlassCard({
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
              color: Color(0xFF1E1E1E).withOpacity(0.7),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Color(0xFF4CC2FF).withOpacity(0.2)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.3),
                  blurRadius: 20,
                  offset: Offset(0, 10),
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
              offset: Offset(0, 4),
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
  AuditGlassPage({Key? key}) : super(key: key);

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

  void _showHelp(BuildContext context) {
    showDialog(
      context: context,
      builder: (c) => ContentDialog(
        title: Text('📘 Ayuda: Validación de Conflictos'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('¿Qué hago en esta pantalla?', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('Autorice los cambios que se escribirán en la base de datos maestra.'),
            SizedBox(height: 10),
            Text('¿Qué significan los colores?', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('• Naranja: Piezas que tienen discrepancias con el Excel.'),
            Text('• Verde (al guardar): Confirmación de escritura exitosa.'),
            SizedBox(height: 10),
            Text('¿Qué paso sigue?', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('Presione "Resolver" y compare. Si el dato es correcto, dele "Aceptar Cambios".'),
          ],
        ),
        actions: [
          Button(child: Text('OK'), onPressed: () => Navigator.pop(c)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: PageHeader(
        title: Text('⚖️ Validación de Conflictos (Árbitro)'),
        commandBar: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Button(
              onPressed: loading ? null : load,
              child: Row(
                children: [
                  Icon(FluentIcons.refresh),
                  SizedBox(width: 8),
                  Text('Recargar'),
                ],
              ),
            ),
            SizedBox(width: 8),
            IconButton(
              icon: Icon(FluentIcons.help, size: 20),
              onPressed: () => _showHelp(context),
            ),
          ],
        ),
      ),

      content:
          loading
              ? Center(child: ProgressRing())
              : error != null
              ? Center(
                child: GlassCard(
                  color: Colors.red,

                  opacity: 0.1,

                  child: Padding(
                    padding: EdgeInsets.all(24),

                    child: Column(
                      mainAxisSize: MainAxisSize.min,

                      children: [
                        Icon(FluentIcons.error, color: Colors.red, size: 40),

                        SizedBox(height: 16),

                        Text(
                          'Error en Árbitro: $error',
                          style: TextStyle(color: Colors.red),
                        ),

                        SizedBox(height: 16),

                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Button(
                              onPressed: load,
                              child: Text('Reintentar'),
                            ),
                            SizedBox(width: 8),
                            Button(
                              onPressed: () {
                                Navigator.push(context, FluentPageRoute(builder: (c) => ServerConfigGlassPage()));
                              },
                              child: Text('Ir a Configuración'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              )
              : ListView.builder(
                padding: EdgeInsets.symmetric(horizontal: 24),

                itemCount: conflicts.length,

                itemBuilder:
                    (c, i) => Padding(
                      padding: EdgeInsets.only(bottom: 12),

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
                            child: Text('Resolver'),

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
  ListCreatorGlassPage({Key? key}) : super(key: key);

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
      header: PageHeader(title: Text('Creador de Listas v5.5')),

      content: Padding(
        padding: EdgeInsets.all(24),

        child: Column(
          children: [
            GlassCard(
              color: Colors.blue,

              opacity: 0.15,

              child: Padding(
                padding: EdgeInsets.all(16),

                child: Row(
                  children: [
                    Icon(FluentIcons.info, color: Colors.blue),

                    SizedBox(width: 12),

                    Expanded(
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

            SizedBox(height: 20),

            Expanded(
              child: ListView.builder(
                itemCount: rows.length,

                itemBuilder:
                    (c, i) => Padding(
                      padding: EdgeInsets.only(bottom: 8),

                      child: GlassCard(
                        child: Padding(
                          padding: EdgeInsets.all(8),

                          child: Row(
                            children: [
                              Expanded(
                                flex: 2,
                                child: TextBox(
                                  controller: rows[i]['code'],
                                  placeholder: 'Paso 1: Código',
                                ),
                              ),

                              SizedBox(width: 10),

                              Expanded(
                                flex: 4,
                                child: TextBox(
                                  controller: rows[i]['desc'],
                                  placeholder:
                                      'Paso 2: Desc (Enter para autollenado)',
                                ),
                              ),

                              SizedBox(width: 10),

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
  AutomationGlassPage({Key? key}) : super(key: key);

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
      header: PageHeader(
        title: Text('Automatización Industrial (Masiva)'),
      ),
      content: Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          children: [
            // Control Panel
            GlassCard(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Paso 1: Seleccionar Origen de Datos",
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    SizedBox(height: 10),
                    Row(
                      children: [
                        Button(
                          onPressed: running ? null : pickFolder,
                          child: Row(
                            children: [
                              Icon(FluentIcons.folder_open),
                              SizedBox(width: 8),
                              Text("Buscar Carpeta"),
                            ],
                          ),
                        ),
                        SizedBox(width: 12),
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

            SizedBox(height: 20),

            SizedBox(
              width: double.infinity,
              height: 50,
              child: FilledButton(
                onPressed: running || selectedFolder == null ? null : runCarga,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (running)
                      Padding(
                        padding: EdgeInsets.only(right: 12),
                        child: ProgressRing(strokeWidth: 2),
                      ),
                    Text(
                      running ? 'PROCESANDO ARCHIVOS...' : 'INICIAR CARGA MASIVA',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),

            if (running)
              Padding(
                padding: EdgeInsets.only(top: 10),

                child: ProgressBar(),
              ),

            SizedBox(height: 20),

            Expanded(
              child: GlassCard(
                color: Colors.black,

                opacity: 0.8,

                child: Container(
                  width: double.infinity,

                  padding: EdgeInsets.all(16),

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
  HomologationTasksGlassPage({Key? key}) : super(key: key);

  @override
  State<HomologationTasksGlassPage> createState() =>
      _HomologationTasksGlassPageState();
}

class _HomologationTasksGlassPageState
    extends State<HomologationTasksGlassPage> {
  final DatabaseHelper db = DatabaseHelper();

  List<Map<String, dynamic>> tasks = [];

  bool loading = true;
  bool processing = false;

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
      if (mounted) {
        setState(() => loading = false);
        _showErrorDialog("Error al cargar tareas", e.toString());
      }
    }
  }

  void _showErrorDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (c) => ContentDialog(
        title: Text(title, style: TextStyle(color: Colors.red)),
        content: Text("No se pudo completar la acción.\nCausa: $message"),
        actions: [
          Button(child: Text('Entendido'), onPressed: () => Navigator.pop(c)),
        ],
      ),
    );
  }

  void _showSuccess(String msg) {
    displayInfoBar(
      context,
      builder: (context, close) => InfoBar(
        title: Text('✅ Operación Exitosa'),
        content: Text(msg),
        severity: InfoBarSeverity.success,
      ),
    );
  }

  void _showHelp(BuildContext context) {
    showDialog(
      context: context,
      builder: (c) => ContentDialog(
        title: Text('📘 Ayuda: Corrección de Excel'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('¿Qué hago en esta pantalla?', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('Limpie las descripciones de los archivos de Excel detectados con errores.'),
            SizedBox(height: 10),
            Text('¿Qué significan los colores?', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('• Naranja: Nombre detectado en el archivo XLS.'),
            Text('• Azul (v12.1 IA): Sugerencia automática del estándar más cercano.'),
            SizedBox(height: 10),
            Text('¿Qué paso sigue?', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('Corrija todos los errores para que aparezcan limpios en el Árbitro de Conflictos.'),
          ],
        ),
        actions: [
          Button(child: Text('Entendido'), onPressed: () => Navigator.pop(c)),
        ],
      ),
    );
  }

  void _showExcelCorrectionDialog(BuildContext context, Map<String, dynamic> item, String? suggestion) {
    final controller = TextEditingController(text: suggestion ?? item['desc_excel'] ?? '');
    
    showDialog(
      context: context,
      builder: (context) => ContentDialog(
        title: Text('📝 Corregir Entrada de Excel'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Ajuste la descripción para el reporte técnico de correcciones:'),
            SizedBox(height: 16),
            TextBox(
              controller: controller,
              placeholder: 'Descripción corregida',
              maxLines: 3,
            ),
            SizedBox(height: 12),
            Text(
              "Original: ${item['desc_excel']}",
              style: TextStyle(
                fontSize: 11,
                color: FluentTheme.of(context).typography.caption?.color?.withOpacity(0.6),
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
        actions: [
          Button(
            child: Text('Cancelar'),
            onPressed: () => Navigator.pop(context),
          ),
          FilledButton(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (processing)
                  Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: ProgressRing(strokeWidth: 2),
                  ),
                Text('Guardar Corrección'),
              ],
            ),
            onPressed: processing ? null : () async {
              setState(() => processing = true);
              try {
                // v13.1: Write directly to Excel if path is known
                final filename = item['archivo']?.toString() ?? '';
                final sheet = item['hoja']?.toString() ?? '';
                final row = int.tryParse(item['fila']?.toString() ?? '0') ?? 0;
                
                // If we have file info, try writing to Excel first
                if (filename.isNotEmpty && sheet.isNotEmpty && row > 0) {
                   final res = await db.writeExcel(item['id'], controller.text, filename, sheet, row);
                   if (res['status'] != 'success') throw Exception(res['message']);
                   _showSuccess("Excel y Base de Datos actualizados correctamente.");
                } else {
                   // Fallback for logic-only correction (should not happen in v13.1)
                   final res = await db.saveExcelCorrection(item['id'], controller.text);
                   if (res['status'] != 'success') throw Exception(res['message']);
                   _showSuccess("Descripción corregida (Solo SQL).");
                }
                
                if (mounted) {
                  await load(); // Reload to reflect changes
                  Navigator.pop(context);
                }
              } catch (e) {
                // Determine if it's a path error to show accurate help
                final msg = e.toString();
                if (msg.contains("Ruta no encontrada")) {
                    _showErrorDialog("Archivo No Localizado", "Vaya a la pestaña 'Fuentes de Datos' y localice el archivo:\n${item['archivo']}");
                } else {
                    _showErrorDialog("Error al guardar", msg);
                }
              } finally {
                if (mounted) setState(() => processing = false);
              }
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: PageHeader(
        title: Text('📝 Corrección de Excel (Limpieza)'),
        commandBar: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Button(
              onPressed: loading ? null : load,
              child: Row(
                children: [
                   Icon(FluentIcons.refresh),
                   SizedBox(width: 8),
                   Text('Recargar'),
                ],
              ),
            ),
            SizedBox(width: 8),
            IconButton(
              icon: Icon(FluentIcons.help, size: 20),
              onPressed: () => _showHelp(context),
            ),
          ],
        ),
      ),

      content: Padding(
        padding: EdgeInsets.symmetric(horizontal: 24),

        child:
            loading
                ? Center(child: ProgressRing())
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

                      SizedBox(height: 16),

                      Text(
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
                      padding: EdgeInsets.only(bottom: 24),

                      itemCount: keys.length,

                      itemBuilder: (context, index) {
                        final code = keys[index];

                        final items = grouped[code]!;

                        // Use the First item to get Official Description (assumed same for all with same code)

                        final officialDesc =
                            items.first['descripcion'] ?? // Updated key
                            'Sin Descripción en BD';

                        return Padding(
                          padding: EdgeInsets.only(bottom: 16),
                          child: Card(
                            padding: EdgeInsets.all(12),
                            borderRadius: BorderRadius.circular(12),
                            child: Expander(
                              header: Row(
                                children: [
                                  Container(
                                    padding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                    decoration: BoxDecoration(
                                      color: Colors.orange,
                                      borderRadius: BorderRadius.circular(6),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.orange.withOpacity(0.3),
                                          blurRadius: 4,
                                          offset: Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                    child: Text(
                                      code,
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                  SizedBox(width: 16),
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
                                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: Colors.red.withOpacity(0.9),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Text(
                                      "${items.length} errores",
                                      style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ],
                              ),
                              initiallyExpanded: true,
                              content: Column(
                                children: items.map((item) {
                                  final String dirtyText = item['desc_excel'] ?? '';
                                  return Container(
                                    margin: EdgeInsets.only(bottom: 8),
                                    padding: EdgeInsets.all(12),
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
                                          padding: EdgeInsets.all(8),
                                          decoration: BoxDecoration(
                                            color: Colors.green.withOpacity(0.1),
                                            shape: BoxShape.circle,
                                          ),
                                          child: Icon(FluentIcons.excel_document, size: 16, color: Colors.green),
                                        ),
                                        SizedBox(width: 14),
                                        // Info
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                item['archivo'] ?? 'Desconocido',
                                                style: FluentTheme.of(context).typography.bodyStrong,
                                              ),
                                              SizedBox(height: 2),
                                              Text(
                                                "Fila: ${item['fila']} • Hoja: ${item['hoja']}",
                                                style: FluentTheme.of(context).typography.caption,
                                              ),
                                              SizedBox(height: 6),
                                              Text(
                                                "Excel: $dirtyText",
                                                style: TextStyle(
                                                  color: Colors.orange,
                                                  fontFamily: 'Consolas',
                                                  fontSize: 12,
                                                ),
                                              ),
                                              
                                              // --- v12.1 SMART HOMOLOGATOR AREA ---
                                              FutureBuilder<Map<String, dynamic>?>(
                                                future: db.getSuggestion(dirtyText),
                                                builder: (context, snapshot) {
                                                  if (!snapshot.hasData || snapshot.data == null) return SizedBox.shrink();
                                                  final suggestion = snapshot.data!['suggestion'];
                                                  final ratio = snapshot.data!['ratio'];
                                                  
                                                  return Padding(
                                                    padding: EdgeInsets.only(top: 10),
                                                    child: Column(
                                                      crossAxisAlignment: CrossAxisAlignment.start,
                                                      children: [
                                                        Row(
                                                          children: [
                                                            Icon(FluentIcons.robot, size: 12, color: Color(0xFF4CC2FF)),
                                                            SizedBox(width: 6),
                                                            Text(
                                                              "INTELIGENCIA ARTIFICIAL (${(ratio * 100).toInt()}%)",
                                                              style: TextStyle(
                                                                fontSize: 10,
                                                                fontWeight: FontWeight.bold,
                                                                color: FluentTheme.of(context).accentColor,
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                        SizedBox(height: 6),
                                                        Button(
                                                          onPressed: () => _showExcelCorrectionDialog(context, item, suggestion),
                                                          child: Text("✨ Sugerencia: $suggestion"),
                                                        ),
                                                      ],
                                                    ),
                                                  );
                                                },
                                              ),
                                            ],
                                          ),
                                        ),
                                        SizedBox(width: 12),
                                        // Action
                                        Button(
                                          child: Text("Corregir"),
                                          onPressed: () => _showExcelCorrectionDialog(context, item, null),
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
  ResolvedHistoryGlassPage({Key? key}) : super(key: key);
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

  void _showHelp(BuildContext context) {
    showDialog(
      context: context,
      builder: (c) => ContentDialog(
        title: Text('📘 Ayuda: Auditoría de Resoluciones'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('¿Qué hago en esta pantalla?', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('Consulte el registro histórico de todas las piezas que han sido homologadas y resueltas.'),
            SizedBox(height: 10),
            Text('¿Qué significan los registros?', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('Muestran el código, la descripción original del Excel y la descripción final que se guardó en el Maestro.'),
            SizedBox(height: 10),
            Text('¿Qué paso sigue?', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('Puede usar esta pantalla para verificar quién y cuándo autorizó un cambio específico.'),
          ],
        ),
        actions: [
          Button(child: Text('OK'), onPressed: () => Navigator.pop(c)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = FluentTheme.of(context).brightness == Brightness.dark;
    return ScaffoldPage(
      header: PageHeader(
        title: Text('📜 Auditoría de Resoluciones'),
        commandBar: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Button(
              child: Icon(FluentIcons.refresh),
              onPressed: load,
            ),
            SizedBox(width: 8),
            IconButton(
              icon: Icon(FluentIcons.help, size: 20),
              onPressed: () => _showHelp(context),
            ),
          ],
        ),
      ),
      content:
          loading
              ? Center(child: ProgressRing())
              : tasks.isEmpty
              ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text("No hay historial de resoluciones."),
                    SizedBox(height: 16),
                    Button(
                      child: Text("Forzar Recarga"),
                      onPressed: () => load(),
                    ),
                  ],
                ),
              )
              : ListView.builder(
                padding: EdgeInsets.only(bottom: 24, left: 24, right: 24),
                itemCount: tasks.length,
                itemBuilder: (context, index) {
                  final item = tasks[index];
                  final status = item['estado'] ?? '---';
                  Color statusColor =
                      status == 'CORREGIDO' ? Colors.green : Colors.orange;

                  return Padding(
                    padding: EdgeInsets.only(bottom: 8),
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

