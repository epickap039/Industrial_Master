import 'package:fluent_ui/fluent_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api_client.dart';
import '../theme/ui_tokens.dart';
import '../widgets/compact_page_header.dart';

class CodeGeneratorScreen extends StatefulWidget {
  const CodeGeneratorScreen({super.key});

  @override
  State<CodeGeneratorScreen> createState() => _CodeGeneratorScreenState();
}

class _CodeGeneratorScreenState extends State<CodeGeneratorScreen> {
  final _formKey = GlobalKey<FormState>();
  final _codigoCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _largoCtrl = TextEditingController();
  final _anchoCtrl = TextEditingController();
  final _espesorCtrl = TextEditingController();
  final _simDetalleCtrl = TextEditingController();
  final _refPlanoCtrl = TextEditingController();

  bool _simetria = false;
  bool _guardando = false;
  String _material = '';
  String _procPrimario = '';
  String _proc1 = '';
  String _proc2 = '';
  String _proc3 = '';
  List<String> _materiales = const [];
  List<String> _procesos = const [];

  @override
  void initState() {
    super.initState();
    _cargarMateriales();
    _cargarProcesos();
  }

  @override
  void dispose() {
    _codigoCtrl.dispose();
    _descCtrl.dispose();
    _largoCtrl.dispose();
    _anchoCtrl.dispose();
    _espesorCtrl.dispose();
    _simDetalleCtrl.dispose();
    _refPlanoCtrl.dispose();
    super.dispose();
  }

  Future<void> _cargarMateriales() async {
    try {
      final raw = await ApiClient.get('/api/config/materiales');
      final mats = (raw is List ? raw : const [])
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
      if (!mounted) return;
      setState(() {
        _materiales = mats;
        if (_material.isEmpty && mats.isNotEmpty) {
          _material = mats.first;
        }
      });
    } catch (_) {}
  }

  Future<void> _cargarProcesos() async {
    try {
      final raw = await ApiClient.get('/api/catalog/procesos');
      final p = (raw is List ? raw : const [])
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
      if (!mounted) return;
      setState(() {
        _procesos = p;
        if (_procPrimario.isEmpty && p.isNotEmpty) {
          _procPrimario = p.first;
        }
      });
    } catch (_) {}
  }

  double? _numOrNull(String v) {
    final s = v.trim().replaceAll(',', '.');
    if (s.isEmpty) return null;
    return double.tryParse(s);
  }

  Future<void> _guardar() async {
    if (!_formKey.currentState!.validate()) return;
    final codigo = _codigoCtrl.text.trim().toUpperCase();
    final procesos = <String>[
      _procPrimario.trim(),
      _proc1.trim(),
      _proc2.trim(),
      _proc3.trim(),
    ].where((e) => e.isNotEmpty).toList();
    if (procesos.isEmpty) {
      if (!mounted) return;
      displayInfoBar(
        context,
        builder: (c, close) => InfoBar(
          title: const Text('Proceso requerido'),
          content: const Text('Selecciona al menos un proceso para registrar la pieza.'),
          severity: InfoBarSeverity.warning,
          onClose: close,
        ),
      );
      return;
    }
    setState(() => _guardando = true);
    try {
      final exists = await ApiClient.getUnvalidated('/api/catalog/pieza/$codigo');
      if (exists.statusCode == 200) {
        throw Exception('El código $codigo ya existe en el catálogo.');
      }
      final prefs = await SharedPreferences.getInstance();
      final usuario = (prefs.getString('username') ?? 'GeneradorCodigo').trim();
      await ApiClient.post(
        '/api/catalog/generador/crear',
        body: {
          'codigo': codigo,
          'procesos': procesos,
          'descripcion': _descCtrl.text.trim(),
          'material': _material.trim(),
          'largo': _numOrNull(_largoCtrl.text),
          'ancho': _numOrNull(_anchoCtrl.text),
          'espesor': _numOrNull(_espesorCtrl.text),
          'simetria': _simetria,
          'detalle_simetria': _simDetalleCtrl.text.trim(),
          'referencia_plano': _refPlanoCtrl.text.trim(),
          'usuario': usuario,
        },
      );
      if (!mounted) return;
      displayInfoBar(
        context,
        builder: (c, close) => InfoBar(
          title: const Text('Código registrado'),
          content: Text('La pieza $codigo se agregó al catálogo maestro.'),
          severity: InfoBarSeverity.success,
          onClose: close,
        ),
      );
      _formKey.currentState?.reset();
      _codigoCtrl.clear();
      _descCtrl.clear();
      _largoCtrl.clear();
      _anchoCtrl.clear();
      _espesorCtrl.clear();
      _simDetalleCtrl.clear();
      _refPlanoCtrl.clear();
      setState(() {
        _simetria = false;
        _proc1 = '';
        _proc2 = '';
        _proc3 = '';
      });
    } catch (e) {
      if (!mounted) return;
      displayInfoBar(
        context,
        builder: (c, close) => InfoBar(
          title: const Text('No se pudo registrar'),
          content: Text('$e'),
          severity: InfoBarSeverity.error,
          onClose: close,
        ),
      );
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = uiSurfacePaletteOf(context);
    return ScaffoldPage(
      header: const CompactPageHeader(
        title: Text('Generador de Código'),
      ),
      content: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1080),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 7,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Form(
                      key: _formKey,
                      child: ListView(
                        children: [
                          const Text(
                            'Nota temporal: mientras se termina el generador automático, '
                            'el código debe capturarse manualmente.',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 12),
                          TextFormBox(
                            controller: _codigoCtrl,
                            placeholder: 'Código (obligatorio)',
                            onChanged: (_) => setState(() {}),
                            validator: (v) =>
                                (v == null || v.trim().isEmpty) ? 'Ingresa un código' : null,
                          ),
                          const SizedBox(height: 8),
                          ComboBox<String>(
                            isExpanded: true,
                            value: _procPrimario.isNotEmpty ? _procPrimario : null,
                            placeholder: const Text('Proceso primario (obligatorio)'),
                            items: _procesos
                                .map((m) => ComboBoxItem(value: m, child: Text(m)))
                                .toList(),
                            onChanged: (v) => setState(() => _procPrimario = v ?? ''),
                          ),
                          if (_procPrimario.isEmpty)
                            const Padding(
                              padding: EdgeInsets.only(top: 4),
                              child: Text(
                                'Selecciona un proceso primario.',
                                style: TextStyle(fontSize: 11, color: Color(0xFFE57373)),
                              ),
                            ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: ComboBox<String>(
                                  isExpanded: true,
                                  value: _proc1.isNotEmpty ? _proc1 : null,
                                  placeholder: const Text('Proceso 1 (opcional)'),
                                  items: _procesos
                                      .map((m) => ComboBoxItem(value: m, child: Text(m)))
                                      .toList(),
                                  onChanged: (v) => setState(() => _proc1 = v ?? ''),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: ComboBox<String>(
                                  isExpanded: true,
                                  value: _proc2.isNotEmpty ? _proc2 : null,
                                  placeholder: const Text('Proceso 2 (opcional)'),
                                  items: _procesos
                                      .map((m) => ComboBoxItem(value: m, child: Text(m)))
                                      .toList(),
                                  onChanged: (v) => setState(() => _proc2 = v ?? ''),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: ComboBox<String>(
                                  isExpanded: true,
                                  value: _proc3.isNotEmpty ? _proc3 : null,
                                  placeholder: const Text('Proceso 3 (opcional)'),
                                  items: _procesos
                                      .map((m) => ComboBoxItem(value: m, child: Text(m)))
                                      .toList(),
                                  onChanged: (v) => setState(() => _proc3 = v ?? ''),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          TextBox(
                            controller: _descCtrl,
                            placeholder: 'Descripción (opcional)',
                            onChanged: (_) => setState(() {}),
                          ),
                          const SizedBox(height: 8),
                          ComboBox<String>(
                            isExpanded: true,
                            value: _material.isNotEmpty ? _material : null,
                            placeholder: const Text('Material oficial'),
                            items: _materiales
                                .map((m) => ComboBoxItem(value: m, child: Text(m)))
                                .toList(),
                            onChanged: (v) => setState(() => _material = v ?? ''),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: TextBox(
                                  controller: _largoCtrl,
                                  placeholder: 'Largo (opcional)',
                                  onChanged: (_) => setState(() {}),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextBox(
                                  controller: _anchoCtrl,
                                  placeholder: 'Ancho (opcional)',
                                  onChanged: (_) => setState(() {}),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextBox(
                                  controller: _espesorCtrl,
                                  placeholder: 'Espesor (opcional)',
                                  onChanged: (_) => setState(() {}),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Checkbox(
                            checked: _simetria,
                            content: const Text('Tiene simetría'),
                            onChanged: (v) => setState(() => _simetria = v ?? false),
                          ),
                          if (_simetria) ...[
                            const SizedBox(height: 6),
                            TextBox(
                              controller: _simDetalleCtrl,
                              placeholder: 'Detalle de simetría (medida o nota)',
                              onChanged: (_) => setState(() {}),
                            ),
                          ],
                          const SizedBox(height: 8),
                          TextBox(
                            controller: _refPlanoCtrl,
                            placeholder: 'Referencia de plano (opcional)',
                            onChanged: (_) => setState(() {}),
                          ),
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              FilledButton(
                                onPressed: _guardando ? null : _guardar,
                                child: _guardando
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: ProgressRing(strokeWidth: 2),
                                      )
                                    : const Text('Registrar código'),
                              ),
                              const SizedBox(width: 8),
                              Button(
                                onPressed: _guardando
                                    ? null
                                    : () {
                                        _formKey.currentState?.reset();
                                        _codigoCtrl.clear();
                                        _descCtrl.clear();
                                        _largoCtrl.clear();
                                        _anchoCtrl.clear();
                                        _espesorCtrl.clear();
                                        _simDetalleCtrl.clear();
                                        _refPlanoCtrl.clear();
                                        setState(() {
                                          _simetria = false;
                                          _proc1 = '';
                                          _proc2 = '';
                                          _proc3 = '';
                                        });
                                      },
                                child: const Text('Limpiar'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 5,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Vista previa catálogo maestro',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        _previewRow('Código', _codigoCtrl.text.trim().toUpperCase()),
                        _previewRow('Descripción', _descCtrl.text.trim()),
                        _previewRow('Material', _material),
                        _previewRow(
                          'Procesos',
                          [
                            _procPrimario,
                            _proc1,
                            _proc2,
                            _proc3,
                          ].where((e) => e.trim().isNotEmpty).join(' | '),
                        ),
                        _previewRow(
                          'Medida',
                          [
                            if (_largoCtrl.text.trim().isNotEmpty) 'L:${_largoCtrl.text.trim()}',
                            if (_anchoCtrl.text.trim().isNotEmpty) 'A:${_anchoCtrl.text.trim()}',
                            if (_espesorCtrl.text.trim().isNotEmpty) 'E:${_espesorCtrl.text.trim()}',
                          ].join(' | '),
                        ),
                        _previewRow('Simetría', _simetria ? 'SI' : 'NO'),
                        _previewRow('Detalle simetría', _simDetalleCtrl.text.trim()),
                        _previewRow('Plano', _refPlanoCtrl.text.trim()),
                        const Spacer(),
                        Text(
                          'Esta vista permite validar cómo quedará el registro antes de guardar.',
                          style: TextStyle(color: palette.textSecondary, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _previewRow(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(k, style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 6),
          Expanded(child: Text(v.isEmpty ? '-' : v)),
        ],
      ),
    );
  }
}
