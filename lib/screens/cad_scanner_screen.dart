import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as material;
import 'package:file_picker/file_picker.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../services/api_client.dart';
import '../theme/ui_tokens.dart';
import '../widgets/compact_page_header.dart';

class CADScannerScreen extends StatefulWidget {
  const CADScannerScreen({super.key});

  @override
  State<CADScannerScreen> createState() => _CADScannerScreenState();
}

class _CADScannerScreenState extends State<CADScannerScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  /// Usuario de sesión para `X-Usuario` (auditoría CAD / historial).
  Future<String> _prefsUsername() async {
    final prefs = await SharedPreferences.getInstance();
    final u = prefs.getString('username')?.trim();
    return (u != null && u.isNotEmpty) ? u : 'Operador';
  }

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

  // Maestro Mode: true = solo faltantes, false = todo el catálogo
  bool _maestroSoloFaltantes = true;

  /// Escribir medidas en el .sldprt y copiar el archivo de vuelta a la ruta de red.
  bool _inyectarPropiedadesMaestro = false;

  static const String _kDefaultSourceRed =
      r'Z:\INGENIERIA\Alejandro de Jesus Gonzalez Hdez\BASE DE DATOS INGENIERIA\EXPERIMENTO';

  final TextEditingController _sourceFolderController = TextEditingController();
  final TextEditingController _localFolderController = TextEditingController();

  String _status = 'idle';
  int _progress = 0;
  int _total = 0;
  String _excelPath = '';

  /// Solo true cuando el polling confirma fin exitoso de Fase 2 (auditar).
  bool _mostrarBotonExcel = false;

  /// Tras POST Fase 1 OK: mostrar diálogo macro cuando el status indique fin del trabajo.
  bool _pendingPhase1MacroDialog = false;

  /// Tras POST Fase 2 OK: al completar, habilitar botón Excel.
  bool _phase2TrackExcel = false;

  String _errorMessage = '';
  String _warningMessage = '';
  String _currentFile = ''; // texto de la pieza en proceso
  int _currentItem = 0; // índice numérico actual
  int _totalItems = 0; // total objetivo del proceso activo

  String _procesarStatus = 'idle';
  List<String> _cadLogs = [];
  final ScrollController _logsScrollController = ScrollController();

  Timer? _statusTimer;

  String _defaultDesktopLocalPath() {
    if (!Platform.isWindows) {
      final h = Platform.environment['HOME'];
      return h != null && h.isNotEmpty
          ? '$h/Desktop/Piezas_A_Procesar'
          : '~/Desktop/Piezas_A_Procesar';
    }
    final up = Platform.environment['USERPROFILE'];
    if (up == null || up.isEmpty) {
      return r'C:\Users\Public\Desktop\Piezas_A_Procesar';
    }
    return '$up\\Desktop\\Piezas_A_Procesar';
  }

  @override
  void initState() {
    super.initState();
    _sourceFolderController.text = _kDefaultSourceRed;
    _localFolderController.text = _defaultDesktopLocalPath();
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _sourceFolderController.dispose();
    _localFolderController.dispose();
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
            _warningMessage = data['warning_message'] ?? '';
            _currentFile = data['current_file'] ?? '';
            _currentItem = data['current_item'] ?? 0;
            _totalItems = data['total_items'] ?? 0;

            _procesarStatus = data['procesar_status'] ?? 'idle';
            if (data['logs'] != null) {
              int oldLength = _cadLogs.length;
              _cadLogs = List<String>.from(data['logs']);
              if (_cadLogs.length > oldLength) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (_logsScrollController.hasClients) {
                    _logsScrollController.jumpTo(
                      _logsScrollController.position.maxScrollExtent,
                    );
                  }
                });
              }
            }
          });

          bool isScanning =
              _status == 'scanning' || _status == 'generating_excel';
          bool isProcessing = _procesarStatus == 'processing';

          if (!isScanning && !isProcessing) {
            _stopPolling();

            if (_status == 'error') {
              _pendingPhase1MacroDialog = false;
              _phase2TrackExcel = false;
              displayInfoBar(
                context,
                builder: (context, close) {
                  return InfoBar(
                    title: const Text('Error en escaneo'),
                    content: Text(_errorMessage),
                    severity: InfoBarSeverity.error,
                    onClose: close,
                  );
                },
              );
              // avoid showing it repeatedly, set to idle
              _status = 'idle';
            } else if (_status == 'cancelled') {
              _pendingPhase1MacroDialog = false;
              _phase2TrackExcel = false;
              displayInfoBar(
                context,
                builder: (context, close) {
                  return InfoBar(
                    title: const Text('Cancelado'),
                    content: const Text('El proceso ha sido cancelado.'),
                    severity: InfoBarSeverity.warning,
                    onClose: close,
                  );
                },
              );
              _status = 'idle';
              _procesarStatus = 'idle';
            } else if (_pendingPhase1MacroDialog &&
                _status == 'completed' &&
                _procesarStatus == 'completed') {
              _pendingPhase1MacroDialog = false;
              WidgetsBinding.instance.addPostFrameCallback((_) async {
                if (!mounted) return;
                await showDialog<void>(
                  context: context,
                  barrierDismissible: false,
                  builder:
                      (ctx) => ContentDialog(
                        title: Text(
                          '⚠️ PAUSA OBLIGATORIA',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: material.Colors.deepOrange.shade800,
                          ),
                        ),
                        content: SingleChildScrollView(
                          child: Text(
                            'El Paso 0 ha terminado y los archivos están listos.\n\n'
                            '1. Abre SolidWorks.\n'
                            '2. Ejecuta tu Macro VBA sobre la Carpeta Destino.\n'
                            '3. Cuando la macro termine de guardar las medidas, cierra SolidWorks y presiona '
                            "'Entendido' aquí para continuar con el Paso 1.",
                            style: const TextStyle(fontSize: 16, height: 1.35),
                          ),
                        ),
                        actions: [
                          FilledButton(
                            child: const Text('Entendido'),
                            onPressed: () => Navigator.of(ctx).pop(),
                          ),
                        ],
                      ),
                );
                if (!mounted) return;
                displayInfoBar(
                  context,
                  builder: (context, close) {
                    return InfoBar(
                      title: const Text('Fase 1 en segundo plano'),
                      content: const Text(
                        'Sigue el progreso en la consola. Ejecuta la macro cuando el servidor termine de copiar.',
                      ),
                      severity: InfoBarSeverity.info,
                      onClose: close,
                    );
                  },
                );
              });
            } else if (_phase2TrackExcel &&
                _status == 'completed' &&
                _procesarStatus == 'completed') {
              _phase2TrackExcel = false;
              setState(() {
                _mostrarBotonExcel = true;
              });
            }
          }
        }
      }
    } catch (e) {
      // Ignoramos errores de red durante el polling
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
        displayInfoBar(
          context,
          builder: (context, close) {
            return InfoBar(
              title: const Text('Cancelado'),
              content: const Text(
                'El escaneo ha sido cancelado exitosamente por el usuario.',
              ),
              severity: InfoBarSeverity.warning,
              onClose: close,
            );
          },
        );
      }
    } catch (e) {
      displayInfoBar(
        context,
        builder: (context, close) {
          return InfoBar(
            title: const Text('Error al cancelar'),
            content: Text(e.toString()),
            severity: InfoBarSeverity.error,
            onClose: close,
          );
        },
      );
    }
  }

  Future<void> _pickSourceFolder() async {
    final String? d = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Carpeta origen en red',
    );
    if (d != null && mounted) {
      setState(() => _sourceFolderController.text = d);
    }
  }

  Future<void> _pickDestFolder() async {
    final String? d = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Carpeta destino local (CAD)',
    );
    if (d != null && mounted) {
      setState(() => _localFolderController.text = d);
    }
  }

  Future<void> _startPreparar() async {
    final bool? confirmar = await showDialog<bool>(
      context: context,
      builder:
          (context) => ContentDialog(
            title: Text(
              'Fase 1: Preparar',
              style: TextStyle(color: Colors.warningPrimaryColor),
            ),
            content: const Text(
              'Se consultará el catálogo, se copiarán archivos desde la red a la carpeta local '
              'y se ejecutará la conversión DWG → DXF.\n\n¿Continuar?',
            ),
            actions: [
              Button(
                child: Text('Cancelar'),
                onPressed: () => Navigator.pop(context, false),
              ),
              FilledButton(
                child: Text('Iniciar Fase 1'),
                onPressed: () => Navigator.pop(context, true),
              ),
            ],
          ),
    );

    if (confirmar != true) return;

    if (_sourceFolderController.text.trim().isEmpty ||
        _localFolderController.text.trim().isEmpty) {
      displayInfoBar(
        context,
        builder: (context, close) {
          return InfoBar(
            title: const Text('Rutas obligatorias'),
            content: const Text(
              'Indica Carpeta Origen (Red) y Carpeta Destino (Local).',
            ),
            severity: InfoBarSeverity.warning,
            onClose: close,
          );
        },
      );
      return;
    }

    setState(() {
      _status = 'collecting';
      _procesarStatus = 'processing';
      _cadLogs = [];
      _progress = 0;
      _excelPath = '';
      _errorMessage = '';
      _warningMessage = '';
      _mostrarBotonExcel = false;
      _pendingPhase1MacroDialog = false;
      _phase2TrackExcel = false;
    });

    try {
      final response = await ApiClient.postUnvalidated(
        '/api/cad/preparar',
        headers: {'Content-Type': 'application/json'},
        body: {
          'source_folder': _sourceFolderController.text.trim(),
          'local_folder': _localFolderController.text.trim(),
          'solo_faltantes': _maestroSoloFaltantes,
        },
      );

      if (response.statusCode == 200) {
        _pendingPhase1MacroDialog = true;
        _startPolling();
      } else {
        setState(() {
          _status = 'error';
          _procesarStatus = 'idle';
        });
        throw Exception('Error del servidor: ${response.statusCode}');
      }
    } catch (e) {
      setState(() {
        _status = 'idle';
        _procesarStatus = 'idle';
      });
      displayInfoBar(
        context,
        builder: (context, close) {
          return InfoBar(
            title: const Text('Error al iniciar Fase 1'),
            content: Text(e.toString()),
            severity: InfoBarSeverity.error,
            onClose: close,
          );
        },
      );
    }
  }

  Future<void> _startAuditar() async {
    final bool? confirmar = await showDialog<bool>(
      context: context,
      builder:
          (context) => ContentDialog(
            title: const Text(
              "Fase 2: Auditar piezas en 'Carpeta Destino (Local)'",
              style: TextStyle(color: Colors.warningPrimaryColor),
            ),
            content: const Text(
              'Se leerán los .sldprt de la Carpeta Destino (Local) indicada arriba; se cruzarán con los DXF de esa carpeta (subcarpeta dxf), se generará el Excel y se actualizará la base de datos.\n\n'
              '¿Ya ejecutaste la macro VBA en esa carpeta local?\n\n'
              'Puede tardar mucho tiempo. ¿Continuar?',
            ),
            actions: [
              Button(
                child: Text('Cancelar'),
                onPressed: () => Navigator.pop(context, false),
              ),
              FilledButton(
                child: Text('Iniciar Fase 2'),
                onPressed: () => Navigator.pop(context, true),
              ),
            ],
          ),
    );

    if (confirmar != true) return;

    if (_localFolderController.text.trim().isEmpty) {
      displayInfoBar(
        context,
        builder: (context, close) {
          return InfoBar(
            title: const Text('Carpeta destino'),
            content: const Text(
              'Indica la Carpeta Destino (Local) para la auditoría.',
            ),
            severity: InfoBarSeverity.warning,
            onClose: close,
          );
        },
      );
      return;
    }

    setState(() {
      _status = 'scanning';
      _procesarStatus = 'processing';
      _cadLogs = [];
      _progress = 0;
      _excelPath = '';
      _errorMessage = '';
      _warningMessage = '';
      _mostrarBotonExcel = false;
      _pendingPhase1MacroDialog = false;
      _phase2TrackExcel = false;
    });

    try {
      final username = await _prefsUsername();
      final response = await ApiClient.postUnvalidated(
        '/api/cad/auditar',
        headers: {'Content-Type': 'application/json', 'X-Usuario': username},
        body: {
          'local_folder': _localFolderController.text.trim(),
          'solo_faltantes': _maestroSoloFaltantes,
          'inyectar_propiedades': _inyectarPropiedadesMaestro,
        },
      );

      if (response.statusCode == 200) {
        _phase2TrackExcel = true;
        _startPolling();
        displayInfoBar(
          context,
          builder: (context, close) {
            return InfoBar(
              title: const Text('Fase 2 iniciada'),
              content: const Text(
                'Auditoría CAD, Excel y SQL. Monitorea la consola.',
              ),
              severity: InfoBarSeverity.info,
              onClose: close,
            );
          },
        );
      } else {
        setState(() {
          _status = 'error';
          _procesarStatus = 'idle';
        });
        throw Exception('Error del servidor: ${response.statusCode}');
      }
    } catch (e) {
      setState(() {
        _status = 'idle';
        _procesarStatus = 'idle';
      });
      displayInfoBar(
        context,
        builder: (context, close) {
          return InfoBar(
            title: const Text('Error al iniciar Fase 2'),
            content: Text(e.toString()),
            severity: InfoBarSeverity.error,
            onClose: close,
          );
        },
      );
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
      displayInfoBar(
        context,
        builder: (context, close) {
          return InfoBar(
            title: const Text('Descarga Completa'),
            content: Text('Guardado en:\n$outputFile'),
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
            title: const Text('Error Descargando'),
            content: Text('$e'),
            severity: InfoBarSeverity.error,
            onClose: close,
          );
        },
      );
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
      },
    );

    try {
      final username = await _prefsUsername();
      final data =
          await ApiClient.postMultipart(
                '/api/cad/upload',
                headers: {'X-Usuario': username},
                files: {'file': await ApiClient.fileField('file', filePath)},
              )
              as Map<String, dynamic>;

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
                  const Text(
                    'Detalles de errores:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Container(
                    height: 100,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey),
                    ),
                    child: ListView.builder(
                      itemCount: det.length,
                      itemBuilder: (context, idx) {
                        return Padding(
                          padding: const EdgeInsets.all(4.0),
                          child: Text('- ${det[idx]}'),
                        );
                      },
                    ),
                  ),
                ],
              ],
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
    } catch (e) {
      if (isUploading) Navigator.pop(context);
      displayInfoBar(
        context,
        builder: (context, close) {
          return InfoBar(
            title: const Text('Error de subida'),
            content: Text(e.toString()),
            severity: InfoBarSeverity.error,
            onClose: close,
          );
        },
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final palette = uiSurfacePaletteOf(context);
    final bool isScanning =
        _status == 'scanning' || _status == 'generating_excel';
    final bool isProcessing = _procesarStatus == 'processing';
    final bool isBusy = isScanning || isProcessing;

    final pageHPad = PageHeader.horizontalPadding(context);
    return ScaffoldPage.scrollable(
      padding: EdgeInsets.fromLTRB(pageHPad, 8, pageHPad, 24),
      header: CompactPageHeader(
        title: Text(
          'CAD — Flujo híbrido (preparar → macro manual → auditar)',
          style: FluentTheme.of(context).typography.title,
        ),
      ),
      children: [
        Container(
          width: double.infinity,
          color: palette.surfaceBase,
          child: Center(
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
                          const Text(
                            'Flujo de Trabajo:',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 12),

                          Card(
                            borderColor: material.Colors.deepPurple.withValues(alpha: 
                              0.5,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(16.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        FluentIcons.refresh,
                                        color: material.Colors.deepPurple,
                                        size: 24,
                                      ),
                                      const SizedBox(width: 10),
                                      const Expanded(
                                        child: Text(
                                          'Carpeta local y fases',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 16,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),

                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: material.Colors.orange.withValues(alpha: 
                                        0.08,
                                      ),
                                      border: Border.all(
                                        color: material.Colors.orange.shade700,
                                        width: 1.2,
                                      ),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          '⚠️ PROCESO LARGO — Fase 1 trae archivos y convierte DWG; entre fases ejecutas tú la macro en SolidWorks; Fase 2 audita y sube a SQL.',
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 14),

                                  const Text(
                                    'Carpeta Origen (Red):',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: TextBox(
                                          controller: _sourceFolderController,
                                          placeholder: _kDefaultSourceRed,
                                          maxLines: 2,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Button(
                                        onPressed:
                                            isBusy ? null : _pickSourceFolder,
                                        child: const Text('Examinar…'),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  const Text(
                                    'Carpeta Destino (Local):',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: TextBox(
                                          controller: _localFolderController,
                                          placeholder:
                                              _defaultDesktopLocalPath(),
                                          maxLines: 2,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Button(
                                        onPressed:
                                            isBusy ? null : _pickDestFolder,
                                        child: const Text('Examinar…'),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 14),

                                  // ── Selector de modo ────────────────────────────
                                  const Text(
                                    'Alcance del proceso:',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Row(
                                    children: [
                                      RadioButton(
                                        checked: _maestroSoloFaltantes,
                                        onChanged:
                                            isBusy
                                                ? null
                                                : (v) => setState(
                                                  () =>
                                                      _maestroSoloFaltantes =
                                                          true,
                                                ),
                                        content: const Text(
                                          'Solo Faltantes (sin medidas en BD)',
                                        ),
                                      ),
                                      const SizedBox(width: 24),
                                      RadioButton(
                                        checked: !_maestroSoloFaltantes,
                                        onChanged:
                                            isBusy
                                                ? null
                                                : (v) => setState(
                                                  () =>
                                                      _maestroSoloFaltantes =
                                                          false,
                                                ),
                                        content: const Text(
                                          'Analizar Todo el Catálogo',
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.center,
                                    children: [
                                      Checkbox(
                                        checked: _inyectarPropiedadesMaestro,
                                        onChanged:
                                            isBusy
                                                ? null
                                                : (bool? v) {
                                                  setState(() {
                                                    _inyectarPropiedadesMaestro =
                                                        v ?? false;
                                                  });
                                                },
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          'Inyectar medidas en propiedades del archivo CAD original',
                                          style: TextStyle(
                                            fontSize: 13,
                                            color:
                                                FluentTheme.of(
                                                  context,
                                                ).typography.body?.color,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 14),

                                  FilledButton(
                                    onPressed: isBusy ? null : _startPreparar,
                                    style: ButtonStyle(
                                      backgroundColor:
                                          isBusy
                                              ? WidgetStateProperty.all(Colors.grey)
                                              : WidgetStateProperty.all(
                                                material.Colors.teal,
                                              ),
                                    ),
                                    child: const Padding(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 10,
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            FluentIcons.cloud_download,
                                            size: 18,
                                          ),
                                          SizedBox(width: 8),
                                          Text(
                                            'Fase 1: Traer de Red y Convertir 2D (DWG a DXF)',
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),

                                  const SizedBox(height: 16),
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 14,
                                      horizontal: 12,
                                    ),
                                    decoration: BoxDecoration(
                                      color: material.Colors.amber.withValues(alpha: 
                                        0.15,
                                      ),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: material.Colors.amber.shade700,
                                      ),
                                    ),
                                    child: const Text(
                                      '⚠️ PAUSA: Ejecuta tu macro de SolidWorks en la carpeta local antes de continuar.',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        height: 1.25,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 16),

                                  FilledButton(
                                    onPressed: isBusy ? null : _startAuditar,
                                    style: ButtonStyle(
                                      backgroundColor:
                                          isBusy
                                              ? WidgetStateProperty.all(Colors.grey)
                                              : WidgetStateProperty.all(
                                                material.Colors.deepPurple,
                                              ),
                                    ),
                                    child: const Padding(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 10,
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(FluentIcons.table, size: 18),
                                          SizedBox(width: 8),
                                          Text(
                                            "Fase 2: Auditar piezas ubicadas en la 'Carpeta Destino (Local)' seleccionada arriba",
                                            style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),

                                  const SizedBox(height: 10),
                                  Wrap(
                                    spacing: 10,
                                    runSpacing: 8,
                                    children: [
                                      // Botón Cancelar: SIEMPRE visible cuando hay una tarea activa
                                      Button(
                                        onPressed: isBusy ? _cancelScan : null,
                                        style: ButtonStyle(
                                          backgroundColor:
                                              isBusy
                                                  ? WidgetStateProperty.all(
                                                    material.Colors.red
                                                        .withValues(alpha: 0.12),
                                                  )
                                                  : WidgetStateProperty.all(
                                                    Colors.grey.withValues(alpha: 
                                                      0.05,
                                                    ),
                                                  ),
                                          foregroundColor:
                                              isBusy
                                                  ? WidgetStateProperty.all(
                                                    material.Colors.red,
                                                  )
                                                  : WidgetStateProperty.all(
                                                    Colors.grey,
                                                  ),
                                        ),
                                        child: const Padding(
                                          padding: EdgeInsets.symmetric(
                                            horizontal: 16,
                                            vertical: 10,
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                FluentIcons
                                                    .status_circle_error_x,
                                                size: 16,
                                              ),
                                              SizedBox(width: 6),
                                              Text(
                                                'Cancelar Escaneo',
                                                style: TextStyle(fontSize: 14),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            'Macro de ejemplo (VBA): cópiala y ejecútala en SolidWorks sobre la carpeta local entre Fase 1 y Fase 2.',
                            style: TextStyle(
                              fontSize: 12,
                              color:
                                  FluentTheme.of(
                                    context,
                                  ).typography.caption?.color,
                            ),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton(
                            onPressed:
                                isBusy
                                    ? null
                                    : () {
                                      Clipboard.setData(
                                        ClipboardData(text: _macroVbaText),
                                      );
                                      displayInfoBar(
                                        context,
                                        builder: (context, close) {
                                          return InfoBar(
                                            title: const Text('Macro copiada'),
                                            content: const Text(
                                              'Pégala en el editor VBA de SolidWorks',
                                            ),
                                            severity: InfoBarSeverity.success,
                                            onClose: close,
                                          );
                                        },
                                      );
                                    },
                            child: const Text('Copiar Macro a Portapapeles'),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Consola de Logs (Procesamiento CAD)
                  if (_cadLogs.isNotEmpty || isScanning || isProcessing) ...[
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
                          Text(
                            'Procesando archivos...',
                            style: TextStyle(fontStyle: FontStyle.italic),
                          ),
                        ],
                      ),
                    ],
                    if (_procesarStatus == 'completed') ...[
                      const SizedBox(height: 12),
                      Text(
                        'El procesamiento ha finalizado con éxito.',
                        style: TextStyle(
                          color: Colors.green,
                          fontWeight: FontWeight.bold,
                        ),
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
                    Builder(
                      builder: (context) {
                        final double pct =
                            (_totalItems > 0)
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
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
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
                      },
                    ),

                    const SizedBox(height: 12),

                    // ── Mini-Consola Terminal ─────────────────────────────────────
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0D0D0D),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: const Color(0xFF39FF14).withValues(alpha: 0.35),
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
                              _currentFile.isEmpty
                                  ? 'Iniciando...'
                                  : _currentFile,
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

                    if (_warningMessage.isNotEmpty)
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.orange),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              FluentIcons.warning,
                              color: material.Colors.redAccent,
                              size: 16,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _warningMessage,
                                style: const TextStyle(
                                  color: material.Colors.redAccent,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],

                  // Zona de Resultados
                  if (_status == 'completed') ...[
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: Colors.green.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.green),
                      ),
                      child: Column(
                        children: [
                          Icon(
                            FluentIcons.completed_solid,
                            size: 48,
                            color: Colors.green,
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            '¡Escaneo Finalizado con Éxito!',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Se encontraron y procesaron $_progress archivos CAD únicos.',
                          ),
                          const SizedBox(height: 24),
                          Wrap(
                            spacing: 16,
                            runSpacing: 16,
                            alignment: WrapAlignment.center,
                            children: [
                              if (_mostrarBotonExcel)
                                FilledButton(
                                  onPressed: _downloadExcel,
                                  style: ButtonStyle(
                                    backgroundColor: WidgetStateProperty.all(
                                      Colors.blue,
                                    ),
                                  ),
                                  child: const Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: 24,
                                      vertical: 12,
                                    ),
                                    child: Text(
                                      'Descargar Reporte Excel',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                              Button(
                                onPressed: () async {
                                  final base =
                                      kApiBaseUrl.endsWith('/')
                                          ? kApiBaseUrl.substring(
                                            0,
                                            kApiBaseUrl.length - 1,
                                          )
                                          : kApiBaseUrl;
                                  material.ScaffoldMessenger.maybeOf(
                                    context,
                                  )?.showSnackBar(
                                    const material.SnackBar(
                                      content: Text(
                                        'Abriendo carpeta local...',
                                      ),
                                    ),
                                  );
                                  try {
                                    final res = await http.get(
                                      Uri.parse('$base/api/cad/open-folder'),
                                    );
                                    if (!mounted) return;
                                    if (res.statusCode != 200) {
                                      displayInfoBar(
                                        context,
                                        builder: (ctx, close) {
                                          return InfoBar(
                                            title: const Text(
                                              'No se pudo abrir la carpeta',
                                            ),
                                            content: Text(
                                              res.body.isNotEmpty
                                                  ? res.body
                                                  : 'HTTP ${res.statusCode}',
                                            ),
                                            severity: InfoBarSeverity.error,
                                            onClose: close,
                                          );
                                        },
                                      );
                                    }
                                  } catch (e) {
                                    if (!mounted) return;
                                    displayInfoBar(
                                      context,
                                      builder: (ctx, close) {
                                        return InfoBar(
                                          title: const Text('Error de red'),
                                          content: Text(e.toString()),
                                          severity: InfoBarSeverity.error,
                                          onClose: close,
                                        );
                                      },
                                    );
                                  }
                                },
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 12,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(FluentIcons.folder_open),
                                      SizedBox(width: 8),
                                      Text(
                                        'Abrir Carpeta de Trabajo (Desktop)',
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
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
                      color: Colors.blue.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.blue),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Actualizar Base de Datos',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Sube el archivo Excel previament descargado con las columnas Largo_CAD y Ancho_CAD debidamente llenadas para actualizar el Catálogo Maestro.',
                        ),
                        const SizedBox(height: 16),
                        Button(
                          onPressed: isBusy ? null : _uploadModifiedExcel,
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(FluentIcons.upload),
                                SizedBox(width: 8),
                                Text(
                                  'Cargar Excel Modificado',
                                  style: TextStyle(fontSize: 16),
                                ),
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
        ),
      ],
    );
  }
}
