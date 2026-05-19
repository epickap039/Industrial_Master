import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_client.dart';
import '../services/notification_inbox_service.dart';
import '../theme/ui_tokens.dart';
import '../widgets/compact_page_header.dart';

class AuditorScreen extends StatefulWidget {
  const AuditorScreen({super.key});

  @override
  State<AuditorScreen> createState() => _AuditorScreenState();
}

class _AuditorScreenState extends State<AuditorScreen> {
  bool _isProcessing = false;
  List<dynamic>? _errors;
  List<dynamic>? _detailedReport;
  String? _fileName;
  String? _filePath;

  // 1. AUDITORÍA
  Future<void> _auditExcel() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
        dialogTitle: 'Seleccionar Archivo para Auditar (Excel)',
      );

      if (result == null || result.files.single.path == null) return;

      setState(() {
        _isProcessing = true;
        _errors = null;
        _fileName = result.files.single.name;
        _filePath = result.files.single.path!;
      });

      final data = await ApiClient.postMultipart(
        '/api/excel/auditar',
        files: {'file': await ApiClient.fileField('file', _filePath!)},
      ) as Map<String, dynamic>;

      setState(() {
        _errors = data['errores'];
        _detailedReport = data['reporte_detallado'];
      });
    } catch (e) {
      _showErrorDialog("Error de Auditoría", e.toString());
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  // 2. AUTOCORRECCIÓN
  Future<void> _autoCorrect() async {
    if (_errors == null || _errors!.isEmpty || _filePath == null) return;

    // Confirmación
    bool? confirm = await showDialog<bool>(
      context: context,
      builder:
          (c) => ContentDialog(
            title: const Text("Confirmar Autocorrección"),
            content: const Text(
              "El servidor analizará tu archivo y te devolverá una versión con las correcciones de base de datos aplicadas.\n\n¿Deseas continuar?",
            ),
            actions: [
              Button(
                child: const Text("Cancelar"),
                onPressed: () => Navigator.pop(c, false),
              ),
              FilledButton(
                child: const Text("Corregir Archivo"),
                onPressed: () => Navigator.pop(c, true),
              ),
            ],
          ),
    );

    if (confirm != true) return;

    setState(() => _isProcessing = true);

    try {
      final bytes = await ApiClient.postMultipartBytes(
        '/api/excel/corregir',
        fields: {'correcciones': json.encode(_errors)},
        files: {'file': await ApiClient.fileField('file', _filePath!)},
      );

      String? outputFile = await FilePicker.platform.saveFile(
        dialogTitle: 'Guardar Archivo Corregido',
        fileName: 'CORREGIDO_${_fileName ?? "archivo.xlsx"}',
        allowedExtensions: ['xlsx'],
      );

      if (outputFile != null) {
        if (!outputFile.endsWith('.xlsx')) outputFile += '.xlsx';
        final file = File(outputFile);
        await file.writeAsBytes(bytes);

        if (mounted) {
          final prefs = await SharedPreferences.getInstance();
          final usuario = (prefs.getString('username') ?? '').trim();
          await CmdInboxStore.instance.addSystemNotice(
            title: 'Auditor: archivo corregido',
            body: 'Se genero correctamente el archivo corregido: ${_fileName ?? 'Excel'}.',
            assignedUser: usuario,
          );
          displayInfoBar(
            context,
            builder: (context, close) {
              return InfoBar(
                title: const Text('Corrección Exitosa'),
                content: Text("Archivo guardado en: $outputFile"),
                severity: InfoBarSeverity.success,
                action: Button(
                  onPressed: () => _openLocalFile(outputFile!),
                  child: const Text('Abrir File'),
                ),
                onClose: close,
              );
            },
          );
          setState(() => _errors = []);
        }
      }
    } catch (e) {
      _showErrorDialog("Error al Corregir", e.toString());
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  // 3. ABRIR ARCHIVO
  Future<void> _openFile() async {
    if (_filePath == null) return;
    try {
      await ApiClient.post(
        '/api/system/open_file',
        body: {'path': _filePath},
      );
    } catch (e) {
      _showErrorDialog("Error al Abrir", e.toString());
    }
  }

  // 4. EXPORTAR REPORTE
  Future<void> _exportReport() async {
    if (_detailedReport == null || _detailedReport!.isEmpty) return;
    try {
      final reportBytes = await ApiClient.postBytes(
        '/api/excel/exportar_reporte',
        body: _detailedReport,
      );

      String? outputFile = await FilePicker.platform.saveFile(
        dialogTitle: 'Guardar Reporte',
        fileName: 'Reporte_Auditoria.xlsx',
        allowedExtensions: ['xlsx'],
      );

      if (outputFile != null) {
        if (!outputFile.endsWith('.xlsx')) outputFile += '.xlsx';
        final file = File(outputFile);
        await file.writeAsBytes(reportBytes);

        if (mounted) {
          displayInfoBar(
            context,
            builder: (context, close) {
              return InfoBar(
                title: const Text('Reporte Exportado'),
                content: Text('Guardado en: $outputFile'),
                severity: InfoBarSeverity.success,
                action: Button(
                  onPressed: () => _openLocalFile(outputFile!),
                  child: const Text('Abrir'),
                ),
                onClose: close,
              );
            },
          );
        }
      }
    } catch (e) {
      _showErrorDialog("Error Exportando", e.toString());
    }
  }

  Future<void> _openLocalFile(String path) async {
    try {
      await ApiClient.post(
        '/api/system/open_file',
        body: {'path': path},
      );
    } catch (_) {}
  }

  void _showErrorDialog(String title, String message) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder:
          (c) => ContentDialog(
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: SelectableText(
                        message,
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(FluentIcons.copy),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: message));
                        displayInfoBar(
                          c,
                          duration: const Duration(seconds: 2),
                          builder: (context, close) {
                            return InfoBar(
                              title: const Text('Copiado'),
                              content: const Text(
                                'Error copiado al portapapeles',
                              ),
                              severity: InfoBarSeverity.success,
                              onClose: close,
                            );
                          },
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
            actions: [
              Button(
                child: const Text("Cerrar"),
                onPressed: () => Navigator.pop(c),
              ),
            ],
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = uiSurfacePaletteOf(context);
    return ScaffoldPage(
      padding: const EdgeInsets.only(top: 8),
      header: CompactPageHeader(
        title: Text(
          'Auditor de Archivos',
          style: FluentTheme.of(context).typography.title,
        ),
      ),
      content: Container(
        color: palette.surfaceBase,
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // PANEL SUPERIOR
            Card(
              child: Column(
                children: [
                  if (_fileName == null) ...[
                    Icon(
                      FluentIcons.excel_document,
                      size: 40,
                      color: const Color(0xFF22C55E),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Auditor Multicolumna: Descripción, Medida, Simetría, Procesos',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 20),
                  ],

                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (_fileName != null) ...[
                        Text(
                          '📄 $_fileName',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 10),
                        IconButton(
                          icon: const Icon(FluentIcons.folder_open),
                          onPressed: _openFile,
                          style: ButtonStyle(
                            foregroundColor: WidgetStateProperty.all(
                              palette.actionInfo,
                            ),
                          ),
                        ),
                        const SizedBox(width: 20),
                        Button(
                          onPressed: _auditExcel,
                          child: const Text('Analizar Otro Archivo'),
                        ),
                      ] else
                        FilledButton(
                          onPressed: _auditExcel,
                          child: const Text('Seleccionar Archivo Excel'),
                        ),
                    ],
                  ),

                  if (_isProcessing) ...[
                    const SizedBox(height: 20),
                    const ProgressRing(),
                    const SizedBox(height: 10),
                    const Text('Procesando...'),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 20),

            // AREA RESULTADOS
            Expanded(child: _buildResultsArea()),

            // FOOTER ACCIONES
            if (_errors != null && _errors!.isNotEmpty && !_isProcessing)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Button(
                      onPressed: _exportReport,
                      child: const Row(
                        children: [
                          Icon(FluentIcons.download),
                          SizedBox(width: 8),
                          Text('Exportar Reporte'),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      onPressed: _autoCorrect,
                      style: ButtonStyle(
                        backgroundColor: WidgetStateProperty.all(
                          palette.actionInfo,
                        ),
                      ),
                      child: const Row(
                        children: [
                          Icon(FluentIcons.repair),
                          SizedBox(width: 8),
                          Text('Corregir Archivo Excel'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
          ),
        ),
      ),
    );
  }

  Widget _buildResultsArea() {
    if (_isProcessing) return const SizedBox.shrink();

    if (_errors == null) {
      return Center(
        child: Text(
          'Selecciona un archivo para comenzar.',
          style: fluentSecondaryTextStyle(context),
        ),
      );
    }

    if (_errors!.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              FluentIcons.check_mark,
              size: 64,
              color: const Color(0xFF22C55E),
            ),
            const SizedBox(height: 10),
            Text(
              '✅ Archivo Íntegro',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: const Color(0xFF22C55E),
              ),
            ),
            const Text('Todos los campos analizados coinciden con la BD.'),
          ],
        ),
      );
    }

    // 1. Agrupación en Tiempo de Renderizado
    Map<String, List<dynamic>> discrepanciasAgrupadas = {};
    for (var disc in _errors!) {
      String codigo = disc['codigo'] ?? 'Sin Código';
      if (!discrepanciasAgrupadas.containsKey(codigo)) {
        discrepanciasAgrupadas[codigo] = [];
      }
      discrepanciasAgrupadas[codigo]!.add(disc);
    }

    final codigos = discrepanciasAgrupadas.keys.toList();

    const errStrong = Color(0xFFF87171);
    const errSoftBg = Color(0xFF2B1F25);
    const okStrong = Color(0xFF34D399);
    const okSoftBg = Color(0xFF1C2D2A);
    final textMain = FluentTheme.of(context).typography.bodyStrong?.color ??
        (FluentTheme.of(context).brightness == Brightness.dark ? const Color(0xFFF1F5F9) : const Color(0xFF111827));
    final textMuted = FluentTheme.of(context).typography.caption?.color ??
        (FluentTheme.of(context).brightness == Brightness.dark ? const Color(0xFFCBD5E1) : const Color(0xFF475569));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '⚠️ ${_errors!.length} discrepancias encontradas en ${codigos.length} códigos de pieza:',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: const Color(0xFFE67E22),
          ),
        ),
        const SizedBox(height: 5),
        Expanded(
          // 2. Nueva Estructura de Tarjetas por Código
          child: ListView.builder(
            itemCount: codigos.length,
            itemBuilder: (context, index) {
              final codigo = codigos[index];
              final items = discrepanciasAgrupadas[codigo]!;

              return Padding(
                padding: const EdgeInsets.only(bottom: 12.0),
                child: Card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Encabezado de la Tarjeta (Código)
                      Row(
                        children: [
                          Icon(
                            FluentIcons.database,
                            size: 20,
                            color: const Color(0xFFB0BEC5),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            codigo,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: textMain,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF351C24),
                              border: Border.all(color: errStrong.withValues(alpha: 0.75)),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '${items.length} errores',
                              style: const TextStyle(
                                color: Color(0xFFFFCDD2),
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      const Divider(),
                      const SizedBox(height: 10),

                      // 2. Agrupación Secundaria (Por "Firma del Error")
                      Builder(
                        builder: (context) {
                          Map<String, List<int>> erroresUnicosMap = {};
                          // Guardar la primera ocurrencia completa del error para extraer 'campo', 'excel', 'bd' al dibujar
                          Map<String, dynamic> primeraInstancia = {};

                          for (var item in items) {
                            final campo = item['campo'] ?? 'N/A';
                            final valExcel =
                                item['excel']?.toString() ?? 'null';
                            final valBd = item['bd']?.toString() ?? 'null';

                            // Firma Única Combinada
                            final firma =
                                "Col:$campo|Excel:$valExcel|BD:$valBd";

                            if (!erroresUnicosMap.containsKey(firma)) {
                              erroresUnicosMap[firma] = [];
                              primeraInstancia[firma] = item;
                            }

                            // Parsear fila de forma segura para evitar crashes si viene como String o double
                            int filaNum = 0;
                            if (item['fila'] != null) {
                              if (item['fila'] is int) {
                                filaNum = item['fila'];
                              } else {
                                filaNum =
                                    int.tryParse(item['fila'].toString()) ?? 0;
                              }
                            }
                            erroresUnicosMap[firma]!.add(filaNum);
                          }

                          // 3. Bloque de Error Agrupado
                          return Column(
                            children:
                                erroresUnicosMap.keys.map((firma) {
                                  final filas = erroresUnicosMap[firma]!;
                                  final itemRef = primeraInstancia[firma]!;

                                  // Unir números de fila únicos
                                  filas.sort();
                                  final filasStr = filas.join(', ');

                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 12.0),
                                    padding: const EdgeInsets.all(12.0),
                                    decoration: BoxDecoration(
                                      color: FluentTheme.of(
                                        context,
                                      ).cardColor.withValues(alpha: 0.5),
                                      border: Border.all(
                                        color: Colors.grey.withValues(alpha: 0.2),
                                      ),
                                      borderRadius: BorderRadius.circular(6.0),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        // 1. Encabezado del Error
                                        Row(
                                          children: [
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 8,
                                                    vertical: 4,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: errStrong,
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                              ),
                                              child: Text(
                                                filas.length > 1
                                                    ? 'Filas: $filasStr'
                                                    : 'Fila: $filasStr',
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Text(
                                              'Columna: ',
                                              style: TextStyle(
                                                color: FluentTheme.of(
                                                  context,
                                                ).resources.textFillColorSecondary,
                                                fontSize: 13,
                                              ),
                                            ),
                                            Text(
                                              itemRef['campo'],
                                              style: const TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 14,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 12),

                                        // 2. Diseño de 2 Columnas (Excel vs BD)
                                        Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            // Columna Izquierda (Excel)
                                            Expanded(
                                              child: Container(
                                                padding: const EdgeInsets.all(
                                                  8,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: errSoftBg,
                                                  borderRadius: BorderRadius.circular(6),
                                                  border: Border(
                                                    left: BorderSide(
                                                      color: errStrong,
                                                      width: 4,
                                                    ),
                                                  ),
                                                ),
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      'En Documento Excel:',
                                                      style: TextStyle(
                                                        color: errStrong.withValues(alpha: 0.95),
                                                        fontSize: 11,
                                                        fontWeight: FontWeight.w700,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 4),
                                                    SelectableText(
                                                      itemRef['excel']
                                                          .toString(),
                                                      style: TextStyle(
                                                        color: textMain,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),

                                            const Padding(
                                              padding: EdgeInsets.symmetric(
                                                horizontal: 12.0,
                                              ),
                                              child: Icon(
                                                FluentIcons.forward,
                                                size: 16,
                                                color: Colors.grey,
                                              ),
                                            ),

                                            // Columna Derecha (Base de Datos)
                                            Expanded(
                                              child: Container(
                                                padding: const EdgeInsets.all(
                                                  8,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: okSoftBg,
                                                  borderRadius: BorderRadius.circular(6),
                                                  border: Border(
                                                    left: BorderSide(
                                                      color: okStrong,
                                                      width: 4,
                                                    ),
                                                  ),
                                                ),
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      'En Base de Datos:',
                                                      style: TextStyle(
                                                        color: okStrong.withValues(alpha: 0.95),
                                                        fontSize: 11,
                                                        fontWeight: FontWeight.w700,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 4),
                                                    SelectableText(
                                                      itemRef['bd'].toString(),
                                                      style: TextStyle(
                                                        color: textMain,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  );
                                }).toList(),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
