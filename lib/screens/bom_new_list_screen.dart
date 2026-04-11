import 'package:fluent_ui/fluent_ui.dart';

import '../services/api_client.dart';
import '../widgets/compact_page_header.dart';

class BomNewListScreen extends StatefulWidget {
  const BomNewListScreen({super.key, required this.idRevision});

  final int idRevision;

  @override
  State<BomNewListScreen> createState() => _BomNewListScreenState();
}

class _StationDraft {
  _StationDraft(this.nombre);
  String nombre;
  final List<_AssemblyDraft> ensambles = [];
}

class _AssemblyDraft {
  _AssemblyDraft(this.nombre, {this.esProveedor = false});
  String nombre;
  bool esProveedor;
}

class _BomNewListScreenState extends State<BomNewListScreen> {
  final _nombreEstCtrl = TextEditingController();
  final _nombreEnsCtrl = TextEditingController();
  bool _ensProveedor = false;
  bool _saving = false;
  int _selectedStation = -1;
  final List<_StationDraft> _stations = [];

  @override
  void dispose() {
    _nombreEstCtrl.dispose();
    _nombreEnsCtrl.dispose();
    super.dispose();
  }

  Future<void> _guardarEstructura() async {
    if (_stations.isEmpty) return;
    setState(() => _saving = true);
    try {
      for (final st in _stations) {
        await ApiClient.post(
          '/api/bom/estaciones',
          body: {'id_revision': widget.idRevision, 'nombre': st.nombre},
        );
      }
      final tree = await ApiClient.get('/api/bom/arbol/${widget.idRevision}');
      final estacionesActuales = (tree is List ? tree : const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e.map((k, v) => MapEntry('$k', v))))
          .toList();
      for (final st in _stations) {
        final match = estacionesActuales.firstWhere(
          (e) => (e['nombre'] ?? '').toString().trim().toUpperCase() == st.nombre.trim().toUpperCase(),
          orElse: () => <String, dynamic>{},
        );
        final idEst = match['id'] is int ? match['id'] as int : int.tryParse('${match['id'] ?? ''}');
        if (idEst == null) continue;
        for (final ens in st.ensambles) {
          final nombreFinal = ens.esProveedor ? '[PROVEEDOR] ${ens.nombre}' : ens.nombre;
          await ApiClient.post(
            '/api/bom/ensambles',
            body: {'id_estacion': idEst, 'nombre': nombreFinal},
          );
        }
      }
      if (!mounted) return;
      displayInfoBar(
        context,
        builder: (c, close) => InfoBar(
          title: const Text('Estructura creada'),
          content: const Text('Se registraron estaciones y ensambles para la revisión actual.'),
          severity: InfoBarSeverity.success,
          onClose: close,
        ),
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      displayInfoBar(
        context,
        builder: (c, close) => InfoBar(
          title: const Text('No se pudo crear la lista'),
          content: Text('$e'),
          severity: InfoBarSeverity.error,
          onClose: close,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage(
      header: const CompactPageHeader(
        title: Text('Crear lista nueva'),
      ),
      content: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Define estaciones y ensambles en un solo flujo. '
              'Puedes repetir ensambles en varias estaciones (multiestación) y marcar ensambles de proveedor.',
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text('Estaciones', style: TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: TextBox(
                                    controller: _nombreEstCtrl,
                                    placeholder: 'Nombre de estación',
                                  ),
                                ),
                                const SizedBox(width: 8),
                                FilledButton(
                                  onPressed: () {
                                    final n = _nombreEstCtrl.text.trim();
                                    if (n.isEmpty) return;
                                    setState(() {
                                      _stations.add(_StationDraft(n.toUpperCase()));
                                      _selectedStation = _stations.length - 1;
                                      _nombreEstCtrl.clear();
                                    });
                                  },
                                  child: const Text('Agregar'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Expanded(
                              child: ListView.builder(
                                itemCount: _stations.length,
                                itemBuilder: (c, i) {
                                  final s = _stations[i];
                                  final selected = i == _selectedStation;
                                  return ListTile.selectable(
                                    selected: selected,
                                    title: Text(s.nombre),
                                    subtitle: Text('${s.ensambles.length} ensamble(s)'),
                                    onPressed: () => setState(() => _selectedStation = i),
                                    trailing: IconButton(
                                      icon: const Icon(FluentIcons.delete),
                                      onPressed: () => setState(() {
                                        _stations.removeAt(i);
                                        if (_selectedStation >= _stations.length) {
                                          _selectedStation = _stations.length - 1;
                                        }
                                      }),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text('Ensamble por estación', style: TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: TextBox(
                                    controller: _nombreEnsCtrl,
                                    placeholder: 'Nombre de ensamble',
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Checkbox(
                                  checked: _ensProveedor,
                                  content: const Text('Proveedor'),
                                  onChanged: (v) => setState(() => _ensProveedor = v ?? false),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            FilledButton(
                              onPressed: _selectedStation < 0
                                  ? null
                                  : () {
                                      final n = _nombreEnsCtrl.text.trim();
                                      if (n.isEmpty) return;
                                      setState(() {
                                        _stations[_selectedStation].ensambles.add(
                                          _AssemblyDraft(n.toUpperCase(), esProveedor: _ensProveedor),
                                        );
                                        _nombreEnsCtrl.clear();
                                        _ensProveedor = false;
                                      });
                                    },
                              child: const Text('Agregar ensamble'),
                            ),
                            const SizedBox(height: 8),
                            Expanded(
                              child: ListView(
                                children: [
                                  if (_selectedStation < 0)
                                    const Text('Selecciona una estación para cargar ensambles.')
                                  else
                                    for (var i = 0;
                                        i < _stations[_selectedStation].ensambles.length;
                                        i++)
                                      ListTile(
                                        title: Text(_stations[_selectedStation].ensambles[i].nombre),
                                        subtitle: Text(
                                          _stations[_selectedStation].ensambles[i].esProveedor
                                              ? 'Tipo: proveedor'
                                              : 'Tipo: interno / multiestación',
                                        ),
                                        trailing: IconButton(
                                          icon: const Icon(FluentIcons.delete),
                                          onPressed: () => setState(
                                            () => _stations[_selectedStation].ensambles.removeAt(i),
                                          ),
                                        ),
                                      ),
                                ],
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
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Button(
                  onPressed: _saving ? null : () => Navigator.pop(context, false),
                  child: const Text('Regresar'),
                ),
                const SizedBox(width: 8),
                Button(
                  onPressed: _saving ? null : () => Navigator.pop(context, false),
                  child: const Text('Cancelar'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _saving ? null : _guardarEstructura,
                  child: _saving
                      ? const SizedBox(width: 16, height: 16, child: ProgressRing(strokeWidth: 2))
                      : const Text('Crear estructura'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
