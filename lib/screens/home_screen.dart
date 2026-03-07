import 'package:fluent_ui/fluent_ui.dart';

class HomeScreen extends StatefulWidget {
  final Function(int) onNavigate;
  final bool isAdmin;

  const HomeScreen({super.key, required this.onNavigate, this.isAdmin = false});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Widget _buildCard({
    required String title,
    required String description,
    required IconData icon,
    required int navIndex,
    required BuildContext context,
  }) {
    final theme = FluentTheme.of(context);

    return HoverButton(
      onPressed: () {
        widget.onNavigate(navIndex);
      },
      builder: (context, states) {
        final isHovered = states.isHovered;
        final isPressed = states.isPressing;

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
                      color: isHovered ? theme.accentColor : theme.typography.body?.color),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
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

                Widget buildSection(String title, List<Widget> cards) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16.0, horizontal: 8.0),
                        child: Text(
                          title,
                          style: FluentTheme.of(context).typography.subtitle?.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ),
                      GridView.count(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        crossAxisCount: crossAxisCount,
                        mainAxisSpacing: 16,
                        crossAxisSpacing: 16,
                        childAspectRatio: 1.4,
                        children: cards,
                      ),
                      const SizedBox(height: 16),
                    ],
                  );
                }

                return Column(
                  children: [
                    buildSection(
                      "Zona de Consulta",
                      [
                        _buildCard(
                          context: context,
                          title: "1. Catálogo Maestro",
                          description: "La fuente única de la verdad. Visualiza y gestiona el inventario validado. Incluye el motor de búsqueda DXF en red y exportación de metadatos 3D.",
                          icon: FluentIcons.database,
                          navIndex: 2, 
                        ),
                        _buildCard(
                          context: context,
                          title: "2. Materiales Oficiales",
                          description: "Diccionario de materia prima. Administra los calibres, perfiles y aceros base autorizados para la fabricación, previniendo el inventario fantasma.",
                          icon: FluentIcons.set_action,
                          navIndex: 3, 
                        ),
                        _buildCard(
                          context: context,
                          title: "3. Mapa de Ingeniería (BOM)",
                          description: "Explorador visual PLM. Navega por el lienzo interactivo para entender el impacto y la jerarquía de las Listas de Materiales por cliente o tracto.",
                          icon: FluentIcons.graph_symbol,
                          navIndex: 4, 
                        ),
                      ],
                    ),
                    buildSection(
                      "Procesamiento de Datos",
                      [
                        _buildCard(
                          context: context,
                          title: "4. Escáner CAD 3D/2D",
                          description: "Extracción geométrica masiva. Corre la macro en SolidWorks y el sistema leerá los Bounding Box (Largo, Ancho, Espesor) y detectará planos de corte de forma autónoma.",
                          icon: FluentIcons.cube_shape,
                          navIndex: 6, 
                        ),
                        _buildCard(
                          context: context,
                          title: "5. Importar Excel / Arbitraje",
                          description: "El guardián de inyección. Sube los reportes del Escáner CAD. El motor detectará colisiones de datos (Excel vs SQL Server) y te permitirá arbitrar la versión final.",
                          icon: FluentIcons.cloud,
                          navIndex: 7, 
                        ),
                        _buildCard(
                          context: context,
                          title: "6. Auditor de Archivos",
                          description: "Filtro de integridad previo. Analiza la salud de los archivos Excel antes de la importación profunda para asegurar que columnas y formatos cumplan la normativa.",
                          icon: FluentIcons.check_list,
                          navIndex: 8, 
                        ),
                        _buildCard(
                          context: context,
                          title: "7. Estandarización",
                          description: "Normalización de nomenclaturas. Limpia textos sucios y unifica nombres de aceros y procesos para que Compras y Producción hablen el mismo idioma.",
                          icon: FluentIcons.filter,
                          navIndex: 9, 
                        ),
                      ],
                    ),
                    buildSection(
                      "Trazabilidad y Control",
                      [
                        _buildCard(
                          context: context,
                          title: "8. Gestión de Proyectos",
                          description: "Configuración taxonómica. Define la columna vertebral del negocio configurando Tractos, Tipos de Proyecto, Versiones y Clientes oficiales.",
                          icon: FluentIcons.fabric_folder,
                          navIndex: 11, 
                        ),
                        _buildCard(
                          context: context,
                          title: "9. Expedientes VIN",
                          description: "Trazabilidad de Piso (Where-Used). Rastrea a qué número de serie (VIN) específico de ensamble se le aplicó cada revisión de ingeniería.",
                          icon: FluentIcons.car,
                          navIndex: 12, 
                        ),
                        _buildCard(
                          context: context,
                          title: "10. Centro de QA",
                          description: "Terminal de Calidad. Interfaz optimizada para inspección en piso de producción, permitiendo documentar validaciones y anomalías directamente al SQL.",
                          icon: FluentIcons.tablet,
                          navIndex: 13, 
                        ),
                        _buildCard(
                          context: context,
                          title: "11. Historial de Cambios",
                          description: "Trazabilidad ISO 9001. Registra cada inserción, modificación o borrado, sellando el usuario físico y la estampa de tiempo exacta de la alteración.",
                          icon: FluentIcons.history,
                          navIndex: 14, 
                        ),
                      ],
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
