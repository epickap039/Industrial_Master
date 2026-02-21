
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

const String API_URL = "http://192.168.1.73:8001";

class StandardizationScreen extends StatefulWidget {
  @override
  _StandardizationScreenState createState() => _StandardizationScreenState();
}

class _StandardizationScreenState extends State<StandardizationScreen> {
  List<Map<String, dynamic>> _descriptions = [];
  List<Map<String, dynamic>> _filteredDescriptions = [];
  bool _isLoading = false;
  TextEditingController _searchController = TextEditingController();
  bool _soloNoEstandarizados = false;

  List<String> _officialMaterials = [];

  @override
  void initState() {
    super.initState();
    _fetchDescriptions();
    _fetchOfficialMaterials();
  }

  Future<void> _fetchOfficialMaterials() async {
    try {
      final response = await http.get(Uri.parse('$API_URL/api/config/materiales'));
      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        setState(() {
          _officialMaterials = List<String>.from(data);
        });
      }
    } catch (e) {
      print("Error cargando materiales oficiales: $e");
    }
  }

  Future<void> _fetchDescriptions() async {
    setState(() => _isLoading = true);
    try {
      final response = await http.get(Uri.parse('$API_URL/api/limpieza/descripciones_unicas'));
      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        setState(() {
          _descriptions = List<Map<String, dynamic>>.from(data);
          _filteredDescriptions = _descriptions;
        });
      }
    } catch (e) {
      _showError("Error al cargar descripciones: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _filterDescriptions(String query) {
    setState(() {
      final baseList = _soloNoEstandarizados 
          ? _descriptions.where((item) => !_officialMaterials.contains(item['descripcion'])).toList()
          : _descriptions;
          
      if (query.isEmpty) {
        _filteredDescriptions = baseList;
      } else {
        _filteredDescriptions = baseList.where((item) {
          final desc = item['descripcion']?.toString().toLowerCase() ?? '';
          return desc.contains(query.toLowerCase());
        }).toList();
      }
    });
  }

  Future<void> _showStandardizeDialog(String currentDesc, int count) async {
    String? selectedNewDesc;
    TextEditingController _autoSuggestController = TextEditingController();

    await showDialog(
      context: context,
      builder: (context) {
        return ContentDialog(
          title: Text('Estandarizar Descripción'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Descripción Actual:', style: TextStyle(fontWeight: FontWeight.bold)),
              Text(currentDesc, style: TextStyle(color: Colors.red)),
              SizedBox(height: 10),
              Text('Afectará a $count pieza(s).', style: TextStyle(fontStyle: FontStyle.italic)),
              SizedBox(height: 20),
              Text('Nueva Descripción (Seleccionar Oficial):'),
              
              AutoSuggestBox<String>(
                controller: _autoSuggestController,
                items: _officialMaterials.map((e) {
                  return AutoSuggestBoxItem<String>(
                    value: e,
                    label: e,
                    child: Tooltip(
                      message: e,
                      child: Text(
                        e,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  );
                }).toList(),
                onSelected: (item) {
                  selectedNewDesc = item.value;
                },
                onChanged: (text, reason) {
                   selectedNewDesc = text;
                },
              ),
            ],
          ),
          actions: [
            Button(
              child: Text('Cancelar'),
              onPressed: () => Navigator.pop(context),
            ),
            FilledButton(
              child: Text('Aplicar a TODAS'),
              onPressed: () async {
                Navigator.pop(context); // Cerrar dialogo primero
                if (selectedNewDesc != null && selectedNewDesc!.isNotEmpty) {
                  await _applyStandardization(currentDesc, selectedNewDesc!);
                }
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _applyStandardization(String oldDesc, String newDesc) async {
    setState(() => _isLoading = true);
    
    // Obtener usuario (Simulado o de contexto real si existiera)
    String usuario = "Usuario_Estandarizacion"; 
    
    try {
      final response = await http.post(
        Uri.parse('$API_URL/api/limpieza/actualizar_masivo'),
        headers: {"Content-Type": "application/json"},
        body: json.encode({
          "old_desc": oldDesc,
          "new_desc": newDesc,
          "usuario": usuario 
        }),
      );

      if (response.statusCode == 200) {
        final result = json.decode(response.body);
        _showSuccess("Se actualizaron ${result['actualizadas']} piezas.");
        _fetchDescriptions(); // Recargar lista
      } else {
        _showError("Error del servidor: ${response.statusCode}");
      }

    } catch (e) {
      _showError("Error de conexión: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _showError(String message) {
    displayInfoBar(context, builder: (context, close) {
      return InfoBar(
        title: const Text('Error'),
        content: Row(
          children: [
            Expanded(child: SelectableText(message)),
            Padding(
              padding: const EdgeInsets.only(left: 8.0),
              child: IconButton(
                icon: const Icon(FluentIcons.copy),
                onPressed: () => Clipboard.setData(ClipboardData(text: message)),
              ),
            ),
          ],
        ),
        severity: InfoBarSeverity.error,
        onClose: close,
      );
    });
  }

  void _showSuccess(String message) {
    displayInfoBar(context, builder: (context, close) {
      return InfoBar(
        title: Text('Éxito'),
        content: Text(message),
        severity: InfoBarSeverity.success,
        onClose: close,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: PageHeader(
        title: Text('Estandarización de Datos'),
      ),
      content: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextBox(
                    controller: _searchController,
                    placeholder: 'Filtrar descripciones...',
                    onChanged: _filterDescriptions,
                    suffix: Icon(FluentIcons.search),
                  ),
                ),
                SizedBox(width: 16),
                ToggleSwitch(
                  checked: _soloNoEstandarizados,
                  content: Text('Solo no estandarizados'),
                  onChanged: (v) {
                    setState(() {
                      _soloNoEstandarizados = v;
                    });
                    _filterDescriptions(_searchController.text);
                  },
                ),
              ],
            ),
            SizedBox(height: 20),
            Expanded(
              child: _isLoading
                  ? Center(child: ProgressRing())
                  : _filteredDescriptions.isEmpty
                      ? Center(child: Text("No hay datos para mostrar"))
                      : ListView.builder(
                          itemCount: _filteredDescriptions.length,
                          itemBuilder: (context, index) {
                            final item = _filteredDescriptions[index];
                            final desc = item['descripcion'] ?? "---";
                            final total = item['total'] ?? 0;

                            // Verificar si es oficial
                            final isOfficial = _officialMaterials.contains(desc);

                            return Card(
                              margin: EdgeInsets.only(bottom: 8),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          desc, 
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold, 
                                            fontSize: 16,
                                            color: isOfficial ? Colors.green : null
                                          )
                                        ),
                                        Text('Total piezas: $total', style: TextStyle(color: Colors.grey)),
                                        if (isOfficial)
                                           Text('✅ Estandarizado', style: TextStyle(color: Colors.green, fontSize: 12)),
                                      ],
                                    ),
                                  ),
                                  Row(
                                    children: [
                                      if (!isOfficial) ...[
                                        FilledButton(
                                          child: Text('Hacer Oficial'),
                                          onPressed: () {
                                            showDialog(
                                              context: context, 
                                              builder: (context) => ContentDialog(
                                                title: Text("Confirmación"), 
                                                content: Text("Se agregará [$desc] a Materiales Oficiales."), 
                                                actions: [
                                                  Button(child: Text("Cerrar"), onPressed: () => Navigator.pop(context))
                                                ]
                                              )
                                            );
                                          },
                                        ),
                                        SizedBox(width: 8),
                                      ],
                                      Button(
                                        child: Row(
                                          children: [
                                            Icon(FluentIcons.edit),
                                            SizedBox(width: 8),
                                            Text('Estandarizar'),
                                          ],
                                        ),
                                        onPressed: () => _showStandardizeDialog(desc, total),
                                      ),
                                    ],
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
