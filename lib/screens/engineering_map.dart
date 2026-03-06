import 'package:fluent_ui/fluent_ui.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'bom_manager.dart';

const String _API = "http://192.168.1.73:8001";

class EngineeringMapScreen extends StatefulWidget {
  final int? targetRevisionId;
  const EngineeringMapScreen({super.key, this.targetRevisionId});

  @override
  State<EngineeringMapScreen> createState() => _EngineeringMapScreenState();
}

class _EngineeringMapScreenState extends State<EngineeringMapScreen> {
  List<dynamic> _arbol = [];
  bool _isLoading = true;
  String _filter = "";
  int? _lastUsedTargetRevId;

  @override
  void didUpdateWidget(EngineeringMapScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.targetRevisionId != oldWidget.targetRevisionId &&
        widget.targetRevisionId != null) {
      _checkAndAutoLoad();
    }
  }

  void _checkAndAutoLoad() {
    if (widget.targetRevisionId == null ||
        widget.targetRevisionId == _lastUsedTargetRevId)
      return;
    if (_arbol.isEmpty) return;

    for (var tracto in _arbol) {
      for (var tipo in tracto['tipos']) {
        for (var ver in tipo['versiones']) {
          for (var rev in ver['revisiones']) {
            if (rev['id_revision'] == widget.targetRevisionId) {
              _lastUsedTargetRevId = widget.targetRevisionId;
              Future.microtask(() {
                if (mounted) {
                  Navigator.push(
                    context,
                    FluentPageRoute(
                      builder:
                          (_) => BOMManagerScreen(
                            idVersion: ver['id'] as int,
                            versionName: ver['nombre'] as String,
                            tractoName: tracto['nombre'] as String,
                            targetRevisionId: widget.targetRevisionId,
                          ),
                    ),
                  );
                }
              });
              return;
            }
          }
        }
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _fetchArbol();
  }

  Future<void> _fetchArbol() async {
    setState(() => _isLoading = true);
    try {
      final res = await http.get(Uri.parse('$_API/api/mapa/jerarquia'));
      if (res.statusCode == 200) {
        setState(() {
          _arbol = json.decode(res.body);
          _checkAndAutoLoad();
        });
      }
    } catch (e) {
      if (mounted) {
        displayInfoBar(
          context,
          builder:
              (ctx, close) => InfoBar(
                title: const Text('Error'),
                content: Text('No se pudo cargar el mapa: $e'),
                severity: InfoBarSeverity.error,
                onClose: close,
              ),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  List<Widget> _buildTree() {
    final filterLow = _filter.toLowerCase();
    final primaryColor = FluentTheme.of(context).accentColor;
    final bodyColor = FluentTheme.of(context).typography.body?.color ?? Colors.black;
    final dividerColor = FluentTheme.of(context).resources.dividerStrokeColorDefault ?? bodyColor.withOpacity(0.1);

    return _arbol.map<Widget>((tracto) {
      final tractoNombre = tracto['nombre'] as String;

      // Filtrar tipos/versiones por el texto de búsqueda
      final tipos =
          (tracto['tipos'] as List).where((tp) {
            if (filterLow.isEmpty) return true;
            final tpNombre = (tp['nombre'] as String).toLowerCase();
            if (tpNombre.contains(filterLow)) return true;
            return (tp['versiones'] as List).any(
              (v) => (v['nombre'] as String).toLowerCase().contains(filterLow),
            );
          }).toList();

      return _CustomNode(
        initiallyExpanded: false,
        header: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Container(
            margin: const EdgeInsets.only(top: 8, bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: FluentTheme.of(context).cardColor,
              border: Border.all(color: dividerColor.withOpacity(0.5)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 12, height: 12, decoration: BoxDecoration(color: primaryColor, shape: BoxShape.circle)),
                const SizedBox(width: 8),
                Expanded(child: Text(tractoNombre, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: primaryColor))),
              ],
            ),
          ),
        ),
        children:
            tipos.map<Widget>((tipo) {
              return _CustomNode(
                initiallyExpanded: false,
                header: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: Container(
                    margin: const EdgeInsets.only(top: 6, bottom: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: FluentTheme.of(context).cardColor,
                      border: Border.all(color: dividerColor.withOpacity(0.4)),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(FluentIcons.build_definition, size: 14, color: primaryColor.withOpacity(0.7)),
                        const SizedBox(width: 8),
                        Expanded(child: Text(tipo['nombre'], style: TextStyle(fontWeight: FontWeight.w600, color: bodyColor))),
                      ],
                    ),
                  ),
                ),
                children:
                    (tipo['versiones'] as List).map<Widget>((ver) {
                      final revisiones = ver['revisiones'] as List;
                      final bool hasRevs = revisiones.isNotEmpty;
                      
                      return _CustomNode(
                        initiallyExpanded: false,
                        header: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 400),
                          child: Container(
                            margin: const EdgeInsets.only(top: 4, bottom: 4),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: FluentTheme.of(context).cardColor,
                              border: Border.all(color: dividerColor.withOpacity(0.3)),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(FluentIcons.fabric_open_folder_horizontal, size: 13, color: hasRevs ? primaryColor : bodyColor.withOpacity(0.3)),
                                const SizedBox(width: 8),
                                Expanded(child: Text(ver['nombre'], style: TextStyle(fontStyle: FontStyle.italic, color: hasRevs ? bodyColor : bodyColor.withOpacity(0.6)))),
                              ],
                            ),
                          ),
                        ),
                        children: !hasRevs
                            ? []
                            : revisiones.map<Widget>((rev) {
                                  final bool aprobada =
                                      rev['estado'] == 'Aprobada';
                                  return _CustomNode(
                                    initiallyExpanded: false,
                                    header: ConstrainedBox(
                                      constraints: const BoxConstraints(maxWidth: 400),
                                      child: Container(
                                        margin: const EdgeInsets.only(top: 4, bottom: 4),
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                        decoration: BoxDecoration(
                                          color: FluentTheme.of(context).cardColor,
                                          border: Border.all(color: dividerColor.withOpacity(0.2)),
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            // Semáforo de estado
                                            Tooltip(
                                              message: rev['estado'],
                                              child: Container(
                                                width: 10,
                                                height: 10,
                                                margin: const EdgeInsets.only(right: 8),
                                                decoration: BoxDecoration(
                                                  color: aprobada ? Colors.green : Colors.orange,
                                                  shape: BoxShape.circle,
                                                ),
                                              ),
                                            ),
                                            Expanded(
                                              child: Text(
                                                "Rev ${rev['numero_revision']}  •  ${rev['estado']}",
                                                style: TextStyle(fontSize: 13, color: bodyColor),
                                              ),
                                            ),
                                            const SizedBox(width: 16),
                                            // Botón abrir BOM
                                            Tooltip(
                                              message: "Abrir Gestor de BOM para esta revisión",
                                              child: IconButton(
                                                icon: Icon(FluentIcons.open_in_new_window, size: 14, color: primaryColor),
                                                onPressed: () => Navigator.push(
                                                  context,
                                                  FluentPageRoute(
                                                    builder: (_) => BOMManagerScreen(
                                                      idVersion: ver['id'] as int,
                                                      versionName: ver['nombre'] as String,
                                                      tractoName: tractoNombre,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  );
                                }).toList(),
                      );
                    }).toList(),
              );
            }).toList(),
      );
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: PageHeader(
        title: const Text('Mapa de Ingeniería'),
        commandBar: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 220,
              child: TextBox(
                placeholder: 'Buscar tipo o versión...',
                prefix: const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(FluentIcons.search, size: 14),
                ),
                onChanged: (v) => setState(() => _filter = v),
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: "Recargar árbol de ingeniería",
              child: IconButton(
                icon: const Icon(FluentIcons.refresh),
                onPressed: _fetchArbol,
              ),
            ),
          ],
        ),
      ),
      content:
          _isLoading
              ? const Center(child: ProgressRing())
              : _arbol.isEmpty
              ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      FluentIcons.map_layers,
                      size: 48,
                      color:
                          (FluentTheme.of(
                                context,
                              ).typography.body?.color?.withOpacity(0.3) ??
                              Colors.grey),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'No se encontraron datos de ingeniería.',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ],
                ),
              )
              : Column(
                  children: [
                    Expanded(
                      child: InteractiveViewer(
                        constrained: false,
                        minScale: 0.5,
                        maxScale: 2.0,
                        boundaryMargin: const EdgeInsets.all(double.infinity),
                        child: Padding(
                          padding: const EdgeInsets.all(40.0),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: _buildTree(),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}

class _CustomNode extends StatefulWidget {
  final Widget header;
  final List<Widget> children;
  final bool initiallyExpanded;
  
  const _CustomNode({required this.header, this.children = const [], this.initiallyExpanded = false});

  @override
  State<_CustomNode> createState() => _CustomNodeState();
}

class _CustomNodeState extends State<_CustomNode> {
  late bool expanded;
  @override
  void initState() {
    super.initState();
    expanded = widget.initiallyExpanded;
  }
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: widget.children.isEmpty ? null : () => setState(() => expanded = !expanded),
          child: MouseRegion(cursor: widget.children.isEmpty ? SystemMouseCursors.basic : SystemMouseCursors.click, child: widget.header),
        ),
        if (expanded && widget.children.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 40.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: widget.children,
            ),
          ),
      ],
    );
  }
}
