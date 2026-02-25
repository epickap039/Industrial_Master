import 'package:fluent_ui/fluent_ui.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'bom_manager.dart';

const String API_URL = "http://192.168.1.73:8001";

class ProjectManagementScreen extends StatefulWidget {
  const ProjectManagementScreen({Key? key}) : super(key: key);

  @override
  _ProjectManagementScreenState createState() => _ProjectManagementScreenState();
}

class _ProjectManagementScreenState extends State<ProjectManagementScreen> {
  bool _isLoading = false;

  List<dynamic> _tractos = [];
  List<dynamic> _tipos = [];
  List<dynamic> _versiones = [];
  List<dynamic> _clientes = [];

  dynamic _selectedTracto;
  dynamic _selectedTipo;
  dynamic _selectedVersion;
  dynamic _selectedCliente;

  @override
  void initState() {
    super.initState();
    _fetchTractos();
  }

  // === TRACTOS ===
  Future<void> _fetchTractos() async {
    setState(() => _isLoading = true);
    try {
      final response = await http.get(Uri.parse('$API_URL/api/proyectos/tractos'));
      if (response.statusCode == 200) {
        setState(() {
          _tractos = json.decode(response.body);
          _tipos = [];
          _versiones = [];
          _clientes = [];
          _selectedTracto = null;
          _selectedTipo = null;
          _selectedVersion = null;
          _selectedCliente = null;
        });
      }
    } catch (e) {
      _showError("Error al cargar tractos: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _addTracto(String nombre) async {
    try {
      final response = await http.post(
        Uri.parse('$API_URL/api/proyectos/tractos'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'nombre': nombre}),
      );
      if (response.statusCode == 200) {
        _fetchTractos();
      } else {
        _showError("Error al agregar: ${response.statusCode}");
      }
    } catch (e) {
      _showError("Error: $e");
    }
  }

  Future<void> _deleteTracto(int id) async {
    try {
      final response = await http.delete(Uri.parse('$API_URL/api/proyectos/tractos/$id'));
      if (response.statusCode == 200) {
        _fetchTractos();
      }
    } catch (e) {
      _showError("Error al eliminar: $e");
    }
  }

  // === TIPOS DE PROYECTO ===
  Future<void> _fetchTipos(int idTracto) async {
    setState(() => _isLoading = true);
    try {
      final response = await http.get(Uri.parse('$API_URL/api/proyectos/tipos/$idTracto'));
      if (response.statusCode == 200) {
        setState(() {
          _tipos = json.decode(response.body);
          _versiones = [];
          _clientes = [];
          _selectedTipo = null;
          _selectedVersion = null;
          _selectedCliente = null;
        });
      }
    } catch (e) {
      _showError("Error al cargar tipos de proyecto: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _addTipo(String nombre) async {
    if (_selectedTracto == null) return;
    try {
      final response = await http.post(
        Uri.parse('$API_URL/api/proyectos/tipos'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'id_tracto': _selectedTracto['id'], 'nombre': nombre}),
      );
      if (response.statusCode == 200) {
        _fetchTipos(_selectedTracto['id']);
      } else {
        _showError("Error al agregar: ${response.statusCode}");
      }
    } catch (e) {
      _showError("Error: $e");
    }
  }

  Future<void> _deleteTipo(int id) async {
    try {
      final response = await http.delete(Uri.parse('$API_URL/api/proyectos/tipos/$id'));
      if (response.statusCode == 200) {
        _fetchTipos(_selectedTracto['id']);
      }
    } catch (e) {
      _showError("Error al eliminar: $e");
    }
  }

  // === VERSIONES ===
  Future<void> _fetchVersiones(int idTipo) async {
    setState(() => _isLoading = true);
    try {
      final response = await http.get(Uri.parse('$API_URL/api/proyectos/versiones/$idTipo'));
      if (response.statusCode == 200) {
        setState(() {
          _versiones = json.decode(response.body);
          _clientes = [];
          _selectedVersion = null;
          _selectedCliente = null;
        });
      }
    } catch (e) {
      _showError("Error al cargar versiones: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _addVersion(String nombre) async {
    if (_selectedTipo == null) return;
    try {
      final response = await http.post(
        Uri.parse('$API_URL/api/proyectos/versiones'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'id_tipo': _selectedTipo['id'], 'nombre': nombre}),
      );
      if (response.statusCode == 200) {
        _fetchVersiones(_selectedTipo['id']);
      } else {
        _showError("Error al agregar: ${response.statusCode}");
      }
    } catch (e) {
      _showError("Error: $e");
    }
  }

  Future<void> _deleteVersion(int id) async {
    try {
      final response = await http.delete(Uri.parse('$API_URL/api/proyectos/versiones/$id'));
      if (response.statusCode == 200) {
        _fetchVersiones(_selectedTipo['id']);
      }
    } catch (e) {
      _showError("Error al eliminar: $e");
    }
  }

  // === CLIENTES ===
  Future<void> _fetchClientes(int idVersion) async {
    setState(() => _isLoading = true);
    try {
      final response = await http.get(Uri.parse('$API_URL/api/proyectos/clientes/$idVersion'));
      if (response.statusCode == 200) {
        setState(() {
          _clientes = json.decode(response.body);
          _selectedCliente = null;
        });
      }
    } catch (e) {
      _showError("Error al cargar clientes: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _addCliente(String nombre) async {
    if (_selectedVersion == null) return;
    try {
      final response = await http.post(
        Uri.parse('$API_URL/api/proyectos/clientes'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'id_version': _selectedVersion['id'], 'nombre': nombre}),
      );
      if (response.statusCode == 200) {
        _fetchClientes(_selectedVersion['id']);
      } else {
        _showError("Error al agregar: ${response.statusCode}");
      }
    } catch (e) {
      _showError("Error: $e");
    }
  }

  Future<void> _deleteCliente(int id) async {
    try {
      final response = await http.delete(Uri.parse('$API_URL/api/proyectos/clientes/$id'));
      if (response.statusCode == 200) {
        _fetchClientes(_selectedVersion['id']);
      }
    } catch (e) {
      _showError("Error al eliminar: $e");
    }
  }

  void _showError(String message) {
    displayInfoBar(context, builder: (context, close) {
      return InfoBar(
        title: const Text('Error'),
        content: Text(message),
        severity: InfoBarSeverity.error,
        onClose: close,
      );
    });
  }

  void _showAddDialog(String title, Function(String) onSave) {
    String inputValue = "";
    showDialog(
      context: context,
      builder: (context) => ContentDialog(
        constraints: BoxConstraints(maxWidth: 400, maxHeight: 240),
        title: Text(title),
        content: TextBox(
          placeholder: 'Ingresa el nombre...',
          onChanged: (v) => inputValue = v,
        ),
        actions: [
          Button(child: const Text('Cancelar'), onPressed: () => Navigator.pop(context)),
          FilledButton(
            child: const Text('Guardar'),
            onPressed: () {
              if (inputValue.trim().isNotEmpty) {
                onSave(inputValue.trim());
                Navigator.pop(context);
              }
            },
          )
        ],
      ),
    );
  }

  Widget _buildListColumn({
    required String title,
    required List<dynamic> items,
    required dynamic selectedItem,
    required Function(dynamic) onSelect,
    required Function() onAdd,
    required Function(int) onDelete,
    required bool isEnabled,
  }) {
    return Expanded(
      child: Card(
        padding: const EdgeInsets.all(0),
        borderRadius: BorderRadius.circular(8),
        backgroundColor: FluentTheme.of(context).cardColor,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: isEnabled ? Colors.blue.withOpacity(0.05) : Colors.grey[200],
                borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                border: Border(bottom: BorderSide(color: Colors.grey.withOpacity(0.1))),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      title.toUpperCase(), 
                      style: TextStyle(
                        fontWeight: FontWeight.w700, 
                        fontSize: 13, 
                        color: isEnabled ? Colors.blue : Colors.grey[100]
                      ), 
                      overflow: TextOverflow.ellipsis
                    )
                  ),
                  if (isEnabled)
                    IconButton(
                      icon: const Icon(FluentIcons.add, size: 14),
                      onPressed: onAdd,
                    )
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: isEnabled && items.isEmpty && !_isLoading
                    ? const Center(child: Text("Sin elementos", style: TextStyle(color: Colors.grey, fontSize: 13)))
                    : ListView.builder(
                        itemCount: items.length,
                        itemBuilder: (context, index) {
                          final item = items[index];
                          final isSelected = selectedItem != null && selectedItem['id'] == item['id'];
                          return Container(
                            margin: const EdgeInsets.symmetric(vertical: 2),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(4),
                              color: isSelected ? Colors.blue.withOpacity(0.15) : null,
                            ),
                            child: ListTile(
                              title: Text(
                                item['nombre'], 
                                style: TextStyle(
                                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                                  fontSize: 14,
                                ),
                              ),
                              onPressed: () => onSelect(item),
                              trailing: IconButton(
                                icon: Icon(FluentIcons.delete, color: Colors.red.withOpacity(0.6), size: 12),
                                onPressed: () => onDelete(item['id']),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: const PageHeader(title: Text('Jerarquía de Proyectos')),
      content: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Configura la taxonomía de los proyectos en 4 niveles conceptuales: Tracto → Tipo de Proyecto → Versión → Cliente. "
              "Selecciona un Tracto para ver sus Tipos, etc.",
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 20),
            if (_isLoading) const ProgressBar(),
            const SizedBox(height: 8),
            Expanded(
              child: Row(
                children: [
                  _buildListColumn(
                    title: "1. Tractos",
                    items: _tractos,
                    selectedItem: _selectedTracto,
                    isEnabled: true,
                    onSelect: (item) {
                      setState(() => _selectedTracto = item);
                      _fetchTipos(item['id']);
                    },
                    onAdd: () => _showAddDialog("Nuevo Tracto", _addTracto),
                    onDelete: _deleteTracto,
                  ),
                  const SizedBox(width: 16),
                  _buildListColumn(
                    title: "2. Tipos",
                    items: _tipos,
                    selectedItem: _selectedTipo,
                    isEnabled: _selectedTracto != null,
                    onSelect: (item) {
                      setState(() => _selectedTipo = item);
                      _fetchVersiones(item['id']);
                    },
                    onAdd: () => _showAddDialog("Nuevo Tipo para ${_selectedTracto?['nombre'] ?? ''}", _addTipo),
                    onDelete: _deleteTipo,
                  ),
                  const SizedBox(width: 16),
                  _buildListColumn(
                    title: "3. Versiones",
                    items: _versiones,
                    selectedItem: _selectedVersion,
                    isEnabled: _selectedTipo != null,
                    onSelect: (item) {
                      setState(() => _selectedVersion = item);
                      _fetchClientes(item['id']);
                    },
                    onAdd: () => _showAddDialog("Nueva Versión para ${_selectedTipo?['nombre'] ?? ''}", _addVersion),
                    onDelete: _deleteVersion,
                  ),
                  const SizedBox(width: 16),
                  _buildListColumn(
                    title: "4. Clientes",
                    items: _clientes,
                    selectedItem: _selectedCliente,
                    isEnabled: _selectedVersion != null,
                    onSelect: (item) {
                      setState(() => _selectedCliente = item);
                      Navigator.push(
                        context,
                        FluentPageRoute(
                          builder: (context) => BOMManagerScreen(
                            idCliente: item['id'],
                            clientName: item['nombre'],
                          ),
                        ),
                      );
                    },
                    onAdd: () => _showAddDialog("Nuevo Cliente para ${_selectedVersion?['nombre'] ?? ''}", _addCliente),
                    onDelete: _deleteCliente,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
