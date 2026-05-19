import 'package:fluent_ui/fluent_ui.dart';
import 'package:intl/intl.dart';
import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart' as excel_lib;
import '../utils/excel_helper.dart';
import '../services/api_client.dart';
import '../theme/ui_tokens.dart';
import '../widgets/compact_page_header.dart';
import '../services/app_role.dart';
import 'mrp_compra_config_dialog.dart';

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

  /// Conjunto de claves de material cuyas filas están expandidas en la tabla MP.
  final Set<String> _expandedMaterials = <String>{};

  Map<String, dynamic> _compraConfig = {};
  List<Map<String, dynamic>> _formatosCompra = [];

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
    if (txt.isEmpty) return _mrpData;
    return _mrpData.where((row) {
      final hay = [
        _materialOficialMP(row),
        row['Calibre_Espesor']?.toString() ?? '',
        row['Sugerencia_Compra']?.toString() ?? '',
      ].join(' ').toLowerCase().contains(txt);
      return hay;
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
            _compraConfig = data['compra_config'] is Map
                ? Map<String, dynamic>.from(data['compra_config'] as Map)
                : {};
            _formatosCompra = data['formatos_compra'] is List
                ? List<Map<String, dynamic>>.from(
                    (data['formatos_compra'] as List).map(
                      (e) => Map<String, dynamic>.from(e as Map),
                    ),
                  )
                : [];
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

    // ── Hoja 1: Resumen de compra ─────────────────────────────────────────────
    // Incluye todas las categorías: MP calculada, compra directa, comerciales
    // y piezas sin medidas (informativo).
    excel_lib.Sheet sheetResumen = excelFile['Resumen_Compra'];
    const _kResumenCols = 10;
    final resumenHeaders = [
      'Material oficial',      // 0
      'Calibre',               // 1
      'Tipo',                  // 2
      'Largo placa (pies)',    // 3
      'Ancho placa (pies)',    // 4
      'Distancia tramo (m)',   // 5
      'Área req. (m²)',        // 6
      'Área req. (in²)',       // 7
      'Cantidad a Comprar',    // 8  ← destacado amarillo para MP
      'Unidad de Compra',      // 9
    ];
    Map<int, int> resumenWidths = {};
    for (int i = 0; i < resumenHeaders.length; i++) {
      sheetResumen.updateCell(
        excel_lib.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0),
        excel_lib.TextCellValue(resumenHeaders[i]),
        cellStyle: headerStyle,
      );
      ExcelHelper.updateMaxWith(resumenWidths, i, resumenHeaders[i]);
    }

    final sectionStyle = excel_lib.CellStyle(
      backgroundColorHex: excel_lib.ExcelColor.fromHexString('#2D4A7A'),
      fontColorHex: excel_lib.ExcelColor.fromHexString('#FFFFFF'),
      bold: true,
      verticalAlign: excel_lib.VerticalAlign.Center,
    );
    final directaStyle = excel_lib.CellStyle(
      backgroundColorHex: excel_lib.ExcelColor.fromHexString('#FFF3E0'),
      fontColorHex: excel_lib.ExcelColor.fromHexString('#7B3F00'),
      verticalAlign: excel_lib.VerticalAlign.Center,
    );
    final comStyle = excel_lib.CellStyle(
      backgroundColorHex: excel_lib.ExcelColor.fromHexString('#F3E5F5'),
      fontColorHex: excel_lib.ExcelColor.fromHexString('#4A148C'),
      verticalAlign: excel_lib.VerticalAlign.Center,
    );
    final orphanStyle = excel_lib.CellStyle(
      backgroundColorHex: excel_lib.ExcelColor.fromHexString('#FAFAFA'),
      fontColorHex: excel_lib.ExcelColor.fromHexString('#757575'),
      verticalAlign: excel_lib.VerticalAlign.Center,
    );

    void _writeSectionHeader(int rowIdx, String title) {
      sheetResumen.updateCell(
        excel_lib.CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: rowIdx),
        excel_lib.TextCellValue(title),
        cellStyle: sectionStyle,
      );
      ExcelHelper.updateMaxWith(resumenWidths, 0, title);
      for (int c = 1; c < _kResumenCols; c++) {
        sheetResumen.updateCell(
          excel_lib.CellIndex.indexByColumnRow(
              columnIndex: c, rowIndex: rowIdx),
          excel_lib.TextCellValue(''),
          cellStyle: sectionStyle,
        );
      }
    }

    int resumenRow = 1;

    // ── Sección 1: Materia Prima (cálculo por área / longitud) ──────────────
    _writeSectionHeader(resumenRow, '--- MATERIA PRIMA (cálculo por área / longitud) ---');
    resumenRow++;

    excel_lib.CellValue _numOrEmpty(dynamic v) {
      if (v == null) return excel_lib.TextCellValue('');
      final d = _d(v);
      if (d <= 0) return excel_lib.TextCellValue('');
      return excel_lib.DoubleCellValue(d);
    }

    // Estilo amarillo vibrante para la columna "Cantidad a Comprar" en filas MP
    final resumenCantStyle = excel_lib.CellStyle(
      backgroundColorHex: excel_lib.ExcelColor.fromHexString('#FFD600'),
      fontColorHex: excel_lib.ExcelColor.fromHexString('#1A237E'),
      bold: true,
      horizontalAlign: excel_lib.HorizontalAlign.Center,
      verticalAlign: excel_lib.VerticalAlign.Center,
    );

    for (final row in _mrpData) {
      final habilitada = row['Compra_Habilitada'] != false;
      final sug = row['Sugerencia_Compra']?.toString() ?? '';
      final isDirecta = sug.toLowerCase().contains('directa');
      if (!habilitada || sug.startsWith('—') || isDirecta) continue;
      if (sug.startsWith('Pendiente')) continue;

      final areaMm2      = _d(row['Requerimiento_Area_mm2']);
      final areaM2       = areaMm2 / 1_000_000.0;
      final areaIn2      = areaMm2 / 645.16;
      final lp           = row['Compra_Largo_Pies'];
      final ap           = row['Compra_Ancho_Pies'];
      final dm           = row['Compra_Distancia_Metros'];
      final tipo         = row['Tipo_Compra']?.toString() ?? '';
      final compraCant   = _d(row['Compra_Cantidad']);
      final compraUnidad = row['Compra_Unidad']?.toString() ?? '';

      final cells = [
        excel_lib.TextCellValue(_materialOficialMP(row)),
        excel_lib.TextCellValue(row['Calibre_Espesor']?.toString() ?? ''),
        excel_lib.TextCellValue(tipo == 'perfil' ? 'Perfil' : 'Placa'),
        _numOrEmpty(lp),
        _numOrEmpty(ap),
        _numOrEmpty(dm),
        areaMm2 > 0 ? excel_lib.DoubleCellValue(areaM2)  : excel_lib.TextCellValue(''),
        areaMm2 > 0 ? excel_lib.DoubleCellValue(areaIn2) : excel_lib.TextCellValue(''),
        compraCant > 0 ? excel_lib.DoubleCellValue(compraCant) : excel_lib.TextCellValue(''),
        excel_lib.TextCellValue(compraUnidad),
      ];
      for (int c = 0; c < cells.length; c++) {
        sheetResumen.updateCell(
          excel_lib.CellIndex.indexByColumnRow(
              columnIndex: c, rowIndex: resumenRow),
          cells[c],
          // Highlight the "Cantidad a Comprar" column
          cellStyle: c == 8 ? resumenCantStyle : null,
        );
        ExcelHelper.updateMaxWith(resumenWidths, c, cells[c].toString());
      }
      resumenRow++;
    }

    // ── Sección 2: Compra directa (seguro de resorte, spring seal, etc.) ────
    final directaRows = _mrpData.where((row) {
      final sug = row['Sugerencia_Compra']?.toString().toLowerCase() ?? '';
      return sug.contains('directa');
    }).toList();

    if (directaRows.isNotEmpty) {
      resumenRow++;
      _writeSectionHeader(resumenRow,
          '--- COMPRA DIRECTA (subensambles / piezas sin cálculo de área) ---');
      resumenRow++;
      for (final row in directaRows) {
        final stock   = ExcelHelper.cleanToInt(row['Stock_Asociado_Estimado']);
        final brecha  = ExcelHelper.cleanToInt(row['Brecha_Estimada']);
        final matName = _materialOficialMP(row);
        final cantVal = brecha > 0 ? brecha : 0;
        final notaStr = brecha > 0 ? '' : 'En stock ($stock u.)';
        final cells = [
          excel_lib.TextCellValue(matName),              // 0
          excel_lib.TextCellValue(row['Calibre_Espesor']?.toString() ?? 'N/A'), // 1
          excel_lib.TextCellValue('Directa'),            // 2
          excel_lib.TextCellValue(''),                   // 3
          excel_lib.TextCellValue(''),                   // 4
          excel_lib.TextCellValue(''),                   // 5
          excel_lib.TextCellValue(''),                   // 6
          excel_lib.TextCellValue(''),                   // 7
          cantVal > 0
              ? excel_lib.IntCellValue(cantVal)
              : excel_lib.TextCellValue(notaStr),        // 8 Cantidad
          excel_lib.TextCellValue(cantVal > 0 ? 'pz' : ''), // 9 Unidad
        ];
        for (int c = 0; c < cells.length; c++) {
          sheetResumen.updateCell(
            excel_lib.CellIndex.indexByColumnRow(
                columnIndex: c, rowIndex: resumenRow),
            cells[c],
            cellStyle: directaStyle,
          );
          ExcelHelper.updateMaxWith(resumenWidths, c, cells[c].toString());
        }
        resumenRow++;
      }
    }

    // ── Sección 3: Componentes Comerciales ───────────────────────────────────
    if (_comercialesData.isNotEmpty) {
      resumenRow++;
      _writeSectionHeader(resumenRow, '--- COMPONENTES COMERCIALES ---');
      resumenRow++;
      for (final row in _comercialesData) {
        final stock    = ExcelHelper.cleanToInt(row['Stock_PT_Almacen']);
        final faltante = ExcelHelper.cleanToInt(row['Cantidad_Faltante']);
        final desc     = row['Descripcion']?.toString() ?? '-';
        final codigo   = row['Codigo_Pieza']?.toString() ?? '-';
        final cantVal  = faltante > 0 ? faltante : 0;
        final notaStr  = faltante <= 0 ? 'En stock ($stock u.)' : '';
        final cells = [
          excel_lib.TextCellValue(desc),                 // 0
          excel_lib.TextCellValue(codigo),               // 1
          excel_lib.TextCellValue('Comercial'),          // 2
          excel_lib.TextCellValue(''),                   // 3
          excel_lib.TextCellValue(''),                   // 4
          excel_lib.TextCellValue(''),                   // 5
          excel_lib.TextCellValue(''),                   // 6
          excel_lib.TextCellValue(''),                   // 7
          cantVal > 0
              ? excel_lib.IntCellValue(cantVal)
              : excel_lib.TextCellValue(notaStr),        // 8 Cantidad
          excel_lib.TextCellValue(cantVal > 0 ? 'pz' : ''), // 9 Unidad
        ];
        for (int c = 0; c < cells.length; c++) {
          sheetResumen.updateCell(
            excel_lib.CellIndex.indexByColumnRow(
                columnIndex: c, rowIndex: resumenRow),
            cells[c],
            cellStyle: comStyle,
          );
          ExcelHelper.updateMaxWith(resumenWidths, c, cells[c].toString());
        }
        resumenRow++;
      }
    }

    // ── Sección 4: Sin Medidas — informativo para compras sin dimensión CAD ──
    final orphanSinMedida = _orphanData
        .where((r) =>
            (r['Motivo_Rechazo']?.toString() ?? '').toLowerCase().contains('medida') ||
            (r['Motivo_Rechazo']?.toString() ?? '').toLowerCase().contains('sin largo'))
        .toList();
    if (orphanSinMedida.isNotEmpty) {
      resumenRow++;
      _writeSectionHeader(resumenRow,
          '--- SIN MEDIDAS CAD (informativo — verificar antes de comprar) ---');
      resumenRow++;
      for (final row in orphanSinMedida) {
        final mat    = row['Material']?.toString() ?? '-';
        final codigo = row['Codigo_Pieza']?.toString() ?? '-';
        final cant   = ExcelHelper.cleanToInt(row['Cantidad']);
        final motivo = row['Motivo_Rechazo']?.toString() ?? '-';
        final cells = [
          excel_lib.TextCellValue(mat),            // 0
          excel_lib.TextCellValue(codigo),         // 1
          excel_lib.TextCellValue('Sin medidas'),  // 2
          excel_lib.TextCellValue(''),             // 3
          excel_lib.TextCellValue(''),             // 4
          excel_lib.TextCellValue(''),             // 5
          excel_lib.TextCellValue(''),             // 6
          excel_lib.TextCellValue(motivo),         // 7  ← motivo en col area in²
          excel_lib.IntCellValue(cant),            // 8 Cantidad BOM
          excel_lib.TextCellValue('pz'),           // 9 Unidad
        ];
        for (int c = 0; c < cells.length; c++) {
          sheetResumen.updateCell(
            excel_lib.CellIndex.indexByColumnRow(
                columnIndex: c, rowIndex: resumenRow),
            cells[c],
            cellStyle: orphanStyle,
          );
          ExcelHelper.updateMaxWith(resumenWidths, c, cells[c].toString());
        }
        resumenRow++;
      }
    }

    ExcelHelper.applyAutoFit(sheetResumen, resumenWidths);

    // ── Hoja 2: Orden de Compra detallada (Materia Prima) ─────────────────────
    //
    // Columnas (12 en total):
    //  A  Material Oficial / Código Pieza   ("TOTAL [mat]" en fila padre)
    //  B  Calibre Canónico
    //  C  Demanda Total / Cant. Pieza
    //  D  Área Total m²  (numérica)
    //  E  Área Total in² (numérica)
    //  F  Largo Pieza mm
    //  G  Ancho Pieza mm
    //  H  Stock PT (u.)   piezas ya fabricadas en almacén PT
    //  I  Cómo se calcula el área (texto explicativo / fórmula)
    //  J  Cantidad a Comprar  ← destacado en amarillo vibrante en fila padre
    //  K  Unidad de Compra
    //  L  Desglose  (ej. "5 completas y 20% de la última")
    //
    // Estructura de filas:
    //  • Padre  (material): fondo azul #1E3A8A, texto blanco, negrita.
    //            Celda J: fondo #FFD600 (amarillo vibrante), texto #1A237E, negrita.
    //  • Hijo   (pieza)   : fondo #F0F4FF, texto azul oscuro.
    //  • Subtotal área     : fondo amarillo #FFF9C4, negrita.
    //  • Separador vacío   : fondo blanco entre materiales.

    excel_lib.Sheet sheetOC = excelFile['Orden_Compra'];
    excelFile.delete('Sheet1');

    // ── Estilos ───────────────────────────────────────────────────────────────
    const _kTotalCols = 12;

    final parentStyle = excel_lib.CellStyle(
      backgroundColorHex: excel_lib.ExcelColor.fromHexString('#1E3A8A'),
      fontColorHex: excel_lib.ExcelColor.fromHexString('#FFFFFF'),
      bold: true,
      verticalAlign: excel_lib.VerticalAlign.Center,
    );
    final parentNumStyle = excel_lib.CellStyle(
      backgroundColorHex: excel_lib.ExcelColor.fromHexString('#1E3A8A'),
      fontColorHex: excel_lib.ExcelColor.fromHexString('#FFFFFF'),
      bold: true,
      horizontalAlign: excel_lib.HorizontalAlign.Right,
      verticalAlign: excel_lib.VerticalAlign.Center,
    );
    // Celda J (Cantidad a Comprar) en fila padre: amarillo vibrante + texto azul oscuro
    final cantidadHighlightStyle = excel_lib.CellStyle(
      backgroundColorHex: excel_lib.ExcelColor.fromHexString('#FFD600'),
      fontColorHex: excel_lib.ExcelColor.fromHexString('#1A237E'),
      bold: true,
      horizontalAlign: excel_lib.HorizontalAlign.Center,
      verticalAlign: excel_lib.VerticalAlign.Center,
    );
    final childStyle = excel_lib.CellStyle(
      backgroundColorHex: excel_lib.ExcelColor.fromHexString('#F0F4FF'),
      fontColorHex: excel_lib.ExcelColor.fromHexString('#1A2744'),
      verticalAlign: excel_lib.VerticalAlign.Center,
    );
    final childNumStyle = excel_lib.CellStyle(
      backgroundColorHex: excel_lib.ExcelColor.fromHexString('#F0F4FF'),
      fontColorHex: excel_lib.ExcelColor.fromHexString('#1A2744'),
      horizontalAlign: excel_lib.HorizontalAlign.Right,
      verticalAlign: excel_lib.VerticalAlign.Center,
    );
    final subtotalStyle = excel_lib.CellStyle(
      backgroundColorHex: excel_lib.ExcelColor.fromHexString('#FFF9C4'),
      fontColorHex: excel_lib.ExcelColor.fromHexString('#5D4037'),
      bold: true,
      verticalAlign: excel_lib.VerticalAlign.Center,
    );
    final subtotalNumStyle = excel_lib.CellStyle(
      backgroundColorHex: excel_lib.ExcelColor.fromHexString('#FFF9C4'),
      fontColorHex: excel_lib.ExcelColor.fromHexString('#5D4037'),
      bold: true,
      horizontalAlign: excel_lib.HorizontalAlign.Right,
      verticalAlign: excel_lib.VerticalAlign.Center,
    );
    // Celda J en fila subtotal: mismo amarillo vibrante pero tono más suave
    final subtotalCantStyle = excel_lib.CellStyle(
      backgroundColorHex: excel_lib.ExcelColor.fromHexString('#FFF176'),
      fontColorHex: excel_lib.ExcelColor.fromHexString('#5D4037'),
      bold: true,
      horizontalAlign: excel_lib.HorizontalAlign.Center,
      verticalAlign: excel_lib.VerticalAlign.Center,
    );
    final sepStyle = excel_lib.CellStyle(
      backgroundColorHex: excel_lib.ExcelColor.fromHexString('#FFFFFF'),
    );

    // ── Cabecera ──────────────────────────────────────────────────────────────
    final ocHeaders = [
      'Material Oficial / Código Pieza',   // A
      'Calibre Canónico',                   // B
      'Demanda Total / Cant. Pieza',        // C
      'Área m²',                            // D
      'Área in²',                           // E
      'Largo Pieza (mm)',                   // F
      'Ancho Pieza (mm)',                   // G
      'Stock PT (u.) = piezas en almacén', // H
      'Cómo se calcula el Área',            // I
      'Cantidad a Comprar',                 // J  ← destacado
      'Unidad de Compra',                   // K
      'Desglose',                           // L
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

    // ── Helper: escribe una fila completa ─────────────────────────────────────
    void _writeRow(
      excel_lib.Sheet sheet,
      int rowIdx,
      List<(excel_lib.CellValue, excel_lib.CellStyle)> cells,
    ) {
      for (int c = 0; c < cells.length; c++) {
        sheet.updateCell(
          excel_lib.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: rowIdx),
          cells[c].$1,
          cellStyle: cells[c].$2,
        );
        ExcelHelper.updateMaxWith(ocWidths, c, cells[c].$1.toString());
      }
    }

    excel_lib.CellValue _txt(String s) => excel_lib.TextCellValue(s);
    excel_lib.CellValue _dbl(double v) => excel_lib.DoubleCellValue(v);
    excel_lib.CellValue _int(int v)    => excel_lib.IntCellValue(v);
    excel_lib.CellValue _emp()         => excel_lib.TextCellValue('');

    /// Calcula el texto de desglose: "5 completas y 20% de la última" / "Completas"
    String _desglose(double qty) {
      if (qty <= 0) return '';
      final int n = qty.floor();
      final double dec = qty - n;
      if (dec < 0.005) {
        return n == 1 ? '1 Completa' : '$n Completas';
      }
      final int pct = (dec * 100).round();
      if (n == 0) return '${pct}% de la ultima';
      return '$n completa${n == 1 ? '' : 's'} y ${pct}% de la ultima';
    }

    int excelRow = 1;

    for (final row in _mrpData) {
      final double areaMm2    = _d(row['Requerimiento_Area_mm2']);
      final double areaM2     = areaMm2 / 1_000_000.0;
      final double areaIn2    = areaMm2 / 645.16;
      final int    demanda    = ExcelHelper.cleanToInt(row['Cantidad_Total_Piezas']);
      final int    stockTot   = ExcelHelper.cleanToInt(row['Stock_Asociado_Estimado']);
      final String matName    = _materialOficialMP(row);
      final String calibre    = row['Calibre_Espesor']?.toString() ?? 'N/A';
      final String orden      = row['Sugerencia_Compra']?.toString() ?? 'N/A';

      // Structured purchase fields
      final double compraCant = _d(row['Compra_Cantidad']);
      final String compraUnidad = row['Compra_Unidad']?.toString() ?? '';
      final String desgloseStr  = _desglose(compraCant);

      // ── Fila padre (material): etiqueta "TOTAL [material]" ───────────────
      _writeRow(sheetOC, excelRow, [
        (_txt('TOTAL $matName'), parentStyle),     // A ← "TOTAL [material]"
        (_txt(calibre),          parentStyle),     // B
        (_int(demanda),          parentNumStyle),  // C
        (_dbl(areaM2),           parentNumStyle),  // D
        (_dbl(areaIn2),          parentNumStyle),  // E
        (_emp(),                 parentStyle),     // F
        (_emp(),                 parentStyle),     // G
        (_int(stockTot),         parentNumStyle),  // H
        (_emp(),                 parentStyle),     // I
        (compraCant > 0
            ? _dbl(compraCant)
            : _txt(orden),       cantidadHighlightStyle),   // J ← amarillo vibrante
        (_txt(compraUnidad),     parentStyle),     // K
        (_txt(desgloseStr),      parentStyle),     // L
      ]);
      excelRow++;

      // ── Filas hija (piezas individuales) ──────────────────────────────────
      final rawPiezas = row['piezas'];
      if (rawPiezas is List && rawPiezas.isNotEmpty) {
        for (final p in rawPiezas) {
          final pMap      = Map<String, dynamic>.from(p as Map);
          final String cod  = '  \u21b3 ${pMap['codigo_pieza'] ?? '-'}';
          final int    cant = ExcelHelper.cleanToInt(pMap['cantidad']);
          final double pAMm2  = _d(pMap['area_mm2']);
          final double pAM2   = pAMm2 / 1_000_000.0;
          final double pAIn2  = pAMm2 / 645.16;
          final double pAunit = _d(pMap['area_unitaria_mm2']);
          final double pLargo = _d(pMap['largo_mm']);
          final double pAncho = _d(pMap['ancho_mm']);
          final int    pStock = ExcelHelper.cleanToInt(pMap['stock_pieza']);

          String formulaTxt = '';
          if (pAMm2 > 0 && cant > 0) {
            final uM2 = pAunit / 1_000_000.0;
            formulaTxt = '$cant pzas x ${_decFormat.format(uM2)} m2/pza'
                ' = ${_decFormat.format(pAM2)} m2';
          }

          _writeRow(sheetOC, excelRow, [
            (_txt(cod),                                          childStyle),    // A
            (_emp(),                                             childStyle),    // B
            (_int(cant),                                         childNumStyle), // C
            (pAMm2 > 0 ? _dbl(pAM2)   : _emp(),                childNumStyle), // D
            (pAMm2 > 0 ? _dbl(pAIn2)  : _emp(),                childNumStyle), // E
            (pLargo > 0 ? _dbl(pLargo) : _emp(),               childNumStyle), // F
            (pAncho > 0 ? _dbl(pAncho) : _emp(),               childNumStyle), // G
            (_int(pStock),                                       childNumStyle), // H
            (_txt(formulaTxt),                                   childStyle),    // I
            (_emp(),                                             childStyle),    // J
            (_emp(),                                             childStyle),    // K
            (_emp(),                                             childStyle),    // L
          ]);
          excelRow++;
        }

        // ── Fila subtotal de área por material ────────────────────────────
        final String subLabel =
            '\u2211 TOTAL AREA: $matName';
        final String subFormula =
            'Suma de piezas: ${_decFormat.format(areaM2)} m2'
            ' = ${_decFormat.format(areaIn2)} in2';
        _writeRow(sheetOC, excelRow, [
          (_txt(subLabel),       subtotalStyle),    // A
          (_emp(),               subtotalStyle),    // B
          (_int(demanda),        subtotalNumStyle), // C
          (_dbl(areaM2),         subtotalNumStyle), // D
          (_dbl(areaIn2),        subtotalNumStyle), // E
          (_emp(),               subtotalStyle),    // F
          (_emp(),               subtotalStyle),    // G
          (_int(stockTot),       subtotalNumStyle), // H
          (_txt(subFormula),     subtotalStyle),    // I
          (compraCant > 0
              ? _dbl(compraCant)
              : _txt(orden),     subtotalCantStyle), // J ← mismo highlight
          (_txt(compraUnidad),   subtotalStyle),    // K
          (_txt(desgloseStr),    subtotalStyle),    // L
        ]);
        excelRow++;
      }

      // ── Fila separadora entre materiales ──────────────────────────────────
      for (int c = 0; c < _kTotalCols; c++) {
        sheetOC.updateCell(
          excel_lib.CellIndex.indexByColumnRow(
              columnIndex: c, rowIndex: excelRow),
          _emp(),
          cellStyle: sepStyle,
        );
      }
      excelRow++;
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
                  '${_mrpData.length} materiales MP · '
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

  // Área: m² = mm² / 1_000_000 ; in² = mm² / 645.16 (= 25.4² mm²/in²).
  // Equivalente al enunciado del usuario: in² = m² / 0.00064516.
  String _formatArea(double mm2) {
    if (mm2 == 0) return "0.00 m²  /  0.00 in²";
    final double m2  = mm2 / 1_000_000.0;
    final double in2 = mm2 / 645.16;
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
            if (widget.mode == MRPViewMode.requerimientos && hasResults)
              Tooltip(
                message: 'Configurar sugerencias de compra (placas / perfiles)',
                child: IconButton(
                  icon: const Icon(FluentIcons.shopping_cart),
                  onPressed: _selectedRevisionId == null
                      ? null
                      : () => MrpCompraConfigDialog.show(
                            context,
                            mrpRows: _mrpData,
                            initialConfig: _compraConfig,
                            formatos: _formatosCompra,
                            onSaved: _calculateMRP,
                          ),
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
      padding: const EdgeInsets.fromLTRB(12.0, 6.0, 12.0, 4.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Revisión seleccionada (banner compacto) ──────────────────────
          if (_selectedRevisionName != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4.0),
              child: Row(
                children: [
                  const Icon(FluentIcons.file_code, size: 14),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _selectedRevisionName!,
                      style: FluentTheme.of(context)
                          .typography
                          .bodyStrong
                          ?.copyWith(fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                ],
              ),
            ),

          if (widget.mode == MRPViewMode.requerimientos) ...[
            // ── Pestañas + filtros en la misma línea ─────────────────────
            _buildTabBarWithFilters(),
            const SizedBox(height: 4),
            Expanded(child: _buildActivePanel()),
          ] else ...[
            Expanded(child: _buildOptimizarCortePanel()),
          ],
        ],
      ),
    );
  }

  // ── Tab bar + filtros en una sola línea compacta ─────────────────────────

  Widget _buildTabBarWithFilters() {
    // Wrap evita overflow horizontal cuando el panel es estrecho (~486 px).
    return LayoutBuilder(
      builder: (context, constraints) {
        final filterWidth = constraints.maxWidth < 520
            ? constraints.maxWidth
            : 220.0;
        return Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _tabButton(
              index: 0,
              icon: FluentIcons.manufacturing,
              label: 'Materia Prima',
              count: _mrpData.length,
              activeColor: const Color(0xFF1565C0),
            ),
            _tabButton(
              index: 1,
              icon: FluentIcons.shop,
              label: 'Comerciales',
              count: _comercialesData.length,
              activeColor: const Color(0xFF6A1B9A),
            ),
            _tabButton(
              index: 2,
              icon: FluentIcons.warning,
              label: 'Huérfanos',
              count: _orphanData.length,
              activeColor: const Color(0xFFC62828),
            ),
            if (_tabIndex == 0)
              SizedBox(
                width: filterWidth,
                height: 28,
                child: TextBox(
                  placeholder: 'Filtrar material...',
                  onChanged: (v) => setState(() => _filtroTexto = v),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                ),
              ),
          ],
        );
      },
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
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isActive ? activeColor : Colors.transparent,
          borderRadius: BorderRadius.circular(5),
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
            Icon(icon, size: 13, color: textColor),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight:
                      isActive ? FontWeight.bold : FontWeight.normal,
                  color: textColor),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
            const SizedBox(width: 5),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: isActive
                    ? Colors.white.withValues(alpha: 0.25)
                    : (isDark
                        ? Colors.white.withValues(alpha: 0.1)
                        : Colors.black.withValues(alpha: 0.08)),
                borderRadius: BorderRadius.circular(8),
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
              padding: const EdgeInsets.symmetric(horizontal: 6.0, vertical: 4.0),
              children: [
                _buildHeaderRow(),
                const Divider(),
                ...mp.map((row) => _buildExpandableMPRow(row)),
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
        : 0.0; // Brecha retirada de la vista MP
    final syncText = (resumen['ultima_sync_stock_pt'] ?? '').toString();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Colors.grey.withValues(alpha: 0.25))),
        color: Colors.black.withValues(alpha: 0.03),
      ),
      child: Wrap(
        spacing: 14,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            forComerciales ? 'Resumen Comerciales' : 'Resumen MP (estimado)',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          Text('Demanda: ${_numFormat.format(demanda.round())}'),
          Text('Stock PT: ${_numFormat.format(stock.round())}'),
          if (forComerciales && faltante > 0)
            Text(
              'Faltante: ${_numFormat.format(faltante.round())}',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                color: Color(0xFFC62828),
              ),
            ),
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
    final isDark = FluentTheme.of(context).brightness == Brightness.dark;
    final textSecondary = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 2, 10, 4),
      child: Text(
        'Toca una fila para ver las piezas que componen cada material.',
        style: TextStyle(
          fontSize: 11,
          fontStyle: FontStyle.italic,
          color: textSecondary,
        ),
      ),
    );
  }

  /// Fila padre expandible — tarjeta de 3 líneas con colores dinámicos de tema.
  Widget _buildExpandableMPRow(Map<String, dynamic> row) {
    final mat       = _materialOficialMP(row);
    final isExpanded = _expandedMaterials.contains(mat);
    final rawPiezas  = row['piezas'];
    final piezas     = rawPiezas is List
        ? rawPiezas.map((e) => Map<String, dynamic>.from(e as Map)).toList()
        : <Map<String, dynamic>>[];

    final isDark  = FluentTheme.of(context).brightness == Brightness.dark;
    final accent  = FluentTheme.of(context).accentColor;
    // Fondo de la tarjeta expandida — sutil tinte del accent color.
    final expandedBg = isDark
        ? const Color(0xFF141E33)
        : accent.withValues(alpha: 0.05);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Tarjeta padre ────────────────────────────────────────────────
        MouseRegion(
          cursor: piezas.isNotEmpty
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          child: GestureDetector(
            onTap: piezas.isNotEmpty
                ? () => setState(() {
                      if (isExpanded) _expandedMaterials.remove(mat);
                      else _expandedMaterials.add(mat);
                    })
                : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              margin: const EdgeInsets.symmetric(vertical: 2),
              padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 10.0),
              decoration: BoxDecoration(
                color: isExpanded ? expandedBg : null,
                borderRadius: BorderRadius.circular(6),
                border: isExpanded
                    ? Border.all(
                        color: accent.withValues(alpha: 0.35), width: 1.0)
                    : Border.all(color: Colors.transparent),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Ícono chevron — color del accent
                  SizedBox(
                    width: 22,
                    child: piezas.isNotEmpty
                        ? Icon(
                            isExpanded
                                ? FluentIcons.chevron_down_med
                                : FluentIcons.chevron_right_med,
                            size: 11,
                            color: accent,
                          )
                        : null,
                  ),
                  const SizedBox(width: 4),
                  // Contenido de la tarjeta
                  Expanded(child: _buildMPParentCard(row, isDark, accent)),
                ],
              ),
            ),
          ),
        ),
        // ── Filas hija (piezas) ──────────────────────────────────────────
        if (isExpanded) ...[
          Container(
            margin: const EdgeInsets.only(left: 26, bottom: 4),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.black.withValues(alpha: 0.18)
                  : const Color(0xFFF5F7FF),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              children: [
                _buildPiezaChildHeader(),
                ...piezas.map((p) => _buildPiezaChildRow(p)),
              ],
            ),
          ),
          const Divider(),
        ],
      ],
    );
  }

  /// Contenido de la tarjeta padre: 3 líneas semánticas.
  ///
  /// Línea 1 — nombre del material (negrita) + badge de calibre canónico.
  /// Línea 2 — métricas: Área · Demanda · Stock PT.
  /// Línea 3 — sugerencia de compra (resaltada con accent color).
  Widget _buildMPParentCard(
      Map<String, dynamic> row, bool isDark, AccentColor accent) {
    final mat      = _materialOficialMP(row);
    final calibre  = row['Calibre_Espesor']?.toString() ?? 'N/A';
    final areaMm2  = _d(row['Requerimiento_Area_mm2']);
    final areaM2   = areaMm2 / 1_000_000.0;
    final areaIn2  = areaMm2 / 645.16;
    final demanda  = _d(row['Cantidad_Total_Piezas']);
    final stock    = _d(row['Stock_Asociado_Estimado']);
    final sugerencia = row['Sugerencia_Compra']?.toString() ?? '';

    // Colores semánticos — se derivan del tema dinámicamente.
    final textPrimary   = isDark ? const Color(0xFFF1F5F9) : const Color(0xFF0F172A);
    final textSecondary = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final stockColor    = stock > 0
        ? (isDark ? const Color(0xFF6EE7B7) : const Color(0xFF059669))
        : textSecondary;
    final warningColor  = isDark ? Colors.orange.lighter : Colors.orange.darkest;
    final isPending     = sugerencia.contains('Pendiente');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Línea 1: Material + Calibre ───────────────────────────────────
        Row(
          children: [
            Expanded(
              child: Text(
                mat,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: mat == 'FALTA ASIGNAR EN CAD'
                      ? warningColor
                      : textPrimary,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
              ),
            ),
            if (calibre != 'N/A') ...[
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                  border:
                      Border.all(color: accent.withValues(alpha: 0.28)),
                ),
                child: Text(
                  calibre,
                  style: TextStyle(
                    fontSize: 10,
                    color: accent,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            ],
          ],
        ),
        // ── Línea 2: Área · Demanda · Stock PT ───────────────────────────
        const SizedBox(height: 4),
        Wrap(
          spacing: 14,
          runSpacing: 2,
          children: [
            _metricLabel(
              'Área',
              areaMm2 > 0
                  ? '${_decFormat.format(areaM2)} m²  /  '
                      '${_decFormat.format(areaIn2)} in²'
                  : '—',
              textSecondary,
              textPrimary,
            ),
            _metricLabel(
              'Demanda',
              '${_numFormat.format(demanda.round())} u.',
              textSecondary,
              textPrimary,
            ),
            _metricLabel(
              'Stock PT',
              '${_numFormat.format(stock.round())} u.',
              textSecondary,
              stockColor,
            ),
          ],
        ),
        // ── Línea 3: Sugerencia de compra ────────────────────────────────
        if (sugerencia.isNotEmpty && sugerencia != 'N/A') ...[
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(
                isPending ? FluentIcons.warning : FluentIcons.shop,
                size: 11,
                color: isPending ? warningColor : accent,
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  sugerencia,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isPending ? warningColor : accent,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// Widget inline "Label: Valor" con colores independientes.
  Widget _metricLabel(
      String label, String value, Color labelColor, Color valueColor) {
    return RichText(
      text: TextSpan(
        children: [
          TextSpan(
            text: '$label: ',
            style: TextStyle(fontSize: 11.5, color: labelColor),
          ),
          TextSpan(
            text: value,
            style: TextStyle(
                fontSize: 11.5,
                color: valueColor,
                fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  /// Sub-cabecera de las filas hija — aparece encima del primer hijo expandido.
  Widget _buildPiezaChildHeader() {
    final isDark = FluentTheme.of(context).brightness == Brightness.dark;
    final dimColor = isDark ? const Color(0xFF64748B) : const Color(0xFF9CA3AF);
    final s = TextStyle(
      fontSize: 10,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.4,
      color: dimColor,
    );
    return Padding(
      padding: const EdgeInsets.only(
          left: 44.0, right: 8.0, top: 4.0, bottom: 1.0),
      child: Row(
        children: [
          Expanded(flex: 5, child: Text('CÓDIGO PIEZA', style: s)),
          Expanded(
              flex: 2,
              child: Text('CANT.', style: s, textAlign: TextAlign.right)),
          Expanded(
              flex: 2,
              child: Text('ÁREA m²', style: s, textAlign: TextAlign.right)),
          Expanded(
              flex: 2,
              child: Text('ÁREA in²', style: s, textAlign: TextAlign.right)),
          Expanded(
              flex: 2,
              child:
                  Text('LARGO mm', style: s, textAlign: TextAlign.right)),
          Expanded(
              flex: 2,
              child:
                  Text('ANCHO mm', style: s, textAlign: TextAlign.right)),
          Expanded(
              flex: 2,
              child: Text('STOCK PT', style: s, textAlign: TextAlign.right)),
          const Expanded(flex: 3, child: SizedBox()),
        ],
      ),
    );
  }

  /// Fila hija — código, cantidad, área m², área in², largo, ancho, stock PT.
  Widget _buildPiezaChildRow(Map<String, dynamic> pieza) {
    final isDark = FluentTheme.of(context).brightness == Brightness.dark;
    final accent = FluentTheme.of(context).accentColor;

    final codigo   = pieza['codigo_pieza']?.toString() ?? '-';
    final cantidad = _d(pieza['cantidad']);
    final areaMm2  = _d(pieza['area_mm2']);
    final largoMm  = _d(pieza['largo_mm']);
    final anchoMm  = _d(pieza['ancho_mm']);
    final stockP   = _d(pieza['stock_pieza']);

    final areaM2  = areaMm2 / 1_000_000.0;
    final areaIn2 = areaMm2 / 645.16;

    // Colores completamente derivados del tema — sin valores hex fijos.
    final childColor = isDark ? const Color(0xFFCBD5E1) : const Color(0xFF334155);
    final dimColor   = isDark ? const Color(0xFF64748B) : const Color(0xFF9CA3AF);
    final codeColor  = accent;

    final style = TextStyle(
        fontSize: 12, color: childColor, fontWeight: FontWeight.normal);

    String _fmt(double v) =>
        v > 0 ? _decFormat.format(v) : '—';

    return Padding(
      padding: const EdgeInsets.only(
          left: 44.0, right: 8.0, top: 3.0, bottom: 3.0),
      child: Row(
        children: [
          // Código pieza
          Expanded(
            flex: 5,
            child: Text(
              codigo,
              style: style.copyWith(
                fontFamily: 'monospace',
                fontWeight: FontWeight.w500,
                color: codeColor,
              ),
            ),
          ),
          // Cantidad
          Expanded(
            flex: 2,
            child: Text(
              _numFormat.format(cantidad),
              textAlign: TextAlign.right,
              style: style,
            ),
          ),
          // Área m²
          Expanded(
            flex: 2,
            child: Text(
              areaMm2 > 0 ? _decFormat.format(areaM2) : '—',
              textAlign: TextAlign.right,
              style: style,
            ),
          ),
          // Área in²
          Expanded(
            flex: 2,
            child: Text(
              areaMm2 > 0 ? _decFormat.format(areaIn2) : '—',
              textAlign: TextAlign.right,
              style: style.copyWith(color: dimColor),
            ),
          ),
          // Largo mm
          Expanded(
            flex: 2,
            child: Text(
              _fmt(largoMm),
              textAlign: TextAlign.right,
              style: style.copyWith(color: dimColor),
            ),
          ),
          // Ancho mm
          Expanded(
            flex: 2,
            child: Text(
              _fmt(anchoMm),
              textAlign: TextAlign.right,
              style: style.copyWith(color: dimColor),
            ),
          ),
          // Stock PT pieza
          Expanded(
            flex: 2,
            child: Text(
              _numFormat.format(stockP.round()),
              textAlign: TextAlign.right,
              style: style.copyWith(
                color: stockP > 0
                    ? (isDark
                        ? const Color(0xFFB2DFDB)
                        : const Color(0xFF2E7D32))
                    : childColor,
              ),
            ),
          ),
          // Spacer para columnas padre que no aplican a piezas individuales
          const Expanded(flex: 3, child: SizedBox()),
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
    final dataColor = isDark ? const Color(0xFFCBD5E1) : const Color(0xFF1E293B);
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
