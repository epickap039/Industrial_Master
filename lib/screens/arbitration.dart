import 'dart:convert';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ArbitrationScreen extends StatefulWidget {
  final List<dynamic> conflicts;
  final int totalProcessed;

  const ArbitrationScreen({
    super.key,
    required this.conflicts,
    required this.totalProcessed,
  });

  @override
  State<ArbitrationScreen> createState() => _ArbitrationScreenState();
}

class _ArbitrationScreenState extends State<ArbitrationScreen> {
  // Lista local de conflictos para manejar su estado (si se aceptaron o rechazaron)
  List<Map<String, dynamic>> _pendingConflicts = [];
  
  // Set de índices marcados para sincronizar
  final Set<String> _acceptedUpdates = {}; 
  
  bool _isSyncing = false;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _pendingConflicts = List<Map<String, dynamic>>.from(widget.conflicts);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Ejecuta la sincronización enviando los aceptados al backend
  Future<void> _syncChanges() async {
    setState(() => _isSyncing = true);
    
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('username') ?? 'Admin_Arbitraje';

    try {
      // Filtrar solo los aceptados
      final updatesToSend = _pendingConflicts
          .where((c) => _acceptedUpdates.contains(c['Codigo_Pieza']))
          .map((c) => {
            ...c['Excel_Data'], // Datos del Excel
            'usuario': username // Auditoría
          })
          .toList();

      if (updatesToSend.isEmpty) {
        _showResultDialog("Sin Cambios", "No seleccionaste ninguna actualización.");
        setState(() => _isSyncing = false);
        return;
      }

      final response = await http.post(
        Uri.parse('http://127.0.0.1:8001/api/excel/sincronizar'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'updates': updatesToSend}),
      );

      if (response.statusCode == 200) {
        final result = json.decode(response.body);
        _showResultDialog("Sincronización Exitosa", "Se actualizaron ${result['updated_count']} registros.");
        // Limpiar lista visualmente
        setState(() {
          _pendingConflicts.removeWhere((c) => _acceptedUpdates.contains(c['Codigo_Pieza']));
          _acceptedUpdates.clear();
        });
      } else {
        throw Exception("Error Backend: ${response.statusCode}");
      }

    } catch (e) {
      _showResultDialog("Error", e.toString());
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  void _showResultDialog(String title, String content) {
    showDialog(
      context: context,
      builder: (context) => ContentDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          Button(
            child: const Text('Aceptar'),
            onPressed: () => Navigator.pop(context),
          )
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: PageHeader(
        title: const Text('Arbitraje de Conflictos'),
        commandBar: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(FluentIcons.back, size: 20),
              onPressed: () {
                // Confirmación simple antes de salir si hay pendientes
                Navigator.pop(context);
              },
            ),
            const SizedBox(width: 20),
            InfoLabel(
              label: 'Registros Procesados',
              child: Text('${widget.totalProcessed}', style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 20),
            InfoLabel(
              label: 'Conflictos Pendientes',
              child: Text('${_pendingConflicts.length}', style: TextStyle(color: Colors.warningPrimaryColor, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 40),
            FilledButton(
              onPressed: _isSyncing || _acceptedUpdates.isEmpty ? null : _syncChanges,
              child: _isSyncing 
                ? const ProgressRing(strokeWidth: 2) 
                : Text('Aplicar ${_acceptedUpdates.length} Cambios'),
            ),
          ],
        ),
      ),
      content: Padding(
        padding: const EdgeInsets.all(16.0),
        child: _pendingConflicts.isEmpty 
          ? const Center(child: Text("🎉 No hay conflictos pendientes. Todo sincronizado."))
          : Scrollbar(
              controller: _scrollController,
              thumbVisibility: true,
              style: const ScrollbarThemeData(thickness: 15.0), // Scroll Industrial
              child: ListView.builder(
                controller: _scrollController,
                itemCount: _pendingConflicts.length,
                itemBuilder: (context, index) {
                  final item = _pendingConflicts[index];
                  final codigo = item['Codigo_Pieza'];
                  final isMarked = _acceptedUpdates.contains(codigo);
                  final detalles = item['Detalles'] ?? '';

                  return Card(
                    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8), // Compacto
                    margin: const EdgeInsets.only(bottom: 4), // Compacto
                    backgroundColor: isMarked ? Colors.successPrimaryColor.withOpacity(0.1) : null,
                    child: ListTile(
                      leading: Icon(FluentIcons.warning, color: Colors.warningPrimaryColor),
                      title: Text(
                        "${item['Codigo_Pieza']}", 
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(detalles, style: TextStyle(color: Colors.red)), // Diferencias en Rojo
                          const SizedBox(height: 4),
                          Text("Excel: ${item['Excel_Data']['Descripcion_Excel']} | ${item['Excel_Data']['Medida_Excel']}", 
                            style: TextStyle(fontSize: 11, color: Colors.grey),
                          ),
                        ],
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Botón Ignorar
                          IconButton(
                            icon: Icon(FluentIcons.cancel, color: Colors.errorPrimaryColor),
                            onPressed: () {
                              setState(() {
                                _acceptedUpdates.remove(codigo);
                                _pendingConflicts.removeAt(index); // Lo quitamos de la lista visual
                              });
                            },
                          ),
                          const SizedBox(width: 10),
                          // Botón Aceptar (Toggle)
                          ToggleButton(
                            checked: isMarked,
                            onChanged: (v) {
                              setState(() {
                                if (v) {
                                  _acceptedUpdates.add(codigo);
                                } else {
                                  _acceptedUpdates.remove(codigo);
                                }
                              });
                            },
                            child: Icon(FluentIcons.check_mark, 
                              color: isMarked ? Colors.white : Colors.successPrimaryColor
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
      ),
    );
  }
}
