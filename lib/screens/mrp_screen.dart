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
    });

    try {
      final res = await http.get(
        Uri.parse('$_apiUrl/api/mrp/calculate/$_selectedRevisionId'),
      );

      if (res.statusCode == 200) {
        final List<dynamic> data = json.decode(res.body);
        if (mounted) {
          setState(() {
            _mrpData = List<Map<String, dynamic>>.from(data);
          });
        }
      } else {
        throw Exception("Error del servidor: \${res.statusCode}");
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
    if (_mrpData.isEmpty) return;

    var excel = excel_lib.Excel.createExcel();
    excel_lib.Sheet sheetObject = excel['MRP Requerimientos'];
    excel.delete('Sheet1');

    sheetObject.appendRow([
      excel_lib.TextCellValue('Material Oficial'),
      excel_lib.TextCellValue('Calibre/Espesor'),
      excel_lib.TextCellValue('Piezas Totales'),
      excel_lib.TextCellValue('Área Total (Formato Leíble)'),
      excel_lib.TextCellValue('Área Cruda (mm2)'),
    ]);

    for (var row in _mrpData) {
      double areaMm2 = (row['Requerimiento_Area_mm2'] ?? 0).toDouble();
      String readableArea = _formatArea(areaMm2);
      
      sheetObject.appendRow([
        excel_lib.TextCellValue(row['Material']?.toString() ?? '-'),
        excel_lib.TextCellValue(row['Calibre_Espesor']?.toString() ?? '-'),
        excel_lib.DoubleCellValue((row['Cantidad_Total_Piezas'] ?? 0).toDouble()),
        excel_lib.TextCellValue(readableArea),
        excel_lib.DoubleCellValue(areaMm2),
      ]);
    }

    String? outputFile = await FilePicker.platform.saveFile(
      dialogTitle: 'Exportar Requerimiento de Materiales',
      fileName: 'Requerimientos_MRP.xlsx',
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
                content: Text('Se exportaron ${_mrpData.length} materiales a Excel.'),
                severity: InfoBarSeverity.success,
                onClose: close,
              ),
            );
          }
        } catch(e) { /* ignore for web but works in windows */ }
      }
    }
  }
  
  String _formatArea(double mm2) {
    if (mm2 == 0) return "0 mm²";
    if (mm2 > 1000000) {
      double m2 = mm2 / 1000000;
      return '${_decFormat.format(m2)} m²';
    } else {
      return '${_numFormat.format(mm2)} mm²';
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
                onPressed: _mrpData.isEmpty ? null : _exportToExcel,
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

    if (_mrpData.isEmpty) {
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
        ],
      ),
    );
  }

  Widget _buildHeaderRow() {
    const style = TextStyle(fontWeight: FontWeight.bold);
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 8.0, horizontal: 12.0),
      child: Row(
        children: [
          Expanded(flex: 3, child: Text('MATERIAL OFICIAL', style: style)),
          Expanded(flex: 2, child: Text('CALIBRE / ESPESOR', style: style)),
          Expanded(flex: 2, child: Text('PIEZAS TOTALES', style: style, textAlign: TextAlign.right)),
          Expanded(flex: 3, child: Text('ÁREA TOTAL REQUERIDA', style: style, textAlign: TextAlign.right)),
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
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              row['Calibre_Espesor']?.toString() ?? 'N/A',
              style: TextStyle(color: FluentTheme.of(context).accentColor),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              _numFormat.format(piezas),
              textAlign: TextAlign.right,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            flex: 3,
            child: Container(
              alignment: Alignment.centerRight,
              child: InfoBadge(
                color: areaMm2 > 1000000 ? Colors.green.darkest : Colors.blue.darkest,
                source: Text(
                  _formatArea(areaMm2),
                  style: const TextStyle(fontSize: 14),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
