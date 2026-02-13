import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'database_helper.dart';

class StandardsGlassPage extends StatefulWidget {
  StandardsGlassPage({Key? key}) : super(key: key);

  @override
  State<StandardsGlassPage> createState() => _StandardsGlassPageState();
}

class _StandardsGlassPageState extends State<StandardsGlassPage> {
  final DatabaseHelper db = DatabaseHelper();
  List<Map<String, dynamic>> _standards = [];
  List<Map<String, dynamic>> _filteredStandards = [];
  bool _loading = false;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadStandards();
  }

  Future<void> _loadStandards() async {
    if (!mounted) return;
    setState(() => _loading = true);
    
    try {
      final data = await db.getStandards();
      if (mounted) {
        setState(() {
          _standards = data;
          _filteredStandards = data;
          _loading = false;
        });
        _filter(_searchController.text);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  void _filter(String query) {
    if (query.isEmpty) {
      setState(() => _filteredStandards = _standards);
      return;
    }
    setState(() {
      _filteredStandards = _standards.where((s) {
        final desc = (s['Descripcion'] ?? '').toString().toLowerCase();
        final cat = (s['Categoria'] ?? '').toString().toLowerCase();
        final q = query.toLowerCase();
        return desc.contains(q) || cat.contains(q);
      }).toList();
    });
  }

  Future<void> _showAddDialog() async {
    final controller = TextEditingController();
    await showDialog(
      context: context,
      builder: (context) => ContentDialog(
        title: Text('Nuevo Estándar de Material'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Descripción del Material:'),
            SizedBox(height: 8),
            TextBox(
              controller: controller,
              placeholder: 'Ej: ACERO A36 1/2"',
              autofocus: true,
            ),
          ],
        ),
        actions: [
          Button(
            child: Text('Cancelar'),
            onPressed: () => Navigator.pop(context),
          ),
          FilledButton(
            child: Text('Guardar'),
            onPressed: () async {
              if (controller.text.trim().isNotEmpty) {
                Navigator.pop(context);
                setState(() => _loading = true);
                await db.addStandard(controller.text.trim().toUpperCase());
                await _loadStandards();
              }
            },
          ),
        ],
      ),
    );
  }

  Future<void> _showEditDialog(int id, String currentDesc) async {
    final controller = TextEditingController(text: currentDesc);
    await showDialog(
      context: context,
      builder: (context) => ContentDialog(
        title: Text('Editar Estándar'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Descripción del Material:'),
            SizedBox(height: 8),
            TextBox(
              controller: controller,
              autofocus: true,
            ),
          ],
        ),
        actions: [
          Button(
            child: Text('Cancelar'),
            onPressed: () => Navigator.pop(context),
          ),
          FilledButton(
            child: Text('Actualizar'),
            onPressed: () async {
              if (controller.text.trim().isNotEmpty) {
                Navigator.pop(context);
                setState(() => _loading = true);
                await db.editStandard(id, controller.text.trim().toUpperCase());
                await _loadStandards();
              }
            },
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(int id, String desc) async {
    await showDialog(
      context: context,
      builder: (context) => ContentDialog(
        title: Text('Eliminar Estándar'),
        content: Text('¿Está seguro de eliminar "$desc" de la biblioteca?'),
        actions: [
          Button(
            child: Text('Cancelar'),
            onPressed: () => Navigator.pop(context),
          ),
          FilledButton(
            style: ButtonStyle(
              backgroundColor: ButtonState.all(Colors.red),
            ),
            child: Text('Eliminar'),
            onPressed: () async {
              Navigator.pop(context);
              setState(() => _loading = true);
              await db.deleteStandard(id);
              await _loadStandards();
            },
          ),
        ],
      ),
    );
  }

  void _showHelp(BuildContext context) {
    showDialog(
      context: context,
      builder: (c) => ContentDialog(
        title: Text('📘 Ayuda: Biblioteca de Estándares'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('¿Qué hago en esta pantalla?', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('Gestione el diccionario oficial de descripciones técnicas de la empresa.'),
            SizedBox(height: 10),
            Text('¿Cómo afecta al sistema?', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('Cualquier nombre aquí registrado será el que la IA use para sugerir correcciones.'),
            SizedBox(height: 10),
            Text('¿Qué paso sigue?', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('Mantenga esta lista actualizada con los nombres exactos que desea ver en su inventario.'),
          ],
        ),
        actions: [
          Button(child: Text('OK'), onPressed: () => Navigator.pop(c)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    
    return ScaffoldPage(
      header: PageHeader(
        title: Text('📘 Estándares Materiales'),
        commandBar: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            SizedBox(
              width: 180,
              child: TextBox(
                controller: _searchController,
                placeholder: 'Filtrar...',
                onChanged: _filter,
                prefix: Padding(
                  padding: EdgeInsets.only(left: 8.0),
                  child: Icon(FluentIcons.search),
                ),
              ),
            ),
            SizedBox(width: 8),
            IconButton(
              icon: Icon(FluentIcons.refresh),
              onPressed: _loadStandards,
            ),
            SizedBox(width: 8),
            IconButton(
              icon: Icon(FluentIcons.help, size: 20),
              onPressed: () => _showHelp(context),
            ),
          ],
        ),
      ),
      content: _loading
          ? Center(child: ProgressRing())
          : Stack(
              children: [
                if (_filteredStandards.isEmpty)
                  Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(FluentIcons.dictionary, size: 64, color: theme.accentColor.withOpacity(0.5)),
                        SizedBox(height: 16),
                        Text('No se encontraron materiales'),
                      ],
                    ),
                  )
                else
                  ListView.builder(
                    itemCount: _filteredStandards.length,
                    padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                    itemBuilder: (context, index) {
                      final item = _filteredStandards[index];
                      final id = item['ID'] ?? 0;
                      final desc = (item['Descripcion'] ?? '').toString();
                      final cat = (item['Categoria'] ?? 'GENERAL').toString();

                      return Padding(
                        padding: EdgeInsets.only(bottom: 8.0),
                        child: Card(
                          borderRadius: BorderRadius.circular(8),
                          padding: EdgeInsets.all(12),
                          child: Row(
                            children: [
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: theme.accentColor.withOpacity(0.1),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  FluentIcons.list,
                                  color: theme.accentColor,
                                  size: 20,
                                ),
                              ),
                              SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      desc,
                                      style: theme.typography.bodyStrong,
                                    ),
                                    Text(
                                      cat,
                                      style: theme.typography.caption?.copyWith(
                                        color: theme.typography.caption?.color?.withOpacity(0.6),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Row(
                                children: [
                                  Tooltip(
                                    message: 'Copiar al portapapeles',
                                    child: IconButton(
                                      icon: Icon(FluentIcons.copy),
                                      onPressed: () {
                                        Clipboard.setData(ClipboardData(text: desc));
                                        displayInfoBar(context, builder: (context, close) {
                                          return InfoBar(
                                            title: Text('Copiado'),
                                            content: Text('"$desc" copiado al portapapeles'),
                                            severity: InfoBarSeverity.success,
                                          );
                                        });
                                      },
                                    ),
                                  ),
                                  IconButton(
                                    icon: Icon(FluentIcons.edit),
                                    onPressed: () => _showEditDialog(id, desc),
                                  ),
                                  IconButton(
                                    icon: Icon(FluentIcons.delete),
                                    onPressed: () => _confirmDelete(id, desc),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                Positioned(
                  bottom: 32,
                  right: 32,
                  child: FilledButton(
                    onPressed: _showAddDialog,
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Row(
                        children: [
                          Icon(FluentIcons.add),
                          SizedBox(width: 8),
                          Text('Nuevo Estándar'),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
