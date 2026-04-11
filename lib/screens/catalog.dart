import 'dart:async';
import 'dart:io';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart'; // Clipboard
import 'package:url_launcher/url_launcher.dart';
import 'package:excel/excel.dart' as excel_lib;
import 'package:file_picker/file_picker.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import '../utils/excel_helper.dart';
import '../services/api_client.dart';
import '../services/app_role.dart';
import '../theme/ui_tokens.dart';
import '../widgets/compact_page_header.dart';
import '../widgets/contextual_bug_report.dart';

class CatalogScreen extends StatefulWidget {
  const CatalogScreen({super.key, this.effectiveRole});

  /// Rol efectivo (incluye simulacion de rol en admin).
  final String? effectiveRole;

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
  int? _stockPtOrphansCount;
  bool _stockPtSyncBusy = false;
  bool _stockPtOrphansBusy = false;
  Timer? _stockPtAutoSyncTimer;
  DateTime? _lastStockPtAutoSyncAt;
  static const Duration _stockPtAutoSyncEvery = Duration(minutes: 5);

  // Ordenamiento
  String _columnaOrden = "";
  bool _ordenAscendente = true;

  String _userRole = 'USER';
  final Map<String, Set<String>> _selectedValueFilters = {};

  @override
  void initState() {
    super.initState();
    _loadRoleFromContext();
    _fetchData();
  }

  @override
  void didUpdateWidget(covariant CatalogScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.effectiveRole != widget.effectiveRole) {
      _loadRoleFromContext();
    }
  }

  Future<void> _loadRoleFromContext() async {
    final explicit = widget.effectiveRole?.trim();
    if (explicit != null && explicit.isNotEmpty) {
      if (mounted) {
        setState(() => _userRole = explicit);
        _configureStockPtAutoSync();
      }
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _userRole = prefs.getString('rol') ?? 'USER';
      });
      _configureStockPtAutoSync();
    }
  }

  String _normalizeColumnKey(String c) {
    return c.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  bool _isRutaPrivadaColumn(String c) {
    final n = _normalizeColumnKey(c);
    return n == 'rutarchivo' ||
        n == 'rutaarchivo' ||
        n == 'rutaplano' ||
        n == 'ruta' ||
        n == 'linkdrive' ||
        n.contains('rutaarchivo') ||
        n.contains('rutaplano');
  }

  bool _excludeColumnForRole(String c) {
    final ar = parseAppRole(_userRole);
    final norm = _normalizeColumnKey(c);
    if (ar == AppRole.qaLegacy) {
      return const {
        'rutaarchivo',
        'rutaplano',
        'linkdrive',
        'ruta',
        'modificadopor',
        'autor',
        'ultimaactualizacion',
        'fechacreacion',
      }.contains(norm);
    }
    if (ar.catalogHideModificadoPor && norm == 'modificadopor') return true;
    if (ar == AppRole.produccion &&
        const {
          'modificadopor',
          'rutaarchivo',
          'rutaplano',
          'tienedxf',
          'largodxf',
          'anchodxf',
        }.contains(norm)) {
      return true;
    }
    if (ar.catalogHideRutaArchivo && _isRutaPrivadaColumn(c)) {
      return true;
    }
    if (ar.catalogHideFechaModificacion &&
        (norm == 'ultimaactualizacion' || norm == 'fechacreacion')) {
      return true;
    }
    if (ar.catalogHideDxfColumns &&
        (norm == 'tienedxf' || norm == 'largodxf' || norm == 'anchodxf')) {
      return true;
    }
    if (!ar.catalogShowsStockPtAlmacen &&
        (norm == 'stockptalmacen' || norm == 'stockptalmacensyncat')) {
      return true;
    }
    return false;
  }

  @override
  void dispose() {
    _stockPtAutoSyncTimer?.cancel();
    _horizontalScrollController.dispose();
    _verticalScrollController.dispose();
    for (var controller in _filterControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _configureStockPtAutoSync() {
    final canAutoSync = parseAppRole(_userRole).catalogShowsStockPtAlmacen;
    if (!canAutoSync) {
      _stockPtAutoSyncTimer?.cancel();
      _stockPtAutoSyncTimer = null;
      return;
    }
    _stockPtAutoSyncTimer ??= Timer.periodic(_stockPtAutoSyncEvery, (_) {
      unawaited(
        _syncStockPtDesdeHoja(
          showSuccessNotification: false,
          showErrorNotification: true,
          showProgressDialog: false,
        ),
      );
    });
    final last = _lastStockPtAutoSyncAt;
    if (last == null || DateTime.now().difference(last) >= _stockPtAutoSyncEvery) {
      unawaited(
        _syncStockPtDesdeHoja(
          showSuccessNotification: false,
          showErrorNotification: true,
          showProgressDialog: false,
        ),
      );
    }
  }

  void _showStockPtInfo({
    required String title,
    required String message,
    required InfoBarSeverity severity,
  }) {
    if (!mounted) return;
    displayInfoBar(
      context,
      builder:
          (c, close) => InfoBar(
            title: Text(title),
            content: Text(message),
            severity: severity,
            onClose: close,
          ),
    );
  }

  String _stockPtApiErrorDetail(ApiException e, {required String action}) {
    final status = e.statusCode;
    final msg = e.message.trim().isEmpty ? 'Sin detalle del servidor.' : e.message;
    return 'Fallo en $action (HTTP $status): $msg';
  }

  Future<T> _runStockTaskWithProgress<T>({
    required String title,
    required String subtitle,
    required Future<T> Function() task,
  }) async {
    if (!mounted) return task();
    final started = DateTime.now();
    int elapsedSec = 0;
    void Function(void Function())? setProgressState;
    final timer = Timer.periodic(const Duration(seconds: 1), (_) {
      elapsedSec = DateTime.now().difference(started).inSeconds;
      setProgressState?.call(() {});
    });
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (ctx, setStateDialog) {
              setProgressState = setStateDialog;
              return ContentDialog(
                title: Text(title),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(subtitle),
                    const SizedBox(height: 10),
                    const ProgressBar(strokeWidth: 4),
                    const SizedBox(height: 10),
                    Text(
                      'Tiempo transcurrido: ${elapsedSec}s · Estimado: 3 a 20s',
                      style: fluentSecondaryTextStyle(context, fontSize: 11),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
    try {
      return await task();
    } finally {
      timer.cancel();
      if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
  }

  /// Carga conteo de codigos con stock en hoja que no estan en catalogo.
  Future<void> _refreshStockPtOrphansCount() async {
    if (!parseAppRole(_userRole).catalogShowsStockPtAlmacen) return;
    try {
      final raw = await ApiClient.get('/api/catalog/stock-pt/orphans');
      if (!mounted) return;
      if (raw is Map) {
        final c = raw['count'];
        final n = c is int ? c : int.tryParse('$c');
        setState(() => _stockPtOrphansCount = n);
      }
    } on ApiException catch (_) {
      if (mounted) setState(() => _stockPtOrphansCount = null);
    } catch (_) {
      if (mounted) setState(() => _stockPtOrphansCount = null);
    }
  }

  Future<void> _syncStockPtDesdeHoja({
    bool showSuccessNotification = true,
    bool showErrorNotification = true,
    bool showProgressDialog = true,
  }) async {
    if (!parseAppRole(_userRole).catalogShowsStockPtAlmacen) return;
    if (_stockPtSyncBusy) return;
    setState(() => _stockPtSyncBusy = true);
    try {
      final dynamic raw;
      if (showProgressDialog) {
        raw = await _runStockTaskWithProgress(
          title: 'Sincronizando stock PT',
          subtitle: 'Consultando hoja externa y actualizando catálogo maestro...',
          task: () => ApiClient.post('/api/catalog/stock-pt/sync'),
        );
      } else {
        raw = await ApiClient.post('/api/catalog/stock-pt/sync');
      }
      if (!mounted) return;
      _lastStockPtAutoSyncAt = DateTime.now();
      final msg =
          raw is Map
              ? 'Hoja: ${raw['filas_hoja'] ?? '?'} · Catálogo actualizado: ${raw['registros_catalogo_actualizados'] ?? '?'}'
              : 'Sincronizado';
      if (showSuccessNotification) {
        _showStockPtInfo(
          title: 'Stock PT sincronizado',
          message: msg,
          severity: InfoBarSeverity.success,
        );
      }
      await _fetchData(showLoading: false);
      await _refreshStockPtOrphansCount();
    } on ApiException catch (e) {
      if (showErrorNotification) {
        _showStockPtInfo(
          title: 'Error en sync stock PT',
          message: _stockPtApiErrorDetail(
            e,
            action: 'sincronizacion con hoja Inventario PT',
          ),
          severity: InfoBarSeverity.error,
        );
      }
    } catch (e) {
      if (showErrorNotification) {
        _showStockPtInfo(
          title: 'Error en sync stock PT',
          message: 'Fallo de conectividad o parseo local: $e',
          severity: InfoBarSeverity.error,
        );
      }
    } finally {
      if (mounted) setState(() => _stockPtSyncBusy = false);
    }
  }

  Future<void> _showStockPtOrphansDialog() async {
    if (!parseAppRole(_userRole).catalogShowsStockPtAlmacen) return;
    setState(() => _stockPtOrphansBusy = true);
    try {
      final raw = await _runStockTaskWithProgress(
        title: 'Buscando faltantes de catálogo',
        subtitle: 'Escaneando hoja externa vs catálogo maestro...',
        task: () => ApiClient.get('/api/catalog/stock-pt/orphans'),
      );
      if (!mounted) return;
      final items =
          raw is Map && raw['items'] is List
              ? List<Map<String, dynamic>>.from(
                (raw['items'] as List).map(
                  (e) => Map<String, dynamic>.from(e as Map),
                ),
              )
              : <Map<String, dynamic>>[];
      setState(() => _stockPtOrphansCount = items.length);
      _showStockPtInfo(
        title: 'Escaneo completado',
        message:
            'Consulta OK. Códigos con stock sin catálogo: ${items.length}.',
        severity: InfoBarSeverity.success,
      );
      await showDialog<void>(
        context: context,
        builder: (ctx) {
          return ContentDialog(
            title: const Text('SKU en hoja inventario sin catálogo maestro'),
            constraints: const BoxConstraints(maxWidth: 560, maxHeight: 520),
            content: SizedBox(
              width: double.maxFinite,
              height: 360,
              child:
                  items.isEmpty
                      ? const Center(
                        child: Text(
                          'Ninguno. Todos los códigos de la hoja existen en el maestro.',
                        ),
                      )
                      : ListView.separated(
                        itemCount: items.length,
                        separatorBuilder: (_, __) => const Divider(),
                        itemBuilder: (context, i) {
                          final it = items[i];
                          return ListTile(
                            title: Text(
                              '${it['codigo'] ?? ''}',
                              style: const TextStyle(fontWeight: FontWeight.w700),
                            ),
                            subtitle: Text('Stock hoja: ${it['stock'] ?? '-'}'),
                          );
                        },
                      ),
            ),
            actions: [
              FilledButton(
                child: const Text('Cerrar'),
                onPressed: () => Navigator.pop(ctx),
              ),
            ],
          );
        },
      );
    } on ApiException catch (e) {
      _showStockPtInfo(
        title: 'Error al consultar inventario externo',
        message: _stockPtApiErrorDetail(
          e,
          action: 'consulta de codigos sin catalogo',
        ),
        severity: InfoBarSeverity.error,
      );
    } catch (e) {
      _showStockPtInfo(
        title: 'Error al consultar inventario externo',
        message: 'Fallo de red/local al consultar hoja: $e',
        severity: InfoBarSeverity.error,
      );
    } finally {
      if (mounted) setState(() => _stockPtOrphansBusy = false);
    }
  }

  Future<void> _fetchData({bool showLoading = true}) async {
    if (showLoading) {
      if (mounted) {
        setState(() {
          _isLoading = true;
          _errorMessage = null;
        });
      }
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
        if (allKeys.contains('Espesor_Perfil_CAD') &&
            allKeys.contains('Ancho_CAD')) {
          allKeys.remove('Espesor_Perfil_CAD');
          final indexOfAncho = allKeys.indexOf('Ancho_CAD');
          allKeys.insert(indexOfAncho + 1, 'Espesor_Perfil_CAD');
        }

        // Ocultar Area_CAD y ubicar columnas de stock PT en ese tramo.
        final areaCadIndex = allKeys.indexOf('Area_CAD');
        allKeys.remove('Area_CAD');
        allKeys.remove('Stock_PT_Almacen');
        allKeys.remove('Stock_PT_Almacen_SyncAt');
        if (areaCadIndex >= 0) {
          final insertAt = areaCadIndex.clamp(0, allKeys.length);
          if (data.first.containsKey('Stock_PT_Almacen')) {
            allKeys.insert(insertAt, 'Stock_PT_Almacen');
          }
          if (data.first.containsKey('Stock_PT_Almacen_SyncAt')) {
            allKeys.insert(
              (insertAt + 1).clamp(0, allKeys.length),
              'Stock_PT_Almacen_SyncAt',
            );
          }
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
            'Stock_PT_Almacen_SyncAt',
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
        if (parseAppRole(_userRole).catalogShowsStockPtAlmacen) {
          unawaited(_refreshStockPtOrphansCount());
        }
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

      for (final entry in _selectedValueFilters.entries) {
        final selected = entry.value;
        if (selected.isEmpty) continue;
        final col = entry.key;
        final cell = (row[col]?.toString() ?? '').trim();
        if (!selected.contains(cell)) return false;
      }
      return true;
    }).toList();
  }

  int _compareCellValues(dynamic a, dynamic b) {
    final sa = (a ?? '').toString().trim();
    final sb = (b ?? '').toString().trim();

    final na = double.tryParse(sa.replaceAll(',', ''));
    final nb = double.tryParse(sb.replaceAll(',', ''));
    if (na != null && nb != null) {
      return na.compareTo(nb);
    }

    final da = DateTime.tryParse(sa);
    final db = DateTime.tryParse(sb);
    if (da != null && db != null) {
      return da.compareTo(db);
    }

    return sa.toLowerCase().compareTo(sb.toLowerCase());
  }

  void _sortRowsInPlace(List<Map<String, dynamic>> rows) {
    if (_columnaOrden.trim().isEmpty) return;
    rows.sort((a, b) {
      final c = _compareCellValues(a[_columnaOrden], b[_columnaOrden]);
      return _ordenAscendente ? c : -c;
    });
  }

  /// Aplica filtros locales usando solo los controladores persistentes por columna.
  void _applyFilters({bool resetScroll = true}) {
    final next = _computeFilteredRows();
    _sortRowsInPlace(next);
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
    });
    _applyFilters(resetScroll: false);
  }

  void _clearFilters() {
    for (var controller in _filterControllers.values) {
      controller.clear();
    }
    setState(() {
      _onlyWithPlano = false;
      _selectedValueFilters.clear();
    });
    _applyFilters();
  }

  List<String> _distinctColumnValues(String column) {
    final values = _allData
        .map((r) => (r[column]?.toString() ?? '').trim())
        .where((v) => v.isNotEmpty && v != '-')
        .toSet()
        .toList();
    values.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return values;
  }

  Future<void> _showColumnValueFilterDialog(String column) async {
    final allValues = _distinctColumnValues(column);
    final current = Set<String>.from(_selectedValueFilters[column] ?? const {});
    final searchCtrl = TextEditingController();
    final tempSelected = Set<String>.from(current);

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDState) {
            final q = searchCtrl.text.trim().toLowerCase();
            final visible = q.isEmpty
                ? allValues
                : allValues.where((v) => v.toLowerCase().contains(q)).toList();
            return ContentDialog(
              title: Text('Filtro de columna: ${column.replaceAll('_', ' ')}'),
              content: SizedBox(
                width: 420,
                height: 420,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextBox(
                      controller: searchCtrl,
                      placeholder: 'Buscar valor...',
                      onChanged: (_) => setDState(() {}),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Button(
                          child: const Text('Seleccionar todo'),
                          onPressed: () {
                            setDState(() {
                              tempSelected.addAll(visible);
                            });
                          },
                        ),
                        const SizedBox(width: 8),
                        Button(
                          child: const Text('Limpiar'),
                          onPressed: () {
                            setDState(() {
                              tempSelected.clear();
                            });
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: ListView.builder(
                        itemCount: visible.length,
                        itemBuilder: (_, i) {
                          final value = visible[i];
                          final checked = tempSelected.contains(value);
                          return Checkbox(
                            checked: checked,
                            onChanged: (v) {
                              setDState(() {
                                if (v == true) {
                                  tempSelected.add(value);
                                } else {
                                  tempSelected.remove(value);
                                }
                              });
                            },
                            content: Text(
                              value,
                              overflow: TextOverflow.ellipsis,
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                Button(
                  child: const Text('Cancelar'),
                  onPressed: () => Navigator.pop(ctx),
                ),
                Button(
                  child: const Text('Quitar filtro'),
                  onPressed: () {
                    setState(() {
                      _selectedValueFilters.remove(column);
                    });
                    _applyFilters(resetScroll: false);
                    Navigator.pop(ctx);
                  },
                ),
                FilledButton(
                  child: const Text('Aplicar'),
                  onPressed: () {
                    setState(() {
                      if (tempSelected.isEmpty) {
                        _selectedValueFilters.remove(column);
                      } else {
                        _selectedValueFilters[column] = Set<String>.from(
                          tempSelected,
                        );
                      }
                    });
                    _applyFilters(resetScroll: false);
                    Navigator.pop(ctx);
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  List<String> _exportableColumns() {
    return _columns.where((c) {
      if (_visibleColumns[c] != true) return false;
      if (_excludeColumnForRole(c)) return false;
      // Nunca exportar rutas internas (aunque la columna sea visible).
      if (_isRutaPrivadaColumn(c)) return false;
      return true;
    }).toList();
  }

  /// Exporta a Excel
  Future<void> _exportToExcel() async {
    if (_filteredData.isEmpty) return;

    var excel = excel_lib.Excel.createExcel();
    final headerStyle = ExcelHelper.getHeaderStyle();
    excel_lib.Sheet sheetObject = excel['Catálogo'];
    excel.delete('Sheet1');

    final exportCols = _exportableColumns();
    if (exportCols.isEmpty) return;

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
          value = excel_lib.DoubleCellValue(
            ExcelHelper.cleanToDouble(row[colName]),
          );
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

  Future<void> _exportToPdf() async {
    if (_filteredData.isEmpty) return;
    final exportCols = _exportableColumns();
    if (exportCols.isEmpty) return;

    final doc = PdfDocument();
    final grid = PdfGrid();
    grid.columns.add(count: exportCols.length);
    grid.headers.add(1);

    final hdr = grid.headers[0];
    for (int i = 0; i < exportCols.length; i++) {
      hdr.cells[i].value = exportCols[i].replaceAll('_', ' ');
    }

    for (final row in _filteredData) {
      final gr = grid.rows.add();
      for (int c = 0; c < exportCols.length; c++) {
        final col = exportCols[c];
        gr.cells[c].value = row[col]?.toString() ?? '-';
      }
    }

    grid.style = PdfGridStyle(
      font: PdfStandardFont(PdfFontFamily.helvetica, 8),
      cellPadding: PdfPaddings(left: 3, right: 3, top: 2, bottom: 2),
    );

    grid.draw(
      page: doc.pages.add(),
      bounds: const Rect.fromLTWH(0, 0, 0, 0),
      format: PdfLayoutFormat(layoutType: PdfLayoutType.paginate),
    );

    String? outputFile = await FilePicker.platform.saveFile(
      dialogTitle: 'Guardar catálogo PDF',
      fileName: 'catalogo.pdf',
    );
    if (outputFile == null) {
      doc.dispose();
      return;
    }
    if (!outputFile.endsWith('.pdf')) outputFile = '$outputFile.pdf';

    try {
      final bytes = await doc.save();
      File(outputFile)
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes);

      if (mounted) {
        displayInfoBar(
          context,
          builder: (context, close) {
            return InfoBar(
              title: const Text('PDF exportado'),
              content: Text('Guardado en: $outputFile'),
              severity: InfoBarSeverity.success,
              onClose: close,
            );
          },
        );
      }
    } finally {
      doc.dispose();
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
          content: Text(
            '¿Estás seguro de que deseas eliminar permanentemente la pieza $codigo? Esta acción no se puede deshacer.',
          ),
          actions: [
            Button(
              child: const Text('Cancelar'),
              onPressed: () => Navigator.pop(context),
            ),
            FilledButton(
              style: ButtonStyle(backgroundColor: WidgetStateProperty.all(Colors.red)),
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
              child: const Text('Eliminar'),
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
                    Expanded(
                      child: _buildLabelValue("LARGO CAD", row['Largo_CAD']),
                    ),
                    Expanded(
                      child: _buildLabelValue("ANCHO CAD", row['Ancho_CAD']),
                    ),
                    Expanded(
                      child: _buildLabelValue(
                        "ESPESOR / PERFIL",
                        row['Espesor_Perfil_CAD'],
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: _buildLabelValue("TIENE DXF", row['Tiene_DXF']),
                    ),
                    Expanded(
                      child: _buildLabelValue("LARGO DXF", row['Largo_DXF']),
                    ),
                    Expanded(
                      child: _buildLabelValue("ANCHO DXF", row['Ancho_DXF']),
                    ),
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
                if (!_excludeColumnForRole('Link_Drive')) ...[
                  _buildLabelValue("LINK PLANO", row['Link_Drive']),
                  const Divider(),
                ],
                if (!_excludeColumnForRole('Modificado_Por'))
                  _buildLabelValue("Modificado Por", row['Modificado_Por']),
                if (!_excludeColumnForRole('Ultima_Actualizacion'))
                  _buildLabelValue(
                    "Última Actualización",
                    row['Ultima_Actualizacion'],
                  ),
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
                _columns.where((col) => !_excludeColumnForRole(col)).map((col) {
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
    pathController.text =
        prefs.getString('dxf_master_path') ?? r'C:\Libreria_DXF';

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
                        String? selectedDirectory =
                            await FilePicker.platform.getDirectoryPath();
                        if (selectedDirectory != null) {
                          pathController.text = selectedDirectory.replaceAll(
                            '/',
                            r'\',
                          );
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
                        final data = await Clipboard.getData(
                          Clipboard.kTextPlain,
                        );
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
                  onPressed:
                      isSearching
                          ? null
                          : () async {
                            if (searchController.text.isEmpty ||
                                pathController.text.isEmpty) {
                              return;
                            }

                            final plainPath = pathController.text
                                .trim()
                                .replaceAll('"', '')
                                .replaceAll("'", "");
                            await prefs.setString('dxf_master_path', plainPath);
                            setStateDialog(() => isSearching = true);

                            try {
                              final req = await ApiClient.getUnvalidated(
                                '/api/dxf/search/${searchController.text.trim()}',
                                queryParameters: {'base_path': plainPath},
                              );
                              setStateDialog(() => isSearching = false);
                              if (req.statusCode == 200) {
                                final data =
                                    req.decodeJson() as Map<String, dynamic>;
                                final dxfPath = data['dxf_path'];
                                if (!context.mounted) return;
                                Navigator.pop(context); // close search dialog
                                // show success
                                showDialog(
                                  context: context,
                                  builder:
                                      (ctx) => ContentDialog(
                                        title: const Text('Archivo Encontrado'),
                                        content: Text('Ruta: $dxfPath'),
                                        actions: [
                                          Button(
                                            child: const Text('Cerrar'),
                                            onPressed: () => Navigator.pop(ctx),
                                          ),
                                          FilledButton(
                                            child: const Text(
                                              'Abrir Ubicación',
                                            ),
                                            onPressed: () {
                                              Process.run('explorer.exe', [
                                                '/select,',
                                                dxfPath,
                                              ]);
                                              Navigator.pop(ctx);
                                            },
                                          ),
                                        ],
                                      ),
                                );
                              } else {
                                final err = req.decodeJson();
                                final detail =
                                    err is Map
                                        ? (err['detail'] ??
                                                'No se encontraron archivos válidos.')
                                            .toString()
                                        : 'No se encontraron archivos válidos.';
                                if (!context.mounted) return;
                                displayInfoBar(
                                  context,
                                  builder:
                                      (c, close) => InfoBar(
                                        title: const Text('No encontrado'),
                                        content: Text(detail),
                                        severity: InfoBarSeverity.warning,
                                        onClose: close,
                                      ),
                                );
                              }
                            } catch (e) {
                              setStateDialog(() => isSearching = false);
                              displayInfoBar(
                                context,
                                builder:
                                    (c, close) => InfoBar(
                                      title: const Text('Error de Red'),
                                      content: Text(e.toString()),
                                      severity: InfoBarSeverity.error,
                                      onClose: close,
                                    ),
                              );
                            }
                          },
                  child: const Text('Buscar'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = uiSurfacePaletteOf(context);
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
        child: Text(
          'Registros: ${_filteredData.length} / ${_allData.length}',
          style: TextStyle(color: palette.textSecondary),
        ),
      ),
    );
  }

  Widget _buildCommandBar() {
    final role = parseAppRole(_userRole);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            ToggleSwitch(
              checked: _onlyWithPlano,
              content: Text(_onlyWithPlano ? 'Con Plano/Drive' : 'Todos'),
              onChanged: (v) {
                setState(() => _onlyWithPlano = v);
                _applyFilters();
              },
            ),
            const SizedBox(width: 8),
            if (role.catalogCanSelectColumns)
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
            if (role.catalogCanSearchDxf)
              Tooltip(
                message: "Buscar DXF",
                child: IconButton(
                  icon: const Icon(FluentIcons.search),
                  onPressed: _searchDXF,
                ),
              ),
            if (role.catalogCanExportExcel)
              Tooltip(
                message: "Exportar a Excel",
                child: IconButton(
                  icon: const Icon(FluentIcons.excel_logo),
                  onPressed: _filteredData.isNotEmpty ? _exportToExcel : null,
                ),
              ),
            if (role.catalogCanExportPdf)
              Tooltip(
                message: "Exportar PDF (sin columnas privadas)",
                child: IconButton(
                  icon: const Icon(FluentIcons.pdf, size: 14),
                  onPressed: _filteredData.isNotEmpty ? _exportToPdf : null,
                ),
              ),
            Tooltip(
              message: "Reportar fallo del catálogo",
              child: IconButton(
                icon: const Icon(FluentIcons.bug),
                onPressed: () => showContextualBugReportDialog(
                  context,
                  modulo: 'Catálogo Maestro',
                  contextoPantalla: 'catalogo_maestro',
                ),
              ),
            ),
            if (role.catalogCanSeeStockPtActions) ...[
              Tooltip(
                message:
                    role.catalogShowsStockPtAlmacen
                        ? 'Actualizar stock desde hoja externa'
                        : 'Solo Ingeniería y Desarrollador pueden ejecutar este botón',
                child: IconButton(
                  onPressed:
                      !role.catalogShowsStockPtAlmacen
                          ? null
                          : _stockPtSyncBusy
                          ? null
                          : () => _syncStockPtDesdeHoja(
                            showProgressDialog: true,
                          ),
                  icon:
                      _stockPtSyncBusy
                          ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: ProgressRing(strokeWidth: 2),
                          )
                          : const Icon(FluentIcons.sync_status_solid),
                ),
              ),
              Tooltip(
                message:
                    role.catalogShowsStockPtAlmacen
                        ? 'Ver códigos con stock no registrados en catálogo'
                        : 'Solo Ingeniería y Desarrollador pueden ejecutar este botón',
                child: IconButton(
                  onPressed:
                      !role.catalogShowsStockPtAlmacen
                          ? null
                          : _stockPtOrphansBusy
                          ? null
                          : _showStockPtOrphansDialog,
                  icon: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      _stockPtOrphansBusy
                          ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: ProgressRing(strokeWidth: 2),
                          )
                          : const Icon(FluentIcons.issue_tracking),
                      if (_stockPtOrphansCount != null &&
                          _stockPtOrphansCount! > 0)
                        Positioned(
                          right: -9,
                          top: -7,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFC42B1C),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '${_stockPtOrphansCount}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _displayColumnName(String col) {
    return col == 'Espesor_Perfil_CAD'
        ? 'Espesor / Long. Perfil'
        : col.replaceAll('_', ' ');
  }

  double _getColumnWidth(String col) {
    switch (col) {
      case 'Codigo_Pieza':
      case 'Codigo':
        return 120.0;
      case 'Descripcion':
        return 250.0;
      case 'Medida':
        return 100.0;
      case 'Material':
        return 220.0;
      case 'Proceso_Primario':
        return 110.0;
      case 'Proceso_1':
      case 'Proceso_2':
      case 'Proceso_3':
        return 84.0;
      case 'Largo_CAD':
      case 'Ancho_CAD':
        return 90.0;
      case 'Espesor_Perfil_CAD':
        return 120.0;
      case 'Tiene_DXF':
        return 80.0;
      case 'Largo_DXF':
      case 'Ancho_DXF':
        return 90.0;
      case 'Stock_PT_Almacen':
        return 100.0;
      case 'Stock_PT_Almacen_SyncAt':
        return 160.0;
      default:
        return 130.0;
    }
  }

  Map<String, double> _computeColumnWidthsForViewport(
    BuildContext context,
    List<String> activeCols,
    double availableColsWidth,
  ) {
    if (activeCols.isEmpty) return const {};
    final textScale =
        MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 1.45);
    const headerStyle = TextStyle(
      fontWeight: FontWeight.bold,
      fontSize: 12.0,
    );
    final mins = <String, double>{};
    for (final col in activeCols) {
      final title = _displayColumnName(col);
      final tp = TextPainter(
        text: TextSpan(text: title, style: headerStyle),
        maxLines: 1,
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.linear(textScale),
      )..layout();
      // Título + paddings de celda + espacio de botones ordenar/filtro.
      final titleDrivenMin = tp.width + 16 + 62;
      final baseMin = _getColumnWidth(col);
      mins[col] = titleDrivenMin > baseMin ? titleDrivenMin : baseMin;
    }
    final minTotal = mins.values.fold<double>(0.0, (a, b) => a + b);
    if (availableColsWidth <= minTotal) return mins;
    final extra = availableColsWidth - minTotal;
    double weightFor(String col, double w) {
      if (col == 'Material') return w * 2.1;
      if (col == 'Descripcion') return w * 1.15;
      if (col == 'Proceso_Primario') return w * 0.9;
      if (col == 'Proceso_1' || col == 'Proceso_2' || col == 'Proceso_3') {
        return w * 0.82;
      }
      return w;
    }
    final weightedTotal = activeCols.fold<double>(
      0.0,
      (sum, col) => sum + weightFor(col, mins[col]!),
    );
    final out = <String, double>{};
    for (final col in activeCols) {
      final w = mins[col]!;
      final ww = weightFor(col, w);
      out[col] = w + (extra * (ww / weightedTotal));
    }
    return out;
  }

  Widget _buildContent() {
    final palette = uiSurfacePaletteOf(context);
    if (_isLoading) return const Center(child: ProgressRing());
    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableText(
              _errorMessage!,
              style: TextStyle(color: palette.actionDanger),
            ),
            const SizedBox(height: 10),
            IconButton(
              icon: const Icon(FluentIcons.copy),
              onPressed:
                  () => Clipboard.setData(ClipboardData(text: _errorMessage!)),
            ),
            Text(
              "Copiar Error",
              style: fluentSecondaryTextStyle(context, fontSize: 10),
            ),
          ],
        ),
      );
    }
    if (_allData.isEmpty) return const Center(child: Text('Sin datos.'));

    final activeCols =
        _columns.where((c) {
          if (_visibleColumns[c] != true) return false;
          if (_excludeColumnForRole(c)) return false;
          return true;
        }).toList();

    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Container(
        decoration: BoxDecoration(
          color: palette.surfaceCard,
          borderRadius: BorderRadius.circular(UiTokens.cardRadius),
          border: Border.all(color: palette.borderSubtle),
          boxShadow: [
            BoxShadow(
              color:
                  FluentTheme.of(context).brightness == Brightness.dark
                      ? Colors.black.withValues(alpha: 0.22)
                      : Colors.black.withValues(alpha: 0.06),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        padding: const EdgeInsets.all(8.0),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final textScale =
                MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 1.45);
            final double actionsWidth = 145.0 * textScale;
            final widths = _computeColumnWidthsForViewport(
              context,
              activeCols,
              (constraints.maxWidth - actionsWidth).clamp(0.0, double.infinity),
            );
            final double colsWidth = activeCols.fold(
              0.0,
              (sum, col) => sum + (widths[col] ?? _getColumnWidth(col)),
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
                            _buildHeaderRow(activeCols, actionsWidth, widths),
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
                                    widths,
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

  Widget _buildHeaderRow(
    List<String> activeCols,
    double actionsWidth,
    Map<String, double> widths,
  ) {
    return Row(
      children: [
        // Espacio acciones (Sin Settings Icon)
        SizedBox(width: actionsWidth, child: Container()),
        ...activeCols.map((col) {
          final displayName = _displayColumnName(col);
          return SizedBox(
            width: widths[col] ?? _getColumnWidth(col),
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
                        child: Tooltip(
                          message: displayName,
                          child: Text(
                            displayName,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12.0,
                            ),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
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
                          Tooltip(
                            message: 'Filtro desplegable (estilo Excel)',
                            child: IconButton(
                              icon: Icon(
                                _selectedValueFilters[col]?.isNotEmpty == true
                                    ? FluentIcons.filter_solid
                                    : FluentIcons.filter,
                                size: 10,
                                color:
                                    _selectedValueFilters[col]?.isNotEmpty == true
                                    ? FluentTheme.of(context).accentColor
                                    : null,
                              ),
                              onPressed: () => _showColumnValueFilterDialog(col),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  if (_selectedValueFilters[col]?.isNotEmpty == true)
                    Padding(
                      padding: const EdgeInsets.only(top: 2.0),
                      child: Text(
                        '${_selectedValueFilters[col]!.length} seleccionados',
                        style: TextStyle(
                          fontSize: 10,
                          color: FluentTheme.of(context).accentColor,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
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

  Widget _buildDataRow(
    Map<String, dynamic> row,
    int index,
    List<String> activeCols,
    double actionsWidth,
    Map<String, double> widths,
  ) {
    final palette = uiSurfacePaletteOf(context);
    final hasLink =
        row['Link_Drive'] != null &&
        row['Link_Drive'].toString().isNotEmpty &&
        row['Link_Drive'].toString() != '-';

    return Container(
      color:
          index % 2 == 0 ? Colors.transparent : palette.tableStripe,
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
                      color: palette.actionInfo,
                    ), // BLUE
                    onPressed: () => _showInfoDetails(row),
                  ),
                ),
                if (parseAppRole(_userRole).catalogCanEditRows)
                  Tooltip(
                    message: 'Editar',
                    child: IconButton(
                      icon: Icon(
                        FluentIcons.edit,
                        size: 14,
                        color: palette.actionEdit,
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
                        color: palette.actionLink,
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
                      color: palette.actionCopy,
                    ), // MAGENTA/MORADO PARA RESALTAR
                    onPressed: () {
                      final codigoCopiar =
                          row['Codigo_Pieza']?.toString() ??
                          row['Codigo']?.toString() ??
                          '';
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
                if (parseAppRole(_userRole).catalogCanEditRows)
                  Tooltip(
                    message: 'Eliminar Pieza',
                    child: IconButton(
                      icon: Icon(
                        FluentIcons.delete,
                        size: 14,
                        color: palette.actionDanger,
                      ),
                      onPressed:
                          () => _deleteMaterial(
                            row['Codigo_Pieza']?.toString() ??
                                row['Codigo']?.toString() ??
                                '',
                          ),
                    ),
                  ),
              ],
            ),
          ),
          ...activeCols.map((col) {
            return SizedBox(
              width: widths[col] ?? _getColumnWidth(col),
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
