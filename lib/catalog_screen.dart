import 'dart:io';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:syncfusion_flutter_datagrid/datagrid.dart';
import 'package:url_launcher/url_launcher.dart';
import 'database_helper.dart';

bool hasUnsavedChanges = false;

class MasterCatalogGlassPage extends StatefulWidget {
  MasterCatalogGlassPage({Key? key}) : super(key: key);

  @override
  State<MasterCatalogGlassPage> createState() => _MasterCatalogGlassPageState();
}
class _MasterCatalogGlassPageState
    extends State<MasterCatalogGlassPage> {
  final Map<String, Map<String, dynamic>> _unsavedChanges = {};
  final Map<String, String> _filters = {};
  bool saving = false;

  final DatabaseHelper db = DatabaseHelper();
  List<Map<String, dynamic>> items = [];
  late MasterDataSource _dataSource;
  final DataGridController _dataGridController = DataGridController();

  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    _dataSource = MasterDataSource(
      items: [],
      onCellUpdate: _handleCellSubmit,
      onDelete: _handleDelete,
      onRefresh: load,
      onUpdateSuccess: _showSuccess,
      context: context,
      unsavedChanges: _unsavedChanges,
    );
    load();
  }

  Future<void> load() async {
    if (!mounted) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final res = await db.getMaster();
      if (mounted) {
        setState(() {
          items = res;
          _dataSource = MasterDataSource(
            items: items,
            onCellUpdate: _handleCellSubmit,
            onDelete: _handleDelete,
            onRefresh: load,
            controller: _dataGridController,
            onUpdateSuccess: _showSuccess,
            context: context,
            unsavedChanges: _unsavedChanges,
          );
          loading = false;
        });
      }
    } catch (e) {
      if (mounted)
        setState(() {
          error = e.toString();
          loading = false;
        });
    }
  }

  void _handleCellSubmit(String code, String column, dynamic value) {
    setState(() {
      _unsavedChanges.putIfAbsent(code, () => {});
      _unsavedChanges[code]![column] = value;
      hasUnsavedChanges = true;
    });
  }

  Future<void> _saveAllChanges() async {
    if (_unsavedChanges.isEmpty) return;

    setState(() => saving = true);
    try {
      int count = 0;
      for (var entry in _unsavedChanges.entries) {
        final code = entry.key;
        final changes = entry.value;

        // Map column names back to DB column names if necessary
        final Map<String, dynamic> dbChanges = {};
        changes.forEach((col, val) {
          final dbCol = {
            'P.Primario': 'Proceso_Primario',
            'P.1': 'Proceso_1',
            'P.2': 'Proceso_2',
            'P.3': 'Proceso_3',
          }[col] ?? col;
          dbChanges[dbCol] = val;
        });

        await db.updateMaster(code, dbChanges, resolutionStatus: 'EDICION_MANUAL');
        count++;
      }

      _unsavedChanges.clear();
      hasUnsavedChanges = false;
      _showSuccess();
      await load();
    } catch (e) {
      _showErrorDialog("Error al guardar cambios", e.toString());
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  void _showErrorDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (c) => ContentDialog(
        title: Text(title, style: TextStyle(color: Colors.red)),
        content: Text("No se pudo completar la acción.\nCausa: $message"),
        actions: [
          Button(child: Text('Entendido'), onPressed: () => Navigator.pop(c)),
        ],
      ),
    );
  }

  Future<void> _handleDelete(String code) async {
    await db.deleteMaster(code);
    await load();
  }

  void _showSuccess() {
    displayInfoBar(
      context,
      builder: (context, close) {
        return InfoBar(
          title: Text('✅ Guardado'),
          content: Text('Los cambios se han guardado y registrado en el historial.'),
          severity: InfoBarSeverity.success,
        );
      },
    );
  }

  void applyFilters() {
    final filtered = items.where((item) {
      bool matches = true;
      _filters.forEach((key, value) {
        if (value.isEmpty) return;
        final itemValue = item[key]?.toString().toLowerCase() ?? '';
        if (!itemValue.contains(value.toLowerCase())) matches = false;
      });
      return matches;
    }).toList();

    setState(() {
      _dataSource = MasterDataSource(
        items: filtered,
        onCellUpdate: _handleCellSubmit,
        onDelete: _handleDelete,
        onRefresh: load,
        controller: _dataGridController,
        onUpdateSuccess: _showSuccess,
        context: context,
        unsavedChanges: _unsavedChanges,
      );
    });
  }

  Future<void> _exportCatalog() async {
    setState(() { loading = true; });
    try {
      final path = await db.exportFullMaster();
      if (path != null && mounted) {
        displayInfoBar(context, builder: (context, close) => InfoBar(
          title: Text('Exportación Exitosa'),
          content: Text('Guardado en: $path'),
          action: Button(child: Text('Abrir Carpeta'), onPressed: () => _launchFile(path)),
          severity: InfoBarSeverity.success,
          onClose: close,
        ));
      }
    } catch (e) {
      displayInfoBar(context, builder: (context, c) => InfoBar(
        title: Text('Error'),
        content: Text(e.toString()),
        severity: InfoBarSeverity.error,
      ));
    } finally {
      if (mounted) setState(() { loading = false; });
    }
  }

  Future<void> _launchFile(String path) async {
    final Uri uri = Uri.file(path);
    if (await canLaunchUrl(uri)) launchUrl(uri);
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: PageHeader(
        title: Text('Catálogo Maestro v9.4'),
        commandBar: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_unsavedChanges.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(right: 12),
                child: Text(
                  "${_unsavedChanges.length} cambios pendientes",
                  style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold),
                ),
              ),
            SizedBox(
              height: 32,
              child: FilledButton(
                onPressed: saving ? null : _saveAllChanges,
                child: Row(
                  children: [
                    if (saving)
                      Padding(
                        padding: EdgeInsets.only(right: 8),
                        child: ProgressRing(strokeWidth: 2),
                      )
                    else
                      Icon(FluentIcons.save),
                    SizedBox(width: 8),
                    Text("Guardar Cambios"),
                  ],
                ),
              ),
            ),
            SizedBox(width: 10),
            Button(
              onPressed: loading ? null : _exportCatalog,
              child: Row(
                children: [
                  Icon(FluentIcons.excel_document),
                  SizedBox(width: 8),
                  Text("Exportar"),
                ],
              ),
            ),
            SizedBox(width: 10),
            IconButton(
              icon: Icon(FluentIcons.refresh, size: 20),
              onPressed: loading ? null : load,
            ),
            SizedBox(width: 10),
            IconButton(
              icon: Icon(FluentIcons.help, size: 20),
              onPressed: () => _showHelp(context),
            ),
          ],
        ),
      ),
      content: Padding(
        padding: EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          children: [
            SizedBox(height: 16),
            Expanded(
              child: loading
                  ? Center(child: ProgressRing())
                  : error != null
                      ? _buildError()
                      : Container(
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.05),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.white.withOpacity(0.1)),
                          ),
                          child: SfDataGrid(
                            source: _dataSource,
                            controller: _dataGridController,
                            allowEditing: true,
                            selectionMode: SelectionMode.single,
                            navigationMode: GridNavigationMode.cell,
                            headerGridLinesVisibility: GridLinesVisibility.both,
                            gridLinesVisibility: GridLinesVisibility.both,
                            columnWidthMode: ColumnWidthMode.fill,
                            headerRowHeight: 70,
                            columns: [
                              GridColumn(columnName: 'Codigo', label: _buildFilterHeader('Codigo_Pieza', 'Código')),
                              GridColumn(columnName: 'Descripcion', width: 250, label: _buildFilterHeader('Descripcion', 'Descripción (E)')),
                              GridColumn(columnName: 'Medida', label: _buildFilterHeader('Medida', 'Medida')),
                              GridColumn(columnName: 'Material', label: _buildFilterHeader('Material', 'Material')),
                              GridColumn(columnName: 'P.Primario', label: _buildFilterHeader('Proceso_Primario', 'P. Primario')),
                              GridColumn(columnName: 'P.1', label: _buildFilterHeader('Proceso_1', 'P. 1')),
                              GridColumn(columnName: 'P.2', label: _buildFilterHeader('Proceso_2', 'P. 2')),
                              GridColumn(columnName: 'P.3', label: _buildFilterHeader('Proceso_3', 'P. 3')),
                              GridColumn(
                                columnName: 'Acciones',
                                width: 120,
                                allowEditing: false,
                                label: Container(alignment: Alignment.center, child: Text('Acciones')),
                              ),
                            ],
                          ),
                        ),
            ),
            SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterHeader(String key, String label) => Container(
    padding: EdgeInsets.all(4),
    alignment: Alignment.centerLeft,
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
        SizedBox(height: 4),
        SizedBox(
          height: 25,
          child: Builder(
            builder: (context) {
              final isDark = FluentTheme.of(context).brightness == Brightness.dark;
              return TextBox(
                placeholder: '...',
                style: TextStyle(
                  fontSize: 11,
                  color: isDark ? Colors.white : Colors.black,
                ),
                decoration: WidgetStateProperty.all(BoxDecoration(
                  color: isDark ? Color(0xFF333333) : Colors.white,
                  border: Border.all(color: isDark ? Colors.transparent : Colors.black.withOpacity(0.2)),
                  borderRadius: BorderRadius.circular(4),
                )),
                onChanged: (v) {
                  _filters[key] = v;
                  applyFilters();
                },
              );
            }
          ),
        ),
      ],
    ),
  );

  void _showHelp(BuildContext context) {
    showDialog(
      context: context,
      builder: (c) => ContentDialog(
        title: Text('📘 Ayuda: Catálogo Maestro'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('¿Qué hago en esta pantalla?', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('Aquí puede consultar y editar toda la base de datos de materiales.'),
            SizedBox(height: 10),
            Text('¿Qué significan los colores?', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('• Azul (Borde): Indica que la celda ha sido editada pero NO guardada.'),
            Text('• Naranja (Texto): Aparece en el encabezado cuando hay cambios en lote.'),
            SizedBox(height: 10),
            Text('¿Qué paso sigue?', style: TextStyle(fontWeight: FontWeight.bold)),
            Text('Realice todas sus ediciones y presione "Guardar Cambios" al finalizar.'),
          ],
        ),
        actions: [
          Button(child: Text('OK'), onPressed: () => Navigator.pop(c)),
        ],
      ),
    );
  }

  Widget _buildError() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(FluentIcons.error_badge, color: Colors.red, size: 40),
        SizedBox(height: 16),
        Text('Error: ${error ?? "Desconocido"}', style: TextStyle(color: Colors.red)),
        SizedBox(height: 16),
        Button(onPressed: load, child: Text('Reintentar')),
      ],
    ),
  );
}

class MasterDataSource extends DataGridSource {
  final List<Map<String, dynamic>> items;
  final Function(String, String, dynamic) onCellUpdate;
  final BuildContext context;
  final Map<String, Map<String, dynamic>> unsavedChanges;
  final Function(String)? onDelete;
  final VoidCallback? onRefresh;
  final VoidCallback? onUpdateSuccess;
  final DataGridController? controller;

  MasterDataSource({
    required this.items,
    required this.onCellUpdate,
    required this.context,
    required this.unsavedChanges,
    this.onDelete,
    this.onRefresh,
    this.onUpdateSuccess,
    this.controller,
  }) {
    _buildDataGridRows();
  }

  List<DataGridRow> _dataGridRows = [];
  final Map<String, bool> _searchingStatus = {};

  void _buildDataGridRows() {
    _dataGridRows = items.map<DataGridRow>((item) {
      return DataGridRow(cells: [
        DataGridCell<String>(columnName: 'Codigo', value: item['Codigo_Pieza']),
        DataGridCell<String>(columnName: 'Descripcion', value: item['Descripcion']),
        DataGridCell<String>(columnName: 'Medida', value: item['Medida']),
        DataGridCell<String>(columnName: 'Material', value: item['Material']),
        DataGridCell<String>(columnName: 'P.Primario', value: item['Proceso_Primario']),
        DataGridCell<String>(columnName: 'P.1', value: item['Proceso_1']),
        DataGridCell<String>(columnName: 'P.2', value: item['Proceso_2']),
        DataGridCell<String>(columnName: 'P.3', value: item['Proceso_3']),
        DataGridCell<String>(columnName: 'Acciones', value: item['Codigo_Pieza']),
      ]);
    }).toList();
  }

  @override
  List<DataGridRow> get rows => _dataGridRows;

  @override
  DataGridRowAdapter? buildRow(DataGridRow row) {
    final String code = row.getCells().firstWhere((c) => c.columnName == 'Codigo').value.toString();
    final rowChanges = unsavedChanges[code] ?? {};

    return DataGridRowAdapter(
      cells: row.getCells().map<Widget>((cell) {
        final bool isEdited = rowChanges.containsKey(cell.columnName);
        final bool isLink = cell.columnName == 'Medida' &&
            (cell.value.toString().startsWith(r'\\') ||
                cell.value.toString().endsWith('.pdf') ||
                cell.value.toString().endsWith('.dwg'));

        if (cell.columnName == 'Acciones') {
          final String code = cell.value.toString();
          final isSearching = _searchingStatus[code] ?? false;
          return Container(
            alignment: Alignment.center,
            child: isSearching
                ? SizedBox(width: 20, height: 20, child: ProgressRing(strokeWidth: 2))
                : DropDownButton(
                    trailing: null,
                    leading: Icon(FluentIcons.more_vertical, size: 18),
                    items: [
                      MenuFlyoutItem(
                        leading: Icon(FluentIcons.edit, size: 14),
                        text: Text('Editar Registro'),
                        onPressed: () {
                          if (controller != null) {
                            controller!.beginEdit(RowColumnIndex(rows.indexOf(row), 1));
                          }
                        },
                      ),
                      MenuFlyoutItem(
                        leading: Icon(FluentIcons.delete, size: 14, color: Colors.red),
                        text: Text('Eliminar de Maestro', style: TextStyle(color: Colors.red)),
                        onPressed: () => _confirmDelete(code),
                      ),
                      MenuFlyoutSeparator(),
                      MenuFlyoutItem(
                        leading: Icon(FluentIcons.page, size: 14),
                        text: Text('Ver Plano PDF'),
                        onPressed: () => _openBlueprint(code, row),
                      ),
                      MenuFlyoutItem(
                        leading: Icon(FluentIcons.folder_open, size: 14),
                        text: Text('Abrir Carpeta Raíz'),
                        onPressed: () => _openBlueprintFolder(code),
                      ),
                    ],
                  ),
          );
        }

        return Container(
          padding: EdgeInsets.all(8.0),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            border: isEdited ? Border.all(color: Colors.blue, width: 2) : null,
            color: isEdited ? Colors.blue.withOpacity(0.05) : null,
          ),
          child: isLink
              ? GestureDetector(
                  onTap: () => _launchURL(cell.value.toString()),
                  child: Text(
                    isEdited ? rowChanges[cell.columnName].toString() : cell.value.toString(),
                    style: TextStyle(color: Colors.blue, decoration: TextDecoration.underline, fontSize: 11),
                  ),
                )
              : Text(
                  isEdited ? rowChanges[cell.columnName].toString() : cell.value.toString(),
                  style: TextStyle(fontSize: 11, fontWeight: isEdited ? FontWeight.bold : FontWeight.normal),
                ),
        );
      }).toList(),
    );
  }

  Future<void> _confirmDelete(String code) async {
    bool? proceed = await showDialog<bool>(
      context: context,
      builder: (c) => ContentDialog(
        title: Text('⚠️ Confirmar Eliminación'),
        content: Text('¿Realmente desea eliminar $code del Maestro? Esta acción no se puede deshacer.'),
        actions: [
          Button(child: Text('Cancelar'), onPressed: () => Navigator.pop(c, false)),
          FilledButton(
            style: ButtonStyle(backgroundColor: WidgetStateProperty.all(Colors.red)),
            child: Text('Eliminar'),
            onPressed: () => Navigator.pop(c, true),
          ),
        ],
      ),
    );
    if (proceed == true) {
      try {
        await onDelete?.call(code);
        displayInfoBar(context, builder: (context, close) => InfoBar(
          title: Text('Eliminado'),
          content: Text('La pieza ha sido removida del maestro.'),
          severity: InfoBarSeverity.warning,
        ));
      } catch (e) {
        showDialog(context: context, builder: (c) => ContentDialog(title: Text('Error'), content: Text(e.toString()), actions: [Button(child: Text('OK'), onPressed: () => Navigator.pop(c))]));
      }
    }
  }

  Future<void> _launchURL(String path) async {
    final Uri uri = Uri.file(path);
    if (await canLaunchUrl(uri)) launchUrl(uri);
  }

  Future<void> _openBlueprint(String code, DataGridRow row) async {
    final medida = row.getCells().firstWhere((c) => c.columnName == 'Medida').value?.toString() ?? '';
    final hasNumbers = RegExp(r'[0-9]').hasMatch(medida);
    if (hasNumbers && !code.toUpperCase().startsWith('JA')) {
      bool? proceed = await showDialog<bool>(context: context, builder: (c) => ContentDialog(title: Text('⚠️ Materia Prima'), content: Text('Parece que $medida es materia prima. ¿Buscar plano?'), actions: [Button(child: Text('No'), onPressed: () => Navigator.pop(c, false)), FilledButton(child: Text('Buscar'), onPressed: () => Navigator.pop(c, true))]));
      if (proceed != true) return;
    }
    _searchingStatus[code] = true;
    notifyListeners();
    try {
      final db = DatabaseHelper();
      final result = await db.findBlueprint(code);
      _searchingStatus[code] = false;
      notifyListeners();
      if (result['status'] == 'success') {
        launchUrl(Uri.file(result['path']));
      } else {
        showDialog(context: context, builder: (c) => ContentDialog(title: Text("Sin Resultados"), content: Text("No se encontró plano para: $code"), actions: [Button(child: Text('OK'), onPressed: () => Navigator.pop(c))]));
      }
    } catch (e) { _searchingStatus[code] = false; notifyListeners(); }
  }

  Future<void> _openBlueprintFolder(String code) async {
    _searchingStatus[code] = true;
    notifyListeners();
    try {
      final db = DatabaseHelper();
      final result = await db.findBlueprint(code);
      _searchingStatus[code] = false;
      notifyListeners();
      if (result['status'] == 'success') {
        launchUrl(Uri.file(File(result['path']).parent.path));
      }
    } catch (e) { _searchingStatus[code] = false; notifyListeners(); }
  }

  @override
  Future<void> onCellSubmit(DataGridRow dataGridRow, RowColumnIndex rowColumnIndex, GridColumn column) async {
    final dynamic oldValue = dataGridRow.getCells().firstWhere((c) => c.columnName == column.columnName).value;
    final dynamic newValue = newCellValue;
    if (newValue == null || oldValue == newValue) return;
    final String code = dataGridRow.getCells().firstWhere((c) => c.columnName == 'Codigo').value;
    onCellUpdate(code, column.columnName, newValue);
    notifyListeners();
    int index = _dataGridRows.indexOf(dataGridRow);
    items[index][column.columnName] = newValue;
    _buildDataGridRows();
    notifyListeners();
  }

  dynamic newCellValue;

  @override
  Widget? buildEditWidget(DataGridRow dataGridRow, RowColumnIndex rowColumnIndex, GridColumn column, CellSubmit submitCell) {
    final String displayText = dataGridRow.getCells().firstWhere((c) => c.columnName == column.columnName).value.toString();
    newCellValue = null;
    return Container(
      padding: EdgeInsets.all(8),
      alignment: Alignment.centerLeft,
      child: TextBox(
        autofocus: true,
        controller: TextEditingController(text: displayText),
        onChanged: (v) => newCellValue = v,
        onSubmitted: (v) { newCellValue = v; submitCell(); },
      ),
    );
  }
}
