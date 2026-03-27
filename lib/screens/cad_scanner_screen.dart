import 'package:fluent_ui/fluent_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import '../services/api_client.dart';
import '../widgets/compact_page_header.dart';

class CADScannerScreen extends StatefulWidget {
  const CADScannerScreen({Key? key}) : super(key: key);

  State<CADScannerScreen> createState() => _CADScannerScreenState();
}


class _CADScannerScreenState extends State<CADScannerScreen> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  String get _macroVbaText {
    return '''Option Explicit
Dim fso As Object
Dim swApp As Object
Dim dictFiles As Object

Sub main()
    Set swApp = Application.SldWorks
    Set fso = CreateObject("Scripting.FileSystemObject")
    Set dictFiles = CreateObject("Scripting.Dictionary")
    dictFiles.CompareMode = 1
    
    Dim rootPath As String
    Dim ShellApp As Object
    Dim Folder As Object
    Set ShellApp = CreateObject("Shell.Application")
    
    Set Folder = ShellApp.BrowseForFolder(0, "Selecciona la carpeta del proyecto a escanear:", 0, 17)
    
    If Folder Is Nothing Then
        MsgBox "Operación cancelada. No se seleccionó ninguna carpeta.", vbExclamation
        Exit Sub
    End If
    
    rootPath = Folder.Items.Item.Path
    
    If Not fso.FolderExists(rootPath) Then
        MsgBox "Ruta no encontrada: " & rootPath, vbCritical
        Exit Sub
    End If
    
    ScanAndFilterNewestFiles rootPath
    
    Dim key As Variant
    Dim filePathToProcess As String
    Dim totalProcesados As Integer
    totalProcesados = 0
    
    On Error Resume Next
    For Each key In dictFiles.Keys
        filePathToProcess = dictFiles(key).Path
        ProcessPart filePathToProcess
        totalProcesados = totalProcesados + 1
    Next key
    On Error GoTo 0
    
    MsgBox "Procesamiento masivo completado." & vbCrLf & _
           "Se procesaron " & totalProcesados & " archivos únicos (se ignoraron duplicados obsoletos).", vbInformation
End Sub

Sub ScanAndFilterNewestFiles(folderPath As String)
    Dim folder As Object, subFolder As Object, file As Object
    Dim baseName As String
    Set folder = fso.GetFolder(folderPath)
    
    For Each file In folder.Files
        If UCase(fso.GetExtensionName(file.Path)) = "SLDPRT" Then
            baseName = Trim(fso.GetBaseName(file.Path))
            If InStr(1, baseName, "Chapa desplegada -", vbTextCompare) > 0 Then
                baseName = Trim(Replace(baseName, "Chapa desplegada -", "", , , vbTextCompare))
            End If
            
            If dictFiles.Exists(baseName) Then
                If file.DateLastModified > dictFiles(baseName).DateLastModified Then
                    Set dictFiles(baseName) = file
                End If
            Else
                Set dictFiles(baseName) = file
            End If
        End If
    Next file
    
    For Each subFolder In folder.SubFolders
        ScanAndFilterNewestFiles subFolder.Path
    Next subFolder
End Sub

Sub ProcessPart(filePath As String)
    Dim swModel As Object, swFeat As Object
    Dim propMgr As Object, custPropMgr As Object
    Dim nErrors As Long, nWarnings As Long
    Dim largo As Double, ancho As Double, espesorPerfil As Double
    Dim valOut As String, valEval As String
    Dim fileName As String, isSheetMetal As Boolean
    Dim swSheetMetal As Object
    
    fileName = fso.GetBaseName(filePath)
    If InStr(1, fileName, "Chapa desplegada -", vbTextCompare) > 0 Then
        fileName = Trim(Replace(fileName, "Chapa desplegada -", "", , , vbTextCompare))
    End If
    
    Set swModel = swApp.OpenDoc6(filePath, 1, 1, "", nErrors, nWarnings)
    
    If Not swModel Is Nothing Then
        largo = 0: ancho = 0: espesorPerfil = 0: isSheetMetal = False
        Set propMgr = swModel.Extension.CustomPropertyManager("")
        
        propMgr.Get2 "Espesor", valOut, valEval
        If valEval <> "" Then espesorPerfil = Val(valEval)
        If espesorPerfil = 0 Then
            propMgr.Get2 "Thickness", valOut, valEval
            If valEval <> "" Then espesorPerfil = Val(valEval)
        End If
        
        Set swFeat = swModel.FirstFeature
        Do While Not swFeat Is Nothing
            If swFeat.GetTypeName2() = "SheetMetal" Then
                isSheetMetal = True
                Set swSheetMetal = swFeat.GetDefinition()
                If Not swSheetMetal Is Nothing Then
                    If espesorPerfil = 0 Then espesorPerfil = swSheetMetal.Thickness * 1000
                End If
            ElseIf swFeat.GetTypeName2() = "FlatPattern" Then
                isSheetMetal = True
            End If
            
            If swFeat.GetTypeName2() = "CutListFolder" Then
                Set custPropMgr = swFeat.CustomPropertyManager
                custPropMgr.Get2 "Largo del envolvente", valOut, valEval
                If valEval <> "" And largo = 0 Then largo = Val(valEval)
                custPropMgr.Get2 "Ancho del envolvente", valOut, valEval
                If valEval <> "" And ancho = 0 Then ancho = Val(valEval)
                If espesorPerfil = 0 And Not isSheetMetal Then
                    custPropMgr.Get2 "Longitud", valOut, valEval
                    If valEval <> "" Then espesorPerfil = Val(valEval)
                End If
            End If
            Set swFeat = swFeat.GetNextFeature
        Loop
        
        If largo = 0 Or ancho = 0 Or (espesorPerfil = 0 And Not isSheetMetal) Then
            Dim vBox As Variant
            vBox = swModel.GetPartBox(True)
            If Not IsEmpty(vBox) Then
                Dim dx As Double, dy As Double, dz As Double, temp As Double
                dx = Abs(vBox(3) - vBox(0)) * 1000: dy = Abs(vBox(4) - vBox(1)) * 1000: dz = Abs(vBox(5) - vBox(2)) * 1000
                If dx < dy Then temp = dx: dx = dy: dy = temp
                If dx < dz Then temp = dx: dx = dz: dz = temp
                If dy < dz Then temp = dy: dy = dz: dz = temp
                If largo = 0 Then largo = dx
                If ancho = 0 Then ancho = dy
                If espesorPerfil = 0 And Not isSheetMetal Then espesorPerfil = dz
            End If
        End If
        
        propMgr.Add3 "CODIGO_PIEZA", 30, fileName, 1
        propMgr.Set "CODIGO_PIEZA", fileName
        propMgr.Add3 "Largo_CAD", 30, Round(largo, 2) & " mm", 1
        propMgr.Set "Largo_CAD", Round(largo, 2) & " mm"
        propMgr.Add3 "Ancho_CAD", 30, Round(ancho, 2) & " mm", 1
        propMgr.Set "Ancho_CAD", Round(ancho, 2) & " mm"
        
        If espesorPerfil > 0 Then
            propMgr.Add3 "Espesor_Perfil_CAD", 30, Round(espesorPerfil, 2) & " mm", 1
            propMgr.Set "Espesor_Perfil_CAD", Round(espesorPerfil, 2) & " mm"
        Else
            propMgr.Add3 "Espesor_Perfil_CAD", 30, "-", 1
            propMgr.Set "Espesor_Perfil_CAD", "-"
        End If
        
        swModel.Save3 1, nErrors, nWarnings
        swApp.CloseDoc swModel.GetTitle
    End If
    DoEvents
End Sub''';
  }

  final TextEditingController _pathController = TextEditingController();
  final TextEditingController _networkController = TextEditingController();
  bool _isCollecting = false;

  
  String _status = 'idle';
  int _progress = 0;
  int _total = 0;
  String _excelPath = '';
  String _errorMessage = '';
  String _currentFile = '';   // texto de la pieza en proceso
  int _currentItem = 0;       // índice numérico actual
  int _totalItems = 0;        // total objetivo del proceso activo

  String _procesarStatus = 'idle';
  List<String> _cadLogs = [];
  final ScrollController _logsScrollController = ScrollController();
  
  Timer? _statusTimer;

  @override
  void dispose() {
    _statusTimer?.cancel();
    _pathController.dispose();
    _networkController.dispose();
    _logsScrollController.dispose();
    super.dispose();
  }

  void _startPolling() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      _fetchStatus();
    });
  }

  void _stopPolling() {
    _statusTimer?.cancel();
    _statusTimer = null;
  }

  Future<void> _fetchStatus() async {
    try {
      final response = await ApiClient.getUnvalidated('/api/cad/status');
      if (response.statusCode == 200) {
        final data = response.decodeJson() as Map<String, dynamic>;
        if (mounted) {
          setState(() {
            _status = data['status'] ?? 'idle';
            _progress = data['progress'] ?? 0;
            _total = data['total'] ?? 0;
            _excelPath = data['excel_path'] ?? '';
            _errorMessage = data['error'] ?? '';
            _currentFile = data['current_file'] ?? '';
            _currentItem = data['current_item'] ?? 0;
            _totalItems  = data['total_items']  ?? 0;
            
            _procesarStatus = data['procesar_status'] ?? 'idle';
            if (data['logs'] != null) {
              int oldLength = _cadLogs.length;
              _cadLogs = List<String>.from(data['logs']);
              if (_cadLogs.length > oldLength) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (_logsScrollController.hasClients) {
                    _logsScrollController.jumpTo(_logsScrollController.position.maxScrollExtent);
                  }
                });
              }
            }
          });

          bool isScanning = _status == 'scanning' || _status == 'generating_excel';
          bool isProcessing = _procesarStatus == 'processing';

          if (!isScanning && !isProcessing) {
            _stopPolling();
            
            if (_status == 'error') {
              displayInfoBar(context, builder: (context, close) {
                return InfoBar(
                  title: const Text('Error en escaneo'),
                  content: Text(_errorMessage),
                  severity: InfoBarSeverity.error,
                  onClose: close,
                );
              });
              // avoid showing it repeatedly, set to idle
              _status = 'idle'; 
            } else if (_status == 'cancelled') {
              displayInfoBar(context, builder: (context, close) {
                return InfoBar(
                  title: const Text('Cancelado'),
                  content: const Text('El proceso ha sido cancelado.'),
                  severity: InfoBarSeverity.warning,
                  onClose: close,
                );
              });
              _status = 'idle';
              _procesarStatus = 'idle';
            }
          }
        }
      }
    } catch (e) {
      // Ignoramos errores de red durante el polling
    }
  }

  Future<void> _startScan() async {
    final rootPath = _pathController.text.trim();
    if (rootPath.isEmpty) {
      displayInfoBar(context, builder: (context, close) {
        return InfoBar(
          title: const Text('Ruta vacía'),
          content: const Text('Por favor, ingresa una ruta válida para escanear.'),
          severity: InfoBarSeverity.error,
          onClose: close,
        );
      });
      return;
    }

    final bool? confirmar = await showDialog<bool>(
      context: context,
      builder: (context) => ContentDialog(
        title: Text('⚠️ Atención: Extracción SolidWorks', style: TextStyle(color: Colors.warningPrimaryColor)),
        content: Text('El servidor utilizará SolidWorks de forma silenciosa para leer las propiedades de las piezas y generará el reporte Excel. Asegúrate de haber ejecutado la Macro (Paso 1) previamente. ¿Deseas continuar?'),
        actions: [
          Button(
            child: Text('Cancelar'),
            onPressed: () => Navigator.pop(context, false),
          ),
          FilledButton(
            child: Text('Proceder'),
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );

    if (confirmar != true) return;

    setState(() {
      _status = 'scanning';
      _progress = 0;
      _excelPath = '';
      _errorMessage = '';
    });

    try {
      final response = await ApiClient.postUnvalidated(
        '/api/cad/scan',
        headers: {'Content-Type': 'application/json'},
        body: {'root_path': rootPath},
      );

      if (response.statusCode == 200) {
        _startPolling();
      } else {
        setState(() => _status = 'error');
        displayInfoBar(context, builder: (context, close) {
          return InfoBar(
            title: const Text('Error al iniciar'),
            content: Text('Código: ${response.statusCode}'),
            severity: InfoBarSeverity.error,
            onClose: close,
          );
        });
      }
    } catch (e) {
      setState(() => _status = 'error');
      displayInfoBar(context, builder: (context, close) {
        return InfoBar(
          title: const Text('Error de conexión'),
          content: Text(e.toString()),
          severity: InfoBarSeverity.error,
          onClose: close,
        );
      });
    }
  }

  Future<void> _cancelScan() async {
    try {
      final response = await ApiClient.postUnvalidated(
        '/api/cad/abort',
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode == 200) {
        _stopPolling();
        setState(() {
          _status = 'cancelled';
          _procesarStatus = 'idle';
        });
        displayInfoBar(context, builder: (context, close) {
          return InfoBar(
            title: const Text('Cancelado'),
            content: const Text('El escaneo ha sido cancelado exitosamente por el usuario.'),
            severity: InfoBarSeverity.warning,
            onClose: close,
          );
        });
      }
    } catch (e) {
      displayInfoBar(context, builder: (context, close) {
        return InfoBar(
          title: const Text('Error al cancelar'),
          content: Text(e.toString()),
          severity: InfoBarSeverity.error,
          onClose: close,
        );
      });
    }
  }

  Future<void> _procesarDirectorio() async {
    final rootPath = _pathController.text.trim();
    if (rootPath.isEmpty) {
      displayInfoBar(context, builder: (context, close) {
        return InfoBar(
          title: const Text('Ruta vacía'),
          content: const Text('Por favor, ingresa una ruta válida para procesar.'),
          severity: InfoBarSeverity.error,
          onClose: close,
        );
      });
      return;
    }

    // Diálogo de Advertencia (REGLA ANTI-CONST: No usar const en el diálogo)
    final bool? confirmar = await showDialog<bool>(
      context: context,
      builder: (context) => ContentDialog(
        title: Text('⚠️ Atención: Conversión AutoCAD', style: TextStyle(color: Colors.warningPrimaryColor)),
        content: Text('Esta herramienta abrirá AutoCAD en segundo plano para convertir masivamente los archivos DWG a DXF. ¿Deseas continuar?'),
        actions: [
          Button(
            child: Text('Cancelar'),
            onPressed: () => Navigator.pop(context, false),
          ),
          FilledButton(
            child: Text('Proceder'),
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );

    if (confirmar != true) return;

    setState(() {
      _procesarStatus = 'processing';
      _cadLogs = [];
    });

    try {
      final response = await ApiClient.postUnvalidated(
        '/api/cad/procesar-directorio',
        headers: {'Content-Type': 'application/json'},
        body: {'root_path': rootPath},
      );

      if (response.statusCode == 200) {
        _startPolling();
        displayInfoBar(context, builder: (context, close) {
          return InfoBar(
            title: const Text('Procesamiento Iniciado'),
            content: const Text('El procesamiento CAD ha iniciado. Monitorea el progreso en la consola.'),
            severity: InfoBarSeverity.success,
            onClose: close,
          );
        });
      } else {
        setState(() => _procesarStatus = 'error');
        throw Exception('El servidor devolvió Error ${response.statusCode}');
      }
    } catch (e) {
      setState(() => _procesarStatus = 'error');
      displayInfoBar(context, builder: (context, close) {
        return InfoBar(
          title: const Text('Error de procesamiento'),
          content: Text(e.toString()),
          severity: InfoBarSeverity.error,
          onClose: close,
        );
      });
    }
  }

  Future<void> _collectMissingCAD() async {
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Selecciona la carpeta raíz de la red para recolectar CADs',
    );

    if (selectedDirectory == null) return;

    setState(() {
      _networkController.text = selectedDirectory;
      _isCollecting = true;
    });

    try {
      final response = await ApiClient.postUnvalidated(
        '/api/cad/collect-missing',
        headers: {'Content-Type': 'application/json'},
        body: {'source_folder': selectedDirectory},
      );

      setState(() {
        _isCollecting = false;
      });

      if (response.statusCode == 200) {
        final data = response.decodeJson() as Map<String, dynamic>;
        showDialog(
          context: context,
          builder: (context) => ContentDialog(
            title: const Text('Recolección Completada'),
            content: Text(
              'Se encontraron ${data['archivos_encontrados']} archivos de '
              '${data['piezas_faltantes_en_db']} piezas pendientes.\n\n'
              'Fueron copiados a tu escritorio en la carpeta CAD_PENDIENTES.'
            ),
            actions: [
              Button(
                child: const Text('Cerrar'),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        );
      } else {
        throw Exception('Error del servidor: ${response.rawBody}');
      }
    } catch (e) {
      setState(() {
        _isCollecting = false;
      });
      displayInfoBar(context, builder: (context, close) {
        return InfoBar(
          title: const Text('Error en Recolector'),
          content: Text(e.toString()),
          severity: InfoBarSeverity.error,
          onClose: close,
        );
      });
    }
  }

  Future<void> _pickDirectory() async {
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Selecciona el directorio raíz de CAD',
    );

    if (selectedDirectory != null) {
      setState(() {
        _pathController.text = selectedDirectory;
      });
    }
  }

  Future<void> _downloadExcel() async {
    String? outputFile = await FilePicker.platform.saveFile(
      dialogTitle: 'Guardar Reporte',
      fileName: 'Reporte_CAD.xlsx',
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
    );

    if (outputFile == null) return;
    
    try {
      final bytes = await ApiClient.getBytes('/api/cad/download');
      final file = File(outputFile);
      await file.writeAsBytes(bytes);
      displayInfoBar(context, builder: (context, close) {
        return InfoBar(
          title: const Text('Descarga Completa'),
          content: Text('Guardado en:\n$outputFile'),
          severity: InfoBarSeverity.success,
          onClose: close,
        );
      });
    } catch (e) {
      displayInfoBar(context, builder: (context, close) {
        return InfoBar(
          title: const Text('Error Descargando'),
          content: Text('$e'),
          severity: InfoBarSeverity.error,
          onClose: close,
        );
      });
    }
  }

  Future<void> _uploadModifiedExcel() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
      dialogTitle: 'Seleccionar Archivo Modificado',
    );

    if (result == null || result.files.single.path == null) return;
    String filePath = result.files.single.path!;
    
    // Mostrar que está cargando...
    bool isUploading = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return const ContentDialog(
          title: Text('Subiendo e Importando...'),
          content: Center(child: ProgressRing()),
        );
      }
    );

    try {
      final data = await ApiClient.postMultipart(
        '/api/cad/upload',
        headers: {'X-Usuario': 'Alejandro'},
        files: {'file': await ApiClient.fileField('file', filePath)},
      ) as Map<String, dynamic>;

      Navigator.pop(context); // Cerrar diálogo de carga
      isUploading = false;

      int act = data['actualizadas'] ?? 0;
      int err = data['errores'] ?? 0;
      List<dynamic> det = data['detalles_errores'] ?? [];

      showDialog(
        context: context,
        builder: (context) {
          return ContentDialog(
            title: const Text('Resultado de la Actualización'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Piezas actualizadas correctamente: $act'),
                Text('Filas con error o ignoradas: $err'),
                if (det.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text('Detalles de errores:', style: TextStyle(fontWeight: FontWeight.bold)),
                  Container(
                    height: 100,
                    decoration: BoxDecoration(border: Border.all(color: Colors.grey)),
                    child: ListView.builder(
                      itemCount: det.length,
                      itemBuilder: (context, idx) {
                        return Padding(
                          padding: const EdgeInsets.all(4.0),
                          child: Text('- ${det[idx]}'),
                        );
                      },
                    ),
                  )
                ]
              ],
            ),
            actions: [
              Button(
                 child: const Text('Cerrar'),
                 onPressed: () => Navigator.pop(context),
              )
            ],
          );
        }
      );
    } catch (e) {
      if (isUploading) Navigator.pop(context);
      displayInfoBar(context, builder: (context, close) {
        return InfoBar(
          title: const Text('Error de subida'),
          content: Text(e.toString()),
          severity: InfoBarSeverity.error,
          onClose: close,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final bool isScanning = _status == 'scanning' || _status == 'generating_excel';
    final bool isProcessing = _procesarStatus == 'processing';
    final bool isBusy = isScanning || isProcessing;

    final pageHPad = PageHeader.horizontalPadding(context);
    return ScaffoldPage.scrollable(
      padding: EdgeInsets.fromLTRB(pageHPad, 8, pageHPad, 24),
      header: CompactPageHeader(
        title: Text(
          'Escáner de Directorios CAD',
          style: FluentTheme.of(context).typography.title,
        ),
      ),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            // Panel de Acción (Flujo Paso a Paso)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Flujo de Trabajo:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 12),
                    // NUEVO Paso 0: Recolector Inteligente
                    Card(
                      borderColor: Colors.blue.withOpacity(0.3),
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(FluentIcons.search, color: Colors.blue, size: 24),
                                const SizedBox(width: 12),
                                const Text('Paso 0: Recolector Inteligente',
                                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                                const Spacer(),
                                if (_isCollecting) const ProgressRing(),
                              ],
                            ),
                            const SizedBox(height: 8),
                            const Text('Busca en la red piezas sin medidas en la base de datos y las copia a tu escritorio para procesarlas.'),
                            const SizedBox(height: 12),
                            InfoLabel(
                              label: 'Ruta de Origen (Red/Servidor)',
                              child: Row(
                                children: [
                                  Expanded(
                                    child: TextBox(
                                      controller: _networkController,
                                      placeholder:
                                          'Selecciona la carpeta de red (sin cargar aún)',
                                      readOnly: true,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  FilledButton(
                                    onPressed: _isCollecting ? null : _collectMissingCAD,
                                    child: const Text('Seleccionar Red y Recolectar'),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.orange.withOpacity(0.1),
                        border: Border.all(color: Colors.orange, width: 1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(FluentIcons.warning, color: Colors.orange),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '⚠️ ATENCIÓN: SolidWorks debe estar ABIERTO (puede estar minimizado) antes de generar el reporte.',
                                  style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Paso 1 (Manual): Asegúrate de ejecutar la Macro en SolidWorks sobre la carpeta del proyecto. Esta Macro sirve para escribir en masa las propiedades necesarias en todos los archivos antes del escaneo.',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton(
                            child: const Text('📋 Copiar Macro al Portapapeles'),
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: _macroVbaText));
                              displayInfoBar(
                                context,
                                builder: (context, close) {
                                  return InfoBar(
                                    title: const Text('Macro Copiada'),
                                    content: const Text('Pégala en SolidWorks VBA para extraer las medidas'),
                                    severity: InfoBarSeverity.success,
                                    onClose: close,
                                  );
                                },
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.blue.withOpacity(0.1),
                        border: Border.all(color: Colors.blue, width: 1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        children: [
                          Icon(FluentIcons.info, color: Colors.blue),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'NOTA: El Paso 2 (Convertir DWG a DXF) requiere AutoCAD instalado. El Paso 3 (Generar Reporte Excel) requiere SolidWorks instalado.',
                              style: TextStyle(color: Colors.blue, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Card(
                      borderColor: Colors.grey.withValues(alpha: 0.35),
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Paso 2 y 3: Procesamiento Local',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Esta ruta es la carpeta local que usa el servidor para convertir DWG (Paso 2) y para el escaneo SolidWorks / Excel (Paso 3).',
                              style: TextStyle(
                                fontSize: 12,
                                color: FluentTheme.of(context)
                                    .typography
                                    .caption
                                    ?.color,
                              ),
                            ),
                            const SizedBox(height: 12),
                            InfoLabel(
                              label:
                                  'Ruta de Trabajo Local (Carpeta a escanear)',
                              child: Row(
                                children: [
                                  Expanded(
                                    child: TextBox(
                                      controller: _pathController,
                                      placeholder:
                                          r'Ej. C:\Users\...\Desktop\CAD_PENDIENTES',
                                      enabled: !isBusy,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Tooltip(
                                    message: 'Seleccionar carpeta local',
                                    child: IconButton(
                                      icon: const Icon(
                                        FluentIcons.folder_open,
                                        size: 20,
                                      ),
                                      onPressed: isBusy ? null : _pickDirectory,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 16),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              alignment: WrapAlignment.start,
                              children: [
                                FilledButton(
                                  onPressed:
                                      isBusy ? null : _procesarDirectorio,
                                  style: ButtonStyle(
                                    backgroundColor: isBusy
                                        ? ButtonState.all(Colors.grey)
                                        : ButtonState.all(Colors.orange),
                                  ),
                                  child: const Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 8,
                                    ),
                                    child: Text(
                                      'Paso 2: Convertir DWG a DXF',
                                      style: TextStyle(fontSize: 16),
                                    ),
                                  ),
                                ),
                                FilledButton(
                                  onPressed: isBusy ? null : _startScan,
                                  style: ButtonStyle(
                                    backgroundColor: isBusy
                                        ? ButtonState.all(Colors.grey)
                                        : ButtonState.all(Colors.green),
                                  ),
                                  child: const Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 8,
                                    ),
                                    child: Text(
                                      'Paso 3: Generar Reporte Excel',
                                      style: TextStyle(fontSize: 16),
                                    ),
                                  ),
                                ),
                                if (isBusy)
                                  Button(
                                    onPressed: _cancelScan,
                                    style: ButtonStyle(
                                      backgroundColor: ButtonState.all(
                                        Colors.red.withOpacity(0.1),
                                      ),
                                      foregroundColor:
                                          ButtonState.all(Colors.red),
                                    ),
                                    child: const Padding(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 8,
                                      ),
                                      child: Text(
                                        'Cancelar Escaneo',
                                        style: TextStyle(fontSize: 16),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            
            const SizedBox(height: 24),

            // Consola de Logs (Procesamiento CAD)
            if (_procesarStatus != 'idle') ...[
              const Text(
                'Consola de Procesamiento:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Container(
                height: 250,
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: ListView.builder(
                  controller: _logsScrollController,
                  itemCount: _cadLogs.length,
                  itemBuilder: (context, index) {
                    return Text(
                      _cadLogs[index],
                      style: TextStyle(
                        fontFamily: 'Consolas',
                        color: Colors.green,
                        fontSize: 13,
                      ),
                    );
                  },
                ),
              ),
              if (isProcessing) ...[
                const SizedBox(height: 12),
                const Row(
                  children: [
                    ProgressRing(strokeWidth: 3),
                    SizedBox(width: 12),
                    Text('Procesando archivos...', style: TextStyle(fontStyle: FontStyle.italic)),
                  ],
                ),
              ],
              if (_procesarStatus == 'completed') ...[
                const SizedBox(height: 12),
                Text(
                  'El procesamiento ha finalizado con éxito.',
                  style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold),
                ),
              ],
              const SizedBox(height: 24),
            ],

            const SizedBox(height: 24),

            // ── Zona de Progreso (visible en scanning, generating_excel y collecting) ──
            if (isScanning || _status == 'collecting') ...[
              const Text(
                'Progreso del escaneo:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),

              // ── Barra de progreso con porcentaje real ───────────────────────────
              Builder(builder: (context) {
                final double pct = (_totalItems > 0)
                    ? (_currentItem / _totalItems).clamp(0.0, 1.0)
                    : 0.0;
                final int pctInt = (pct * 100).round();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _status == 'generating_excel'
                              ? 'Generando reporte Excel...'
                              : _status == 'collecting'
                                  ? 'Recolectando archivos de red'
                                  : '$_currentItem / $_totalItems piezas',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          '$pctInt%',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    if (_status == 'generating_excel')
                      const ProgressBar()
                    else if (_totalItems > 0)
                      ProgressBar(value: pct * 100)
                    else
                      const ProgressBar(),
                  ],
                );
              }),

              const SizedBox(height: 12),

              // ── Mini-Consola Terminal ─────────────────────────────────────
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF0D0D0D),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: const Color(0xFF39FF14).withOpacity(0.35),
                    width: 1,
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Text(
                      '▶ ',
                      style: TextStyle(
                        color: Color(0xFF39FF14),
                        fontFamily: 'Courier',
                        fontSize: 13,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        _currentFile.isEmpty ? 'Iniciando...' : _currentFile,
                        style: const TextStyle(
                          color: Color(0xFF39FF14),
                          fontFamily: 'Courier',
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 8),
            ],

            // Zona de Resultados
            if (_status == 'completed') ...[
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.green),
                ),
                child: Column(
                  children: [
                    Icon(FluentIcons.completed_solid, size: 48, color: Colors.green),
                    const SizedBox(height: 16),
                    const Text(
                      '¡Escaneo Finalizado con Éxito!',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text('Se encontraron y procesaron $_progress archivos CAD únicos.'),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _downloadExcel,
                      style: ButtonStyle(
                        backgroundColor: ButtonState.all(Colors.blue),
                      ),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                        child: Text(
                          'Descargar Reporte Excel',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 48),

            // Tarjeta de actualización BD
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.05),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Actualizar Base de Datos',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  const Text('Sube el archivo Excel previament descargado con las columnas Largo_CAD y Ancho_CAD debidamente llenadas para actualizar el Catálogo Maestro.'),
                  const SizedBox(height: 16),
                  Button(
                    onPressed: isBusy ? null : _uploadModifiedExcel,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(FluentIcons.upload),
                          SizedBox(width: 8),
                          Text('Cargar Excel Modificado', style: TextStyle(fontSize: 16)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      ),
      ),
      ],
    );
  }
}
