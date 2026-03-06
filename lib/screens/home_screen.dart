import 'package:fluent_ui/fluent_ui.dart';

class HomeScreen extends StatefulWidget {
  final Function(int) onNavigate;
  final bool isAdmin;

  const HomeScreen({super.key, required this.onNavigate, this.isAdmin = false});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _getRealIndex(int adminIndex) {
    if (widget.isAdmin) return adminIndex;
    if (adminIndex == 2) return -1; // CAD Scanner no disponible para non-admin
    if (adminIndex > 2) return adminIndex - 1;
    return adminIndex;
  }

  Widget _buildCard({
    required String title,
    required String description,
    required IconData icon,
    required int navIndex, // Asume índice de Admin
    required BuildContext context,
  }) {
    final theme = FluentTheme.of(context);
    
    // Si no es admin y apunta a CAD, podemos atenuarlo o cambiar color
    final bool isLocked = !widget.isAdmin && navIndex == 2;

    return HoverButton(
      onPressed: () {
        int realIndex = _getRealIndex(navIndex);
        if (realIndex != -1) {
          widget.onNavigate(realIndex);
        } else {
          displayInfoBar(
            context,
            builder: (context, close) {
              return InfoBar(
                title: const Text('Acceso Denegado'),
                content: const Text('Requiere privilegios de Administrador.'),
                severity: InfoBarSeverity.warning,
                action: IconButton(
                  icon: const Icon(FluentIcons.clear),
                  onPressed: close,
                ),
              );
            },
          );
        }
      },
      builder: (context, states) {
        final isHovered = states.isHovered && !isLocked;
        final isPressed = states.isPressing && !isLocked;

        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: isHovered
                ? theme.accentColor.withOpacity(0.1)
                : theme.cardColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isHovered
                  ? theme.accentColor.withOpacity(0.5)
                  : theme.resources.dividerStrokeColorDefault ??
                      const Color(0xFFE5E5E5),
              width: isHovered ? 1.5 : 1.0,
            ),
            boxShadow: isHovered && !isPressed
                ? [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    )
                  ]
                : [],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Icon(icon,
                      size: 40,
                      color:
                          isHovered ? theme.accentColor : (isLocked ? Colors.grey : theme.typography.body?.color)),
                  if (isLocked)
                    const Icon(FluentIcons.lock, size: 20, color: Colors.warningPrimaryColor),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                title,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: isLocked ? Colors.grey : null,
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Text(
                  description,
                  style: TextStyle(
                    fontSize: 14,
                    color: isLocked ? Colors.grey : theme.typography.body?.color?.withOpacity(0.8),
                  ),
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
    return ScaffoldPage(
      header: const PageHeader(
        title: Text(
          'Centro de Mando Industrial v15.5',
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
        ),
      ),
      content: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Bienvenido al nuevo entorno gamificado. Selecciona un ecosistema para comenzar.",
              style: TextStyle(fontSize: 16, fontStyle: FontStyle.italic),
            ),
            const SizedBox(height: 32),
            LayoutBuilder(
              builder: (context, constraints) {
                int crossAxisCount = 3;
                if (constraints.maxWidth < 600) {
                  crossAxisCount = 1;
                } else if (constraints.maxWidth < 1000) {
                  crossAxisCount = 2;
                } else if (constraints.maxWidth > 1400) {
                  crossAxisCount = 4;
                }

                return GridView.count(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount: crossAxisCount,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  childAspectRatio: 1.4,
                  children: [
                    _buildCard(
                      context: context,
                      title: "1. Catálogo Maestro",
                      description: "La fuente única de la verdad. Visualiza y gestiona el inventario validado. Incluye el motor de búsqueda DXF en red y exportación de metadatos 3D.",
                      icon: FluentIcons.database,
                      navIndex: 1, 
                    ),
                    _buildCard(
                      context: context,
                      title: "2. Escáner CAD 3D/2D",
                      description: "Extracción geométrica masiva. Corre la macro en SolidWorks y el sistema leerá los Bounding Box (Largo, Ancho, Espesor) y detectará planos de corte de forma autónoma.",
                      icon: FluentIcons.cube_shape,
                      navIndex: 2, 
                    ),
                    _buildCard(
                      context: context,
                      title: "3. Importar Excel / Arbitraje",
                      description: "El guardián de inyección. Sube los reportes del Escáner CAD. El motor detectará colisiones de datos (Excel vs SQL Server) y te permitirá arbitrar la versión final.",
                      icon: FluentIcons.cloud,
                      navIndex: 3,
                    ),
                    _buildCard(
                      context: context,
                      title: "4. Auditor de Archivos",
                      description: "Filtro de integridad previo. Analiza la salud de los archivos Excel antes de la importación profunda para asegurar que columnas y formatos cumplan la normativa.",
                      icon: FluentIcons.check_list,
                      navIndex: 4, 
                    ),
                    _buildCard(
                      context: context,
                      title: "5. Historial de Cambios",
                      description: "Trazabilidad ISO 9001. Registra cada inserción, modificación o borrado, sellando el usuario físico y la estampa de tiempo exacta de la alteración.",
                      icon: FluentIcons.history,
                      navIndex: 5,
                    ),
                    _buildCard(
                      context: context,
                      title: "6. Estandarización",
                      description: "Normalización de nomenclaturas. Limpia textos sucios y unifica nombres de aceros y procesos para que Compras y Producción hablen el mismo idioma.",
                      icon: FluentIcons.filter,
                      navIndex: 6,
                    ),
                    _buildCard(
                      context: context,
                      title: "7. Materiales Oficiales",
                      description: "Diccionario de materia prima. Administra los calibres, perfiles y aceros base autorizados para la fabricación, previniendo el inventario fantasma.",
                      icon: FluentIcons.set_action,
                      navIndex: 7,
                    ),
                    _buildCard(
                      context: context,
                      title: "8. Gestión de Proyectos",
                      description: "Configuración taxonómica. Define la columna vertebral del negocio configurando Tractos, Tipos de Proyecto, Versiones y Clientes oficiales.",
                      icon: FluentIcons.fabric_folder,
                      navIndex: 8,
                    ),
                    _buildCard(
                      context: context,
                      title: "9. Mapa de Ingeniería (BOM)",
                      description: "Explorador visual PLM. Navega por el lienzo interactivo para entender el impacto y la jerarquía de las Listas de Materiales por cliente o tracto.",
                      icon: FluentIcons.graph_symbol,
                      navIndex: 9, 
                    ),
                    _buildCard(
                      context: context,
                      title: "10. Expedientes VIN",
                      description: "Trazabilidad de Piso (Where-Used). Rastrea a qué número de serie (VIN) específico de ensamble se le aplicó cada revisión de ingeniería.",
                      icon: FluentIcons.car,
                      navIndex: 10, 
                    ),
                    _buildCard(
                      context: context,
                      title: "11. Centro de QA",
                      description: "Terminal de Calidad. Interfaz optimizada para inspección en piso de producción, permitiendo documentar validaciones y anomalías directamente al SQL.",
                      icon: FluentIcons.tablet,
                      navIndex: 11, 
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
