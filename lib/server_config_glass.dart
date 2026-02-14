import 'package:fluent_ui/fluent_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'database_helper.dart';

class ServerConfigGlassPage extends StatefulWidget {
  ServerConfigGlassPage({Key? key}) : super(key: key);

  @override
  State<ServerConfigGlassPage> createState() => _ServerConfigGlassPageState();
}

class _ServerConfigGlassPageState extends State<ServerConfigGlassPage> {
  final db = DatabaseHelper();
  final serverController = TextEditingController();
  final dbController = TextEditingController();
  final userController = TextEditingController();
  final passController = TextEditingController();
  final blueprintsController = TextEditingController();
  final genericsController = TextEditingController();
  bool isWindowsAuth = false;
  
  // Separation of Concerns (Atomic States)
  bool _isSaving = false; 
  bool _isConnecting = false;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final cfg = await db.getConfig();
    setState(() {
      // Logic "Anti-Zombie"
      final savedServer = cfg['server']?.toString();
      if (savedServer != null && savedServer.isNotEmpty) {
         serverController.text = savedServer;
      } else {
         serverController.text = "192.168.1.73,1433"; // Default only if empty
      }

      final savedDb = cfg['database']?.toString();
      if (savedDb != null && savedDb.isNotEmpty) {
        dbController.text = savedDb;
      } else {
        dbController.text = "DB_Materiales_Industrial";
      }

      if (cfg['trusted_connection'] != null) {
        isWindowsAuth = cfg['trusted_connection'].toString().toLowerCase() == 'yes';
      }

      userController.text = cfg['username']?.toString() ?? "jaes_admin";
      passController.text = cfg['password']?.toString() ?? "Jaes2026*";
      
      blueprintsController.text = cfg['blueprints_path']?.toString() ?? "";
      genericsController.text = cfg['generics_path']?.toString() ?? r"Z:\5. PIEZAS GENERICAS\JA'S PDF";
    });
  }

  Future<void> pickBlueprintsFolder() async {
    String? result = await FilePicker.platform.getDirectoryPath();
    if (result != null) setState(() => blueprintsController.text = result);
  }

  Future<void> save() async {
    if (_isSaving) return; // Prevent double click
    setState(() => _isSaving = true);
    
    try {
      // 1. Captura INMEDIATA de valores visibles (Anti-Stale)
      final String currentServer = serverController.text.trim();
      final String currentDb = dbController.text.trim();
      final String currentUser = userController.text.trim();
      final String currentPass = passController.text; // No trim en password
      final String currentBlueprints = blueprintsController.text.trim();
      final String currentGenerics = genericsController.text.trim();

      // 2. Validación básica
      if (currentServer.isEmpty) {
         displayInfoBar(context, builder: (context, close) => InfoBar(
            title: Text('Error'),
            content: Text('El campo Servidor no puede estar vacío.'),
            severity: InfoBarSeverity.error,
         ));
         return;
      }

      // 3. Construcción del Payload sin lógica condicional extraña
      final config = {
        "server": currentServer,
        "database": currentDb,
        "driver": "ODBC Driver 18 for SQL Server", // Default robusto
        "trusted_connection": isWindowsAuth ? "yes" : "no",
        "username": currentUser,
        "password": currentPass,
        "blueprints_path": currentBlueprints,
        "generics_path": currentGenerics,
      };

      // 4. Guardado Directo
      await db.saveConfig(config);
      
      // Simular brevísimo delay para feedback visual
      await Future.delayed(Duration(milliseconds: 300));

      // 5. Feedback Visual
      if (mounted) {
        displayInfoBar(context, builder: (context, close) => InfoBar(
          title: Text('Éxito'),
          content: Text('✅ Configuración Guardada:\nServidor: $currentServer\nUsuario: $currentUser'),
          severity: InfoBarSeverity.success,
        ));
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> test() async {
    if (_isConnecting) return;
    await save(); // Primero guarda
    setState(() => _isConnecting = true);
    
    try {
      // Timeout extendido para redes lentas
      final res = await db.testConnection().timeout(Duration(seconds: 15), onTimeout: () {
          return {'status': 'error', 'message': 'Tiempo de espera agotado (15s). Verifique IP y Red.'};
      });
      
      if (mounted) {
        displayInfoBar(context, builder: (context, close) => InfoBar(
          title: Text(res['status'] == 'success' ? 'Conexión Exitosa' : 'Error de Servidor'),
          content: SelectableText(res['message'] ?? 'Sin respuesta'),
          severity: res['status'] == 'success' ? InfoBarSeverity.success : InfoBarSeverity.error,
          action: IconButton(icon: Icon(FluentIcons.clear), onPressed: close),
        ));
      }
    } catch (e) {
       if (mounted) displayInfoBar(context, builder: (c, close) => InfoBar(title: Text('Error'), content: Text(e.toString()), severity: InfoBarSeverity.error)); 
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  Future<void> diagnoseSystem() async {
    if (_isConnecting) return;
    setState(() => _isConnecting = true);
    try {
      final result = await db.runDiagnostics();
      if (mounted) {
        await showDialog(
          context: context,
          builder: (ctx) => ContentDialog(
            title: Text('Diagnóstico SENTINEL'),
            content: SelectableText(
              'Backend: ${result['backend'] == true ? '✅ OK' : '❌ FALTA'}\n'
              'Conexión BD: ${result['connection'] == true ? '✅ OK' : '❌ ERROR'}\n'
              'Mensaje: ${result['message']}\n'
              'Path: ${result['path'] ?? 'N/A'}'
            ),
            actions: [Button(child: Text('Cerrar'), onPressed: () => Navigator.pop(ctx))],
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  void _showHelp(BuildContext context) {
    showDialog(
      context: context,
      builder: (c) => ContentDialog(
        title: Text('📘 Ayuda: Configuración'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('¿Qué hago en esta pantalla?', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('Configure los parámetros de conexión al servidor SQL y las rutas de los planos.'),
            SizedBox(height: 10),
            Text('¿Qué significan los campos?', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('• Servidor: IP y puerto del servidor de base de datos.'),
            Text('• Diagnóstico SENTINEL: Herramienta para verificar si el sistema tiene acceso a sus componentes críticos.'),
            SizedBox(height: 10),
            Text('¿Qué paso sigue?', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('Asegúrese de que el botón de "Conectar" se ponga en verde antes de empezar a trabajar.'),
          ],
        ),
        actions: [
          Button(child: Text('Entendido'), onPressed: () => Navigator.pop(c)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: PageHeader(
        title: Text('⚙️ Configuración del Sistema'),
        commandBar: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: Icon(FluentIcons.help, size: 20),
              onPressed: () => _showHelp(context),
            ),
          ],
        ),
      ),
      content: SingleChildScrollView(
        padding: EdgeInsets.all(24),
        child: Center(
          child: Container(
            constraints: BoxConstraints(maxWidth: 600),
            child: Column(
              children: [
                SizedBox(height: 40),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: SizedBox(
                        height: 80,
                        child: FilledButton(
                          onPressed: _isConnecting ? null : test,
                          child: _isConnecting 
                            ? SizedBox(width: 20, height: 20, child: ProgressRing(activeColor: Colors.white))
                            : Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(FluentIcons.plug_connected, size: 24),
                                  SizedBox(width: 15),
                                  Text("Conectar a Base de Datos", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                                ],
                              ),
                        ),
                      ),
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: SizedBox(
                        height: 80,
                        child: Button(
                          onPressed: _isConnecting ? null : diagnoseSystem,
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
                SizedBox(height: 24),
                Expander(
                  header: Text("⚙️ Opciones Avanzadas (Técnico)", style: TextStyle(fontWeight: FontWeight.bold)),
                  content: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16.0),
                        child: FilledButton(
                          onPressed: (_isSaving || _isConnecting) 
                            ? null 
                            : () {
                                setState(() {
                                  serverController.text = "192.168.1.73,1433";
                                  userController.text = "jaes_01";
                                  passController.text = "Industrial.2026";
                                });
                              },
                          style: ButtonStyle(
                            backgroundColor: ButtonState.all(Colors.orange),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(FluentIcons.lightning_bolt, size: 16),
                              SizedBox(width: 8),
                              Text("⚡ Cargar Credenciales (jaes_01)", style: TextStyle(fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ),
                      InfoLabel(
                        label: 'Servidor (IP, Puerto)',
                        child: Row(
                          children: [
                            Expanded(child: TextBox(controller: serverController)),
                            SizedBox(width: 8),
                            Button(
                              onPressed: () => setState(() => serverController.text = r"localhost\SQLEXPRESS"),
                              child: Row(
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
                      SizedBox(height: 12),
                      InfoLabel(label: 'Base de Datos', child: TextBox(controller: dbController)),
                      SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(child: InfoLabel(label: 'Usuario SQL', child: TextBox(controller: userController))),
                          SizedBox(width: 12),
                          Expanded(child: InfoLabel(label: 'Password SQL', child: TextBox(controller: passController, obscureText: true))),
                        ],
                      ),
                      SizedBox(height: 20),
                      Divider(),
                      SizedBox(height: 10),
                      Text("Rutas de Archivos", style: TextStyle(fontWeight: FontWeight.bold)),
                      SizedBox(height: 12),
                      InfoLabel(
                        label: 'Carpeta de Planos PDF (Red)',
                        child: Row(
                          children: [
                            Expanded(child: TextBox(controller: blueprintsController)),
                            SizedBox(width: 8),
                            Button(onPressed: pickBlueprintsFolder, child: Icon(FluentIcons.folder_open)),
                          ],
                        ),
                      ),
                      SizedBox(height: 12),
                      InfoLabel(label: 'Carpeta de Genéricos', child: TextBox(controller: genericsController)),
                      SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: Button(
                          onPressed: _isSaving ? null : save, 
                          child: _isSaving 
                             ? SizedBox(height: 16, width: 16, child: ProgressRing())
                             : Text("Guardar Configuración Técnica"),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: 12),
                SizedBox(
                  height: 48,
                  width: double.infinity,
                  child: Button(
                    onPressed: _isConnecting ? null : runSentinel,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(FluentIcons.shield, color: Colors.blue),
                        SizedBox(width: 8),
                        Text("Ejecutar Sentinel Pro"),
                      ],
                    ),
                  ),
                ),
                SizedBox(height: 40),
                Opacity(
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
    setState(() => _isConnecting = true);
    try {
      final report = await db.runSentinelDiagnostics();
      if (!mounted) return;
      
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
            constraints: BoxConstraints(maxWidth: 700, maxHeight: 800),
            title: Text("🛡️ Diagnóstico SENTINEL PRO v10.5"),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildCheckItem("Conexión Base de Datos", dbStatus, false),
                _buildCheckItem("Integridad de Tablas/Columnas", integStatus, false),
                _buildCheckItem("Lógica de Negocio (Excel)", logicStatus, false),
                _buildCheckItem("Ruta de Planos", pathStatus, false),
                SizedBox(height: 20),
                Row(
                  children: [
                    Text("Log del Sistema:", style: TextStyle(fontWeight: FontWeight.bold)),
                    if (hasCriticalError)
                      Text(" (ERRORES DETECTADOS)", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                  ],
                ),
                SizedBox(height: 8),
                Expanded(
                  child: Container(
                    width: double.infinity,
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.05),
                      border: Border.all(color: hasCriticalError ? Colors.red.withOpacity(0.5) : Colors.grey.withOpacity(0.3)),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
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
                child: Text("Cerrar"),
                onPressed: () => Navigator.pop(context),
              ),
              FilledButton(
                child: Text("Copiar Log"),
                onPressed: () {
                   Navigator.pop(context);
                },
              ),
            ],
          );
        }
      );
    } catch (e) {
      if (mounted) displayInfoBar(context, builder: (c, close) => InfoBar(title: Text('Error'), content: Text(e.toString()), severity: InfoBarSeverity.error));
    } finally {
      if (mounted) setState(() => _isConnecting = false);
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
      padding: EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          SizedBox(width: 12),
          Text(label, style: TextStyle(fontSize: 16)),
          if (isWarning) ...[
            SizedBox(width: 8),
            Text("(Advertencia)", style: TextStyle(fontSize: 12, color: Colors.orange)),
          ]
        ],
      ),
    );
  }
}
