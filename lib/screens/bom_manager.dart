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

import '../config/app_config.dart';

const String API_URL = kApiBaseUrl;

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

  // Vista Plana Excel
  List<dynamic> _bomPlana = [];
  bool _vistaPlana = false;

  // Estado de guardado (indicador de cambios pendientes)
  bool _hasPendingChanges = false;
  DateTime? _lastSavedAt;

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

  // ── Estado de edición PLM ──────────────────────────────────────────────────
  /// Editable sólo en estado Borrador (≡ PENDIENTE en terminología PLM)
  bool get _esEditable =>
      _selectedRevision != null &&
      (_selectedRevision!['estado'] == 'Borrador' ||
          _selectedRevision!['estado'] == 'PENDIENTE');

  bool get _esAprobada =>
      _selectedRevision != null &&
      _selectedRevision!['estado'] == 'Aprobada';

  bool get _esObsoleta =>
      _selectedRevision != null &&
      _selectedRevision!['estado'] == 'OBSOLETO';

  // ── Botón ECR inteligente (CommandBarItem, no Widget) ─────────────────────
  CommandBarButton get _ecrCommandBarItem {
    final bool hasBorrador = _revisiones.any(
      (r) => r['estado'] == 'Borrador' || r['estado'] == 'PENDIENTE',
    );
    final bool hasAprobada =
        _revisiones.any((r) => r['estado'] == 'Aprobada');

    if (_revisiones.isEmpty) {
      return CommandBarButton(
        icon: Icon(FluentIcons.add, color: _accentColor),
        label: const Text('Crear Ingeniería (Rev 0)'),
        onPressed: () => _addRevision(''),
      );
    }
    if (hasBorrador) {
      return CommandBarButton(
        icon: const Icon(FluentIcons.edit, color: Color(0xFFBDBDBD)),
        label: const Text('Edición en curso...'),
        onPressed: null,
      );
    }
    if (hasAprobada) {
      return CommandBarButton(
        icon: Icon(FluentIcons.build_definition, color: _accentColor),
        label: const Text('Iniciar Cambio ECR'),
        onPressed: () {
          if (!_esAprobada) {
            final approved = _revisiones.firstWhere(
              (r) => r['estado'] == 'Aprobada',
              orElse: () => null,
            );
            if (approved != null) {
              setState(() {
                _selectedRevision = approved;
                _arbol            = [];
                _selectedEnsamble = null;
                _vins             = [];
                _bomPlana         = [];
              });
              _fetchArbol();
              _fetchVINs();
            }
          }
          _showBranchingDialog();
        },
      );
    }
    // Solo OBSOLETO: permitir crear nueva base
    return CommandBarButton(
      icon: Icon(FluentIcons.add, color: _accentColor),
      label: const Text('Crear Ingeniería (Rev 0)'),
      onPressed: () => _addRevision(''),
    );
  }

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
    if (!mounted) return;
    setState(() => _isLoading = true);
    try {
      // v60.0: usa endpoint por version si está disponible
      final url =
          _usingVersionMode
              ? '$API_URL/api/bom/revisiones/version/$_masterId'
              : '$API_URL/api/bom/revisiones/$_masterId';
      final response = await http.get(Uri.parse(url));
      if (!mounted) return;
      if (response.statusCode == 200) {
        final List<dynamic> lista = json.decode(response.body);
        _clearData();
        // Determinar qué revisión seleccionar — FUERA del setState para
        // no llamar _fetchArbol() ni _fetchBomPlana() dentro del callback.
        dynamic nuevaSeleccion;
        if (lista.isNotEmpty) {
          if (widget.targetRevisionId != null) {
            nuevaSeleccion = lista.firstWhere(
              (r) => r['id_revision'] == widget.targetRevisionId,
              orElse: () => lista.last,
            );
          } else if (_selectedRevision != null) {
            // Intentar mantener la revisión actualmente seleccionada;
            // si ya no existe (fue borrada) caer al último elemento.
            nuevaSeleccion = lista.firstWhere(
              (r) => r['id_revision'] == _selectedRevision!['id_revision'],
              orElse: () => lista.last,
            );
          } else {
            nuevaSeleccion = lista.last;
          }
        }
        if (!mounted) return;
        setState(() {
          _revisiones = lista;
          _selectedRevision = nuevaSeleccion; // null si lista vacía
        });
        // Disparar carga del árbol FUERA del setState — evita RangeError
        // por reconstrucción del widget tree con datos a medio actualizar.
        if (nuevaSeleccion != null) {
          _fetchArbol();
          if (_vistaPlana) _fetchBomPlana();
        }
      }
    } catch (e) {
      if (mounted) _showError("Error al cargar revisiones: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Crea una nueva revisión. El nombre "Revisión N" se genera en el backend.
  /// [notas] es texto libre opcional que se registra en el log de auditoría.
  Future<void> _addRevision(String notas) async {
    final bool hasBorrador = _revisiones.any((r) => r['estado'] == 'Borrador' || r['estado'] == 'PENDIENTE');
    if (hasBorrador) {
       _showError('Ya existe una revisión activa. No se puede crear una base nueva.');
       return;
    }

    setState(() => _isLoading = true);
    try {
      final url =
          _usingVersionMode
              ? '$API_URL/api/bom/revisiones/version/$_masterId'
              : '$API_URL/api/bom/revisiones/$_masterId';
      final response = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json', 'X-Usuario': 'Admin PLM'},
        body: jsonEncode({'notas': notas.isEmpty ? null : notas}),
      );
      if (response.statusCode == 200) {
        await _fetchRevisiones();
      } else {
        _showError("Error al crear revisión: ${response.statusCode}");
      }
    } catch (e) {
      _showError("Error: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showNewRevisionDialog() {
    String notasValue = '';
    showDialog(
      context: context,
      builder: (ctx) => ContentDialog(
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 300),
        title: Row(
          children: [
            Icon(FluentIcons.add, size: 16, color: _accentColor),
            const SizedBox(width: 8),
            const Text('Nueva Revisión de Ingeniería',
                style: TextStyle(fontSize: 14)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: _accentColor.withOpacity(0.07),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: _accentColor.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  Icon(FluentIcons.info, size: 13, color: _accentColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'El nombre se generará automáticamente como "Revisión N".',
                      style: TextStyle(fontSize: 11, color: _accentColor),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            InfoLabel(
              label: 'Anotaciones / Notas  (opcional)',
              child: TextBox(
                padding: const EdgeInsets.symmetric(
                    vertical: 10, horizontal: 12),
                placeholder:
                    'Ej: Cambios en bastidor trasero, revisión por ECR-042...',
                maxLines: 3,
                onChanged: (v) => notasValue = v,
              ),
            ),
          ],
        ),
        actions: [
          Button(
            child: const Text('Cancelar'),
            onPressed: () => Navigator.pop(ctx),
          ),
          FilledButton(
            child: const Text('Crear Revisión'),
            onPressed: () {
              Navigator.pop(ctx);
              _addRevision(notasValue.trim());
            },
          ),
        ],
      ),
    );
  }

  /// Abre el Auditor de Cambios (diff estilo Git) antes de aprobar la revisión.
  void _showAprobarConfirmDialog() {
    if (_selectedRevision == null) return;
    final int idRev = _selectedRevision!['id_revision'] as int;
    final String revNum =
        (_selectedRevision!['numero_revision'] ?? '-').toString();
    showDialog(
      context: context,
      builder: (ctx) => _DiffAuditorDialog(
        idRevision: idRev,
        revNum: revNum,
        accentColor: _accentColor,
        onConfirm: () {
          Navigator.pop(ctx);
          _aprobarRevision();
        },
      ),
    );
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
          _hasPendingChanges = false;
          _lastSavedAt = DateTime.now();
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
        setState(() {
          _bomPlana = json.decode(response.body);
          _hasPendingChanges = false;
          _lastSavedAt = DateTime.now();
        });
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
        headers: {'Content-Type': 'application/json', 'X-Usuario': 'Admin PLM'},
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
        headers: {'Content-Type': 'application/json', 'X-Usuario': 'Admin PLM'},
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
        headers: {'Content-Type': 'application/json', 'X-Usuario': 'Admin PLM'},
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
        if (_vistaPlana) {
          _fetchBomPlana();
        } else {
          _fetchArbol();
        }
      }
    } catch (e) {
      _showError("Error al eliminar la pieza: $e");
    }
  }

  Future<void> _updateCantidadPieza(int idBom, double nuevaCantidad) async {
    // Guard: nunca enviar si la revisión activa no es editable.
    // Previene 404/403 cuando el usuario interactúa con IDs de un clon previo.
    if (!_esEditable) {
      _showError(
        'No se puede editar una ingeniería bloqueada. Inicia un cambio ECR.',
      );
      return;
    }
    if (mounted) setState(() => _hasPendingChanges = true);
    try {
      final response = await http.put(
        Uri.parse('$API_URL/api/bom/estructura/cantidad/$idBom'),
        headers: {'Content-Type': 'application/json', 'X-Usuario': 'Admin PLM'},
        body: jsonEncode({'cantidad': nuevaCantidad}),
      );
      if (response.statusCode == 200) {
        if (mounted) setState(() => _hasPendingChanges = false);
        _showError("✅ Cantidad actualizada correctamente", isError: false);
        if (_vistaPlana) {
          _fetchBomPlana();
        } else {
          _fetchArbol();
        }
      } else {
        final dynamic decoded = _safeDecode(response.body);
        final String detail = (decoded is Map ? decoded['detail'] : null) ??
            'Error ${response.statusCode}';
        _showError(detail);
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

  // ── Verificación de VINs antes de permitir el borrado ─────────────────────
  Future<void> _checkAndShowDeleteDialog() async {
    if (_selectedRevision == null) {
      _showError("Selecciona una revisión primero.");
      return;
    }
    // Refrescar VINs para tener datos al día antes de la comprobación.
    await _fetchVINs();
    if (!mounted) return;

    if (_vins.isNotEmpty) {
      showDialog(
        context: context,
        builder: (ctx) => ContentDialog(
          constraints: const BoxConstraints(maxWidth: 460, maxHeight: 300),
          title: Row(
            children: [
              Icon(FluentIcons.error_badge, color: Colors.red, size: 18),
              const SizedBox(width: 8),
              const Text('Borrado Bloqueado',
                  style: TextStyle(fontSize: 14)),
            ],
          ),
          content: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.red.withOpacity(0.07),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.red.withOpacity(0.35)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(FluentIcons.error_badge,
                    size: 20, color: Colors.red),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'No se puede borrar esta lista.\n\n'
                    'Tiene ${_vins.length} unidad(es) física(s) '
                    '(VINs) asignada(s). Primero desvincula las '
                    'unidades desde "Gestionar VINs" o cancélalas '
                    'en el sistema.',
                    style: const TextStyle(fontSize: 13, height: 1.5),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            FilledButton(
              child: const Text('Entendido'),
              onPressed: () => Navigator.pop(ctx),
            ),
          ],
        ),
      );
      return;
    }

    // Sin VINs asignados → mostrar diálogo de borrado normal.
    _showDeleteRevisionDialog();
  }

  // ── Admin Delete Override ───────────────────────────────────────────────────
  void _showAdminDeleteDialog() {
    final TextEditingController pwdCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => ContentDialog(
        title: const Text('Anular Bloqueo (Admin)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Esta revisión es un archivo histórico. Ingrese clave admin:', style: TextStyle(fontSize: 13)),
            const SizedBox(height: 12),
            PasswordBox(
              controller: pwdCtrl,
              placeholder: 'Contraseña maestra...',
              onSubmitted: (v) {
                if (v == 'ADMIN_ING_2024') {
                  Navigator.pop(ctx);
                  _deleteRevision(password: v, motivo: 'Forzado por Admin Override');
                } else {
                  _showError('Contraseña incorrecta');
                }
              },
            ),
          ],
        ),
        actions: [
          Button(child: const Text('Cancelar'), onPressed: () => Navigator.pop(ctx)),
          FilledButton(
            style: ButtonStyle(backgroundColor: WidgetStateProperty.all(Colors.red)),
            onPressed: () {
              if (pwdCtrl.text == 'ADMIN_ING_2024') {
                Navigator.pop(ctx);
                _deleteRevision(password: pwdCtrl.text, motivo: 'Forzado por Admin Override');
              } else {
                _showError('Contraseña incorrecta');
              }
            },
            child: const Text('Forzar Borrado', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  // ── Control de Cambios (ECR) — Gatillo de Edición ─────────────────────────
  Future<void> _showBranchingDialog() async {
    if (_selectedRevision == null) return;
    
    final bool hasBorrador = _revisiones.any((r) => r['estado'] == 'Borrador' || r['estado'] == 'PENDIENTE');
    if (hasBorrador) {
       _showError('No se puede crear otra revisión. Ya existe una en edición permanente ("Borrador" / "Pendiente"). Finalízala primero.');
       return;
    }

    final int idVersion =
        _selectedRevision!['id_version'] as int? ?? _masterId;
    final int numRev =
        (_selectedRevision!['numero_revision'] as num?)?.toInt() ?? 0;

    // Cargar clientes para poder ofrecer la opción ESPECÍFICO
    List<Map<String, dynamic>> clientes = [];
    try {
      final resp = await http.get(
          Uri.parse('$API_URL/api/proyectos/clientes/$idVersion'));
      if (resp.statusCode == 200) {
        clientes = List<Map<String, dynamic>>.from(json.decode(resp.body));
      }
    } catch (_) {}
    if (!mounted) return;

    String tipoCambio = 'GLOBAL';
    final Set<int> selectedClientes = {};

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => ContentDialog(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 560),
          title: Row(
            children: [
              Icon(FluentIcons.build_definition, size: 18, color: _accentColor),
              const SizedBox(width: 8),
              const Text('Iniciar Cambio de Ingeniería (ECR)',
                  style: TextStyle(fontSize: 14)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Rev. $numRev está APROBADA. Elige cómo aplicar el cambio:',
                style: const TextStyle(fontSize: 12, color: Color(0xFF616161)),
              ),
              const SizedBox(height: 16),
              // ── Opción GLOBAL ──────────────────────────────────────────
              RadioButton(
                checked: tipoCambio == 'GLOBAL',
                onChanged: (_) => setD(() => tipoCambio = 'GLOBAL'),
                content: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Cambio Global (Toda la Versión)',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 2),
                    Text(
                      'Crea Rev ${numRev + 1} en la misma versión para todos los '
                      'clientes vinculados. Ningún cliente es reasignado.',
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFF757575)),
                    ),
                  ],
                ),
              ),
              // ── Opción ESPECÍFICO (sólo si hay clientes) ──────────────
              if (clientes.isNotEmpty) ...[
                const SizedBox(height: 14),
                RadioButton(
                  checked: tipoCambio == 'ESPECIFICO',
                  onChanged: (_) => setD(() => tipoCambio = 'ESPECIFICO'),
                  content: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Cambio para Cliente(s) Específico(s)',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 2),
                      const Text(
                        'Crea una nueva Versión de Ingeniería y mueve los clientes '
                        'seleccionados. Los demás mantienen la ingeniería actual.',
                        style:
                            TextStyle(fontSize: 11, color: Color(0xFF757575)),
                      ),
                    ],
                  ),
                ),
                if (tipoCambio == 'ESPECIFICO') ...[
                  const SizedBox(height: 8),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 180),
                    decoration: BoxDecoration(
                      border: Border.all(color: const Color(0xFFBDBDBD)),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: ListView(
                      shrinkWrap: true,
                      children: clientes
                          .map((c) => Checkbox(
                                checked: selectedClientes
                                    .contains(c['id'] as int),
                                onChanged: (v) => setD(() {
                                  if (v == true) {
                                    selectedClientes.add(c['id'] as int);
                                  } else {
                                    selectedClientes
                                        .remove(c['id'] as int);
                                  }
                                }),
                                content: Text(c['nombre'] as String),
                              ))
                          .toList(),
                    ),
                  ),
                ],
              ],
            ],
          ),
          actions: [
            Button(
              child: const Text('Cancelar'),
              onPressed: () => Navigator.pop(ctx),
            ),
            FilledButton(
              onPressed: (tipoCambio == 'ESPECIFICO' &&
                      selectedClientes.isEmpty)
                  ? null
                  : () {
                      Navigator.pop(ctx);
                      _ejecutarBranching(
                          tipoCambio, selectedClientes.toList());
                    },
              child: const Text('Crear Rama y Editar'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _ejecutarBranching(
      String tipoCambio, List<int> listaClientes) async {
    if (_selectedRevision == null) return;

    // 1. Limpieza atómica: invalidar TODOS los datos de la revisión anterior
    //    antes de hacer cualquier llamada de red para que el árbol no muestre
    //    IDs fantasma del clon.
    if (mounted) {
      setState(() {
        _isLoading         = true;
        _arbol             = [];
        _selectedEnsamble  = null;
        _vins              = [];
        _bomPlana          = [];
      });
    }

    try {
      final response = await http.post(
        Uri.parse('$API_URL/api/bom/branching'),
        headers: {'Content-Type': 'application/json', 'X-Usuario': 'Admin PLM'},
        body: jsonEncode({
          'id_revision_origen': _selectedRevision!['id_revision'],
          'tipo_cambio': tipoCambio,
          'lista_clientes': listaClientes,
        }),
      );
      if (!mounted) return;

      if (response.statusCode == 200) {
        final data   = json.decode(response.body) as Map<String, dynamic>;
        final int nuevoId = data['nuevo_id_revision'] as int;

        if (tipoCambio == 'ESPECIFICO') {
          _showError(
            '✅ Nueva versión creada con Rev. ${data['numero_revision']}. '
            'Navega al nuevo proyecto en el menú lateral para editarla.',
            isError: false,
          );
          // Limpiar selección: ya no estamos en esa versión
          if (mounted) setState(() => _selectedRevision = null);
          await _fetchRevisiones();
        } else {
          // ── GLOBAL ──────────────────────────────────────────────────────
          // 2. Recargar lista de revisiones (incluye la nueva)
          await _fetchRevisiones();
          if (!mounted) return;

          // 3. Localizar la nueva revisión por su ID exacto (devuelto por el backend)
          final newRev = _revisiones.firstWhere(
            (r) => r['id_revision'] == nuevoId,
            orElse: () => null,
          );

          if (newRev != null && mounted) {
            // 4. Seleccionar atómicamente y borrar cualquier ensamble previo
            setState(() {
              _selectedRevision  = newRev;
              _arbol             = [];
              _selectedEnsamble  = null;
              _vins              = [];
              _bomPlana          = [];
            });

            // 5. Cargar árbol fresco — ahora con los IDs del clon
            await _fetchArbol();
            await _fetchVINs();
            if (_vistaPlana && mounted) await _fetchBomPlana();

            if (mounted) {
              _showError(
                '✅ Rev. ${data['numero_revision']} creada y lista para editar.',
                isError: false,
              );
            }
          }
        }
      } else {
        final dynamic decoded = _safeDecode(response.body);
        final detail = (decoded is Map ? decoded['detail'] : null) ??
            'Error desconocido (${response.statusCode})';
        _showError('Error al crear rama: $detail');
      }
    } catch (e) {
      if (mounted) _showError('Error de conexión durante branching: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ── NUEVO v60.1: Eliminar revisión con protección ──────────────────────────
  Future<void> _deleteRevision({
    String password = '',
    String motivo = '',
  }) async {
    if (_selectedRevision == null) return;
    final idRev = _selectedRevision['id_revision'];
    if (!mounted) return;
    setState(() => _isLoading = true);
    try {
      final response = await http.delete(
        Uri.parse('$API_URL/api/bom/revisiones/$idRev'),
        headers: {'Content-Type': 'application/json', 'X-Usuario': 'Admin PLM'},
        body: jsonEncode({'password': password, 'motivo': motivo}),
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        // 1. Limpiar TODO el estado dependiente ANTES de recargar la lista,
        //    para que el widget tree no intente renderizar un índice fantasma.
        setState(() {
          _selectedRevision = null;
          _arbol            = [];
          _selectedEnsamble = null;
          _vins             = [];
          _bomPlana         = [];
        });
        // 2. Esperar la recarga completa — _fetchRevisiones seleccionará la
        //    primera revisión disponible, o dejará _selectedRevision = null.
        await _fetchRevisiones();
        if (mounted) {
          _showError("✅ Revisión eliminada correctamente", isError: false);
        }
      } else if (response.statusCode == 401) {
        _showError("❌ Contraseña incorrecta. Operación denegada.");
      } else {
        final dynamic decoded = _safeDecode(response.body);
        final detail = (decoded is Map ? decoded['detail'] : null)
            ?? 'Error desconocido (${response.statusCode})';
        _showError("Error al eliminar: $detail");
      }
    } catch (e) {
      if (mounted) {
        _showError(
          "No se pudo eliminar la revisión. "
          "Verifica la conexión con el servidor.",
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Decodifica JSON de forma segura; retorna null en vez de lanzar excepción.
  dynamic _safeDecode(String body) {
    try {
      return json.decode(body);
    } catch (_) {
      return null;
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
        headers: {'Content-Type': 'application/json', 'X-Usuario': 'Admin PLM'},
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

  Future<void> _updateVINNotas(int idUnidad, String notas) async {
    try {
      final response = await http.put(
        Uri.parse('$API_URL/api/vins/$idUnidad/notas'),
        headers: {'Content-Type': 'application/json', 'X-Usuario': 'Admin PLM'},
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

  List<TreeViewItem> _buildTreeItems() {
    final bool isAprobada = !_esEditable;

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
    final bool isAprobada = !_esEditable;

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
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 80,
                                    ),
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
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                      ),
                                      textAlign: TextAlign.center,
                                      onSubmitted: (value) {
                                        final cant = double.tryParse(value);
                                        if (cant != null && cant > 0) {
                                          _updateCantidadPieza(
                                            pieza['id_estructura'],
                                            cant,
                                          );
                                        } else {
                                          _showError(
                                            "Cantidad inválida o igual a 0",
                                          );
                                        }
                                      },
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

  /// Palabras clave de proceso que indican piezas que NO pasan por láser/punzonadora:
  /// - SIERRACINTA: corte con sierra de cinta (perfil estructural)
  /// - RECTO: corte recto / guillotina
  /// - COMERCIAL: compra directa, no se necesita plano de fabricación
  static const List<String> _procesosExcluidos = [
    'SIERRACINTA',
    'RECTO',
    'COMERCIAL',
  ];

  /// Devuelve true si la pieza debe omitirse del auditor de planos.
  bool _esPiezaSinPlano(Map<String, dynamic> row) {
    final String procesos =
        (row['procesos'] as String? ?? '').toUpperCase();
    final String material =
        (row['material'] as String? ?? '').toUpperCase();
    final String combinado = '$procesos|$material';
    return _procesosExcluidos.any((kw) => combinado.contains(kw));
  }

  Future<void> _buscarPlanos() async {
    final List<String> codigos = _bomPlana
        .where((r) => (r['nivel'] as num).toInt() == 3)
        .where((r) => !_esPiezaSinPlano(r))   // excluir corte recto, sierra, comercial
        .map<String>((r) => r['codigo_pieza']?.toString() ?? '')
        .where((c) => c.isNotEmpty)
        .toSet()
        .toList();

    if (codigos.isEmpty) {
      _showError("No hay piezas (Nivel 3) en la Vista Plana para auditar.");
      return;
    }

    // Pedir al usuario que elija la carpeta con los planos DXF/PDF
    final String? selectedDirectory = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Selecciona la carpeta de Planos DXF/PDF',
    );
    if (selectedDirectory == null) return; // canceló el selector

    setState(() => _isLoading = true);
    try {
      final response = await http.post(
        Uri.parse('$API_URL/api/bom/buscar_planos'),
        headers: {'Content-Type': 'application/json', 'X-Usuario': 'Admin PLM'},
        body: jsonEncode({
          'codigos': codigos,
          'ruta_base': selectedDirectory,
        }),
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
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
    final String? advertencia = data['advertencia'] as String?;

    showDialog(
      context: context,
      builder: (ctx) {
        final typography = FluentTheme.of(ctx).typography;
        final Color bodyColor =
            typography.body?.color ?? Colors.black;
        final Color labelColor =
            typography.caption?.color ?? bodyColor.withOpacity(0.65);

        return ContentDialog(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
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
                // Banner de advertencia (ruta inexistente, permisos, etc.)
                if (advertencia != null) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.orange.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.orange.withOpacity(0.5)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(FluentIcons.warning,
                            size: 14, color: Colors.orange),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            advertencia,
                            style: TextStyle(
                                fontSize: 12,
                                color: Colors.orange.darker),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                // Resumen
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
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
                        labelColor,
                      ),
                      _auditChip(
                        "${faltantes.length}",
                        "Faltantes",
                        Colors.red,
                        labelColor,
                      ),
                      _auditChip(
                        "${encontrados.length + faltantes.length}",
                        "Total",
                        _accentColor,
                        labelColor,
                      ),
                    ],
                  ),
                ),
                if (encontrados.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      const Icon(FluentIcons.check_mark,
                          size: 14, color: Color(0xFF2E7D32)),
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
                                    color: bodyColor),
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
                      Icon(FluentIcons.error_badge,
                          size: 14, color: Colors.red),
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
                                    color: Colors.red.darker,
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
        );
      },
    );
  }

  Widget _auditChip(String valor, String label, Color color, Color labelColor) {
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
          style: TextStyle(fontSize: 11, color: labelColor),
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
    const double wCodigo = 180.0;
    const double wDesc = 250.0;
    const double wCant = 80.0;
    const double wMat = 140.0;
    const double wMedida = 65.0; // Largo, Ancho, Espesor
    const double wProceso = 85.0; // P. Primario, 1, 2, 3
    const double wSimetria = 80.0;
    const double totalWidth = wNivel + wCodigo + wDesc + wCant + wMat + (wMedida * 3) + (wProceso * 4) + wSimetria;

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
                        headerCell("Estación", wNivel),
                        headerCell("Código", wCodigo),
                        headerCell("Descripción", wDesc),
                        headerCell("Material", wMat),
                        headerCell("Cantidad", wCant),
                        headerCell("Largo", wMedida),
                        headerCell("Ancho", wMedida),
                        headerCell("Espesor", wMedida),
                        headerCell("Proc. P", wProceso),
                        headerCell("Proc. 1", wProceso),
                        headerCell("Proc. 2", wProceso),
                        headerCell("Proc. 3", wProceso),
                        headerCell("Simetría", wSimetria),
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
                          // Tarea 5: Mostrar Ensamble Padre o PIEZA
                          final padre = row['nom_ensamble']?.toString() ?? "PIEZA";
                          nivelLabel = "      " + (padre.length > 15 ? padre.substring(0,15) : padre);
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
                              dataCell(row['codigo_pieza']?.toString() ?? '', wCodigo, colorOverride: rowTextOverride, fontWeight: fw),
                              dataCell(row['descripcion']?.toString() ?? '', wDesc, tooltip: true),
                              dataCell(row['material']?.toString() ?? '', wMat, tooltip: true),
                              nivel == 3
                                  ? Container(
                                      width: wCant,
                                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                      decoration: BoxDecoration(border: Border(right: BorderSide(color: borderColor, width: 0.5))),
                                      child: TextBox(
                                        controller: TextEditingController(text: cantStr),
                                        keyboardType: TextInputType.number,
                                        enabled: _esEditable,
                                        textAlign: TextAlign.center,
                                        onSubmitted: (value) async {
                                          final cant = double.tryParse(value);
                                          if (cant != null && cant > 0) {
                                            final idEst = row['id_estructura'];
                                            if (idEst != null) {
                                              await _updateCantidadPieza((idEst as num).toInt(), cant);
                                            } else { _showError("Sin id_estructura"); }
                                          } else { _showError("Cantidad inválida"); }
                                        },
                                      ),
                                    )
                                  : dataCell(cantStr, wCant, isNumber: true),
                              dataCell(row['largo']?.toString() ?? '', wMedida, isNumber: true),
                              dataCell(row['ancho']?.toString() ?? '', wMedida, isNumber: true),
                              dataCell(row['espesor']?.toString() ?? '', wMedida, isNumber: true),
                              dataCell(row['proceso_primario']?.toString() ?? '', wProceso, tooltip: true),
                              dataCell(row['proceso_1']?.toString() ?? '', wProceso, tooltip: true),
                              dataCell(row['proceso_2']?.toString() ?? '', wProceso, tooltip: true),
                              dataCell(row['proceso_3']?.toString() ?? '', wProceso, tooltip: true),
                              dataCell(row['simetria']?.toString() ?? '', wSimetria, tooltip: true),
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
          final isObsoleta = rev['estado'] == 'OBSOLETO';
          final stepColor = isAprobada
              ? const Color(0xFF2E7D32)   // verde
              : isObsoleta
                  ? const Color(0xFF9E9E9E)  // gris
                  : const Color(0xFFF9A825); // amarillo (Borrador)

          return Tooltip(
            message:
                "Rev ${rev['numero_revision']} - ${rev['estado']} (click para seleccionar)",
            child: GestureDetector(
              onTap: () {
                // setState atómico: revisión + limpieza en UN solo frame.
                // Así _esEditable/_esAprobada se recalculan con el estado
                // correcto antes del primer rebuild, habilitando/deshabilitando
                // los TextBox y botones instantáneamente.
                setState(() {
                  _selectedRevision = rev;
                  _arbol            = [];
                  _selectedEnsamble = null;
                  _vins             = [];
                  _bomPlana         = [];
                });
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
                      isAprobada
                          ? FluentIcons.lock
                          : isObsoleta
                              ? FluentIcons.blocked
                              : FluentIcons.edit,
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
                  // ─── Banner: ingeniería compartida entre múltiples clientes ───
                  Builder(builder: (context) {
                    final clientes =
                        _selectedRevision?['clientes_afectados']?.toString() ??
                        '';
                    final isShared = clientes.isNotEmpty &&
                        clientes != 'Ingeniería Base (Sin clientes)';
                    if (!isShared) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8.0),
                      child: InfoBar(
                        title: const Text('Ingeniería Compartida'),
                        content: Text(
                          '⚠️ Ingeniería compartida por: $clientes. '
                          'Cambios afectan a todos los VINs vinculados.',
                        ),
                        severity: InfoBarSeverity.warning,
                      ),
                    );
                  }),
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
                        // ── Semáforo de Estado ──
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: Tooltip(
                            message: _esAprobada 
                                ? 'Revisión Aprobada - Sólo Lectura' 
                                : _esObsoleta 
                                    ? 'Archivo Histórico - Sólo Lectura' 
                                    : 'Borrador - Edición Activa',
                            child: Icon(
                              FluentIcons.circle_fill, 
                              size: 14, 
                              color: _esAprobada 
                                  ? const Color(0xFF2E7D32) 
                                  : _esObsoleta 
                                      ? const Color(0xFF9E9E9E) 
                                      : const Color(0xFFF9A825)
                            ),
                          ),
                        ),
                        Expanded(
                          child: CommandBar(
                            key: ValueKey(_selectedRevision?['id_revision'] ?? 'cmd'),
                            overflowBehavior:
                                CommandBarOverflowBehavior.dynamicOverflow,
                            primaryItems: [
                              // ── Botón ECR inteligente ──────────────────────
                              _ecrCommandBarItem,

                              // ── 💾 Guardar Cambios (solo Borrador) ─────────
                              if (_esEditable)
                                CommandBarButton(
                                  icon: Icon(
                                    FluentIcons.save,
                                    color: _hasPendingChanges
                                        ? Colors.orange
                                        : Colors.grey,
                                  ),
                                  label: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        _hasPendingChanges
                                            ? 'Cambios sin guardar'
                                            : 'Actualizado',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: _hasPendingChanges
                                              ? Colors.orange
                                              : Colors.grey,
                                          fontWeight: _hasPendingChanges
                                              ? FontWeight.bold
                                              : FontWeight.normal,
                                        ),
                                      ),
                                      if (_hasPendingChanges) ...[
                                        const SizedBox(width: 4),
                                        Container(
                                          width: 7,
                                          height: 7,
                                          decoration: BoxDecoration(
                                            color: Colors.orange,
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  onPressed: _hasPendingChanges
                                      ? () => _vistaPlana
                                          ? _fetchBomPlana()
                                          : _fetchArbol()
                                      : null,
                                ),
                              if (_esEditable)
                                CommandBarButton(
                                  icon: Icon(FluentIcons.lock,
                                      color: Colors.green),
                                  label: const Text("Aprobar"),
                                  onPressed: _showAprobarConfirmDialog,
                                ),
                              // ── Eliminar: siempre visible, admin bypass si no es borrador ──
                              if (_selectedRevision != null)
                                CommandBarButton(
                                  icon: Icon(FluentIcons.delete,
                                      color: _esEditable ? const Color(0xFFF57C00) : const Color(0xFFBDBDBD)),
                                  label: const Text("Eliminar"),
                                  onPressed: _esEditable 
                                      ? _checkAndShowDeleteDialog 
                                      : _showAdminDeleteDialog,
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
                                onPressed: (_selectedRevision == null ||
                                        !_esEditable)
                                    ? null
                                    : _importarExcel,
                              ),
                              CommandBarButton(
                                icon: const Icon(FluentIcons.copy),
                                label: const Text("Clonar BOM"),
                                onPressed: (_selectedRevision == null ||
                                        !_esEditable)
                                    ? null
                                    : _showClonarDialog,
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
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
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
                                          if (_esEditable)
                                            Tooltip(
                                              message: "Agregar Estación",
                                              child: IconButton(
                                                icon: const Icon(
                                                  FluentIcons.add,
                                                  size: 14,
                                                ),
                                                onPressed: () =>
                                                    _showAddDialog(
                                                  "Nueva Estación",
                                                  _addEstacion,
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                      const Divider(),
                                      Expanded(
                                        child: _arbol.isEmpty
                                            ? Center(
                                                child: Text(
                                                  "Sin estaciones",
                                                  style: TextStyle(
                                                    color: (FluentTheme.of(
                                                                    context)
                                                                .typography
                                                                .body
                                                                ?.color
                                                                ?.withOpacity(
                                                                    0.5) ??
                                                            Colors.grey),
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              )
                                            : TreeView(
                                                items: _buildTreeItems(),
                                                selectionMode:
                                                    TreeViewSelectionMode
                                                        .single,
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


// ════════════════════════════════════════════════════════════════════════════
// _DiffAuditorDialog — Auditor de Cambios estilo Git/Cursor
// Muestra el diff de la revisión actual vs la anterior antes de aprobar.
// Tabla color-codificada: Verde=nuevo  Rojo=eliminado  Naranja=modificado
// ════════════════════════════════════════════════════════════════════════════

class _DiffAuditorDialog extends StatefulWidget {
  final int          idRevision;
  final String       revNum;
  final Color        accentColor;
  final VoidCallback onConfirm;

  const _DiffAuditorDialog({
    required this.idRevision,
    required this.revNum,
    required this.accentColor,
    required this.onConfirm,
  });

  @override
  State<_DiffAuditorDialog> createState() => _DiffAuditorDialogState();
}

class _DiffAuditorDialogState extends State<_DiffAuditorDialog> {
  bool    _loading     = true;
  String? _error;
  List<_DiffRow> _rows = [];
  int _cntNuevos       = 0;
  int _cntEliminados   = 0;
  int _cntModificados  = 0;

  @override
  void initState() {
    super.initState();
    _loadDiff();
  }

  Future<void> _loadDiff() async {
    try {
      final respDelta = await http.get(
        Uri.parse('$API_URL/api/bom/delta/${widget.idRevision}'),
      );
      if (respDelta.statusCode != 200) {
        setState(() {
          _error   = 'Error en delta: ${respDelta.statusCode}';
          _loading = false;
        });
        return;
      }
      final delta = json.decode(respDelta.body) as Map<String, dynamic>;

      if (delta['tiene_anterior'] != true) {
        setState(() { _rows = []; _loading = false; });
        return;
      }

      final List<String> nuevos =
          List<String>.from(delta['codigos_nuevos']     as List? ?? []);
      final List<String> eliminados =
          List<String>.from(delta['codigos_eliminados'] as List? ?? []);
      final Map<String, dynamic> modificados =
          Map<String, dynamic>.from(delta['modificados'] as Map? ?? {});

      final respPlana = await http.get(
        Uri.parse('$API_URL/api/bom/plana/${widget.idRevision}'),
      );
      final Map<String, String> descMap = {};
      final Map<String, double> cantMap = {};
      if (respPlana.statusCode == 200) {
        final plana = json.decode(respPlana.body) as List<dynamic>;
        for (final row in plana) {
          if ((row['nivel'] as num).toInt() == 3) {
            final cod    = row['codigo_pieza']?.toString() ?? '';
            descMap[cod] = row['descripcion']?.toString() ?? '';
            cantMap[cod] = double.tryParse(row['cantidad']?.toString() ?? '') ?? 0.0;
          }
        }
      }

      final List<_DiffRow> rows = [];

      for (final cod in nuevos) {
        rows.add(_DiffRow(
          tipo:         _DiffTipo.agregado,
          codigo:       cod,
          descripcion:  descMap[cod] ?? '',
          cantAnterior: '',
          cantActual:   _fmt(cantMap[cod] ?? 0.0),
        ));
      }
      for (final cod in eliminados) {
        final prev = (modificados[cod]?['prev_qty'] as num?)?.toDouble() ?? 0.0;
        rows.add(_DiffRow(
          tipo:         _DiffTipo.eliminado,
          codigo:       cod,
          descripcion:  '',
          cantAnterior: _fmt(prev),
          cantActual:   '--',
        ));
      }
      for (final entry in modificados.entries) {
        final cod  = entry.key;
        final prev = double.tryParse(entry.value['prev_qty']?.toString() ?? '') ?? 0.0;
        final curr = double.tryParse(entry.value['curr_qty']?.toString() ?? '') ?? 0.0;
        if (prev == curr) continue;
        rows.add(_DiffRow(
          tipo:         _DiffTipo.modificado,
          codigo:       cod,
          descripcion:  descMap[cod] ?? '',
          cantAnterior: _fmt(prev),
          cantActual:   _fmt(curr),
        ));
      }

      rows.sort((a, b) => a.tipo.index.compareTo(b.tipo.index));

      setState(() {
        _rows           = rows;
        _cntNuevos      = rows.where((r) => r.tipo == _DiffTipo.agregado).length;
        _cntEliminados  = rows.where((r) => r.tipo == _DiffTipo.eliminado).length;
        _cntModificados = rows.where((r) => r.tipo == _DiffTipo.modificado).length;
        _loading        = false;
      });
    } catch (e) {
      setState(() { _error = 'Error: $e'; _loading = false; });
    }
  }

  String _fmt(double v) {
    if (v == v.truncateToDouble()) return v.toInt().toString();
    return v.toStringAsFixed(2).replaceAll(RegExp(r'\.?0+$'), '');
  }

  @override
  Widget build(BuildContext context) {
    final bool isDark = FluentTheme.of(context).brightness == Brightness.dark;
    final Color bg  = isDark ? const Color(0xFF1E1E2A) : Colors.white;
    final Color tx  = isDark ? const Color(0xFFE8EAED) : const Color(0xFF1A1A2E);
    final Color bdr = isDark ? const Color(0xFF3A3A4A) : const Color(0xFFDDE3EA);

    const Color clrGreen    = Color(0xFF2E7D32);
    const Color clrGreenBg  = Color(0x182E7D32);
    const Color clrRed      = Color(0xFFC62828);
    const Color clrRedBg    = Color(0x18C62828);
    const Color clrOrange   = Color(0xFFE65100);
    const Color clrOrangeBg = Color(0x18E65100);

    const double wFlag  =   5.0;
    const double wCod   = 130.0;
    const double wDesc  = 260.0;
    const double wPrev  =  90.0;
    const double wCurr  =  90.0;
    const double totalW = wFlag + wCod + wDesc + wPrev + wCurr;

    Widget hCell(String label, double w, {TextAlign align = TextAlign.left}) {
      return Container(
        width: w,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        decoration: BoxDecoration(
          color: widget.accentColor,
          border: Border(right: BorderSide(
              color: Colors.white.withOpacity(0.15), width: 0.5)),
        ),
        child: Text(label,
          style: const TextStyle(color: Colors.white,
              fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 0.3),
          textAlign: align, overflow: TextOverflow.ellipsis),
      );
    }

    Widget dCell(String text, double w,
        {Color? fg, FontWeight fw = FontWeight.normal,
         bool mono = false, TextAlign align = TextAlign.left}) {
      final txt = Text(text,
        style: TextStyle(color: fg ?? tx, fontSize: 11, fontWeight: fw,
            fontFamily: mono ? 'monospace' : null),
        textAlign: align, overflow: TextOverflow.ellipsis, maxLines: 1);
      return Container(
        width: w,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
            border: Border(right: BorderSide(color: bdr, width: 0.5))),
        child: text.length > 35 ? Tooltip(message: text, child: txt) : txt,
      );
    }

    Widget badge(String label, int count, Color color) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(0.5)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 8, height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text('$count $label',
              style: TextStyle(color: color, fontSize: 11,
                  fontWeight: FontWeight.bold)),
        ]),
      );
    }

    return ContentDialog(
      constraints: BoxConstraints(
        maxWidth:  MediaQuery.of(context).size.width  * 0.82,
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      title: Row(children: [
        Icon(FluentIcons.compare, size: 18, color: widget.accentColor),
        const SizedBox(width: 8),
        Expanded(child: Text(
          'Auditor de Cambios — Rev. ${widget.revNum}',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
          overflow: TextOverflow.ellipsis)),
        if (!_loading && _error == null) ...[
          const SizedBox(width: 8),
          badge('Nuevas',      _cntNuevos,      clrGreen),
          const SizedBox(width: 6),
          badge('Eliminadas',  _cntEliminados,  clrRed),
          const SizedBox(width: 6),
          badge('Modificadas', _cntModificados, clrOrange),
        ],
      ]),
      content: _loading
          ? const Center(child: ProgressRing())
          : _error != null
              ? Center(child: Text(_error!,
                  style: TextStyle(color: Colors.red)))
              : _rows.isEmpty
                  ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(FluentIcons.check_mark, size: 40, color: clrGreen),
                      const SizedBox(height: 12),
                      const Text('Sin diferencias detectadas.',
                          style: TextStyle(fontSize: 15,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      Text(
                        'La revisión ${widget.revNum} es idéntica a la anterior.',
                        style: const TextStyle(fontSize: 12, color: Colors.grey)),
                    ]))
                  : Container(
                      decoration: BoxDecoration(
                          border: Border.all(color: bdr),
                          borderRadius: BorderRadius.circular(6),
                          color: bg),
                      child: Column(children: [
                        Row(children: [
                          Container(width: wFlag, color: widget.accentColor),
                          hCell('Código',        wCod),
                          hCell('Descripción',   wDesc),
                          hCell('Rev. Anterior', wPrev, align: TextAlign.center),
                          hCell('Rev. Actual',   wCurr, align: TextAlign.center),
                        ]),
                        Expanded(child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            width: totalW,
                            child: ListView.builder(
                              itemCount: _rows.length,
                              itemBuilder: (ctx, i) {
                                final r = _rows[i];
                                Color rowBg, flagClr, codeFg, qtyFg;
                                String icon;
                                switch (r.tipo) {
                                  case _DiffTipo.agregado:
                                    rowBg = clrGreenBg; flagClr = clrGreen;
                                    codeFg = clrGreen; qtyFg = clrGreen; icon = '+';
                                  case _DiffTipo.eliminado:
                                    rowBg = clrRedBg; flagClr = clrRed;
                                    codeFg = clrRed; qtyFg = clrRed; icon = '-';
                                  case _DiffTipo.modificado:
                                    rowBg = isDark ? const Color(0xFF1E1000) : clrOrangeBg;
                                    flagClr = clrOrange; codeFg = clrOrange;
                                    qtyFg = clrOrange; icon = '*';
                                }
                                return Container(
                                  color: rowBg,
                                  child: Row(children: [
                                    Container(
                                      width: wFlag, color: flagClr,
                                      alignment: Alignment.center,
                                      child: Text(icon, style: const TextStyle(
                                          color: Colors.white, fontSize: 10,
                                          fontWeight: FontWeight.bold)),
                                    ),
                                    dCell(r.codigo, wCod,
                                        fg: codeFg, fw: FontWeight.w600, mono: true),
                                    dCell(r.descripcion, wDesc,
                                        fg: r.tipo == _DiffTipo.eliminado
                                            ? clrRed.withOpacity(0.8) : null),
                                    Container(
                                      width: wPrev,
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 5),
                                      decoration: BoxDecoration(border: Border(
                                          right: BorderSide(color: bdr, width: 0.5))),
                                      child: Text(r.cantAnterior,
                                        style: TextStyle(
                                          fontSize: 12, fontWeight: FontWeight.w600,
                                          color: r.tipo == _DiffTipo.eliminado ? clrRed
                                              : r.tipo == _DiffTipo.modificado
                                                  ? clrOrange.withOpacity(0.7) : tx,
                                          decoration: r.tipo == _DiffTipo.modificado
                                              ? TextDecoration.lineThrough : null),
                                        textAlign: TextAlign.center),
                                    ),
                                    Container(
                                      width: wCurr,
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 5),
                                      child: Text(r.cantActual,
                                        style: TextStyle(fontSize: 12,
                                            fontWeight: FontWeight.bold, color: qtyFg),
                                        textAlign: TextAlign.center),
                                    ),
                                  ]),
                                );
                              },
                            ),
                          ),
                        )),
                      ]),
                    ),
      actions: [
        Button(
          child: const Text('Cancelar'),
          onPressed: () => Navigator.pop(context),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Text('Esta acción es irreversible.',
              style: TextStyle(fontSize: 11,
                  color: Colors.orange.withOpacity(0.9))),
        ),
        FilledButton(
          style: ButtonStyle(backgroundColor: WidgetStateProperty.all(clrGreen)),
          onPressed: widget.onConfirm,
          child: const Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(FluentIcons.check_mark, size: 13, color: Colors.white),
            SizedBox(width: 6),
            Text('Confirmar y Aprobar Revisión',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ]),
        ),
      ],
    );
  }
}

// ─── Modelos ──────────────────────────────────────────────────────────────────
enum _DiffTipo { eliminado, modificado, agregado }

class _DiffRow {
  final _DiffTipo tipo;
  final String    codigo;
  final String    descripcion;
  final String    cantAnterior;
  final String    cantActual;

  const _DiffRow({
    required this.tipo,
    required this.codigo,
    required this.descripcion,
    required this.cantAnterior,
    required this.cantActual,
  });
}
