import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' as material;
import 'package:flutter/widgets.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/api_client.dart';
import '../../services/ayudas_offline_cache_service.dart';
import 'ayudas_api_models.dart';
import 'ayudas_visor_screen.dart';

/// Máximo de tags generados en un solo rango (evita cuelgues y payloads enormes).
const int kAyudasTagsRangoMaximo = 500;

/// Tras cerrar un `showDialog` (p. ej. con ESC), el route puede seguir desmontándose un frame;
/// no desechar [TextEditingController] hasta el siguiente frame para evitar asserts en framework.
void _disposeTextCtrlsAfterRouteClosed(List<TextEditingController> controllers) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    for (final c in controllers) {
      c.dispose();
    }
  });
}

/// Genera etiquetas **sin** `#` (misma convención que chips y API: se guardan sin almohadilla).
/// Ej.: prefijo `JAVH0`, desde `197`, hasta `200` → `JAVH0197` … `JAVH0200`.
/// El ancho de ceros a la izquierda sigue el máximo entre las longitudes de [desdeStr] y [hastaStr].
({List<String> tags, String? error}) ayudasTagsDesdeRango({
  required String prefijoRaw,
  required String desdeStr,
  required String hastaStr,
  int maxCantidad = kAyudasTagsRangoMaximo,
}) {
  final prefijo =
      prefijoRaw.trim().replaceAll('#', '').replaceAll(RegExp(r'\s+'), '');
  final ds = desdeStr.trim();
  final hs = hastaStr.trim();
  if (prefijo.isEmpty) {
    return (tags: const <String>[], error: 'Indica el código base (ej. JAVH0).');
  }
  if (ds.isEmpty || hs.isEmpty) {
    return (tags: const <String>[], error: 'Completa "Desde" y "Hasta" con números.');
  }
  final numRe = RegExp(r'^\d+$');
  if (!numRe.hasMatch(ds) || !numRe.hasMatch(hs)) {
    return (tags: const <String>[], error: 'Desde y hasta deben ser solo dígitos (0-9).');
  }
  final d = int.tryParse(ds);
  final h = int.tryParse(hs);
  if (d == null || h == null) {
    return (tags: const <String>[], error: 'Números inválidos en el rango.');
  }
  if (d > h) {
    return (tags: const <String>[], error: '"Desde" no puede ser mayor que "Hasta".');
  }
  final n = h - d + 1;
  if (n > maxCantidad) {
    return (
      tags: const <String>[],
      error: 'El rango tiene $n etiquetas; el máximo permitido es $maxCantidad.',
    );
  }
  final pad = ds.length > hs.length ? ds.length : hs.length;
  final out = <String>[];
  for (var i = d; i <= h; i++) {
    out.add('$prefijo${i.toString().padLeft(pad, '0')}');
  }
  return (tags: out, error: null);
}

/// Tags tipo identificador de hoja (p. ej. `JAVH0197`): no se usan como "sugeridos".
/// Heurística: al menos 2 letras seguidas solo de dígitos (mín. 3) hasta el final.
bool ayudasTagEsCodigoHojaIdentificador(String tag) {
  final t = tag.trim().replaceAll('#', '');
  if (t.length < 5) return false;
  return RegExp(r'^[A-Za-z]{2,}\d{3,}$').hasMatch(t);
}

Iterable<String> _ayudasTagsSinCodigosHoja(Iterable<String> tags) sync* {
  for (final t in tags) {
    if (!ayudasTagEsCodigoHojaIdentificador(t)) yield t;
  }
}

/// Pantalla 2: documentos de una categoría + nuevo documento.
class AyudasCategoriaScreen extends StatefulWidget {
  const AyudasCategoriaScreen({
    super.key,
    required this.idCategoria,
    required this.nombreCategoria,
    required this.canUpload,
    this.allowRevisionHistory = true,
    this.allowCrossDocumentCompare = true,
  });

  final int idCategoria;
  final String nombreCategoria;
  final bool canUpload;
  final bool allowRevisionHistory;
  final bool allowCrossDocumentCompare;

  @override
  State<AyudasCategoriaScreen> createState() => _AyudasCategoriaScreenState();
}

class _AyudasCategoriaScreenState extends State<AyudasCategoriaScreen> {
  static const List<String> _kSeedTags = ['Soldadura', 'Ensamble', 'Pintura'];

  bool _loading = true;
  String? _error;
  bool _usingOfflineSnapshot = false;
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
      _usingOfflineSnapshot = false;
    });
    try {
      final data = await ApiClient.get('/api/ayudas/lista/${widget.idCategoria}');
      await AyudasOfflineCacheService.instance.saveCategoriaListaSnapshot(
        widget.idCategoria,
        data is List ? data : const <dynamic>[],
      );
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
      final cached = await AyudasOfflineCacheService.instance
          .readCategoriaListaSnapshot(widget.idCategoria);
      if (cached != null) {
        final tags = <String>{..._kSeedTags};
        for (final d in cached) {
          if (d is Map<String, dynamic>) {
            tags.addAll(ayudasTags(d));
          }
        }
        setState(() {
          _docs = cached;
          _tagsEnCategoria = tags.toList()
            ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
          _loading = false;
          _usingOfflineSnapshot = true;
        });
        return;
      }
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
    if (!widget.canUpload) return;
    final tituloCtrl = TextEditingController();
    final subcategoriaCtrl = TextEditingController();
    final revCtrl = TextEditingController();
    final vinCtrl = TextEditingController();
    final nuevoTagCtrl = TextEditingController();
    final prefijoRangoCtrl = TextEditingController();
    final desdeRangoCtrl = TextEditingController();
    final hastaRangoCtrl = TextEditingController();
    String suggestedConsec = '';
    String? pathPdf;
    final poolTags = <String>{
      ..._ayudasTagsSinCodigosHoja(_kSeedTags),
      ..._ayudasTagsSinCodigosHoja(_tagsEnCategoria),
    };
    for (final d in _docs) {
      if (d is Map<String, dynamic>) {
        poolTags.addAll(_ayudasTagsSinCodigosHoja(ayudasTags(d)));
      }
    }
    final tagsOrdenados = poolTags.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final seleccionTags = <String>{};
    var mostrarSugerencias = true;

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

    try {
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
                    const SizedBox(height: 4),
                    material.SwitchListTile(
                      contentPadding: material.EdgeInsets.zero,
                      dense: true,
                      title: const Text('Mostrar sugerencias'),
                      subtitle: const Text(
                        'Semilla, categoría y tags de otros PDFs. Los códigos de hoja (p. ej. JAVH0197) no se sugieren.',
                        style: material.TextStyle(fontSize: 12),
                      ),
                      value: mostrarSugerencias,
                      onChanged: (v) => setLocal(() => mostrarSugerencias = v),
                    ),
                    const SizedBox(height: 6),
                    Builder(
                      builder: (context) {
                        final chips = <String>{...seleccionTags};
                        if (mostrarSugerencias) {
                          chips.addAll(tagsOrdenados);
                        }
                        final ordenados = chips.toList()
                          ..sort(
                            (a, b) => a.toLowerCase().compareTo(b.toLowerCase()),
                          );
                        if (ordenados.isEmpty) {
                          return Text(
                            mostrarSugerencias
                                ? 'Sin etiquetas. Crea una o usa el rango.'
                                : 'Sin etiquetas seleccionadas. Activa sugerencias, crea un # o usa el rango.',
                            style: material.TextStyle(
                              fontSize: 12,
                              color: material.Theme.of(context).hintColor,
                            ),
                          );
                        }
                        return material.Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: ordenados.map((tag) {
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
                        );
                      },
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
                    const SizedBox(height: 14),
                    material.Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        'Rango de #tags (opcional)',
                        style: material.Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Añade varios códigos a la vez (ej. base JAVH0 + de 197 a 200 → JAVH0197…JAVH0200). '
                      'Suma al método manual de arriba.',
                      style: material.TextStyle(
                        fontSize: 12,
                        color: material.Theme.of(context).hintColor,
                      ),
                    ),
                    const SizedBox(height: 8),
                    material.Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: material.TextField(
                            controller: prefijoRangoCtrl,
                            style: material.TextStyle(
                              color: material.Theme.of(context).textTheme.bodyLarge?.color,
                            ),
                            decoration: _inputDec(
                              context,
                              'Código base',
                              hint: 'Ej: JAVH0',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: material.TextField(
                            controller: desdeRangoCtrl,
                            keyboardType: material.TextInputType.number,
                            style: material.TextStyle(
                              color: material.Theme.of(context).textTheme.bodyLarge?.color,
                            ),
                            decoration: _inputDec(
                              context,
                              'Desde',
                              hint: '197',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: material.TextField(
                            controller: hastaRangoCtrl,
                            keyboardType: material.TextInputType.number,
                            style: material.TextStyle(
                              color: material.Theme.of(context).textTheme.bodyLarge?.color,
                            ),
                            decoration: _inputDec(
                              context,
                              'Hasta',
                              hint: '200',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    material.Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: material.OutlinedButton.icon(
                        icon: const material.Icon(material.Icons.playlist_add, size: 18),
                        label: const Text('Agregar # del rango'),
                        onPressed: () {
                          final res = ayudasTagsDesdeRango(
                            prefijoRaw: prefijoRangoCtrl.text,
                            desdeStr: desdeRangoCtrl.text,
                            hastaStr: hastaRangoCtrl.text,
                          );
                          if (res.error != null) {
                            displayInfoBar(
                              ctx,
                              builder: (c, close) => InfoBar(
                                title: const Text('Rango de tags'),
                                content: Text(res.error!),
                                severity: InfoBarSeverity.warning,
                                onClose: close,
                              ),
                            );
                            return;
                          }
                          if (res.tags.isEmpty) return;
                          setLocal(() {
                            for (final t in res.tags) {
                              seleccionTags.add(t);
                            }
                          });
                        },
                      ),
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
    } finally {
      _disposeTextCtrlsAfterRouteClosed([
        tituloCtrl,
        subcategoriaCtrl,
        revCtrl,
        vinCtrl,
        nuevoTagCtrl,
        prefijoRangoCtrl,
        desdeRangoCtrl,
        hastaRangoCtrl,
      ]);
    }
  }

  Future<void> _dialogoEditarSubcategoria(String nombreActual) async {
    if (!widget.canUpload) return;
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
      _disposeTextCtrlsAfterRouteClosed([ctrl]);
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
    if (!widget.canUpload) return;
    final passCtrl = TextEditingController();
    try {
      await showDialog<void>(
        context: context,
        builder: (dCtx) => material.AlertDialog(
          title: const Text('Eliminar documento'),
          content: material.TextField(
            controller: passCtrl,
            obscureText: true,
            decoration: const material.InputDecoration(
              labelText: 'Clave maestra',
            ),
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
                      ApiClient.adminMasterPasswordHeader: passCtrl.text.trim(),
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
      _disposeTextCtrlsAfterRouteClosed([passCtrl]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final grouped = _groupedDocs();
    final textColor = material.Theme.of(context).textTheme.bodyMedium?.color;
    final isDark = FluentTheme.of(context).brightness == Brightness.dark;
    final bg = isDark
        ? const material.Color(0xFF0F1113)
        : const material.Color(0xFFF3F5F9);
    final surface = isDark
        ? const material.Color(0xFF1A1D21)
        : const material.Color(0xFFFFFFFF);
    final border = isDark
        ? const material.Color(0xFF2D3139)
        : const material.Color(0xFFD4DCE8);
    return material.Scaffold(
      backgroundColor: bg,
      appBar: material.AppBar(
        primary: false,
        toolbarHeight: 40,
        titleSpacing: 2,
        backgroundColor: surface,
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
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          children: [
                            if (_usingOfflineSnapshot)
                              const Padding(
                                padding: EdgeInsets.only(bottom: 8),
                                child: InfoBar(
                                  title: Text('Sin conexión'),
                                  content: Text(
                                    'Mostrando la última copia guardada de esta categoría.',
                                  ),
                                  severity: InfoBarSeverity.warning,
                                ),
                              ),
                            ...grouped.entries.map((entry) {
                              return material.Card(
                                color: surface,
                                shape: material.RoundedRectangleBorder(
                                  borderRadius: material.BorderRadius.circular(12),
                                  side: material.BorderSide(color: border),
                                ),
                                child: material.ExpansionTile(
                                  collapsedBackgroundColor: surface,
                                  backgroundColor: surface,
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
                                      if (widget.canUpload)
                                        material.IconButton(
                                          icon: Icon(
                                            material.Icons.edit,
                                            size: 18,
                                            color: material.Theme.of(
                                              context,
                                            ).primaryColor,
                                          ),
                                          tooltip: 'Editar subcategoría',
                                          onPressed: () => _dialogoEditarSubcategoria(
                                            entry.key,
                                          ),
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
                                      color: isDark
                                          ? const material.Color(0xFF151920)
                                          : const material.Color(0xFFF8FAFD),
                                      margin: const material.EdgeInsets.fromLTRB(
                                        12,
                                        4,
                                        12,
                                        8,
                                      ),
                                      shape: material.RoundedRectangleBorder(
                                        borderRadius: material.BorderRadius.circular(10),
                                        side: material.BorderSide(color: border),
                                      ),
                                      child: material.ListTile(
                                        isThreeLine: true,
                                        dense: false,
                                        minVerticalPadding: 12,
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
                                        trailing: widget.canUpload
                                            ? material.IconButton(
                                                icon: Icon(
                                                  material.Icons.delete_outline,
                                                  color: material.Theme.of(
                                                    context,
                                                  ).colorScheme.error,
                                                ),
                                                onPressed: () =>
                                                    _eliminarDocumento(
                                                      idAyuda,
                                                      titulo,
                                                    ),
                                              )
                                            : null,
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
                                                allowCrossDocumentCompare: widget
                                                    .allowCrossDocumentCompare,
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
