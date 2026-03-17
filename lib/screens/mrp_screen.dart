import 'package:fluent_ui/fluent_ui.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:intl/intl.dart';
import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart' as excel_lib;
import '../utils/excel_helper.dart';

import 'dart:io';

const String _apiUrl = "http://192.168.1.73:8001";

class MRPScreen extends StatefulWidget {
  const MRPScreen({super.key});

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
  String? _errorMessage;
  String? _selectedRevisionClientes;

  // Tab index: 0 = Materia Prima, 1 = Comerciales, 2 = Huérfanos
  int _tabIndex = 0;

  final NumberFormat _numFormat = NumberFormat('#,##0', 'en_US');
  final NumberFormat _decFormat = NumberFormat('#,##0.00', 'en_US');

  @override
  void initState() {
    super.initState();
    _fetchRevisions();
  }

  Future<void> _fetchRevisions() async {
    setState(() => _isLoadingRevisions = true);
    try {
      // Endpoint dedicado: DISTINCT sin JOIN de clientes → sin duplicados.
      final res =
          await http.get(Uri.parse('$_apiUrl/api/mrp/revisiones'));
      if (res.statusCode == 200) {
        final List<dynamic> rows = json.decode(res.body);

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
      _tabIndex = 0;
    });

    try {
      final res = await http.get(
        Uri.parse('$_apiUrl/api/mrp/calculate/$_selectedRevisionId'),
      );

      if (res.statusCode == 200) {
        final Map<String, dynamic> data = json.decode(res.body);
        if (mounted) {
          setState(() {
            _mrpData =
                List<Map<String, dynamic>>.from(data['mrp_calculado'] ?? []);
            _comercialesData = List<Map<String, dynamic>>.from(
                data['componentes_comerciales'] ?? []);
            _orphanData = List<Map<String, dynamic>>.from(
                data['piezas_sin_medidas'] ?? []);
          });
        }
      } else {
        throw Exception("Error del servidor: ${res.statusCode} - ${res.body}");
      }
    } catch (e) {
      if (mounted) setState(() => _errorMessage = e.toString());
    } finally {
      if (mounted) setState(() => _isCalculating = false);
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
        excel_lib.TextCellValue(row['Material']?.toString() ?? '-'),
        ExcelHelper.parseDynamicCell(row['Calibre_Espesor']),
        excel_lib.IntCellValue(piezas),
        excel_lib.TextCellValue(_formatArea(areaMm2)),
        excel_lib.DoubleCellValue(areaM2),
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
      final comHeaders = ['Código de Pieza', 'Descripción', 'Cantidad Total'];
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
    final hasResults =
        _mrpData.isNotEmpty || _comercialesData.isNotEmpty || _orphanData.isNotEmpty;

    return ScaffoldPage(
      header: PageHeader(
        title: const Text('MRPII: Requerimiento de Materiales'),
        commandBar: Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 10,
          runSpacing: 10,
          children: [
            _isLoadingRevisions
                ? const ProgressRing(strokeWidth: 2)
                : ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
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
                            });
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
                                  color: Colors.blue.withOpacity(0.65),
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    'Aplica para: $_selectedRevisionClientes',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontStyle: FontStyle.italic,
                                      color: Colors.blue.withOpacity(0.75),
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
            FilledButton(
              onPressed: _selectedRevisionId == null || _isCalculating
                  ? null
                  : _calculateMRP,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(FluentIcons.calculator),
                  SizedBox(width: 8),
                  Text('Calcular Requerimiento'),
                ],
              ),
            ),
            Tooltip(
              message: "Exportar a Excel",
              child: IconButton(
                icon: Icon(FluentIcons.excel_logo, color: Colors.green),
                onPressed: hasResults ? _exportToExcel : null,
              ),
            ),
          ],
        ),
      ),
      content: _buildContent(),
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

    if (_mrpData.isEmpty && _comercialesData.isEmpty && _orphanData.isEmpty) {
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
                    ?.withOpacity(0.25)),
            const SizedBox(height: 16),
            Text(
              "Selecciona una Revisión de Ingeniería y presiona Calcular.",
              style: FluentTheme.of(context)
                  .typography
                  .body
                  ?.copyWith(color: Colors.grey),
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

          // ── Pestañas ─────────────────────────────────────────────────────
          _buildTabBar(),
          const SizedBox(height: 12),

          // ── Panel activo ─────────────────────────────────────────────────
          Expanded(child: _buildActivePanel()),
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
            ? Colors.white.withOpacity(0.75)
            : Colors.black.withOpacity(0.65));

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
                    ? Colors.white.withOpacity(0.2)
                    : Colors.black.withOpacity(0.15)),
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
                    ? Colors.white.withOpacity(0.25)
                    : (isDark
                        ? Colors.white.withOpacity(0.1)
                        : Colors.black.withOpacity(0.08)),
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
    if (_mrpData.isEmpty) {
      return const Center(
        child: Text("No hay materia prima que cortar para esta revisión."),
      );
    }
    return Container(
      decoration: _cardDecoration(),
      child: ListView(
        padding: const EdgeInsets.all(8.0),
        children: [
          _buildHeaderRow(),
          const Divider(),
          ..._mrpData.map((row) => _buildDataRow(row)),
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
      child: ListView(
        padding: const EdgeInsets.all(8.0),
        children: [
          _buildComercialHeaderRow(),
          const Divider(),
          ..._comercialesData.map((row) => _buildComercialDataRow(row)),
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
              row['Material']?.toString() ?? 'N/A',
              style: base.copyWith(
                fontWeight: FontWeight.w600,
                color: row['Material'] == 'FALTA ASIGNAR EN CAD'
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
          Expanded(flex: 5, child: Text('DESCRIPCIÓN', style: style)),
          Expanded(
              flex: 2,
              child: Text('CANTIDAD',
                  style: style, textAlign: TextAlign.right)),
          Expanded(
              flex: 3,
              child: Text('ACCIÓN SUGERIDA',
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
            flex: 5,
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
              'Compra directa (${_numFormat.format(cant)} pzs)',
              textAlign: TextAlign.right,
              style: base.copyWith(
                color: isDark
                    ? const Color(0xFFCE93D8)
                    : const Color(0xFF6A1B9A),
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
