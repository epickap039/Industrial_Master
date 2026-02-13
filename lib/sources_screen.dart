import 'package:fluent_ui/fluent_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'database_helper.dart';

class SourcesPage extends StatefulWidget {
  const SourcesPage({Key? key}) : super(key: key);

  @override
  State<SourcesPage> createState() => _SourcesPageState();
}

class _SourcesPageState extends State<SourcesPage> {
  final DatabaseHelper db = DatabaseHelper();
  List<Map<String, dynamic>> _sources = [];
  bool _loading = false;
  
  // Track scanning state per item
  final Map<int, bool> _scanningStates = {};

  @override
  void initState() {
    super.initState();
    _loadSources();
  }

  Future<void> _loadSources() async {
    setState(() => _loading = true);
    try {
      final sources = await db.getSources();
      if (mounted) {
        setState(() {
          _sources = sources;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _showError(e.toString());
      }
    }
  }

  void _showError(String message) {
    displayInfoBar(
      context,
      builder: (context, close) => InfoBar(
        title: const Text('Error'),
        content: Text(message),
        severity: InfoBarSeverity.error,
        onClose: close,
      ),
    );
  }

  void _showSuccess(String title, String message) {
    displayInfoBar(
      context,
      builder: (context, close) => InfoBar(
        title: Text(title),
        content: Text(message),
        severity: InfoBarSeverity.success,
        onClose: close,
      ),
    );
  }

  Future<void> _addSource() async {
    final nameCtrl = TextEditingController();
    String? pickedPath;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => ContentDialog(
          title: const Text('Agregar Nueva Fuente de Datos'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Nombre Lógico (ej: JIF-008, REV14):'),
              const SizedBox(height: 8),
              TextBox(controller: nameCtrl, placeholder: 'Identificador del Archivo'),
              const SizedBox(height: 16),
              const Text('Archivo Excel:'),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextBox(
                      readOnly: true,
                      placeholder: pickedPath ?? 'Ningún archivo seleccionado',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Button(
                    child: const Icon(FluentIcons.folder_open),
                    onPressed: () async {
                      final result = await FilePicker.platform.pickFiles(
                        type: FileType.custom,
                        allowedExtensions: ['xlsx', 'xls'],
                      );
                      if (result != null && result.files.single.path != null) {
                        setDialogState(() => pickedPath = result.files.single.path);
                      }
                    },
                  ),
                ],
              ),
            ],
          ),
          actions: [
            Button(
              child: const Text('Cancelar'),
              onPressed: () => Navigator.pop(context),
            ),
            FilledButton(
              onPressed: (pickedPath == null) ? null : () async {
                try {
                  final name = nameCtrl.text.trim().isEmpty 
                      ? pickedPath!.split('\\').last 
                      : nameCtrl.text.trim();
                      
                  await db.addSource(name, pickedPath!);
                  if (mounted) {
                    Navigator.pop(context);
                    _loadSources();
                    _showSuccess('Fuente Agregada', 'Se ha registrado $name exitosamente.');
                  }
                } catch (e) {
                   // Error handling inside dialog if needed
                }
              },
              child: const Text('Registrar'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _relocateSource(int id, String currentPath) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx', 'xls'],
        dialogTitle: 'Relocalizar Archivo',
      );

      if (result != null && result.files.single.path != null) {
        final newPath = result.files.single.path!;
        final res = await db.updateSource(id, newPath);
        
        if (res['status'] == 'success') {
          _loadSources();
          _showSuccess('Ruta Actualizada', 'El archivo ahora apunta a:\n$newPath');
        } else {
          throw Exception(res['message']);
        }
      }
    } catch (e) {
      _showError(e.toString());
    }
  }

  Future<void> _scanSource(int id, String name) async {
    setState(() => _scanningStates[id] = true);
    try {
      final res = await db.scanSource(id);
      
      if (res['status'] == 'success') {
        final newItems = res['new_items'];
        final conflicts = res['conflicts'];
        
        // Custom Dialog for results
        if (mounted) {
           showDialog(
             context: context,
             builder: (c) => ContentDialog(
               title: Text('Sincronización Completada: $name'),
               content: Column(
                 mainAxisSize: MainAxisSize.min,
                 crossAxisAlignment: CrossAxisAlignment.start,
                 children: [
                   _buildResultRow(FluentIcons.add, Colors.blue, '$newItems Nuevas Piezas', 'Agregadas al Catálogo Maestro.'),
                   const SizedBox(height: 12),
                   _buildResultRow(FluentIcons.warning, Colors.orange, '$conflicts Conflictos', 'Diferencias detectadas con el Maestro.'),
                 ],
               ),
               actions: [
                 FilledButton(child: const Text('Aceptar'), onPressed: () => Navigator.pop(c)),
               ],
             ),
           );
           _loadSources(); // Refresh status
        }
      } else {
        throw Exception(res['message']);
      }
    } catch (e) {
      _showError(e.toString());
    } finally {
      if (mounted) setState(() => _scanningStates[id] = false);
    }
  }

  Widget _buildResultRow(IconData icon, Color color, String title, String subtitle) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(icon, color: color),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            Text(subtitle, style: TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: PageHeader(
        title: const Text('Fuentes de Datos (Data Manager)'),
        commandBar: CommandBar(
          primaryItems: [
            CommandBarButton(
              icon: const Icon(FluentIcons.add),
              label: const Text('Agregar Fuente'),
              onPressed: _addSource,
            ),
            CommandBarButton(
              icon: const Icon(FluentIcons.refresh),
              label: const Text('Recargar Lista'),
              onPressed: _loadSources,
            ),
          ],
        ),
      ),
      content: _loading
          ? const Center(child: ProgressRing())
          : _sources.isEmpty
              ? _buildEmptyState()
              : GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 400,
                    childAspectRatio: 1.8,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
                  ),
                  itemCount: _sources.length,
                  itemBuilder: (context, index) {
                    final source = _sources[index];
                    final id = source['ID'];
                    final name = source['Nombre_Logico'] ?? 'Sin Nombre';
                    final path = source['Ruta_Actual'] ?? '';
                    final lastSync = source['Ultima_Sincronizacion'];
                    final isScanning = _scanningStates[id] == true;

                    return Card(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.green.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Icon(FluentIcons.excel_document, color: Colors.green, size: 24),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16), overflow: TextOverflow.ellipsis),
                                    Text(
                                      lastSync != null ? 'Sincronizado: ${_formatDate(lastSync)}' : 'Nunca sincronizado',
                                      style: TextStyle(fontSize: 10, color: Colors.grey),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const Spacer(),
                          Text(path, style: TextStyle(fontSize: 11, color: Colors.grey), maxLines: 2, overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: Button(
                                  child: const Text('Relocalizar'),
                                  onPressed: isScanning ? null : () => _relocateSource(id, path),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: FilledButton(
                                  child: isScanning 
                                      ? const SizedBox(width: 16, height: 16, child: ProgressRing(strokeWidth: 2))
                                      : const Text('Sincronizar'),
                                  onPressed: isScanning ? null : () => _scanSource(id, name),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
  
  String _formatDate(String dateStr) {
      try {
          // Asumiendo formato ISO o similar de SQL
          final date = DateTime.parse(dateStr);
          return "${date.day}/${date.month} ${date.hour}:${date.minute}"; 
      } catch (e) {
          return dateStr;
      }
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(FluentIcons.database, size: 64, color: Colors.grey.withOpacity(0.5)),
          const SizedBox(height: 16),
          const Text(
            'No hay fuentes de datos configuradas.',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Agregue archivos Excel para comenzar a auditar.',
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 24),
          FilledButton(
            child: const Text('Agregar Primera Fuente'),
            onPressed: _addSource,
          ),
        ],
      ),
    );
  }
}
