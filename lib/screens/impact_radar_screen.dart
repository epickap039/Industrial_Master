import 'package:fluent_ui/fluent_ui.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../theme/app_themes.dart';

class ImpactRadarScreen extends StatefulWidget {
  const ImpactRadarScreen({super.key});

  @override
  State<ImpactRadarScreen> createState() => _ImpactRadarScreenState();
}

class _ImpactRadarScreenState extends State<ImpactRadarScreen> {
  final TextEditingController _searchController = TextEditingController();
  bool _isLoading = false;
  String _currentPiece = "";

  // Resultados agrupados: Map<Cliente, Map<Proyecto/Lista, List<Ensamble>>>
  Map<String, Map<String, List<dynamic>>> _groupedResults = {};
  
  // Tareas Globales
  bool _gPlano = false;
  bool _gPdfDxf = false;
  bool _gEdrawing = false;
  bool _gDrive = false;

  // Checklists Locales: Map<id_ensamble, Map<String, bool>>
  Map<int, Map<String, bool>> _localChecklists = {};

  Future<void> _escanearImpacto() async {
    final query = _searchController.text.trim().toUpperCase();
    if (query.isEmpty) return;

    setState(() {
      _isLoading = true;
      _currentPiece = query;
      _groupedResults = {};
      _localChecklists = {};
    });

    try {
      final response = await http.get(Uri.parse('http://192.168.1.73:8001/api/bom/where-used/$query'));
      
      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        
        // Agrupar datos
        final tempGrouped = <String, Map<String, List<dynamic>>>{};
        
        for (var item in data) {
          final cliente = item['cliente'] as String;
          final proyLista = "${item['tracto']} / ${item['proyecto']} / ${item['version']} (${item['lista_bom']})";
          
          if (!tempGrouped.containsKey(cliente)) {
            tempGrouped[cliente] = {};
          }
          if (!tempGrouped[cliente]!.containsKey(proyLista)) {
            tempGrouped[cliente]![proyLista] = [];
          }
          
          // Verificar si el ensamble ya existe en este proyLista (para no duplicar visualmente si hay algo raro)
          if (!tempGrouped[cliente]![proyLista]!.any((e) => e['id_ensamble'] == item['id_ensamble'])) {
             tempGrouped[cliente]![proyLista]!.add(item);
             
             // Inicializar checklist local si no existe
             final idEns = item['id_ensamble'];
             if (!_localChecklists.containsKey(idEns)) {
               _localChecklists[idEns] = {
                 'plano_ensamble': false,
                 'pdf_ensamble': false,
                 'plano_general': false,
                 'drive': false,
               };
             }
          }
        }
        
        setState(() {
          _groupedResults = tempGrouped;
        });

      } else {
        _showError("No se encontraron resultados o hubo un error en la búsqueda.");
      }
    } catch (e) {
      _showError("No se pudo conectar al servidor: $e");
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _limpiarPantalla() {
    setState(() {
      _searchController.clear();
      _currentPiece = "";
      _groupedResults = {};
      _localChecklists = {};
      _gPlano = false;
      _gPdfDxf = false;
      _gEdrawing = false;
      _gDrive = false;
    });
  }

  void _showError(String msg) {
    displayInfoBar(
      context,
      builder: (context, close) => InfoBar(
        title: const Text('Error'),
        content: Text(msg),
        severity: InfoBarSeverity.error,
        action: IconButton(icon: const Icon(FluentIcons.clear), onPressed: close),
      ),
    );
  }

  Widget _buildGlobalTasks() {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Tareas Globales de la Pieza', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 16),
          Checkbox(
            checked: _gPlano,
            onChanged: (v) => setState(() => _gPlano = v ?? false),
            content: const Text('Actualizar Plano de Pieza (.SLDDRW)'),
          ),
          const SizedBox(height: 8),
          Checkbox(
            checked: _gPdfDxf,
            onChanged: (v) => setState(() => _gPdfDxf = v ?? false),
            content: const Text('Exportar nuevo PDF/DXF'),
          ),
          const SizedBox(height: 8),
          Checkbox(
            checked: _gEdrawing,
            onChanged: (v) => setState(() => _gEdrawing = v ?? false),
            content: const Text('Exportar E-Drawing'),
          ),
          const SizedBox(height: 8),
          Checkbox(
            checked: _gDrive,
            onChanged: (v) => setState(() => _gDrive = v ?? false),
            content: const Text('Reemplazar archivo en Drive'),
          ),
        ],
      ),
    );
  }

  Widget _buildAssemblyCard(dynamic ensamble) {
    final int idEns = ensamble['id_ensamble'];
    final checks = _localChecklists[idEns]!;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: FluentTheme.of(context).cardColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: FluentTheme.of(context).resources.dividerStrokeColorDefault ?? Colors.grey[300]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                ensamble['nombre_ensamble'],
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: FluentTheme.of(context).accentColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text('Cant: ${ensamble['cantidad']}'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text('Checklist de Integración:'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              Checkbox(
                checked: checks['plano_ensamble'],
                onChanged: (v) => setState(() => _localChecklists[idEns]!['plano_ensamble'] = v ?? false),
                content: const Text('Plano de Ensamble'),
              ),
              Checkbox(
                checked: checks['pdf_ensamble'],
                onChanged: (v) => setState(() => _localChecklists[idEns]!['pdf_ensamble'] = v ?? false),
                content: const Text('PDF del Ensamble'),
              ),
              Checkbox(
                checked: checks['plano_general'],
                onChanged: (v) => setState(() => _localChecklists[idEns]!['plano_general'] = v ?? false),
                content: const Text('Plano General (si aplica)'),
              ),
              Checkbox(
                checked: checks['drive'],
                onChanged: (v) => setState(() => _localChecklists[idEns]!['drive'] = v ?? false),
                content: const Text('Subir a Drive'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildImpactTree() {
    if (_currentPiece.isEmpty && _groupedResults.isEmpty) {
      return const Center(
        child: Text("Ingresa un código de pieza para revelar su impacto estructural.", style: TextStyle(color: Colors.grey)),
      );
    }

    if (_groupedResults.isEmpty) {
       return const Center(child: Text("Pieza no encontrada en ninguna Lista de Materiales (Orphaneada o Error).", style: TextStyle(color: Colors.grey)));
    }

    List<Widget> clienteWidgets = [];
    _groupedResults.forEach((cliente, proyectosMap) {
      List<Widget> proyectoWidgets = [];
      proyectosMap.forEach((proyecto, ensambles) {
        proyectoWidgets.add(
          Padding(
            padding: const EdgeInsets.only(left: 16.0, top: 12.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(FluentIcons.fabric_folder, size: 16, color: Colors.blue),
                    const SizedBox(width: 8),
                    Text(proyecto, style: const TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(left: 24.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: ensambles.map((e) => _buildAssemblyCard(e)).toList(),
                  ),
                ),
              ],
            ),
          )
        );
      });

      clienteWidgets.add(
        Expander(
          initiallyExpanded: true,
          header: Row(
            children: [
              const Icon(FluentIcons.group, size: 18),
              const SizedBox(width: 8),
              Text(cliente, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ],
          ),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: proyectoWidgets,
          ),
        )
      );
      clienteWidgets.add(const SizedBox(height: 16));
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: clienteWidgets,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: PageHeader(
        title: const Text('Radar de Impacto (Where-Used)'),
        commandBar: CommandBar(
          mainAxisAlignment: MainAxisAlignment.end,
          primaryItems: [
            CommandBarButton(
              icon: const Icon(FluentIcons.clear),
              label: const Text('Limpiar Pantalla'),
              onPressed: _limpiarPantalla,
            ),
          ],
        ),
      ),
      content: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Panel Izquierdo
            SizedBox(
              width: 300,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  InfoLabel(
                    label: "Código de Pieza a Analizar",
                    child: TextBox(
                      controller: _searchController,
                      placeholder: "Ej: JA-002",
                      onSubmitted: (_) => _escanearImpacto(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _isLoading ? null : _escanearImpacto,
                    child: _isLoading 
                        ? const ProgressRing(strokeWidth: 2,) 
                        : const Text('Escanear Impacto'),
                  ),
                  const SizedBox(height: 24),
                  if (_currentPiece.isNotEmpty)
                    _buildGlobalTasks(),
                ],
              ),
            ),
            const SizedBox(width: 32),
            // Panel Derecho (Radar Tree)
            Expanded(
              child: _isLoading 
                ? const Center(child: ProgressRing())
                : SingleChildScrollView(child: _buildImpactTree()),
            ),
          ],
        ),
      ),
    );
  }
}
