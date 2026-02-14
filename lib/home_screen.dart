import 'package:fluent_ui/fluent_ui.dart';

class HomeGlassPage extends StatelessWidget {
  final Function(int) onNavigate;

  const HomeGlassPage({Key? key, required this.onNavigate}) : super(key: key);

  @override
  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: const PageHeader(
        title: Text('Panel de Control Principal'),
      ),
      content: LayoutBuilder(
        builder: (context, constraints) {
          // Diseño Líquido: Se adapta al ancho disponible
          return Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 20.0),
              child: SizedBox(
                height: 200, // Altura fija para el contenedor de cards
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: _buildFlowCard(
                        context,
                        index: 6,
                        icon: FluentIcons.folder_open,
                        title: '1. Fuentes',
                        subtitle: 'Carga de Archivos',
                      ),
                    ),
                    _buildConnector(),
                    Expanded(
                      child: _buildFlowCard(
                        context,
                        index: 1,
                        icon: FluentIcons.edit,
                        title: '2. Corrección',
                        subtitle: 'Limpieza de Datos',
                      ),
                    ),
                    _buildConnector(),
                    Expanded(
                      child: _buildFlowCard(
                        context,
                        index: 2,
                        icon: FluentIcons.warning,
                        title: '3. Validación',
                        subtitle: 'Control de Conflictos',
                      ),
                    ),
                    _buildConnector(),
                    Expanded(
                      child: _buildFlowCard(
                        context,
                        index: 3,
                        icon: FluentIcons.database,
                        title: '4. Catálogo',
                        subtitle: 'Maestro de Materiales',
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

  Widget _buildFlowCard(
    BuildContext context, {
    required int index,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return GestureDetector(
      onTap: () => onNavigate(index),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          // width: eliminado para ser líquido
          height: 150,
          margin: EdgeInsets.symmetric(horizontal: 4), // Margen mínimo entre cartas y conectores
          decoration: BoxDecoration(
            color: const Color(0xFF0078D4),
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 32, color: Colors.white),
                const SizedBox(height: 16),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    subtitle,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.7),
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildConnector() {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 16.0),
      child: Icon(
        FluentIcons.chevron_right_med,
        size: 30,
        color: Color(0xFFCCCCCC),
      ),
    );
  }
}
