import 'package:fluent_ui/fluent_ui.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:intl/intl.dart';
import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart' as excel_lib;

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
  List<Map<String, dynamic>> _mrpData = [];
  List<Map<String, dynamic>> _orphanData = [];
  String? _errorMessage;

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
      final res = await http.get(Uri.parse('$_apiUrl/api/mapa/jerarquia'));
      if (res.statusCode == 200) {
        final List<dynamic> tractos = json.decode(res.body);
        List<Map<String, dynamic>> flattened = [];

        for (var tracto in tractos) {
          final tName = tracto['nombre'];
          for (var tipo in tracto['tipos'] ?? []) {
            final typeName = tipo['nombre'];
            for (var ver in tipo['versiones'] ?? []) {
              final verName = ver['nombre'];
              for (var rev in ver['revisiones'] ?? []) {
                final rId = rev['id_revision'];
                final rNum = rev['numero'];
                if (rId != null) {
                  flattened.add({
                    'id': rId,
                    'name': '$tName - $typeName ($verName) - Rev ${rNum ?? 'N/A'}',
                  });
                }
              }
            }
          }
        }

        if (mounted) {
          setState(() {
            _revisionsList = flattened;
          });
        }
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
      _orphanData = [];
    });

    try {
      final res = await http.get(
        Uri.parse('$_apiUrl/api/mrp/calculate/$_selectedRevisionId'),
      );

      if (res.statusCode == 200) {
        final Map<String, dynamic> data = json.decode(res.body);
        if (mounted) {
          setState(() {
            _mrpData = List<Map<String, dynamic>>.from(data['mrp_calculado'] ?? []);
            _orphanData = List<Map<String, dynamic>>.from(data['piezas_sin_medidas'] ?? []);
          });
        }
      } else {
        throw Exception("Error del servidor: ${res.statusCode} - ${res.body}");
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
        });
      }
    } finally {
      if (mounted) setState(() => _isCalculating = false);
    }
  }

  Future<void> _exportToExcel() async {
    if (_mrpData.isEmpty && _orphanData.isEmpty) return;

    var excel = excel_lib.Excel.createExcel();
    
    // 1. Hoja de Orden de Compra
    excel_lib.Sheet sheetOC = excel['Orden_Compra'];
    excel.delete('Sheet1'); // Eliminar la hoja por defecto

    sheetOC.appendRow([
      excel_lib.TextCellValue('Material Oficial'),
      excel_lib.TextCellValue('Calibre/Espesor'),
      excel_lib.TextCellValue('Piezas Totales'),
      excel_lib.TextCellValue('Área / Requerimiento'),
      excel_lib.TextCellValue('Orden de Compra Sugerida'),
    ]);

    for (var row in _mrpData) {
      double areaMm2 = (row['Requerimiento_Area_mm2'] ?? 0).toDouble();
      sheetOC.appendRow([
        excel_lib.TextCellValue(row['Material']?.toString() ?? '-'),
        excel_lib.TextCellValue(row['Calibre_Espesor']?.toString() ?? '-'),
        excel_lib.DoubleCellValue((row['Cantidad_Total_Piezas'] ?? 0).toDouble()),
        excel_lib.TextCellValue(_formatArea(areaMm2)),
        excel_lib.TextCellValue(row['Sugerencia_Compra']?.toString() ?? 'N/A'),
      ]);
    }

    // 2. Hoja de Auditoría de Ingeniería (Huérfanos)
    if (_orphanData.isNotEmpty) {
      excel_lib.Sheet sheetAudit = excel['Auditoria_Ingenieria'];
      sheetAudit.appendRow([
        excel_lib.TextCellValue('Código de Pieza'),
        excel_lib.TextCellValue('Ensamble'),
        excel_lib.TextCellValue('Material CAD'),
        excel_lib.TextCellValue('Cantidad BOM'),
        excel_lib.TextCellValue('Motivo de Rechazo'),
      ]);

      for (var row in _orphanData) {
        sheetAudit.appendRow([
          excel_lib.TextCellValue(row['Codigo_Pieza']?.toString() ?? '-'),
          excel_lib.TextCellValue(row['Nombre_Ensamble']?.toString() ?? '-'),
          excel_lib.TextCellValue(row['Material']?.toString() ?? '-'),
          excel_lib.DoubleCellValue((row['Cantidad'] ?? 0).toDouble()),
          excel_lib.TextCellValue(row['Motivo_Rechazo']?.toString() ?? '-'),
        ]);
      }
    }

    String fileName = 'MRP_Requerimiento_Rev_${_selectedRevisionId ?? "Unknown"}.xlsx';
    
    String? outputFile = await FilePicker.platform.saveFile(
      dialogTitle: 'Exportar Requerimiento de Materiales',
      fileName: fileName,
    );

    if (outputFile != null) {
      if (!outputFile.endsWith('.xlsx')) outputFile = '$outputFile.xlsx';
      var fileBytes = excel.save();
      if (fileBytes != null) {
        try {
          final file = File(outputFile);
          file.writeAsBytesSync(fileBytes);
          if (mounted) {
            displayInfoBar(
              context,
              builder: (context, close) => InfoBar(
                title: const Text('Exportación Exitosa'),
                content: Text('Reporte generado: $fileName. ${_mrpData.length} ítems de compra y ${_orphanData.length} huérfanos.'),
                severity: InfoBarSeverity.success,
                onClose: close,
              ),
            );
          }
        } catch(e) {
          debugPrint("Error al guardar Excel: $e");
        }
      }
    }
  }
  
  String _formatArea(double mm2) {
    if (mm2 == 0) return "0.00 mm²";
    if (mm2 > 1000000) {
      double m2 = mm2 / 1000000;
      return '${_decFormat.format(m2)} m²';
    } else {
      return '${_decFormat.format(mm2)} mm²';
    }
  }

  @override
  Widget build(BuildContext context) {
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
                    constraints: const BoxConstraints(maxWidth: 250),
                    child: ComboBox<int>(
                      placeholder: const Text('Seleccionar Proyecto (Revisión)'),
                      value: _selectedRevisionId,
                      items: _revisionsList.map((rev) {
                        return ComboBoxItem<int>(
                          value: rev['id'] as int,
                          child: Text(
                            rev['name'] as String,
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      }).toList(),
                      onChanged: (val) {
                        setState(() {
                          _selectedRevisionId = val;
                        });
                      },
                      isExpanded: true,
                    ),
                  ),
            const SizedBox(width: 15),
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
                onPressed: (_mrpData.isEmpty && _orphanData.isEmpty) ? null : _exportToExcel,
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
          style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
        ),
      );
    }

    if (_mrpData.isEmpty && _orphanData.isEmpty) {
      return const Center(
        child: Text(
          "Selecciona una revisión y presiona Calcular.",
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Consolidación de Materiales (${_mrpData.length} registros)',
            style: FluentTheme.of(context).typography.subtitle,
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: FluentTheme.of(context).cardColor,
                borderRadius: BorderRadius.circular(8.0),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ListView(
                padding: const EdgeInsets.all(8.0),
                children: [
                  _buildHeaderRow(),
                  const Divider(),
                  ..._mrpData.map((row) => _buildDataRow(row)),
                ],
              ),
            ),
          ),
          if (_orphanData.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20.0),
              child: Container(height: 2, color: Colors.red),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 12.0),
              child: Text(
                '⚠️ Piezas sin dimensiones CAD o Material (Excluidas del cálculo)',
                style: FluentTheme.of(context).typography.subtitle?.copyWith(color: Colors.red, fontWeight: FontWeight.bold),
              ),
            ),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: FluentTheme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(8.0),
                ),
                child: ListView(
                  padding: const EdgeInsets.all(8.0),
                  children: [
                    _buildOrphanHeaderRow(),
                    const Divider(),
                    ..._orphanData.map((row) => _buildOrphanDataRow(row)),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHeaderRow() {
    final style = FluentTheme.of(context).typography.body?.copyWith(fontWeight: FontWeight.bold);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 12.0),
      child: Row(
        children: [
          Expanded(flex: 3, child: Text('MATERIAL OFICIAL', style: style)),
          Expanded(flex: 2, child: Text('CALIBRE / ESPESOR', style: style)),
          Expanded(flex: 2, child: Text('PIEZAS TOTALES', style: style, textAlign: TextAlign.right)),
          Expanded(flex: 3, child: Text('ÁREA TOTAL REQUERIDA', style: style, textAlign: TextAlign.right)),
          Expanded(flex: 4, child: Text('ORDEN DE COMPRA SUGERIDA', style: style, textAlign: TextAlign.right)),
        ],
      ),
    );
  }

  Widget _buildDataRow(Map<String, dynamic> row) {
    double areaMm2 = (row['Requerimiento_Area_mm2'] ?? 0).toDouble();
    double piezas = (row['Cantidad_Total_Piezas'] ?? 0).toDouble();
    
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10.0, horizontal: 12.0),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              row['Material']?.toString() ?? 'N/A',
              style: FluentTheme.of(context).typography.body?.copyWith(
                fontWeight: FontWeight.w600,
                color: row['Material'] == 'FALTA ASIGNAR EN CAD' ? Colors.orange.darkest : null,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              row['Calibre_Espesor']?.toString() ?? 'N/A',
              style: FluentTheme.of(context).typography.body?.copyWith(color: FluentTheme.of(context).accentColor),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              _numFormat.format(piezas),
              textAlign: TextAlign.right,
              style: FluentTheme.of(context).typography.body?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            flex: 3,
            child: Container(
              alignment: Alignment.centerRight,
              child: Text(
                _formatArea(areaMm2),
                style: FluentTheme.of(context).typography.body,
              ),
            ),
          ),
          Expanded(
            flex: 4,
            child: Text(
              row['Sugerencia_Compra']?.toString() ?? 'N/A',
              textAlign: TextAlign.right,
              style: FluentTheme.of(context).typography.body?.copyWith(
                color: Colors.orange.darkest,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOrphanHeaderRow() {
    final style = FluentTheme.of(context).typography.body?.copyWith(fontWeight: FontWeight.bold, color: Colors.red);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 12.0),
      child: Row(
        children: [
          Expanded(flex: 3, child: Text('CÓDIGO DE PIEZA', style: style)),
          Expanded(flex: 3, child: Text('ENSAMBLE', style: style)),
          Expanded(flex: 3, child: Text('MATERIAL', style: style)),
          Expanded(flex: 1, child: Text('CANT', style: style, textAlign: TextAlign.right)),
          Expanded(flex: 3, child: Text('MOTIVO DE RECHAZO', style: style, textAlign: TextAlign.right)),
        ],
      ),
    );
  }

  Widget _buildOrphanDataRow(Map<String, dynamic> row) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 12.0),
      child: Row(
        children: [
          Expanded(flex: 3, child: Text(row['Codigo_Pieza']?.toString() ?? '-', style: FluentTheme.of(context).typography.body)),
          Expanded(flex: 3, child: Text(row['Nombre_Ensamble']?.toString() ?? '-', style: FluentTheme.of(context).typography.body)),
          Expanded(flex: 3, child: Text(row['Material']?.toString() ?? '-', style: FluentTheme.of(context).typography.body)),
          Expanded(flex: 1, child: Text(row['Cantidad']?.toString() ?? '0', style: FluentTheme.of(context).typography.body, textAlign: TextAlign.right)),
          Expanded(
            flex: 3,
            child: Text(
              row['Motivo_Rechazo']?.toString() ?? '-',
              style: FluentTheme.of(context).typography.body?.copyWith(color: Colors.red.darkest, fontWeight: FontWeight.bold),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}
