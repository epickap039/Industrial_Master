import 'package:fluent_ui/fluent_ui.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_file/open_file.dart';
import 'dart:io';

const String API_URL = "http://192.168.1.73:8001";

class BOMManagerScreen extends StatefulWidget {
  final int? idCliente;
  final String? clientName;
  // v60.0: nuevos parámetros de ingeniería maestra
  final int? idVersion;
  final String? versionName;
  final String? tractoName; // para theming de color
  
  const BOMManagerScreen({
    Key? key, 
    this.idCliente, 
    this.clientName,
    this.idVersion,
    this.versionName,
    this.tractoName,
  }) : super(key: key);

  @override
  _BOMManagerScreenState createState() => _BOMManagerScreenState();
}

class _BOMManagerScreenState extends State<BOMManagerScreen> {
  bool _isLoading = false;
  
  int _currentIdCliente = 0;
  String _currentClientName = '';

  List<dynamic> _arbol = [];
  dynamic _selectedEnsamble;
  List<dynamic> _revisiones = [];
  dynamic _selectedRevision;
  List<dynamic> _vins = [];
  bool _propagarAutomaticamente = false;

  // v60.0: determina el color de acento según el nombre del tracto
  Color get _accentColor {
    final t = (widget.tractoName ?? '').toUpperCase();
    if (t.contains('KENWORTH')) return const Color(0xFFD32F2F); // Rojo
    if (t.contains('INTERNATIONAL')) return const Color(0xFFE65100); // Naranja
    if (t.contains('PETERBILT')) return const Color(0xFF1565C0); // Azul
    return const Color(0xFF1565C0); // Azul por defecto
  }

  // v60.0: ID maestro de la versión de ingeniería
  int get _masterId => widget.idVersion ?? widget.idCliente ?? 1;
  bool get _usingVersionMode => widget.idVersion != null;

  @override
  void initState() {
    super.initState();
    _fetchRevisiones();
  }

  void _clearData() {
    setState(() {
      _arbol = [];
      _selectedEnsamble = null;
      _vins = [];
    });
  }

  Future<void> _fetchRevisiones() async {
    setState(() => _isLoading = true);
    try {
      // v60.0: usa endpoint por version si está disponible
      final url = _usingVersionMode
          ? '$API_URL/api/bom/revisiones/version/$_masterId'
          : '$API_URL/api/bom/revisiones/$_masterId';
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        _clearData();
        setState(() {
          _revisiones = json.decode(response.body);
          if (_revisiones.isNotEmpty) {
            _selectedRevision = _revisiones.last; // última revisión por defecto
            _fetchArbol();
          } else {
            _selectedRevision = null;
          }
        });
      }
    } catch (e) {
      _showError("Error al cargar revisiones: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _addRevision(String nombre) async {
    setState(() => _isLoading = true);
    try {
      // v60.0: endpoint por versión
      final url = _usingVersionMode
          ? '$API_URL/api/bom/revisiones/version/$_masterId'
          : '$API_URL/api/bom/revisiones/$_masterId';
      final response = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'nombre_revision': nombre}),
      );
      if (response.statusCode == 200) {
        await _fetchRevisiones();
      } else {
        _showError("Error al crear revisión: ${response.statusCode}");
      }
    } catch (e) {
      _showError("Error: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _aprobarRevision() async {
    if (_selectedRevision == null) return;
    setState(() => _isLoading = true);
    try {
      final response = await http.put(
        Uri.parse('$API_URL/api/bom/revisiones/${_selectedRevision['id_revision']}/aprobar'),
      );
      if (response.statusCode == 200) {
        _showError("Revisión Aprobada Correctamente", isError: false);
        await _fetchRevisiones();
      } else {
        _showError("Error al aprobar: ${response.body}");
      }
    } catch (e) {
      _showError("Error de conexión: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _fetchArbol() async {
    if (_selectedRevision == null) return;
    setState(() => _isLoading = true);
    try {
      final response = await http.get(Uri.parse('$API_URL/api/bom/arbol/${_selectedRevision['id_revision']}'));
      if (response.statusCode == 200) {
        setState(() {
          _arbol = json.decode(response.body);
          // Actualizar selectedEnsamble si es que se borró o cambió
          if (_selectedEnsamble != null) {
            bool found = false;
            for (var est in _arbol) {
              for (var ens in est['ensambles']) {
                if (ens['id'] == _selectedEnsamble['id']) {
                  _selectedEnsamble = ens;
                  found = true;
                  break;
                }
              }
            }
            if (!found) _selectedEnsamble = null;
          }
        });
      } else {
        _showError("Error cargar árbol: ${response.statusCode}");
      }
    } catch (e) {
      _showError("Error al cargar árbol: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _importarExcel() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx', 'xls'],
      );

      if (result != null && result.files.single.path != null) {
        if (_selectedRevision == null) {
          _showError("Crea o selecciona una revisión primero");
          return;
        }

        String filePath = result.files.single.path!;
        
        setState(() => _isLoading = true);

        var request = http.MultipartRequest(
          'POST', 
          Uri.parse('$API_URL/api/bom/importar/${_selectedRevision['id_revision']}')
        );
        
        request.files.add(await http.MultipartFile.fromPath('file', filePath));
        
        var streamedResponse = await request.send();
        var response = await http.Response.fromStream(streamedResponse);

        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          int importadas = data['insertados'] ?? 0;
          List errores = data['errores'] ?? [];

          if (errores.isEmpty) {
            _showError("✅ Se cargaron $importadas piezas con éxito.", isError: false);
          } else {
            showDialog(
              context: context,
              builder: (context) => ContentDialog(
                title: const Text("Resumen de Importación"),
                content: Text("Se cargaron $importadas piezas con éxito.\n\n"
                    "Los siguientes códigos no existen en el catálogo maestro y fueron omitidos:\n${errores.join(', ')}"),
                actions: [
                  Button(
                    child: const Text('Copiar Errores'),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: errores.join(', ')));
                      _showError("Errores copiados al portapapeles", isError: false);
                    },
                  ),
                  Button(
                    child: const Text('Cerrar'),
                    onPressed: () => Navigator.pop(context),
                  )
                ],
              ),
            );
          }
          _fetchArbol();
        } else {
          final errorMsg = json.decode(response.body)['detail'] ?? "Error desconocido en el servidor";
          _showError("Error al importar: $errorMsg");
        }
      }
    } catch (e) {
      _showError("Error durante la importación: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _addEstacion(String nombre) async {
    if (_selectedRevision == null) return;
    try {
      final response = await http.post(
        Uri.parse('$API_URL/api/bom/estaciones'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'id_revision': _selectedRevision['id_revision'], 'nombre': nombre}),
      );
      if (response.statusCode == 200) {
        _fetchArbol();
      } else {
        _showError("Error al agregar la estación");
      }
    } catch (e) {
      _showError("Error: $e");
    }
  }

  Future<void> _deleteEstacion(int id) async {
    try {
      final response = await http.delete(Uri.parse('$API_URL/api/bom/estaciones/$id'));
      if (response.statusCode == 200) {
        if (_selectedEnsamble != null && _arbol.any((est) => est['id'] == id)) {
           _selectedEnsamble = null;
        }
        _fetchArbol();
      } else {
        final errorMsg = json.decode(response.body)['detail'] ?? "Error desconocido";
        _showError(errorMsg);
      }
    } catch (e) {
      _showError("Error al eliminar la estación: $e");
    }
  }

  Future<void> _addEnsamble(int idEstacion, String nombre) async {
    try {
      final response = await http.post(
        Uri.parse('$API_URL/api/bom/ensambles'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'id_estacion': idEstacion, 'nombre': nombre}),
      );
      if (response.statusCode == 200) {
        _fetchArbol();
      } else {
        _showError("Error al agregar el ensamble");
      }
    } catch (e) {
      _showError("Error: $e");
    }
  }

  Future<void> _deleteEnsamble(int id) async {
    try {
      final response = await http.delete(Uri.parse('$API_URL/api/bom/ensambles/$id'));
      if (response.statusCode == 200) {
        if (_selectedEnsamble != null && _selectedEnsamble['id'] == id) {
          _selectedEnsamble = null;
        }
        _fetchArbol();
      } else {
        final errorMsg = json.decode(response.body)['detail'] ?? "Error desconocido";
        _showError(errorMsg);
      }
    } catch (e) {
      _showError("Error al eliminar el ensamble: $e");
    }
  }

  Future<void> _addPieza(String codigo, double cantidad, String obs) async {
    if (_selectedEnsamble == null) return;
    try {
      final response = await http.post(
        Uri.parse('$API_URL/api/bom/estructura'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'id_ensamble': _selectedEnsamble['id'],
          'codigo_pieza': codigo,
          'cantidad': cantidad,
          'observaciones': obs
        }),
      );
      if (response.statusCode == 200) {
        _fetchArbol();
      } else {
        _showError("Error al agregar la pieza");
      }
    } catch (e) {
      _showError("Error: $e");
    }
  }

  Future<void> _deletePieza(int idBom) async {
    try {
      final response = await http.delete(Uri.parse('$API_URL/api/bom/estructura/$idBom'));
      if (response.statusCode == 200) {
        _fetchArbol();
      }
    } catch (e) {
      _showError("Error al eliminar la pieza: $e");
    }
  }

  Future<void> _updateCantidadPieza(int idBom, double nuevaCantidad, {bool propagar = false, String? codigo}) async {
    try {
      final response = await http.put(
        Uri.parse('$API_URL/api/bom/estructura/cantidad/$idBom'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'cantidad': nuevaCantidad}),
      );
      if (response.statusCode == 200) {
        _showError("✅ Cantidad actualizada correctamente", isError: false);
        _fetchArbol();
        if (_propagarAutomaticamente && codigo != null) {
          _showPropagacionDialog(codigo, nuevaCantidad);
        }
      } else {
        _showError("Error al actualizar la cantidad");
      }
    } catch (e) {
      _showError("Error de conexión: $e");
    }
  }

  Future<void> _exportarExcel() async {
    if (_selectedRevision == null) return;
    setState(() => _isLoading = true);
    try {
      final response = await http.get(Uri.parse('$API_URL/api/bom/exportar/${_selectedRevision['id_revision']}'));
      if (response.statusCode == 200) {
        final directory = await getApplicationDocumentsDirectory();
        final filePath = '${directory.path}/BOM_Rev_${_selectedRevision['numero_revision']}.xlsx';
        final file = File(filePath);
        await file.writeAsBytes(response.bodyBytes);
        _showError("Archivo exportado en: $filePath", isError: false);
        OpenFile.open(filePath);
      } else {
        _showError("Error al exportar: ${response.statusCode}");
      }
    } catch (e) {
      _showError("Error: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // ── NUEVO v60.1: Eliminar revisión con protección ──────────────────────────
  Future<void> _deleteRevision({String password = '', String motivo = ''}) async {
    if (_selectedRevision == null) return;
    final idRev = _selectedRevision['id_revision'];
    setState(() => _isLoading = true);
    try {
      final response = await http.delete(
        Uri.parse('$API_URL/api/bom/revisiones/$idRev'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'password': password, 'motivo': motivo}),
      );
      if (response.statusCode == 200) {
        _showError("✅ Revisión eliminada correctamente", isError: false);
        setState(() {
          _selectedRevision = null;
          _arbol = [];
          _selectedEnsamble = null;
        });
        _fetchRevisiones();
      } else if (response.statusCode == 401) {
        _showError("❌ Contraseña incorrecta. Operación denegada.");
      } else {
        final detail = json.decode(response.body)['detail'] ?? 'Error desconocido';
        _showError("Error: $detail");
      }
    } catch (e) {
      _showError("Error de conexión: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _showDeleteRevisionDialog() {
    if (_selectedRevision == null) {
      _showError("Selecciona una revisión primero.");
      return;
    }
    final bool isAprobada = _selectedRevision['estado'] == 'Aprobada';
    final String revLabel =
        "Rev. ${_selectedRevision['numero_revision']} — ${_selectedRevision['estado']}";
    String passwordInput = '';
    String motivoInput = '';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => ContentDialog(
          constraints: const BoxConstraints(maxWidth: 460, maxHeight: 380),
          title: Row(children: [
            Icon(FluentIcons.delete, color: isAprobada ? Colors.red : Colors.orange, size: 20),
            const SizedBox(width: 8),
            Text(isAprobada ? "⚠️ Eliminar Revisión Aprobada" : "Eliminar Revisión"),
          ]),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isAprobada) ...[
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.1),
                    border: Border.all(color: Colors.red),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(children: [
                    Icon(FluentIcons.error_badge, color: Colors.red, size: 18),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "ADVERTENCIA: Esta revisión está APROBADA. "
                        "Eliminarla borrará permanentemente toda su ingeniería. "
                        "Se requiere contraseña de seguridad.",
                        style: TextStyle(color: Colors.red, fontSize: 12),
                      ),
                    ),
                  ]),
                ),
                const SizedBox(height: 12),
                const Text("Contraseña de Seguridad:", style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                PasswordBox(
                  placeholder: 'Contraseña maestra...',
                  onChanged: (v) => setD(() => passwordInput = v),
                ),
                const SizedBox(height: 10),
              ] else ...[
                Text("¿Estás seguro de eliminar $revLabel?",
                    style: const TextStyle(fontWeight: FontWeight.w500)),
                const SizedBox(height: 4),
                const Text("Se borrarán todas las estaciones, ensambles y piezas de esta revisión.",
                    style: TextStyle(fontSize: 12, color: Color(0xFFF57C00))),
                const SizedBox(height: 10),
              ],
              const Text("Motivo del borrado (opcional):"),
              const SizedBox(height: 4),
              TextBox(
                placeholder: "Describe el motivo...",
                onChanged: (v) => setD(() => motivoInput = v),
              ),
            ],
          ),
          actions: [
            Button(
              child: const Text("Cancelar"),
              onPressed: () => Navigator.pop(ctx),
            ),
            FilledButton(
              style: ButtonStyle(
                backgroundColor: WidgetStateProperty.all(Colors.red),
              ),
              child: const Text("ELIMINAR"),
              onPressed: () {
                Navigator.pop(ctx);
                _deleteRevision(password: passwordInput, motivo: motivoInput);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _clonarBOM(int idOrigen) async {
    if (_selectedRevision == null) return;
    setState(() => _isLoading = true);
    try {
      final response = await http.post(
        Uri.parse('$API_URL/api/bom/clonar'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'id_revision_origen': idOrigen,
          'id_revision_destino': _selectedRevision['id_revision']
        }),
      );
      if (response.statusCode == 200) {
        _showError("✅ BOM Clonado correctamente", isError: false);
        _fetchArbol();
      } else {
        _showError("Error al clonar BOM");
      }
    } catch (e) {
      _showError("Error: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _propagarCambio(String codigo, double cantidad, List<int> ids) async {
    try {
      final response = await http.post(
        Uri.parse('$API_URL/api/bom/propagar'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'codigo_pieza': codigo,
          'nueva_cantidad': cantidad,
          'id_revisiones': ids
        }),
      );
      if (response.statusCode == 200) {
        _showError("✅ Cambio propagado exitosamente", isError: false);
      }
    } catch (e) {
      _showError("Error al propagar: $e");
    }
  }

  Future<void> _updateVINNotas(int idUnidad, String notas) async {
    try {
      final response = await http.put(
        Uri.parse('$API_URL/api/vins/$idUnidad/notas'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'vin': '', 'notas': notas}), // vin es requerido por el modelo pero ignorado si es vacío en el update
      );
      if (response.statusCode == 200) {
        await _fetchVINs();
      }
    } catch (e) {
      _showError("Error guardando notas: $e");
    }
  }

  Future<void> _fetchVINs() async {
    if (_selectedRevision == null) return;
    try {
      final response = await http.get(Uri.parse('$API_URL/api/bom/revisiones/${_selectedRevision['id_revision']}/vins'));
      if (response.statusCode == 200) {
        setState(() {
          _vins = json.decode(response.body);
        });
      }
    } catch (e) {
      _showError("Error al cargar VINs: $e");
    }
  }

  Future<void> _addVIN(String vin) async {
    if (_selectedRevision == null) return;
    try {
      final response = await http.post(
        Uri.parse('$API_URL/api/bom/revisiones/${_selectedRevision['id_revision']}/vins'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'vin': vin}),
      );
      if (response.statusCode == 200) {
        await _fetchVINs();
      } else {
        _showError("Error al agregar VIN");
      }
    } catch (e) {
      _showError("Error: $e");
    }
  }

  Future<void> _deleteVIN(int idUnidad) async {
    try {
      final response = await http.delete(Uri.parse('$API_URL/api/bom/vins/$idUnidad'));
      if (response.statusCode == 200) {
        await _fetchVINs();
      } else {
        _showError("Error al eliminar VIN");
      }
    } catch (e) {
      _showError("Error: $e");
    }
  }

  void _showError(String message, {bool isError = true}) {
    displayInfoBar(context, builder: (context, close) {
      return InfoBar(
        title: Text(isError ? 'Error' : 'Éxito'),
        content: Text(message),
        severity: isError ? InfoBarSeverity.error : InfoBarSeverity.success,
        onClose: close,
      );
    });
  }

  // DIALOGOS
  void _showAddDialog(String title, Function(String) onSave) {
    String inputValue = "";
    showDialog(
      context: context,
      builder: (context) => ContentDialog(
        title: Text(title),
        content: TextBox(
          placeholder: 'Nombre...',
          onChanged: (v) => inputValue = v,
        ),
        actions: [
          Button(child: const Text('Cancelar'), onPressed: () => Navigator.pop(context)),
          FilledButton(
            child: const Text('Guardar'),
            onPressed: () {
              if (inputValue.trim().isNotEmpty) {
                onSave(inputValue.trim());
                Navigator.pop(context);
              }
            },
          )
        ],
      ),
    );
  }

  void _showAddPiezaDialog() {
    String codigoValue = "";
    String cantStr = "";
    String obsValue = "";

    showDialog(
      context: context,
      builder: (context) => ContentDialog(
        title: const Text("Agregar Pieza"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InfoLabel(
              label: "Código de Pieza (del Catálogo)",
              child: TextBox(
                onChanged: (v) => codigoValue = v,
              ),
            ),
            const SizedBox(height: 8),
            InfoLabel(
              label: "Cantidad",
              child: TextBox(
                keyboardType: TextInputType.number,
                onChanged: (v) => cantStr = v,
              ),
            ),
            const SizedBox(height: 8),
            InfoLabel(
              label: "Observaciones",
              child: TextBox(
                onChanged: (v) => obsValue = v,
              ),
            ),
          ],
        ),
        actions: [
          Button(child: const Text('Cancelar'), onPressed: () => Navigator.pop(context)),
          FilledButton(
            child: const Text('Agregar'),
            onPressed: () {
              if (codigoValue.trim().isNotEmpty && cantStr.isNotEmpty) {
                double? cant = double.tryParse(cantStr);
                if (cant != null) {
                  _addPieza(codigoValue.trim(), cant, obsValue.trim());
                  Navigator.pop(context);
                } else {
                  _showError("Cantidad inválida");
                }
              }
            },
          )
        ],
      ),
    );
  }

  void _confirmDelete(String title, VoidCallback onConfirm) {
    showDialog(
      context: context,
      builder: (context) => ContentDialog(
        title: const Text('Eliminar'),
        content: Text(title),
        actions: [
          Button(child: const Text('Cancelar'), onPressed: () => Navigator.pop(context)),
          FilledButton(
            style: ButtonStyle(backgroundColor: ButtonState.all(Colors.red)),
            child: const Text('Eliminar'),
            onPressed: () {
              onConfirm();
              Navigator.pop(context);
            },
          )
        ],
      ),
    );
  }

  void _showVINManagementDialog() {
    if (_selectedRevision == null) return;
    String newVin = "";
    _fetchVINs();
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return ContentDialog(
            title: const Text("VINs Asignados - Gestión"),
            content: SizedBox(
              width: 500,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextBox(
                          placeholder: "Nuevo VIN...",
                          onChanged: (v) => newVin = v,
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        child: const Text("Agregar"),
                        onPressed: () {
                          if (newVin.trim().isNotEmpty) {
                            _addVIN(newVin.trim()).then((_) {
                              setDialogState(() {});
                            });
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 400),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: _vins.length,
                      itemBuilder: (context, index) {
                        final vin = _vins[index];
                        return ListTile(
                          title: Text(vin['vin']),
                          subtitle: Text(vin['notas'] ?? "Sin notas", maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(FluentIcons.edit_note),
                                onPressed: () => _showNotasVINDialog(vin),
                              ),
                              IconButton(
                                icon: const Icon(FluentIcons.delete),
                                onPressed: () {
                                  _confirmDelete("¿Seguro de eliminar el VIN ${vin['vin']}?", () {
                                    _deleteVIN(vin['id_unidad']).then((_) {
                                      setDialogState(() {});
                                    });
                                  });
                                },
                              ),
                            ],
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
                child: const Text("Cerrar"),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          );
        }
      ),
    );
  }

  void _showNotasVINDialog(dynamic vin) {
    String notasTemp = vin['notas'] ?? "";
    showDialog(
      context: context,
      builder: (context) => ContentDialog(
        title: Text("Notas del VIN: ${vin['vin']}"),
        content: TextBox(
          controller: TextEditingController(text: notasTemp),
          maxLines: 5,
          placeholder: "Escribe notas aquí...",
          onChanged: (v) => notasTemp = v,
        ),
        actions: [
          Button(child: const Text("Cancelar"), onPressed: () => Navigator.pop(context)),
          FilledButton(
            child: const Text("Guardar"),
            onPressed: () {
              _updateVINNotas(vin['id_unidad'], notasTemp);
              Navigator.pop(context);
            },
          ),
        ],
      ),
    );
  }

  void _showClonarDialog() async {
    int? selectedOrigenId;
    List<dynamic> allRevisions = [];
    bool loadingDialog = true;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDState) {
          if (loadingDialog) {
            http.get(Uri.parse('$API_URL/api/bom/revisiones/$_masterId')).then((res) {
              if (res.statusCode == 200) {
                setDState(() {
                  allRevisions = (json.decode(res.body) as List).where((r) => r['id_revision'] != _selectedRevision['id_revision']).toList();
                  loadingDialog = false;
                });
              }
            });
            return const ContentDialog(content: ProgressRing());
          }

          return ContentDialog(
            title: const Text("Clonar BOM desde otra Revisión"),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text("Selecciona la revisión de origen para copiar toda su estructura a la revisión actual:"),
                const SizedBox(height: 16),
                ComboBox<int>(
                  placeholder: const Text("Seleccionar Revisión Origen"),
                  value: selectedOrigenId,
                  items: allRevisions.map((r) => ComboBoxItem<int>(
                    value: r['id_revision'],
                    child: Text("Rev ${r['numero_revision']} (ID ${r['id_revision']}) - ${r['estado']}"),
                  )).toList(),
                  onChanged: (v) => setDState(() => selectedOrigenId = v),
                ),
              ],
            ),
            actions: [
              Button(child: const Text("Cancelar"), onPressed: () => Navigator.pop(context)),
              FilledButton(
                child: const Text("Clonar Ahora"),
                onPressed: selectedOrigenId == null ? null : () {
                  Navigator.pop(context);
                  _clonarBOM(selectedOrigenId!);
                },
              ),
            ],
          );
        },
      ),
    );
  }


  void _showPropagacionDialog(String codigo, double cantidad) async {
    List<int> selectedIds = [];
    List<dynamic> jerarquia = [];
    bool dialogLoading = true;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDState) {
          if (dialogLoading) {
            http.get(Uri.parse('$API_URL/api/bom/buscar_pieza_jerarquia/$codigo?exclude_rev=${_selectedRevision['id_revision']}')).then((res) {
              if (res.statusCode == 200) {
                setDState(() {
                  jerarquia = json.decode(res.body);
                  dialogLoading = false;
                });
              }
            });
            return const ContentDialog(content: ProgressRing());
          }

          return ContentDialog(
            title: Text("Propagar cambio: $codigo"),
            content: SizedBox(
              width: 500,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Selecciona las listas donde deseas actualizar la cantidad a $cantidad:"),
                  const SizedBox(height: 12),
                  if (jerarquia.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(8.0),
                      child: Text("No se encontró esta pieza en otras revisiones."),
                    )
                  else
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: jerarquia.length,
                        itemBuilder: (context, idx) {
                          final item = jerarquia[idx];
                          final label = "${item['tracto']} > ${item['tipo']} > ${item['version']} > ${item['cliente']}";
                          final revisionInfo = "Rev ${item['numero_revision']} - ${item['estado']}";
                          
                          return Checkbox(
                            content: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
                                Text(revisionInfo, style: const TextStyle(fontSize: 12)),
                                Text("Cantidad actual: ${item['cantidad']}", style: TextStyle(color: Colors.blue.withOpacity(0.8), fontSize: 11)),
                              ],
                            ),
                            checked: selectedIds.contains(item['id_revision']),
                            onChanged: (v) {
                              setDState(() {
                                if (v == true) selectedIds.add(item['id_revision']);
                                else selectedIds.remove(item['id_revision']);
                              });
                            },
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              Button(child: const Text("Cancelar"), onPressed: () => Navigator.pop(context)),
              FilledButton(
                child: const Text("Propagar a Marcados"),
                onPressed: selectedIds.isEmpty ? null : () {
                  _propagarCambio(codigo, cantidad, selectedIds);
                  Navigator.pop(context);
                },
              ),
            ],
          );
        }
      ),
    );
  }

  List<TreeViewItem> _buildTreeItems() {
    final bool isAprobada = _selectedRevision != null && _selectedRevision['estado'] == 'Aprobada';

    return _arbol.map((est) {
      return TreeViewItem(
        content: Row(
          children: [
            Expanded(
              child: Text(est['nombre'], style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            if (!isAprobada) ...[
              IconButton(
                icon: const Icon(FluentIcons.add),
                onPressed: () => _showAddDialog("Nuevo Ensamble para ${est['nombre']}", (nombre) {
                  _addEnsamble(est['id'], nombre);
                }),
              ),
              IconButton(
                icon: const Icon(FluentIcons.delete),
                onPressed: () => _confirmDelete("¿Seguro de eliminar la estación '${est['nombre']}' y todo su contenido?", () {
                  _deleteEstacion(est['id']);
                }),
              ),
            ],
          ],
        ),
        children: (est['ensambles'] as List).map((ens) {
          final isSelected = _selectedEnsamble != null && _selectedEnsamble['id'] == ens['id'];
          return TreeViewItem(
            content: GestureDetector(
              onTap: () {
                setState(() => _selectedEnsamble = ens);
              },
              child: Container(
                color: isSelected ? Colors.blue.withOpacity(0.2) : Colors.transparent,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        "[E-${ens['id'].toString().padLeft(4, '0')}] - ${ens['nombre']}",
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                    ),
                    if (!isAprobada)
                      IconButton(
                        icon: const Icon(FluentIcons.delete),
                        onPressed: () => _confirmDelete("¿Seguro de eliminar el ensamble '${ens['nombre']}' y sus piezas?", () {
                          _deleteEnsamble(ens['id']);
                        }),
                      ),
                  ],
                ),
              ),
            ),
            value: ens,
          );
        }).toList(),
      );
    }).toList();
  }

  Widget _buildPiezasTable() {
    if (_selectedEnsamble == null) {
      return const Center(child: Text("Selecciona un ensamble para ver sus piezas."));
    }

    final piezas = _selectedEnsamble['piezas'] as List;
    final bool isAprobada = _selectedRevision != null && _selectedRevision['estado'] == 'Aprobada';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text("Piezas en: ${_selectedEnsamble['nombre']}", style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            if (!isAprobada)
              FilledButton(
                onPressed: _showAddPiezaDialog,
                child: const Text("Agregar Pieza"),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Expanded(
          child: piezas.isEmpty
              ? const Center(child: Text("No hay piezas en este ensamble."))
              : ListView.builder(
                  itemCount: piezas.length + 1, // Header + Rows
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return Container(
                        padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
                        color: Colors.blue.withOpacity(0.1),
                        child: const Row(
                          children: [
                            Expanded(flex: 2, child: Text("Código", style: TextStyle(fontWeight: FontWeight.bold))),
                            Expanded(flex: 4, child: Text("Descripción Oficial", style: TextStyle(fontWeight: FontWeight.bold))),
                            Expanded(flex: 1, child: Text("Cant.", style: TextStyle(fontWeight: FontWeight.bold))),
                            Expanded(flex: 2, child: Text("Procesos", style: TextStyle(fontWeight: FontWeight.bold))),
                            Expanded(flex: 1, child: Text("Simetría", style: TextStyle(fontWeight: FontWeight.bold))),
                            Expanded(flex: 1, child: Text("Plano / Acciones", style: TextStyle(fontWeight: FontWeight.bold))),
                          ],
                        ),
                      );
                    }

                    final pieza = piezas[index - 1];
                    
                    List<String> procesos = [];
                    if (pieza['proceso_primario'] != null && pieza['proceso_primario'].toString().isNotEmpty) procesos.add(pieza['proceso_primario'].toString());
                    if (pieza['proceso_1'] != null && pieza['proceso_1'].toString().isNotEmpty) procesos.add(pieza['proceso_1'].toString());
                    if (pieza['proceso_2'] != null && pieza['proceso_2'].toString().isNotEmpty) procesos.add(pieza['proceso_2'].toString());
                    if (pieza['proceso_3'] != null && pieza['proceso_3'].toString().isNotEmpty) procesos.add(pieza['proceso_3'].toString());
                    
                    String strProcesos = procesos.join(', ');
                    String strLink = pieza['link_drive']?.toString() ?? '';
                    bool hasLink = strLink.isNotEmpty && strLink != 'N/A';

                    return Container(
                      padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 16.0),
                      decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(color: const Color(0xFFEEEEEE))),
                      ),
                      child: Row(
                        children: [
                          Expanded(flex: 2, child: Text(pieza['codigo'])),
                          Expanded(
                            flex: 4, 
                            child: Tooltip(
                              message: pieza['descripcion'],
                              child: Text(pieza['descripcion'], overflow: TextOverflow.ellipsis),
                            ),
                          ),
                          Expanded(
                            flex: 1, 
                            child: Row(
                              children: [
                                Expanded(
                                  child: TextBox(
                                    controller: TextEditingController(text: pieza['cantidad'].toString()),
                                    keyboardType: TextInputType.number,
                                    textInputAction: TextInputAction.done,
                                    enabled: !isAprobada,
                                    placeholder: "Cant.",
                                    onSubmitted: (value) {
                                      double? cant = double.tryParse(value);
                                      if (cant != null && cant > 0) {
                                        _updateCantidadPieza(pieza['id'], cant, codigo: pieza['codigo']);
                                      } else {
                                        _showError("Cantidad inválida o igual a 0");
                                      }
                                    },
                                  ),
                                ),
                                if (!isAprobada)
                                  IconButton(
                                    icon: const Icon(FluentIcons.sync_occurence, size: 14),
                                    onPressed: () {
                                      _showPropagacionDialog(pieza['codigo'], pieza['cantidad'].toDouble());
                                    },
                                  ),
                              ],
                            ),
                          ),
                          Expanded(flex: 2, child: Text(strProcesos, style: const TextStyle(fontSize: 12))),
                          Expanded(flex: 1, child: Text(pieza['simetria']?.toString() ?? '')),
                          Expanded(
                            flex: 1, 
                            child: Row(
                              children: [
                                if (hasLink)
                                  Tooltip(
                                    message: "Abrir Plano",
                                    child: IconButton(
                                      icon: Icon(FluentIcons.link, color: Colors.blue), 
                                      onPressed: () async {
                                        final Uri url = Uri.parse(strLink);
                                        if (await canLaunchUrl(url)) {
                                          await launchUrl(url);
                                        }
                                      }
                                    )
                                  ),
                                if (!isAprobada)
                                  IconButton(
                                    icon: Icon(FluentIcons.delete, color: Colors.red),
                                    onPressed: () => _confirmDelete("¿Seguro de quitar la pieza ${pieza['codigo']}?", () {
                                      _deletePieza(pieza['id']);
                                    }),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // === v60.0: HORIZONTAL STEPPER DE REVISIONES ===
  Widget _buildRevisionStepper() {
    if (_revisiones.isEmpty) {
      return const Text("Sin revisiones", style: TextStyle(color: Colors.grey));
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: List.generate(
          // BUGFIX: proteger contra lista vacía (length=0 → count=-1 → RangeError)
          _revisiones.isEmpty ? 0 : _revisiones.length * 2 - 1,
          (i) {
          if (i.isOdd) {
            // Conector entre pasos
            return Container(
              width: 24, height: 2,
              color: Colors.grey.withOpacity(0.4),
            );
          }
          final rev = _revisiones[i ~/ 2];
          final isSelected = _selectedRevision != null &&
              _selectedRevision['id_revision'] == rev['id_revision'];
          final isAprobada = rev['estado'] == 'Aprobada';
          final stepColor = isAprobada
              ? const Color(0xFF2E7D32) // Verde
              : const Color(0xFFF9A825); // Amarillo

          return Tooltip(
            message: "Rev ${rev['numero_revision']} - ${rev['estado']} (click para seleccionar)",
            child: GestureDetector(
              onTap: () {
                _clearData();
                setState(() => _selectedRevision = rev);
                _fetchArbol();
                _fetchVINs();
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: isSelected ? stepColor : stepColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: stepColor,
                    width: isSelected ? 2.5 : 1,
                  ),
                  boxShadow: isSelected
                      ? [BoxShadow(color: stepColor.withOpacity(0.4), blurRadius: 6)]
                      : [],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isAprobada ? FluentIcons.lock : FluentIcons.edit,
                      size: 12,
                      color: isSelected ? Colors.white : stepColor,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      "Rev ${rev['numero_revision']}",
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        color: isSelected ? Colors.white : stepColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: PageHeader(
        leading: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0),
          child: IconButton(
            icon: const Icon(FluentIcons.back),
            onPressed: () {
              if (Navigator.canPop(context)) Navigator.pop(context);
            },
          ),
        ),
        title: const Text('Gestor de Listas (BOM)'),
      ),
      content: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header con CommandBar
            Container(
              decoration: BoxDecoration(
                color: _accentColor.withOpacity(0.06),
                border: Border(bottom: BorderSide(color: _accentColor.withOpacity(0.2), width: 1.5)),
              ),
              child: Row(
                children: [
                  // === v60.0: HORIZONTAL STEPPER DE REVISIONES ===
                  Expanded(
                    flex: 4,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
                      child: _buildRevisionStepper(),
                    ),
                  ),
                  // Divider vertical
                  Container(width: 1, height: 24, color: Colors.grey.withOpacity(0.2)),
                  // Centro/Derecha: CommandBar responsiva (primaryItems + secondaryItems)
                  Expanded(
                    child: CommandBar(
                      overflowBehavior: CommandBarOverflowBehavior.dynamicOverflow,
                      primaryItems: [
                        // ── PRIMARIOS: Siempre visibles ─────────────────────
                        CommandBarButton(
                          icon: const Icon(FluentIcons.add),
                          label: const Text("Nueva Rev."),
                          onPressed: () => _showAddDialog("Nueva Revisión", _addRevision),
                        ),
                        if (_selectedRevision != null &&
                            _selectedRevision['estado'] != 'Aprobada')
                          CommandBarButton(
                            icon: Icon(FluentIcons.lock, color: Colors.green),
                            label: const Text("Aprobar"),
                            onPressed: _aprobarRevision,
                          ),
                        CommandBarButton(
                          icon: Icon(
                            FluentIcons.delete,
                            color: _selectedRevision?['estado'] == 'Aprobada'
                                ? Colors.red
                                : Colors.orange,
                          ),
                          label: const Text("Eliminar"),
                          onPressed: _selectedRevision == null
                              ? null
                              : _showDeleteRevisionDialog,
                        ),
                      ],
                      secondaryItems: [
                        // ── SECUNDARIOS: se colapsan en el menú "..." ───────
                        CommandBarButton(
                          icon: Icon(FluentIcons.excel_document, color: Colors.green),
                          label: const Text("Exportar BOM"),
                          onPressed: _selectedRevision == null ? null : _exportarExcel,
                        ),
                        CommandBarButton(
                          icon: Icon(FluentIcons.car, color: Colors.blue),
                          label: const Text("Gestionar VINs"),
                          onPressed: _selectedRevision == null
                              ? null
                              : _showVINManagementDialog,
                        ),
                        const CommandBarSeparator(),
                        CommandBarButton(
                          icon: const Icon(FluentIcons.download),
                          label: const Text("Importar Excel"),
                          onPressed: (_selectedRevision == null ||
                                  _selectedRevision['estado'] == 'Aprobada')
                              ? null
                              : _importarExcel,
                        ),
                        CommandBarButton(
                          icon: const Icon(FluentIcons.copy),
                          label: const Text("Clonar BOM"),
                          onPressed: (_selectedRevision == null ||
                                  _selectedRevision['estado'] == 'Aprobada')
                              ? null
                              : _showClonarDialog,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (_isLoading) const ProgressBar(),
            const SizedBox(height: 8),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Left Panel: TreeView (Flex 3)
                  Expanded(
                    flex: 3,
                    child: Card(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text("ENSAMBLES", style: TextStyle(fontWeight: FontWeight.bold)),
                              Tooltip(
                                message: "Agregar Estación",
                                child: IconButton(
                                  icon: const Icon(FluentIcons.add),
                                  onPressed: () => _showAddDialog("Nueva Estación", _addEstacion),
                                ),
                              )
                            ],
                          ),
                          const Divider(),
                          Expanded(
                            child: _arbol.isEmpty
                                ? Center(child: Text("Sin estaciones", style: TextStyle(color: Colors.grey)))
                                : TreeView(
                                    items: _buildTreeItems(),
                                    selectionMode: TreeViewSelectionMode.single,
                                    onItemInvoked: (item, reason) async {},
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  
                  // Right Panel: Table (Flex 7)
                  Expanded(
                    flex: 7,
                    child: Container(
                      decoration: BoxDecoration(
                        color: FluentTheme.of(context).cardColor,
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.04),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                        border: Border.all(color: Colors.grey.withOpacity(0.2)),
                      ),
                      child: _isLoading && _selectedEnsamble == null
                          ? const Center(child: ProgressRing())
                          : LayoutBuilder(
                              builder: (context, constraints) {
                                // BUGFIX OVERFLOW: _buildPiezasTable usa Expanded internamente,
                                // necesita un padre con altura definida.
                                return SizedBox(
                                  height: constraints.maxHeight,
                                  child: Padding(
                                    padding: const EdgeInsets.all(12.0),
                                    child: _buildPiezasTable(),
                                  ),
                                );
                              },
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
