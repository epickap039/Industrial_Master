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
  Map<String, dynamic> _paths = {};
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPaths();
  }

  Future<void> _loadPaths() async {
    setState(() => _loading = true);
    try {
      final paths = await db.getPaths();
      setState(() {
        _paths = paths;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _relocateFile(String filename) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx', 'xls'],
        dialogTitle: 'Seleccionar nueva ubicación para $filename',
      );

      if (result != null && result.files.single.path != null) {
        final newPath = result.files.single.path!;
        
        // Optimistic update
        final oldPaths = Map<String, dynamic>.from(_paths);
        setState(() {
          _paths[filename] = newPath;
        });

        // Backend update
        final res = await db.registerPath(filename, newPath);
        
        if (res['status'] == 'success') {
          displayInfoBar(context, builder: (context, close) {
            return InfoBar(
              title: const Text('Ruta Actualizada'),
              content: Text('El archivo $filename ahora apunta a:\n$newPath'),
              severity: InfoBarSeverity.success,
              onClose: close,
            );
          });
        } else {
          // Revert on error
          setState(() => _paths = oldPaths);
          throw Exception(res['message']);
        }
      }
    } catch (e) {
      if (mounted) {
        displayInfoBar(context, builder: (context, close) {
          return InfoBar(
            title: const Text('Error al actualizar ruta'),
            content: Text(e.toString()),
            severity: InfoBarSeverity.error,
            onClose: close,
          );
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _paths.isEmpty) {
      return const Center(child: ProgressRing());
    }

    return ScaffoldPage(
      header: PageHeader(
        title: const Text('Gestión de Fuentes de Datos'),
        commandBar: CommandBar(
          primaryItems: [
            CommandBarButton(
              icon: const Icon(FluentIcons.refresh),
              label: const Text('Recargar Mapeo'),
              onPressed: _loadPaths,
            ),
          ],
        ),
      ),
      content: _paths.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(FluentIcons.archive, size: 40, color: Colors.grey),
                  const SizedBox(height: 10),
                  const Text(
                    'No hay rutas registradas aún.\nEl sistema registrará automáticamente las rutas cuando intente escribir en un Excel.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _paths.length,
              itemBuilder: (context, index) {
                final filename = _paths.keys.elementAt(index);
                final path = _paths[filename];
                
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Card(
                    child: ListTile(
                      leading: Icon(FluentIcons.excel_document, size: 28, color: Colors.green),
                      title: Text(filename, style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text(
                        path ?? 'Ruta desconocida',
                        style: TextStyle(
                          color: Colors.grey, // Adjusted for Fluent UI
                          fontSize: 12,
                        ),
                      ),
                      trailing: Button(
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(FluentIcons.edit, size: 14),
                            SizedBox(width: 8),
                            Text('Relocalizar'),
                          ],
                        ),
                        onPressed: () => _relocateFile(filename),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
