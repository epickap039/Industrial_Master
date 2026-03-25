import 'dart:io';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart'; // Clipboard
import 'package:url_launcher/url_launcher.dart';
import 'package:excel/excel.dart' as excel_lib;
import 'package:file_picker/file_picker.dart';
import '../utils/excel_helper.dart';
import '../services/api_client.dart';
import '../widgets/compact_page_header.dart';

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

  String _userRole = 'USER';

  @override
  void initState() {
    super.initState();
    _loadRole();
    _fetchData();
  }

  Future<void> _loadRole() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _userRole = prefs.getString('rol') ?? 'USER';
      });
    }
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
      if (mounted)
        setState(() {
          _isLoading = true;
          _errorMessage = null;
        });
    }

    try {
      final jsonList = await ApiClient.get('/api/catalog') as List<dynamic>;
      List<Map<String, dynamic>> data = List<Map<String, dynamic>>.from(
        jsonList,
      );

      if (data.isNotEmpty) {
          List<String> allKeys = data.first.keys.toList();
          allKeys.remove('Link_Drive'); // Metadata interna
          
          // Reordenar Espesor_Perfil_CAD después de Ancho_CAD
          if (allKeys.contains('Espesor_Perfil_CAD') && allKeys.contains('Ancho_CAD')) {
            allKeys.remove('Espesor_Perfil_CAD');
            final indexOfAncho = allKeys.indexOf('Ancho_CAD');
            allKeys.insert(indexOfAncho + 1, 'Espesor_Perfil_CAD');
          }
          
          _columns = allKeys;

          if (_visibleColumns.isEmpty) {
            // Columnas ocultas por defecto (ruido técnico).
            // Descripcion oculta: el foco operativo es Material; la descripción
            // sigue disponible en el selector de columnas y en búsqueda/filtros.
            const hiddenByDefault = {
              'Descripcion',
              'Modificado_Por',
              'Ultima_Actualizacion',
              'Fecha_Creacion',
              'Simetria',
              'Tiene_DXF',
              'Largo_DXF',
              'Ancho_DXF',
            };
            for (var col in _columns) {
              _visibleColumns[col] = !hiddenByDefault.contains(col);
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
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Error servidor: ${e.statusCode}';
          _isLoading = false;
        });
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

  List<Map<String, dynamic>> _computeFilteredRows() {
    return _allData.where((row) {
      if (_onlyWithPlano) {
        final link = row['Link_Drive']?.toString();
        if (link == null || link.isEmpty || link == '-') return false;
      }

      for (var entry in _filterControllers.entries) {
        final filterText = entry.value.text.trim().toLowerCase();
        if (filterText.isEmpty) continue;
        final col = entry.key;
        final cellValue = row[col]?.toString().toLowerCase() ?? '';
        if (!cellValue.contains(filterText)) return false;
      }
      return true;
    }).toList();
  }

  /// Aplica filtros locales usando solo los controladores persistentes por columna.
  void _applyFilters({bool resetScroll = true}) {
    final next = _computeFilteredRows();
    setState(() {
      _filteredData = next;
    });

    if (resetScroll &&
        _filteredData.isNotEmpty &&
        _verticalScrollController.hasClients) {
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
            return _ordenAscendente
                ? dateA.compareTo(dateB)
                : dateB.compareTo(dateA);
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
    final headerStyle = ExcelHelper.getHeaderStyle();
    excel_lib.Sheet sheetObject = excel['Catálogo'];
    excel.delete('Sheet1');

    final exportCols = _columns.where((c) {
      if (_visibleColumns[c] != true) return false;
      if (_userRole == 'QA' &&
          (c == 'Ruta_Archivo' ||
              c == 'Ruta_Plano' ||
              c == 'Link_Drive' ||
              c == 'Ruta' ||
              c == 'Modificado_Por' ||
              c == 'Autor' ||
              c == 'Ultima_Actualizacion' ||
              c == 'Fecha_Creacion')) {
        return false;
      }
      return true;
    }).toList();

    Map<int, int> colWidths = {};

    for (int i = 0; i < exportCols.length; i++) {
        sheetObject.updateCell(
            excel_lib.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0),
            excel_lib.TextCellValue(exportCols[i]),
            cellStyle: headerStyle,
        );
        ExcelHelper.updateMaxWith(colWidths, i, exportCols[i]);
    }

    for (int r = 0; r < _filteredData.length; r++) {
      var row = _filteredData[r];
      for (int c = 0; c < exportCols.length; c++) {
        String colName = exportCols[c];
        excel_lib.CellValue value;
        
        // Identificamos columnas numéricas para limpieza estricta
        if (colName.toLowerCase().contains('area') || 
            colName.toLowerCase().contains('largo') || 
            colName.toLowerCase().contains('ancho') ||
            colName.toLowerCase().contains('espesor') ||
            colName.toLowerCase().contains('cantidad')) {
            value = excel_lib.DoubleCellValue(ExcelHelper.cleanToDouble(row[colName]));
        } else if (colName.toLowerCase() == 'medida') {
            value = ExcelHelper.parseDynamicCell(row[colName]);
        } else {
            value = excel_lib.TextCellValue(row[colName]?.toString() ?? '-');
        }

        sheetObject.updateCell(
            excel_lib.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r + 1),
            value,
        );
        ExcelHelper.updateMaxWith(colWidths, c, value.toString());
      }
    }

    ExcelHelper.applyAutoFit(sheetObject, colWidths);

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
          displayInfoBar(
            context,
            builder: (context, close) {
              return InfoBar(
                title: const Text('Exportado'),
                content: Text('Guardado en: $outputFile'),
                severity: InfoBarSeverity.success,
                onClose: close,
              );
            },
          );
        }
      }
    }
  }

  /// Guarda cambios - Payload Completo
  Future<void> _updateMaterial(
    Map<String, dynamic> row,
    Map<String, dynamic> updates,
  ) async {
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
        'Modificado_Por': username,
      };

      // 3. Enviar al Backend
      await ApiClient.put('/api/material/update', body: body);

      if (mounted) {
        displayInfoBar(
          context,
          builder: (context, close) {
            return InfoBar(
              title: const Text('Guardado Exitoso'),
              content: const Text('Registro actualizado correctamente.'),
              severity: InfoBarSeverity.success,
              onClose: close,
            );
          },
        );
      }
    } catch (e) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) {
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
                    onPressed:
                        () => Clipboard.setData(
                          ClipboardData(text: e.toString()),
                        ),
                  ),
                ],
              ),
              actions: [
                Button(
                  child: const Text('Ok'),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            );
          },
        );
      }
      // Revertir cambios (sin mover scroll)
      _fetchData(showLoading: false);
    }
  }

  Future<void> _deleteMaterial(String codigo) async {
    showDialog(
      context: context,
      builder: (context) {
        return ContentDialog(
          title: const Text('Confirmar Eliminación'),
          content: Text('¿Estás seguro de que deseas eliminar permanentemente la pieza $codigo? Esta acción no se puede deshacer.'),
          actions: [
            Button(
              child: const Text('Cancelar'),
              onPressed: () => Navigator.pop(context),
            ),
            FilledButton(
              child: const Text('Eliminar'),
              style: ButtonStyle(backgroundColor: ButtonState.all(Colors.red)),
              onPressed: () async {
                Navigator.pop(context);
                try {
                  await ApiClient.delete('/api/catalog/$codigo');
                  if (!mounted) return;
                  _fetchData();
                  displayInfoBar(
                    context,
                    builder: (context, close) {
                      return InfoBar(
                        title: const Text('Eliminada'),
                        content: Text('La pieza $codigo ha sido eliminada.'),
                        severity: InfoBarSeverity.success,
                        onClose: close,
                      );
                    },
                  );
                } catch (e) {
                  displayInfoBar(
                    context,
                    builder: (context, close) {
                      return InfoBar(
                        title: const Text('Error al eliminar'),
                        content: Text(e.toString()),
                        severity: InfoBarSeverity.error,
                        onClose: close,
                      );
                    },
                  );
                }
              },
            ),
          ],
        );
      },
    );
  }

  /// Diálogo de Edición COMPLETO (Incluye Proceso 3)
  void _showEditDialog(Map<String, dynamic> row) {
    // Controladores para todos los campos
    final descCtrl = TextEditingController(
      text: row['Descripcion']?.toString() ?? '',
    );
    final medCtrl = TextEditingController(
      text: row['Medida']?.toString() ?? '',
    );
    final matCtrl = TextEditingController(
      text: row['Material']?.toString() ?? '',
    );
    final linkCtrl = TextEditingController(
      text: row['Link_Drive']?.toString() ?? '',
    );
    // Nuevos Campos
    final simetriaCtrl = TextEditingController(
      text: row['Simetria']?.toString() ?? '',
    );
    final procPrimCtrl = TextEditingController(
      text: row['Proceso_Primario']?.toString() ?? '',
    );
    final proc1Ctrl = TextEditingController(
      text: row['Proceso_1']?.toString() ?? '',
    );
    final proc2Ctrl = TextEditingController(
      text: row['Proceso_2']?.toString() ?? '',
    );
    final proc3Ctrl = TextEditingController(
      text: row['Proceso_3']?.toString() ?? '',
    );

    showDialog(
      context: context,
      builder: (context) {
        return ContentDialog(
          constraints: const BoxConstraints(maxWidth: 600), // Diálogo más ancho
          title: Text(
            "Editor Maestro: ${row['Codigo_Pieza'] ?? row['Codigo']}",
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InfoLabel(
                  label: 'Descripción',
                  child: TextBox(controller: descCtrl, maxLines: 2),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: InfoLabel(
                        label: 'Medida',
                        child: TextBox(controller: medCtrl),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: InfoLabel(
                        label: 'Material',
                        child: TextBox(controller: matCtrl),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: InfoLabel(
                        label: 'Simetría',
                        child: TextBox(controller: simetriaCtrl),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: InfoLabel(
                        label: 'Proceso Primario',
                        child: TextBox(controller: procPrimCtrl),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: InfoLabel(
                        label: 'Proceso 1',
                        child: TextBox(controller: proc1Ctrl),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: InfoLabel(
                        label: 'Proceso 2',
                        child: TextBox(controller: proc2Ctrl),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                InfoLabel(
                  label: 'Proceso 3',
                  child: TextBox(controller: proc3Ctrl),
                ),
                const SizedBox(height: 8),
                InfoLabel(
                  label: 'Link Drive / Plano',
                  child: TextBox(controller: linkCtrl),
                ),
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
      },
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
                _buildLabelValue(
                  "CODIGO PIEZA",
                  row['Codigo_Pieza'] ?? row['Codigo'],
                ),
                const Divider(),
                _buildLabelValue("DESCRIPCIÓN", row['Descripcion']),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(child: _buildLabelValue("MEDIDA", row['Medida'])),
                    Expanded(
                      child: _buildLabelValue("MATERIAL", row['Material']),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(child: _buildLabelValue("LARGO CAD", row['Largo_CAD'])),
                    Expanded(child: _buildLabelValue("ANCHO CAD", row['Ancho_CAD'])),
                    Expanded(child: _buildLabelValue("ESPESOR / PERFIL", row['Espesor_Perfil_CAD'])),
                  ],
                ),
                Row(
                  children: [
                    Expanded(child: _buildLabelValue("TIENE DXF", row['Tiene_DXF'])),
                    Expanded(child: _buildLabelValue("LARGO DXF", row['Largo_DXF'])),
                    Expanded(child: _buildLabelValue("ANCHO DXF", row['Ancho_DXF'])),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: _buildLabelValue("SIMETRÍA", row['Simetria']),
                    ),
                    Expanded(
                      child: _buildLabelValue(
                        "PROC. PRIMARIO",
                        row['Proceso_Primario'],
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: _buildLabelValue("PROC. 1", row['Proceso_1']),
                    ),
                    Expanded(
                      child: _buildLabelValue("PROC. 2", row['Proceso_2']),
                    ),
                    Expanded(
                      child: _buildLabelValue("PROC. 3", row['Proceso_3']),
                    ),
                  ],
                ),
                const Divider(),
                if (_userRole != 'QA') ...[
                  _buildLabelValue("LINK PLANO", row['Link_Drive']),
                  const Divider(),
                  _buildLabelValue("Modificado Por", row['Modificado_Por']),
                  _buildLabelValue(
                    "Última Actualización",
                    row['Ultima_Actualizacion'],
                  ),
                ],
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
      },
    );
  }

  void _launchDriveLink(String? url) async {
    if (url == null || url.isEmpty || url == '-') return;

    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      displayInfoBar(
        context,
        builder: (context, close) {
          return InfoBar(
            title: const Text('Error'),
            content: Row(
              children: [
                const Expanded(
                  child: SelectableText('Link inválido o inaccesible.'),
                ),
                IconButton(
                  icon: const Icon(FluentIcons.copy),
                  onPressed:
                      () => Clipboard.setData(
                        ClipboardData(text: 'Link inválido o inaccesible.'),
                      ),
                ),
              ],
            ),
            severity: InfoBarSeverity.error,
            onClose: close,
          );
        },
      );
    }
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    displayInfoBar(
      context,
      builder: (context, close) {
        return InfoBar(
          title: const Text('Copiado'),
          content: Text(text),
          severity: InfoBarSeverity.info,
          onClose: close,
        );
      },
    );
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
              children: List<Widget>.from(
                _columns.map((col) {
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
                }),
              ),
            ),
          ),
          actions: [
            Button(
              child: const Text('Cerrar'),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        );
      },
    );
  }

  Widget _buildLabelValue(String label, dynamic value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: Colors.blue,
              fontWeight: FontWeight.bold,
            ),
          ),
          SelectableText(
            value?.toString() ?? '-',
            style: TextStyle(fontSize: 13),
          ),
        ],
      ),
    );
  }

  Future<void> _searchDXF() async {
    final TextEditingController searchController = TextEditingController();
    final TextEditingController pathController = TextEditingController();
    bool isSearching = false;

    final prefs = await SharedPreferences.getInstance();
    pathController.text = prefs.getString('dxf_master_path') ?? r'C:\Libreria_DXF';

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return ContentDialog(
              title: const Text('Buscador Rápido DXF / DWG'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Ruta Maestra de Búsqueda (Red/Local):'),
                  const SizedBox(height: 8),
                  TextBox(
                    controller: pathController,
                    placeholder: r'Ej. C:\Libreria_DXF',
                    suffix: IconButton(
                      icon: const Icon(FluentIcons.folder_open),
                      onPressed: () async {
                        String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
                        if (selectedDirectory != null) {
                           pathController.text = selectedDirectory.replaceAll('/', r'\');
                        }
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text('Ingresa el código de la pieza:'),
                  const SizedBox(height: 12),
                  TextBox(
                    controller: searchController,
                    placeholder: 'Ej. PTR-L200-XZ',
                    autofocus: true,
                    suffix: IconButton(
                      icon: const Icon(FluentIcons.paste),
                      onPressed: () async {
                        final data = await Clipboard.getData(Clipboard.kTextPlain);
                        if (data != null && data.text != null) {
                          searchController.text = data.text!;
                        }
                      },
                    ),
                  ),
                  if (isSearching)
                    const Padding(
                      padding: EdgeInsets.only(top: 12.0),
                      child: ProgressRing(),
                    ),
                ],
              ),
              actions: [
                Button(
                  child: const Text('Cerrar'),
                  onPressed: () => Navigator.pop(context),
                ),
                FilledButton(
                  onPressed: isSearching ? null : () async {
                    if (searchController.text.isEmpty || pathController.text.isEmpty) return;
                    
                    final plainPath = pathController.text.trim().replaceAll('"', '').replaceAll("'", "");
                    await prefs.setString('dxf_master_path', plainPath);
                    setStateDialog(() => isSearching = true);
                    
                    try {
                      final req = await ApiClient.getUnvalidated(
                        '/api/dxf/search/${searchController.text.trim()}',
                        queryParameters: {'base_path': plainPath},
                      );
                      setStateDialog(() => isSearching = false);
                      if (req.statusCode == 200) {
                        final data = req.decodeJson() as Map<String, dynamic>;
                        final dxfPath = data['dxf_path'];
                        if (!context.mounted) return;
                        Navigator.pop(context); // close search dialog
                        // show success
                        showDialog(context: context, builder: (ctx) => ContentDialog(
                          title: const Text('Archivo Encontrado'),
                          content: Text('Ruta: $dxfPath'),
                          actions: [
                            Button(child: const Text('Cerrar'), onPressed: () => Navigator.pop(ctx)),
                            FilledButton(child: const Text('Abrir Ubicación'), onPressed: () {
                              Process.run('explorer.exe', ['/select,', dxfPath]);
                              Navigator.pop(ctx);
                            }),
                          ]
                        ));
                      } else {
                        final err = req.decodeJson();
                        final detail = err is Map
                            ? (err['detail'] ?? 'No se encontraron archivos válidos.').toString()
                            : 'No se encontraron archivos válidos.';
                        if (!context.mounted) return;
                        displayInfoBar(
                          context, 
                          builder: (c, close) => InfoBar(
                            title: const Text('No encontrado'), 
                            content: Text(detail), 
                            severity: InfoBarSeverity.warning, 
                            onClose: close
                          )
                        );
                      }
                    } catch (e) {
                       setStateDialog(() => isSearching = false);
                       displayInfoBar(
                         context, 
                         builder: (c, close) => InfoBar(
                           title: const Text('Error de Red'), 
                           content: Text(e.toString()), 
                           severity: InfoBarSeverity.error, 
                           onClose: close
                         )
                       );
                    }
                  },
                  child: const Text('Buscar'),
                ),
              ],
            );
          }
        );
      }
    );
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      padding: EdgeInsets.zero,
      header: CompactPageHeader(
        title: Text(
          'Catálogo Maestro',
          style: FluentTheme.of(context).typography.title,
        ),
        commandBar: _buildCommandBar(),
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [Expanded(child: _buildContent())],
      ),
      bottomBar: Container(
        padding: const EdgeInsets.all(10),
        child: Text('Registros: ${_filteredData.length} / ${_allData.length}'),
      ),
    );
  }

  Widget _buildCommandBar() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ToggleSwitch(
          checked: _onlyWithPlano,
          content: Text(_onlyWithPlano ? 'Con Plano/Drive' : 'Todos'),
          onChanged: (v) {
            setState(() => _onlyWithPlano = v);
            _applyFilters();
          },
        ),
        Tooltip(
          message: "Seleccionar Columnas",
          child: IconButton(
            icon: const Icon(FluentIcons.column_options),
            onPressed: _showColumnSelector,
          ),
        ),
        Tooltip(
          message: "Refrescar Datos",
          child: IconButton(
            icon: const Icon(FluentIcons.refresh),
            onPressed: _fetchData,
          ),
        ),
        Tooltip(
          message: "Limpiar Filtros",
          child: IconButton(
            icon: const Icon(FluentIcons.clear_filter),
            onPressed: _clearFilters,
          ),
        ),
        if (_userRole != 'QA')
          Tooltip(
            message: "Buscar DXF",
            child: Button(
              onPressed: _searchDXF,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(FluentIcons.search),
                  SizedBox(width: 8),
                  Text('Buscar DXF'),
                ],
              ),
            ),
          ),
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
    switch (col) {
      case 'Codigo_Pieza':
      case 'Codigo':         return 120.0;
      case 'Descripcion':    return 250.0;
      case 'Medida':         return 100.0;
      case 'Material':       return 160.0;
      case 'Proceso_Primario': return 135.0;
      case 'Proceso_1':
      case 'Proceso_2':
      case 'Proceso_3':      return 100.0;
      case 'Largo_CAD':
      case 'Ancho_CAD':      return  90.0;
      case 'Espesor_Perfil_CAD': return 120.0;
      case 'Tiene_DXF':      return  80.0;
      case 'Largo_DXF':
      case 'Ancho_DXF':      return  90.0;
      default:               return 130.0;
    }
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
              onPressed:
                  () => Clipboard.setData(ClipboardData(text: _errorMessage!)),
            ),
            const Text(
              "Copiar Error",
              style: TextStyle(fontSize: 10, color: Colors.grey),
            ),
          ],
        ),
      );
    }
    if (_allData.isEmpty) return const Center(child: Text('Sin datos.'));

    final activeCols = _columns.where((c) {
      if (_visibleColumns[c] != true) return false;
      if (_userRole == 'QA' &&
          (c == 'Ruta_Archivo' ||
              c == 'Ruta_Plano' ||
              c == 'Link_Drive' ||
              c == 'Ruta' ||
              c == 'Modificado_Por' ||
              c == 'Autor' ||
              c == 'Ultima_Actualizacion' ||
              c == 'Fecha_Creacion')) {
        return false;
      }
      return true;
    }).toList();

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
            ),
          ],
        ),
        padding: const EdgeInsets.all(8.0),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final double actionsWidth = 145.0;
            final double colsWidth = activeCols.fold(
              0.0,
              (sum, col) => sum + _getColumnWidth(col),
            );
            final minWidth = colsWidth + actionsWidth;
            final viewWidth =
                minWidth > constraints.maxWidth
                    ? minWidth
                    : constraints.maxWidth;

            // 1. ELIMINAR EXPANDED REDUNDANTES (Se quitó el Expanded raíz que causaba el crash en ScaffoldPage)
            // 2. Y 3. ORDEN CORRECTO CON LISTA PEREZOSA PARA 60 FPS
            return Scrollbar(
              controller: _verticalScrollController,
              thumbVisibility: true,
              interactive: true,
              style: const ScrollbarThemeData(
                thickness: 14.0, // Industrial
                radius: Radius.circular(4),
              ),
              child: FluentTheme(
                data: FluentTheme.of(context).copyWith(
                  scrollbarTheme: ScrollbarThemeData(
                    backgroundColor: FluentTheme.of(context).cardColor,
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
                      padding: const EdgeInsets.only(
                        bottom: 20.0,
                      ), // Carril exclusivo inferior
                      child: SizedBox(
                        width: viewWidth,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildHeaderRow(activeCols, actionsWidth),
                            const SizedBox(height: 8), // Separación justa (8px)
                            const Divider(),
                            // Expanded hijo válido de Column, que NO hace scroll.
                            // Esto habilita ListView como renderizado perezoso (60 FPS puros).
                            Expanded(
                              child: ListView.builder(
                                controller:
                                    _verticalScrollController, // Vinculado al Scrollbar vertical maestro
                                itemCount: _filteredData.length,
                                itemBuilder: (context, index) {
                                  return _buildDataRow(
                                    _filteredData[index],
                                    index,
                                    activeCols,
                                    actionsWidth,
                                  );
                                },
                              ),
                            ),
                          ],
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
    final theme = FluentTheme.of(context);
    final filterTextStyle =
        theme.typography.body?.copyWith(fontSize: 12) ??
        TextStyle(fontSize: 12, color: theme.resources.textFillColorPrimary);

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
                          col == 'Espesor_Perfil_CAD' ? 'Espesor / Long. Perfil' : col.replaceAll('_', ' '),
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 12.0,
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                      Tooltip(
                        message: 'Ordenar por $col',
                        child: IconButton(
                          icon: Icon(
                            _columnaOrden == col
                                ? (_ordenAscendente
                                    ? FluentIcons.sort_up
                                    : FluentIcons.sort_down)
                                : FluentIcons.sort,
                            size: 10,
                          ),
                          onPressed: () => _ordenarTabla(col),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(
                    height: 4.0,
                  ), // Separación justa sin paddings extra
                  SizedBox(
                    width: _getColumnWidth(col),
                    child: TextBox(
                      key: ValueKey('catalog_col_filter_$col'),
                      controller: _filterControllers[col]!,
                      placeholder: 'Buscar',
                      style: filterTextStyle,
                      onChanged: (_) =>
                          _applyFilters(resetScroll: false),
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ],
    );
  }

  Widget _buildDataRow(
    Map<String, dynamic> row,
    int index,
    List<String> activeCols,
    double actionsWidth,
  ) {
    final hasLink =
        row['Link_Drive'] != null &&
        row['Link_Drive'].toString().isNotEmpty &&
        row['Link_Drive'].toString() != '-';

    return Container(
      color:
          index % 2 == 0 ? Colors.transparent : Colors.black.withOpacity(0.03),
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
                    icon: Icon(
                      FluentIcons.info,
                      size: 14,
                      color: Colors.blue,
                    ), // BLUE
                    onPressed: () => _showInfoDetails(row),
                  ),
                ),
                if (_userRole == 'ADMIN')
                  Tooltip(
                    message: 'Editar',
                    child: IconButton(
                      icon: Icon(
                        FluentIcons.edit,
                        size: 14,
                        color: Colors.orange,
                      ), // NARANJA VIBRANTE
                      onPressed: () => _showEditDialog(row),
                    ),
                  ),

                if (hasLink)
                  Tooltip(
                    message: 'Abrir Drive/Plano',
                    child: IconButton(
                      icon: Icon(
                        FluentIcons.cloud,
                        size: 14,
                        color: Colors.teal,
                      ), // TEAL (VERDE PASTEL VIBRANTE)
                      onPressed:
                          () => _launchDriveLink(row['Link_Drive']?.toString()),
                    ),
                  )
                else
                  const SizedBox(width: 30),

                Tooltip(
                  message: 'Copiar Código',
                  child: IconButton(
                    icon: Icon(
                      FluentIcons.copy,
                      size: 14,
                      color: Colors.magenta,
                    ), // MAGENTA/MORADO PARA RESALTAR
                    onPressed: () {
                      final codigoCopiar = row['Codigo_Pieza']?.toString() ?? row['Codigo']?.toString() ?? '';
                      Clipboard.setData(ClipboardData(text: codigoCopiar));
                      displayInfoBar(
                        context,
                        builder: (context, close) {
                          return InfoBar(
                            title: const Text('Código Copiado'),
                            content: Text(codigoCopiar),
                            severity: InfoBarSeverity.success,
                            onClose: close,
                          );
                        },
                      );
                    },
                  ),
                ),
                if (_userRole == 'ADMIN')
                  Tooltip(
                    message: 'Eliminar Pieza',
                    child: IconButton(
                      icon: Icon(
                        FluentIcons.delete,
                        size: 14,
                        color: Colors.red,
                      ),
                      onPressed: () => _deleteMaterial(row['Codigo_Pieza']?.toString() ?? row['Codigo']?.toString() ?? ''),
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
