import 'package:fluent_ui/fluent_ui.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'bom_manager.dart';

const String _API = "http://192.168.1.73:8001";

class EngineeringMapScreen extends StatefulWidget {
  const EngineeringMapScreen({super.key});

  @override
  State<EngineeringMapScreen> createState() => _EngineeringMapScreenState();
}

class _EngineeringMapScreenState extends State<EngineeringMapScreen> {
  List<dynamic> _arbol = [];
  bool _isLoading = true;
  String _filter = "";

  // v60.0: Color de acento por nombre de tracto
  Color _colorByTracto(String nombre) {
    final n = nombre.toUpperCase();
    if (n.contains('KENWORTH')) return const Color(0xFFD32F2F);
    if (n.contains('INTERNATIONAL')) return const Color(0xFFE65100);
    if (n.contains('PETERBILT')) return const Color(0xFF1565C0);
    return const Color(0xFF455A64); // Gris azul por defecto
  }

  @override
  void initState() {
    super.initState();
    _fetchArbol();
  }

  Future<void> _fetchArbol() async {
    setState(() => _isLoading = true);
    try {
      final res = await http.get(Uri.parse('$_API/api/mapa/jerarquia'));
      if (res.statusCode == 200) {
        setState(() => _arbol = json.decode(res.body));
      }
    } catch (e) {
      if (mounted) {
        displayInfoBar(context, builder: (ctx, close) => InfoBar(
          title: const Text('Error'),
          content: Text('No se pudo cargar el mapa: $e'),
          severity: InfoBarSeverity.error,
          onClose: close,
        ));
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  List<TreeViewItem> _buildTree() {
    final filterLow = _filter.toLowerCase();
    return _arbol.map<TreeViewItem>((tracto) {
      final tractoNombre = tracto['nombre'] as String;
      final color = _colorByTracto(tractoNombre);

      // Filtrar tipos/versiones por el texto de búsqueda
      final tipos = (tracto['tipos'] as List).where((tp) {
        if (filterLow.isEmpty) return true;
        final tpNombre = (tp['nombre'] as String).toLowerCase();
        if (tpNombre.contains(filterLow)) return true;
        return (tp['versiones'] as List).any((v) =>
          (v['nombre'] as String).toLowerCase().contains(filterLow));
      }).toList();

      return TreeViewItem(
        leading: Container(
          width: 12, height: 12,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        content: Text(
          tractoNombre,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 15,
            color: color,
          ),
        ),
        children: tipos.map<TreeViewItem>((tipo) {
          return TreeViewItem(
            leading: Icon(FluentIcons.build_definition, size: 14, color: color.withOpacity(0.7)),
            content: Text(tipo['nombre'], style: const TextStyle(fontWeight: FontWeight.w600)),
            children: (tipo['versiones'] as List).map<TreeViewItem>((ver) {
              final revisiones = ver['revisiones'] as List;
              return TreeViewItem(
                leading: Icon(FluentIcons.fabric_open_folder_horizontal, size: 13, color: Colors.grey[100]),
                content: Text(ver['nombre'], style: const TextStyle(fontStyle: FontStyle.italic)),
                children: revisiones.isEmpty
                  ? [TreeViewItem(content: const Text('Sin revisiones', style: TextStyle(color: Colors.grey)))]
                  : revisiones.map<TreeViewItem>((rev) {
                      final bool aprobada = rev['estado'] == 'Aprobada';
                      return TreeViewItem(
                        content: Row(
                          children: [
                            // Semáforo de estado
                            Tooltip(
                              message: rev['estado'],
                              child: Container(
                                width: 10, height: 10,
                                margin: const EdgeInsets.only(right: 6),
                                decoration: BoxDecoration(
                                  color: aprobada ? const Color(0xFF2E7D32) : const Color(0xFFF9A825),
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                "Rev ${rev['numero_revision']}  •  ${rev['estado']}",
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                            // Botón abrir BOM
                            Tooltip(
                              message: "Abrir Gestor de BOM para esta revisión",
                              child: IconButton(
                                icon: Icon(FluentIcons.open_in_new_window, size: 14, color: color),
                                onPressed: () => Navigator.push(
                                  context,
                                  FluentPageRoute(builder: (_) => BOMManagerScreen(
                                    idVersion: ver['id'] as int,
                                    versionName: ver['nombre'] as String,
                                    tractoName: tractoNombre,
                                  )),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
              );
            }).toList(),
          );
        }).toList(),
      );
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: PageHeader(
        title: const Text('Mapa de Ingeniería'),
        commandBar: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 220,
              child: TextBox(
                placeholder: 'Buscar tipo o versión...',
                prefix: const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(FluentIcons.search, size: 14),
                ),
                onChanged: (v) => setState(() => _filter = v),
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: "Recargar árbol de ingeniería",
              child: IconButton(
                icon: const Icon(FluentIcons.refresh),
                onPressed: _fetchArbol,
              ),
            ),
          ],
        ),
      ),
      content: _isLoading
          ? const Center(child: ProgressRing())
          : _arbol.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(FluentIcons.map_layers, size: 48, color: Colors.grey[100]),
                      const SizedBox(height: 12),
                      const Text('No se encontraron datos de ingeniería.',
                          style: TextStyle(color: Colors.grey)),
                    ],
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.all(16),
                  child: TreeView(
                    items: _buildTree(),
                    selectionMode: TreeViewSelectionMode.single,
                    onItemInvoked: (item, reason) async {},
                  ),
                ),
    );
  }
}
