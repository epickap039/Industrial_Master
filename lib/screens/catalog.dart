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
          allKeys.remove('Link_Drive'); // Se maneja internamente
          _columns = allKeys;
          
          if (_visibleColumns.isEmpty) {
            for (var col in _columns) {
              // Por defecto ocultar columnas de auditoría para ahorrar espacio
              if (['Modificado_Por', 'Ultima_Actualizacion', 'Fecha_Creacion'].contains(col)) {
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
    
    // Solo reseteamos el scroll si es explicitamente solicitado (ej. carga inicial)
    // Para filtros, mantenemos posición si es posible, o reset si cambia longitud drasticamente
    if (resetScroll && _filteredData.isNotEmpty && _verticalScrollController.hasClients) {
       _verticalScrollController.jumpTo(0);
    }
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

  /// Guarda cambios en Backend
  Future<void> _updateMaterial(Map<String, dynamic> row, Map<String, dynamic> updates) async {
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('username') ?? 'Usuario_Desconocido';

    try {
      // Optimistic Update
      setState(() {
         updates.forEach((key, value) {
           row[key] = value;
         });
         row['Modificado_Por'] = username;
         row['Ultima_Actualizacion'] = DateTime.now().toIso8601String(); 
      });

      // Enviar al backend
      for (var entry in updates.entries) {
        // payload con Codigo_Pieza para evitar error 500
        final body = {
          'Codigo': row['Codigo'],
          'Codigo_Pieza': row['Codigo_Pieza'] ?? row['Codigo'], 
          'Campo': entry.key,
          'Valor': entry.value,
          'Modificado_Por': username,
          'usuario': username // Backup field
        };
        
        final response = await http.put(
          Uri.parse('http://192.168.1.73:8001/api/material/update'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode(body),
        );

        if (response.statusCode != 200) {
          throw Exception('Error actualizando ${entry.key}: ${response.body}');
        }
      }

      if (mounted) {
        displayInfoBar(context, builder: (context, close) {
          return InfoBar(
            title: const Text('Guardado'),
            content: const Text('Cambios registrados correctamente'),
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
             content: Text(e.toString()),
             actions: [
               Button(child: const Text('Ok'), onPressed: () => Navigator.pop(context))
             ],
           );
         });
      }
      // Revertir cambios recargando
      _fetchData(showLoading: false);
    }
  }

  /// Diálogo de Edición
  void _showEditDialog(Map<String, dynamic> row) {
    final descController = TextEditingController(text: row['Descripcion']?.toString() ?? '');
    final medidaController = TextEditingController(text: row['Medida']?.toString() ?? '');
    final materialController = TextEditingController(text: row['Material']?.toString() ?? '');
    final linkController = TextEditingController(text: row['Link_Drive']?.toString() ?? '');

    showDialog(
      context: context,
      builder: (context) {
        return ContentDialog(
          title: Text("Editar: ${row['Codigo_Pieza'] ?? row['Codigo']}"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              InfoLabel(label: 'Descripción', child: TextBox(controller: descController, maxLines: 3)),
              const SizedBox(height: 8),
              InfoLabel(label: 'Medida', child: TextBox(controller: medidaController)),
              const SizedBox(height: 8),
              InfoLabel(label: 'Material', child: TextBox(controller: materialController)),
               const SizedBox(height: 8),
              InfoLabel(label: 'Link Drive', child: TextBox(controller: linkController)),
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
                Navigator.pop(context);
                final updates = <String, dynamic>{};
                if (descController.text != (row['Descripcion']?.toString() ?? '')) {
                  updates['Descripcion'] = descController.text;
                }
                 if (medidaController.text != (row['Medida']?.toString() ?? '')) {
                  updates['Medida'] = medidaController.text;
                }
                 if (materialController.text != (row['Material']?.toString() ?? '')) {
                  updates['Material'] = materialController.text;
                }
                 if (linkController.text != (row['Link_Drive']?.toString() ?? '')) {
                  updates['Link_Drive'] = linkController.text;
                }

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

  /// Detalles (Solo lectura)
  void _showInfoDetails(Map<String, dynamic> row) {
    showDialog(
      context: context,
      builder: (context) {
        return ContentDialog(
          title: Text("Detalle: ${row['Codigo_Pieza'] ?? row['Codigo'] ?? '?'}"),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildLabelValue("Codigo", row['Codigo']),
                _buildLabelValue("Codigo Pieza", row['Codigo_Pieza']),
                const Divider(),
                _buildLabelValue("Descripción", row['Descripcion']),
                const SizedBox(height: 10),
                _buildLabelValue("Medida", row['Medida']),
                _buildLabelValue("Material", row['Material']),
                const Divider(),
                _buildLabelValue("Link Drive", row['Link_Drive']),
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

  /// Abrir link
  void _launchDriveLink(String? url) async {
    if (url == null || url.isEmpty || url == '-') return;
    
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
       displayInfoBar(context, builder: (context, close) {
        return InfoBar(
          title: const Text('Error'),
          content: const Text('No se pudo abrir el link.'),
          severity: InfoBarSeverity.error,
          onClose: close,
        );
      });
    }
  }

  /// Copiar al portapapeles
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

  /// Selector de Columnas
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
                // Usamos Row con Checkbox nativo de fluent_ui
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
                          _showColumnSelector(); // Refrescar diálogo
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

  /// Helper para labels
  Widget _buildLabelValue(String label, dynamic value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(), style: TextStyle(fontSize: 10, color: Colors.blue, fontWeight: FontWeight.bold)),
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
      header: PageHeader(
        title: const Text('Catálogo Maestro'),
        commandBar: _buildCommandBar(),
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
        CommandBar(
          primaryItems: [
            CommandBarButton(
              icon: const Icon(FluentIcons.column_options),
              label: const Text('Columnas'),
              onPressed: _showColumnSelector,
            ),
            CommandBarButton(
              icon: const Icon(FluentIcons.refresh),
              label: const Text('Refrescar'),
              onPressed: _fetchData,
            ),
            CommandBarButton(
              icon: const Icon(FluentIcons.clear_filter),
              label: const Text('Limpiar'),
              onPressed: _clearFilters,
            ),
            CommandBarButton(
              icon: const Icon(FluentIcons.excel_logo),
              label: const Text('Exportar'),
              onPressed: _filteredData.isNotEmpty ? _exportToExcel : null,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildContent() {
    if (_isLoading) return const Center(child: ProgressRing());
    if (_errorMessage != null) return Center(child: Text(_errorMessage!));
    if (_allData.isEmpty) return const Center(child: Text('Sin datos.'));

    final activeCols = _columns.where((c) => _visibleColumns[c] == true).toList();

    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final double actionsWidth = 160.0;
          final minWidth = (activeCols.length * 180.0) + actionsWidth;
          final viewWidth = minWidth > constraints.maxWidth ? minWidth : constraints.maxWidth;

          return Scrollbar(
            controller: _horizontalScrollController,
            thumbVisibility: true,
            style: const ScrollbarThemeData(thickness: 10.0), // Scrollbar grueso
            child: SingleChildScrollView(
              controller: _horizontalScrollController,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: viewWidth,
                height: constraints.maxHeight,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeaderRow(activeCols, actionsWidth),
                    const Divider(),
                    Expanded(
                      child: Scrollbar(
                        controller: _verticalScrollController,
                        thumbVisibility: true,
                         style: const ScrollbarThemeData(thickness: 10.0), // Scrollbar grueso
                        child: ListView.builder(
                          controller: _verticalScrollController,
                          itemCount: _filteredData.length,
                          itemBuilder: (context, index) {
                            return _buildDataRow(_filteredData[index], index, activeCols, actionsWidth);
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
      ),
    );
  }

  Widget _buildHeaderRow(List<String> activeCols, double actionsWidth) {
    return Row(
      children: [
        SizedBox(
          width: actionsWidth,
          child: const Center(child: Icon(FluentIcons.settings, size: 14)),
        ),
        ...activeCols.map((col) {
          return SizedBox(
            width: 180,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(col.replaceAll('_', ' '), style: TextStyle(fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  InfoLabel( // Fix para evitar error de compilación (TextBox no tiene header)
                    label: '',
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
                    icon: const Icon(FluentIcons.info, size: 14),
                    onPressed: () => _showInfoDetails(row),
                  ),
                ),
                Tooltip(
                  message: 'Editar',
                  child: IconButton(
                    icon: const Icon(FluentIcons.edit, size: 14),
                    onPressed: () => _showEditDialog(row),
                  ),
                ),
                // Icono Condicional: Nube solo si hay link
                if (hasLink)
                   Tooltip(
                    message: 'Abrir Drive/Plano',
                    child: IconButton(
                      icon: const Icon(FluentIcons.cloud, size: 14),
                      onPressed: () => _launchDriveLink(row['Link_Drive']?.toString()),
                    ),
                  )
                else
                   const SizedBox(width: 30), // Espacio para alineación

                Tooltip(
                  message: 'Copiar Código',
                  child: IconButton(
                    icon: const Icon(FluentIcons.copy, size: 14),
                    onPressed: () => _copyToClipboard(row['Codigo']?.toString() ?? ''),
                  ),
                ),
              ],
            ),
          ),
          ...activeCols.map((col) {
            return SizedBox(
              width: 180,
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
