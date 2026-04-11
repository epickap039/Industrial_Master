import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' as material;
import 'package:fluent_ui/fluent_ui.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/api_client.dart';
import '../../services/main_nav.dart';
import '../../theme/app_themes.dart';
import '../../widgets/compact_page_header.dart';
import '../../widgets/contextual_bug_report.dart';
import 'ayudas_api_models.dart';
import 'ayudas_categoria_screen.dart';
import 'ayudas_search_utils.dart';
import 'ayudas_visor_screen.dart';

IconData _obtenerIcono(String? codigo) {
  switch (codigo?.toLowerCase().trim()) {
    case 'build':
      return material.Icons.build;
    case 'bolt':
      return material.Icons.bolt;
    case 'format_paint':
      return material.Icons.format_paint;
    case 'water_drop':
      return material.Icons.water_drop;
    case 'whatshot':
      return material.Icons.whatshot;
    case 'brush':
      return material.Icons.brush;
    case 'security':
      return material.Icons.security;
    case 'info':
      return material.Icons.info;
    default:
      return material.Icons.folder_copy_outlined;
  }
}

Uint8List? _decodeIconPng(dynamic raw) {
  final s = raw == null ? '' : raw.toString().trim();
  if (s.isEmpty) return null;
  try {
    return base64Decode(s);
  } catch (_) {
    return null;
  }
}

String? _validateCategoriaPng(Uint8List bytes) {
  const maxBytes = 512 * 1024;
  if (bytes.isEmpty) return 'La imagen está vacía.';
  if (bytes.lengthInBytes > maxBytes) {
    return 'La imagen excede 512KB. Selecciona una imagen PNG más ligera.';
  }
  if (bytes.lengthInBytes < 8) return 'Archivo PNG inválido.';
  const sig = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  for (var i = 0; i < sig.length; i++) {
    if (bytes[i] != sig[i]) {
      return 'Formato inválido: solo se permiten imágenes PNG válidas.';
    }
  }
  return null;
}

/// Pantalla 1: menú de categorías (grid grande con iconos).
class AyudasMenuScreen extends StatefulWidget {
  const AyudasMenuScreen({
    super.key,
    required this.canUpload,
    this.canEditCategoryImage = false,
    this.allowRevisionHistory = true,
  });

  final bool canUpload;
  final bool canEditCategoryImage;
  final bool allowRevisionHistory;

  @override
  State<AyudasMenuScreen> createState() => _AyudasMenuScreenState();
}

class _AyudasMenuScreenState extends State<AyudasMenuScreen> {
  static const List<String> _kSeedTags = ['Soldadura', 'Ensamble', 'Pintura'];

  late final VoidCallback _lobbyOpenListener;

  bool _loading = true;
  String? _error;
  List<dynamic> _categorias = [];
  bool _loadingIndice = false;
  List<Map<String, dynamic>> _todosDocumentos = [];
  final material.TextEditingController _searchCtrl = material.TextEditingController();

  void _showIconValidationError(String msg) {
    if (!mounted) return;
    displayInfoBar(
      context,
      builder: (c, close) => InfoBar(
        title: const Text('Ícono no válido'),
        content: Text(msg),
        severity: InfoBarSeverity.warning,
        onClose: close,
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _lobbyOpenListener = _drainLobbyOpenIntent;
    MainNav.ayudaLobbyOpenSignal.addListener(_lobbyOpenListener);
    _searchCtrl.addListener(() {
      if (mounted) setState(() {});
    });
    _cargar();
    WidgetsBinding.instance.addPostFrameCallback((_) => _drainLobbyOpenIntent());
  }

  @override
  void dispose() {
    MainNav.ayudaLobbyOpenSignal.removeListener(_lobbyOpenListener);
    _searchCtrl.dispose();
    super.dispose();
  }

  void _drainLobbyOpenIntent() {
    final intent = MainNav.takePendingAyudaLobby();
    if (intent == null || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).push(
        material.MaterialPageRoute<void>(
          builder: (_) => AyudasVisorScreen(
            idAyuda: intent.idAyuda,
            tituloDocumento: intent.tituloDocumento,
            idRevisionInicial: intent.idRevision,
            canUpload: widget.canUpload,
            allowRevisionHistory: widget.allowRevisionHistory,
          ),
        ),
      );
    });
  }

  Future<void> _cargar() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await ApiClient.get('/api/ayudas/categorias');
      final list = data is List ? data : <dynamic>[];
      setState(() {
        _categorias = list;
        _loading = false;
      });
      await _cargarIndiceDocumentos();
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _cargarIndiceDocumentos() async {
    if (_categorias.isEmpty) {
      setState(() => _todosDocumentos = []);
      return;
    }
    setState(() => _loadingIndice = true);
    try {
      final futures = <Future<List<Map<String, dynamic>>>>[];
      for (final c in _categorias) {
        if (c is! Map<String, dynamic>) continue;
        final idRaw = c['ID_Categoria'];
        final idCat = idRaw is int ? idRaw : int.tryParse('$idRaw') ?? 0;
        final nombre = (c['Nombre_Categoria'] ?? '').toString();
        futures.add(() async {
          final data = await ApiClient.get('/api/ayudas/lista/$idCat');
          final raw = data is List ? data : <dynamic>[];
          return raw
              .whereType<Map>()
              .map((d) {
                final m = Map<String, dynamic>.from(d);
                m['_id_categoria'] = idCat;
                m['_nombre_categoria'] = nombre;
                return m;
              })
              .toList();
        }());
      }
      final lists = await Future.wait(futures);
      final flat = <Map<String, dynamic>>[];
      for (final l in lists) {
        flat.addAll(l);
      }
      if (mounted) {
        setState(() {
          _todosDocumentos = flat;
          _loadingIndice = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingIndice = false);
    }
  }

  List<String> _poolTagsBusqueda() {
    final s = <String>{..._kSeedTags, ...ayudasAllTagsFromDocs(_todosDocumentos)};
    return s.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  List<Map<String, dynamic>> _documentosFiltrados() {
    final q = _searchCtrl.text;
    if (q.trim().isEmpty) return [];
    var list = _todosDocumentos
        .where((d) => ayudasDocumentMatchesQuery(d, q))
        .toList();
    final qLow = q.trim().toLowerCase();
    if (qLow.contains('#')) {
      list.sort((a, b) {
        final c = ayudasMatchScoreForQuery(b, q).compareTo(
          ayudasMatchScoreForQuery(a, q),
        );
        if (c != 0) return c;
        return ayudasTituloDocumento(a).toLowerCase().compareTo(
              ayudasTituloDocumento(b).toLowerCase(),
            );
      });
    } else {
      list.sort((a, b) => ayudasTituloDocumento(a).toLowerCase().compareTo(
            ayudasTituloDocumento(b).toLowerCase(),
          ));
    }
    return list;
  }

  void _aplicarSugerenciaTag(String tag) {
    final t = _searchCtrl.text;
    final replaced = t.replaceFirst(RegExp(r'#\w*$'), '#$tag ');
    _searchCtrl.value = material.TextEditingValue(
      text: replaced,
      selection: material.TextSelection.collapsed(offset: replaced.length),
    );
  }

  String _fechaSubidaStr(Map<String, dynamic> m) {
    final fecha = ayudasFechaSubida(m);
    if (fecha == null) return '';
    try {
      return DateFormat('yyyy-MM-dd HH:mm')
          .format(DateTime.parse(fecha.toString()));
    } catch (_) {
      return fecha.toString();
    }
  }

  Widget _buildResultadosBusqueda(BuildContext context) {
    final filtrados = _documentosFiltrados();
    final hintColor = material.Theme.of(context).hintColor;
    if (filtrados.isEmpty) {
      return Center(
        child: Text(
          _loadingIndice
              ? 'Cargando índice de documentos…'
              : 'Sin resultados para esta búsqueda.',
          style: TextStyle(color: FluentTheme.of(context).inactiveColor),
        ),
      );
    }
    return material.ListView.separated(
      itemCount: filtrados.length,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (context, i) {
        final m = filtrados[i];
        final titulo = ayudasTituloDocumento(m);
        final idAyuda = ayudasIdAyuda(m);
        final idRev = ayudasIdRevision(m);
        final cat =
            (m['_nombre_categoria'] ?? '').toString();
        final fechaStr = _fechaSubidaStr(m);
        final tags = ayudasTags(m);
        return material.Card(
          margin: material.EdgeInsets.zero,
          child: material.ListTile(
            dense: true,
            leading: Icon(
              FluentIcons.pdf,
              color: FluentTheme.of(context).accentColor,
            ),
            title: material.Text(
              titulo,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Column(
              crossAxisAlignment: material.CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (cat.isNotEmpty)
                  material.Text(
                    cat,
                    style: material.TextStyle(
                      fontSize: 12,
                      fontWeight: material.FontWeight.w600,
                      color: material.Theme.of(context).colorScheme.secondary,
                    ),
                  ),
                material.Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: material.WrapCrossAlignment.center,
                  children: [
                    if (fechaStr.isNotEmpty)
                      material.Text(
                        fechaStr,
                        style: material.TextStyle(
                          fontSize: 12.5,
                          color: material.Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.color,
                        ),
                      ),
                    ...tags.map(
                      (tg) => material.Text(
                        '#$tg',
                        style: material.TextStyle(
                          fontSize: 10,
                          height: 1.2,
                          color: hintColor,
                          fontWeight: material.FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            onTap: () {
              Navigator.of(context).push(
                material.MaterialPageRoute<void>(
                  builder: (_) => AyudasVisorScreen(
                    idAyuda: idAyuda,
                    tituloDocumento: titulo,
                    idRevisionInicial: idRev,
                    canUpload: widget.canUpload,
                    allowRevisionHistory: widget.allowRevisionHistory,
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _dialogoNuevaCategoria() async {
    final nombreCtrl = TextEditingController();
    final iconoCtrl = TextEditingController();
    Uint8List? iconoPngBytes;
    String? iconoPngB64;
    try {
      await showDialog<void>(
        context: context,
        builder: (ctx) {
          return ContentDialog(
            title: const Text('Nueva categoría'),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Nombre'),
                const SizedBox(height: 6),
                TextBox(controller: nombreCtrl, placeholder: 'Ej. Mecánico'),
                const SizedBox(height: 12),
                const Text('Código de icono (opcional)'),
                const SizedBox(height: 6),
                TextBox(
                  controller: iconoCtrl,
                  placeholder: 'mecanico, electrico…',
                ),
                const SizedBox(height: 12),
                const Text('Ícono PNG (opcional)'),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: FluentTheme.of(context).inactiveColor,
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: iconoPngBytes == null
                          ? const Icon(FluentIcons.picture, size: 14)
                          : Image.memory(iconoPngBytes!, fit: BoxFit.cover),
                    ),
                    const SizedBox(width: 8),
                    Button(
                      child: const Text('Seleccionar PNG'),
                      onPressed: () async {
                        final r = await FilePicker.platform.pickFiles(
                          type: FileType.custom,
                          allowMultiple: false,
                          allowedExtensions: ['png'],
                          withData: true,
                        );
                        if (r == null || r.files.isEmpty) return;
                        Uint8List? bytes = r.files.single.bytes;
                        final path = r.files.single.path;
                        if (bytes == null && path != null && path.isNotEmpty) {
                          bytes = await File(path).readAsBytes();
                        }
                        if (bytes == null || bytes.isEmpty) return;
                        final validation = _validateCategoriaPng(bytes);
                        if (validation != null) {
                          _showIconValidationError(validation);
                          return;
                        }
                        final b64 = base64Encode(bytes);
                        iconoPngBytes = bytes;
                        iconoPngB64 = b64;
                        (ctx as Element).markNeedsBuild();
                      },
                    ),
                  ],
                ),
              ],
            ),
            actions: [
              Button(
                child: const Text('Cancelar'),
                onPressed: () => Navigator.pop(ctx),
              ),
              FilledButton(
                child: const Text('Crear'),
                onPressed: () async {
                  final n = nombreCtrl.text.trim();
                  if (n.isEmpty) return;
                  final prefs = await SharedPreferences.getInstance();
                  final user =
                      prefs.getString('username')?.trim() ?? 'Operador';
                  showDialog<void>(
                    context: context,
                    barrierDismissible: false,
                    builder: (lc) => const ContentDialog(
                      title: Text('Guardando…'),
                      content: Center(
                        child: SizedBox(height: 80, child: ProgressRing()),
                      ),
                    ),
                  );
                  try {
                    await ApiClient.post(
                      '/api/ayudas/categorias',
                      body: {
                        'nombre': n,
                        'icono': iconoCtrl.text.trim(),
                        if (iconoPngB64 != null && iconoPngB64!.isNotEmpty)
                          'icono_png_base64': iconoPngB64,
                      },
                      headers: {'X-Usuario': user},
                    );
                    if (!mounted) return;
                    Navigator.of(context, rootNavigator: true).pop();
                    Navigator.of(context, rootNavigator: true).pop();
                    await _cargar();
                    if (mounted) {
                      displayInfoBar(context, builder: (c, close) {
                        return InfoBar(
                          title: const Text('Listo'),
                          content: const Text('Categoría creada.'),
                          severity: InfoBarSeverity.success,
                          onClose: close,
                        );
                      });
                    }
                  } catch (e) {
                    if (!mounted) return;
                    Navigator.of(context, rootNavigator: true).pop();
                    material.ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                      material.SnackBar(
                        content: Text('$e'),
                        backgroundColor: material.Colors.red.shade800,
                      ),
                    );
                  }
                },
              ),
            ],
          );
        },
      );
    } finally {
      nombreCtrl.dispose();
      iconoCtrl.dispose();
    }
  }

  Future<void> _dialogoEditarImagenCategoria(Map<String, dynamic> row) async {
    if (!widget.canEditCategoryImage) return;
    final idRaw = row['ID_Categoria'];
    final idCategoria = idRaw is int ? idRaw : int.tryParse('$idRaw') ?? 0;
    if (idCategoria <= 0) return;
    final nombre = (row['Nombre_Categoria'] ?? 'Categoría').toString().trim();
    final iconoCtrl = TextEditingController(
      text: (row['Icono_Codigo'] ?? '').toString(),
    );
    Uint8List? iconoPngBytes =
        _decodeIconPng(row['Icono_Png_Base64'] ?? row['icono_png_base64']);
    String? iconoPngB64 = iconoPngBytes == null ? null : base64Encode(iconoPngBytes);
    try {
      await showDialog<void>(
        context: context,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (context, setLocalState) {
              return ContentDialog(
                title: Text('Editar imagen: $nombre'),
                content: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Código de icono (opcional)'),
                    const SizedBox(height: 6),
                    TextBox(controller: iconoCtrl, placeholder: 'mecanico, electrico…'),
                    const SizedBox(height: 12),
                    const Text('Ícono PNG (opcional)'),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: FluentTheme.of(context).inactiveColor,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: iconoPngBytes == null
                              ? const Icon(FluentIcons.picture, size: 16)
                              : Image.memory(iconoPngBytes!, fit: BoxFit.cover),
                        ),
                        const SizedBox(width: 8),
                        Button(
                          child: const Text('Cambiar PNG'),
                          onPressed: () async {
                            final r = await FilePicker.platform.pickFiles(
                              type: FileType.custom,
                              allowMultiple: false,
                              allowedExtensions: ['png'],
                              withData: true,
                            );
                            if (r == null || r.files.isEmpty) return;
                            Uint8List? bytes = r.files.single.bytes;
                            final path = r.files.single.path;
                            if (bytes == null && path != null && path.isNotEmpty) {
                              bytes = await File(path).readAsBytes();
                            }
                            if (bytes == null || bytes.isEmpty) return;
                            final validation = _validateCategoriaPng(bytes);
                            if (validation != null) {
                              _showIconValidationError(validation);
                              return;
                            }
                            setLocalState(() {
                              iconoPngBytes = bytes;
                              iconoPngB64 = base64Encode(bytes!);
                            });
                          },
                        ),
                        const SizedBox(width: 8),
                        if (iconoPngBytes != null)
                          IconButton(
                            icon: const Icon(FluentIcons.clear, size: 14),
                            onPressed: () {
                              setLocalState(() {
                                iconoPngBytes = null;
                                iconoPngB64 = '';
                              });
                            },
                          ),
                      ],
                    ),
                  ],
                ),
                actions: [
                  Button(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancelar'),
                  ),
                  FilledButton(
                    child: const Text('Guardar'),
                    onPressed: () async {
                      final prefs = await SharedPreferences.getInstance();
                      final user = prefs.getString('username')?.trim() ?? 'Operador';
                      showDialog<void>(
                        context: context,
                        barrierDismissible: false,
                        builder: (lc) => const ContentDialog(
                          title: Text('Guardando…'),
                          content: Center(
                            child: SizedBox(height: 80, child: ProgressRing()),
                          ),
                        ),
                      );
                      try {
                        final body = <String, dynamic>{
                          'icono': iconoCtrl.text.trim(),
                        };
                        if (iconoPngB64 != null) {
                          body['icono_png_base64'] = iconoPngB64;
                        }
                        await ApiClient.put(
                          '/api/ayudas/categorias/$idCategoria',
                          body: body,
                          headers: {'X-Usuario': user},
                        );
                        if (!mounted) return;
                        Navigator.of(context, rootNavigator: true).pop();
                        Navigator.of(context, rootNavigator: true).pop();
                        await _cargar();
                        if (!mounted) return;
                        displayInfoBar(
                          context,
                          builder: (c, close) => InfoBar(
                            title: const Text('Listo'),
                            content: const Text('Imagen de categoría actualizada.'),
                            severity: InfoBarSeverity.success,
                            onClose: close,
                          ),
                        );
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
        },
      );
    } finally {
      iconoCtrl.dispose();
    }
  }

  Future<void> _abrirSelectorCategoriaEditarImagen() async {
    if (!widget.canEditCategoryImage || _categorias.isEmpty) return;
    Map<String, dynamic>? selected =
        _categorias.first as Map<String, dynamic>;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setLocalState) {
            return ContentDialog(
              title: const Text('Editar imagen de categoría'),
              content: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Selecciona una categoría'),
                  const SizedBox(height: 8),
                  ComboBox<Map<String, dynamic>>(
                    value: selected,
                    items: _categorias
                        .whereType<Map<String, dynamic>>()
                        .map(
                          (row) => ComboBoxItem<Map<String, dynamic>>(
                            value: row,
                            child: Text(
                              (row['Nombre_Categoria'] ?? 'Sin nombre').toString(),
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (v) {
                      if (v == null) return;
                      setLocalState(() => selected = v);
                    },
                  ),
                ],
              ),
              actions: [
                Button(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed: () async {
                    final row = selected;
                    Navigator.pop(ctx);
                    if (row == null) return;
                    await _dialogoEditarImagenCategoria(row);
                  },
                  child: const Text('Continuar'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  bool _esModoCiberpunk(BuildContext context) {
    if (appTheme.currentMode == AppThemeMode.cyberpunk) return true;
    final theme = FluentTheme.of(context);
    return theme.brightness == Brightness.dark &&
        theme.typography.body?.fontFamily == 'Consolas';
  }

  @override
  Widget build(BuildContext context) {
    final isCyberpunk = _esModoCiberpunk(context);
    return ScaffoldPage(
      header: CompactPageHeader(
        title: const Text('Ayudas visuales'),
        commandBar: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(FluentIcons.bug),
              onPressed: () => showContextualBugReportDialog(
                context,
                modulo: 'Ayudas Visuales',
                contextoPantalla: 'ayudas_menu',
              ),
            ),
            IconButton(
              icon: const Icon(FluentIcons.refresh),
              onPressed: _loading ? null : _cargar,
            ),
          ],
        ),
      ),
      content: Stack(
        children: [
          _loading
              ? const Center(child: ProgressRing())
              : _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_error!, style: TextStyle(color: Colors.red)),
                            const SizedBox(height: 12),
                            FilledButton(
                              onPressed: _cargar,
                              child: const Text('Reintentar'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 6, 20, 8),
                          child: material.Material(
                            color: material.Colors.transparent,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                material.TextField(
                                  controller: _searchCtrl,
                                  decoration: material.InputDecoration(
                                    hintText:
                                        'Buscar en todas las categorías: título, VIN, #etiqueta…',
                                    prefixIcon: const material.Icon(
                                      material.Icons.search,
                                    ),
                                    border: material.OutlineInputBorder(
                                      borderRadius:
                                          material.BorderRadius.circular(12),
                                    ),
                                    isDense: true,
                                  ),
                                ),
                                if (_loadingIndice)
                                  const Padding(
                                    padding: EdgeInsets.only(top: 6),
                                    child: SizedBox(
                                      height: 2,
                                      child: material.LinearProgressIndicator(),
                                    ),
                                  ),
                                if (ayudasTagSuggestionsForQuery(
                                      _searchCtrl.text,
                                      _poolTagsBusqueda(),
                                    ).isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  material.Align(
                                    alignment:
                                        AlignmentDirectional.centerStart,
                                    child: Text(
                                      'Sugerencias de etiquetas',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: FluentTheme.of(context)
                                            .inactiveColor,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  material.Wrap(
                                    spacing: 6,
                                    runSpacing: 6,
                                    children: ayudasTagSuggestionsForQuery(
                                      _searchCtrl.text,
                                      _poolTagsBusqueda(),
                                    )
                                        .map(
                                          (tag) => material.ActionChip(
                                            label: material.Text('#$tag'),
                                            onPressed: () =>
                                                _aplicarSugerenciaTag(tag),
                                          ),
                                        )
                                        .toList(),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                            child: _searchCtrl.text.trim().isEmpty
                                ? LayoutBuilder(
                                    builder: (context, c) {
                                      final cols = c.maxWidth >= 1000
                                          ? 4
                                          : c.maxWidth >= 700
                                              ? 3
                                              : 2;
                                      return GridView.builder(
                                        gridDelegate:
                                            SliverGridDelegateWithFixedCrossAxisCount(
                                          crossAxisCount: cols,
                                          mainAxisSpacing: 16,
                                          crossAxisSpacing: 16,
                                          childAspectRatio: 1.15,
                                        ),
                                        itemCount: _categorias.length,
                                        itemBuilder: (context, i) {
                                          final row = _categorias[i]
                                              as Map<String, dynamic>;
                                          final id = row['ID_Categoria'];
                                          final nombre =
                                              (row['Nombre_Categoria'] ??
                                                      'Sin nombre')
                                                  .toString();
                                          final icono =
                                              row['Icono_Codigo']?.toString();
                                          final iconoPng = _decodeIconPng(
                                            row['Icono_Png_Base64'] ??
                                                row['icono_png_base64'],
                                          );
                                          return _CategoriaTile(
                                            titulo: nombre,
                                            icon: _obtenerIcono(icono),
                                            iconPng: iconoPng,
                                            isCyberpunk: isCyberpunk,
                                            onTap: () {
                                              Navigator.of(context).push(
                                                material.MaterialPageRoute<void>(
                                                  builder: (_) =>
                                                      AyudasCategoriaScreen(
                                                    idCategoria: id is int
                                                        ? id
                                                        : int.tryParse(
                                                                '$id',
                                                              ) ??
                                                              0,
                                                    nombreCategoria: nombre,
                                                    canUpload: widget.canUpload,
                                                    allowRevisionHistory:
                                                        widget
                                                            .allowRevisionHistory,
                                                  ),
                                                ),
                                              );
                                            },
                                          );
                                        },
                                      );
                                    },
                                  )
                                : _buildResultadosBusqueda(context),
                          ),
                        ),
                      ],
                    ),
          if (widget.canUpload || widget.canEditCategoryImage)
            Positioned(
              right: 20,
              bottom: 20,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.canEditCategoryImage) ...[
                    material.FloatingActionButton.extended(
                      heroTag: 'ayudas_menu_editar_imagen_categoria',
                      onPressed: _abrirSelectorCategoriaEditarImagen,
                      shape: material.RoundedRectangleBorder(
                        borderRadius: material.BorderRadius.circular(24.0),
                      ),
                      icon: const Icon(material.Icons.photo_camera_outlined),
                      label: const Text('Editar imagen categoría'),
                    ),
                    const SizedBox(height: 10),
                  ],
                  if (widget.canUpload)
                    material.FloatingActionButton.extended(
                      heroTag: 'ayudas_menu_nueva_categoria',
                      onPressed: _dialogoNuevaCategoria,
                      shape: material.RoundedRectangleBorder(
                        borderRadius: material.BorderRadius.circular(24.0),
                      ),
                      icon: const Icon(material.Icons.add),
                      label: const Text('Nueva categoría'),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _CategoriaTile extends StatelessWidget {
  const _CategoriaTile({
    required this.titulo,
    required this.icon,
    required this.iconPng,
    required this.isCyberpunk,
    required this.onTap,
  });

  final String titulo;
  final IconData icon;
  final Uint8List? iconPng;
  final bool isCyberpunk;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = material.Theme.of(context).brightness == material.Brightness.dark;
    final borderRadius = material.BorderRadius.circular(
      isCyberpunk ? 4.0 : 24.0,
    );
    final neonColors = <Color>[
      const Color(0xFF00E5FF), // cyan
      const Color(0xFFFF00D4), // magenta
      const Color(0xFFB7FF00), // lima
    ];
    final neonIndex = titulo.runes.fold<int>(0, (a, b) => a + b) %
        neonColors.length;
    final iconColor = isCyberpunk
        ? neonColors[neonIndex]
        : isDark
            ? material.Theme.of(context).colorScheme.secondary
            : material.Theme.of(context).primaryColor;

    return material.Card(
      elevation: 4.0,
      shape: material.RoundedRectangleBorder(
        borderRadius: borderRadius,
      ),
      child: material.InkWell(
        onTap: onTap,
        borderRadius: borderRadius,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (iconPng != null)
                Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: iconColor.withValues(alpha: 0.4)),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Image.memory(iconPng!, fit: BoxFit.cover),
                )
              else
                Icon(
                  icon,
                  size: 56.0,
                  color: iconColor,
                ),
              const SizedBox(height: 12),
              Text(
                titulo,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: FluentTheme.of(context).typography.bodyStrong,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
