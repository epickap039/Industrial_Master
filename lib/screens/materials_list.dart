import 'dart:convert';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

class MaterialsListScreen extends StatefulWidget {
  const MaterialsListScreen({super.key});

  @override
  State<MaterialsListScreen> createState() => _MaterialsListScreenState();
}

class _MaterialsListScreenState extends State<MaterialsListScreen> {
  List<String> _descripcionesOficiales = [];
  bool _isLoading = true;
  String _searchQuery = "";

  @override
  void initState() {
    super.initState();
    _fetchMaterials();
  }

  Future<void> _fetchMaterials() async {
    setState(() => _isLoading = true);
    try {
      final response = await http.get(Uri.parse('http://192.168.1.73:8001/api/config/materiales'));
      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        setState(() {
          _descripcionesOficiales = List<String>.from(data);
          _isLoading = false;
        });
      } else {
        throw Exception('Error al cargar materiales');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        displayInfoBar(context, builder: (context, close) {
          return InfoBar(
            title: const Text('Error'),
            content: Text('No se pudieron cargar los materiales: $e'),
            severity: InfoBarSeverity.error,
            onClose: close,
          );
        });
      }
    }
  }

  Future<void> _addMaterial() async {
    final TextEditingController controller = TextEditingController();
    await showDialog(
      context: context,
      builder: (context) {
        return ContentDialog(
          title: const Text('Agregar Nuevo Material'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Ingrese la descripción oficial del material:'),
              const SizedBox(height: 10),
              TextBox(
                controller: controller,
                placeholder: 'Ej: ACERO 1018 Ø 1"',
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
              onPressed: () async {
                final material = controller.text.trim();
                if (material.isNotEmpty) {
                  Navigator.pop(context);
                  await _saveMaterialToBackend(material);
                }
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _saveMaterialToBackend(String material) async {
    try {
      final response = await http.post(
        Uri.parse('http://192.168.1.73:8001/api/config/materiales'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'material': material}),
      );

      if (response.statusCode == 200) {
        await _fetchMaterials();
        if (mounted) {
          displayInfoBar(context, duration: const Duration(seconds: 3), builder: (context, close) {
            return InfoBar(
              title: const Text('Éxito'),
              content: Text('Material "$material" agregado correctamente.'),
              severity: InfoBarSeverity.success,
              onClose: close,
            );
          });
        }
      } else {
        final error = json.decode(response.body)['detail'] ?? 'Error desconocido';
        throw Exception(error);
      }
    } catch (e) {
      if (mounted) {
        displayInfoBar(context, builder: (context, close) {
          return InfoBar(
            title: const Text('Error al Guardar'),
            content: Text(e.toString()),
            severity: InfoBarSeverity.error,
            onClose: close,
          );
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Filtrado de la lista
    final filteredList = _descripcionesOficiales
        .where((material) => material.toLowerCase().contains(_searchQuery.toLowerCase()))
        .toList();

    return ScaffoldPage(
      header: PageHeader(
        title: const Text("Materiales Oficiales"),
        commandBar: FilledButton(
          onPressed: _addMaterial,
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(FluentIcons.add),
              SizedBox(width: 8),
              Text('Agregar Material'),
            ],
          ),
        ),
      ),
      content: Column(
        children: [
          // Barra de Búsqueda
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
            child: TextBox(
              placeholder: "Buscar material...",
              prefix: const Padding(
                padding: EdgeInsets.only(left: 8.0),
                child: Icon(FluentIcons.search),
              ),
              onChanged: (value) {
                setState(() => _searchQuery = value);
              },
            ),
          ),
          
          if (_isLoading)
            const Expanded(child: Center(child: ProgressRing()))
          else if (filteredList.isEmpty)
             const Expanded(child: Center(child: Text("No se encontraron materiales.")))
          else
            Expanded(
              child: ListView.builder(
                itemCount: filteredList.length,
                itemBuilder: (context, index) {
                  final material = filteredList[index];
                  return ListTile(
                    title: Text(material),
                    trailing: IconButton(
                      icon: const Icon(FluentIcons.copy),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: material));
                        displayInfoBar(context, duration: const Duration(seconds: 2), builder: (context, close) {
                          return InfoBar(
                            title: const Text('Copiado'),
                            content: Text("'$material' copiado al portapapeles"),
                            severity: InfoBarSeverity.success,
                            onClose: close,
                          );
                        });
                      },
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
