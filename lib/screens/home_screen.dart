import 'package:fluent_ui/fluent_ui.dart';

class HomeScreen extends StatefulWidget {
  final Function(int) onNavigate;

  const HomeScreen({super.key, required this.onNavigate});

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
      onPressed: () => widget.onNavigate(navIndex),
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
              Icon(icon,
                  size: 40,
                  color:
                      isHovered ? theme.accentColor : theme.typography.body?.color),
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
                    color: theme.typography.body?.color?.withOpacity(0.8),
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
                // Determine crossAxisCount based on screen width
                int crossAxisCount = 3;
                if (constraints.maxWidth < 600) {
                  crossAxisCount = 1;
                } else if (constraints.maxWidth < 1000) {
                  crossAxisCount = 2;
                }

                // Las Tarjetas de Inducción
                // Index 1: Catalogo
                // Index 2: Escáner (Si es Admin, depende de auth pero pasamos rutas relativas)
                // O enviaremos los índices correctos: Catálogo(1), Motor (2), Arbitraje(3), Mapa(8/9 dependiendo de admin), Buscador(4), Historial(5)
                
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
                      title: "Catálogo Maestro",
                      description:
                          "La fuente única de la verdad. Aquí viven las medidas validadas y los metadatos de toda nuestra ingeniería.",
                      icon: FluentIcons.database,
                      navIndex: 1, // Index 1 en el NavigationPane (si Home=0)
                    ),
                    _buildCard(
                      context: context,
                      title: "Motor CAD 3D/2D",
                      description:
                          "Extracción masiva. Corre la macro en SolidWorks y sube el Excel. El sistema cruzará la información y medirá cajas 3D automáticamente.",
                      icon: FluentIcons.cube_shape,
                      navIndex: 2, // Asumiendo que CAD Scanner es index 2
                    ),
                    _buildCard(
                      context: context,
                      title: "Arbitraje e Inyección",
                      description:
                          "El guardián de la base de datos. Detecta colisiones entre los Excels nuevos y el SQL Server para evitar duplicados.",
                      icon: FluentIcons.shield,
                      navIndex: 3,
                    ),
                    _buildCard(
                      context: context,
                      title: "Mapa de Ingeniería (BOM)",
                      description:
                          "Navega por el mapa interactivo de Tractos y Clientes para entender la estructura de nuestras Listas de Materiales.",
                      icon: FluentIcons.graph_symbol,
                      navIndex: 8, // Index tentativo para Mapa de Ingeniería
                    ),
                    _buildCard(
                      context: context,
                      title: "Buscador DXF Inteligente",
                      description:
                          "Encuentra al instante el archivo de corte de cualquier pieza en nuestro servidor de red.",
                      icon: FluentIcons.search_and_apps, // Auditor
                      navIndex: 4,
                    ),
                    _buildCard(
                      context: context,
                      title: "Trazabilidad ISO",
                      description:
                          "El Gran Ojo. Todo movimiento, borrado o modificación queda registrado para auditorías de calidad.",
                      icon: FluentIcons.history,
                      navIndex: 5,
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
