import 'package:fluent_ui/fluent_ui.dart';
import 'dart:convert';
import 'dart:io';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_file/open_file.dart';
import '../services/api_client.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  static const int _pageSize = 50;

  List<dynamic> _registros = [];
  bool _hasMore = true;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  /// Búsqueda activa para paginación (sincronizada al refrescar / buscar).
  String _activeSearchQuery = '';

  bool _isTimelineView = false;

  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _reloadHistory();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!mounted) return;
    if (!_scrollController.hasClients) return;
    if (!_hasMore || _isLoadingMore || _isLoading) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 120) {
      _loadMore();
    }
  }

  /// Si la lista no llena el viewport, pide más páginas (sin scroll).
  void _scheduleFillIfNeeded() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_hasMore || _isLoadingMore || _isLoading) return;
      if (!_scrollController.hasClients) return;
      if (_registros.isEmpty) return;
      final max = _scrollController.position.maxScrollExtent;
      if (max < 80) {
        _loadMore().then((_) {
          if (mounted) _scheduleFillIfNeeded();
        });
      }
    });
  }

  Map<String, String> _historialQueryParams(int offset) {
    final qp = <String, String>{
      'offset': '$offset',
      'limit': '$_pageSize',
    };
    if (_activeSearchQuery.isNotEmpty) {
      qp['busqueda'] = _activeSearchQuery;
    }
    return qp;
  }

  Future<void> _reloadHistory({String? query}) async {
    final q = (query ?? _searchController.text).trim();
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _isLoadingMore = false;
      _registros = [];
      _hasMore = true;
      _activeSearchQuery = q;
    });

    try {
      final data = await ApiClient.get(
        '/api/historial',
        queryParameters: _historialQueryParams(0),
      ) as Map<String, dynamic>;

      if (!mounted) return;
      setState(() {
        _registros = List<dynamic>.from(data['items'] as List? ?? []);
        _hasMore = data['has_more'] == true;
      });
      _scheduleFillIfNeeded();
    } catch (e) {
      if (!mounted) return;
      _showErrorDialog(e.toString());
    } finally {
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  Future<void> _loadMore() async {
    if (!_hasMore || _isLoadingMore || _isLoading) return;
    if (!mounted) return;

    setState(() => _isLoadingMore = true);

    try {
      final data = await ApiClient.get(
        '/api/historial',
        queryParameters: _historialQueryParams(_registros.length),
      ) as Map<String, dynamic>;

      if (!mounted) return;
      setState(() {
        _registros.addAll(List<dynamic>.from(data['items'] as List? ?? []));
        _hasMore = data['has_more'] == true;
      });
      _scheduleFillIfNeeded();
    } catch (e) {
      if (!mounted) return;
      _showErrorDialog(e.toString());
    } finally {
      if (!mounted) return;
      setState(() => _isLoadingMore = false);
    }
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (context) {
        return ContentDialog(
          title: const Text('Error'),
          content: Text(message),
          actions: [
            Button(
              child: const Text('Cerrar'),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        );
      },
    );
  }

  Color _getActionColor(String action) {
    if (action.toUpperCase().contains('CREACION') ||
        action.toUpperCase() == 'NUEVO') {
      return Colors.green;
    } else if (action.toUpperCase().contains('MODIFICACION') ||
        action.toUpperCase() == 'UPDATE') {
      return Colors.blue;
    } else if (action.toUpperCase().contains('ELIMINACION') ||
        action.toUpperCase() == 'DELETE') {
      return Colors.red;
    }
    return Colors.orange; // Default/Unknown
  }

  /// Nodo de timeline: verde crear/aprobar, azul editar, rojo eliminar, naranja resto.
  Color _getTimelineNodeColor(String action) {
    final u = action.toUpperCase();
    if (u.contains('APROB') ||
        u.contains('CREACION') ||
        u == 'NUEVO') {
      return Colors.green;
    }
    if (u.contains('MODIFICACION') || u.contains('UPDATE')) {
      return Colors.blue;
    }
    if (u.contains('ELIMINACION') || u.contains('DELETE')) {
      return Colors.red;
    }
    return Colors.orange;
  }

  Color _timelineLineColor(BuildContext context) {
    return FluentTheme.of(context).resources.dividerStrokeColorDefault ??
        Colors.grey.withOpacity(0.45);
  }

  Widget _buildDiffView(
    dynamic oldData,
    dynamic newData,
    BuildContext context,
  ) {
    // 1. LÓGICA DE PARSEO INTELIGENTE
    Map<String, dynamic>? tryParseJson(dynamic data) {
      if (data == null) return null;
      if (data is Map<String, dynamic>) return data;
      if (data is String) {
        try {
          String sanitized = data
              .replaceAll('"', '\\"') // 1. Protege las pulgadas primero
              .replaceAll("'", '"') // 2. Convierte sintaxis Python a JSON
              .replaceAll("None", "null")
              .replaceAll("True", "true")
              .replaceAll("False", "false");
          final decoded = jsonDecode(sanitized);
          if (decoded is Map<String, dynamic>) return decoded;
        } catch (_) {}
      }
      return null;
    }

    final oldMap = tryParseJson(oldData);
    final newMap = tryParseJson(newData);

    final isDict = (oldMap != null || newMap != null);

    // 2. CONSTRUCCIÓN VISUAL DEL BLOQUE (MAPAS DESGLOSADOS)
    if (isDict) {
      final safeOld = oldMap ?? {};
      final safeNew = newMap ?? {};

      final allKeys = {...safeOld.keys, ...safeNew.keys}.toList();
      List<Widget> changes = [];

      for (var key in allKeys) {
        final oldVal = safeOld[key]?.toString() ?? 'N/A';
        final newVal = safeNew[key]?.toString() ?? 'N/A';
        // === TAREA 3: Colores explícitos independientes de TextTheme ===
        final isDark = FluentTheme.of(context).brightness == Brightness.dark;
        final labelColor = isDark ? Colors.white.withOpacity(0.7) : const Color(0xFF444444);

        if (oldVal != newVal) {
          changes.add(
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '$key: ',
                  style: TextStyle(fontWeight: FontWeight.bold, color: labelColor),
                ),
                Text(
                  oldVal,
                  style: TextStyle(
                    color: Colors.red,
                    decoration: TextDecoration.lineThrough,
                  ),
                ),
                Text(
                  ' ➔ ',
                  style: TextStyle(
                    color: isDark ? Colors.grey : Colors.grey[100],
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(newVal, style: TextStyle(color: Colors.green)),
              ],
            ),
          );
        }
      }

      if (changes.isEmpty) {
        return const Text(
          'Sin cambios identificados en estructura.',
          style: TextStyle(fontStyle: FontStyle.italic),
        );
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: changes,
      );
    } else {
      // 2B. CONSTRUCCIÓN VISUAL (TEXTO SIMPLE)
      // === TAREA 3: Colores explícitos para modo oscuro ===
      final isDark = FluentTheme.of(context).brightness == Brightness.dark;
      final labelColor = isDark ? Colors.white.withOpacity(0.7) : const Color(0xFF555555);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (oldData != null && oldData.toString().isNotEmpty)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Anterior: ', style: TextStyle(color: labelColor, fontWeight: FontWeight.bold)),
                Expanded(
                  child: Text(
                    oldData.toString(),
                    style: TextStyle(color: Colors.red),
                  ),
                ),
              ],
            ),
          if (newData != null && newData.toString().isNotEmpty) ...[
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Nuevo: ', style: TextStyle(color: labelColor, fontWeight: FontWeight.bold)),
                Expanded(
                  child: Text(
                    newData.toString(),
                    style: TextStyle(color: Colors.green),
                  ),
                ),
              ],
            ),
          ],
        ],
      );
    }
  }

  Future<void> _exportarBugs() async {
    setState(() => _isLoading = true);
    try {
      final response =
          await ApiClient.getUnvalidated('/api/reportes/exportar_gemini');
      if (response.statusCode == 200) {
        final dir = await getDownloadsDirectory();
        final filePath =
            '${dir?.path ?? "C:\\"}\\Tbl_Reportes_Beta_Gemini.json';
        final file = File(filePath);
        await file.writeAsString(response.rawBody);

        displayInfoBar(
          context,
          builder: (context, close) {
            return InfoBar(
              title: const Text('Exportado'),
              content: Text('Reporte JSON guardado en Descargas: $filePath'),
              severity: InfoBarSeverity.success,
              action: Button(
                child: const Text("Abrir"),
                onPressed: () {
                  OpenFile.open(filePath);
                },
              ),
              onClose: close,
            );
          },
        );
      } else {
        _showErrorDialog("Error al generar reporte de Bugs.");
      }
    } catch (e) {
      _showErrorDialog(e.toString());
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Widget _buildStandardView() {
    return ListView.builder(
      controller: _scrollController,
      itemCount: _registros.length + (_isLoadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _registros.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: ProgressRing(),
            ),
          );
        }
        final item = _registros[index];

        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    item['fecha'] ?? 'Sin fecha',
                    style: TextStyle(
                      fontSize: 12,
                      color: FluentTheme.of(context).brightness ==
                              Brightness.dark
                          ? Colors.white.withOpacity(0.54)
                          : const Color(0xFF666666),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '| Usuario: ${item['usuario'] ?? "Desconocido"}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: FluentTheme.of(context).brightness ==
                                Brightness.dark
                            ? Colors.white
                            : Colors.black.withOpacity(0.87),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.orange.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      item['accion'] ?? 'ACCIÓN',
                      style: TextStyle(
                        color: Colors.orange,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SelectableText(
                item['codigo'] ?? 'SIN CÓDIGO',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: FluentTheme.of(context).brightness == Brightness.dark
                      ? Colors.white
                      : Colors.black,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: FluentTheme.of(context).brightness == Brightness.dark
                      ? Colors.black.withOpacity(0.2)
                      : Colors.grey[20],
                  borderRadius: BorderRadius.circular(4),
                ),
                child: _buildDiffView(
                  item['valor_anterior'],
                  item['valor_nuevo'],
                  context,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTimelineView() {
    final lineColor = _timelineLineColor(context);

    return ListView.builder(
      controller: _scrollController,
      itemCount: _registros.length + (_isLoadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _registros.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: ProgressRing(),
            ),
          );
        }

        final item = _registros[index];
        final isFirst = index == 0;
        final isLast = index == _registros.length - 1;
        final accion = item['accion']?.toString() ?? '';
        final nodeColor = _getTimelineNodeColor(accion);
        final isDark = FluentTheme.of(context).brightness == Brightness.dark;
        final metaColor = isDark
            ? Colors.white.withOpacity(0.54)
            : const Color(0xFF666666);
        final titleColor =
            isDark ? Colors.white : Colors.black.withOpacity(0.87);

        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 40,
                  child: Column(
                    children: [
                      if (!isFirst)
                        SizedBox(
                          height: 12,
                          width: 40,
                          child: Center(
                            child: Container(
                              width: 2,
                              height: 12,
                              color: lineColor,
                            ),
                          ),
                        )
                      else
                        const SizedBox(height: 12, width: 40),
                      SizedBox(
                        width: 40,
                        height: 12,
                        child: Center(
                          child: Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: nodeColor,
                              border: Border.all(
                                color: isDark
                                    ? Colors.white.withOpacity(0.35)
                                    : Colors.black.withOpacity(0.2),
                                width: 1,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (!isLast)
                        Expanded(
                          child: Center(
                            child: Container(
                              width: 2,
                              color: lineColor,
                            ),
                          ),
                        )
                      else
                        const SizedBox(height: 12, width: 40),
                    ],
                  ),
                ),
                Expanded(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item['fecha']?.toString() ?? 'Sin fecha',
                            style: TextStyle(
                              fontSize: 12,
                              color: metaColor,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Usuario: ${item['usuario'] ?? "Desconocido"}',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: titleColor,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            accion.isEmpty ? 'ACCIÓN' : accion,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: _getActionColor(accion),
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Código: ${item['codigo'] ?? "SIN CÓDIGO"}',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: titleColor,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 8),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? Colors.black.withOpacity(0.2)
                                  : Colors.grey[20],
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: _buildDiffView(
                              item['valor_anterior'],
                              item['valor_nuevo'],
                              context,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showEventosAyuda() {
    final typo = FluentTheme.of(context).typography;
    final bodyStyle = typo.body?.copyWith(fontSize: 13) ??
        const TextStyle(fontSize: 13);
    final hintStyle = typo.caption?.copyWith(
          fontSize: 12,
          color: FluentTheme.of(context).inactiveColor,
        ) ??
        TextStyle(fontSize: 12, color: FluentTheme.of(context).inactiveColor);

    showDialog(
      context: context,
      builder: (ctx) {
        return ContentDialog(
          constraints: const BoxConstraints(maxWidth: 440, maxHeight: 480),
          title: const Text('Referencia de eventos'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'La búsqueda coincide con código de pieza, usuario o nombre '
                  'de acción (coincidencia parcial).',
                  style: hintStyle,
                ),
                const SizedBox(height: 14),
                _ayudaCategoria(
                  'Catálogo',
                  const [
                    'CREAR_PIEZA',
                    'MODIFICAR_PIEZA',
                    'ELIMINAR_PIEZA',
                  ],
                  bodyStyle,
                ),
                _ayudaCategoria(
                  'Ingeniería',
                  const [
                    'CREAR_REVISION',
                    'APROBAR_REVISION',
                    'ELIMINAR_REVISION',
                    'DERIVACION',
                    'ECR_BRANCHING',
                  ],
                  bodyStyle,
                ),
                _ayudaCategoria(
                  'Estructura',
                  const [
                    'AGREGAR_PIEZA',
                    'ELIMINAR_PIEZA_BOM',
                    'MODIFICAR_CANTIDAD',
                  ],
                  bodyStyle,
                ),
                _ayudaCategoria(
                  'Autenticación',
                  const [
                    'LOGIN_EXITOSO',
                    'LOGIN_FALLIDO',
                  ],
                  bodyStyle,
                ),
              ],
            ),
          ),
          actions: [
            Button(
              child: const Text('Cerrar'),
              onPressed: () => Navigator.pop(ctx),
            ),
          ],
        );
      },
    );
  }

  Widget _ayudaCategoria(
    String titulo,
    List<String> eventos,
    TextStyle bodyStyle,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            titulo,
            style: bodyStyle.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          SelectableText(
            eventos.join(' · '),
            style: bodyStyle,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: const PageHeader(
        title: Text('Historial Global de Cambios'),
      ),
      content: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextBox(
                    controller: _searchController,
                    placeholder: 'Buscar por Código o Usuario...',
                    suffix: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_searchController.text.isNotEmpty)
                          IconButton(
                            icon: Icon(FluentIcons.clear),
                            onPressed: () {
                              _searchController.clear();
                              _reloadHistory(query: '');
                            },
                          ),
                        IconButton(
                          icon: Icon(FluentIcons.search),
                          onPressed: () =>
                              _reloadHistory(query: _searchController.text),
                        ),
                        IconButton(
                          icon: Icon(FluentIcons.refresh),
                          onPressed: () =>
                              _reloadHistory(query: _searchController.text),
                        ),
                      ],
                    ),
                    onSubmitted: (value) => _reloadHistory(query: value),
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message:
                      'Términos de acción que puedes buscar en el historial',
                  child: IconButton(
                    icon: const Icon(FluentIcons.info),
                    onPressed: _showEventosAyuda,
                  ),
                ),
                Tooltip(
                  message: _isTimelineView
                      ? 'Ver como lista'
                      : 'Ver línea de tiempo',
                  child: IconButton(
                    icon: Icon(
                      _isTimelineView
                          ? FluentIcons.bulleted_list_bullet
                          : FluentIcons.timeline,
                    ),
                    onPressed: () {
                      setState(() => _isTimelineView = !_isTimelineView);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Expanded(
              child: _isLoading && _registros.isEmpty
                  ? const Center(child: ProgressRing())
                  : _registros.isEmpty
                      ? const Center(
                          child: Text('No se encontraron registros.'),
                        )
                      : _isTimelineView
                          ? _buildTimelineView()
                          : _buildStandardView(),
            ),
          ],
        ),
      ),
    );
  }
}
