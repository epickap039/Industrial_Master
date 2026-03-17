import 'package:fluent_ui/fluent_ui.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_file/open_file.dart';
import 'package:shared_preferences/shared_preferences.dart'; // === TAREA 2: Para rastreo de usuario ===
import 'dart:io';

const String API_URL = "http://192.168.1.73:8001";

class BOMManagerScreen extends StatefulWidget {
  final int? idCliente;
  final String? clientName;
  // v60.0: nuevos parámetros de ingeniería maestra
  final int? idVersion;
  final String? versionName;
  final String? tractoName;
  final int? targetRevisionId;

  const BOMManagerScreen({
    Key? key,
    this.idCliente,
    this.clientName,
    this.idVersion,
    this.versionName,
    this.tractoName,
    this.targetRevisionId,
  }) : super(key: key);

  @override
  _BOMManagerScreenState createState() => _BOMManagerScreenState();
}

class _BOMManagerScreenState extends State<BOMManagerScreen> {
  bool _isLoading = false;

  int? _currentIdCliente;
  String _currentClientName = '';

  List<dynamic> _arbol = [];
  dynamic _selectedEnsamble;
  List<dynamic> _revisiones = [];
  dynamic _selectedRevision;
  List<dynamic> _vins = [];
  bool _propagarAutomaticamente = false;

  // Vista Plana Excel
  List<dynamic> _bomPlana = [];
  bool _vistaPlana = false;

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
  void didUpdateWidget(BOMManagerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.targetRevisionId != oldWidget.targetRevisionId &&
        widget.targetRevisionId != null) {
      if (_revisiones.isNotEmpty) {
        final rev = _revisiones.firstWhere(
          (r) => r['id_revision'] == widget.targetRevisionId,
          orElse: () => null,
        );
        if (rev != null) {
          setState(() {
            _selectedRevision = rev;
          });
          _fetchArbol();
        }
      }
    }
  }

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
      _bomPlana = [];
    });
  }

  Future<void> _fetchRevisiones() async {
    setState(() => _isLoading = true);
    try {
      // v60.0: usa endpoint por version si está disponible
      final url =
          _usingVersionMode
              ? '$API_URL/api/bom/revisiones/version/$_masterId'
              : '$API_URL/api/bom/revisiones/$_masterId';
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        _clearData();
        setState(() {
          _revisiones = json.decode(response.body);
          if (_revisiones.isNotEmpty) {
            if (widget.targetRevisionId != null) {
              _selectedRevision = _revisiones.firstWhere(
                (r) => r['id_revision'] == widget.targetRevisionId,
                orElse: () => _revisiones.last,
              );
            } else {
              _selectedRevision = _revisiones.last;
            }
            _fetchArbol();
            if (_vistaPlana) _fetchBomPlana();
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
      final url =
          _usingVersionMode
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
        Uri.parse(
          '$API_URL/api/bom/revisiones/${_selectedRevision['id_revision']}/aprobar',
        ),
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
      final response = await http.get(
        Uri.parse('$API_URL/api/bom/arbol/${_selectedRevision['id_revision']}'),
      );
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

  Future<void> _fetchBomPlana() async {
    if (_selectedRevision == null) return;
    setState(() => _isLoading = true);
    try {
      final response = await http.get(
        Uri.parse(
          '$API_URL/api/bom/plana/${_selectedRevision['id_revision']}',
        ),
      );
      if (response.statusCode == 200) {
        setState(() => _bomPlana = json.decode(response.body));
      } else {
        _showError("Error al cargar vista plana: ${response.statusCode}");
      }
    } catch (e) {
      _showError("Error al cargar vista plana: $e");
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
          Uri.parse(
            '$API_URL/api/bom/importar/${_selectedRevision['id_revision']}',
          ),
        );

        request.files.add(await http.MultipartFile.fromPath('file', filePath));

        var streamedResponse = await request.send();
        var response = await http.Response.fromStream(streamedResponse);

        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          int importadas = data['insertados'] ?? 0;
          List errores = data['errores'] ?? [];

          if (errores.isEmpty) {
            _showError(
              "✅ Se cargaron $importadas piezas con éxito.",
              isError: false,
            );
          } else {
            showDialog(
              context: context,
              builder:
                  (context) => ContentDialog(
                    title: const Text("Resumen de Importación"),
                    content: Text(
                      "Se cargaron $importadas piezas con éxito.\n\n"
                      "Los siguientes códigos no existen en el catálogo maestro y fueron omitidos:\n${errores.join(', ')}",
                    ),
                    actions: [
                      Button(
                        child: const Text('Copiar Errores'),
                        onPressed: () {
                          Clipboard.setData(
                            ClipboardData(text: errores.join(', ')),
                          );
                          _showError(
                            "Errores copiados al portapapeles",
                            isError: false,
                          );
                        },
                      ),
                      Button(
                        child: const Text('Cerrar'),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
            );
          }
          _fetchArbol();
        } else {
          final errorMsg =
              json.decode(response.body)['detail'] ??
              "Error desconocido en el servidor";
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
        body: jsonEncode({
          'id_revision': _selectedRevision['id_revision'],
          'nombre': nombre,
        }),
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
      final response = await http.delete(
        Uri.parse('$API_URL/api/bom/estaciones/$id'),
      );
      if (response.statusCode == 200) {
        if (_selectedEnsamble != null && _arbol.any((est) => est['id'] == id)) {
          _selectedEnsamble = null;
        }
        _fetchArbol();
      } else {
        final errorMsg =
            json.decode(response.body)['detail'] ?? "Error desconocido";
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
      final response = await http.delete(
        Uri.parse('$API_URL/api/bom/ensambles/$id'),
      );
      if (response.statusCode == 200) {
        if (_selectedEnsamble != null && _selectedEnsamble['id'] == id) {
          _selectedEnsamble = null;
        }
        _fetchArbol();
      } else {
        final errorMsg =
            json.decode(response.body)['detail'] ?? "Error desconocido";
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
          'observaciones': obs,
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
      final response = await http.delete(
        Uri.parse('$API_URL/api/bom/estructura/$idBom'),
      );
      if (response.statusCode == 200) {
        _fetchArbol();
      }
    } catch (e) {
      _showError("Error al eliminar la pieza: $e");
    }
  }

  Future<void> _updateCantidadPieza(
    int idBom,
    double nuevaCantidad, {
    bool propagar = false,
    String? codigo,
  }) async {
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
      final response = await http.get(
        Uri.parse(
          '$API_URL/api/bom/exportar/${_selectedRevision['id_revision']}',
        ),
      );
      if (response.statusCode == 200) {
        final directory = await getApplicationDocumentsDirectory();
        final filePath =
            '${directory.path}/BOM_Rev_${_selectedRevision['numero_revision']}.xlsx';
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
  Future<void> _deleteRevision({
    String password = '',
    String motivo = '',
  }) async {
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
        final detail =
            json.decode(response.body)['detail'] ?? 'Error desconocido';
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
      builder:
          (ctx) => StatefulBuilder(
            builder:
                (ctx, setD) => ContentDialog(
                  constraints: const BoxConstraints(
                    maxWidth: 460,
                    maxHeight: 380,
                  ),
                  title: Row(
                    children: [
                      Icon(
                        FluentIcons.delete,
                        color: isAprobada ? Colors.red : Colors.orange,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          isAprobada
                              ? "⚠️ Eliminar Revisión Aprobada"
                              : "Eliminar Revisión",
                          style: const TextStyle(fontSize: 14),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
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
                          child: Row(
                            children: [
                              Icon(
                                FluentIcons.error_badge,
                                color: Colors.red,
                                size: 18,
                              ),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  "ADVERTENCIA: Esta revisión está APROBADA. "
                                  "Eliminarla borrará permanentemente toda su ingeniería. "
                                  "Se requiere contraseña de seguridad.",
                                  style: TextStyle(
                                    color: Colors.red,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          "Contraseña de Seguridad:",
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        PasswordBox(
                          placeholder: 'Contraseña maestra...',
                          onChanged: (v) => setD(() => passwordInput = v),
                        ),
                        const SizedBox(height: 10),
                      ] else ...[
                        Text(
                          "¿Estás seguro de eliminar $revLabel?",
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          "Se borrarán todas las estaciones, ensambles y piezas de esta revisión.",
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFFF57C00),
                          ),
                        ),
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
                        _deleteRevision(
                          password: passwordInput,
                          motivo: motivoInput,
                        );
                      },
                    ),
                  ],
                ),
          ),
    );
  }

  Future<void> _clonarBOM() async {
    if (_selectedRevision == null) return;
    final int idOrigen = _selectedRevision['id_revision'];
    setState(() => _isLoading = true);
    try {
      final response = await http.post(
        Uri.parse('$API_URL/api/bom/clonar/$idOrigen'),
        headers: {'Content-Type': 'application/json'},
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final int nuevoId = data['nuevo_id_revision'];
        final int numRev = data['numero_revision'];
        final int piezas = data['piezas_clonadas'] ?? 0;
        _showError(
          "✅ BOM clonada: Rev $numRev creada con $piezas piezas.",
          isError: false,
        );
        // Re-cargar revisiones y seleccionar automáticamente la recién creada
        await _fetchRevisionesYSeleccionar(nuevoId);
      } else {
        final detail =
            json.decode(response.body)['detail'] ?? 'Error desconocido';
        _showError("Error al clonar BOM: $detail");
      }
    } catch (e) {
      _showError("Error: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  /// Recarga la lista de revisiones y selecciona la indicada por [targetId].
  Future<void> _fetchRevisionesYSeleccionar(int targetId) async {
    setState(() => _isLoading = true);
    try {
      final url = _usingVersionMode
          ? '$API_URL/api/bom/revisiones/version/$_masterId'
          : '$API_URL/api/bom/revisiones/$_masterId';
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        _clearData();
        setState(() {
          _revisiones = json.decode(response.body);
          _selectedRevision = _revisiones.firstWhere(
            (r) => r['id_revision'] == targetId,
            orElse: () =>
                _revisiones.isNotEmpty ? _revisiones.last : null,
          );
        });
        _fetchArbol();
        if (_vistaPlana) _fetchBomPlana();
      }
    } catch (e) {
      _showError("Error al recargar revisiones: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _propagarCambio(
    String codigo,
    double cantidad,
    List<int> ids,
  ) async {
    try {
      final response = await http.post(
        Uri.parse('$API_URL/api/bom/propagar'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'codigo_pieza': codigo,
          'nueva_cantidad': cantidad,
          'id_revisiones': ids,
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
        body: jsonEncode(
          {'vin': '', 'notas': notas},
        ), // vin es requerido por el modelo pero ignorado si es vacío en el update
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
      final response = await http.get(
        Uri.parse(
          '$API_URL/api/bom/revisiones/${_selectedRevision['id_revision']}/vins',
        ),
      );
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
    // === TAREA 2: Leer usuario real para el header ===
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('username') ?? 'SISTEMA_VIN';
    try {
      final response = await http.post(
        Uri.parse(
          '$API_URL/api/bom/revisiones/${_selectedRevision['id_revision']}/vins',
        ),
        headers: {
          'Content-Type': 'application/json',
          'X-Usuario': username, // === TAREA 2: header de usuario ===
        },
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
    // === TAREA 2: Leer usuario real para el header ===
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('username') ?? 'SISTEMA_VIN';
    try {
      final response = await http.delete(
        Uri.parse('$API_URL/api/bom/vins/$idUnidad'),
        headers: {
          'Content-Type': 'application/json',
          'X-Usuario': username, // === TAREA 2: header de usuario ===
        },
      );
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
    displayInfoBar(
      context,
      builder: (context, close) {
        return InfoBar(
          title: Text(isError ? 'Error' : 'Éxito'),
          content: Text(message),
          severity: isError ? InfoBarSeverity.error : InfoBarSeverity.success,
          onClose: close,
        );
      },
    );
  }

  // DIALOGOS
  void _showAddDialog(String title, Function(String) onSave) {
    String inputValue = "";
    showDialog(
      context: context,
      builder:
          (context) => ContentDialog(
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextBox(
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                  placeholder: 'Nombre...',
                  onChanged: (v) => inputValue = v,
                ),
              ],
            ),
            actions: [
              Button(
                child: const Text('Cancelar'),
                onPressed: () => Navigator.pop(context),
              ),
              FilledButton(
                child: const Text('Guardar'),
                onPressed: () {
                  if (inputValue.trim().isNotEmpty) {
                    onSave(inputValue.trim());
                    Navigator.pop(context);
                  }
                },
              ),
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
      builder:
          (context) => ContentDialog(
            title: const Text("Agregar Pieza"),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                InfoLabel(
                  label: "Código de Pieza (del Catálogo)",
                  child: TextBox(
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                    onChanged: (v) => codigoValue = v,
                  ),
                ),
                const SizedBox(height: 16),
                InfoLabel(
                  label: "Cantidad",
                  child: TextBox(
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                    keyboardType: TextInputType.number,
                    onChanged: (v) => cantStr = v,
                  ),
                ),
                const SizedBox(height: 16),
                InfoLabel(
                  label: "Observaciones",
                  child: TextBox(
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                    onChanged: (v) => obsValue = v,
                  ),
                ),
              ],
            ),
            actions: [
              Button(
                child: const Text('Cancelar'),
                onPressed: () => Navigator.pop(context),
              ),
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
              ),
            ],
          ),
    );
  }

  void _confirmDelete(String title, VoidCallback onConfirm) {
    showDialog(
      context: context,
      builder:
          (context) => ContentDialog(
            title: const Text('Eliminar'),
            content: Text(title),
            actions: [
              Button(
                child: const Text('Cancelar'),
                onPressed: () => Navigator.pop(context),
              ),
              FilledButton(
                style: ButtonStyle(
                  backgroundColor: ButtonState.all(Colors.red),
                ),
                child: const Text('Eliminar'),
                onPressed: () {
                  onConfirm();
                  Navigator.pop(context);
                },
              ),
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
      builder:
          (context) => StatefulBuilder(
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
                              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
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
                              subtitle: Text(
                                vin['notas'] ?? "Sin notas",
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
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
                                      _confirmDelete(
                                        "¿Seguro de eliminar el VIN ${vin['vin']}?",
                                        () {
                                          _deleteVIN(vin['id_unidad']).then((
                                            _,
                                          ) {
                                            setDialogState(() {});
                                          });
                                        },
                                      );
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
            },
          ),
    );
  }

  void _showNotasVINDialog(dynamic vin) {
    String notasTemp = vin['notas'] ?? "";
    showDialog(
      context: context,
      builder:
          (context) => ContentDialog(
            title: Text("Notas del VIN: ${vin['vin']}"),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextBox(
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                  controller: TextEditingController(text: notasTemp),
                  maxLines: 5,
                  placeholder: "Escribe notas aquí...",
                  onChanged: (v) => notasTemp = v,
                ),
              ],
            ),
            actions: [
              Button(
                child: const Text("Cancelar"),
                onPressed: () => Navigator.pop(context),
              ),
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

  void _showClonarDialog() {
    if (_selectedRevision == null) {
      _showError("Selecciona una revisión primero.");
      return;
    }
    final String revLabel =
        "Rev. ${_selectedRevision['numero_revision']} — ${_selectedRevision['estado']}";

    showDialog(
      context: context,
      builder: (ctx) => ContentDialog(
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 280),
        title: Row(
          children: [
            Icon(FluentIcons.copy, size: 18, color: _accentColor),
            const SizedBox(width: 8),
            const Text("Clonar Lista de Materiales"),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "¿Deseas clonar esta Lista de Materiales?",
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              "Se creará una copia exacta de $revLabel en estado Borrador, "
              "con todas sus estaciones, ensambles y piezas.",
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: _accentColor.withOpacity(0.07),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: _accentColor.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  Icon(FluentIcons.info, size: 14, color: _accentColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "La nueva revisión se seleccionará automáticamente al finalizar.",
                      style: TextStyle(fontSize: 11, color: _accentColor),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          Button(
            child: const Text("Cancelar"),
            onPressed: () => Navigator.pop(ctx),
          ),
          FilledButton(
            child: const Text("Clonar Ahora"),
            onPressed: () {
              Navigator.pop(ctx);
              _clonarBOM();
            },
          ),
        ],
      ),
    );
  }

  void _showPropagacionDialog(String codigo, double cantidad) async {
    List<int> selectedIds = [];
    List<dynamic> jerarquia = [];
    bool dialogLoading = true;

    showDialog(
      context: context,
      builder:
          (context) => StatefulBuilder(
            builder: (context, setDState) {
              if (dialogLoading) {
                http
                    .get(
                      Uri.parse(
                        '$API_URL/api/bom/buscar_pieza_jerarquia/$codigo?exclude_rev=${_selectedRevision['id_revision']}',
                      ),
                    )
                    .then((res) {
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
                constraints: const BoxConstraints(
                  maxWidth: 540,
                  maxHeight: 520,
                ),
                title: Text(
                  "Propagar cambio: $codigo",
                  overflow: TextOverflow.ellipsis,
                ),
                content: SizedBox(
                  width: 500,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Selecciona las listas donde deseas actualizar la cantidad a $cantidad:",
                      ),
                      const SizedBox(height: 12),
                      if (jerarquia.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(8.0),
                          child: Text(
                            "No se encontró esta pieza en otras revisiones.",
                          ),
                        )
                      else
                        Flexible(
                          child: ListView.builder(
                            shrinkWrap: true,
                            itemCount: jerarquia.length,
                            itemBuilder: (context, idx) {
                              final item = jerarquia[idx];
                              final clientes = (item['clientes_afectados'] ?? item['cliente'] ?? 'General').toString();
                              final label =
                                  "${item['tracto']} > ${item['tipo']} > ${item['version']}";
                              final revisionInfo =
                                  "Rev ${item['numero_revision']} - ${item['estado']}";

                              return Checkbox(
                                content: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 420,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        label,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                        maxLines: 2,
                                      ),
                                      Text(
                                        revisionInfo,
                                        style:
                                            const TextStyle(fontSize: 12),
                                        overflow: TextOverflow.ellipsis,
                                        maxLines: 1,
                                      ),
                                      if (clientes.isNotEmpty &&
                                          clientes != 'General')
                                        Row(
                                          children: [
                                            Icon(
                                              FluentIcons.people,
                                              size: 10,
                                              color: Colors.blue
                                                  .withOpacity(0.65),
                                            ),
                                            const SizedBox(width: 3),
                                            Flexible(
                                              child: Text(
                                                clientes,
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  fontStyle:
                                                      FontStyle.italic,
                                                  color: Colors.blue
                                                      .withOpacity(0.65),
                                                ),
                                                overflow:
                                                    TextOverflow.ellipsis,
                                                maxLines: 1,
                                              ),
                                            ),
                                          ],
                                        ),
                                      Text(
                                        "Cantidad actual: ${item['cantidad']}",
                                        style: TextStyle(
                                          color:
                                              Colors.blue.withOpacity(0.8),
                                          fontSize: 11,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                        maxLines: 1,
                                      ),
                                    ],
                                  ),
                                ),
                                checked: selectedIds.contains(
                                  item['id_revision'],
                                ),
                                onChanged: (v) {
                                  setDState(() {
                                    if (v == true)
                                      selectedIds.add(item['id_revision']);
                                    else
                                      selectedIds
                                          .remove(item['id_revision']);
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
                  Button(
                    child: const Text("Cancelar"),
                    onPressed: () => Navigator.pop(context),
                  ),
                  FilledButton(
                    child: Tooltip(
                      message: "Actualiza la ingeniería en todos los VINs seleccionados",
                      child: const Text("Propagar Cambios"),
                    ),
                    onPressed:
                        selectedIds.isEmpty
                            ? null
                            : () {
                              _propagarCambio(codigo, cantidad, selectedIds);
                              Navigator.pop(context);
                            },
                  ),
                ],
              );
            },
          ),
    );
  }


  List<TreeViewItem> _buildTreeItems() {
    final bool isAprobada =
        _selectedRevision != null && _selectedRevision['estado'] == 'Aprobada';

    return _arbol.map((est) {
      final List ensamblesList = est['ensambles'] as List;
      final bool hasChildren = ensamblesList.isNotEmpty;

      return TreeViewItem(
        expanded: hasChildren,
        content: Row(
          children: [
            Expanded(
              child: Text(
                est['nombre'],
                style: const TextStyle(fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (!isAprobada) ...[
              IconButton(
                icon: const Icon(FluentIcons.add),
                onPressed:
                    () => _showAddDialog(
                      "Nuevo Ensamble para ${est['nombre']}",
                      (nombre) {
                        _addEnsamble(est['id'], nombre);
                      },
                    ),
              ),
              IconButton(
                icon: const Icon(FluentIcons.delete),
                onPressed:
                    () => _confirmDelete(
                      "¿Seguro de eliminar la estación '${est['nombre']}' y todo su contenido?",
                      () {
                        _deleteEstacion(est['id']);
                      },
                    ),
              ),
            ],
          ],
        ),
        children:
            ensamblesList.map((ens) {
              final isSelected =
                  _selectedEnsamble != null &&
                  _selectedEnsamble['id'] == ens['id'];
              return TreeViewItem(
                content: GestureDetector(
                  onTap: () {
                    setState(() => _selectedEnsamble = ens);
                  },
                  child: Container(
                    color:
                        isSelected
                            ? Colors.blue.withOpacity(0.2)
                            : Colors.transparent,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            "${ens['nombre']}",
                            style: const TextStyle(fontWeight: FontWeight.w500),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (!isAprobada)
                          IconButton(
                            icon: const Icon(FluentIcons.delete),
                            onPressed:
                                () => _confirmDelete(
                                  "¿Seguro de eliminar el ensamble '${ens['nombre']}' y sus piezas?",
                                  () {
                                    _deleteEnsamble(ens['id']);
                                  },
                                ),
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
    if (_selectedRevision == null) {
      return const Center(child: Text("Selecciona una revisión primero."));
    }
    if (_selectedEnsamble == null) {
      return const Center(
        child: Text("Selecciona un ensamble para ver sus piezas."),
      );
    }

    // Snapshot inmutable para evitar RangeError si el estado cambia mid-frame
    final List<dynamic> piezas = List<dynamic>.from(
      _selectedEnsamble['piezas'] ?? [],
    );
    final bool isAprobada = _selectedRevision['estado'] == 'Aprobada';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ─── Encabezado del ensamble ───
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(
                "Piezas: ${_selectedEnsamble['nombre']}",
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (!isAprobada)
              FilledButton(
                onPressed: _showAddPiezaDialog,
                child: const Text("Agregar Pieza"),
              ),
          ],
        ),
        const SizedBox(height: 8),
        // ─── Header de columnas ───
        Container(
          padding: const EdgeInsets.symmetric(vertical: 6.0, horizontal: 12.0),
          decoration: BoxDecoration(
            color: Colors.blue.withOpacity(0.1),
            borderRadius: BorderRadius.circular(4),
          ),
          child: const Row(
            children: [
              Expanded(
                flex: 2,
                child: Text(
                  "Código",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
              Expanded(
                flex: 4,
                child: Text(
                  "Descripción Oficial",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
              Expanded(
                flex: 1,
                child: Text(
                  "Cant.",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  "Procesos",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
              Expanded(
                flex: 1,
                child: Text(
                  "Simetría",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
              Expanded(
                flex: 1,
                child: Text(
                  "Acciones",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        // ─── Lista de piezas ─── Expanded recibe constraints del Column padre
        Expanded(
          child:
              piezas.isEmpty
                  ? Center(
                    child: Text(
                      "No hay piezas en este ensamble.",
                      style: TextStyle(
                        color:
                            (FluentTheme.of(
                                  context,
                                ).typography.body?.color?.withOpacity(0.5) ??
                                Colors.grey),
                      ),
                    ),
                  )
                  : ListView.builder(
                    itemCount: piezas.length,
                    itemBuilder: (context, index) {
                      // Guardia: nunca acceder fuera de rango
                      if (index >= piezas.length)
                        return const SizedBox.shrink();
                      final pieza = piezas[index];

                      final List<String> procesos = [];
                      for (final key in [
                        'proceso_primario',
                        'proceso_1',
                        'proceso_2',
                        'proceso_3',
                      ]) {
                        final v = pieza[key]?.toString() ?? '';
                        if (v.isNotEmpty) procesos.add(v);
                      }
                      final strProcesos = procesos.join(', ');
                      final strLink = pieza['link_drive']?.toString() ?? '';
                      final hasLink = strLink.isNotEmpty && strLink != 'N/A';
                      final descripcion =
                          pieza['descripcion']?.toString() ?? '';

                      return Container(
                        padding: const EdgeInsets.symmetric(
                          vertical: 3.0,
                          horizontal: 12.0,
                        ),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color:
                                  FluentTheme.of(
                                    context,
                                  ).scaffoldBackgroundColor,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: Text(
                                pieza['codigo']?.toString() ?? '',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            Expanded(
                              flex: 4,
                              child: Tooltip(
                                message: descripcion,
                                child: Text(
                                  descripcion,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                            ),
                            Expanded(
                              flex: 1,
                              child: Row(
                                children: [
                                  Expanded(
                                    child: TextBox(
                                      controller: TextEditingController(
                                        text:
                                            pieza['cantidad']?.toString() ??
                                            '0',
                                      ),
                                      keyboardType: TextInputType.number,
                                      textInputAction: TextInputAction.done,
                                      enabled: !isAprobada,
                                      placeholder: "Cant.",
                                      onSubmitted: (value) {
                                        final cant = double.tryParse(value);
                                        if (cant != null && cant > 0) {
                                          _updateCantidadPieza(
                                            pieza['id'],
                                            cant,
                                            codigo: pieza['codigo']?.toString(),
                                          );
                                        } else {
                                          _showError(
                                            "Cantidad inválida o igual a 0",
                                          );
                                        }
                                      },
                                    ),
                                  ),
                                  if (!isAprobada)
                                    IconButton(
                                      icon: const Icon(
                                        FluentIcons.sync_occurence,
                                        size: 13,
                                      ),
                                      onPressed:
                                          () => _showPropagacionDialog(
                                            pieza['codigo']?.toString() ?? '',
                                            (pieza['cantidad'] as num)
                                                .toDouble(),
                                          ),
                                    ),
                                ],
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: Text(
                                strProcesos,
                                style: const TextStyle(fontSize: 11),
                              ),
                            ),
                            Expanded(
                              flex: 1,
                              child: Text(
                                pieza['simetria']?.toString() ?? '',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            Expanded(
                              flex: 1,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (hasLink)
                                    Tooltip(
                                      message: "Abrir Plano",
                                      child: IconButton(
                                        icon: Icon(
                                          FluentIcons.link,
                                          color: Colors.blue,
                                          size: 14,
                                        ),
                                        onPressed: () async {
                                          final uri = Uri.parse(strLink);
                                          if (await canLaunchUrl(uri))
                                            await launchUrl(uri);
                                        },
                                      ),
                                    ),
                                  if (!isAprobada)
                                    IconButton(
                                      icon: Icon(
                                        FluentIcons.delete,
                                        color: Colors.red,
                                        size: 14,
                                      ),
                                      onPressed:
                                          () => _confirmDelete(
                                            "¿Seguro de quitar la pieza ${pieza['codigo']}?",
                                            () => _deletePieza(pieza['id']),
                                          ),
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

  // === AUDITORÍA DE PLANOS DXF/PDF ===
  Future<void> _buscarPlanos() async {
    final List<String> codigos = _bomPlana
        .where((r) => (r['nivel'] as num).toInt() == 3)
        .map<String>((r) => r['codigo_pieza']?.toString() ?? '')
        .where((c) => c.isNotEmpty)
        .toSet()
        .toList();

    if (codigos.isEmpty) {
      _showError("No hay piezas (Nivel 3) en la Vista Plana para auditar.");
      return;
    }

    setState(() => _isLoading = true);
    try {
      final response = await http.post(
        Uri.parse('$API_URL/api/bom/buscar_planos'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'codigos': codigos}),
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        _showAuditoriaPlanosDialog(data);
      } else {
        _showError("Error al buscar planos: ${response.statusCode}");
      }
    } catch (e) {
      _showError("Error de conexión: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _showAuditoriaPlanosDialog(Map<String, dynamic> data) {
    final List encontrados = data['encontrados'] as List? ?? [];
    final List faltantes = data['faltantes'] as List? ?? [];
    final bool isDark =
        MediaQuery.of(context).platformBrightness == Brightness.dark;
    final Color textColor = isDark ? Colors.white : Colors.black;

    showDialog(
      context: context,
      builder: (ctx) => ContentDialog(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 600),
        title: Row(
          children: [
            Icon(FluentIcons.document_search, size: 18, color: _accentColor),
            const SizedBox(width: 8),
            const Text("Auditoría de Planos DXF / PDF"),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Resumen
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: _accentColor.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _auditChip(
                      "${encontrados.length}",
                      "Encontrados",
                      const Color(0xFF2E7D32),
                      isDark,
                    ),
                    _auditChip(
                      "${faltantes.length}",
                      "Faltantes",
                      Colors.red,
                      isDark,
                    ),
                    _auditChip(
                      "${encontrados.length + faltantes.length}",
                      "Total",
                      _accentColor,
                      isDark,
                    ),
                  ],
                ),
              ),
              if (encontrados.isNotEmpty) ...[
                const SizedBox(height: 14),
                Row(
                  children: [
                    const Icon(FluentIcons.check_mark, size: 14,
                        color: Color(0xFF2E7D32)),
                    const SizedBox(width: 6),
                    Text("ENCONTRADOS (${encontrados.length})",
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                            color: Color(0xFF2E7D32))),
                  ],
                ),
                const SizedBox(height: 4),
                ...encontrados.map((e) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          const SizedBox(width: 20),
                          Expanded(
                            flex: 2,
                            child: Text(
                              e['codigo']?.toString() ?? '',
                              style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12,
                                  color: textColor),
                            ),
                          ),
                          Expanded(
                            flex: 3,
                            child: Text(
                              e['archivo']?.toString() ?? '',
                              style: const TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF388E3C)),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    )),
              ],
              if (faltantes.isNotEmpty) ...[
                const SizedBox(height: 14),
                Row(
                  children: [
                    Icon(FluentIcons.error_badge, size: 14, color: Colors.red),
                    const SizedBox(width: 6),
                    Text("FALTANTES (${faltantes.length})",
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                            color: Colors.red)),
                  ],
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: faltantes
                      .map((c) => Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: Colors.red.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                  color: Colors.red.withOpacity(0.4)),
                            ),
                            child: Text(
                              c.toString(),
                              style: TextStyle(
                                  fontSize: 11,
                                  color: isDark
                                      ? Colors.red.lighter
                                      : Colors.red.darker,
                                  fontWeight: FontWeight.w600),
                            ),
                          ))
                      .toList(),
                ),
              ],
            ],
          ),
        ),
        actions: [
          Button(
            child: const Text("Cerrar"),
            onPressed: () => Navigator.pop(ctx),
          ),
        ],
      ),
    );
  }

  Widget _auditChip(String valor, String label, Color color, bool isDark) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          valor,
          style: TextStyle(
              fontSize: 22, fontWeight: FontWeight.bold, color: color),
        ),
        Text(
          label,
          style: TextStyle(
              fontSize: 11,
              color: isDark
                  ? Colors.white.withOpacity(0.7)
                  : Colors.black.withOpacity(0.55)),
        ),
      ],
    );
  }

  // === VISTA PLANA ESTILO EXCEL ===
  Widget _buildVistaPlanaExcel() {
    final bool isDark =
        MediaQuery.of(context).platformBrightness == Brightness.dark;
    final Color textColor = isDark ? Colors.white : Colors.black;
    final Color rowEven =
        isDark ? const Color(0xFF242424) : Colors.white;
    final Color rowOdd =
        isDark ? const Color(0xFF2E2E2E) : const Color(0xFFF3F6FA);
    final Color hdBg = _accentColor;
    final Color borderColor =
        isDark ? const Color(0xFF3C3C3C) : const Color(0xFFDDE1E6);
    final Color lvl1Color = _accentColor;
    final Color lvl2Color =
        isDark ? const Color(0xFF90CAF9) : const Color(0xFF0D47A1);

    const double wNivel = 80.0;
    const double wCodigo = 210.0;
    const double wDesc = 340.0;
    const double wCant = 80.0;
    const double wMat = 170.0;
    const double totalWidth = wNivel + wCodigo + wDesc + wCant + wMat;

    Widget headerCell(String label, double w) {
      return Container(
        width: w,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: hdBg,
          border: Border(
            right: BorderSide(
              color: Colors.white.withOpacity(0.25),
              width: 0.5,
            ),
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 11,
            letterSpacing: 0.4,
          ),
        ),
      );
    }

    Widget dataCell(
      String text,
      double w, {
      bool isNumber = false,
      Color? colorOverride,
      FontWeight fontWeight = FontWeight.normal,
      bool tooltip = false,
    }) {
      final txt = Text(
        text,
        style: TextStyle(
          color: colorOverride ?? textColor,
          fontSize: 12,
          fontWeight: fontWeight,
        ),
        textAlign: isNumber ? TextAlign.center : TextAlign.start,
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
      );
      return Container(
        width: w,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          border: Border(
            right: BorderSide(color: borderColor, width: 0.5),
          ),
        ),
        child: tooltip && text.length > 35
            ? Tooltip(message: text, child: txt)
            : txt,
      );
    }

    if (_isLoading && _bomPlana.isEmpty) {
      return const Center(child: ProgressRing());
    }

    if (_bomPlana.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(FluentIcons.table, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            Text(
              _selectedRevision == null
                  ? "Selecciona una revisión para ver la Vista Plana."
                  : "No hay datos para mostrar en esta revisión.",
              style: TextStyle(color: textColor, fontSize: 13),
            ),
          ],
        ),
      );
    }

    final int totalPiezas =
        _bomPlana.where((r) => (r['nivel'] as num).toInt() == 3).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ─── Título compacto + botón auditoría ───
        Padding(
          padding: const EdgeInsets.only(bottom: 8.0),
          child: Row(
            children: [
              Icon(FluentIcons.table, size: 14, color: _accentColor),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  "Vista Plana — Rev. ${_selectedRevision?['numero_revision'] ?? '-'}"
                  "  ·  $totalPiezas piezas",
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: textColor,
                  ),
                ),
              ),
              Tooltip(
                message: "Verifica si existen planos DXF/PDF para cada pieza",
                child: Button(
                  onPressed: _isLoading ? null : _buscarPlanos,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(FluentIcons.document_search,
                          size: 13, color: _accentColor),
                      const SizedBox(width: 5),
                      const Text("Auditar Planos",
                          style: TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        // ─── Tabla con doble scroll ───
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: totalWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header fijo
                  Container(
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(color: borderColor, width: 1.5),
                      ),
                    ),
                    child: Row(
                      children: [
                        headerCell("Nivel", wNivel),
                        headerCell("Código", wCodigo),
                        headerCell("Descripción", wDesc),
                        headerCell("Cantidad", wCant),
                        headerCell("Material", wMat),
                      ],
                    ),
                  ),
                  // Filas virtualizadas
                  Expanded(
                    child: ListView.builder(
                      itemCount: _bomPlana.length,
                      itemBuilder: (context, index) {
                        final row = _bomPlana[index];
                        final int nivel = (row['nivel'] as num).toInt();
                        final bool isOdd = index.isOdd;

                        Color? rowTextOverride;
                        FontWeight fw = FontWeight.normal;
                        String nivelLabel;

                        if (nivel == 1) {
                          rowTextOverride = lvl1Color;
                          fw = FontWeight.bold;
                          nivelLabel = "▶ EST";
                        } else if (nivel == 2) {
                          rowTextOverride = lvl2Color;
                          fw = FontWeight.w600;
                          nivelLabel = "  ▸ ENS";
                        } else {
                          nivelLabel = "      PIE";
                        }

                        final cantStr = row['cantidad'] != null
                            ? (row['cantidad'] as num)
                                .toStringAsFixed(2)
                                .replaceAll(RegExp(r'\.?0+$'), '')
                            : '';

                        return Container(
                          decoration: BoxDecoration(
                            color: isOdd ? rowOdd : rowEven,
                            border: Border(
                              bottom: BorderSide(
                                color: borderColor,
                                width: 0.5,
                              ),
                            ),
                          ),
                          child: Row(
                            children: [
                              dataCell(
                                nivelLabel,
                                wNivel,
                                isNumber: true,
                                colorOverride: rowTextOverride,
                                fontWeight: fw,
                              ),
                              dataCell(
                                row['codigo_pieza']?.toString() ?? '',
                                wCodigo,
                                colorOverride: rowTextOverride,
                                fontWeight: fw,
                              ),
                              dataCell(
                                row['descripcion']?.toString() ?? '',
                                wDesc,
                                tooltip: true,
                              ),
                              dataCell(cantStr, wCant, isNumber: true),
                              dataCell(
                                row['material']?.toString() ?? '',
                                wMat,
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
    // Snapshot inmutable: evita RangeError si _revisiones cambia mid-frame
    final List<dynamic> snap = List<dynamic>.from(_revisiones);
    if (snap.isEmpty) return const SizedBox.shrink();

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: List.generate(snap.length * 2 - 1, (i) {
          if (i.isOdd) {
            return Container(
              width: 24,
              height: 2,
              color: Colors.grey.withOpacity(0.4),
            );
          }
          final idx = i ~/ 2;
          if (idx >= snap.length) return const SizedBox.shrink();
          final rev = snap[idx];
          final isSelected =
              _selectedRevision != null &&
              _selectedRevision['id_revision'] == rev['id_revision'];
          final isAprobada = rev['estado'] == 'Aprobada';
          final stepColor =
              isAprobada ? const Color(0xFF2E7D32) : const Color(0xFFF9A825);

          return Tooltip(
            message:
                "Rev ${rev['numero_revision']} - ${rev['estado']} (click para seleccionar)",
            child: GestureDetector(
              onTap: () {
                _clearData();
                setState(() => _selectedRevision = rev);
                _fetchArbol();
                _fetchVINs();
                if (_vistaPlana) _fetchBomPlana();
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: isSelected ? stepColor : stepColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: stepColor,
                    width: isSelected ? 2.5 : 1,
                  ),
                  boxShadow:
                      isSelected
                          ? [
                            BoxShadow(
                              color: stepColor.withOpacity(0.4),
                              blurRadius: 6,
                            ),
                          ]
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
                        fontWeight:
                            isSelected ? FontWeight.bold : FontWeight.normal,
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
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Gestor de Listas (BOM)'),
            if ((_selectedRevision?['clientes_afectados'] ?? '').toString().trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      FluentIcons.people,
                      size: 11,
                      color: Colors.blue.withOpacity(0.65),
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        'Aplica para: ${_selectedRevision!['clientes_afectados']}',
                        style: TextStyle(
                          fontSize: 12,
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
      // LayoutBuilder garantiza constraints reales antes del Column
      content: LayoutBuilder(
        builder: (context, constraints) {
          return SizedBox(
            width: constraints.maxWidth,
            height:
                constraints.maxHeight.isInfinite ? 600 : constraints.maxHeight,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ─── Barra superior: Stepper + CommandBar ───────────────
                  Container(
                    decoration: BoxDecoration(
                      color: _accentColor.withOpacity(0.06),
                      border: Border(
                        bottom: BorderSide(
                          color: _accentColor.withOpacity(0.2),
                          width: 1.5,
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 4,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12.0,
                              vertical: 6.0,
                            ),
                            child: _buildRevisionStepper(),
                          ),
                        ),
                        Container(
                          width: 1,
                          height: 24,
                          color: Colors.grey.withOpacity(0.2),
                        ),
                        Expanded(
                          child: CommandBar(
                            overflowBehavior:
                                CommandBarOverflowBehavior.dynamicOverflow,
                            primaryItems: [
                              CommandBarButton(
                                icon: const Icon(FluentIcons.add),
                                label: const Text("Nueva Rev."),
                                onPressed:
                                    () => _showAddDialog(
                                      "Nueva Revisión",
                                      _addRevision,
                                    ),
                              ),
                              if (_selectedRevision != null &&
                                  _selectedRevision['estado'] != 'Aprobada')
                                CommandBarButton(
                                  icon: Icon(
                                    FluentIcons.lock,
                                    color: Colors.green,
                                  ),
                                  label: const Text("Aprobar"),
                                  onPressed: _aprobarRevision,
                                ),
                              CommandBarButton(
                                icon: Icon(
                                  FluentIcons.delete,
                                  color:
                                      _selectedRevision?['estado'] == 'Aprobada'
                                          ? Colors.red
                                          : Colors.orange,
                                ),
                                label: const Text("Eliminar"),
                                onPressed:
                                    _selectedRevision == null
                                        ? null
                                        : _showDeleteRevisionDialog,
                              ),
                              CommandBarButton(
                                icon: Icon(
                                  _vistaPlana
                                      ? FluentIcons.check_list
                                      : FluentIcons.table,
                                  color:
                                      _vistaPlana
                                          ? _accentColor
                                          : const Color(0xFF757575),
                                ),
                                label: Text(
                                  _vistaPlana ? "Vista Árbol" : "Vista Plana",
                                ),
                                onPressed:
                                    _selectedRevision == null
                                        ? null
                                        : () {
                                          final entering = !_vistaPlana;
                                          setState(
                                            () => _vistaPlana = entering,
                                          );
                                          if (entering) _fetchBomPlana();
                                        },
                              ),
                            ],
                            secondaryItems: [
                              CommandBarButton(
                                icon: Icon(
                                  FluentIcons.excel_document,
                                  color: Colors.green,
                                ),
                                label: const Text("Exportar BOM"),
                                onPressed:
                                    _selectedRevision == null
                                        ? null
                                        : _exportarExcel,
                              ),
                              CommandBarButton(
                                icon: Icon(FluentIcons.car, color: Colors.blue),
                                label: Tooltip(
                                  message: "Administra las unidades físicas ligadas a esta revisión",
                                  child: const Text("Gestionar VINs"),
                                ),
                                onPressed:
                                    _selectedRevision == null
                                        ? null
                                        : _showVINManagementDialog,
                              ),
                              const CommandBarSeparator(),
                              CommandBarButton(
                                icon: const Icon(FluentIcons.download),
                                label: const Text("Importar Excel"),
                                onPressed:
                                    (_selectedRevision == null ||
                                            _selectedRevision['estado'] ==
                                                'Aprobada')
                                        ? null
                                        : _importarExcel,
                              ),
                              CommandBarButton(
                                icon: const Icon(FluentIcons.copy),
                                label: const Text("Clonar BOM"),
                                onPressed:
                                    (_selectedRevision == null ||
                                            _selectedRevision['estado'] ==
                                                'Aprobada')
                                        ? null
                                        : _showClonarDialog,
                              ),
                              const CommandBarSeparator(),
                              CommandBarButton(
                                icon: Icon(
                                  FluentIcons.search,
                                  color: _accentColor,
                                ),
                                label: const Text("Auditar Planos (Radar)"),
                                onPressed:
                                    (_selectedRevision == null || _isLoading)
                                        ? null
                                        : _buscarPlanos,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_isLoading) const ProgressBar(),
                  const SizedBox(height: 8),
                  // ─── ZONA PRINCIPAL: ocupa todo el espacio restante ─────
                  Expanded(
                    child: _vistaPlana
                        ? Card(
                            padding: const EdgeInsets.all(12),
                            child: _buildVistaPlanaExcel(),
                          )
                        : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Panel izquierdo: TreeView de ensambles
                        SizedBox(
                          width: 280,
                          child: Card(
                            padding: const EdgeInsets.all(8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Text(
                                      "ENSAMBLES",
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                    ),
                                    Tooltip(
                                      message: "Agregar Estación",
                                      child: IconButton(
                                        icon: const Icon(
                                          FluentIcons.add,
                                          size: 14,
                                        ),
                                        onPressed:
                                            () => _showAddDialog(
                                              "Nueva Estación",
                                              _addEstacion,
                                            ),
                                      ),
                                    ),
                                  ],
                                ),
                                const Divider(),
                                Expanded(
                                  child:
                                      _arbol.isEmpty
                                          ? Center(
                                            child: Text(
                                              "Sin estaciones",
                                              style: TextStyle(
                                                color:
                                                    (FluentTheme.of(context)
                                                            .typography
                                                            .body
                                                            ?.color
                                                            ?.withOpacity(
                                                              0.5,
                                                            ) ??
                                                        Colors.grey),
                                                fontSize: 12,
                                              ),
                                            ),
                                          )
                                          : TreeView(
                                            items: _buildTreeItems(),
                                            selectionMode:
                                                TreeViewSelectionMode.single,
                                            onItemInvoked:
                                                (item, reason) async {},
                                          ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Panel derecho: tabla de piezas — Expanded recibe
                        // constraints exactos del Row padre
                        Expanded(
                          child: Card(
                            padding: const EdgeInsets.all(12),
                            child:
                                _isLoading && _selectedEnsamble == null
                                    ? const Center(child: ProgressRing())
                                    : _buildPiezasTable(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
