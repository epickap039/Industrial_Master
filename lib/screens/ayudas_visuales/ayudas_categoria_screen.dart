import 'dart:convert';

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
    this.allowRevisionHistory = true,
  });

  final int idCategoria;
  final String nombreCategoria;
  final bool canUpload;
  final bool allowRevisionHistory;

  @override
  State<AyudasCategoriaScreen> createState() => _AyudasCategoriaScreenState();
}

class _AyudasCategoriaScreenState extends State<AyudasCategoriaScreen> {
  static const List<String> _kSeedTags = ['Soldadura', 'Ensamble', 'Pintura'];

  bool _loading = true;
  String? _error;
  List<dynamic> _docs = [];
  List<String> _tagsEnCategoria = [];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await ApiClient.get('/api/ayudas/lista/${widget.idCategoria}');
      List<String> tagsApi = [];
      try {
        final tjson = await ApiClient.get('/api/ayudas/tags/${widget.idCategoria}');
        if (tjson is List) {
          tagsApi = tjson.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
        }
      } catch (_) {}
      setState(() {
        _docs = data is List ? data : [];
        _tagsEnCategoria = tagsApi;
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
    final revCtrl = TextEditingController();
    final vinCtrl = TextEditingController();
    final nuevoTagCtrl = TextEditingController();
    String suggestedConsec = '';
    String? pathPdf;
    final poolTags = <String>{..._kSeedTags, ..._tagsEnCategoria};
    for (final d in _docs) {
      if (d is Map<String, dynamic>) poolTags.addAll(ayudasTags(d));
    }
    final tagsOrdenados = poolTags.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final seleccionTags = <String>{};

    try {
      final raw = await ApiClient.get('/api/ayudas/consecutivo/siguiente');
      if (raw is Map) {
        final s = '${raw['sugerido'] ?? ''}'.trim();
        if (s.isNotEmpty) {
          suggestedConsec = s;
          revCtrl.text = s;
        }
      }
    } catch (_) {}

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
                      decoration: _inputDec(
                        context,
                        'Consecutivo único',
                        hint: suggestedConsec.isEmpty
                            ? 'Ej: AV-000123'
                            : 'Sugerido: $suggestedConsec',
                      ),
                    ),
                    if (suggestedConsec.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Sugerencia actual: $suggestedConsec',
                        style: material.TextStyle(
                          fontSize: 12,
                          color: material.Theme.of(context).hintColor,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    material.Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        'Etiquetas (#hashtags)',
                        style: material.Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    const SizedBox(height: 6),
                    material.Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: tagsOrdenados.map((tag) {
                        final sel = seleccionTags.contains(tag);
                        return material.FilterChip(
                          label: Text('#$tag'),
                          selected: sel,
                          onSelected: (v) {
                            setLocal(() {
                              if (v) {
                                seleccionTags.add(tag);
                              } else {
                                seleccionTags.remove(tag);
                              }
                            });
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 8),
                    material.TextField(
                      controller: nuevoTagCtrl,
                      style: material.TextStyle(
                        color: material.Theme.of(context).textTheme.bodyLarge?.color,
                      ),
                      decoration: _inputDec(
                        context,
                        'Crear nuevo #tag',
                        hint: 'Escribe y pulsa Enter',
                      ).copyWith(
                        suffixIcon: material.IconButton(
                          icon: const material.Icon(material.Icons.add),
                          onPressed: () {
                            final raw = nuevoTagCtrl.text.trim().replaceAll('#', '');
                            if (raw.isEmpty) return;
                            setLocal(() {
                              seleccionTags.add(raw);
                              if (!tagsOrdenados.contains(raw)) {
                                tagsOrdenados.add(raw);
                                tagsOrdenados.sort(
                                  (a, b) => a.toLowerCase().compareTo(b.toLowerCase()),
                                );
                              }
                              nuevoTagCtrl.clear();
                            });
                          },
                        ),
                      ),
                      onSubmitted: (_) {
                        final raw = nuevoTagCtrl.text.trim().replaceAll('#', '');
                        if (raw.isEmpty) return;
                        setLocal(() {
                          seleccionTags.add(raw);
                          if (!tagsOrdenados.contains(raw)) {
                            tagsOrdenados.add(raw);
                            tagsOrdenados.sort(
                              (a, b) => a.toLowerCase().compareTo(b.toLowerCase()),
                            );
                          }
                          nuevoTagCtrl.clear();
                        });
                      },
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
                final consec = revCtrl.text.trim();
                if (t.isEmpty || pathPdf == null || consec.isEmpty) return;
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
                    'numero_revision': consec,
                    'consecutivo': consec,
                    'usuario': user,
                  };
                  if (subcategoriaCtrl.text.trim().isNotEmpty) {
                    fields['subcategoria'] = subcategoriaCtrl.text;
                  }
                  final v = vinCtrl.text.trim();
                  if (v.isNotEmpty) fields['vin'] = v;
                  if (seleccionTags.isNotEmpty) {
                    fields['tags'] = jsonEncode(seleccionTags.toList());
                  }
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
    nuevoTagCtrl.dispose();
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
    final out = <String, List<Map<String, dynamic>>>{};
    for (final d in _docs) {
      if (d is! Map<String, dynamic>) continue;
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
                Navigator.pop(dCtx);
                try {
                  final prefs = await SharedPreferences.getInstance();
                  final user = prefs.getString('username')?.trim() ?? 'Operador';
                  await ApiClient.delete(
                    '/api/ayudas/documento/$idAyuda',
                    headers: {
                      'X-Usuario': user,
                      ApiClient.adminMasterPasswordHeader: passCtrl.text,
                    },
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
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                          children: [
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
                                    final tagList = ayudasTags(m);
                                    final metaLine = [
                                      if (vinTxt.isNotEmpty) 'VIN: $vinTxt',
                                      'Rev. $numRev',
                                      if (usuario.isNotEmpty) 'Usuario: $usuario',
                                    ].join('  ·  ');
                                    final hintColor =
                                        material.Theme.of(context).hintColor;
                                    return material.Card(
                                      margin: const material.EdgeInsets.fromLTRB(
                                        12,
                                        4,
                                        12,
                                        8,
                                      ),
                                      child: material.ListTile(
                                        isThreeLine: true,
                                        dense: true,
                                        leading: Icon(
                                          FluentIcons.pdf,
                                          color: FluentTheme.of(context).accentColor,
                                        ),
                                        title: material.Text(titulo),
                                        subtitle: Column(
                                          crossAxisAlignment:
                                              material.CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (metaLine.isNotEmpty)
                                              material.Text(
                                                metaLine,
                                                style: material.TextStyle(
                                                  fontSize: 12,
                                                  color: material.Theme.of(context)
                                                      .textTheme
                                                      .bodySmall
                                                      ?.color,
                                                ),
                                              ),
                                            material.Wrap(
                                              spacing: 6,
                                              runSpacing: 4,
                                              crossAxisAlignment:
                                                  material.WrapCrossAlignment
                                                      .center,
                                              children: [
                                                if (fechaStr.isNotEmpty)
                                                  material.Text(
                                                    fechaStr,
                                                    style: material.TextStyle(
                                                      fontSize: 12.5,
                                                      color: material.Theme.of(
                                                            context,
                                                          )
                                                          .textTheme
                                                          .bodySmall
                                                          ?.color,
                                                    ),
                                                  ),
                                                ...tagList.map(
                                                  (tg) => material.Text(
                                                    '#$tg',
                                                    style: material.TextStyle(
                                                      fontSize: 10,
                                                      height: 1.2,
                                                      color: hintColor,
                                                      fontWeight:
                                                          material.FontWeight.w500,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
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
                                                allowRevisionHistory:
                                                    widget.allowRevisionHistory,
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
                heroTag: 'ayudas_categoria_nuevo_documento',
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
