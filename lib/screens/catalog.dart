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

  Future<void> _fetchData({bool showLoading = true}) async {
    if (showLoading) {
      setState(() {
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
              _visibleColumns[col] = true;
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
    
    // Solo resetear scroll si hubo un cambio drástico o limpieza
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
                _buildLabelValue("Descripción", row['Descripcion']),
                const SizedBox(height: 10),
                _buildLabelValue("Medida", row['Medida']),
                _buildLabelValue("Material", row['Material']),
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

  Widget _buildLabelValue(String label, dynamic value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Removed const from TextStyle as requested
          Text(label.toUpperCase(), style: TextStyle(fontSize: 10, color: Colors.blue, fontWeight: FontWeight.bold)),
          SelectableText(
            value?.toString() ?? '-',
            style: TextStyle(fontSize: 13), // Removed const
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

  CommandBar _buildCommandBar() {
    return CommandBar(
      primaryItems: [
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
          final minWidth = (activeCols.length * 180.0) + 60.0;
          final viewWidth = minWidth > constraints.maxWidth ? minWidth : constraints.maxWidth;

          return Scrollbar(
            controller: _horizontalScrollController,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: _horizontalScrollController,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: viewWidth,
                height: constraints.maxHeight,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeaderRow(activeCols),
                    const Divider(),
                    Expanded(
                      child: Scrollbar(
                        controller: _verticalScrollController,
                        thumbVisibility: true,
                        child: ListView.builder(
                          controller: _verticalScrollController,
                          itemCount: _filteredData.length,
                          itemBuilder: (context, index) {
                            return _buildDataRow(_filteredData[index], index, activeCols);
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

  Widget _buildHeaderRow(List<String> activeCols) {
    return Row(
      children: [
        SizedBox(
          width: 60,
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
                  // Removed const from TextStyle
                  Text(col.replaceAll('_', ' '), style: TextStyle(fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  TextBox(
                    controller: _filterControllers[col],
                    placeholder: 'Buscar',
                    style: TextStyle(fontSize: 12), // Removed const
                    onChanged: (v) => _applyFilters(),
                  ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  Widget _buildDataRow(Map<String, dynamic> row, int index, List<String> activeCols) {
    return Container(
      color: index % 2 == 0 ? Colors.transparent : Colors.black.withOpacity(0.03),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 60,
            child: Center(
              child: IconButton(
                icon: const Icon(FluentIcons.info, size: 16),
                onPressed: () => _showInfoDetails(row),
              ),
            ),
          ),
          ...activeCols.map((col) {
            return SizedBox(
              width: 180,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                child: Text(
                  row[col]?.toString() ?? '',
                  style: TextStyle(fontSize: 12), // Removed const
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
