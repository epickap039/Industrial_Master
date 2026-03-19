import 'package:fluent_ui/fluent_ui.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'bom_manager.dart';
import '../config/app_config.dart';

const String _API = kApiBaseUrl;

class EngineeringMapScreen extends StatefulWidget {
  final int? targetRevisionId;
  const EngineeringMapScreen({super.key, this.targetRevisionId});

  @override
  State<EngineeringMapScreen> createState() => _EngineeringMapScreenState();
}

class _EngineeringMapScreenState extends State<EngineeringMapScreen> {
  List<dynamic> _arbol = [];
  String _filter = '';
  bool _isLoading = false;
  bool _groupByClient = false;
  final TransformationController _transformationController = TransformationController();

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }
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
                  ).then((result) {
                    if (result == true && mounted) {
                      _fetchArbol();
                    }
                  });
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
    final bodyColor = FluentTheme.of(context).typography.body?.color ?? const Color(0xFF000000);
    final dividerColor = FluentTheme.of(context).resources.dividerStrokeColorDefault ?? bodyColor.withOpacity(0.1);

    if (_groupByClient) {
      return _buildByClient(filterLow, primaryColor, bodyColor, dividerColor);
    } else {
      return _buildByProject(filterLow, primaryColor, bodyColor, dividerColor);
    }
  }

  Widget _buildCardNode({
    required Widget child,
    required bool initiallyExpanded,
    required List<Widget> children,
    required Color cardColor,
    required Color borderColor,
  }) {
    return _CustomNode(
      initiallyExpanded: initiallyExpanded,
      header: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: cardColor,
            border: Border.all(color: borderColor),
            borderRadius: BorderRadius.circular(8),
          ),
          child: child,
        ),
      ),
      children: children,
    );
  }

  Widget _buildRevisionRow(dynamic rev, Color cardColor, Color dividerColor, Color bodyColor, Color primaryColor, int verId, String versionName, String tractoName) {
    final bool aprobada = rev['estado'] == 'Aprobada';
    return _buildCardNode(
      initiallyExpanded: false,
      cardColor: cardColor,
      borderColor: dividerColor.withOpacity(0.2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: rev['estado'],
            child: Container(
              width: 10,
              height: 10,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(color: aprobada ? const Color(0xFF4CAF50) : const Color(0xFFFF9800), shape: BoxShape.circle),
            ),
          ),
          Text("Rev ${rev['numero_revision']}  •  ${rev['estado']}", style: TextStyle(fontSize: 13, color: bodyColor)),
          const SizedBox(width: 16),
          Tooltip(
            message: "Abrir Gestor de BOM para esta revisión",
            child: IconButton(
              icon: Icon(FluentIcons.open_in_new_window, size: 14, color: primaryColor),
              onPressed: () async {
                final result = await Navigator.push(
                  context,
                  FluentPageRoute(
                    builder: (_) => BOMManagerScreen(
                      idVersion: verId,
                      versionName: versionName,
                      tractoName: tractoName,
                    ),
                  ),
                );
                if (result == true && mounted) {
                  await _fetchArbol();
                }
              },
            ),
          ),
        ],
      ),
      children: [],
    );
  }

  List<Widget> _buildByProject(String filterLow, Color primaryColor, Color bodyColor, Color dividerColor) {
    final cardColor = FluentTheme.of(context).cardColor;
    return _arbol.map<Widget>((tracto) {
      final tractoNombre = tracto['nombre'] as String;
      final tipos = (tracto['tipos'] as List).where((tp) {
        if (filterLow.isEmpty) return true;
        if ((tp['nombre'] as String).toLowerCase().contains(filterLow)) return true;
        return (tp['versiones'] as List).any((v) => (v['nombre'] as String).toLowerCase().contains(filterLow));
      }).toList();

      if (filterLow.isNotEmpty && tipos.isEmpty && !tractoNombre.toLowerCase().contains(filterLow)) {
        return const SizedBox.shrink();
      }

      return _buildCardNode(
        initiallyExpanded: false,
        cardColor: cardColor,
        borderColor: dividerColor.withOpacity(0.5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 12, height: 12, decoration: BoxDecoration(color: primaryColor, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Expanded(child: Text(tractoNombre, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: bodyColor))),
          ],
        ),
        children: tipos.map<Widget>((tipo) {
          return _buildCardNode(
            initiallyExpanded: false,
            cardColor: cardColor,
            borderColor: dividerColor.withOpacity(0.4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(FluentIcons.build_definition, size: 14, color: primaryColor.withOpacity(0.7)),
                const SizedBox(width: 8),
                Expanded(child: Text(tipo['nombre'], style: TextStyle(fontWeight: FontWeight.w600, color: bodyColor))),
              ],
            ),
            children: (tipo['versiones'] as List).map<Widget>((ver) {
              final revisiones = ver['revisiones'] as List;
              if (revisiones.isEmpty) {
                return _buildCardNode(
                  initiallyExpanded: false,
                  cardColor: cardColor,
                  borderColor: dividerColor.withOpacity(0.3),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(FluentIcons.fabric_open_folder_horizontal, size: 13, color: bodyColor.withOpacity(0.3)),
                      const SizedBox(width: 8),
                      Expanded(child: Text(ver['nombre'], style: TextStyle(fontStyle: FontStyle.italic, color: bodyColor.withOpacity(0.6)))),
                    ],
                  ),
                  children: [],
                );
              }

              Map<String, List<dynamic>> byCliente = {};
              for(var rev in revisiones) {
                String cl = rev['cliente'] ?? "General";
                byCliente.putIfAbsent(cl, () => []).add(rev);
              }

              return _buildCardNode(
                initiallyExpanded: false,
                cardColor: cardColor,
                borderColor: dividerColor.withOpacity(0.3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(FluentIcons.fabric_open_folder_horizontal, size: 13, color: primaryColor),
                    const SizedBox(width: 8),
                    Expanded(child: Text(ver['nombre'], style: TextStyle(fontStyle: FontStyle.italic, color: bodyColor))),
                  ],
                ),
                children: byCliente.entries.map<Widget>((entry) {
                   String clname = entry.key;
                   List<dynamic> revs = entry.value;
                   return _buildCardNode(
                     initiallyExpanded: false,
                     cardColor: cardColor,
                     borderColor: dividerColor.withOpacity(0.25),
                     child: Row(
                       mainAxisSize: MainAxisSize.min,
                       children: [
                         Icon(FluentIcons.accounts, size: 13, color: primaryColor.withOpacity(0.8)),
                         const SizedBox(width: 8),
                         Expanded(child: Text(clname, style: TextStyle(fontWeight: FontWeight.w500, color: bodyColor))),
                       ],
                     ),
                     children: revs.map<Widget>((item) {
                        return _buildRevisionRow(item, cardColor, dividerColor, bodyColor, primaryColor, ver['id'], ver['nombre'], tractoNombre);
                     }).toList(),
                   );
                }).toList(),
              );
            }).toList(),
          );
        }).toList(),
      );
    }).where((w) => w is! SizedBox).toList();
  }

  List<Widget> _buildByClient(String filterLow, Color primaryColor, Color bodyColor, Color dividerColor) {
    final cardColor = FluentTheme.of(context).cardColor;
    Map<String, Map<String, Map<String, Map<String, List<dynamic>>>>> hierarchy = {};
    
    for (var tracto in _arbol) {
      String trName = tracto['nombre'];
      for (var tipo in tracto['tipos']) {
        String tpName = tipo['nombre'];
        for (var ver in tipo['versiones']) {
           for (var rev in ver['revisiones']) {
              String clName = rev['cliente'] ?? 'General';
              
              if (filterLow.isNotEmpty) {
                 if (!trName.toLowerCase().contains(filterLow) &&
                     !tpName.toLowerCase().contains(filterLow) &&
                     !ver['nombre'].toLowerCase().contains(filterLow)) {
                    continue;
                 }
              }

              hierarchy.putIfAbsent(clName, () => {});
              hierarchy[clName]!.putIfAbsent(trName, () => {});
              hierarchy[clName]![trName]!.putIfAbsent(tpName, () => {});
              hierarchy[clName]![trName]![tpName]!.putIfAbsent(ver['nombre'], () => []);
              
              hierarchy[clName]![trName]![tpName]![ver['nombre']]!.add({
                "rev": rev,
                "verId": ver['id'],
              });
           }
        }
      }
    }

    return hierarchy.entries.map<Widget>((clEntry) {
       return _buildCardNode(
         initiallyExpanded: false,
         cardColor: cardColor,
         borderColor: dividerColor.withOpacity(0.5),
         child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 12, height: 12, decoration: BoxDecoration(color: primaryColor, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Expanded(child: Text(clEntry.key, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: bodyColor))),
            ],
         ),
         children: clEntry.value.entries.map<Widget>((trEntry) {
             return _buildCardNode(
               initiallyExpanded: false,
               cardColor: cardColor,
               borderColor: dividerColor.withOpacity(0.4),
               child: Row(
                 mainAxisSize: MainAxisSize.min,
                 children: [
                   Icon(FluentIcons.transportation, size: 14, color: primaryColor.withOpacity(0.7)),
                   const SizedBox(width: 8),
                   Expanded(child: Text(trEntry.key, style: TextStyle(fontWeight: FontWeight.w600, color: bodyColor))),
                 ],
               ),
               children: trEntry.value.entries.map<Widget>((tpEntry) {
                  return _buildCardNode(
                    initiallyExpanded: false,
                    cardColor: cardColor,
                    borderColor: dividerColor.withOpacity(0.3),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(FluentIcons.build_definition, size: 13, color: primaryColor.withOpacity(0.8)),
                        const SizedBox(width: 8),
                        Expanded(child: Text(tpEntry.key, style: TextStyle(fontWeight: FontWeight.w500, color: bodyColor))),
                      ],
                    ),
                    children: tpEntry.value.entries.map<Widget>((vEntry) {
                       return _buildCardNode(
                         initiallyExpanded: false,
                         cardColor: cardColor,
                         borderColor: dividerColor.withOpacity(0.2),
                         child: Row(
                           mainAxisSize: MainAxisSize.min,
                           children: [
                             Icon(FluentIcons.fabric_open_folder_horizontal, size: 13, color: primaryColor),
                             const SizedBox(width: 8),
                             Expanded(child: Text(vEntry.key, style: TextStyle(fontStyle: FontStyle.italic, color: bodyColor))),
                           ],
                         ),
                         children: vEntry.value.map<Widget>((item) {
                            return _buildRevisionRow(item['rev'], cardColor, dividerColor, bodyColor, primaryColor, item['verId'], vEntry.key, trEntry.key);
                         }).toList(),
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
          children: [
            SizedBox(
              width: 180,
              child: ComboBox<bool>(
                value: _groupByClient,
                items: const [
                  ComboBoxItem(value: false, child: Text("Por Proyecto")),
                  ComboBoxItem(value: true, child: Text("Por Cliente")),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _groupByClient = v);
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextBox(
                placeholder: 'Crit. de Búsqueda...',
                prefix: const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(FluentIcons.search, size: 14),
                ),
                onChanged: (v) => setState(() => _filter = v),
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: "Centrar Mapa a Origen",
              child: IconButton(
                icon: const Icon(FluentIcons.home),
                onPressed: () {
                  _transformationController.value = Matrix4.identity();
                },
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: "Recargar árbol",
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
                        transformationController: _transformationController,
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
