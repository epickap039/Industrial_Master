import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import '../services/api_client.dart';
import '../theme/page_title_style.dart';

class StandardizationScreen extends StatefulWidget {
  @override
  _StandardizationScreenState createState() => _StandardizationScreenState();
}

class _StandardizationScreenState extends State<StandardizationScreen> {
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _filteredItems = [];
  bool _isLoading = false;
  final TextEditingController _searchController = TextEditingController();
  bool _soloNoEstandarizados = false;

  /// `material` (por defecto) o `descripcion` — alineado con backend `campo`.
  String _campo = 'material';

  List<String> _officialMaterials = [];

  String _etiqueta(dynamic item) {
    return (item['valor'] ?? item['descripcion'] ?? '---').toString();
  }

  @override
  void initState() {
    super.initState();
    _fetchItems();
    _fetchOfficialMaterials();
  }

  Future<void> _fetchOfficialMaterials() async {
    try {
      final response = await ApiClient.getUnvalidated('/api/config/materiales');
      if (response.statusCode == 200) {
        final List<dynamic> data = response.decodeJson() as List<dynamic>;
        setState(() {
          _officialMaterials = List<String>.from(data);
        });
      }
    } catch (e) {
      print("Error cargando materiales oficiales: $e");
    }
  }

  Future<void> _fetchItems() async {
    setState(() => _isLoading = true);
    try {
      final response = await ApiClient.getUnvalidated(
        '/api/limpieza/descripciones_unicas',
        queryParameters: {'campo': _campo},
      );
      if (response.statusCode == 200) {
        final List<dynamic> data = response.decodeJson() as List<dynamic>;
        setState(() {
          _items = List<Map<String, dynamic>>.from(data);
        });
        _filterItems(_searchController.text);
      }
    } catch (e) {
      _showError("Error al cargar datos: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _onCampoChanged(String? v) {
    if (v == null || v == _campo) return;
    setState(() {
      _campo = v;
      if (_campo != 'material') {
        _soloNoEstandarizados = false;
      }
    });
    _fetchItems();
    _filterItems(_searchController.text);
  }

  void _filterItems(String query) {
    setState(() {
      final baseList =
          _campo == 'material' && _soloNoEstandarizados
              ? _items
                  .where(
                    (item) =>
                        !_officialMaterials.contains(_etiqueta(item)),
                  )
                  .toList()
              : _items;

      if (query.isEmpty) {
        _filteredItems = baseList;
      } else {
        _filteredItems =
            baseList.where((item) {
              final t = _etiqueta(item).toLowerCase();
              return t.contains(query.toLowerCase());
            }).toList();
      }
    });
  }

  Future<void> _showStandardizeDialog(String currentVal, int count) async {
    String? selectedNew;
    final autoSuggestController = TextEditingController();
    final bool esMaterial = _campo == 'material';
    final titulo =
        esMaterial
            ? 'Estandarizar material'
            : 'Estandarizar descripción';

    await showDialog(
      context: context,
      builder: (context) {
        return ContentDialog(
          title: Text(titulo),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                esMaterial ? 'Material actual:' : 'Descripción actual:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(currentVal, style: TextStyle(color: Colors.red)),
              SizedBox(height: 10),
              Text(
                'Afectará a $count pieza(s).',
                style: TextStyle(fontStyle: FontStyle.italic),
              ),
              SizedBox(height: 20),
              Text(
                esMaterial
                    ? 'Nuevo material (lista oficial o texto libre):'
                    : 'Nueva descripción (lista oficial o texto libre):',
              ),
              AutoSuggestBox<String>(
                controller: autoSuggestController,
                items:
                    _officialMaterials.map((e) {
                      return AutoSuggestBoxItem<String>(
                        value: e,
                        label: e,
                        child: Tooltip(
                          message: e,
                          child: Text(
                            e,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      );
                    }).toList(),
                onSelected: (item) {
                  selectedNew = item.value;
                },
                onChanged: (text, reason) {
                  selectedNew = text;
                },
              ),
            ],
          ),
          actions: [
            Button(
              child: Text('Cancelar'),
              onPressed: () => Navigator.pop(context),
            ),
            FilledButton(
              child: Text('Aplicar a TODAS'),
              onPressed: () async {
                Navigator.pop(context);
                if (selectedNew != null && selectedNew!.isNotEmpty) {
                  await _applyStandardization(currentVal, selectedNew!);
                }
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _applyStandardization(String oldVal, String newVal) async {
    setState(() => _isLoading = true);

    const usuario = "Usuario_Estandarizacion";

    try {
      final response = await ApiClient.postUnvalidated(
        '/api/limpieza/actualizar_masivo',
        body: {
          "old_desc": oldVal,
          "new_desc": newVal,
          "usuario": usuario,
          "campo": _campo,
        },
      );

      if (response.statusCode == 200) {
        final result = response.decodeJson() as Map<String, dynamic>;
        _showSuccess("Se actualizaron ${result['actualizadas']} piezas.");
        _fetchItems();
      } else {
        _showError("Error del servidor: ${response.statusCode}");
      }
    } catch (e) {
      _showError("Error de conexión: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _hacerOficial(String desc) async {
    setState(() => _isLoading = true);
    try {
      final response = await ApiClient.postUnvalidated(
        '/api/materiales/oficial',
        body: {'descripcion': desc},
      );

      if (response.statusCode == 200) {
        _showSuccess("Material '$desc' agregado a la lista oficial.");
        await _fetchOfficialMaterials();
        await _fetchItems();
      } else {
        _showError("Error del servidor: ${response.statusCode}");
      }
    } catch (e) {
      _showError("Error de conexión: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _eliminarOficial(String desc) async {
    setState(() => _isLoading = true);
    try {
      final response = await ApiClient.deleteUnvalidated(
        '/api/materiales/oficial/${Uri.encodeComponent(desc)}',
      );

      if (response.statusCode == 200) {
        _showSuccess("Material '$desc' eliminado de la lista oficial.");
        await _fetchOfficialMaterials();
        await _fetchItems();
      } else {
        _showError("Error del servidor: ${response.statusCode}");
      }
    } catch (e) {
      _showError("Error de conexión: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _showError(String message) {
    displayInfoBar(
      context,
      builder: (context, close) {
        return InfoBar(
          title: const Text('Error'),
          content: Row(
            children: [
              Expanded(child: SelectableText(message)),
              Padding(
                padding: const EdgeInsets.only(left: 8.0),
                child: IconButton(
                  icon: const Icon(FluentIcons.copy),
                  onPressed:
                      () => Clipboard.setData(ClipboardData(text: message)),
                ),
              ),
            ],
          ),
          severity: InfoBarSeverity.error,
          onClose: close,
        );
      },
    );
  }

  void _showSuccess(String message) {
    displayInfoBar(
      context,
      builder: (context, close) {
        return InfoBar(
          title: Text('Éxito'),
          content: Text(message),
          severity: InfoBarSeverity.success,
          onClose: close,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final captionColor = theme.typography.caption?.color;
    final successGreen =
        theme.brightness == Brightness.dark
            ? Colors.green.light
            : Colors.green.dark;

    final esMaterial = _campo == 'material';

    return ScaffoldPage(
      padding: const EdgeInsets.only(top: 8),
      header: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
        child: Text(
          'Estandarización de datos',
          style: pageTitleTextStyle(context).copyWith(
            color: FluentTheme.of(context).typography.title?.color,
          ),
        ),
      ),
      content: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              esMaterial
                  ? 'Unifica textos en la columna Material del catálogo maestro.'
                  : 'Unifica textos en la columna Descripción del catálogo maestro.',
              style: TextStyle(
                fontSize: 13,
                color: FluentTheme.of(context).typography.body?.color,
              ),
            ),
            SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('Campo a estandarizar:'),
                SizedBox(
                  width: 220,
                  child: ComboBox<String>(
                    value: _campo,
                    items: const [
                      ComboBoxItem(
                        value: 'material',
                        child: Text('Material'),
                      ),
                      ComboBoxItem(
                        value: 'descripcion',
                        child: Text('Descripción'),
                      ),
                    ],
                    onChanged: _onCampoChanged,
                  ),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: TextBox(
                    controller: _searchController,
                    placeholder:
                        esMaterial
                            ? 'Filtrar materiales…'
                            : 'Filtrar descripciones…',
                    onChanged: _filterItems,
                    suffix: Icon(FluentIcons.search),
                  ),
                ),
                if (esMaterial)
                  ToggleSwitch(
                    checked: _soloNoEstandarizados,
                    content: const Text('Solo no estandarizados'),
                    onChanged: (v) {
                      setState(() {
                        _soloNoEstandarizados = v;
                      });
                      _filterItems(_searchController.text);
                    },
                  ),
              ],
            ),
            SizedBox(height: 20),
            Expanded(
              child:
                  _isLoading
                      ? Center(child: ProgressRing())
                      : _filteredItems.isEmpty
                      ? Center(child: Text("No hay datos para mostrar"))
                      : ListView.builder(
                        itemCount: _filteredItems.length,
                        itemBuilder: (context, index) {
                          final item = _filteredItems[index];
                          final val = _etiqueta(item);
                          final total = item['total'] ?? 0;
                          final isOfficial =
                              esMaterial &&
                              _officialMaterials.contains(val);

                          return Card(
                            margin: EdgeInsets.only(bottom: 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        val,
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16,
                                          color: isOfficial ? successGreen : null,
                                        ),
                                      ),
                                      Text(
                                        'Total piezas: $total',
                                        style: TextStyle(color: captionColor),
                                      ),
                                      if (isOfficial)
                                        Text(
                                          '✅ En lista oficial de materiales',
                                          style: TextStyle(
                                            color: successGreen,
                                            fontSize: 12,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                Row(
                                  children: [
                                    if (esMaterial && !isOfficial) ...[
                                      FilledButton(
                                        child: Text('Hacer oficial'),
                                        onPressed: () {
                                          showDialog(
                                            context: context,
                                            builder:
                                                (context) => ContentDialog(
                                                  title: Text("Confirmación"),
                                                  content: Text(
                                                    "Se agregará [$val] a materiales oficiales.",
                                                  ),
                                                  actions: [
                                                    Button(
                                                      child: Text("Cancelar"),
                                                      onPressed:
                                                          () => Navigator.pop(
                                                            context,
                                                          ),
                                                    ),
                                                    FilledButton(
                                                      child: Text(
                                                        "Hacer oficial",
                                                      ),
                                                      onPressed: () {
                                                        Navigator.pop(context);
                                                        _hacerOficial(val);
                                                      },
                                                    ),
                                                  ],
                                                ),
                                          );
                                        },
                                      ),
                                      SizedBox(width: 8),
                                    ],
                                    Button(
                                      child: Row(
                                        children: [
                                          Icon(FluentIcons.edit),
                                          SizedBox(width: 8),
                                          Text('Estandarizar'),
                                        ],
                                      ),
                                      onPressed:
                                          () => _showStandardizeDialog(
                                            val,
                                            total is int
                                                ? total
                                                : int.tryParse(
                                                      '$total',
                                                    ) ??
                                                    0,
                                          ),
                                    ),
                                    if (esMaterial && isOfficial) ...[
                                      SizedBox(width: 8),
                                      IconButton(
                                        icon: Icon(
                                          FluentIcons.delete,
                                          color: Colors.red,
                                        ),
                                        onPressed: () {
                                          showDialog(
                                            context: context,
                                            builder:
                                                (context) => ContentDialog(
                                                  title: Text(
                                                    "Eliminar material oficial",
                                                  ),
                                                  content: Text(
                                                    "¿Seguro que deseas eliminar '$val' del catálogo oficial?",
                                                  ),
                                                  actions: [
                                                    Button(
                                                      child: Text("Cancelar"),
                                                      onPressed:
                                                          () => Navigator.pop(
                                                            context,
                                                          ),
                                                    ),
                                                    FilledButton(
                                                      style: ButtonStyle(
                                                        backgroundColor:
                                                            ButtonState.all(
                                                              Colors.red,
                                                            ),
                                                      ),
                                                      child: Text("Eliminar"),
                                                      onPressed: () {
                                                        Navigator.pop(context);
                                                        _eliminarOficial(val);
                                                      },
                                                    ),
                                                  ],
                                                ),
                                          );
                                        },
                                      ),
                                    ],
                                  ],
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
    );
  }
}
