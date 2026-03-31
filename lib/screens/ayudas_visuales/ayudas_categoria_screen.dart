import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' as material;
import 'package:fluent_ui/fluent_ui.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/api_client.dart';
import 'ayudas_api_models.dart';
import 'ayudas_visor_screen.dart';

/// Pantalla 2: documentos de una categoría + nuevo documento.
class AyudasCategoriaScreen extends StatefulWidget {
  const AyudasCategoriaScreen({
    super.key,
    required this.idCategoria,
    required this.nombreCategoria,
    required this.canUpload,
  });

  final int idCategoria;
  final String nombreCategoria;
  final bool canUpload;

  @override
  State<AyudasCategoriaScreen> createState() => _AyudasCategoriaScreenState();
}

class _AyudasCategoriaScreenState extends State<AyudasCategoriaScreen> {
  bool _loading = true;
  String? _error;
  List<dynamic> _docs = [];
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _cargar();
    _searchCtrl.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _cargar() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await ApiClient.get('/api/ayudas/lista/${widget.idCategoria}');
      setState(() {
        _docs = data is List ? data : [];
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  material.InputDecoration _inputDec(
    BuildContext context,
    String label, {
    String? hint,
  }) {
    final border = material.OutlineInputBorder(
      borderRadius: material.BorderRadius.circular(12.0),
      borderSide: material.BorderSide(color: material.Theme.of(context).dividerColor),
    );
    return material.InputDecoration(
      labelText: label,
      hintText: hint,
      contentPadding: const material.EdgeInsets.symmetric(
        vertical: 12.0,
        horizontal: 16.0,
      ),
      border: border,
      enabledBorder: border,
    );
  }

  Future<void> _dialogoNuevoDocumento() async {
    final tituloCtrl = TextEditingController();
    final subcategoriaCtrl = TextEditingController();
    final revCtrl = TextEditingController(text: 'A');
    final vinCtrl = TextEditingController();
    String? pathPdf;

    await showDialog<void>(
      context: context,
      barrierColor: material.Theme.of(context).brightness == material.Brightness.dark
          ? const material.Color(0xFF121212)
          : material.Colors.white,
      builder: (ctx) {
        return material.AlertDialog(
          backgroundColor: material.Theme.of(context).brightness ==
                  material.Brightness.dark
              ? const material.Color(0xFF121212)
              : material.Colors.white,
          shape: material.RoundedRectangleBorder(
            borderRadius: material.BorderRadius.circular(20.0),
          ),
          title: const Text('Nuevo documento'),
          content: StatefulBuilder(
            builder: (context, setLocal) {
              return SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    material.TextField(
                      controller: tituloCtrl,
                      style: material.TextStyle(
                        color: material.Theme.of(context).textTheme.bodyLarge?.color,
                      ),
                      decoration: _inputDec(context, 'Titulo'),
                    ),
                    const SizedBox(height: 12),
                    material.TextField(
                      controller: subcategoriaCtrl,
                      style: material.TextStyle(
                        color: material.Theme.of(context).textTheme.bodyLarge?.color,
                      ),
                      decoration: _inputDec(context, 'Subcategoría / Proceso'),
                    ),
                    const SizedBox(height: 12),
                    material.TextField(
                      controller: vinCtrl,
                      style: material.TextStyle(
                        color: material.Theme.of(context).textTheme.bodyLarge?.color,
                      ),
                      decoration: _inputDec(
                        context,
                        'VINs aplicables',
                        hint: 'Ej: 3N1AB7AP1HY123456, 1HGCM82633A004352',
                      ),
                    ),
                    const SizedBox(height: 12),
                    material.TextField(
                      controller: revCtrl,
                      style: material.TextStyle(
                        color: material.Theme.of(context).textTheme.bodyLarge?.color,
                      ),
                      decoration: _inputDec(context, 'Numero de revision'),
                    ),
                    const SizedBox(height: 12),
                    material.OutlinedButton(
                      onPressed: () async {
                        final r = await FilePicker.platform.pickFiles(
                          type: FileType.custom,
                          allowedExtensions: ['pdf'],
                        );
                        if (r != null && r.files.single.path != null) {
                          setLocal(() => pathPdf = r.files.single.path);
                        }
                      },
                      child: Text(
                        pathPdf == null
                            ? 'Seleccionar PDF…'
                            : 'PDF: ${pathPdf!.split(RegExp(r'[\\/]')).last}',
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          actions: [
            material.TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar'),
            ),
            material.ElevatedButton(
              child: const Text('Subir'),
              onPressed: () async {
                final t = tituloCtrl.text.trim();
                if (t.isEmpty || pathPdf == null) return;
                final prefs = await SharedPreferences.getInstance();
                final user = prefs.getString('username')?.trim() ?? 'Operador';
                if (!mounted) return;
                showDialog<void>(
                  context: context,
                  barrierDismissible: false,
                  builder: (lc) => const ContentDialog(
                    title: Text('Subiendo…'),
                    content: Center(child: SizedBox(height: 80, child: ProgressRing())),
                  ),
                );
                try {
                  final fields = <String, String>{
                    'id_categoria': '${widget.idCategoria}',
                    'titulo': t,
                    'numero_revision': revCtrl.text.trim(),
                    'usuario': user,
                  };
                  if (subcategoriaCtrl.text.trim().isNotEmpty) {
                    fields['subcategoria'] = subcategoriaCtrl.text;
                  }
                  final v = vinCtrl.text.trim();
                  if (v.isNotEmpty) fields['vin'] = v;
                  await ApiClient.postMultipart(
                    '/api/ayudas/subir',
                    fields: fields,
                    files: {'file': await ApiClient.fileField('file', pathPdf!)},
                  );
                  if (!mounted) return;
                  Navigator.of(context, rootNavigator: true).pop();
                  Navigator.of(context, rootNavigator: true).pop();
                  await _cargar();
                  if (mounted) {
                    displayInfoBar(context, builder: (c, close) {
                      return InfoBar(
                        title: const Text('Listo'),
                        content: const Text('Documento creado.'),
                        severity: InfoBarSeverity.success,
                        onClose: close,
                      );
                    });
                  }
                } catch (e) {
                  if (!mounted) return;
                  Navigator.of(context, rootNavigator: true).pop();
                  showAyudasUploadError(context, e);
                }
              },
            ),
          ],
        );
      },
    );

    tituloCtrl.dispose();
    subcategoriaCtrl.dispose();
    revCtrl.dispose();
    vinCtrl.dispose();
  }

  Future<void> _dialogoEditarSubcategoria(String nombreActual) async {
    final ctrl = TextEditingController(text: nombreActual);
    try {
      await showDialog<void>(
        context: context,
        barrierColor:
            material.Theme.of(context).brightness == material.Brightness.dark
            ? const material.Color(0xFF121212)
            : material.Colors.white,
        builder: (ctx) {
          return material.AlertDialog(
            backgroundColor:
                material.Theme.of(context).brightness == material.Brightness.dark
                ? const material.Color(0xFF121212)
                : material.Colors.white,
            shape: material.RoundedRectangleBorder(
              borderRadius: material.BorderRadius.circular(20.0),
            ),
            title: const Text('Editar subcategoría'),
            content: material.TextField(
              controller: ctrl,
              style: material.TextStyle(
                color: material.Theme.of(context).textTheme.bodyLarge?.color,
              ),
              decoration: _inputDec(context, 'Subcategoría / Proceso'),
            ),
            actions: [
              material.TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancelar'),
              ),
              material.ElevatedButton(
                onPressed: () async {
                  final nuevo = ctrl.text.trim();
                  if (nuevo.isEmpty) return;
                  await ApiClient.put(
                    '/api/ayudas/subcategoria/editar',
                    body: {
                      'id_categoria': widget.idCategoria,
                      'nombre_antiguo': nombreActual == 'Sin subcategoría'
                          ? ''
                          : nombreActual,
                      'nombre_nuevo': nuevo,
                    },
                  );
                  if (!mounted) return;
                  Navigator.pop(ctx);
                  await _cargar();
                },
                child: const Text('Guardar'),
              ),
            ],
          );
        },
      );
    } catch (e) {
      if (mounted) showAyudasUploadError(context, e);
    } finally {
      ctrl.dispose();
    }
  }

  Map<String, List<Map<String, dynamic>>> _groupedDocs() {
    final q = _searchCtrl.text.trim().toLowerCase();
    final out = <String, List<Map<String, dynamic>>>{};
    for (final d in _docs) {
      if (d is! Map<String, dynamic>) continue;
      final title = ayudasTituloDocumento(d).toLowerCase();
      final vin = ayudasVin(d).toLowerCase();
      final sub = ayudasSubcategoriaProceso(d).toLowerCase();
      if (q.isNotEmpty && !title.contains(q) && !vin.contains(q) && !sub.contains(q)) {
        continue;
      }
      final key = ayudasSubcategoriaProceso(d).isEmpty
          ? 'Sin subcategoría'
          : ayudasSubcategoriaProceso(d);
      out.putIfAbsent(key, () => <Map<String, dynamic>>[]).add(d);
    }
    return out;
  }

  Future<void> _eliminarDocumento(int idAyuda, String titulo) async {
    final passCtrl = TextEditingController();
    try {
      await showDialog<void>(
        context: context,
        builder: (dCtx) => material.AlertDialog(
          title: const Text('Eliminar documento'),
          content: material.TextField(
            controller: passCtrl,
            obscureText: true,
            decoration: const material.InputDecoration(labelText: 'Contraseña'),
          ),
          actions: [
            material.TextButton(
              onPressed: () => Navigator.pop(dCtx),
              child: const Text('Cancelar'),
            ),
            material.TextButton(
              onPressed: () async {
                if (passCtrl.text != kAyudasDeletePassword) {
                  displayInfoBar(context, builder: (c, close) {
                    return InfoBar(
                      title: const Text('Error'),
                      content: const Text('Contraseña incorrecta'),
                      severity: InfoBarSeverity.error,
                      onClose: close,
                    );
                  });
                  return;
                }
                Navigator.pop(dCtx);
                try {
                  final prefs = await SharedPreferences.getInstance();
                  final user = prefs.getString('username')?.trim() ?? 'Operador';
                  await ApiClient.delete(
                    '/api/ayudas/documento/$idAyuda',
                    headers: {'X-Usuario': user},
                  );
                  await _cargar();
                } catch (e) {
                  if (mounted) showAyudasUploadError(context, e);
                }
              },
              child: const Text('Eliminar'),
            ),
          ],
        ),
      );
    } finally {
      passCtrl.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final grouped = _groupedDocs();
    final textColor = material.Theme.of(context).textTheme.bodyMedium?.color;
    return material.Scaffold(
      appBar: material.AppBar(
        leading: material.IconButton(
          icon: const material.Icon(material.Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(widget.nombreCategoria),
        actions: [
          material.IconButton(
            icon: const material.Icon(material.Icons.refresh),
            onPressed: _loading ? null : _cargar,
          ),
        ],
      ),
      body: Stack(
        children: [
          _loading
              ? const Center(child: ProgressRing())
              : _error != null
                  ? Center(child: Text(_error!))
                  : grouped.isEmpty
                      ? const Center(child: Text('No hay documentos en esta categoría.'))
                      : ListView(
                          padding: const EdgeInsets.all(16),
                          children: [
                            material.TextField(
                              controller: _searchCtrl,
                              decoration: material.InputDecoration(
                                hintText: 'Buscar por titulo, VIN o subcategoría',
                                prefixIcon: const material.Icon(material.Icons.search),
                                border: material.OutlineInputBorder(
                                  borderRadius: material.BorderRadius.circular(12),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            ...grouped.entries.map((entry) {
                              return material.Card(
                                child: material.ExpansionTile(
                                  title: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          entry.key,
                                          style: TextStyle(
                                            color: textColor,
                                            fontWeight: material.FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                      material.IconButton(
                                        icon: Icon(
                                          material.Icons.edit,
                                          size: 18,
                                          color: material.Theme.of(
                                            context,
                                          ).primaryColor,
                                        ),
                                        tooltip: 'Editar subcategoría',
                                        onPressed: () =>
                                            _dialogoEditarSubcategoria(entry.key),
                                      ),
                                    ],
                                  ),
                                  children: entry.value.map((m) {
                                    final idAyuda = ayudasIdAyuda(m);
                                    final titulo = ayudasTituloDocumento(m);
                                    final idRev = ayudasIdRevision(m);
                                    final numRev = ayudasNumeroRevision(m);
                                    final vinTxt = ayudasVin(m);
                                    final usuario = (m['Usuario_Subida'] ?? '').toString();
                                    final fecha = ayudasFechaSubida(m);
                                    String fechaStr = '';
                                    if (fecha != null) {
                                      try {
                                        fechaStr = DateFormat('yyyy-MM-dd HH:mm')
                                            .format(DateTime.parse(fecha.toString()));
                                      } catch (_) {
                                        fechaStr = fecha.toString();
                                      }
                                    }
                                    final subtitle = [
                                      if (vinTxt.isNotEmpty) 'VIN: $vinTxt',
                                      'Rev. $numRev',
                                      if (usuario.isNotEmpty) 'Usuario: $usuario',
                                      if (fechaStr.isNotEmpty) fechaStr,
                                    ].join('  ·  ');
                                    return material.Card(
                                      margin: const material.EdgeInsets.fromLTRB(
                                        12,
                                        4,
                                        12,
                                        8,
                                      ),
                                      child: material.ListTile(
                                        leading: Icon(
                                          FluentIcons.pdf,
                                          color: FluentTheme.of(context).accentColor,
                                        ),
                                        title: Text(titulo),
                                        subtitle: Text(subtitle),
                                        trailing: material.IconButton(
                                          icon: Icon(
                                            material.Icons.delete_outline,
                                            color: material.Theme.of(
                                              context,
                                            ).colorScheme.error,
                                          ),
                                          onPressed: () =>
                                              _eliminarDocumento(idAyuda, titulo),
                                        ),
                                        onTap: () {
                                          Navigator.of(context).push(
                                            material.MaterialPageRoute<void>(
                                              builder: (_) => AyudasVisorScreen(
                                                idAyuda: idAyuda,
                                                tituloDocumento: titulo,
                                                idRevisionInicial: idRev,
                                                canUpload: widget.canUpload,
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    );
                                  }).toList(),
                                ),
                              );
                            }),
                          ],
                        ),
          if (widget.canUpload)
            Positioned(
              right: 20,
              bottom: 20,
              child: material.FloatingActionButton.extended(
                onPressed: _dialogoNuevoDocumento,
                shape: material.RoundedRectangleBorder(
                  borderRadius: material.BorderRadius.circular(24.0),
                ),
                icon: const Icon(material.Icons.add),
                label: const Text('Nuevo documento'),
              ),
            ),
        ],
      ),
    );
  }
}
