import 'package:fluent_ui/fluent_ui.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:open_file/open_file.dart';
import 'dart:io';
import 'bom_manager.dart';

const String API_URL = "http://192.168.1.73:8001";

class VINDossierScreen extends StatefulWidget {
  final Function(int idVersion, String versionName, String tractoName)?
      onNavigateToBOM;

  const VINDossierScreen({Key? key, this.onNavigateToBOM}) : super(key: key);

  @override
  _VINDossierScreenState createState() => _VINDossierScreenState();
}

class _VINDossierScreenState extends State<VINDossierScreen> {
  final TextEditingController _searchController = TextEditingController();
  dynamic _vinData;
  bool _isLoading = false;
  final TextEditingController _notesController = TextEditingController();
  List<dynamic> _allVins = [];
  List<dynamic> _filteredVins = [];

  // v60.0: Nube de Archivos
  List<dynamic> _archivos = [];
  bool _isLoadingArchivos = false;
  bool _isSubiendo = false;

  @override
  void initState() {
    super.initState();
    _fetchAllVins();
  }

  Future<void> _fetchAllVins() async {
    setState(() => _isLoading = true);
    try {
      final response = await http.get(Uri.parse('$API_URL/api/vins/buscar?q='));
      if (response.statusCode == 200) {
        setState(() {
          _allVins = json.decode(response.body);
          _filteredVins = List.from(_allVins);
        });
      }
    } catch (e) {
      _showError("Error al cargar VINs: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _filterVins(String query) {
    setState(() {
      _filteredVins =
          _allVins.where((v) {
            final vinStr = v['vin']?.toString().toLowerCase() ?? '';
            final clientStr = v['cliente']?.toString().toLowerCase() ?? '';
            return vinStr.contains(query.toLowerCase()) ||
                clientStr.contains(query.toLowerCase());
          }).toList();
    });
  }

  Future<void> _searchVIN(String query) async {
    if (query.isEmpty) return;
    setState(() => _isLoading = true);
    try {
      final response = await http.get(
        Uri.parse('$API_URL/api/vins/buscar?q=$query'),
      );
      if (response.statusCode == 200) {
        final List results = json.decode(response.body);
        setState(() {
          if (results.isNotEmpty) {
            _vinData = results.first;
            _notesController.text = _vinData['notas'] ?? "";
            _fetchArchivos(); // v60.0: cargar archivos del VIN
          } else {
            _vinData = null;
            _archivos = [];
            _showError("No se encontró el VIN");
          }
        });
      }
    } catch (e) {
      _showError("Error de conexión: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // === v60.0: NUBE DE ARCHIVOS ===
  Future<void> _fetchArchivos() async {
    if (_vinData == null) return;
    setState(() => _isLoadingArchivos = true);
    try {
      final res = await http.get(
        Uri.parse('$API_URL/api/vins/${_vinData['id_unidad']}/archivos'),
      );
      if (res.statusCode == 200) {
        setState(() => _archivos = json.decode(res.body));
      }
    } catch (_) {
      // silencioso
    } finally {
      setState(() => _isLoadingArchivos = false);
    }
  }

  Future<void> _subirArchivo() async {
    if (_vinData == null) return;
    final result = await FilePicker.platform.pickFiles(allowMultiple: false);
    if (result == null || result.files.isEmpty) return;
    final pf = result.files.first;
    if (pf.path == null) return;

    setState(() => _isSubiendo = true);
    try {
      final req = http.MultipartRequest(
        'POST',
        Uri.parse('$API_URL/api/vins/${_vinData['id_unidad']}/subir_archivo'),
      );
      req.files.add(await http.MultipartFile.fromPath('file', pf.path!));
      final streamed = await req.send();
      if (streamed.statusCode == 200) {
        _showError("Archivo subido correctamente", isError: false);
        await _fetchArchivos();
      } else {
        _showError("Error al subir archivo: ${streamed.statusCode}");
      }
    } catch (e) {
      _showError("Error: $e");
    } finally {
      setState(() => _isSubiendo = false);
    }
  }

  Future<void> _abrirArchivoDesdeServer(String nombreArchivo) async {
    if (_vinData == null) return;
    final url =
        '$API_URL/api/vins/${_vinData['id_unidad']}/archivos/$nombreArchivo';
    try {
      // Descargar a carpeta temporal y abrir
      final res = await http.get(Uri.parse(url));
      if (res.statusCode == 200) {
        final tmpDir = Directory.systemTemp;
        final tmpFile = File('${tmpDir.path}\\$nombreArchivo');
        await tmpFile.writeAsBytes(res.bodyBytes);
        await OpenFile.open(tmpFile.path);
      }
    } catch (e) {
      _showError("No se pudo abrir el archivo: $e");
    }
  }

  Future<void> _saveNotes() async {
    if (_vinData == null) return;
    try {
      final response = await http.put(
        Uri.parse('$API_URL/api/vins/${_vinData['id_unidad']}/notas'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'vin': _vinData['vin'],
          'observaciones': _notesController.text,
        }),
      );
      if (response.statusCode == 200) {
        _showError("Notas guardadas correctamente", isError: false);
      }
    } catch (e) {
      _showError("Error al guardar: $e");
    }
  }

  // v60.0: ADN de Ingeniería - Muestra historial combinado del VIN y su revisión
  Future<void> _showADNIngenieria() async {
    if (_vinData == null) return;

    List<dynamic> log = [];
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
                        '$API_URL/api/vins/${_vinData['id_unidad']}/adn',
                      ),
                    )
                    .then((res) {
                      if (res.statusCode == 200) {
                        setDState(() {
                          log = json.decode(res.body);
                          dialogLoading = false;
                        });
                      } else {
                        setDState(() => dialogLoading = false);
                      }
                    });
                return const ContentDialog(
                  content: Center(child: ProgressRing()),
                );
              }

              return ContentDialog(
                title: Row(
                  children: [
                    Icon(FluentIcons.history, color: Colors.blue),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "ADN de Ingeniería - VIN: ${_vinData['vin']}",
                      ),
                    ),
                  ],
                ),
                content: SizedBox(
                  width: 600,
                  height: 400,
                  child:
                      log.isEmpty
                          ? const Center(
                            child: Text(
                              "Sin historial de eventos.",
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.grey),
                            ),
                          )
                          : ListView.builder(
                            itemCount: log.length,
                            itemBuilder: (context, idx) {
                              final item = log[idx];
                              final titulo =
                                  (item['titulo'] as String).toLowerCase();

                              String icn = "🔧";
                              if (titulo.contains('aprob'))
                                icn = "✅";
                              else if (titulo.contains('archivo'))
                                icn = "📎";
                              else if (titulo.contains('combo') ||
                                  titulo.contains('vinc'))
                                icn = "🔗";

                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 4.0,
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        top: 4,
                                        right: 8,
                                      ),
                                      child: Text(
                                        icn,
                                        style: const TextStyle(fontSize: 16),
                                      ),
                                    ),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            item['detalle'] ?? "",
                                            style: const TextStyle(
                                              fontSize: 13,
                                            ),
                                          ),
                                          Text(
                                            "${item['titulo']}  •  ${item['usuario']}  •  ${item['fecha']?.toString().substring(0, 16) ?? ''}",
                                            style: TextStyle(
                                              fontSize: 11,
                                              color:
                                                  (FluentTheme.of(context)
                                                          .typography
                                                          .body
                                                          ?.color
                                                          ?.withOpacity(0.3) ??
                                                      Colors.grey),
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

  Future<void> _vincularSocio(int idSocio) async {
    if (_vinData == null) return;
    try {
      final res = await http.post(
        Uri.parse(
          '$API_URL/api/vins/${_vinData['id_unidad']}/vincular/$idSocio',
        ),
      );
      if (res.statusCode == 200) {
        _showError(
          idSocio == 0 ? "VIN desvinculado" : "Complemento vinculado",
          isError: false,
        );
        _searchVIN(_vinData['vin']); // reload
      } else {
        _showError("Error al vincular: ${res.statusCode}");
      }
    } catch (e) {
      _showError("Error: $e");
    }
  }

  void _showVincularDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return ContentDialog(
          title: const Text("Vincular a Complemento"),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.only(bottom: 12.0),
                  child: Text(
                    "Busca o selecciona un VIN de la lista para vincularlo a esta unidad.",
                  ),
                ),
                AutoSuggestBox<String>(
                  placeholder: "Buscar VIN de socio...",
                  items:
                      _allVins
                          .where((v) => v['id_unidad'] != _vinData['id_unidad'])
                          .map<AutoSuggestBoxItem<String>>(
                            (v) => AutoSuggestBoxItem<String>(
                              value: v['id_unidad'].toString(),
                              label: "${v['vin']} - ${v['tracto']}",
                            ),
                          )
                          .toList(),
                  onSelected: (item) {
                    final idSocio = int.tryParse(item.value ?? "0") ?? 0;
                    if (idSocio > 0) {
                      Navigator.pop(context);
                      _vincularSocio(idSocio);
                    }
                  },
                ),
              ],
            ),
          ),
          actions: [
            Button(
              child: const Text("Cancelar"),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        );
      },
    );
  }

  void _showDeleteVinDialog() {
    String password = "";
    String motivo = "";
    bool eliminando = false;

    showDialog(
      context: context,
      builder:
          (context) => StatefulBuilder(
            builder: (context, setDState) {
              return ContentDialog(
                title: const Text(
                  "Eliminar Expediente VIN",
                  style: TextStyle(color: Color(0xFFE53935)),
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      "Esta acción es irreversible e impactará en auditoría global. Ingresa tus credenciales para continuar.",
                    ),
                    const SizedBox(height: 12),
                    TextBox(
                      placeholder: "Contraseña de Admin",
                      obscureText: true,
                      onChanged: (v) => password = v,
                    ),
                    const SizedBox(height: 8),
                    TextBox(
                      placeholder: "Motivo de la eliminación (Opcional)",
                      onChanged: (v) => motivo = v,
                    ),
                    const SizedBox(height: 12),
                    if (eliminando) const ProgressRing(),
                  ],
                ),
                actions: [
                  Button(
                    child: const Text("Cancelar"),
                    onPressed: () => Navigator.pop(context),
                  ),
                  FilledButton(
                    style: ButtonStyle(
                      backgroundColor: ButtonState.all(Colors.red),
                    ),
                    onPressed: () async {
                      if (password.isEmpty) return;
                      setDState(() => eliminando = true);
                      try {
                        final res = await http.delete(
                          Uri.parse('$API_URL/api/vins/${_vinData['vin']}'),
                          headers: {"Content-Type": "application/json"},
                          body: json.encode({
                            "password": password.trim(),
                            "motivo": motivo.trim(),
                          }),
                        );
                        if (res.statusCode == 200) {
                          Navigator.pop(context);
                          setState(() {
                            _vinData = null;
                            _archivos = [];
                            _notesController.clear();
                          });
                          _fetchAllVins();
                          _showError("Expediente eliminado", isError: false);
                        } else if (res.statusCode == 401) {
                          setDState(() => eliminando = false);
                          _showError("Contraseña incorrecta");
                        } else {
                          setDState(() => eliminando = false);
                          _showError("Error: ${res.body}");
                        }
                      } catch (e) {
                        setDState(() => eliminando = false);
                        _showError("Error: $e");
                      }
                    },
                    child: const Text("Eliminar Definitivamente"),
                  ),
                ],
              );
            },
          ),
    );
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

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: const PageHeader(title: Text("Expedientes VIN / Dossier")),
      content: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 300,
                  child: TextBox(
                    controller: _searchController,
                    placeholder: "Ingresa VIN para buscar...",
                    suffix: IconButton(
                      icon: const Icon(FluentIcons.search),
                      onPressed: () => _searchVIN(_searchController.text),
                    ),
                    onChanged: _filterVins,
                    onSubmitted: (v) {
                      _filterVins(v);
                      if (_filteredVins.isNotEmpty) {
                        setState(() {
                          _vinData = _filteredVins.first;
                          _notesController.text = _vinData['notas'] ?? "";
                        });
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                if (_isLoading) const ProgressRing(),
              ],
            ),
            Expanded(
              child: Row(
                children: [
                  // Lista de VINs filtrada
                  Expanded(
                    flex: 2,
                    child: Card(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "Listado de Unidades",
                            style: FluentTheme.of(context).typography.subtitle,
                          ),
                          const Divider(),
                          Expanded(
                            child: ListView.builder(
                              itemCount: _filteredVins.length,
                              itemBuilder: (context, index) {
                                final v = _filteredVins[index];
                                final isSelected =
                                    _vinData != null &&
                                    _vinData['id_unidad'] == v['id_unidad'];
                                return Container(
                                  margin: const EdgeInsets.symmetric(
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(4),
                                    color:
                                        isSelected
                                            ? Colors.blue.withOpacity(0.1)
                                            : null,
                                  ),
                                  child: ListTile(
                                    title: Text(
                                      v['vin'],
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    subtitle: Text(
                                      "${v['cliente']} - ${v['tracto']}",
                                    ),
                                    onPressed: () {
                                      setState(() {
                                        _vinData = v;
                                        _notesController.text =
                                            v['notas'] ?? "";
                                      });
                                    },
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  // Detalle del VIN seleccionado
                  Expanded(
                    flex: 3,
                    child:
                        _vinData == null
                            ? const Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    FluentIcons.contact_card,
                                    size: 80,
                                    color: Colors.grey,
                                  ),
                                  SizedBox(height: 16),
                                  Text(
                                    "Selecciona una unidad para ver su expediente.",
                                  ),
                                ],
                              ),
                            )
                            : SingleChildScrollView(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Card(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text(
                                              "Detalles del Vehículo",
                                              style:
                                                  FluentTheme.of(
                                                    context,
                                                  ).typography.subtitle,
                                            ),
                                            Tooltip(
                                              message: "Eliminar Expediente",
                                              child: IconButton(
                                                icon: const Icon(
                                                  FluentIcons.delete,
                                                  color: Color(0xFFE53935),
                                                ),
                                                onPressed: _showDeleteVinDialog,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const Divider(),
                                        const SizedBox(height: 8),
                                        _buildInfoRow("VIN:", _vinData['vin']),
                                        _buildInfoRow(
                                          "Cliente:",
                                          _vinData['cliente'],
                                        ),
                                        _buildInfoRow(
                                          "Tracto:",
                                          _vinData['tracto'],
                                        ),
                                        _buildInfoRow(
                                          "Tipo:",
                                          _vinData['tipo'],
                                        ),
                                        _buildInfoRow(
                                          "Versión:",
                                          _vinData['version'],
                                        ),
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 4.0,
                                          ),
                                          child: Row(
                                            children: [
                                              const SizedBox(
                                                width: 100,
                                                child: Text(
                                                  "Estructura / BOM:",
                                                  style: TextStyle(
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ),
                                              Expanded(
                                                child: Text(
                                                  "Rev ${_vinData['numero_revision']} - ${_vinData['version']}",
                                                ),
                                              ),
                                              if (widget.onNavigateToBOM !=
                                                  null)
                                                HyperlinkButton(
                                                  child: const Row(
                                                    children: [
                                                      Icon(
                                                        FluentIcons
                                                            .open_in_new_window,
                                                        size: 14,
                                                      ),
                                                      SizedBox(width: 4),
                                                      Text("Ver Lista Asignada"),
                                                    ],
                                                  ),
                                                  onPressed: () {
                                                    widget.onNavigateToBOM!(
                                                      _vinData['id_version'] ??
                                                          0,
                                                      _vinData['version'] ?? '',
                                                      _vinData['tracto'] ?? '',
                                                    );
                                                  },
                                                ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(height: 12),
                                        Text(
                                          "Complemento",
                                          style:
                                              FluentTheme.of(
                                                context,
                                              ).typography.subtitle,
                                        ),
                                        const Divider(),
                                        if (_vinData['id_socio'] == null)
                                          Padding(
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 8.0,
                                            ),
                                            child: Button(
                                              onPressed: _showVincularDialog,
                                              child: const Text(
                                                "Vincular con Complemento",
                                              ),
                                            ),
                                          )
                                        else
                                          Padding(
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 8.0,
                                            ),
                                            child: Row(
                                              children: [
                                                Icon(
                                                  FluentIcons.link,
                                                  color: Colors.blue,
                                                ),
                                                const SizedBox(width: 8),
                                                Text(
                                                  _vinData['vin_socio'] ??
                                                      "Socio Desconocido",
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                                const SizedBox(width: 16),
                                                Button(
                                                  onPressed:
                                                      () => _vincularSocio(0),
                                                  child: const Text(
                                                    "Desvincular",
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        const SizedBox(height: 12),
                                        // v60.0: Botón ADN de Ingeniería
                                        Button(
                                          onPressed: _showADNIngenieria,
                                          child: const Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                FluentIcons.history,
                                                size: 14,
                                              ),
                                              SizedBox(width: 6),
                                              Text("Ver ADN de Ingeniería"),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  Card(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text(
                                              "Notas de Modificación / Piso",
                                              style:
                                                  FluentTheme.of(
                                                    context,
                                                  ).typography.subtitle,
                                            ),
                                            FilledButton(
                                              child: const Text(
                                                "Guardar Notas",
                                              ),
                                              onPressed: _saveNotes,
                                            ),
                                          ],
                                        ),
                                        const Divider(),
                                        const SizedBox(height: 8),
                                        TextBox(
                                          controller: _notesController,
                                          maxLines: null,
                                          minLines: 4,
                                          placeholder:
                                              "Escribe aquí las modificaciones realizadas en piso...",
                                        ),
                                        const SizedBox(height: 8),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  // === v60.0: NUBE DE ARCHIVOS ===
                                  Card(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            Row(
                                              children: [
                                                const Icon(
                                                  FluentIcons.cloud_upload,
                                                  size: 16,
                                                  color: Color(0xFF1565C0),
                                                ),
                                                const SizedBox(width: 6),
                                                Text(
                                                  "Nube de Archivos",
                                                  style:
                                                      FluentTheme.of(
                                                        context,
                                                      ).typography.subtitle,
                                                ),
                                              ],
                                            ),
                                            Row(
                                              children: [
                                                _isSubiendo
                                                    ? const SizedBox(
                                                      width: 20,
                                                      height: 20,
                                                      child: ProgressRing(
                                                        strokeWidth: 2,
                                                      ),
                                                    )
                                                    : Tooltip(
                                                      message:
                                                          "Adjuntar archivo al expediente del VIN",
                                                      child: IconButton(
                                                        icon: const Icon(
                                                          FluentIcons.upload,
                                                          size: 16,
                                                        ),
                                                        onPressed:
                                                            _subirArchivo,
                                                      ),
                                                    ),
                                                Tooltip(
                                                  message: "Recargar archivos",
                                                  child: IconButton(
                                                    icon: const Icon(
                                                      FluentIcons.refresh,
                                                      size: 14,
                                                    ),
                                                    onPressed: _fetchArchivos,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                        const Divider(),
                                        if (_isLoadingArchivos)
                                          const SizedBox(
                                            height: 40,
                                            child: Center(
                                              child: ProgressRing(),
                                            ),
                                          )
                                        else if (_archivos.isEmpty)
                                          const Padding(
                                            padding: EdgeInsets.symmetric(
                                              vertical: 8,
                                            ),
                                            child: Text(
                                              "Sin archivos adjuntos.",
                                              style: TextStyle(
                                                color: Colors.grey,
                                              ),
                                            ),
                                          )
                                        else
                                          ...(_archivos.map(
                                            (arch) => Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 3,
                                                  ),
                                              child: Row(
                                                children: [
                                                  Icon(
                                                    (arch['es_pdf'] as bool)
                                                        ? FluentIcons.pdf
                                                        : FluentIcons.document,
                                                    size: 16,
                                                    color:
                                                        (arch['es_pdf'] as bool)
                                                            ? Colors.red
                                                            : (FluentTheme.of(
                                                                      context,
                                                                    )
                                                                    .typography
                                                                    .body
                                                                    ?.color
                                                                    ?.withOpacity(
                                                                      0.3,
                                                                    ) ??
                                                                Colors.grey),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Expanded(
                                                    child: Text(
                                                      arch['nombre'],
                                                      style: const TextStyle(
                                                        fontSize: 13,
                                                      ),
                                                    ),
                                                  ),
                                                  Text(
                                                    "${arch['tamano_kb']} KB",
                                                    style: const TextStyle(
                                                      fontSize: 11,
                                                      color: Colors.grey,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Tooltip(
                                                    message: "Abrir archivo",
                                                    child: IconButton(
                                                      icon: Icon(
                                                        FluentIcons
                                                            .open_in_new_window,
                                                        size: 14,
                                                        color: Color(
                                                          0xFF1565C0,
                                                        ),
                                                      ),
                                                      onPressed:
                                                          () =>
                                                              _abrirArchivoDesdeServer(
                                                                arch['nombre'],
                                                              ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          )).toList(),
                                      ],
                                    ),
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
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Text(value),
        ],
      ),
    );
  }
}
