import 'package:fluent_ui/fluent_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import '../main.dart'; // Para API_URL

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
  
  String _status = 'idle';
  int _progress = 0;
  int _total = 0;
  String _excelPath = '';
  String _errorMessage = '';
  
  String _procesarStatus = 'idle';
  List<String> _cadLogs = [];
  final ScrollController _logsScrollController = ScrollController();
  
  Timer? _statusTimer;

  @override
  void dispose() {
    _statusTimer?.cancel();
    _pathController.dispose();
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
      final response = await http.get(Uri.parse('$API_URL/api/cad/status'));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (mounted) {
          setState(() {
            _status = data['status'] ?? 'idle';
            _progress = data['progress'] ?? 0;
            _total = data['total'] ?? 0;
            _excelPath = data['excel_path'] ?? '';
            _errorMessage = data['error'] ?? '';
            
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
                  content: const Text('El escaneo ha sido cancelado.'),
                  severity: InfoBarSeverity.warning,
                  onClose: close,
                );
              });
              _status = 'idle';
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

    setState(() {
      _status = 'scanning';
      _progress = 0;
      _excelPath = '';
      _errorMessage = '';
    });

    try {
      final response = await http.post(
        Uri.parse('$API_URL/api/cad/scan'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'root_path': rootPath}),
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
      await http.post(
        Uri.parse('$API_URL/api/cad/scan'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'root_path': 'cancel'}),
      );
      // El polling actualizará el estado a cancelled
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
        title: Text('⚠️ Atención: Operación Crítica', style: TextStyle(color: Colors.warningPrimaryColor)),
        content: Text(
          'Esta herramienta abrirá SolidWorks en segundo plano y sobrescribirá propiedades en masa.\n\n'
          'Todos los archivos manipulados se guardarán con la fecha de hoy.\n'
          '¿Deseas continuar?'
        ),
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
      final response = await http.post(
        Uri.parse('$API_URL/api/cad/procesar-directorio'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'root_path': rootPath}),
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
      final response = await http.get(Uri.parse('$API_URL/api/cad/download'));
      if (response.statusCode == 200) {
        final file = File(outputFile);
        await file.writeAsBytes(response.bodyBytes);
        displayInfoBar(context, builder: (context, close) {
          return InfoBar(
            title: const Text('Descarga Completa'),
            content: Text('Guardado en:\n$outputFile'),
            severity: InfoBarSeverity.success,
            onClose: close,
          );
        });
      } else {
        throw Exception('Error al descargar: ${response.statusCode}');
      }
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
      var request = http.MultipartRequest('POST', Uri.parse('$API_URL/api/cad/upload'));
      request.files.add(await http.MultipartFile.fromPath('file', filePath));
      request.headers.addAll({'X-Usuario': 'Alejandro'});
      
      var response = await request.send();
      var responseData = await http.Response.fromStream(response);
      
      Navigator.pop(context); // Cerrar diálogo de carga
      isUploading = false;

      if (response.statusCode == 200) {
        final data = json.decode(responseData.body);
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
      } else {
        throw Exception('El servidor devolvió Error ${response.statusCode}: ${responseData.body}');
      }
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

    return ScaffoldPage.scrollable(
      header: const PageHeader(
        title: Text('Escáner de Directorios CAD'),
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
              // Sección de Input
              const Text(
                'Ruta a escanear (Búsqueda Recursiva):',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextBox(
                    controller: _pathController,
                    placeholder: r'Ej. Z:\Ingenieria\SolidWorks',
                    enabled: !isBusy,
                  ),
                ),
                const SizedBox(width: 12),
                Tooltip(
                  message: 'Seleccionar Carpeta',
                  child: IconButton(
                    icon: const Icon(FluentIcons.folder_open, size: 20),
                    onPressed: isBusy ? null : _pickDirectory,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            
            // Panel de Acción (Flujo Paso a Paso)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Flujo de Trabajo:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 12),
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
                            'Paso 1 (Manual): Asegúrate de ejecutar la Macro de extracción de Cajas (Bounding Box) en SolidWorks sobre esta carpeta primero.',
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
                              'NOTA: El Paso 2 (Convertir DWG a DXF) requiere que AutoCAD esté instalado en este equipo.',
                              style: TextStyle(color: Colors.blue, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        FilledButton(
                          onPressed: isBusy ? null : _procesarDirectorio,
                          style: ButtonStyle(
                            backgroundColor: isBusy 
                              ? ButtonState.all(Colors.grey) 
                              : ButtonState.all(Colors.orange),
                          ),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            child: Text('Paso 2: Convertir DWG a DXF', style: TextStyle(fontSize: 16)),
                          ),
                        ),
                        const SizedBox(width: 16),
                        FilledButton(
                          onPressed: isBusy ? null : _startScan,
                          style: ButtonStyle(
                            backgroundColor: isBusy 
                              ? ButtonState.all(Colors.grey) 
                              : ButtonState.all(Colors.green),
                          ),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            child: Text('Paso 3: Generar Reporte Excel', style: TextStyle(fontSize: 16)),
                          ),
                        ),
                        if (isScanning) ...[
                          const SizedBox(width: 16),
                          Button(
                            onPressed: _status == 'scanning' ? _cancelScan : null,
                            style: ButtonStyle(
                              backgroundColor: ButtonState.all(Colors.red.withOpacity(0.1)),
                              foregroundColor: ButtonState.all(Colors.red),
                            ),
                            child: const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              child: Text('Cancelar Escaneo', style: TextStyle(fontSize: 16)),
                            ),
                          ),
                        ],
                      ],
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

            // Zona de Progreso
            if (isScanning) ...[
              const Text('Progreso del escaneo:'),
              const SizedBox(height: 8),
              if (_status == 'generating_excel') ...[
                const ProgressBar(),
                const SizedBox(height: 8),
                const Text('Generando reporte Excel...', style: TextStyle(fontStyle: FontStyle.italic)),
              ] else ...[
                if (_total > 0)
                  ProgressBar(value: (_progress / _total) * 100)
                else
                  const ProgressBar(), // Indeterminada
                const SizedBox(height: 8),
                Text(
                  'Escaneando... $_progress archivos encontrados',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
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
