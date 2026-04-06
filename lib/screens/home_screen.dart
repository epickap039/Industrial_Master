import 'package:fluent_ui/fluent_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../widgets/compact_page_header.dart';

class HomeScreen extends StatefulWidget {
  final Function(int) onNavigate;
  final bool isAdmin;

  const HomeScreen({super.key, required this.onNavigate, this.isAdmin = false});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _userName = 'Cargando...';
  String _userRole = '';

  @override
  void initState() {
    super.initState();
    _loadUser();
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

  Widget _buildQuickCard({
    required String title,
    required String description,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return HoverButton(
      onPressed: onTap,
      builder: (context, states) {
        final theme = FluentTheme.of(context);
        final isHovered = states.isHovered;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: isHovered ? theme.accentColor.withOpacity(0.1) : theme.cardColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isHovered ? theme.accentColor : theme.resources.dividerStrokeColorDefault!,
              width: isHovered ? 2 : 1,
            ),
          ),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 48, color: isHovered ? theme.accentColor : color),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                description,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: theme.typography.body?.color?.withOpacity(0.7),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);

    return ScaffoldPage(
      padding: const EdgeInsets.only(top: 8),
      header: CompactPageHeader(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Hola, $_userName',
              style: theme.typography.title?.copyWith(
                fontSize: 32,
                fontWeight: FontWeight.w800,
                color: theme.typography.title?.color,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Rol: $_userRole | Bienvenido al Centro de Mando Jaes',
              style: TextStyle(
                fontSize: 14,
                color: theme.typography.caption?.color,
              ),
            ),
          ],
        ),
      ),
      content: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Accesos Directos Prioritarios',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 24),
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 3,
              mainAxisSpacing: 24,
              crossAxisSpacing: 24,
              childAspectRatio: 1.2,
              children: [
                _buildQuickCard(
                  title: 'Catálogo Maestro',
                  description: 'Gestión centralizada de materia prima y CAD.',
                  icon: FluentIcons.database,
                  color: Colors.blue,
                  onTap: () => widget.onNavigate(1), // Catálogo Maestro
                ),
                _buildQuickCard(
                  title: 'Motor MRP',
                  description: 'Cálculo de compras y requerimientos.',
                  icon: FluentIcons.shopping_cart,
                  color: Colors.green,
                  onTap: () => widget.onNavigate(15), // MRP (índice panel principal)
                ),
                _buildQuickCard(
                  title: 'Dashboard Analytics',
                  description: 'Métricas e inteligencia de negocio.',
                  icon: FluentIcons.pie_single,
                  color: Colors.orange,
                  onTap: () => widget.onNavigate(12), // Analytics
                ),
              ],
            ),
            const Divider(),
            const SizedBox(height: 32),
            const Text(
              'Guía de Módulos Adicionales',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Column(
              children: [
                _buildModuleInfo(
                  icon: FluentIcons.cube_shape,
                  title: 'Escáner CAD 3D/2D',
                  description: 'Motor de extracción automática. Analiza archivos nativos de SolidWorks para extraer metadatos, dimensiones y pesos exactos.',
                ),
                _buildModuleInfo(
                  icon: FluentIcons.excel_logo,
                  title: 'Importar Excel',
                  description: 'Módulo de carga masiva. Permite subir listas de materiales (BOM) estructuradas por Ingeniería para poblar la base de datos.',
                ),
                _buildModuleInfo(
                  icon: FluentIcons.check_list,
                  title: 'Auditor de Archivos',
                  description: 'Radar de calidad. Rastrea el servidor local para asegurar que cada pieza registrada cuente con su plano DXF o PDF correspondiente.',
                ),
                _buildModuleInfo(
                  icon: FluentIcons.fabric_folder,
                  title: 'Gestión de Proyectos',
                  description: 'Centro de control de revisiones. Aquí puedes crear, clonar o bloquear las versiones de los tractos (Ej. Cascadia 01) antes de enviarlos a piso.',
                ),
                _buildModuleInfo(
                  icon: FluentIcons.car,
                  title: 'Expedientes VIN',
                  description: 'Control de piso de producción. Monitorea en tiempo real en qué estación de ensamblaje o manufactura se encuentra cada tracto.',
                ),
                _buildModuleInfo(
                  icon: FluentIcons.tablet,
                  title: 'Centro de QA',
                  description: 'Gestión de calidad. Sistema de tickets para reportar piezas no conformes, errores de corte láser o problemas de doblez.',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModuleInfo({required IconData icon, required String title, required String description}) {
    final theme = FluentTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        children: [
          Icon(icon, size: 20, color: theme.accentColor.withOpacity(0.8)),
          const SizedBox(width: 16),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: theme.typography.body,
                children: [
                  TextSpan(text: '$title: ', style: const TextStyle(fontWeight: FontWeight.bold)),
                  TextSpan(
                    text: description,
                    style: TextStyle(
                      color: theme.typography.caption?.color?.withOpacity(0.7),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

