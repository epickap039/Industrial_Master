import 'package:fluent_ui/fluent_ui.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:intl/intl.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<dynamic> _history = [];
  bool _isLoading = false;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _fetchHistory();
  }

  Future<void> _fetchHistory({String? query}) async {
    setState(() {
      _isLoading = true;
    });

    try {
      String url = 'http://192.168.1.73:8001/api/historial?limite=50';
      if (query != null && query.isNotEmpty) {
        url += '&busqueda=$query';
      }

      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        setState(() {
          _history = data;
        });
      } else {
        throw Exception('Error al cargar historial: ${response.statusCode}');
      }
    } catch (e) {
      _showErrorDialog(e.toString());
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (context) {
        return ContentDialog(
          title: const Text('Error'),
          content: Text(message),
          actions: [
            Button(
              child: const Text('Cerrar'),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        );
      },
    );
  }

  Color _getActionColor(String action) {
    if (action.toUpperCase().contains('CREACION') || action.toUpperCase() == 'NUEVO') {
      return Colors.green;
    } else if (action.toUpperCase().contains('MODIFICACION') || action.toUpperCase() == 'UPDATE') {
      return Colors.blue; 
    } else if (action.toUpperCase().contains('ELIMINACION') || action.toUpperCase() == 'DELETE') {
      return Colors.red;
    }
    return Colors.orange; // Default/Unknown
  }

  Widget _buildDiffView(dynamic oldData, dynamic newData, BuildContext context) {
    // Si son mapas (JSON Objects), mostramos diferencias campo por campo
    if (oldData is Map || newData is Map) {
      final oldMap = oldData is Map ? oldData : {};
      final newMap = newData is Map ? newData : {};
      
      final allKeys = {...oldMap.keys, ...newMap.keys}.toList();
      List<Widget> changes = [];

      for (var key in allKeys) {
        final oldVal = oldMap[key];
        final newVal = newMap[key];
        
        // Convertir a string para comparar y mostrar
        final oldStr = oldVal?.toString() ?? 'N/A';
        final newStr = newVal?.toString() ?? 'N/A';

        if (oldStr != newStr) {
           changes.add(
             Padding(
               padding: EdgeInsets.symmetric(vertical: 2.0),
               child: RichText(
                 text: TextSpan(
                   style: TextStyle(color: FluentTheme.of(context).typography.body!.color, fontSize: 13),
                   children: [
                     TextSpan(text: '$key: ', style: TextStyle(fontWeight: FontWeight.bold)),
                     TextSpan(text: oldStr, style: TextStyle(color: Colors.red, decoration: TextDecoration.lineThrough)),
                     TextSpan(text: ' -> '),
                     TextSpan(text: newStr, style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                   ]
                 ),
               ),
             )
           );
        }
      }
      
      if (changes.isEmpty) {
         return Text('Sin cambios identificados en estructura.', style: TextStyle(fontStyle: FontStyle.italic));
      }
      
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: changes);

    } else {
       // Fallback para datos simples (Strings, etc.)
       return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
             if (oldData != null)
               Row(
                 crossAxisAlignment: CrossAxisAlignment.start,
                 children: [
                    SizedBox(width: 70, child: Text('Anterior:', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red))),
                    Expanded(child: Text(oldData.toString(), maxLines: 3, overflow: TextOverflow.ellipsis)),
                 ],
               ),
             if (newData != null) ...[
               SizedBox(height: 4),
               Row(
                 crossAxisAlignment: CrossAxisAlignment.start,
                 children: [
                    SizedBox(width: 70, child: Text('Nuevo:', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green))),
                    Expanded(child: Text(newData.toString(), maxLines: 3, overflow: TextOverflow.ellipsis)),
                 ],
               ),
             ]
          ]
       );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: PageHeader(
        title: const Text('Historial Global de Cambios'),
      ),
      content: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // BARRA DE BÚSQUEDA
            TextBox(
              controller: _searchController,
              placeholder: 'Buscar por Código o Usuario...',
              suffix: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                   if (_searchController.text.isNotEmpty)
                    IconButton(
                        icon: Icon(FluentIcons.clear),
                        onPressed: () {
                          _searchController.clear();
                          _fetchHistory();
                        },
                    ),
                   IconButton(
                    icon: Icon(FluentIcons.search),
                    onPressed: () => _fetchHistory(query: _searchController.text),
                  ),
                  IconButton(
                    icon: Icon(FluentIcons.refresh),
                    onPressed: () => _fetchHistory(query: _searchController.text),
                  ),
                ],
              ),
              onSubmitted: (value) => _fetchHistory(query: value),
            ),
            const SizedBox(height: 20),
            
            // LISTA DE RESULTADOS
            Expanded(
              child: _isLoading
                  ? const Center(child: ProgressRing())
                  : _history.isEmpty
                      ? const Center(child: Text('No se encontraron registros.'))
                      : ListView.builder(
                          itemCount: _history.length,
                          itemBuilder: (context, index) {
                            final item = _history[index];
                            final actionColor = _getActionColor(item['accion'] ?? '');
                            
                            return Card(
                              margin: const EdgeInsets.only(bottom: 10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Encabezado
                                  Row(
                                    children: [
                                      Text(
                                        item['fecha'] ?? 'Sin fecha',
                                        style: const TextStyle(fontSize: 12, color: Colors.grey),
                                      ),
                                      const SizedBox(width: 10),
                                      Text(
                                        '| Usuario: ${item['usuario'] ?? "Desconocido"}',
                                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                      ),
                                      const Spacer(),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: actionColor.withOpacity(0.2),
                                          borderRadius: BorderRadius.circular(4),
                                          border: Border.all(color: actionColor),
                                        ),
                                        child: Text(
                                          item['accion'] ?? 'ACCIÓN',
                                          style: TextStyle(color: actionColor, fontWeight: FontWeight.bold, fontSize: 12),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  
                                  // Título (Código)
                                  SelectableText(
                                    item['codigo'] ?? 'SIN CÓDIGO',
                                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                                  ),
                                  const SizedBox(height: 8),
                                  
                                  // Cuerpo (Cambios - Diff View)
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: FluentTheme.of(context).brightness == Brightness.dark 
                                          ? Colors.black.withOpacity(0.2) 
                                          : Colors.grey[20], // Still using grey[20] as it seemed fine before, just non-const
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: _buildDiffView(item['valor_anterior'], item['valor_nuevo'], context),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
