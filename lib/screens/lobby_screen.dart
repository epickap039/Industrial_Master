import 'package:fluent_ui/fluent_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../config/app_config.dart';

class LobbyScreen extends StatefulWidget {
  final Function(int) onNavigate;
  final bool isAdmin;

  // REGLA ANTI-CONST: Evitamos marcar como const el constructor para mayor seguridad en este entorno
  LobbyScreen({
    Key? key,
    required this.onNavigate,
    this.isAdmin = false,
  }) : super(key: key);

  @override
  State<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends State<LobbyScreen> {
  String _userName = 'Cargando...';
  String _userRole = '';
  
  // Variables de Estado para KPIs
  int totalPiezas = 0;
  int totalUnidades = 0;
  int totalVersiones = 0;
  double saludCad = 0.0;
  int mermaConsolidada = 0;
  bool isLoadingKPI = true;
  String? kpiError;

  @override
  void initState() {
    super.initState();
    _loadUser();
    _fetchKPIs();
  }

  Future<void> _loadUser() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _userName = prefs.getString('username') ?? 'Usuario';
        _userRole = prefs.getString('rol') ?? 'USER';
      });
    }
  }

  Future<void> _fetchKPIs() async {
    try {
      final response = await http.get(
        Uri.parse('$kApiBaseUrl/api/dashboard/kpi'),
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (mounted) {
          setState(() {
            totalPiezas    = (data['total_piezas']    ?? 0).toInt();
            totalUnidades  = (data['total_unidades']  ?? 0).toInt();
            totalVersiones = (data['total_versiones'] ?? 0).toInt();
            saludCad       = (data['salud_cad']       ?? 0.0).toDouble();
            mermaConsolidada = (data['merma_configurada'] ?? 15).toInt();
            isLoadingKPI = false;
          });
        }
      }
    } catch (e) {
      debugPrint("Error fetching KPIs: $e");
      if (mounted) {
        setState(() {
          isLoadingKPI = false;
          kpiError = "Sin conexión con el servidor.\nVerifica que el backend esté activo en $kApiBaseUrl";
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    // Color de fondo para las tarjetas según el modo
    final cardBgColor = isDark ? Color(0xFF1E1E1E) : theme.cardColor;

    return ScaffoldPage(
      header: PageHeader(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Bienvenido, $_userName',
              style: TextStyle(fontSize: 32, fontWeight: FontWeight.w800),
            ),
            SizedBox(height: 4),
            Text(
              'Panel de Control Jaes | Rol: $_userRole',
              style: TextStyle(
                fontSize: 14,
                color: theme.typography.caption?.color?.withOpacity(0.6),
              ),
            ),
          ],
        ),
      ),
      content: SingleChildScrollView(
        padding: EdgeInsets.all(32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // --- SECCIÓN SUPERIOR: TARJETAS KPI ---
            Text(
              'Accesos Rápidos e Indicadores',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 24),
            
            if (kpiError != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
                child: InfoBar(
                  title: const Text('Backend no disponible'),
                  content: Text(kpiError!),
                  severity: InfoBarSeverity.warning,
                  onClose: () => setState(() => kpiError = null),
                ),
              ),

            if (isLoadingKPI)
              Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Column(
                    children: [
                      ProgressRing(),
                      SizedBox(height: 16),
                      Text('Sincronizando métricas en tiempo real...',
                        style: TextStyle(color: theme.typography.caption?.color)),
                    ],
                  ),
                ),
              )
            else
              // Usamos Wrap para que sea responsivo si la ventana se encoge
              Wrap(
                spacing: 24,
                runSpacing: 24,
                children: [
                  _buildKPICard(
                    title: 'Catálogo Maestro',
                    value: totalPiezas.toString(),
                    subtitle: 'Piezas Registradas',
                    icon: FluentIcons.database,
                    onTap: () => widget.onNavigate(2),
                  ),
                  _buildKPICard(
                    title: 'Motor MRP',
                    value: '$mermaConsolidada%',
                    subtitle: 'Merma Configurada',
                    icon: FluentIcons.shopping_cart,
                    onTap: () => widget.onNavigate(12),
                  ),
                  _buildKPICard(
                    title: 'Salud CAD',
                    value: '${saludCad.toStringAsFixed(1)}%',
                    subtitle: 'Piezas Listas',
                    icon: FluentIcons.line_chart,
                    onTap: () => widget.onNavigate(15),
                  ),
                  _buildKPICard(
                    title: 'Versiones de Ing.',
                    value: totalVersiones.toString(),
                    subtitle: 'Listas Únicas',
                    icon: FluentIcons.fabric_folder,
                    onTap: () => widget.onNavigate(13),
                  ),
                  _buildKPICard(
                    title: 'VINs Producidos',
                    value: totalUnidades.toString(),
                    subtitle: 'Unidades Físicas',
                    icon: FluentIcons.car,
                    onTap: () => widget.onNavigate(14),
                  ),
                ],
              ),

            SizedBox(height: 48),
            Divider(),
            SizedBox(height: 32),

            // --- SECCIÓN INFERIOR: CUADRÍCULA DE MÓDULOS ---
            Text(
              'Ecosistema de Módulos Secundarios',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 24),

            GridView.builder(
              shrinkWrap: true,
              physics: NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3, // 3 columnas fijas por fila
                crossAxisSpacing: 20,
                mainAxisSpacing: 20,
                childAspectRatio: 2.8, // Relación de aspecto para que sean rectangulares
              ),
              itemCount: 6,
              itemBuilder: (context, index) {
                final modules = [
                  {
                    'icon': FluentIcons.cube_shape,
                    'title': 'Escáner CAD',
                    'desc': 'Extracción automática de metadatos.',
                    'nav': 7
                  },
                  {
                    'icon': FluentIcons.excel_logo,
                    'title': 'Importar Excel',
                    'desc': 'Carga masiva de listas BOM.',
                    'nav': 8
                  },
                  {
                    'icon': FluentIcons.check_list,
                    'title': 'Auditor',
                    'desc': 'Radar de integridad de archivos.',
                    'nav': 9
                  },
                  {
                    'icon': FluentIcons.fabric_folder,
                    'title': 'Gestión de Proyectos',
                    'desc': 'Control de versiones y tractos.',
                    'nav': 13
                  },
                  {
                    'icon': FluentIcons.car,
                    'title': 'Expedientes VIN',
                    'desc': 'Trazabilidad de manufactura.',
                    'nav': 14
                  },
                  {
                    'icon': FluentIcons.tablet,
                    'title': 'Centro de QA',
                    'desc': 'Gestión de calidad y no conformes.',
                    'nav': 16
                  },
                ];

                final mod = modules[index];
                return _buildModuleItem(
                  icon: mod['icon'] as IconData,
                  title: mod['title'] as String,
                  description: mod['desc'] as String,
                  onTap: () => widget.onNavigate(mod['nav'] as int),
                );
              },
            ),
            
            // Espacio extra al final para scroll suave
            SizedBox(height: 50),
          ],
        ),
      ),
    );
  }

  // Helper para construir las tarjetas de KPI
  Widget _buildKPICard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    final theme = FluentTheme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardColor = isDark ? Color(0xFF1E1E1E) : theme.cardColor;

    return HoverButton(
      onPressed: onTap,
      builder: (context, states) {
        final isHovered = states.isHovered;
        return AnimatedContainer(
          duration: Duration(milliseconds: 200),
          width: 300,
          padding: EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: isHovered ? theme.accentColor.withOpacity(0.12) : cardColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isHovered ? theme.accentColor : theme.resources.dividerStrokeColorDefault!,
              width: isHovered ? 2 : 1,
            ),
            boxShadow: isHovered ? [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 10,
                offset: Offset(0, 4),
              )
            ] : [],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: theme.typography.caption?.color,
                    ),
                  ),
                  Icon(icon, color: theme.accentColor, size: 24),
                ],
              ),
              SizedBox(height: 16),
              Text(
                value,
                style: TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.bold,
                  color: isHovered ? theme.accentColor : theme.typography.titleLarge?.color,
                ),
              ),
              SizedBox(height: 6),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 13,
                  color: theme.typography.caption?.color?.withOpacity(0.7),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // Helper para construir los ítems de la cuadrícula de módulos
  Widget _buildModuleItem({
    required IconData icon,
    required String title,
    required String description,
    required VoidCallback onTap,
  }) {
    final theme = FluentTheme.of(context);
    
    return HoverButton(
      onPressed: onTap,
      builder: (context, states) {
        final isHovered = states.isHovered;
        return AnimatedContainer(
          duration: Duration(milliseconds: 150),
          padding: EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isHovered ? theme.accentColor.withOpacity(0.08) : theme.cardColor.withOpacity(0.4),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isHovered ? theme.accentColor.withOpacity(0.6) : theme.resources.dividerStrokeColorDefault!,
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon, 
                size: 32, 
                color: isHovered ? theme.accentColor : theme.typography.body?.color?.withOpacity(0.6),
              ),
              SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: theme.typography.body?.color,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      description,
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.typography.caption?.color?.withOpacity(0.7),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
