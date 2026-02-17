import 'dart:convert';
import 'dart:io';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart'; // Clipboard
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:excel/excel.dart';
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
  
  // Columnas Visibles (Mapa para estado On/Off)
  final Map<String, bool> _visibleColumns = {};
  
  // Controllers
  final Map<String, TextEditingController> _filterControllers = {};
  final ScrollController _horizontalScrollController = ScrollController();
  final FlyoutController _flyoutController = FlyoutController();
  
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
    _flyoutController.dispose();
    for (var controller in _filterControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _fetchData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final response = await http.get(Uri.parse('http://127.0.0.1:8001/api/catalog'));

      if (response.statusCode == 200) {
        final List<dynamic> jsonList = json.decode(response.body);
        List<Map<String, dynamic>> data = List<Map<String, dynamic>>.from(jsonList);

        if (data.isNotEmpty) {
          // Obtener todas las claves
          List<String> allKeys = data.first.keys.toList();
          
          // Eliminar 'Link_Drive' de las columnas visuales (se mostrará en Acciones)
          allKeys.remove('Link_Drive');
          
          _columns = allKeys;
          
          // Inicializar visibilidad: Todas true si es la primera vez
          if (_visibleColumns.isEmpty) {
            for (var col in _columns) {
              _visibleColumns[col] = true;
            }
          } else {
            // Asegurar que las nuevas columnas estén presentes
            for (var col in _columns) {
              if (!_visibleColumns.containsKey(col)) {
                _visibleColumns[col] = true;
              }
            }
          }
          
          // Crear controladores de filtro
          for (var col in _columns) {
            if (!_filterControllers.containsKey(col)) {
              _filterControllers[col] = TextEditingController();
            }
          }
        }

        setState(() {
          _allData = data;
          _applyFilters();
          _isLoading = false;
        });
      } else {
         if (mounted) {
           setState(() {
            _errorMessage = 'Error del servidor: ${response.statusCode}';
            _isLoading = false;
          });
         }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = '❌ Error de Conexión: Verifica el backend (8001).';
          _isLoading = false;
        });
      }
    }
  }

  void _applyFilters() {
    setState(() {
      _filteredData = _allData.where((row) {
        // Filtro "Solo con Plano"
        if (_onlyWithPlano) {
           final link = row['Link_Drive']?.toString();
           if (link == null || link.isEmpty || link == '-') {
             return false;
           }
        }

        for (var entry in _filterControllers.entries) {
          String col = entry.key;
          String filterText = entry.value.text.toLowerCase();
          
          if (_visibleColumns[col] == true && filterText.isNotEmpty) {
            String cellValue = row[col]?.toString().toLowerCase() ?? '';
            if (!cellValue.contains(filterText)) {
              return false;
            }
          }
        }
        return true;
      }).toList();
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

  Future<void> _exportToExcel() async {
    if (_filteredData.isEmpty) return;

    var excel = Excel.createExcel();
    Sheet sheetObject = excel['Catálogo'];
    excel.delete('Sheet1'); 

    // Solo exportar columnas visibles
    final exportCols = _columns.where((c) => _visibleColumns[c] == true).toList();

    // Encabezados
    List<CellValue> headers = exportCols.map((c) => TextCellValue(c)).toList();
    sheetObject.appendRow(headers);

    // Datos
    for (var row in _filteredData) {
      List<CellValue> rowData = exportCols.map((col) {
        return TextCellValue(row[col]?.toString() ?? '-');
      }).toList();
      sheetObject.appendRow(rowData);
    }

    // Guardar
    String? outputFile = await FilePicker.platform.saveFile(
      dialogTitle: 'Guardar Vista de Catálogo',
      fileName: 'vista_catalogo.xlsx',
    );

    if (outputFile != null) {
      if (!outputFile.endsWith('.xlsx')) {
        outputFile = '$outputFile.xlsx';
      }
      
      var fileBytes = excel.save();
      if (fileBytes != null) {
        File(outputFile)
          ..createSync(recursive: true)
          ..writeAsBytesSync(fileBytes);
        
        if (mounted) {
          displayInfoBar(context, builder: (context, close) {
            return InfoBar(
              title: const Text('Exportación Exitosa'),
              content: Text('Guardado en: $outputFile'),
              severity: InfoBarSeverity.success,
              onClose: close,
            );
          });
        }
      }
    }
  }

  Future<void> _openPlano(String codigo) async {
    final cleanCode = codigo.trim();
    final extensions = ['.pdf', '.jpg', '.png'];
    String? foundPath;

    for (var ext in extensions) {
      final path = '$_basePlanosPath\\$cleanCode$ext';
      if (await File(path).exists()) {
        foundPath = path;
        break;
      }
    }

    if (foundPath != null) {
      try {
        await launchUrl(Uri.file(foundPath));
        if (mounted) _showInfoBar('Abriendo Plano', 'Lanzando: $foundPath', InfoBarSeverity.success);
      } catch (e) {
        if (mounted) _showInfoBar('Error', 'No se pudo abrir el archivo: $e', InfoBarSeverity.error);
      }
    } else {
      if (mounted) _showInfoBar('Plano No Encontrado', 'No existe archivo para $cleanCode en $_basePlanosPath (Probados: pdf, jpg, png)', InfoBarSeverity.warning);
    }
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    _showInfoBar('Copiado', '$text copiado al portapapeles', InfoBarSeverity.success);
  }

  void _showInfoBar(String title, String content, InfoBarSeverity severity) {
    displayInfoBar(context, builder: (context, close) {
      return InfoBar(
        title: Text(title),
        content: Text(content),
        severity: severity,
        onClose: close,
      );
    });
  }

  Future<void> _updateMaterial(Map<String, dynamic> updatedData) async {
    // Mostrar carga
    showDialog(
      context: context,
      builder: (c) => const Center(child: ProgressRing()),
    );

    try {
      final response = await http.put(
        Uri.parse('http://127.0.0.1:8001/api/material/update'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(updatedData),
      );

      Navigator.pop(context); // Cerrar loading

      if (response.statusCode == 200) {
        _showInfoBar('Actualización Exitosa', 'Registro guardado correctamente.', InfoBarSeverity.success);
        _fetchData(); // Refrescar tabla
      } else {
        _showInfoBar('Error al Guardar', 'Backend respondió: ${response.statusCode}', InfoBarSeverity.error);
      }
    } catch (e) {
      Navigator.pop(context); // Cerrar loading si falla
      _showInfoBar('Error de Conexión', 'No se pudo conectar al servidor.', InfoBarSeverity.error);
    }
  }

  Future<void> _showEditDialog(Map<String, dynamic> row) async {
     // Verificar Sesión (Aunque main.dart protege, validamos por seguridad)
     final prefs = await SharedPreferences.getInstance();
     final isLoggedIn = prefs.getBool('isLoggedIn') ?? false;

     if (!isLoggedIn) {
       _showInfoBar('Acceso Denegado', 'Debe iniciar sesión para editar.', InfoBarSeverity.warning);
       return;
     }

     Map<String, TextEditingController> controllers = {};
     for (var key in row.keys) {
       controllers[key] = TextEditingController(text: row[key]?.toString() ?? '');
     }

     await showDialog(
       context: context,
       builder: (context) {
         return ContentDialog(
           title: const Text('Editar Pieza'),
           content: SizedBox(
             width: 400,
             child: ListView(
               shrinkWrap: true,
               children: row.keys.map((key) {
                 final isReadOnly = key == 'Codigo_Pieza' || key == 'Codigo' || key == 'ID';
                 return Padding(
                   padding: const EdgeInsets.only(bottom: 8.0),
                   child: InfoLabel(
                     label: key.replaceAll('_', ' '),
                     child: TextBox(
                       controller: controllers[key],
                       readOnly: isReadOnly,
                       enabled: !isReadOnly, 
                     ),
                   ),
                 );
               }).toList(),
             ),
           ),
           actions: [
             Button(
               child: const Text('Cancelar'),
               onPressed: () => Navigator.pop(context),
             ),
             FilledButton(
               child: const Text('Guardar'),
               onPressed: () {
                 Map<String, dynamic> updatedData = {};
                 controllers.forEach((k, v) {
                   updatedData[k] = v.text;
                 });
                 
                 Navigator.pop(context); // Cerrar diálogo
                 _updateMaterial(updatedData); // Enviar al backend
               },
             ),
           ],
         );
       }
     );
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: PageHeader(
        title: const Text('Catálogo Maestro Avanzado'),
        commandBar: mapCommandBar(),
      ),
      content: _buildContent(),
      bottomBar: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        color: Colors.grey.withValues(alpha: 0.05),
        child: Text(
          'Registros Mostrados: ${_filteredData.length} / ${_allData.length}',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  CommandBar mapCommandBar() {
    return CommandBar(
      primaryItems: [
        CommandBarButton(
          icon: const Icon(FluentIcons.refresh),
          label: const Text('Refrescar'),
          onPressed: _fetchData,
        ),
        // Toggle: Solo con Plano
        CommandBarButton(
          key: ValueKey('toggle_plano_$_onlyWithPlano'),
          onPressed: () {
            setState(() {
              _onlyWithPlano = !_onlyWithPlano;
              _applyFilters();
            });
          },
          icon: ToggleSwitch(
            checked: _onlyWithPlano,
            onChanged: (v) {
              setState(() {
                _onlyWithPlano = v;
                _applyFilters();
              });
            },
          ),
          label: const Text("Plano/Drive"),
        ),
         // Botón Columnas (Flyout)
        CommandBarButton(
          icon: FlyoutTarget(
            controller: _flyoutController,
            child: const Icon(FluentIcons.column_options),
          ),
          label: const Text('Columnas'),
          onPressed: () {
            _flyoutController.showFlyout(
              autoModeConfiguration: FlyoutAutoConfiguration(
                preferredMode: FlyoutPlacementMode.bottomCenter,
              ),
              barrierDismissible: true,
              dismissOnPointerMoveAway: false,
              builder: (context) {
                return FlyoutContent(
                  child: SizedBox(
                    width: 250,
                    height: 300,
                    child: StatefulBuilder(
                      builder: (context, setFlyoutState) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Padding(
                              padding: EdgeInsets.all(8.0),
                              child: Text('Mostrar Columnas', style: TextStyle(fontWeight: FontWeight.bold)),
                            ),
                            const Divider(),
                            Expanded(
                              child: ListView.builder(
                                itemCount: _columns.length,
                                itemBuilder: (context, index) {
                                  final col = _columns[index];
                                  final isChecked = _visibleColumns[col] ?? false;
                                  
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                                    child: Row(
                                      children: [
                                        Checkbox(
                                          checked: isChecked,
                                          onChanged: (v) {
                                            // Actualizar estado global
                                            setState(() {
                                              _visibleColumns[col] = v ?? false;
                                            });
                                            // Actualizar estado local del Flyout
                                            setFlyoutState(() {});
                                          },
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(col.replaceAll('_', ' ')),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        );
                      }
                    ),
                  ),
                );
              },
            );
          },
        ),
        CommandBarButton(
          icon: const Icon(FluentIcons.clear_filter),
          label: const Text('Limpiar Filtros'),
          onPressed: _clearFilters,
        ),
        CommandBarButton(
          icon: const Icon(FluentIcons.excel_logo),
          label: const Text('Exportar Vista'),
          onPressed: _filteredData.isNotEmpty ? _exportToExcel : null,
        ),
      ],
    );
  }

  Widget _buildContent() {
    if (_isLoading) {
      return const Center(child: ProgressRing());
    }

    if (_errorMessage != null) {
      return Center(
        child: InfoBar(
          title: const Text('Error'),
          content: Text(_errorMessage!),
          severity: InfoBarSeverity.error,
          action: Button(onPressed: _fetchData, child: const Text('Reintentar')),
        ),
      );
    }

    if (_allData.isEmpty) {
      return const Center(child: Text('No hay datos disponibles en la base de datos.'));
    }

    // Calcular columnas visibles activas
    final activeCols = _columns.where((c) => _visibleColumns[c] == true).toList();
    
    if (activeCols.isEmpty) {
      return const Center(child: Text('Seleccione al menos una columna para visualizar.'));
    }

    return Padding(
      padding: const EdgeInsets.all(10.0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Ancho estimado: columas * 180 + 120 (Acciones mejoradas)
          final minWidth = (activeCols.length * 180.0) + 120.0;
          final viewWidth = minWidth > constraints.maxWidth ? minWidth : constraints.maxWidth;
          
          return Scrollbar(
            controller: _horizontalScrollController,
            thumbVisibility: true,
            style: const ScrollbarThemeData(thickness: 10),
            child: SingleChildScrollView(
              controller: _horizontalScrollController,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: viewWidth,
                child: Column(
                  children: [
                    _buildHeaderRow(activeCols),
                    const Divider(),
                    Expanded(
                      child: ListView.builder(
                        itemCount: _filteredData.length,
                        itemBuilder: (context, index) {
                          final row = _filteredData[index];
                          return _buildDataRow(row, index, activeCols);
                        },
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
    return Container(
      color: Colors.blue.withValues(alpha: 0.1),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          // Columna Fija: Acciones
          const SizedBox(
            width: 120, // Más ancha para Edit + Link + Copy
            child: Center(
              child: Text(
                'Acciones',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ), 
          
          // Columnas Visibles
          ...activeCols.map((col) {
            return SizedBox(
              width: 180,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      col.replaceAll('_', ' '),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 5),
                    TextBox(
                      controller: _filterControllers[col],
                      placeholder: 'Filtrar...',
                      style: const TextStyle(fontSize: 12),
                      onChanged: (value) => _applyFilters(),
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildDataRow(Map<String, dynamic> row, int index, List<String> activeCols) {
    final color = index % 2 == 0 ? Colors.transparent : Colors.grey.withValues(alpha: 0.03);
    
    final codigo = row['Codigo_Pieza']?.toString() ?? row['Codigo']?.toString() ?? '?';
    
    // Check Drive Link
    final linkDrive = row.containsKey('Link_Drive') ? row['Link_Drive']?.toString() : null;
    final hasLink = linkDrive != null && linkDrive.isNotEmpty && linkDrive != '-';

    return GestureDetector(
      onDoubleTap: () => _openPlano(codigo),
      child: Container(
        color: color,
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            // Columna Fija: Acciones (Copiar + Edit + Drive)
            SizedBox(
              width: 120,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Copiar
                  Tooltip(
                    message: 'Copiar Código',
                    child: IconButton(
                      icon: const Icon(FluentIcons.copy, size: 14),
                      onPressed: () => _copyToClipboard(codigo),
                    ),
                  ),

                  // Edit
                   Tooltip(
                    message: 'Editar Registro',
                    child: IconButton(
                      icon: const Icon(FluentIcons.edit, size: 14),
                      onPressed: () => _showEditDialog(row),
                    ),
                  ),

                  // Drive (Condicional)
                  if (hasLink)
                    Tooltip(
                      message: 'Ver en Drive',
                      child: IconButton(
                        icon: Icon(FluentIcons.cloud_link, size: 18, color: Colors.blue),
                        onPressed: () async {
                           if (await canLaunchUrl(Uri.parse(linkDrive))) {
                             await launchUrl(Uri.parse(linkDrive));
                           } else {
                             _showInfoBar('Error', 'Link inválido', InfoBarSeverity.error);
                           }
                        },
                      ),
                    )
                  else
                    const SizedBox(width: 25), // Espaciador para alinear
                ],
              ),
            ),
            
            // Datos
            ...activeCols.map((col) {
              return SizedBox(
                width: 180,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0),
                  child: Text(
                    row[col]?.toString() ?? '-',
                    style: const TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}
