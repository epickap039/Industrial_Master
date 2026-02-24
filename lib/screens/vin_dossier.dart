import 'package:fluent_ui/fluent_ui.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

const String API_URL = "http://192.168.1.73:8001";

class VINDossierScreen extends StatefulWidget {
  const VINDossierScreen({Key? key}) : super(key: key);

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
      _filteredVins = _allVins.where((v) {
        final vinStr = v['vin']?.toString().toLowerCase() ?? '';
        final clientStr = v['cliente']?.toString().toLowerCase() ?? '';
        return vinStr.contains(query.toLowerCase()) || clientStr.contains(query.toLowerCase());
      }).toList();
    });
  }

  Future<void> _searchVIN(String query) async {
    if (query.isEmpty) return;
    setState(() => _isLoading = true);
    try {
      final response = await http.get(Uri.parse('$API_URL/api/vins/buscar?q=$query'));
      if (response.statusCode == 200) {
        final List results = json.decode(response.body);
        setState(() {
          if (results.isNotEmpty) {
            _vinData = results.first;
            _notesController.text = _vinData['notas'] ?? "";
          } else {
            _vinData = null;
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

  Future<void> _saveNotes() async {
    if (_vinData == null) return;
    try {
      final response = await http.put(
        Uri.parse('$API_URL/api/vins/${_vinData['id_unidad']}/notas'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'vin': '', 'notas': _notesController.text}),
      );
      if (response.statusCode == 200) {
        _showError("Notas guardadas correctamente", isError: false);
      }
    } catch (e) {
      _showError("Error al guardar: $e");
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
                          Text("Listado de Unidades", style: FluentTheme.of(context).typography.subtitle),
                          const Divider(),
                          Expanded(
                            child: ListView.builder(
                              itemCount: _filteredVins.length,
                              itemBuilder: (context, index) {
                                final v = _filteredVins[index];
                                final isSelected = _vinData != null && _vinData['id_unidad'] == v['id_unidad'];
                                return Container(
                                  margin: const EdgeInsets.symmetric(vertical: 4),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(4),
                                    color: isSelected ? Colors.blue.withOpacity(0.1) : null,
                                  ),
                                  child: ListTile(
                                    title: Text(v['vin'], style: const TextStyle(fontWeight: FontWeight.bold)),
                                    subtitle: Text("${v['cliente']} - ${v['tracto']}"),
                                    onPressed: () {
                                      setState(() {
                                        _vinData = v;
                                        _notesController.text = v['notas'] ?? "";
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
                    child: _vinData == null
                        ? const Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(FluentIcons.contact_card, size: 80, color: Colors.grey),
                                SizedBox(height: 16),
                                Text("Selecciona una unidad para ver su expediente."),
                              ],
                            ),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Card(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text("Detalles del Vehículo", style: FluentTheme.of(context).typography.subtitle),
                                    const Divider(),
                                    const SizedBox(height: 8),
                                    _buildInfoRow("VIN:", _vinData['vin']),
                                    _buildInfoRow("Cliente:", _vinData['cliente']),
                                    _buildInfoRow("Tracto:", _vinData['tracto']),
                                    _buildInfoRow("Tipo:", _vinData['tipo']),
                                    _buildInfoRow("Versión:", _vinData['version']),
                                    _buildInfoRow("BOM Rev:", "Rev ${_vinData['numero_revision']}"),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 16),
                              Expanded(
                                child: Card(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          Text("Notas de Modificación / Piso", style: FluentTheme.of(context).typography.subtitle),
                                          FilledButton(
                                            child: const Text("Guardar Notas"),
                                            onPressed: _saveNotes,
                                          ),
                                        ],
                                      ),
                                      const Divider(),
                                      const SizedBox(height: 8),
                                      Expanded(
                                        child: TextBox(
                                          controller: _notesController,
                                          maxLines: null,
                                          placeholder: "Escribe aquí las modificaciones realizadas en piso...",
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      const Button(
                                        onPressed: null, // Deshabilitado por ahora
                                        child: Text("Adjuntar Archivos / Reportes"),
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
          SizedBox(width: 100, child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold))),
          Text(value),
        ],
      ),
    );
  }
}
