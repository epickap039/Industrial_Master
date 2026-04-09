import 'package:fluent_ui/fluent_ui.dart';
import 'bom_manager.dart';
import '../services/api_client.dart';
import '../widgets/compact_page_header.dart';

class ProjectManagementScreen extends StatefulWidget {
  const ProjectManagementScreen({super.key});

  @override
  _ProjectManagementScreenState createState() =>
      _ProjectManagementScreenState();
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
      final response = await ApiClient.getUnvalidated('/api/proyectos/tractos');
      if (response.statusCode == 200) {
        setState(() {
          _tractos = response.decodeJson();
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
      final response = await ApiClient.postUnvalidated(
        '/api/proyectos/tractos',
        body: {'nombre': nombre},
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
    final password = await _showConfirmDialog(
      '¿Eliminar Tracto/Proyecto?',
      'Selecciona un tracto para continuar.',
    );
    if (password == null) return;

    try {
      setState(() => _isLoading = true);
      final response = await ApiClient.deleteUnvalidated(
        '/api/proyectos/tractos/$id',
        headers: {ApiClient.adminMasterPasswordHeader: password},
      );
      if (response.statusCode == 200) {
        _showSuccess('Tracto eliminado correctamente');
        _fetchTractos();
      } else {
        _reportDeleteFailure(response);
      }
    } catch (e) {
      _showError("Error al eliminar: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // === TIPOS DE PROYECTO ===
  Future<void> _fetchTipos(int idTracto) async {
    setState(() => _isLoading = true);
    try {
      final response = await ApiClient.getUnvalidated(
        '/api/proyectos/tipos/$idTracto',
      );
      if (response.statusCode == 200) {
        setState(() {
          _tipos = response.decodeJson();
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
      final response = await ApiClient.postUnvalidated(
        '/api/proyectos/tipos',
        body: {'id_tracto': _selectedTracto['id'], 'nombre': nombre},
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
    final password = await _showConfirmDialog(
      '¿Eliminar Tipo de Proyecto?',
      'Esta acción es irreversible. Todos los datos asociados se perderán.',
    );
    if (password == null) return;

    try {
      setState(() => _isLoading = true);
      final response = await ApiClient.deleteUnvalidated(
        '/api/proyectos/tipos/$id',
        headers: {ApiClient.adminMasterPasswordHeader: password},
      );
      if (response.statusCode == 200) {
        _showSuccess('Tipo eliminado correctamente');
        _fetchTipos(_selectedTracto['id']);
      } else {
        _reportDeleteFailure(response);
      }
    } catch (e) {
      _showError("Error al eliminar: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // === VERSIONES ===
  Future<void> _fetchVersiones(int idTipo) async {
    setState(() => _isLoading = true);
    try {
      final response = await ApiClient.getUnvalidated(
        '/api/proyectos/versiones/$idTipo',
      );
      if (response.statusCode == 200) {
        setState(() {
          _versiones = response.decodeJson();
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
      final response = await ApiClient.postUnvalidated(
        '/api/proyectos/versiones',
        body: {'id_tipo': _selectedTipo['id'], 'nombre': nombre},
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
    final password = await _showConfirmDialog(
      '¿Eliminar Versión?',
      'Se eliminarán todos los clientes y BOMs asociados.',
    );
    if (password == null) return;

    try {
      setState(() => _isLoading = true);
      final response = await ApiClient.deleteUnvalidated(
        '/api/proyectos/versiones/$id',
        headers: {ApiClient.adminMasterPasswordHeader: password},
      );
      if (response.statusCode == 200) {
        _showSuccess('Versión eliminada correctamente');
        _fetchVersiones(_selectedTipo['id']);
      } else {
        _reportDeleteFailure(response);
      }
    } catch (e) {
      _showError("Error al eliminar: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // === CLIENTES ===
  Future<void> _fetchClientes(int idVersion) async {
    setState(() => _isLoading = true);
    try {
      final response = await ApiClient.getUnvalidated(
        '/api/proyectos/clientes/$idVersion',
      );
      if (response.statusCode == 200) {
        setState(() {
          _clientes = response.decodeJson();
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
      final response = await ApiClient.postUnvalidated(
        '/api/proyectos/clientes',
        body: {'id_version': _selectedVersion['id'], 'nombre': nombre},
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
    final password = await _showConfirmDialog(
      '¿Eliminar Cliente?',
      'Se eliminarán los datos de configuración asociados.',
    );
    if (password == null) return;

    try {
      setState(() => _isLoading = true);
      final response = await ApiClient.deleteUnvalidated(
        '/api/proyectos/clientes/$id',
        headers: {ApiClient.adminMasterPasswordHeader: password},
      );
      if (response.statusCode == 200) {
        _showSuccess('Cliente eliminado correctamente');
        _fetchClientes(_selectedVersion['id']);
      } else {
        _reportDeleteFailure(response);
      }
    } catch (e) {
      _showError("Error al eliminar: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _showError(String message) {
    displayInfoBar(
      context,
      builder: (context, close) {
        return InfoBar(
          title: const Text('Error'),
          content: Text(message),
          severity: InfoBarSeverity.error,
          onClose: close,
        );
      },
    );
  }

  void _showSuccess(String message) {
    displayInfoBar(
      context,
      builder: (context, close) {
        return InfoBar(
          title: const Text('✓ Éxito'),
          content: Text(message),
          severity: InfoBarSeverity.success,
          onClose: close,
        );
      },
    );
  }

  void _reportDeleteFailure(ApiHttpResult response) {
    if (response.statusCode == 401) {
      final body = response.decodeJsonLenient();
      if (body is Map && body['detail'] != null) {
        _showError(body['detail'].toString());
        return;
      }
      _showError('Contraseña maestra incorrecta');
      return;
    }
    _showError('Error: ${response.statusCode}');
  }

  Future<String?> _showConfirmDialog(String title, String content) async {
    String password = '';

    final result = await showDialog<String?>(
      context: context,
      builder:
          (context) => ContentDialog(
            constraints: const BoxConstraints(maxWidth: 520, maxHeight: 420),
            title: Row(
              children: [
                const Icon(
                  FluentIcons.lock,
                  color: Color.fromARGB(255, 255, 152, 0),
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(title, overflow: TextOverflow.ellipsis)),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(content, style: const TextStyle(fontSize: 13)),
                  const SizedBox(height: 16),
                  const Divider(),
                  const SizedBox(height: 12),
                  const Text(
                    '🚨 ACCIÓN CRÍTICA - DATOS IRRECUPERABLES',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Color.fromARGB(255, 244, 67, 54),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Se eliminarán permanentemente:',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Color.fromARGB(26, 244, 67, 54),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: Color.fromARGB(50, 244, 67, 54),
                      ),
                    ),
                    child: const Text(
                      '• Versiones y clientes\n• BOMs y revisiones\n• TODOS los datos asociados',
                      style: TextStyle(fontSize: 10),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Ingresa contraseña maestra para confirmar:',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextBox(
                    placeholder: 'Contraseña maestra',
                    obscureText: true,
                    onChanged: (value) => password = value,
                  ),
                ],
              ),
            ),
            actions: [
              Button(
                child: const Text('Cancelar'),
                onPressed: () => Navigator.pop(context, null),
              ),
              FilledButton(
                child: const Text('Confirmar'),
                onPressed: () => Navigator.pop(context, password),
              ),
            ],
          ),
    );

    return result;
  }

  void _showAddDialog(String title, Function(String) onSave) {
    String inputValue = "";
    showDialog(
      context: context,
      builder:
          (context) => ContentDialog(
            constraints: BoxConstraints(maxWidth: 400, maxHeight: 240),
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextBox(
                  placeholder: 'Ingresa el nombre...',
                  onChanged: (v) => inputValue = v,
                ),
              ],
            ),
            actions: [
              Button(
                child: const Text('Cancelar'),
                onPressed: () => Navigator.pop(context),
              ),
              FilledButton(
                child: const Text('Guardar'),
                onPressed: () {
                  if (inputValue.trim().isNotEmpty) {
                    onSave(inputValue.trim());
                    Navigator.pop(context);
                  }
                },
              ),
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
                color:
                    isEnabled
                        ? Colors.blue.withValues(alpha: 0.05)
                        : Colors.grey[200],
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(8),
                ),
                border: Border(
                  bottom: BorderSide(color: Colors.grey.withValues(alpha: 0.1)),
                ),
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
                        color:
                            isEnabled
                                ? Colors.blue
                                : (FluentTheme.of(
                                          context,
                                        ).typography.body?.color ??
                                        (MediaQuery.of(
                                                  context,
                                                ).platformBrightness ==
                                                Brightness.dark
                                            ? Colors.white
                                            : Colors.black))
                                    .withValues(alpha: 0.4),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (isEnabled)
                    IconButton(
                      icon: const Icon(FluentIcons.add, size: 14),
                      onPressed: onAdd,
                    ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child:
                    isEnabled && items.isEmpty && !_isLoading
                        ? Center(
                          child: Text(
                            "Sin elementos",
                            style: TextStyle(
                              fontSize: 13,
                              color:
                                  FluentTheme.of(
                                    context,
                                  ).typography.body?.color?.withValues(alpha: 0.5) ??
                                  Colors.grey,
                            ),
                          ),
                        )
                        : ListView.builder(
                          itemCount: items.length,
                          itemBuilder: (context, index) {
                            final item = items[index];
                            final isSelected =
                                selectedItem != null &&
                                selectedItem['id'] == item['id'];
                            return Container(
                              margin: const EdgeInsets.symmetric(vertical: 2),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(4),
                                color:
                                    isSelected
                                        ? Colors.blue.withValues(alpha: 0.15)
                                        : null,
                              ),
                              child: ListTile(
                                title: Text(
                                  item['nombre'],
                                  style: TextStyle(
                                    fontWeight:
                                        isSelected
                                            ? FontWeight.w600
                                            : FontWeight.normal,
                                    fontSize: 14,
                                  ),
                                ),
                                onPressed: () => onSelect(item),
                                trailing: IconButton(
                                  icon: Icon(
                                    FluentIcons.delete,
                                    color: Colors.red.withValues(alpha: 0.6),
                                    size: 12,
                                  ),
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
      padding: const EdgeInsets.only(top: 8),
      header: CompactPageHeader(
        title: Text(
          'Jerarquía de Proyectos',
          style: FluentTheme.of(context).typography.title,
        ),
      ),
      content: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Configura la taxonomía de los proyectos en 4 niveles conceptuales: Tractos / Proyectos → Tipo de Proyecto → Versión → Cliente. "
              "Selecciona un Tracto / Proyecto para ver sus Tipos, etc.",
              style: const TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 20),
            if (_isLoading) const ProgressBar(),
            const SizedBox(height: 8),
            Expanded(
              child: Row(
                children: [
                  _buildListColumn(
                    title: "1. Tractos / Proyectos",
                    items: _tractos,
                    selectedItem: _selectedTracto,
                    isEnabled: true,
                    onSelect: (item) {
                      setState(() => _selectedTracto = item);
                      _fetchTipos(item['id']);
                    },
                    onAdd:
                        () => _showAddDialog(
                          "Nuevo Tracto / Proyecto",
                          _addTracto,
                        ),
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
                    onAdd:
                        () => _showAddDialog(
                          "Nuevo Tipo para ${_selectedTracto?['nombre'] ?? ''}",
                          _addTipo,
                        ),
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
                    onAdd:
                        () => _showAddDialog(
                          "Nueva Versión para ${_selectedTipo?['nombre'] ?? ''}",
                          _addVersion,
                        ),
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
                          builder:
                              (context) => BOMManagerScreen(
                                idCliente: item['id'],
                                clientName: item['nombre'],
                              ),
                        ),
                      );
                    },
                    onAdd:
                        () => _showAddDialog(
                          "Nuevo Cliente para ${_selectedVersion?['nombre'] ?? ''}",
                          _addCliente,
                        ),
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
