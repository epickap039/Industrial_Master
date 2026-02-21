import 'dart:convert';
import 'dart:io';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart'; // Clipboard
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:excel/excel.dart' as excel_lib;
import 'package:file_picker/file_picker.dart';

class CatalogScreen extends StatefulWidget {
  const CatalogScreen({super.key});

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  // Configuración
  static const String _basePlanosPath = r"Z:\Ingenieria\Planos";
  
  // Datos
  List<Map<String, dynamic>> _allData = [];
  List<Map<String, dynamic>> _filteredData = [];
  List<String> _columns = [];
  
  // Columnas Visibles
  final Map<String, bool> _visibleColumns = {};
  
  // Controllers
  final Map<String, TextEditingController> _filterControllers = {};
  final ScrollController _horizontalScrollController = ScrollController();
  final ScrollController _verticalScrollController = ScrollController();

  // Estado
  bool _isLoading = true;
  bool _onlyWithPlano = false;
  String? _errorMessage;
  
  // Ordenamiento
  String _columnaOrden = "";
  bool _ordenAscendente = true;

  @override
  void initState() {
    super.initState();
    _fetchData();
  }

  @override
  void dispose() {
    _horizontalScrollController.dispose();
    _verticalScrollController.dispose();
    for (var controller in _filterControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// Carga datos del backend
  Future<void> _fetchData({bool showLoading = true}) async {
    if (showLoading) {
      if (mounted) setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      final response = await http.get(Uri.parse('http://192.168.1.73:8001/api/catalog'));

      if (response.statusCode == 200) {
        final List<dynamic> jsonList = json.decode(response.body);
        List<Map<String, dynamic>> data = List<Map<String, dynamic>>.from(jsonList);

        if (data.isNotEmpty) {
          List<String> allKeys = data.first.keys.toList();
          allKeys.remove('Link_Drive'); // Metadata interna
          _columns = allKeys;
          
          if (_visibleColumns.isEmpty) {
            for (var col in _columns) {
              if (['Modificado_Por', 'Ultima_Actualizacion', 'Fecha_Creacion', 'Material', 'Simetria'].contains(col)) {
                _visibleColumns[col] = false;
              } else {
                _visibleColumns[col] = true;
              }
            }
          } else {
             for (var col in _columns) {
              if (!_visibleColumns.containsKey(col)) {
                _visibleColumns[col] = true;
              }
            }
          }
          
          for (var col in _columns) {
            if (!_filterControllers.containsKey(col)) {
              _filterControllers[col] = TextEditingController();
            }
          }
        }

        if (mounted) {
          setState(() {
            _allData = data;
            _applyFilters(resetScroll: showLoading);
            _isLoading = false;
          });
        }
      } else {
         if (mounted) {
           setState(() {
            _errorMessage = 'Error servidor: ${response.statusCode}';
            _isLoading = false;
          });
         }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Error de Conexión (Backend 8001)';
          _isLoading = false;
        });
      }
    }
  }

  /// Aplica filtros locales
  void _applyFilters({bool resetScroll = true}) {
    setState(() {
      _filteredData = _allData.where((row) {
        if (_onlyWithPlano) {
           final link = row['Link_Drive']?.toString();
           if (link == null || link.isEmpty || link == '-') return false;
        }

        for (var entry in _filterControllers.entries) {
          String col = entry.key;
          String filterText = entry.value.text.toLowerCase();
          String cellValue = row[col]?.toString().toLowerCase() ?? '';
          if (!cellValue.contains(filterText)) return false;
        }
        return true;
      }).toList();
    });
    
    // Mantenemos posición de scroll al filtrar/editar, solo reset en carga inicial
    if (resetScroll && _filteredData.isNotEmpty && _verticalScrollController.hasClients) {
       _verticalScrollController.jumpTo(0);
    }
  }

  void _ordenarTabla(String columna) {
    setState(() {
      if (_columnaOrden == columna) {
        _ordenAscendente = !_ordenAscendente;
      } else {
        _columnaOrden = columna;
        _ordenAscendente = true;
      }

      _filteredData.sort((a, b) {
        String valA = (a[columna] ?? "").toString().toLowerCase();
        String valB = (b[columna] ?? "").toString().toLowerCase();
        
        // Manejo especial de fechas para última actualización
        if (columna == 'Ultima_Actualizacion') {
           DateTime? dateA = DateTime.tryParse(valA);
           DateTime? dateB = DateTime.tryParse(valB);
           if (dateA != null && dateB != null) {
              return _ordenAscendente ? dateA.compareTo(dateB) : dateB.compareTo(dateA);
           }
        }

        return _ordenAscendente ? valA.compareTo(valB) : valB.compareTo(valA);
      });
    });
  }

  void _clearFilters() {
    for (var controller in _filterControllers.values) {
      controller.clear();
    }
    setState(() {
      _onlyWithPlano = false;
    });
    _applyFilters();
  }

  /// Exporta a Excel
  Future<void> _exportToExcel() async {
    if (_filteredData.isEmpty) return;

    var excel = excel_lib.Excel.createExcel();
    excel_lib.Sheet sheetObject = excel['Catálogo'];
    excel.delete('Sheet1'); 

    final exportCols = _columns.where((c) => _visibleColumns[c] == true).toList();
    List<excel_lib.CellValue> headers = exportCols.map((c) => excel_lib.TextCellValue(c)).toList();
    sheetObject.appendRow(headers);

    for (var row in _filteredData) {
      List<excel_lib.CellValue> rowData = exportCols.map((col) {
        return excel_lib.TextCellValue(row[col]?.toString() ?? '-');
      }).toList();
      sheetObject.appendRow(rowData);
    }

    String? outputFile = await FilePicker.platform.saveFile(
      dialogTitle: 'Guardar Catálogo',
      fileName: 'catalogo.xlsx',
    );

    if (outputFile != null) {
      if (!outputFile.endsWith('.xlsx')) outputFile = '$outputFile.xlsx';
      
      var fileBytes = excel.save();
      if (fileBytes != null) {
        File(outputFile)
          ..createSync(recursive: true)
          ..writeAsBytesSync(fileBytes);
        
        if (mounted) {
          displayInfoBar(context, builder: (context, close) {
            return InfoBar(
              title: const Text('Exportado'),
              content: Text('Guardado en: $outputFile'),
              severity: InfoBarSeverity.success,
              onClose: close,
            );
          });
        }
      }
    }
  }

  /// Guarda cambios - Payload Completo
  Future<void> _updateMaterial(Map<String, dynamic> row, Map<String, dynamic> updates) async {
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('username') ?? 'Usuario_Desconocido';

    try {
      // 1. Optimistic Update (UI)
      setState(() {
         updates.forEach((key, value) {
           row[key] = value;
         });
         row['Modificado_Por'] = username;
         row['Ultima_Actualizacion'] = DateTime.now().toIso8601String(); 
      });

      // 2. Construir Payload COMPLETO
      // Enviamos TODOS los campos editables para asegurar consistencia
      final body = {
        'Codigo_Pieza': row['Codigo_Pieza'] ?? row['Codigo'],
        'Codigo': row['Codigo'],
        'Descripcion': row['Descripcion'],
        'Medida': row['Medida'],
        'Material': row['Material'],
        'Link_Drive': row['Link_Drive'],
        // Campos Nuevos del Full Editor
        'Simetria': row['Simetria'],
        'Proceso_Primario': row['Proceso_Primario'],
        'Proceso_1': row['Proceso_1'],
        'Proceso_2': row['Proceso_2'],
        'Proceso_3': row['Proceso_3'], 
        // Auditoría
        'usuario': username,
        'Modificado_Por': username
      };
      
      // 3. Enviar al Backend
      final response = await http.put(
        Uri.parse('http://192.168.1.73:8001/api/material/update'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(body),
      );

      if (response.statusCode != 200) {
        throw Exception('Server Error: ${response.body}');
      }

      if (mounted) {
        displayInfoBar(context, builder: (context, close) {
          return InfoBar(
            title: const Text('Guardado Exitoso'),
            content: const Text('Registro actualizado correctamente.'),
            severity: InfoBarSeverity.success,
            onClose: close,
          );
        });
      }

    } catch (e) {
      if (mounted) {
         showDialog(context: context, builder: (context) {
           return ContentDialog(
             title: const Text('Error al Guardar'),
             content: Column(
               mainAxisSize: MainAxisSize.min,
               crossAxisAlignment: CrossAxisAlignment.start,
               children: [
                 SelectableText(e.toString()),
                 const SizedBox(height: 10),
                 Button(
                   child: const Row(
                     mainAxisSize: MainAxisSize.min,
                     children: [
                       Icon(FluentIcons.copy, size: 12),
                       SizedBox(width: 8),
                       Text('Copiar Detalle'),
                     ],
                   ),
                   onPressed: () => Clipboard.setData(ClipboardData(text: e.toString())),
                 ),
               ],
             ),
             actions: [
               Button(child: const Text('Ok'), onPressed: () => Navigator.pop(context))
             ],
           );
         });
      }
      // Revertir cambios (sin mover scroll)
      _fetchData(showLoading: false);
    }
  }

  /// Diálogo de Edición COMPLETO (Incluye Proceso 3)
  void _showEditDialog(Map<String, dynamic> row) {
    // Controladores para todos los campos
    final descCtrl = TextEditingController(text: row['Descripcion']?.toString() ?? '');
    final medCtrl = TextEditingController(text: row['Medida']?.toString() ?? '');
    final matCtrl = TextEditingController(text: row['Material']?.toString() ?? '');
    final linkCtrl = TextEditingController(text: row['Link_Drive']?.toString() ?? '');
    // Nuevos Campos
    final simetriaCtrl = TextEditingController(text: row['Simetria']?.toString() ?? '');
    final procPrimCtrl = TextEditingController(text: row['Proceso_Primario']?.toString() ?? '');
    final proc1Ctrl = TextEditingController(text: row['Proceso_1']?.toString() ?? '');
    final proc2Ctrl = TextEditingController(text: row['Proceso_2']?.toString() ?? '');
    final proc3Ctrl = TextEditingController(text: row['Proceso_3']?.toString() ?? '');

    showDialog(
      context: context,
      builder: (context) {
        return ContentDialog(
          constraints: const BoxConstraints(maxWidth: 600), // Diálogo más ancho
          title: Text("Editor Maestro: ${row['Codigo_Pieza'] ?? row['Codigo']}"),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InfoLabel(label: 'Descripción', child: TextBox(controller: descCtrl, maxLines: 2)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: InfoLabel(label: 'Medida', child: TextBox(controller: medCtrl))),
                    const SizedBox(width: 10),
                    Expanded(child: InfoLabel(label: 'Material', child: TextBox(controller: matCtrl))),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: InfoLabel(label: 'Simetría', child: TextBox(controller: simetriaCtrl))),
                    const SizedBox(width: 10),
                    Expanded(child: InfoLabel(label: 'Proceso Primario', child: TextBox(controller: procPrimCtrl))),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: InfoLabel(label: 'Proceso 1', child: TextBox(controller: proc1Ctrl))),
                    const SizedBox(width: 10),
                    Expanded(child: InfoLabel(label: 'Proceso 2', child: TextBox(controller: proc2Ctrl))),
                  ],
                ),
                const SizedBox(height: 8),
                InfoLabel(label: 'Proceso 3', child: TextBox(controller: proc3Ctrl)),
                const SizedBox(height: 8),
                InfoLabel(label: 'Link Drive / Plano', child: TextBox(controller: linkCtrl)),
              ],
            ),
          ),
          actions: [
            Button(
              child: const Text('Cancelar'),
              onPressed: () => Navigator.pop(context),
            ),
            FilledButton(
              child: const Text('Guardar Cambios'),
              onPressed: () {
                Navigator.pop(context);
                final updates = <String, dynamic>{};
                
                // Helper para chequear cambios
                void check(String key, TextEditingController ctrl) {
                   if (ctrl.text != (row[key]?.toString() ?? '')) {
                     updates[key] = ctrl.text;
                   }
                }

                check('Descripcion', descCtrl);
                check('Medida', medCtrl);
                check('Material', matCtrl);
                check('Link_Drive', linkCtrl);
                check('Simetria', simetriaCtrl);
                check('Proceso_Primario', procPrimCtrl);
                check('Proceso_1', proc1Ctrl);
                check('Proceso_2', proc2Ctrl);
                check('Proceso_3', proc3Ctrl);

                if (updates.isNotEmpty) {
                  _updateMaterial(row, updates);
                }
              },
            ),
          ],
        );
      }
    );
  }

  /// Detalles (Limpiado: Sin "CODIGO" vacio)
  void _showInfoDetails(Map<String, dynamic> row) {
    showDialog(
      context: context,
      builder: (context) {
        return ContentDialog(
          title: Text("Detalle de Pieza"),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Solo Codigo Pieza
                _buildLabelValue("CODIGO PIEZA", row['Codigo_Pieza'] ?? row['Codigo']),
                const Divider(),
                _buildLabelValue("DESCRIPCIÓN", row['Descripcion']),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(child: _buildLabelValue("MEDIDA", row['Medida'])),
                     Expanded(child: _buildLabelValue("MATERIAL", row['Material'])),
                  ],
                ),
                 Row(
                  children: [
                    Expanded(child: _buildLabelValue("SIMETRÍA", row['Simetria'])),
                     Expanded(child: _buildLabelValue("PROC. PRIMARIO", row['Proceso_Primario'])),
                  ],
                ),
                Row(
                  children: [
                    Expanded(child: _buildLabelValue("PROC. 1", row['Proceso_1'])),
                     Expanded(child: _buildLabelValue("PROC. 2", row['Proceso_2'])),
                      Expanded(child: _buildLabelValue("PROC. 3", row['Proceso_3'])),
                  ],
                ),
                const Divider(),
                _buildLabelValue("LINK PLANO", row['Link_Drive']),
                 const Divider(),
                _buildLabelValue("Modificado Por", row['Modificado_Por']),
                _buildLabelValue("Última Actualización", row['Ultima_Actualizacion']),
              ],
            ),
          ),
          actions: [
            Button(
              child: const Text('Cerrar'),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        );
      }
    );
  }

  void _launchDriveLink(String? url) async {
    if (url == null || url.isEmpty || url == '-') return;
    
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
       displayInfoBar(context, builder: (context, close) {
        return InfoBar(
          title: const Text('Error'),
          content: Row(
            children: [
              const Expanded(child: SelectableText('Link inválido o inaccesible.')),
              IconButton(icon: const Icon(FluentIcons.copy), onPressed: () => Clipboard.setData(ClipboardData(text: 'Link inválido o inaccesible.'))),
            ],
          ),
          severity: InfoBarSeverity.error,
          onClose: close,
        );
      });
    }
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    displayInfoBar(context, builder: (context, close) {
      return InfoBar(
        title: const Text('Copiado'),
        content: Text(text),
        severity: InfoBarSeverity.info,
        onClose: close,
      );
    });
  }

  void _showColumnSelector() {
    showDialog(
      context: context,
      builder: (context) {
        return ContentDialog(
          title: const Text('Seleccionar Columnas'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: List<Widget>.from(_columns.map((col) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4.0),
                  child: Row(
                    children: [
                      Checkbox(
                        checked: _visibleColumns[col] == true,
                        onChanged: (v) {
                          setState(() {
                            _visibleColumns[col] = v ?? false;
                          });
                          Navigator.pop(context);
                          _showColumnSelector(); 
                        },
                      ),
                      const SizedBox(width: 8),
                      Text(col.replaceAll('_', ' ')),
                    ],
                  ),
                );
              })),
            ),
          ),
          actions: [
            Button(
              child: const Text('Cerrar'),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        );
      }
    );
  }

  Widget _buildLabelValue(String label, dynamic value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 10, color: Colors.blue, fontWeight: FontWeight.bold)),
          SelectableText(
            value?.toString() ?? '-',
            style: TextStyle(fontSize: 13),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      // Padding compactado en header
      padding: EdgeInsets.zero,
      header: Padding(
        padding: const EdgeInsets.only(left: 10.0, right: 10.0, top: 4.0, bottom: 0.0), // Compactado severamente debajo del titulo
        child: PageHeader(
          title: const Text('Catálogo Maestro'),
          commandBar: _buildCommandBar(),
        ),
      ),
      content: _buildContent(),
      bottomBar: Container(
        padding: const EdgeInsets.all(10),
        child: Text('Registros: ${_filteredData.length} / ${_allData.length}'),
      ),
    );
  }

  Widget _buildCommandBar() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ToggleSwitch(
          checked: _onlyWithPlano,
          content: Text(_onlyWithPlano ? 'Con Plano/Drive' : 'Todos'),
          onChanged: (v) {
            setState(() {
              _onlyWithPlano = v;
              _applyFilters();
            });
          },
        ),
        const SizedBox(width: 20),
        Tooltip(
          message: "Seleccionar Columnas",
          child: IconButton(
            icon: const Icon(FluentIcons.column_options),
            onPressed: _showColumnSelector,
          ),
        ),
        const SizedBox(width: 10),
        Tooltip(
          message: "Refrescar Datos",
          child: IconButton(
            icon: const Icon(FluentIcons.refresh),
            onPressed: _fetchData,
          ),
        ),
        const SizedBox(width: 10),
        Tooltip(
          message: "Limpiar Filtros",
          child: IconButton(
            icon: const Icon(FluentIcons.clear_filter),
            onPressed: _clearFilters,
          ),
        ),
        const SizedBox(width: 10),
        Tooltip(
          message: "Exportar a Excel",
          child: IconButton(
            icon: const Icon(FluentIcons.excel_logo),
            onPressed: _filteredData.isNotEmpty ? _exportToExcel : null,
          ),
        ),
      ],
    );
  }

  double _getColumnWidth(String col) {
    if (col == 'Descripcion') return 250.0;
    if (col == 'Codigo_Pieza' || col == 'Codigo') return 120.0;
    if (col == 'Proceso_Primario') return 135.0; // Fit text
    if (col == 'Medida') return 100.0;
    if (col.startsWith('Proceso_')) return 100.0;
    return 130.0; // Restante (Link Drive, etc.)
  }

  Widget _buildContent() {
    if (_isLoading) return const Center(child: ProgressRing());
    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableText(_errorMessage!, style: TextStyle(color: Colors.red)),
            const SizedBox(height: 10),
            IconButton(
              icon: const Icon(FluentIcons.copy),
              onPressed: () => Clipboard.setData(ClipboardData(text: _errorMessage!)),
            ),
            const Text("Copiar Error", style: TextStyle(fontSize: 10, color: Colors.grey)),
          ],
        ),
      );
    }
    if (_allData.isEmpty) return const Center(child: Text('Sin datos.'));

    final activeCols = _columns.where((c) => _visibleColumns[c] == true).toList();

    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Container(
        decoration: BoxDecoration(
          color: FluentTheme.of(context).cardColor,
          borderRadius: BorderRadius.circular(8.0),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 10,
              offset: const Offset(0, 4),
            )
          ],
        ),
        padding: const EdgeInsets.all(8.0),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final double actionsWidth = 110.0;
            final double colsWidth = activeCols.fold(0.0, (sum, col) => sum + _getColumnWidth(col));
            final minWidth = colsWidth + actionsWidth; 
            final viewWidth = minWidth > constraints.maxWidth ? minWidth : constraints.maxWidth;

            // SOLUCIÓN SCROLLBAR: Scrollbar vertical envuelve al Horizontal
            // Esto asegura que la barra vertical esté siempre visible a la derecha de la pantalla
            return Scrollbar(
              controller: _verticalScrollController,
              thumbVisibility: true,
              interactive: true,
              style: const ScrollbarThemeData(
                thickness: 14.0, // Industrial
                radius: Radius.circular(4),
              ),
              child: SingleChildScrollView(
                controller: _verticalScrollController,
                scrollDirection: Axis.vertical,
                child: FluentTheme(
                  data: FluentTheme.of(context).copyWith(
                    scrollbarTheme: ScrollbarThemeData(
                      backgroundColor: ButtonState.all(FluentTheme.of(context).cardColor),
                      thickness: 12.0, // Barra horizontal opaca y más gruesa
                      radius: const Radius.circular(4),
                    ),
                  ),
                  child: Scrollbar(
                    controller: _horizontalScrollController,
                    thumbVisibility: true,
                    interactive: true,
                    child: SingleChildScrollView(
                      controller: _horizontalScrollController,
                      scrollDirection: Axis.horizontal,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 20.0), // Carril exclusivo inferior
                        child: SizedBox(
                          width: viewWidth,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildHeaderRow(activeCols, actionsWidth),
                              const SizedBox(height: 8), // Separación justa (8px)
                              const Divider(),
                              ListView.builder(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: _filteredData.length,
                                itemBuilder: (context, index) {
                                  return _buildDataRow(_filteredData[index], index, activeCols, actionsWidth);
                                },
                              ),
                              // ESPACIO DE MARGEN FINAL
                              const SizedBox(height: 20),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildHeaderRow(List<String> activeCols, double actionsWidth) {
    return Row(
      children: [
         // Espacio acciones (Sin Settings Icon)
         SizedBox(width: actionsWidth, child: Container()), 
        ...activeCols.map((col) {
          return SizedBox(
            width: _getColumnWidth(col),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Column(
                mainAxisSize: MainAxisSize.min, // COMPACTAR
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          col.replaceAll('_', ' '), 
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12.0), 
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                      Tooltip(
                        message: 'Ordenar por $col',
                        child: IconButton(
                          icon: Icon(
                            _columnaOrden == col 
                              ? (_ordenAscendente ? FluentIcons.sort_up : FluentIcons.sort_down)
                              : FluentIcons.sort, 
                            size: 10
                          ),
                          onPressed: () => _ordenarTabla(col),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4.0), // Separación justa sin paddings extra
                  SizedBox(
                    width: _getColumnWidth(col),
                    child: TextBox(
                      controller: _filterControllers[col],
                      placeholder: 'Buscar',
                      style: TextStyle(fontSize: 12),
                      onChanged: (v) => _applyFilters(resetScroll: true),
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  Widget _buildDataRow(Map<String, dynamic> row, int index, List<String> activeCols, double actionsWidth) {
    final hasLink = row['Link_Drive'] != null && row['Link_Drive'].toString().isNotEmpty && row['Link_Drive'].toString() != '-';

    return Container(
      color: index % 2 == 0 ? Colors.transparent : Colors.black.withOpacity(0.03),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: actionsWidth,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                Tooltip(
                  message: 'Información',
                  child: IconButton(
                    icon: Icon(FluentIcons.info, size: 14, color: Colors.blue), // BLUE
                    onPressed: () => _showInfoDetails(row),
                  ),
                ),
                Tooltip(
                  message: 'Editar',
                  child: IconButton(
                    icon: Icon(FluentIcons.edit, size: 14, color: Colors.orange), // NARANJA VIBRANTE
                    onPressed: () => _showEditDialog(row),
                  ),
                ),
                
                if (hasLink)
                   Tooltip(
                    message: 'Abrir Drive/Plano',
                    child: IconButton(
                      icon: Icon(FluentIcons.cloud, size: 14, color: Colors.teal), // TEAL (VERDE PASTEL VIBRANTE)
                      onPressed: () => _launchDriveLink(row['Link_Drive']?.toString()),
                    ),
                  )
                else
                   const SizedBox(width: 30), 

                Tooltip(
                  message: 'Copiar Código',
                  child: IconButton(
                    icon: Icon(FluentIcons.copy, size: 14, color: Colors.magenta), // MAGENTA/MORADO PARA RESALTAR
                    onPressed: () => _copyToClipboard(row['Codigo']?.toString() ?? ''),
                  ),
                ),
              ],
            ),
          ),
          ...activeCols.map((col) {
            return SizedBox(
              width: _getColumnWidth(col),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                child: Text(
                  row[col]?.toString() ?? '',
                  style: TextStyle(fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}
