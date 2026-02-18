import 'dart:convert';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ArbitrationScreen extends StatefulWidget {
  const ArbitrationScreen({super.key});

  @override
  State<ArbitrationScreen> createState() => _ArbitrationScreenState();
}

class _ArbitrationScreenState extends State<ArbitrationScreen> {
  // Datos
  List<dynamic> _conflicts = [];
  int _totalProcessed = 0;
  bool _isLoading = false;
  
  // Filtros y Selección
  String _filterStatus = 'TODOS'; // TODOS, NUEVO, CONFLICTO
  final Set<String> _selectedUpdates = {};
  
  // UI Scroll
  final ScrollController _scrollController = ScrollController();

  // GETTER FILTRADO
  List<dynamic> get _filteredList {
    if (_filterStatus == 'TODOS') return _conflicts;
    return _conflicts.where((c) => c['Estado'] == _filterStatus).toList();
  }

  // ACCIONES MASIVAS
  void _selectAllVisible() {
    setState(() {
      final idsVisible = _filteredList.map((c) => c['Codigo_Pieza'] as String).toSet();
      // Si todos los visibles ya están seleccionados, deseleccionar
      if (idsVisible.every((id) => _selectedUpdates.contains(id))) {
        _selectedUpdates.removeWhere((id) => idsVisible.contains(id));
      } else {
        _selectedUpdates.addAll(idsVisible);
      }
    });
  }

  void _selectOnlyNew() {
    setState(() {
      _filterStatus = 'NUEVO'; // Cambiar vista para feedback visual
      final newItems = _conflicts.where((c) => c['Estado'] == 'NUEVO').map((c) => c['Codigo_Pieza'] as String);
      _selectedUpdates.addAll(newItems);
    });
  }

  // 1. CARGA DE ARCHIVO
  Future<void> _pickFile() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
        withData: true,
      );

      if (result != null) {
        setState(() => _isLoading = true);
        
        var request = http.MultipartRequest(
          'POST', 
          Uri.parse('http://127.0.0.1:8001/api/excel/procesar')
        );
        
        request.files.add(http.MultipartFile.fromBytes(
          'file',
          result.files.first.bytes!,
          filename: result.files.first.name,
        ));

        var streamedResponse = await request.send();
        var response = await http.Response.fromStream(streamedResponse);

        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          setState(() {
            _conflicts = data['conflictos'];
            _totalProcessed = data['total_leidos'];
            _selectedUpdates.clear();
            _filterStatus = 'TODOS';
          });
        } else {
          _showError("Error al procesar: ${response.statusCode}");
        }
      }
    } catch (e) {
      _showError("Error de archivo: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // 2. SINCRONIZACIÓN
  Future<void> _syncSelected() async {
     setState(() => _isLoading = true);
     final prefs = await SharedPreferences.getInstance();
     final username = prefs.getString('username') ?? 'Admin_Arbitraje';

     try {
       // Preparar payload con origen de estado para el backend
       final updatesToSend = _conflicts
           .where((c) => _selectedUpdates.contains(c['Codigo_Pieza']))
           .map((c) => {
             ...c['Excel_Data'],
             'usuario': username,
             '_Estado_Origen': c['Estado'] // Meta-dato crítico para el backend
           })
           .toList();

       if (updatesToSend.isEmpty) return;

       final response = await http.post(
         Uri.parse('http://127.0.0.1:8001/api/excel/sincronizar'),
         headers: {'Content-Type': 'application/json'},
         body: json.encode({'updates': updatesToSend}),
       );

       if (response.statusCode == 200) {
         final result = json.decode(response.body);
         
         await showDialog(context: context, builder: (c) => ContentDialog(
             title: const Text("Sincronización Completada"),
             content: Text("Procesados: ${result['processed']}\nErrores: ${result['errors'].length}"),
             actions: [Button(child: const Text("OK"), onPressed: () => Navigator.pop(c))]
         ));

         // Limpiar lista visualmente
         setState(() {
           _conflicts.removeWhere((c) => _selectedUpdates.contains(c['Codigo_Pieza']));
           _selectedUpdates.clear();
           if (_conflicts.isEmpty) _totalProcessed = 0;
         });

       } else {
         throw Exception("Error Backend: ${response.statusCode}");
       }
     } catch (e) {
       _showError(e.toString());
     } finally {
       if (mounted) setState(() => _isLoading = false);
     }
  }

  void _showError(String msg) {
    showDialog(context: context, builder: (c) => ContentDialog(
      title: const Text("Error"),
      content: Text(msg),
      actions: [Button(child: const Text("OK"), onPressed: () => Navigator.pop(c))],
    ));
  }

  // 3. EDICIÓN MANUAL
  void _showEditDialog(Map<String, dynamic> item) {
    // Inicializar controladores con datos existentes o vacíos
    final descCtrl = TextEditingController(text: item['Excel_Data']['Descripcion_Excel']);
    final medidaCtrl = TextEditingController(text: item['Excel_Data']['Medida_Excel']);
    final matCtrl = TextEditingController(text: item['Excel_Data']['Material_Excel']);
    final simetriaCtrl = TextEditingController(text: item['Excel_Data']['Simetria'] ?? "No");
    final procPrimCtrl = TextEditingController(text: item['Excel_Data']['Proceso_Primario'] ?? "Torneado");
    final proc1Ctrl = TextEditingController(text: item['Excel_Data']['Proceso_1']);
    final proc2Ctrl = TextEditingController(text: item['Excel_Data']['Proceso_2']);
    final proc3Ctrl = TextEditingController(text: item['Excel_Data']['Proceso_3']); // Campo Nuevo
    final linkCtrl = TextEditingController(text: item['Excel_Data']['Link_Drive']);

    showDialog(
      context: context,
      builder: (c) => ContentDialog(
        title: Text("Editar Item: ${item['Codigo_Pieza']}"),
        content: SizedBox(
          width: 400, // Ancho fijo para el diálogo
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InfoLabel(label: "Descripción", child: TextFormBox(controller: descCtrl, maxLines: 2)),
                const SizedBox(height: 8),
                Row(children: [
                   Expanded(child: InfoLabel(label: "Medida", child: TextFormBox(controller: medidaCtrl))),
                   const SizedBox(width: 8),
                   Expanded(child: InfoLabel(label: "Material", child: TextFormBox(controller: matCtrl))),
                ]),
                const SizedBox(height: 8),
                const Divider(), 
                const SizedBox(height: 8),
                const Text("Procesos y Geometría", style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Row(children: [
                   Expanded(child: InfoLabel(label: "Simetría", child: TextFormBox(controller: simetriaCtrl))),
                   const SizedBox(width: 8),
                   Expanded(child: InfoLabel(label: "Primario", child: TextFormBox(controller: procPrimCtrl))),
                ]),
                const SizedBox(height: 8),
                InfoLabel(label: "Proceso 1", child: TextFormBox(controller: proc1Ctrl)),
                const SizedBox(height: 4),
                InfoLabel(label: "Proceso 2", child: TextFormBox(controller: proc2Ctrl)),
                const SizedBox(height: 4),
                InfoLabel(label: "Proceso 3", child: TextFormBox(controller: proc3Ctrl)),
                const SizedBox(height: 8),
                const Divider(), 
                const SizedBox(height: 8),
                InfoLabel(label: "Link Drive", child: TextFormBox(controller: linkCtrl)),
              ],
            ),
          ),
        ),
        actions: [
          Button(
            child: const Text("Cancelar"),
            onPressed: () => Navigator.pop(c),
          ),
          FilledButton(
            child: const Text("Guardar Cambios"),
            onPressed: () {
              setState(() {
                // Actualizar TODOS los campos en el objeto local
                item['Excel_Data']['Descripcion_Excel'] = descCtrl.text;
                item['Excel_Data']['Medida_Excel'] = medidaCtrl.text;
                item['Excel_Data']['Material_Excel'] = matCtrl.text;
                item['Excel_Data']['Simetria'] = simetriaCtrl.text;
                item['Excel_Data']['Proceso_Primario'] = procPrimCtrl.text;
                item['Excel_Data']['Proceso_1'] = proc1Ctrl.text;
                item['Excel_Data']['Proceso_2'] = proc2Ctrl.text;
                item['Excel_Data']['Proceso_3'] = proc3Ctrl.text;
                item['Excel_Data']['Link_Drive'] = linkCtrl.text;
                
                item['is_manual_edit'] = true; // Flag visual
                
                // Seleccionar automáticamente al editar
                _selectedUpdates.add(item['Codigo_Pieza']);
              });
              Navigator.pop(c);
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // ESTADO VACIO
    if (_conflicts.isEmpty && _totalProcessed == 0 && !_isLoading) {
      return ScaffoldPage(
        header: const PageHeader(title: Text('Importar Excel')),
        content: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(FluentIcons.excel_document, size: 60, color: Colors.successPrimaryColor),
              const SizedBox(height: 20),
              const Text("Carga un BOM para comparar con SQL Server", style: TextStyle(fontSize: 18)),
              const SizedBox(height: 30),
              FilledButton(
                onPressed: _pickFile,
                child: const Padding(padding: EdgeInsets.all(12.0), child: Text("Seleccionar Archivo .xlsx")),
              )
            ],
          ),
        ),
      );
    }

    // ESTADO CON DATOS
    return ScaffoldPage(
      header: PageHeader(
        title: const Text('Importar Excel'),
        commandBar: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Button(
              child: const Row(children: [Icon(FluentIcons.back), SizedBox(width: 8), Text("Limpiar Todo")]), // Botón mejorado para UX
              onPressed: () => setState(() { _conflicts.clear(); _totalProcessed = 0; }),
            ),
            const SizedBox(width: 20),
            FilledButton(
               onPressed: _selectedUpdates.isNotEmpty ? _syncSelected : null,
               child: _isLoading ? const ProgressRing(strokeWidth: 2) : Text("Sincronizar (${_selectedUpdates.length})"),
             )
          ],
        ),
      ),
      content: Column(
        children: [
          // BARRA DE FILTROS Y ACCIONES (NUEVO DISEÑO PARA EVITAR OVERFLOW)
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 8, left: 16, right: 16),
            decoration: BoxDecoration(
              color: FluentTheme.of(context).cardColor,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: FluentTheme.of(context).resources.dividerStrokeColorDefault),
            ),
            child: Wrap( // Usamos Wrap para responsividad total
              spacing: 20,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                 // FILTROS
                 Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(FluentIcons.filter, size: 16),
                    const SizedBox(width: 8),
                    ToggleSwitch(
                      checked: _filterStatus == 'NUEVO',
                      content: const Text("Solo Nuevos"),
                      onChanged: (v) => setState(() => _filterStatus = v ? 'NUEVO' : 'TODOS'),
                    ),
                    const SizedBox(width: 16),
                    ToggleSwitch(
                      checked: _filterStatus == 'CONFLICTO',
                      content: const Text("Solo Conflictos"),
                      onChanged: (v) => setState(() => _filterStatus = v ? 'CONFLICTO' : 'TODOS'),
                    ),
                 ]),
                 
                 // ACCIONES MASIVAS
                 if (_filterStatus != 'CONFLICTO')
                   Button(
                      onPressed: _selectOnlyNew,
                      child: const Row(children: [Icon(FluentIcons.add), SizedBox(width: 5), Text("Aprobar Todos Nuevos")]),
                   ),
              ],
            ),
          ),

          // HEADER TABLA
          // HEADER TABLA
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
            color: FluentTheme.of(context).cardColor,
            child: Row(
              children: [
                SizedBox(width: 50, child: Checkbox(
                  checked: _selectedUpdates.isNotEmpty && _filteredList.every((c) => _selectedUpdates.contains(c['Codigo_Pieza'])),
                  onChanged: (v) => _selectAllVisible()
                )),
                const Expanded(flex: 2, child: Text("CÓDIGO", style: TextStyle(fontWeight: FontWeight.bold))),
                const Expanded(flex: 4, child: Text("VALOR EXCEL", style: TextStyle(color: Colors.successPrimaryColor, fontWeight: FontWeight.bold))),
                const SizedBox(width: 30), 
                const Expanded(flex: 4, child: Text("COMPARATIVA SQL", style: TextStyle(fontWeight: FontWeight.bold))),
                const SizedBox(width: 100, child: Text("ACCIONES")), // Movido aquí
                const SizedBox(width: 80, child: Text("ESTADO")),
              ],
            ),
          ),
          const Divider(),
          // LISTA
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              itemCount: _filteredList.length,
              itemBuilder: (context, index) {
                final item = _filteredList[index];
                final codigo = item['Codigo_Pieza'];
                final isSelected = _selectedUpdates.contains(codigo);
                final estado = item['Estado'];
                final detalles = (item['Detalles'] as String?) ?? "";
                final isManual = item['is_manual_edit'] == true;

                return Container(
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: FluentTheme.of(context).resources.dividerStrokeColorDefault)),
                    color: isSelected ? FluentTheme.of(context).accentColor.withOpacity(0.1) : null,
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                  child: Row(
                    children: [
                      // 1. Checkbox (50px)
                      SizedBox(width: 50, child: Checkbox(
                        checked: isSelected,
                        onChanged: (v) => setState(() {
                          v == true ? _selectedUpdates.add(codigo) : _selectedUpdates.remove(codigo);
                        })
                      )),
                      
                      // 2. Código (Flex 2)
                      Expanded(flex: 2, child: Text(codigo, style: const TextStyle(fontWeight: FontWeight.bold))),
                      
                      // 3. Valor Excel (Flex 4)
                      Expanded(flex: 4, child: Tooltip(
                        message: "${item['Excel_Data']['Descripcion_Excel']} ${item['Excel_Data']['Medida_Excel']}",
                        child: Text(
                          "${item['Excel_Data']['Descripcion_Excel']} ${item['Excel_Data']['Medida_Excel']}", 
                          style: TextStyle(
                            color: isManual ? Colors.blue : Colors.successPrimaryColor,
                            fontWeight: isManual ? FontWeight.bold : FontWeight.normal
                          ),
                          maxLines: 2, 
                          overflow: TextOverflow.ellipsis
                        ),
                      )),
                      
                      // 4. Icono (30px)
                      const SizedBox(width: 30, child: Icon(FluentIcons.forward, size: 14, color: Colors.grey)),
                      
                      // 5. Comparativa Visual (Flex 4)
                      Expanded(flex: 4, child: estado == 'NUEVO' 
                        ? const Text("✨ NUEVA ENTRADA", style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic))
                        : Tooltip(
                            message: detalles,
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                               const Text("DIFERENCIA EN SQL:", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                               Text(detalles, style: TextStyle(color: Colors.warningPrimaryColor, fontSize: 11), maxLines: 2, overflow: TextOverflow.ellipsis)
                            ]),
                          )
                      ),

                      // 6. Acciones - Botón Editar (100px)
                      SizedBox(width: 100, child: Row(
                        children: [
                           IconButton(
                             icon: const Icon(FluentIcons.edit, size: 16),
                             onPressed: () => _showEditDialog(item),
                           ),
                           const Text(" Editar", style: TextStyle(fontSize: 12))
                        ],
                      )),

                      // 7. Badge Estado (80px)
                      SizedBox(width: 80, child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: estado == "NUEVO" ? Colors.successPrimaryColor : Colors.warningPrimaryColor,
                          borderRadius: BorderRadius.circular(12)
                        ),
                        child: Text(estado, 
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)
                        ),
                      )),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
