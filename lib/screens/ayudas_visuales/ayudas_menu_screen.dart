import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart' as material;
import 'package:flutter/widgets.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/api_client.dart';
import '../../services/ayudas_offline_cache_service.dart';
import '../../services/main_nav.dart';
import '../../theme/app_themes.dart';
import '../../widgets/compact_page_header.dart';
import 'ayudas_api_models.dart';
import 'ayudas_categoria_screen.dart';
import 'ayudas_search_utils.dart';
import 'ayudas_visor_screen.dart';

void _disposeTextCtrlsAfterRouteClosed(List<TextEditingController> controllers) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    for (final c in controllers) {
      c.dispose();
    }
  });
}

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
  return _decodeImageBase64(raw);
}

Uint8List? _decodeIconIco(dynamic raw) {
  return _decodeImageBase64(raw);
}

Uint8List? _decodeImageBase64(dynamic raw) {
  final s = raw == null ? '' : raw.toString().trim();
  if (s.isEmpty) return null;
  try {
    return base64Decode(s);
  } catch (_) {
    return null;
  }
}

/// Etiqueta tipo REF de la referencia visual (id estable o nombre abreviado).
String _refEtiquetaAyudaCategoria(dynamic id, String nombre) {
  final idNum = id is int ? id : int.tryParse('$id');
  if (idNum != null && idNum > 0) {
    return 'REF-$idNum';
  }
  final u = nombre.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]+'), '-');
  final clean = u
      .replaceAll(RegExp(r'-+'), '-')
      .replaceFirst(RegExp(r'^-+'), '')
      .replaceFirst(RegExp(r'-+$'), '');
  if (clean.isEmpty) return 'REF';
  const max = 14;
  final tail = clean.length > max ? clean.substring(0, max) : clean;
  return 'REF-$tail';
}

/// Paleta “industrial / ayudas” cercana a la referencia (naranja + azul muy oscuro).
abstract final class _AyudasTarjetaIndustrial {
  static const Color orange = Color(0xFFF37021);
  static const Color canvasDark = Color(0xFF0B0E14);
  static const Color panelDark = Color(0xFF1A1F2B);
  static const Color iconBoxDark = Color(0xFF252B38);
  static const Color strokeDark = Color(0xFF2D3548);
}

String? _validateCategoriaIco(Uint8List bytes) {
  const maxBytes = 256 * 1024;
  if (bytes.isEmpty) return 'El archivo ICO está vacío.';
  if (bytes.lengthInBytes > maxBytes) {
    return 'El ICO excede 256KB. Usa un icono de menos tamaños embebidos.';
  }
  if (bytes.lengthInBytes < 22) return 'Archivo ICO demasiado corto.';
  if (bytes[0] != 0 || bytes[1] != 0 || bytes[2] != 1 || bytes[3] != 0) {
    return 'Formato inválido: se espera un archivo .ico (tipo icono 1).';
  }
  return null;
}

Color _ayudaCategoryIconTint(
  BuildContext context,
  bool isCyberpunk,
  String titulo,
) {
  final isDark =
      material.Theme.of(context).brightness == material.Brightness.dark;
  final neonColors = <Color>[
    const Color(0xFF00E5FF),
    const Color(0xFFFF00D4),
    const Color(0xFFB7FF00),
  ];
  final neonIndex =
      titulo.runes.fold<int>(0, (a, b) => a + b) % neonColors.length;
  if (isCyberpunk) return neonColors[neonIndex];
  if (isDark) return material.Theme.of(context).colorScheme.secondary;
  return material.Theme.of(context).primaryColor;
}

Widget _themedAyudaIcoImage(Uint8List bytes, Color tint) {
  return ColorFiltered(
    colorFilter: ColorFilter.mode(tint, BlendMode.srcIn),
    child: Image.memory(bytes, fit: BoxFit.contain),
  );
}

String? _validateBackgroundImage(Uint8List bytes) {
  const maxBytes = 2 * 1024 * 1024;
  if (bytes.isEmpty) return 'La imagen de fondo está vacía.';
  if (bytes.lengthInBytes > maxBytes) {
    return 'La imagen de fondo excede 2MB.';
  }
  if (bytes.lengthInBytes < 8) return 'Archivo de fondo inválido.';
  return null;
}

/// Pantalla 1: menú de categorías (grid grande con iconos).
class AyudasMenuScreen extends StatefulWidget {
  const AyudasMenuScreen({
    super.key,
    required this.canUpload,
    this.canEditCategoryImage = false,
    this.allowRevisionHistory = true,
    this.allowCrossDocumentCompare = true,
  });

  final bool canUpload;
  final bool canEditCategoryImage;
  final bool allowRevisionHistory;
  final bool allowCrossDocumentCompare;

  @override
  State<AyudasMenuScreen> createState() => _AyudasMenuScreenState();
}

class _AyudasMenuScreenState extends State<AyudasMenuScreen> {
  static const List<String> _kSeedTags = ['Soldadura', 'Ensamble', 'Pintura'];

  /// Hueco fijo a la derecha para que el thumb de la barra no tape la última columna.
  static const double _kScrollbarEndGutter = 10;

  late final VoidCallback _lobbyOpenListener;

  bool _loading = true;
  String? _error;
  bool _usingOfflineSnapshot = false;
  List<dynamic> _categorias = [];
  bool _loadingIndice = false;
  List<Map<String, dynamic>> _todosDocumentos = [];
  final material.TextEditingController _searchCtrl = material.TextEditingController();
  final material.ScrollController _scrollCategoriasGrid = material.ScrollController();
  final material.ScrollController _scrollBusquedaLista = material.ScrollController();

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
    _scrollCategoriasGrid.dispose();
    _scrollBusquedaLista.dispose();
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
            allowCrossDocumentCompare: widget.allowCrossDocumentCompare,
          ),
        ),
      );
    });
  }

  Future<void> _cargar() async {
    setState(() {
      _loading = true;
      _error = null;
      _usingOfflineSnapshot = false;
    });
    try {
      final data = await ApiClient.get('/api/ayudas/categorias');
      final list = data is List ? data : <dynamic>[];
      await AyudasOfflineCacheService.instance.saveCategoriasSnapshot(list);
      setState(() {
        _categorias = list;
        _loading = false;
      });
      await _cargarIndiceDocumentos();
    } catch (e) {
      final cached = await AyudasOfflineCacheService.instance
          .readCategoriasSnapshot();
      if (cached != null) {
        setState(() {
          _categorias = cached;
          _loading = false;
          _usingOfflineSnapshot = true;
        });
        await _cargarIndiceDocumentos();
        return;
      }
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
      var usedOfflineDocs = false;
      for (final c in _categorias) {
        if (c is! Map<String, dynamic>) continue;
        final idRaw = c['ID_Categoria'];
        final idCat = idRaw is int ? idRaw : int.tryParse('$idRaw') ?? 0;
        final nombre = (c['Nombre_Categoria'] ?? '').toString();
        futures.add(() async {
          List<dynamic> raw = const <dynamic>[];
          try {
            final data = await ApiClient.get('/api/ayudas/lista/$idCat');
            raw = data is List ? data : <dynamic>[];
            await AyudasOfflineCacheService.instance.saveCategoriaListaSnapshot(
              idCat,
              raw,
            );
          } catch (_) {
            final cached = await AyudasOfflineCacheService.instance
                .readCategoriaListaSnapshot(idCat);
            if (cached != null) {
              raw = cached;
              usedOfflineDocs = true;
            }
          }
          return raw.whereType<Map>().map((d) {
            final m = Map<String, dynamic>.from(d);
            m['_id_categoria'] = idCat;
            m['_nombre_categoria'] = nombre;
            return m;
          }).toList();
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
          _usingOfflineSnapshot = _usingOfflineSnapshot || usedOfflineDocs;
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
    return material.Scrollbar(
      controller: _scrollBusquedaLista,
      thickness: 10,
      child: material.ListView.separated(
        controller: _scrollBusquedaLista,
        padding: const EdgeInsets.only(right: _kScrollbarEndGutter),
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
                      allowCrossDocumentCompare: widget.allowCrossDocumentCompare,
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  Future<void> _dialogoNuevaCategoria() async {
    final nombreCtrl = TextEditingController();
    final iconoCtrl = TextEditingController();
    Uint8List? iconoIcoBytes;
    String? iconoIcoB64;
    Uint8List? fondoBytes;
    String? fondoB64;
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
                const Text('Ícono .ico (opcional, monocromo / transparente)'),
                const SizedBox(height: 4),
                Text(
                  'Se pinta con el color del tema (como los iconos vectoriales).',
                  style: TextStyle(
                    fontSize: 12,
                    color: FluentTheme.of(context).resources.textFillColorSecondary,
                  ),
                ),
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
                      alignment: Alignment.center,
                      child: iconoIcoBytes == null
                          ? const Icon(FluentIcons.picture, size: 14)
                          : _themedAyudaIcoImage(
                              iconoIcoBytes!,
                              _ayudaCategoryIconTint(
                                context,
                                _esModoCiberpunk(context),
                                nombreCtrl.text.trim().isEmpty
                                    ? 'Cat'
                                    : nombreCtrl.text.trim(),
                              ),
                            ),
                    ),
                    const SizedBox(width: 8),
                    Button(
                      child: const Text('Seleccionar .ico'),
                      onPressed: () async {
                        final r = await FilePicker.platform.pickFiles(
                          type: FileType.custom,
                          allowMultiple: false,
                          allowedExtensions: ['ico'],
                          withData: true,
                        );
                        if (r == null || r.files.isEmpty) return;
                        Uint8List? bytes = r.files.single.bytes;
                        final path = r.files.single.path;
                        if (bytes == null && path != null && path.isNotEmpty) {
                          bytes = await File(path).readAsBytes();
                        }
                        if (bytes == null || bytes.isEmpty) return;
                        final validation = _validateCategoriaIco(bytes);
                        if (validation != null) {
                          _showIconValidationError(validation);
                          return;
                        }
                        final b64 = base64Encode(bytes);
                        iconoIcoBytes = bytes;
                        iconoIcoB64 = b64;
                        (ctx as Element).markNeedsBuild();
                      },
                    ),
                    if (iconoIcoBytes != null) ...[
                      const SizedBox(width: 6),
                      IconButton(
                        icon: const Icon(FluentIcons.clear, size: 14),
                        onPressed: () {
                          iconoIcoBytes = null;
                          iconoIcoB64 = null;
                          (ctx as Element).markNeedsBuild();
                        },
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 12),
                const Text('Imagen de fondo (opcional)'),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Container(
                      width: 56,
                      height: 34,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: FluentTheme.of(context).inactiveColor,
                        ),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: fondoBytes == null
                          ? const Icon(FluentIcons.picture, size: 14)
                          : Image.memory(fondoBytes!, fit: BoxFit.cover),
                    ),
                    const SizedBox(width: 8),
                    Button(
                      child: const Text('Seleccionar fondo'),
                      onPressed: () async {
                        final r = await FilePicker.platform.pickFiles(
                          type: FileType.custom,
                          allowMultiple: false,
                          allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
                          withData: true,
                        );
                        if (r == null || r.files.isEmpty) return;
                        Uint8List? bytes = r.files.single.bytes;
                        final path = r.files.single.path;
                        if (bytes == null && path != null && path.isNotEmpty) {
                          bytes = await File(path).readAsBytes();
                        }
                        if (bytes == null || bytes.isEmpty) return;
                        final validation = _validateBackgroundImage(bytes);
                        if (validation != null) {
                          _showIconValidationError(validation);
                          return;
                        }
                        fondoBytes = bytes;
                        fondoB64 = base64Encode(bytes);
                        (ctx as Element).markNeedsBuild();
                      },
                    ),
                    if (fondoBytes != null) ...[
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(FluentIcons.clear, size: 14),
                        onPressed: () {
                          fondoBytes = null;
                          fondoB64 = '';
                          (ctx as Element).markNeedsBuild();
                        },
                      ),
                    ],
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
                        if (iconoIcoB64 != null && iconoIcoB64!.isNotEmpty)
                          'icono_ico_base64': iconoIcoB64,
                        if (fondoB64 != null) 'fondo_base64': fondoB64,
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
      _disposeTextCtrlsAfterRouteClosed([nombreCtrl, iconoCtrl]);
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
    Uint8List? iconoIcoBytes =
        _decodeIconIco(row['Icono_Ico_Base64'] ?? row['icono_ico_base64']);
    String? iconoIcoB64 =
        iconoIcoBytes == null ? null : base64Encode(iconoIcoBytes);
    Uint8List? iconoPngBytes =
        _decodeIconPng(row['Icono_Png_Base64'] ?? row['icono_png_base64']);
    String? iconoPngB64 = iconoPngBytes == null ? null : base64Encode(iconoPngBytes);
    if (iconoIcoBytes != null) {
      iconoPngBytes = null;
      iconoPngB64 = null;
    }
    Uint8List? fondoBytes =
        _decodeImageBase64(row['Fondo_Base64'] ?? row['fondo_base64']);
    String? fondoB64 = fondoBytes == null ? null : base64Encode(fondoBytes);
    try {
      await showDialog<void>(
        context: context,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (context, setLocalState) {
              return ContentDialog(
                title: Text('Editar estilo: $nombre'),
                content: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Código de icono (opcional)'),
                    const SizedBox(height: 6),
                    TextBox(controller: iconoCtrl, placeholder: 'mecanico, electrico…'),
                    const SizedBox(height: 12),
                    const Text('Ícono .ico (opcional, monocromo / transparente)'),
                    const SizedBox(height: 4),
                    Text(
                      'Se pinta con el color del tema. Sustituye al PNG en categorías nuevas.',
                      style: TextStyle(
                        fontSize: 12,
                        color: FluentTheme.of(context)
                            .resources
                            .textFillColorSecondary,
                      ),
                    ),
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
                          alignment: Alignment.center,
                          child: iconoIcoBytes == null
                              ? const Icon(FluentIcons.picture, size: 16)
                              : _themedAyudaIcoImage(
                                  iconoIcoBytes!,
                                  _ayudaCategoryIconTint(
                                    context,
                                    _esModoCiberpunk(context),
                                    nombre,
                                  ),
                                ),
                        ),
                        const SizedBox(width: 8),
                        Button(
                          child: const Text('Cambiar .ico'),
                          onPressed: () async {
                            final r = await FilePicker.platform.pickFiles(
                              type: FileType.custom,
                              allowMultiple: false,
                              allowedExtensions: ['ico'],
                              withData: true,
                            );
                            if (r == null || r.files.isEmpty) return;
                            Uint8List? bytes = r.files.single.bytes;
                            final path = r.files.single.path;
                            if (bytes == null && path != null && path.isNotEmpty) {
                              bytes = await File(path).readAsBytes();
                            }
                            if (bytes == null || bytes.isEmpty) return;
                            final validation = _validateCategoriaIco(bytes);
                            if (validation != null) {
                              _showIconValidationError(validation);
                              return;
                            }
                            setLocalState(() {
                              iconoIcoBytes = bytes;
                              iconoIcoB64 = base64Encode(bytes!);
                              iconoPngBytes = null;
                              iconoPngB64 = null;
                            });
                          },
                        ),
                        const SizedBox(width: 8),
                        if (iconoIcoBytes != null)
                          IconButton(
                            icon: const Icon(FluentIcons.clear, size: 14),
                            onPressed: () {
                              setLocalState(() {
                                iconoIcoBytes = null;
                                iconoIcoB64 = '';
                              });
                            },
                          ),
                      ],
                    ),
                    if (iconoPngBytes != null && iconoIcoBytes == null) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Esta categoría aún usa un PNG antiguo (sin tinte de tema). '
                        'Sube un .ico para alinearlo con el tema.',
                        style: TextStyle(
                          fontSize: 12,
                          color: FluentTheme.of(context)
                              .resources
                              .textFillColorSecondary,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: SizedBox(
                          width: 42,
                          height: 42,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.memory(
                              iconoPngBytes!,
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    const Text('Imagen de fondo (opcional)'),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Container(
                          width: 68,
                          height: 42,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: FluentTheme.of(context).inactiveColor,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: fondoBytes == null
                              ? const Icon(FluentIcons.picture, size: 16)
                              : Image.memory(fondoBytes!, fit: BoxFit.cover),
                        ),
                        const SizedBox(width: 8),
                        Button(
                          child: const Text('Cambiar fondo'),
                          onPressed: () async {
                            final r = await FilePicker.platform.pickFiles(
                              type: FileType.custom,
                              allowMultiple: false,
                              allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
                              withData: true,
                            );
                            if (r == null || r.files.isEmpty) return;
                            Uint8List? bytes = r.files.single.bytes;
                            final path = r.files.single.path;
                            if (bytes == null && path != null && path.isNotEmpty) {
                              bytes = await File(path).readAsBytes();
                            }
                            if (bytes == null || bytes.isEmpty) return;
                            final validation = _validateBackgroundImage(bytes);
                            if (validation != null) {
                              _showIconValidationError(validation);
                              return;
                            }
                            setLocalState(() {
                              fondoBytes = bytes;
                              fondoB64 = base64Encode(bytes!);
                            });
                          },
                        ),
                        const SizedBox(width: 8),
                        if (fondoBytes != null)
                          IconButton(
                            icon: const Icon(FluentIcons.clear, size: 14),
                            onPressed: () {
                              setLocalState(() {
                                fondoBytes = null;
                                fondoB64 = '';
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
                      // Evitar el `context` del StatefulBuilder (inválido tras cerrar rutas).
                      final shellCtx = this.context;
                      showDialog<void>(
                        context: shellCtx,
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
                        if (iconoIcoB64 != null) {
                          body['icono_ico_base64'] = iconoIcoB64;
                        }
                        if (iconoPngB64 != null) {
                          body['icono_png_base64'] = iconoPngB64;
                        }
                        if (fondoB64 != null) {
                          body['fondo_base64'] = fondoB64;
                        }
                        await ApiClient.put(
                          '/api/ayudas/categorias/$idCategoria',
                          body: body,
                          headers: {'X-Usuario': user},
                        );
                        if (!mounted) return;
                        Navigator.of(shellCtx, rootNavigator: true).pop();
                        Navigator.of(shellCtx, rootNavigator: true).pop();
                        await _cargar();
                        if (!mounted) return;
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (!mounted) return;
                          displayInfoBar(
                            this.context,
                            builder: (c, close) => InfoBar(
                              title: const Text('Listo'),
                              content: const Text('Imagen de categoría actualizada.'),
                              severity: InfoBarSeverity.success,
                              onClose: close,
                            ),
                          );
                        });
                      } catch (e) {
                        if (!mounted) return;
                        Navigator.of(shellCtx, rootNavigator: true).pop();
                        showAyudasUploadError(this.context, e);
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
      _disposeTextCtrlsAfterRouteClosed([iconoCtrl]);
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
              title: const Text('Editar estilo de categoría'),
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
    final screenW = MediaQuery.sizeOf(context).width;
    final compactHeader = screenW < 980;
    final theme = FluentTheme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return ScaffoldPage(
      header: DecoratedBox(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF141A24) : const Color(0xFFF7F9FC),
          border: Border(
            bottom: BorderSide(
              color: isDark ? const Color(0xFF2A3444) : const Color(0xFFE2E8F0),
            ),
          ),
        ),
        child: CompactPageHeader(
          applyTitleTypography: false,
          crossAxisAlignment: CrossAxisAlignment.center,
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
          title: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                'Ayudas visuales',
                style: theme.typography.subtitle?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: compactHeader ? 290 : 420,
                      minWidth: compactHeader ? 180 : 240,
                    ),
                    child: SizedBox(
                      height: compactHeader ? 34 : 36,
                      child: material.Material(
                        color: material.Colors.transparent,
                        child: material.TextField(
                          controller: _searchCtrl,
                          style: material.TextStyle(
                            color: isDark
                                ? const Color(0xFFE2E4E9)
                                : const Color(0xFF1B2B44),
                            fontSize: 13.5,
                          ),
                          decoration: material.InputDecoration(
                            hintText: compactHeader
                                ? 'Título, VIN, #etiqueta…'
                                : 'Buscar: título, VIN, #etiqueta…',
                            hintStyle: material.TextStyle(
                              color: isDark
                                  ? const Color(0xFF9AA2B3)
                                  : const Color(0xFF6B7F9C),
                              fontSize: 12.5,
                            ),
                            prefixIcon: material.Icon(
                              material.Icons.search,
                              color: isDark
                                  ? const Color(0xFF9AA2B3)
                                  : const Color(0xFF6B7F9C),
                              size: 18,
                            ),
                            prefixIconConstraints: const BoxConstraints(
                              minWidth: 34,
                              minHeight: 34,
                            ),
                            filled: true,
                            fillColor: isDark
                                ? const Color(0xFF1A2230)
                                : const Color(0xFFF2F6FC),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 6,
                            ),
                            border: material.OutlineInputBorder(
                              borderRadius: material.BorderRadius.circular(18),
                              borderSide: material.BorderSide(
                                color: isDark
                                    ? const Color(0xFF334155)
                                    : const Color(0xFFC7D6EA),
                              ),
                            ),
                            enabledBorder: material.OutlineInputBorder(
                              borderRadius: material.BorderRadius.circular(18),
                              borderSide: material.BorderSide(
                                color: isDark
                                    ? const Color(0xFF334155)
                                    : const Color(0xFFC7D6EA),
                              ),
                            ),
                            focusedBorder: material.OutlineInputBorder(
                              borderRadius: material.BorderRadius.circular(18),
                              borderSide: const material.BorderSide(
                                color: Color(0xFF2F80ED),
                              ),
                            ),
                            isDense: true,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                icon: const Icon(FluentIcons.refresh),
                onPressed: _loading ? null : _cargar,
              ),
          ],
        ),
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
                        if (_usingOfflineSnapshot)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                            child: InfoBar(
                              title: const Text('Sin conexión'),
                              content: const Text(
                                'Mostrando la última copia guardada de ayudas visuales.',
                              ),
                              severity: InfoBarSeverity.warning,
                            ),
                          ),
                        if (_loadingIndice)
                          const Padding(
                            padding: EdgeInsets.fromLTRB(12, 0, 12, 3),
                            child: SizedBox(
                              height: 2,
                              child: material.LinearProgressIndicator(),
                            ),
                          ),
                        if (ayudasTagSuggestionsForQuery(
                          _searchCtrl.text,
                          _poolTagsBusqueda(),
                        ).isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                            child: material.Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              mainAxisSize: material.MainAxisSize.min,
                              children: [
                                Text(
                                  'Sugerencias de etiquetas',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: FluentTheme.of(context).inactiveColor,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                material.Wrap(
                                  spacing: 4,
                                  runSpacing: 4,
                                  children: ayudasTagSuggestionsForQuery(
                                    _searchCtrl.text,
                                    _poolTagsBusqueda(),
                                  )
                                      .map(
                                        (tag) => material.ActionChip(
                                          label: material.Text(
                                            '#$tag',
                                            style: const material.TextStyle(
                                              fontSize: 12,
                                            ),
                                          ),
                                          materialTapTargetSize: material
                                              .MaterialTapTargetSize
                                              .shrinkWrap,
                                          visualDensity:
                                              material.VisualDensity.compact,
                                          onPressed: () =>
                                              _aplicarSugerenciaTag(tag),
                                        ),
                                      )
                                      .toList(),
                                ),
                              ],
                            ),
                          ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                            child: _searchCtrl.text.trim().isEmpty
                                ? LayoutBuilder(
                                    builder: (context, c) {
                                      final cols = c.maxWidth >= 1300
                                          ? 4
                                          : c.maxWidth >= 900
                                              ? 3
                                              : c.maxWidth >= 640
                                                  ? 2
                                                  : 1;
                                      final gap =
                                          c.maxWidth >= 900 ? 14.0 : 12.0;
                                      final ratio = c.maxWidth >= 1100
                                          ? 1.22
                                          : c.maxWidth >= 900
                                              ? 1.12
                                              : c.maxWidth >= 640
                                                  ? 0.98
                                                  : 0.92;
                                      return material.Scrollbar(
                                        controller: _scrollCategoriasGrid,
                                        thickness: 10,
                                        child: GridView.builder(
                                          controller: _scrollCategoriasGrid,
                                          padding: const EdgeInsets.only(
                                            right: _kScrollbarEndGutter,
                                          ),
                                          gridDelegate:
                                              SliverGridDelegateWithFixedCrossAxisCount(
                                            crossAxisCount: cols,
                                            mainAxisSpacing: gap,
                                            crossAxisSpacing: gap,
                                            childAspectRatio: ratio,
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
                                            final iconoIco = _decodeIconIco(
                                              row['Icono_Ico_Base64'] ??
                                                  row['icono_ico_base64'],
                                            );
                                            final iconoPng = _decodeIconPng(
                                              row['Icono_Png_Base64'] ??
                                                  row['icono_png_base64'],
                                            );
                                            final fondo = _decodeImageBase64(
                                              row['Fondo_Base64'] ??
                                                  row['fondo_base64'],
                                            );
                                            return _CategoriaTile(
                                              titulo: nombre,
                                              refTag: _refEtiquetaAyudaCategoria(
                                                id,
                                                nombre,
                                              ),
                                              icon: _obtenerIcono(icono),
                                              iconIco: iconoIco,
                                              iconPng: iconoIco != null
                                                  ? null
                                                  : iconoPng,
                                              fondo: fondo,
                                              isCyberpunk: isCyberpunk,
                                              onTap: () {
                                                Navigator.of(context).push(
                                                  material.MaterialPageRoute<
                                                      void>(
                                                    builder: (_) =>
                                                        AyudasCategoriaScreen(
                                                      idCategoria: id is int
                                                          ? id
                                                          : int.tryParse(
                                                                  '$id',
                                                                ) ??
                                                                0,
                                                      nombreCategoria: nombre,
                                                      canUpload:
                                                          widget.canUpload,
                                                      allowRevisionHistory: widget
                                                          .allowRevisionHistory,
                                                      allowCrossDocumentCompare:
                                                          widget
                                                              .allowCrossDocumentCompare,
                                                    ),
                                                  ),
                                                );
                                              },
                                            );
                                          },
                                        ),
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
              right: 12 + _kScrollbarEndGutter,
              bottom: 12,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.canEditCategoryImage) ...[
                    material.FloatingActionButton.small(
                      heroTag: 'ayudas_menu_editar_imagen_categoria',
                      onPressed: _abrirSelectorCategoriaEditarImagen,
                      tooltip: 'Editar estilo categoría',
                      child: const Icon(material.Icons.photo_camera_outlined),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (widget.canUpload)
                    material.FloatingActionButton.small(
                      heroTag: 'ayudas_menu_nueva_categoria',
                      onPressed: _dialogoNuevaCategoria,
                      tooltip: 'Nueva categoría',
                      child: const Icon(material.Icons.add),
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
    required this.refTag,
    required this.icon,
    required this.iconIco,
    required this.iconPng,
    required this.fondo,
    required this.isCyberpunk,
    required this.onTap,
  });

  final String titulo;
  final String refTag;
  final IconData icon;
  final Uint8List? iconIco;
  final Uint8List? iconPng;
  final Uint8List? fondo;
  final bool isCyberpunk;
  final VoidCallback onTap;

  Widget _footerIcon(double innerSide, Color iconColor) {
    final dim = innerSide.clamp(22.0, 44.0);
    if (iconIco != null) {
      return SizedBox(
        width: dim,
        height: dim,
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: _themedAyudaIcoImage(iconIco!, iconColor),
        ),
      );
    }
    if (iconPng != null) {
      return SizedBox(
        width: dim,
        height: dim,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(iconPng!, fit: BoxFit.contain),
        ),
      );
    }
    return Icon(icon, size: dim * 0.78, color: iconColor);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = FluentTheme.of(context).brightness == Brightness.dark;
    final borderRadius = material.BorderRadius.circular(
      isCyberpunk ? 6.0 : 26.0,
    );
    final iconColor = isCyberpunk
        ? _ayudaCategoryIconTint(context, isCyberpunk, titulo)
        : _AyudasTarjetaIndustrial.orange;
    final industrial = !isCyberpunk;

    final cardStroke = industrial && isDark
        ? _AyudasTarjetaIndustrial.strokeDark
        : (isDark ? const Color(0xFF343B48) : const Color(0xFFC5D2E5));
    final cardBg = industrial && isDark
        ? _AyudasTarjetaIndustrial.canvasDark
        : (isDark ? const Color(0xFF12161C) : const Color(0xFFF7F9FD));
    final heroPlaceholderTop = industrial && isDark
        ? _AyudasTarjetaIndustrial.panelDark
        : (isDark ? const Color(0xFF1E252F) : const Color(0xFFD8DEE9));
    final heroPlaceholderBottom = industrial && isDark
        ? const Color(0xFF141A24)
        : (isDark ? const Color(0xFF161C26) : const Color(0xFFE2E8F0));
    final footerFill = industrial && isDark
        ? _AyudasTarjetaIndustrial.panelDark
        : (isDark ? const Color(0xE6182233) : const Color(0xF2F0F4FA));
    final footerBorderTop = industrial && isDark
        ? _AyudasTarjetaIndustrial.strokeDark.withValues(alpha: 0.85)
        : (isDark
            ? const Color(0xFF3D4A5E).withValues(alpha: 0.65)
            : const Color(0xFF9DB0CC).withValues(alpha: 0.45));
    final titleAccentOrange =
        industrial && titulo.hashCode.isEven; // variación tipo referencia
    final titleColor = industrial && isDark
        ? (titleAccentOrange
            ? _AyudasTarjetaIndustrial.orange
            : const Color(0xFFF4F7FC))
        : (isDark ? const Color(0xFFF1F5FB) : const Color(0xFF0F172A));
    final subtitleColor = industrial && isDark
        ? const Color(0xFF8B95A8)
        : (isDark ? const Color(0xFF9CA8BC) : const Color(0xFF64748B));
    final iconBoxBg = industrial && isDark
        ? _AyudasTarjetaIndustrial.iconBoxDark
        : (isDark ? const Color(0xFF232B38) : const Color(0xFFE8EEF7));
    final pillBg = industrial && isDark
        ? const Color(0xD90B0E14)
        : const Color(0xE60F172A);
    final chevronAccent = isCyberpunk ? iconColor : _AyudasTarjetaIndustrial.orange;
    final chevronBorder = chevronAccent.withValues(
      alpha: isDark ? 0.55 : 0.42,
    );

    return material.Material(
      color: material.Colors.transparent,
      child: material.InkWell(
        onTap: onTap,
        borderRadius: borderRadius,
        child: material.Ink(
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            color: cardBg,
            border: Border.all(color: cardStroke, width: 1),
            boxShadow: [
              if (industrial && isDark)
                BoxShadow(
                  color: _AyudasTarjetaIndustrial.orange.withValues(alpha: 0.07),
                  blurRadius: 22,
                  offset: const Offset(0, 10),
                )
              else
                BoxShadow(
                  color: material.Colors.black.withValues(
                    alpha: isDark ? 0.28 : 0.06,
                  ),
                  blurRadius: 12,
                  offset: const Offset(0, 5),
                ),
            ],
          ),
          child: ClipRRect(
            borderRadius: borderRadius,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 13,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (fondo != null)
                        Image.memory(
                          fondo!,
                          fit: BoxFit.cover,
                          alignment: const Alignment(0, -0.1),
                          filterQuality: FilterQuality.medium,
                          gaplessPlayback: true,
                        )
                      else
                        DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [heroPlaceholderTop, heroPlaceholderBottom],
                            ),
                          ),
                          child: Center(
                            child: Icon(
                              material.Icons.photo_library_outlined,
                              size: 46,
                              color: isDark
                                  ? const Color(0xFF5C6678)
                                  : const Color(0xFF5A6B82),
                            ),
                          ),
                        ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        height: 36,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                material.Colors.transparent,
                                (isDark
                                        ? _AyudasTarjetaIndustrial.canvasDark
                                        : const Color(0xFF0F172A))
                                    .withValues(alpha: isDark ? 0.55 : 0.06),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (industrial)
                        Positioned(
                          top: 10,
                          right: 10,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: pillBg,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: _AyudasTarjetaIndustrial.orange
                                    .withValues(alpha: 0.35),
                              ),
                            ),
                            child: Text(
                              refTag,
                              style: const TextStyle(
                                color: _AyudasTarjetaIndustrial.orange,
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.6,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  flex: 10,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: footerFill,
                      border: Border(
                        top: BorderSide(color: footerBorderTop, width: 1),
                      ),
                    ),
                    child: LayoutBuilder(
                      builder: (context, c) {
                        final h = c.maxHeight;
                        final boxSide = (h * 0.78).clamp(44.0, 58.0);
                        final innerIcon = (boxSide - 18).clamp(22.0, 40.0);
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Container(
                                width: boxSide,
                                height: boxSide,
                                decoration: BoxDecoration(
                                  color: iconBoxBg,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: industrial && isDark
                                        ? _AyudasTarjetaIndustrial.strokeDark
                                        : cardStroke,
                                  ),
                                ),
                                alignment: Alignment.center,
                                child: _footerIcon(innerIcon, iconColor),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      titulo,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: titleColor,
                                        fontSize: h > 50 ? 17.5 : 15.5,
                                        fontWeight: FontWeight.w800,
                                        height: 1.1,
                                        letterSpacing: -0.15,
                                      ),
                                    ),
                                    const SizedBox(height: 5),
                                    Text(
                                      'CATEGORÍA INDUSTRIAL',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: subtitleColor,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                        letterSpacing: 1.1,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 6),
                              Container(
                                width: 34,
                                height: 34,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: chevronBorder,
                                    width: 1.5,
                                  ),
                                ),
                                alignment: Alignment.center,
                                child: Icon(
                                  material.Icons.chevron_right_rounded,
                                  size: 20,
                                  color: chevronAccent.withValues(alpha: 0.92),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
