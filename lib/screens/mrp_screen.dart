import 'package:fluent_ui/fluent_ui.dart';
import 'package:intl/intl.dart';
import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart' as excel_lib;
import '../utils/excel_helper.dart';
import '../services/api_client.dart';
import '../theme/ui_tokens.dart';
import '../widgets/compact_page_header.dart';
import '../services/app_role.dart';

import 'dart:io';

enum MRPViewMode {
  requerimientos,
  optimizacionCorte,
}

class MRPScreen extends StatefulWidget {
  const MRPScreen({
    super.key,
    this.mode = MRPViewMode.requerimientos,
    this.effectiveRole,
  });

  final MRPViewMode mode;
  /// Rol efectivo (p. ej. simulación admin) para notas solo desarrollo.
  final String? effectiveRole;

  @override
  State<MRPScreen> createState() => _MRPScreenState();
}

class _MRPScreenState extends State<MRPScreen> {
  bool _isLoadingRevisions = false;
  bool _isCalculating = false;
  List<Map<String, dynamic>> _revisionsList = [];
  int? _selectedRevisionId;
  String? _selectedRevisionName;

  List<Map<String, dynamic>> _mrpData = [];
  List<Map<String, dynamic>> _comercialesData = [];
  List<Map<String, dynamic>> _orphanData = [];
  Map<String, dynamic>? _resumenStockMrp;
  String? _errorMessage;
  String? _selectedRevisionClientes;
  String _filtroRiesgo = 'Todos';
  bool _soloConBrecha = false;
  String _filtroTexto = '';
  bool _isOptimizingCut = false;
  final Set<int> _optRevisionIds = <int>{};
  List<Map<String, dynamic>> _optFabricables = [];
  List<Map<String, dynamic>> _optSobrestock = [];
  String _optMaterial = '';
  String _optCalibre = '';
  String _optDisponible = '';
  /// Medidas del retazo/chapa disponible (mm). Si ambas > 0, cantidad = nº de piezas de ese tamaño.
  String _optLargoMp = '';
  String _optAnchoMp = '';
  bool _optExcluirStockPositivo = false;
  List<Map<String, dynamic>> _optDescartadasMedida = [];
  Map<String, dynamic>? _optResumenCut;
  double? _optAreaDisponibleMm2;

  // Tab index: 0 = Materia Prima, 1 = Comerciales, 2 = Huérfanos
  int _tabIndex = 0;

  final NumberFormat _numFormat = NumberFormat('#,##0', 'en_US');
  final NumberFormat _decFormat = NumberFormat('#,##0.00', 'en_US');

  bool get _showDevCorteNotaCorteMp {
    final r = parseAppRole(widget.effectiveRole);
    return r == AppRole.desarrollador || r == AppRole.administrador;
  }

  /// API MRPII: `material_oficial` (maestro); `Material` se mantiene por compatibilidad.
  String _materialOficialMP(Map<String, dynamic> row) {
    final v = row['material_oficial'] ?? row['Material'];
    if (v == null) return 'N/A';
    final s = v.toString().trim();
    return s.isEmpty ? 'N/A' : s;
  }

  double _d(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  String _riesgoMp(Map<String, dynamic> row) {
    final demanda = _d(row['Cantidad_Total_Piezas']);
    final stock = _d(row['Stock_Asociado_Estimado']);
    final brecha = _d(row['Brecha_Estimada']);
    final cobertura = demanda <= 0 ? 100 : (stock / demanda) * 100;
    if (brecha > 0 && cobertura <= 40) return 'Crítico';
    if (brecha > 0) return 'Alerta';
    return 'Estable';
  }

  List<Map<String, dynamic>> get _mrpFiltrado {
    final txt = _filtroTexto.trim().toLowerCase();
    return _mrpData.where((row) {
      final riesgo = _riesgoMp(row);
      final brecha = _d(row['Brecha_Estimada']);
      if (_filtroRiesgo != 'Todos' && riesgo != _filtroRiesgo) return false;
      if (_soloConBrecha && brecha <= 0) return false;
      if (txt.isNotEmpty) {
        final hay = [
          _materialOficialMP(row),
          row['Calibre_Espesor']?.toString() ?? '',
          row['Sugerencia_Compra']?.toString() ?? '',
        ].join(' ').toLowerCase().contains(txt);
        if (!hay) return false;
      }
      return true;
    }).toList();
  }

  List<String> get _optMaterialOptions {
    final materiales = _mrpData
        .map(_materialOficialMP)
        .map((v) => v.trim())
        .where((v) => v.isNotEmpty && v.toUpperCase() != 'N/A')
        .toSet()
        .toList()
      ..sort();
    return materiales;
  }

  List<String> get _optCalibreOptions {
    final materialSel = _optMaterial.trim();
    Iterable<Map<String, dynamic>> src = _mrpData;
    if (materialSel.isNotEmpty) {
      src = src.where((row) => _materialOficialMP(row).trim() == materialSel);
    }
    final calibres = src
        .map((row) => (row['Calibre_Espesor'] ?? '').toString().trim())
        .where((v) => v.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return calibres;
  }

  void _syncOptSelectorsWithData() {
    final materiales = _optMaterialOptions;
    if (_optMaterial.isNotEmpty && !materiales.contains(_optMaterial)) {
      _optMaterial = '';
    }
    final calibres = _optCalibreOptions;
    if (_optCalibre.isNotEmpty && !calibres.contains(_optCalibre)) {
      _optCalibre = '';
    }
  }

  @override
  void initState() {
    super.initState();
    _fetchRevisions();
  }

  Future<void> _fetchRevisions() async {
    setState(() => _isLoadingRevisions = true);
    try {
      // Endpoint dedicado: DISTINCT sin JOIN de clientes → sin duplicados.
      final res = await ApiClient.getUnvalidated('/api/mrp/revisiones');
      if (res.statusCode == 200) {
        final List<dynamic> rows = res.decodeJson() as List<dynamic>;

        final flattened = rows
            .map((r) {
              final int? rId = r['id_revision'] as int?;
              if (rId == null) return null;

              final String tracto    = (r['nombre_tracto']      ?? '').toString().trim();
              final String tipo      = (r['nombre_tipo']        ?? '').toString().trim();
              final String version   = (r['nombre_version']     ?? '').toString().trim();
              final String numRev    = (r['numero_revision']    ?? 'N/A').toString();
              final String estado    = (r['estado']             ?? '').toString().trim();
              final String clientes  = (r['clientes_afectados'] ?? '').toString().trim();

              final String name =
                  '$tracto — $tipo ($version) · Rev $numRev'
                  '${estado.isNotEmpty ? "  [$estado]" : ""}';

              return <String, dynamic>{
                'id': rId,
                'name': name,
                'clientes_afectados': clientes,
              };
            })
            .whereType<Map<String, dynamic>>()
            .toList();

        if (mounted) setState(() => _revisionsList = flattened);
      }
    } catch (e) {
      debugPrint("Error obteniendo revisiones MRP: $e");
    } finally {
      if (mounted) setState(() => _isLoadingRevisions = false);
    }
  }

  Future<void> _calculateMRP() async {
    if (_selectedRevisionId == null) return;
    setState(() {
      _isCalculating = true;
      _errorMessage = null;
      _mrpData = [];
      _comercialesData = [];
      _orphanData = [];
      _resumenStockMrp = null;
      _tabIndex = 0;
    });

    try {
      final res = await ApiClient.getUnvalidated(
        '/api/mrp/calculate/$_selectedRevisionId',
      );

      if (res.statusCode == 200) {
        final Map<String, dynamic> data = res.decodeJson() as Map<String, dynamic>;
        if (mounted) {
          setState(() {
            _mrpData =
                List<Map<String, dynamic>>.from(data['mrp_calculado'] ?? []);
            _comercialesData = List<Map<String, dynamic>>.from(
                data['componentes_comerciales'] ?? []);
            _orphanData = List<Map<String, dynamic>>.from(
                data['piezas_sin_medidas'] ?? []);
            _resumenStockMrp = data['resumen_stock_mrp'] is Map
                ? Map<String, dynamic>.from(data['resumen_stock_mrp'])
                : null;
            _syncOptSelectorsWithData();
          });
        }
      } else {
        throw Exception("Error del servidor: ${res.statusCode} - ${res.rawBody}");
      }
    } catch (e) {
      if (mounted) setState(() => _errorMessage = e.toString());
    } finally {
      if (mounted) setState(() => _isCalculating = false);
    }
  }

  Future<void> _optimizarCorteMp() async {
    final disponible =
        double.tryParse(_optDisponible.trim().replaceAll(',', '.'));
    if (disponible == null || disponible <= 0) {
      setState(() {
        _errorMessage = 'Ingrese una cantidad disponible válida (> 0).';
      });
      return;
    }
    final tl = _optLargoMp.trim();
    final ta = _optAnchoMp.trim();
    final tieneL = tl.isNotEmpty;
    final tieneA = ta.isNotEmpty;
    if (tieneL != tieneA) {
      setState(() {
        _errorMessage =
            'Indique largo y ancho de la materia prima (mm), o deje ambos vacíos.';
      });
      return;
    }
    double? lm;
    double? wm;
    if (tieneL && tieneA) {
      lm = double.tryParse(tl.replaceAll(',', '.'));
      wm = double.tryParse(ta.replaceAll(',', '.'));
      if (lm == null || wm == null || lm <= 0 || wm <= 0) {
        setState(() {
          _errorMessage = 'Largo y ancho deben ser números mayores que 0 (mm).';
        });
        return;
      }
    }
    if (_optMaterial.trim().isEmpty) {
      setState(() {
        _errorMessage = 'Seleccione un material oficial.';
      });
      return;
    }
    if (_optRevisionIds.isEmpty && _selectedRevisionId != null) {
      _optRevisionIds.add(_selectedRevisionId!);
    }
    if (_optRevisionIds.isEmpty) {
      setState(() {
        _errorMessage = 'Seleccione al menos una revisión para optimizar.';
      });
      return;
    }
    setState(() {
      _isOptimizingCut = true;
      _errorMessage = null;
      _optFabricables = [];
      _optSobrestock = [];
      _optDescartadasMedida = [];
      _optResumenCut = null;
      _optAreaDisponibleMm2 = null;
    });
    try {
      final res = await ApiClient.post(
        '/api/mrp/optimizar_uso_material',
        body: {
          'material_oficial': _optMaterial.trim(),
          'calibre_espesor': _optCalibre.trim().isEmpty ? null : _optCalibre.trim(),
          'cantidad_disponible': disponible,
          'id_revisiones': _optRevisionIds.toList()..sort(),
          'excluir_si_stock_gt_cero': _optExcluirStockPositivo,
          if (lm != null && wm != null) 'largo_materia_prima_mm': lm,
          if (lm != null && wm != null) 'ancho_materia_prima_mm': wm,
        },
      );
      if (res is Map<String, dynamic>) {
        setState(() {
          _optFabricables =
              List<Map<String, dynamic>>.from(res['fabricables'] ?? const []);
          _optSobrestock =
              List<Map<String, dynamic>>.from(res['sobrestock'] ?? const []);
          _optDescartadasMedida = List<Map<String, dynamic>>.from(
              res['descartadas_por_medida'] ?? const []);
          _optResumenCut = res['resumen'] is Map
              ? Map<String, dynamic>.from(res['resumen'] as Map)
              : null;
          final ad = res['area_disponible_mm2'];
          _optAreaDisponibleMm2 =
              ad == null ? null : double.tryParse(ad.toString());
        });
      } else {
        setState(() {
          _errorMessage = 'Respuesta inválida en optimización de corte.';
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error optimizando uso de material: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _isOptimizingCut = false);
      }
    }
  }

  // ── Export ────────────────────────────────────────────────────────────────

  Future<void> _exportToExcel() async {
    if (_mrpData.isEmpty && _comercialesData.isEmpty && _orphanData.isEmpty) {
      return;
    }

    var excelFile = excel_lib.Excel.createExcel();
    final headerStyle = ExcelHelper.getHeaderStyle();

    // Hoja 1 — Orden de Compra (Materia Prima)
    excel_lib.Sheet sheetOC = excelFile['Orden_Compra'];
    excelFile.delete('Sheet1');

    final ocHeaders = [
      'Material Oficial',
      'Calibre/Espesor',
      'Piezas Totales',
      'Área / Requerimiento (Texto)',
      'Área m² (Num)',
      'Stock Asociado Estimado',
      'Brecha Estimada',
      'Orden de Compra Sugerida',
    ];
    Map<int, int> ocWidths = {};
    for (int i = 0; i < ocHeaders.length; i++) {
      sheetOC.updateCell(
        excel_lib.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0),
        excel_lib.TextCellValue(ocHeaders[i]),
        cellStyle: headerStyle,
      );
      ExcelHelper.updateMaxWith(ocWidths, i, ocHeaders[i]);
    }
    for (int r = 0; r < _mrpData.length; r++) {
      final row = _mrpData[r];
      final double areaMm2 = (row['Requerimiento_Area_mm2'] ?? 0).toDouble();
      final double areaM2  = areaMm2 / 1_000_000.0;
      final int piezas = ExcelHelper.cleanToInt(row['Cantidad_Total_Piezas']);
      final cells = [
        excel_lib.TextCellValue(_materialOficialMP(row)),
        ExcelHelper.parseDynamicCell(row['Calibre_Espesor']),
        excel_lib.IntCellValue(piezas),
        excel_lib.TextCellValue(_formatArea(areaMm2)),
        excel_lib.DoubleCellValue(areaM2),
        excel_lib.IntCellValue(ExcelHelper.cleanToInt(row['Stock_Asociado_Estimado'])),
        excel_lib.IntCellValue(ExcelHelper.cleanToInt(row['Brecha_Estimada'])),
        excel_lib.TextCellValue(row['Sugerencia_Compra']?.toString() ?? 'N/A'),
      ];
      for (int c = 0; c < cells.length; c++) {
        sheetOC.updateCell(
          excel_lib.CellIndex.indexByColumnRow(
              columnIndex: c, rowIndex: r + 1),
          cells[c],
        );
        ExcelHelper.updateMaxWith(ocWidths, c, cells[c].toString());
      }
    }
    ExcelHelper.applyAutoFit(sheetOC, ocWidths);

    // Hoja 2 — Componentes Comerciales
    if (_comercialesData.isNotEmpty) {
      excel_lib.Sheet sheetCom = excelFile['Componentes_Comerciales'];
      final comHeaders = [
        'Código de Pieza',
        'Descripción',
        'Cantidad Total',
        'Stock Almacén',
        'Cantidad Faltante',
        'Cobertura %',
      ];
      Map<int, int> comWidths = {};
      for (int i = 0; i < comHeaders.length; i++) {
        sheetCom.updateCell(
          excel_lib.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0),
          excel_lib.TextCellValue(comHeaders[i]),
          cellStyle: headerStyle,
        );
        ExcelHelper.updateMaxWith(comWidths, i, comHeaders[i]);
      }
      for (int r = 0; r < _comercialesData.length; r++) {
        final row = _comercialesData[r];
        final int cant =
            ExcelHelper.cleanToInt(row['Cantidad_Total']);
        final cells = [
          excel_lib.TextCellValue(row['Codigo_Pieza']?.toString() ?? '-'),
          excel_lib.TextCellValue(row['Descripcion']?.toString() ?? '-'),
          excel_lib.IntCellValue(cant),
          excel_lib.IntCellValue(ExcelHelper.cleanToInt(row['Stock_PT_Almacen'])),
          excel_lib.IntCellValue(ExcelHelper.cleanToInt(row['Cantidad_Faltante'])),
          excel_lib.DoubleCellValue(_d(row['Cobertura_Pct'])),
        ];
        for (int c = 0; c < cells.length; c++) {
          sheetCom.updateCell(
            excel_lib.CellIndex.indexByColumnRow(
                columnIndex: c, rowIndex: r + 1),
            cells[c],
          );
          ExcelHelper.updateMaxWith(comWidths, c, cells[c].toString());
        }
      }
      ExcelHelper.applyAutoFit(sheetCom, comWidths);
    }

    // Hoja 3 — Auditoría de Ingeniería (Huérfanos)
    if (_orphanData.isNotEmpty) {
      excel_lib.Sheet sheetAudit = excelFile['Auditoria_Ingenieria'];
      final auditHeaders = [
        'Código de Pieza',
        'Ensamble',
        'Material CAD',
        'Cantidad BOM',
        'Motivo de Rechazo',
      ];
      Map<int, int> auditWidths = {};
      for (int i = 0; i < auditHeaders.length; i++) {
        sheetAudit.updateCell(
          excel_lib.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0),
          excel_lib.TextCellValue(auditHeaders[i]),
          cellStyle: headerStyle,
        );
        ExcelHelper.updateMaxWith(auditWidths, i, auditHeaders[i]);
      }
      for (int r = 0; r < _orphanData.length; r++) {
        final row = _orphanData[r];
        final int cant = ExcelHelper.cleanToInt(row['Cantidad']);
        final cells = [
          excel_lib.TextCellValue(row['Codigo_Pieza']?.toString() ?? '-'),
          excel_lib.TextCellValue(row['Nombre_Ensamble']?.toString() ?? '-'),
          excel_lib.TextCellValue(row['Material']?.toString() ?? '-'),
          excel_lib.IntCellValue(cant),
          excel_lib.TextCellValue(row['Motivo_Rechazo']?.toString() ?? '-'),
        ];
        for (int c = 0; c < cells.length; c++) {
          sheetAudit.updateCell(
            excel_lib.CellIndex.indexByColumnRow(
                columnIndex: c, rowIndex: r + 1),
            cells[c],
          );
          ExcelHelper.updateMaxWith(auditWidths, c, cells[c].toString());
        }
      }
      ExcelHelper.applyAutoFit(sheetAudit, auditWidths);
    }

    final fileName =
        'MRP_Requerimiento_Rev_${_selectedRevisionId ?? "Unknown"}.xlsx';
    String? outputFile = await FilePicker.platform.saveFile(
      dialogTitle: 'Exportar Requerimiento de Materiales',
      fileName: fileName,
    );

    if (outputFile != null) {
      if (!outputFile.endsWith('.xlsx')) outputFile = '$outputFile.xlsx';
      final fileBytes = excelFile.save();
      if (fileBytes != null) {
        try {
          File(outputFile).writeAsBytesSync(fileBytes);
          if (mounted) {
            displayInfoBar(
              context,
              builder: (context, close) => InfoBar(
                title: const Text('Exportación Exitosa'),
                content: Text(
                  'Reporte generado: $fileName. '
                  '${_mrpData.length} ítems MP · '
                  '${_comercialesData.length} comerciales · '
                  '${_orphanData.length} huérfanos.',
                ),
                severity: InfoBarSeverity.success,
                onClose: close,
              ),
            );
          }
        } catch (e) {
          debugPrint("Error al guardar Excel: $e");
        }
      }
    }
  }

  String _formatArea(double mm2) {
    if (mm2 == 0) return "0.00 m²  /  0.00 in²";
    final double m2  = mm2 / 1_000_000.0;
    final double in2 = mm2 / 645.16129;
    return '${_decFormat.format(m2)} m²  /  ${_decFormat.format(in2)} in²';
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final palette = uiSurfacePaletteOf(context);
    final hasResults =
        _mrpData.isNotEmpty || _comercialesData.isNotEmpty || _orphanData.isNotEmpty;

    return ScaffoldPage(
      padding: const EdgeInsets.only(top: 8),
      header: CompactPageHeader(
        title: Text(
          widget.mode == MRPViewMode.optimizacionCorte
              ? 'MRPII: Optimización de corte MP'
              : 'MRPII: Requerimiento de Materiales',
          style: FluentTheme.of(context).typography.title,
        ),
        commandBar: Wrap(
          alignment: WrapAlignment.start,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            _isLoadingRevisions
                ? const ProgressRing(strokeWidth: 2)
                : ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 300),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ComboBox<int>(
                          placeholder: const Text(
                            'Seleccionar Revisión de Ingeniería',
                            overflow: TextOverflow.ellipsis,
                          ),
                          value: _selectedRevisionId,
                          isExpanded: true,
                          items: _revisionsList.map((rev) {
                            return ComboBoxItem<int>(
                              value: rev['id'] as int,
                              child: Tooltip(
                                message: rev['name'] as String,
                                child: Text(
                                  rev['name'] as String,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            );
                          }).toList(),
                          onChanged: (val) {
                            if (val == null) return;
                            final rev = _revisionsList.firstWhere(
                              (r) => r['id'] == val,
                              orElse: () => {'name': '', 'clientes_afectados': ''},
                            );
                            setState(() {
                              _selectedRevisionId = val;
                              _selectedRevisionName =
                                  rev['name'] as String?;
                              _selectedRevisionClientes =
                                  (rev['clientes_afectados'] as String?)
                                      ?.trim();
                              // Limpiar resultados del cálculo anterior
                              _mrpData = [];
                              _comercialesData = [];
                              _orphanData = [];
                              _resumenStockMrp = null;
                              _optFabricables = [];
                              _optSobrestock = [];
                              _optDescartadasMedida = [];
                              _optResumenCut = null;
                              _optAreaDisponibleMm2 = null;
                              _optMaterial = '';
                              _optCalibre = '';
                              _optLargoMp = '';
                              _optAnchoMp = '';
                              if (_optRevisionIds.isEmpty) {
                                _optRevisionIds.add(val);
                              }
                              _errorMessage = null;
                              _tabIndex = 0;
                            });
                            // Auto-calcular sin esperar a que el usuario
                            // presione el botón "Calcular Requerimiento"
                            _calculateMRP();
                          },
                        ),
                        if (_selectedRevisionClientes != null &&
                            _selectedRevisionClientes!.isNotEmpty)
                          Padding(
                            padding:
                                const EdgeInsets.only(top: 4, left: 4),
                            child: Row(
                              children: [
                                Icon(
                                  FluentIcons.people,
                                  size: 11,
                                  color: palette.actionInfo.withValues(alpha: 0.75),
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    'Aplica para: $_selectedRevisionClientes',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontStyle: FontStyle.italic,
                                      color: palette.actionInfo.withValues(alpha: 0.82),
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                    maxLines: 1,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
            Tooltip(
              message: "Exportar a Excel",
              child: IconButton(
                icon: const Icon(FluentIcons.excel_logo, color: Color(0xFF22C55E)),
                onPressed: hasResults ? _exportToExcel : null,
              ),
            ),
          ],
        ),
      ),
      content: Container(
        color: palette.surfaceBase,
        child: _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    if (_isCalculating) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ProgressRing(),
            SizedBox(height: 15),
            Text("Procesando explosión de materiales inferior a superior..."),
          ],
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Text(
          "Error: $_errorMessage",
          style: const TextStyle(
              color: Color(0xFFD32F2F), fontWeight: FontWeight.bold),
        ),
      );
    }

    if (widget.mode == MRPViewMode.requerimientos &&
        _mrpData.isEmpty &&
        _comercialesData.isEmpty &&
        _orphanData.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(FluentIcons.manufacturing,
                size: 48,
                color: FluentTheme.of(context)
                    .typography
                    .body
                    ?.color
                    ?.withValues(alpha: 0.25)),
            const SizedBox(height: 16),
            Text(
              "Selecciona una Revisión de Ingeniería y presiona Calcular.",
              style: FluentTheme.of(context).typography.body?.copyWith(
                    color: fluentSecondaryTextColor(context),
                  ) ??
                  fluentSecondaryTextStyle(context),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Revisión seleccionada ────────────────────────────────────────
          if (_selectedRevisionName != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12.0),
              child: Row(
                children: [
                  const Icon(FluentIcons.file_code, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _selectedRevisionName!,
                      style: FluentTheme.of(context)
                          .typography
                          .bodyStrong
                          ?.copyWith(fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 2,
                    ),
                  ),
                ],
              ),
            ),

          if (widget.mode == MRPViewMode.requerimientos) ...[
            // ── Pestañas ───────────────────────────────────────────────────
            _buildTabBar(),
            const SizedBox(height: 12),
            _buildFiltrosOperativos(),
            const SizedBox(height: 8),
            Expanded(child: _buildActivePanel()),
          ] else ...[
            Expanded(child: _buildOptimizarCortePanel()),
          ],
        ],
      ),
    );
  }

  // ── Tab bar ───────────────────────────────────────────────────────────────

  Widget _buildTabBar() {
    return Row(
      children: [
        _tabButton(
          index: 0,
          icon: FluentIcons.manufacturing,
          label: 'Materia Prima / Placas',
          count: _mrpData.length,
          activeColor: const Color(0xFF1565C0),
        ),
        const SizedBox(width: 8),
        _tabButton(
          index: 1,
          icon: FluentIcons.shop,
          label: 'Componentes Comerciales',
          count: _comercialesData.length,
          activeColor: const Color(0xFF6A1B9A),
        ),
        const SizedBox(width: 8),
        _tabButton(
          index: 2,
          icon: FluentIcons.warning,
          label: 'Auditoría / Huérfanos',
          count: _orphanData.length,
          activeColor: const Color(0xFFC62828),
        ),
      ],
    );
  }

  Widget _tabButton({
    required int index,
    required IconData icon,
    required String label,
    required int count,
    required Color activeColor,
  }) {
    final isActive = _tabIndex == index;
    final isDark = FluentTheme.of(context).brightness == Brightness.dark;
    final textColor = isActive
        ? Colors.white
        : (isDark
            ? Colors.white.withValues(alpha: 0.75)
            : Colors.black.withValues(alpha: 0.65));

    return GestureDetector(
      onTap: () => setState(() => _tabIndex = index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? activeColor : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isActive
                ? activeColor
                : (isDark
                    ? Colors.white.withValues(alpha: 0.2)
                    : Colors.black.withValues(alpha: 0.15)),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: textColor),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight:
                      isActive ? FontWeight.bold : FontWeight.normal,
                  color: textColor),
            ),
            const SizedBox(width: 6),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: isActive
                    ? Colors.white.withValues(alpha: 0.25)
                    : (isDark
                        ? Colors.white.withValues(alpha: 0.1)
                        : Colors.black.withValues(alpha: 0.08)),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$count',
                style: TextStyle(fontSize: 11, color: textColor),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Panels ────────────────────────────────────────────────────────────────

  Widget _buildFiltrosOperativos() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: 240,
          child: TextBox(
            placeholder: 'Filtrar material / acción...',
            onChanged: (v) => setState(() => _filtroTexto = v),
          ),
        ),
        SizedBox(
          width: 140,
          child: ComboBox<String>(
            value: _filtroRiesgo,
            isExpanded: true,
            items: const [
              ComboBoxItem(value: 'Todos', child: Text('Riesgo: Todos')),
              ComboBoxItem(value: 'Crítico', child: Text('Crítico')),
              ComboBoxItem(value: 'Alerta', child: Text('Alerta')),
              ComboBoxItem(value: 'Estable', child: Text('Estable')),
            ],
            onChanged: (v) => setState(() => _filtroRiesgo = v ?? 'Todos'),
          ),
        ),
        ToggleSwitch(
          checked: _soloConBrecha,
          content: const Text('Solo con brecha'),
          onChanged: (v) => setState(() => _soloConBrecha = v),
        ),
      ],
    );
  }

  Widget _buildActivePanel() {
    switch (_tabIndex) {
      case 0:
        return _buildMPPanel();
      case 1:
        return _buildComercialPanel();
      case 2:
        return _buildOrphanPanel();
      default:
        return const SizedBox();
    }
  }

  // Panel 0 — Materia Prima / Placas
  Widget _buildMPPanel() {
    final mp = _mrpFiltrado;
    if (mp.isEmpty) {
      return const Center(
        child: Text("No hay resultados para los filtros actuales."),
      );
    }
    return Container(
      decoration: _cardDecoration(),
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(8.0),
              children: [
                _buildHeaderRow(),
                const Divider(),
                ...mp.map((row) => _buildDataRow(row)),
              ],
            ),
          ),
          _buildStockSummaryFooter(forComerciales: false),
        ],
      ),
    );
  }

  // Panel 1 — Componentes Comerciales
  Widget _buildComercialPanel() {
    if (_comercialesData.isEmpty) {
      return const Center(
        child: Text(
            "No se encontraron componentes comerciales en esta revisión."),
      );
    }
    return Container(
      decoration: _cardDecoration(),
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(8.0),
              children: [
                _buildComercialHeaderRow(),
                const Divider(),
                ..._comercialesData.map((row) => _buildComercialDataRow(row)),
              ],
            ),
          ),
          _buildStockSummaryFooter(forComerciales: true),
        ],
      ),
    );
  }

  // Panel 2 — Huérfanos / Auditoría
  Widget _buildOrphanPanel() {
    if (_orphanData.isEmpty) {
      return const Center(
        child: Text("Sin piezas huérfanas. ¡Ingeniería al 100%!"),
      );
    }
    return Container(
      decoration: _cardDecoration(),
      child: ListView(
        padding: const EdgeInsets.all(8.0),
        children: [
          _buildOrphanHeaderRow(),
          const Divider(),
          ..._orphanData.map((row) => _buildOrphanDataRow(row)),
        ],
      ),
    );
  }

  Widget _buildOptimizarCortePanel() {
    final revisionItems = _revisionsList
        .map((e) => Map<String, dynamic>.from(e))
        .where((e) => e['id'] is int)
        .toList();
    final materialOptions = _optMaterialOptions;
    final calibreOptions = _optCalibreOptions;
    final hasCatalogOptions = materialOptions.isNotEmpty;
    return Container(
      decoration: _cardDecoration(),
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text(
            'Optimización de uso de materia prima',
            style: FluentTheme.of(context).typography.subtitle,
          ),
          const SizedBox(height: 8),
          Text(
            'Indica el retazo o chapa (largo × ancho en mm) y cuántas piezas iguales tienes; '
            'solo se sugieren cortes que caben en esa medida (como en retacería). '
            'Si dejas largo/ancho vacíos, la cantidad se interpreta como mm² totales (modo anterior).',
            style: FluentTheme.of(context).typography.body,
          ),
          const SizedBox(height: 10),
          InfoBar(
            title: const Text('En desarrollo'),
            content: const Text(
              'La optimización de corte MP aún no está completa. '
              'Los resultados son orientativos; no sustituyen criterio de taller ni ingeniería.',
            ),
            severity: InfoBarSeverity.warning,
          ),
          if (_showDevCorteNotaCorteMp) ...[
            const SizedBox(height: 8),
            InfoBar(
              title: const Text('Nota interna (desarrollo)'),
              content: const Text(
                'Falta ajustar la lógica de optimización / nesting y validación con casos reales.',
              ),
              severity: InfoBarSeverity.info,
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              SizedBox(
                width: 290,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Material oficial'),
                    const SizedBox(height: 4),
                    ComboBox<String>(
                      isExpanded: true,
                      value: _optMaterial.isEmpty ? null : _optMaterial,
                      placeholder: Text(
                        hasCatalogOptions
                            ? 'Selecciona material'
                            : 'Sin materiales disponibles',
                        overflow: TextOverflow.ellipsis,
                      ),
                      items: materialOptions
                          .map(
                            (m) => ComboBoxItem<String>(
                              value: m,
                              child: Text(m, overflow: TextOverflow.ellipsis),
                            ),
                          )
                          .toList(),
                      onChanged: hasCatalogOptions
                          ? (v) {
                              if (v == null) return;
                              setState(() {
                                _optMaterial = v;
                                final calibres = _optCalibreOptions;
                                if (_optCalibre.isNotEmpty &&
                                    !calibres.contains(_optCalibre)) {
                                  _optCalibre = '';
                                }
                              });
                            }
                          : null,
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 180,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Calibre (opcional)'),
                    const SizedBox(height: 4),
                    ComboBox<String>(
                      isExpanded: true,
                      value: _optCalibre.isEmpty ? null : _optCalibre,
                      placeholder: const Text(
                        'Todos',
                        overflow: TextOverflow.ellipsis,
                      ),
                      items: calibreOptions
                          .map(
                            (c) => ComboBoxItem<String>(
                              value: c,
                              child: Text(c, overflow: TextOverflow.ellipsis),
                            ),
                          )
                          .toList(),
                      onChanged: calibreOptions.isNotEmpty
                          ? (v) => setState(() => _optCalibre = v ?? '')
                          : null,
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 120,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Largo MP (mm)'),
                    const SizedBox(height: 4),
                    TextBox(
                      placeholder: 'Ej. 3000',
                      onChanged: (v) => _optLargoMp = v,
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 120,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Ancho MP (mm)'),
                    const SizedBox(height: 4),
                    TextBox(
                      placeholder: 'Ej. 1500',
                      onChanged: (v) => _optAnchoMp = v,
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 200,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _optLargoMp.trim().isNotEmpty && _optAnchoMp.trim().isNotEmpty
                          ? 'Nº chapas / retazos'
                          : 'Cantidad (mm² o nº chapas)',
                      style: FluentTheme.of(context).typography.body,
                    ),
                    const SizedBox(height: 4),
                    TextBox(
                      placeholder: _optLargoMp.trim().isNotEmpty ? 'Ej. 1' : 'mm² o cantidad',
                      onChanged: (v) => _optDisponible = v,
                    ),
                  ],
                ),
              ),
              ToggleSwitch(
                checked: _optExcluirStockPositivo,
                content: const Text('Sobrestock si stock > 0'),
                onChanged: (v) => setState(() => _optExcluirStockPositivo = v),
              ),
              FilledButton(
                onPressed: _isOptimizingCut ? null : _optimizarCorteMp,
                child: _isOptimizingCut
                    ? const ProgressRing(strokeWidth: 2)
                    : const Text('Optimizar'),
              ),
            ],
          ),
          if (!hasCatalogOptions)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'No hay catálogo de materiales/calibres para esta revisión. '
                'Selecciona otra revisión o recalcula MRP.',
                style: FluentTheme.of(context).typography.caption,
              ),
            ),
          if (_optAreaDisponibleMm2 != null && _optAreaDisponibleMm2! > 0) ...[
            const SizedBox(height: 10),
            Text(
              'Superficie disponible estimada: ${_formatArea(_optAreaDisponibleMm2!)}',
              style: FluentTheme.of(context).typography.caption,
            ),
          ],
          const SizedBox(height: 12),
          Expander(
            header: const Text('Revisiones incluidas'),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final rev in revisionItems)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Checkbox(
                      checked: _optRevisionIds.contains(rev['id'] as int),
                      onChanged: (v) {
                        final id = rev['id'] as int;
                        setState(() {
                          if (v == true) {
                            _optRevisionIds.add(id);
                          } else {
                            _optRevisionIds.remove(id);
                          }
                        });
                      },
                      content: Text(
                        rev['name']?.toString() ?? 'Revisión',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Fabricables (${_optFabricables.length})',
            style: FluentTheme.of(context).typography.bodyStrong,
          ),
          const SizedBox(height: 6),
          for (final row in _optFabricables)
            ListTile.selectable(
              title: Text('${row['codigo_pieza'] ?? '-'} · ${row['descripcion'] ?? ''}'),
              subtitle: Text(
                'Sugerida: ${row['cantidad_sugerida_fabricar'] ?? 0} · '
                'Consumo: ${_decFormat.format(_d(row['material_consumido_estimado']))}',
              ),
            ),
          if (_optFabricables.isEmpty)
            const Text('Sin piezas fabricables para los parámetros actuales.'),
          if (_optDescartadasMedida.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              'No caben en la medida ingresada (${_optDescartadasMedida.length})',
              style: FluentTheme.of(context).typography.bodyStrong,
            ),
            const SizedBox(height: 6),
            for (final row in _optDescartadasMedida)
              ListTile.selectable(
                title: Text('${row['codigo_pieza'] ?? '-'} · ${row['descripcion'] ?? ''}'),
                subtitle: Text(
                  row['motivo'] == 'sin_medidas_cad'
                      ? 'Sin largo/ancho en maestro (CAD/DXF)'
                      : 'Pieza más grande que el retazo (con giro)',
                ),
              ),
          ],
          const SizedBox(height: 14),
          Text(
            'Sobrestock (${_optSobrestock.length})',
            style: FluentTheme.of(context).typography.bodyStrong,
          ),
          const SizedBox(height: 6),
          for (final row in _optSobrestock)
            ListTile.selectable(
              title: Text('${row['codigo_pieza'] ?? '-'} · ${row['descripcion'] ?? ''}'),
              subtitle: Text(
                'Stock: ${_decFormat.format(_d(row['stock_pt']))} · '
                'Demanda: ${_decFormat.format(_d(row['demanda_en_revisiones']))}',
              ),
            ),
          if (_optSobrestock.isEmpty)
            const Text('Sin piezas en sobrestock con la regla seleccionada.'),
        ],
      ),
    );
  }

  BoxDecoration _cardDecoration() => BoxDecoration(
        color: FluentTheme.of(context).cardColor,
        borderRadius: BorderRadius.circular(8.0),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      );

  Widget _buildStockSummaryFooter({required bool forComerciales}) {
    final resumen = _resumenStockMrp;
    if (resumen == null) return const SizedBox.shrink();
    final block = forComerciales
        ? Map<String, dynamic>.from(resumen['comerciales'] ?? const {})
        : Map<String, dynamic>.from(resumen['materia_prima_estimado'] ?? const {});
    final demanda = _d(block['demanda_total_unidades']);
    final stock = forComerciales
        ? _d(block['stock_total_unidades'])
        : _d(block['stock_asociado_total_unidades']);
    final faltante = forComerciales
        ? _d(block['faltante_total_unidades'])
        : _d(block['brecha_total_unidades']);
    final lineas = forComerciales
        ? _d(block['lineas_con_faltante']).toInt()
        : _d(block['lineas_con_brecha']).toInt();
    final syncText = (resumen['ultima_sync_stock_pt'] ?? '').toString();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Colors.grey.withValues(alpha: 0.25))),
        color: Colors.black.withValues(alpha: 0.03),
      ),
      child: Wrap(
        spacing: 16,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            forComerciales ? 'Resumen Comerciales' : 'Resumen MP (estimado)',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          Text('Demanda: ${_numFormat.format(demanda.round())}'),
          Text('Stock: ${_numFormat.format(stock.round())}'),
          Text(
            forComerciales
                ? 'Faltante: ${_numFormat.format(faltante.round())}'
                : 'Brecha: ${_numFormat.format(faltante.round())}',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: faltante > 0 ? const Color(0xFFC62828) : const Color(0xFF2E7D32),
            ),
          ),
          Text('Líneas con brecha: $lineas'),
          if (syncText.isNotEmpty)
            Text(
              'Última sync stock: $syncText',
              style: TextStyle(
                fontSize: 11,
                color: Colors.blue.withValues(alpha: 0.8),
                fontStyle: FontStyle.italic,
              ),
            ),
          if (!forComerciales)
            const Text(
              'Valores estimados por agrupación de material.',
              style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
            ),
        ],
      ),
    );
  }

  // ── Materia Prima rows ────────────────────────────────────────────────────

  Widget _buildHeaderRow() {
    final style = FluentTheme.of(context)
        .typography
        .body
        ?.copyWith(fontWeight: FontWeight.bold);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 12.0),
      child: Row(
        children: [
          Expanded(flex: 3, child: Text('MATERIAL OFICIAL', style: style)),
          Expanded(flex: 2, child: Text('CALIBRE / ESPESOR', style: style)),
          Expanded(
              flex: 2,
              child:
                  Text('PIEZAS', style: style, textAlign: TextAlign.right)),
          Expanded(
              flex: 3,
              child: Text('ÁREA TOTAL REQUERIDA',
                  style: style, textAlign: TextAlign.right)),
          Expanded(
              flex: 2,
              child: Text('STOCK EST.',
                  style: style, textAlign: TextAlign.right)),
          Expanded(
              flex: 2,
              child: Text('BRECHA EST.',
                  style: style, textAlign: TextAlign.right)),
          Expanded(
              flex: 2,
              child: Text('RIESGO',
                  style: style, textAlign: TextAlign.right)),
          Expanded(
              flex: 4,
              child: Text('ORDEN DE COMPRA SUGERIDA',
                  style: style, textAlign: TextAlign.right)),
        ],
      ),
    );
  }

  Widget _buildDataRow(Map<String, dynamic> row) {
    final double areaMm2 = (row['Requerimiento_Area_mm2'] ?? 0).toDouble();
    final double piezas  = (row['Cantidad_Total_Piezas'] ?? 0).toDouble();
    final stockEst = _d(row['Stock_Asociado_Estimado']);
    final brechaEst = _d(row['Brecha_Estimada']);
    final riesgo = _riesgoMp(row);
    final isDark = FluentTheme.of(context).brightness == Brightness.dark;
    final dataColor = isDark
        ? Colors.white.withValues(alpha: 0.9)
        : Colors.black.withValues(alpha: 0.85);
    final base =
        TextStyle(color: dataColor, fontWeight: FontWeight.normal, fontSize: 13);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10.0, horizontal: 12.0),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              _materialOficialMP(row),
              style: base.copyWith(
                fontWeight: FontWeight.w600,
                color: _materialOficialMP(row) == 'FALTA ASIGNAR EN CAD'
                    ? (isDark ? Colors.orange.lighter : Colors.orange.darkest)
                    : null,
              ),
            ),
          ),
          Expanded(
              flex: 2,
              child: Text(
                  row['Calibre_Espesor']?.toString() ?? 'N/A',
                  style: base)),
          Expanded(
            flex: 2,
            child: Text(
              _numFormat.format(piezas),
              textAlign: TextAlign.right,
              style: base.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              _formatArea(areaMm2),
              textAlign: TextAlign.right,
              style: base,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              _numFormat.format(stockEst.round()),
              textAlign: TextAlign.right,
              style: base.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              _numFormat.format(brechaEst.round()),
              textAlign: TextAlign.right,
              style: base.copyWith(
                fontWeight: FontWeight.w700,
                color: brechaEst > 0
                    ? (isDark ? const Color(0xFFFFAB91) : const Color(0xFFC62828))
                    : (isDark ? const Color(0xFFB2DFDB) : const Color(0xFF2E7D32)),
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              riesgo,
              textAlign: TextAlign.right,
              style: base.copyWith(
                fontWeight: FontWeight.w700,
                color: riesgo == 'Crítico'
                    ? const Color(0xFFC62828)
                    : riesgo == 'Alerta'
                        ? const Color(0xFFEF6C00)
                        : const Color(0xFF2E7D32),
              ),
            ),
          ),
          Expanded(
            flex: 4,
            child: Text(
              row['Sugerencia_Compra']?.toString() ?? 'N/A',
              textAlign: TextAlign.right,
              style: base.copyWith(
                color: isDark ? Colors.orange.lighter : Colors.orange.darkest,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Comerciales rows ──────────────────────────────────────────────────────

  Widget _buildComercialHeaderRow() {
    final isDark = FluentTheme.of(context).brightness == Brightness.dark;
    final accentColor =
        isDark ? const Color(0xFFCE93D8) : const Color(0xFF6A1B9A);
    final style = FluentTheme.of(context)
        .typography
        .body
        ?.copyWith(fontWeight: FontWeight.bold, color: accentColor);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 12.0),
      child: Row(
        children: [
          Expanded(flex: 2, child: Text('CÓDIGO', style: style)),
          Expanded(flex: 4, child: Text('DESCRIPCIÓN', style: style)),
          Expanded(
              flex: 2,
              child: Text('CANTIDAD',
                  style: style, textAlign: TextAlign.right)),
          Expanded(
              flex: 3,
              child: Text('STOCK',
                  style: style, textAlign: TextAlign.right)),
          Expanded(
              flex: 3,
              child: Text('FALTANTE',
                  style: style, textAlign: TextAlign.right)),
          Expanded(
              flex: 2,
              child: Text('COBERTURA',
                  style: style, textAlign: TextAlign.right)),
          Expanded(
              flex: 3,
              child: Text('ACCIÓN',
                  style: style, textAlign: TextAlign.right)),
        ],
      ),
    );
  }

  Widget _buildComercialDataRow(Map<String, dynamic> row) {
    final isDark = FluentTheme.of(context).brightness == Brightness.dark;
    final dataColor = isDark
        ? Colors.white.withValues(alpha: 0.9)
        : Colors.black.withValues(alpha: 0.85);
    final base =
        TextStyle(color: dataColor, fontWeight: FontWeight.normal, fontSize: 13);
    final double cant = (row['Cantidad_Total'] ?? 0).toDouble();
    final double stock = _d(row['Stock_PT_Almacen']);
    final double faltante = _d(row['Cantidad_Faltante']);
    final double cobertura = _d(row['Cobertura_Pct']);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 12.0),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(
              row['Codigo_Pieza']?.toString() ?? '-',
              style: base.copyWith(
                fontWeight: FontWeight.w600,
                fontFamily: 'monospace',
              ),
            ),
          ),
          Expanded(
            flex: 4,
            child: Text(
              row['Descripcion']?.toString() ?? '-',
              style: base,
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              _numFormat.format(cant),
              textAlign: TextAlign.right,
              style: base.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              _numFormat.format(stock.round()),
              textAlign: TextAlign.right,
              style: base.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              _numFormat.format(faltante.round()),
              textAlign: TextAlign.right,
              style: base.copyWith(
                fontWeight: FontWeight.bold,
                color: faltante > 0
                    ? (isDark ? const Color(0xFFFFAB91) : const Color(0xFFC62828))
                    : (isDark ? const Color(0xFFB2DFDB) : const Color(0xFF2E7D32)),
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              '${cobertura.toStringAsFixed(1)}%',
              textAlign: TextAlign.right,
              style: base.copyWith(
                color: cobertura >= 100
                    ? (isDark ? const Color(0xFFB2DFDB) : const Color(0xFF2E7D32))
                    : (isDark ? const Color(0xFFFFAB91) : const Color(0xFFC62828)),
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              faltante <= 0
                  ? 'Cubierto con stock'
                  : 'Comprar ${_numFormat.format(faltante.round())} pzs',
              textAlign: TextAlign.right,
              style: base.copyWith(
                color: faltante <= 0
                    ? (isDark ? const Color(0xFFB2DFDB) : const Color(0xFF2E7D32))
                    : (isDark ? const Color(0xFFCE93D8) : const Color(0xFF6A1B9A)),
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Orphan rows ───────────────────────────────────────────────────────────

  Widget _buildOrphanHeaderRow() {
    final style = FluentTheme.of(context).typography.body?.copyWith(
        fontWeight: FontWeight.bold, color: const Color(0xFFC62828));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 12.0),
      child: Row(
        children: [
          Expanded(flex: 3, child: Text('CÓDIGO DE PIEZA', style: style)),
          Expanded(flex: 3, child: Text('ENSAMBLE', style: style)),
          Expanded(flex: 3, child: Text('MATERIAL', style: style)),
          Expanded(
              flex: 1,
              child:
                  Text('CANT', style: style, textAlign: TextAlign.right)),
          Expanded(
              flex: 3,
              child: Text('MOTIVO DE RECHAZO',
                  style: style, textAlign: TextAlign.right)),
        ],
      ),
    );
  }

  Widget _buildOrphanDataRow(Map<String, dynamic> row) {
    final body = FluentTheme.of(context).typography.body;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 12.0),
      child: Row(
        children: [
          Expanded(
              flex: 3,
              child: Text(row['Codigo_Pieza']?.toString() ?? '-',
                  style: body)),
          Expanded(
              flex: 3,
              child: Text(row['Nombre_Ensamble']?.toString() ?? '-',
                  style: body,
                  overflow: TextOverflow.ellipsis)),
          Expanded(
              flex: 3,
              child:
                  Text(row['Material']?.toString() ?? '-', style: body)),
          Expanded(
            flex: 1,
            child: Text(
              row['Cantidad']?.toString() ?? '0',
              style: body,
              textAlign: TextAlign.right,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              row['Motivo_Rechazo']?.toString() ?? '-',
              style: body?.copyWith(
                  color: const Color(0xFFC62828),
                  fontWeight: FontWeight.bold),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}
