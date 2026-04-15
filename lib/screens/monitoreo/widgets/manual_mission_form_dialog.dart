import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:pasteboard/pasteboard.dart';

import '../../../services/api_client.dart';
import '../../../services/usuarios_lookup_service.dart';

/// Opciones si el servidor aún no tiene usuarios en `Tbl_Comando_Usuarios`.
const List<String> kResponsablesMisionFallback = [
  'Equipo Ingeniería',
  'Equipo CAD',
  'Documentación',
  'Producción / Procesos',
  'Calidad',
  'Sin asignar',
];

const List<String> kCategoriasMision = [
  'Cambio estructural',
  'Documentación',
  'Urgencia',
  'Mejora continua',
  'Correctivo',
  'Preventivo',
  'Otro',
];

const String kTodosResponsablesToken = '__TODOS__';
const int kMinutosPorJornadaLaboral = 9 * 60;

String? _base64SinPrefijoDataUrl(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;
  final i = s.indexOf('base64,');
  if (i >= 0) return s.substring(i + 7).trim();
  return s;
}

/// Formulario modal para `POST /api/tareas/crear_manual`.
/// Responsable: lista desde `GET /api/usuarios/lista` (`username`).
Future<bool> showManualMissionFormDialog(BuildContext context) async {
  final responsables = await UsuariosLookupService.instance.getResponsables();

  if (!context.mounted) return false;

  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    barrierColor:
        Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF121212)
            : Colors.white,
    builder: (ctx) => _ManualMissionDialog(responsables: responsables),
  );

  return ok == true;
}

class _ManualMissionDialog extends StatefulWidget {
  const _ManualMissionDialog({required this.responsables});

  final List<String> responsables;

  @override
  State<_ManualMissionDialog> createState() => _ManualMissionDialogState();
}

class _ManualMissionDialogState extends State<_ManualMissionDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _tituloCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _diasCtrl;
  late final TextEditingController _horasCtrl;
  late final TextEditingController _minutosCtrl;
  late final TextEditingController _pasoCtrl;
  late final List<TextEditingController> _pasoExtraCtrls;
  String? _responsable;
  String? _categoria;
  String? _imagenBase64;
  final List<String?> _imagenExtraBase64 = <String?>[null, null];
  bool _enviando = false;
  int _slotCount = 1;
  bool _asignarMultiples = false;
  bool _asignarATodos = false;
  final Set<String> _responsablesSeleccionados = <String>{};
  late final List<TextEditingController> _tituloExtraCtrls;
  late final List<TextEditingController> _descExtraCtrls;
  late final List<TextEditingController> _diasExtraCtrls;
  late final List<TextEditingController> _horasExtraCtrls;
  late final List<TextEditingController> _minutosExtraCtrls;
  final List<String?> _responsableExtra = <String?>[null, null];
  final List<String?> _categoriaExtra = <String?>[null, null];
  final List<bool> _sinTiempoExtra = <bool>[false, false];

  /// Si true, no se envía presupuesto de tiempo (carga acumulada ignora esta misión).
  bool _sinTiempoEstimado = false;

  /// Items de checklist para la tarea
  final List<Map<String, dynamic>> _checklistItems = [];
  final List<List<Map<String, dynamic>>> _checklistItemsExtra = <List<Map<String, dynamic>>>[
    <Map<String, dynamic>>[],
    <Map<String, dynamic>>[],
  ];

  @override
  void initState() {
    super.initState();
    _tituloCtrl = TextEditingController();
    _descCtrl = TextEditingController();
    _diasCtrl = TextEditingController(text: '0');
    _horasCtrl = TextEditingController(text: '0');
    _minutosCtrl = TextEditingController(text: '0');
    _pasoCtrl = TextEditingController();
    _pasoExtraCtrls = List<TextEditingController>.generate(
      2,
      (_) => TextEditingController(),
    );
    _tituloExtraCtrls = List<TextEditingController>.generate(
      2,
      (_) => TextEditingController(),
    );
    _descExtraCtrls = List<TextEditingController>.generate(
      2,
      (_) => TextEditingController(),
    );
    _diasExtraCtrls = List<TextEditingController>.generate(
      2,
      (_) => TextEditingController(text: '0'),
    );
    _horasExtraCtrls = List<TextEditingController>.generate(
      2,
      (_) => TextEditingController(text: '0'),
    );
    _minutosExtraCtrls = List<TextEditingController>.generate(
      2,
      (_) => TextEditingController(text: '0'),
    );
    _responsable = widget.responsables.first;
    if (_responsable != null && _responsable!.isNotEmpty) {
      _responsablesSeleccionados.add(_responsable!);
    }
    _categoria = kCategoriasMision.first;
  }

  @override
  void dispose() {
    _tituloCtrl.dispose();
    _descCtrl.dispose();
    _diasCtrl.dispose();
    _horasCtrl.dispose();
    _minutosCtrl.dispose();
    _pasoCtrl.dispose();
    for (final c in _pasoExtraCtrls) {
      c.dispose();
    }
    for (final c in _tituloExtraCtrls) {
      c.dispose();
    }
    for (final c in _descExtraCtrls) {
      c.dispose();
    }
    for (final c in _diasExtraCtrls) {
      c.dispose();
    }
    for (final c in _horasExtraCtrls) {
      c.dispose();
    }
    for (final c in _minutosExtraCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  List<Map<String, dynamic>> _checklistForCard(int cardIndex) {
    if (cardIndex == 0) return _checklistItems;
    return _checklistItemsExtra[cardIndex - 1];
  }

  TextEditingController _pasoCtrlForCard(int cardIndex) {
    if (cardIndex == 0) return _pasoCtrl;
    return _pasoExtraCtrls[cardIndex - 1];
  }

  String? _imagenForCard(int cardIndex) {
    if (cardIndex == 0) return _imagenBase64;
    return _imagenExtraBase64[cardIndex - 1];
  }

  void _setImagenForCard(int cardIndex, String? value) {
    if (cardIndex == 0) {
      _imagenBase64 = value;
      return;
    }
    _imagenExtraBase64[cardIndex - 1] = value;
  }

  void _agregarPasoCard(int cardIndex) {
    final paso = _pasoCtrlForCard(cardIndex).text.trim();
    if (paso.isEmpty) return;
    setState(() {
      _checklistForCard(cardIndex).add({
        'nombre': paso,
        'completado': 0,
        'minutos': 0,
        'grupo': '',
      });
    });
    _pasoCtrlForCard(cardIndex).clear();
  }

  void _removerPasoCard(int cardIndex, int pasoIndex) {
    setState(() => _checklistForCard(cardIndex).removeAt(pasoIndex));
  }

  void _agregarPaso() => _agregarPasoCard(0);

  void _removerPaso(int index) => _removerPasoCard(0, index);

  Future<void> _pegarPortapapelesCard(int cardIndex) async {
    try {
      final Uint8List? bytes = await Pasteboard.image;
      if (bytes != null && bytes.isNotEmpty) {
        setState(() => _setImagenForCard(cardIndex, base64Encode(bytes)));
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Portapapeles sin imagen')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo leer el portapapeles: $e')),
        );
      }
    }
  }

  void _activarModoTresTarjetas() {
    setState(() {
      _slotCount = 3;
      for (var i = 0; i < 2; i++) {
        _responsableExtra[i] ??= _responsable;
        _categoriaExtra[i] ??= _categoria;
      }
    });
  }

  Future<void> _pegarPortapapeles() async {
    await _pegarPortapapelesCard(0);
  }

  Future<void> _elegirArchivoCard(int cardIndex) async {
    try {
      final r = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );
      if (r == null || r.files.isEmpty) return;
      final b = r.files.first.bytes;
      if (b != null && b.isNotEmpty) {
        setState(() => _setImagenForCard(cardIndex, base64Encode(b)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error al elegir archivo: $e')));
      }
    }
  }

  Future<void> _elegirArchivo() async {
    await _elegirArchivoCard(0);
  }

  Future<void> _crear() async {
    if (_slotCount > 1) {
      await _crearModoTresTarjetas();
      return;
    }
    if (!_formKey.currentState!.validate()) return;
    if (!_sinTiempoEstimado) {
      final dp = int.tryParse(_diasCtrl.text.trim());
      final hp = int.tryParse(_horasCtrl.text.trim());
      final mp = int.tryParse(_minutosCtrl.text.trim());
      if (dp == null || dp < 0 || hp == null || hp < 0 || mp == null || mp < 0) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Indique días/horas/minutos válidos (>= 0) o marque "No aplica".',
              ),
            ),
          );
        }
        return;
      }
    }
    setState(() => _enviando = true);
    try {
      final diasParse = int.tryParse(_diasCtrl.text.trim()) ?? 0;
      final horasParse = int.tryParse(_horasCtrl.text.trim()) ?? 0;
      final minParse = int.tryParse(_minutosCtrl.text.trim());
      final int totalMin =
          _sinTiempoEstimado
              ? 0
              : (diasParse * kMinutosPorJornadaLaboral) +
                    (horasParse * 60) +
                    (minParse ?? 0);
      final Set<String> responsablesPayload = <String>{};
      final principal = (_responsable ?? '').trim();
      if (principal.isNotEmpty) responsablesPayload.add(principal);
      if (_asignarMultiples) {
        responsablesPayload.addAll(
          _responsablesSeleccionados.where((u) => u.trim().isNotEmpty),
        );
      }
      if (!_asignarATodos && responsablesPayload.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Seleccione al menos un responsable.')),
          );
        }
        setState(() => _enviando = false);
        return;
      }
      final principalBody = <String, dynamic>{
        'titulo': _tituloCtrl.text.trim(),
        'descripcion': _descCtrl.text.trim(),
        'responsable': principal,
        'responsables': _asignarATodos
            ? const [kTodosResponsablesToken]
            : responsablesPayload.toList(),
        'categoria': _categoria ?? '',
        'minutos_estimados': totalMin,
        'sin_tiempo_estimado': _sinTiempoEstimado,
        'checklist': _checklistItems,
      };
      final img =
          _imagenBase64 == null
              ? null
              : _base64SinPrefijoDataUrl(_imagenBase64!);
      if (img != null && img.isNotEmpty) {
        principalBody['imagen_base64'] = img;
      }

      final payloads = <Map<String, dynamic>>[principalBody];
      if (_slotCount > 1) {
        for (var i = 0; i < 2; i++) {
          final title = _tituloExtraCtrls[i].text.trim();
          if (title.isEmpty) continue;
          final resp = (_responsableExtra[i] ?? principal).trim();
          payloads.add({
            'titulo': title,
            'descripcion': _descExtraCtrls[i].text.trim(),
            'responsable': resp,
            'responsables': [resp],
            'categoria': _categoria ?? '',
            'minutos_estimados': totalMin,
            'sin_tiempo_estimado': _sinTiempoEstimado,
            'checklist': const <Map<String, dynamic>>[],
          });
        }
      }

      final errores = <String>[];
      for (var i = 0; i < payloads.length; i++) {
        try {
          await ApiClient.post('/api/tareas/crear_manual', body: payloads[i]);
        } catch (e) {
          errores.add('Misión ${i + 1}: $e');
        }
      }
      if (errores.isNotEmpty) {
        throw Exception(errores.join('\n'));
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() => _enviando = false);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  int? _totalMinFromInputs({
    required TextEditingController diasCtrl,
    required TextEditingController horasCtrl,
    required TextEditingController minutosCtrl,
    required bool sinTiempo,
  }) {
    if (sinTiempo) return 0;
    final dp = int.tryParse(diasCtrl.text.trim());
    final hp = int.tryParse(horasCtrl.text.trim());
    final mp = int.tryParse(minutosCtrl.text.trim());
    if (dp == null || dp < 0 || hp == null || hp < 0 || mp == null || mp < 0) {
      return null;
    }
    return (dp * kMinutosPorJornadaLaboral) + (hp * 60) + mp;
  }

  Future<void> _crearModoTresTarjetas() async {
    final cards = <Map<String, dynamic>>[
      {
        'titulo': _tituloCtrl.text.trim(),
        'descripcion': _descCtrl.text.trim(),
        'responsable': (_responsable ?? '').trim(),
        'categoria': _categoria ?? '',
        'minutos': _totalMinFromInputs(
          diasCtrl: _diasCtrl,
          horasCtrl: _horasCtrl,
          minutosCtrl: _minutosCtrl,
          sinTiempo: _sinTiempoEstimado,
        ),
        'sin_tiempo_estimado': _sinTiempoEstimado,
        'checklist': _checklistItems,
        'imagen_base64': _base64SinPrefijoDataUrl(_imagenBase64 ?? ''),
      },
      for (var i = 0; i < 2; i++)
        {
          'titulo': _tituloExtraCtrls[i].text.trim(),
          'descripcion': _descExtraCtrls[i].text.trim(),
          'responsable': (_responsableExtra[i] ?? '').trim(),
          'categoria': _categoriaExtra[i] ?? (_categoria ?? ''),
          'minutos': _totalMinFromInputs(
            diasCtrl: _diasExtraCtrls[i],
            horasCtrl: _horasExtraCtrls[i],
            minutosCtrl: _minutosExtraCtrls[i],
            sinTiempo: _sinTiempoExtra[i],
          ),
          'sin_tiempo_estimado': _sinTiempoExtra[i],
          'checklist': _checklistItemsExtra[i],
          'imagen_base64': _base64SinPrefijoDataUrl(_imagenExtraBase64[i] ?? ''),
        },
    ];

    final activos = cards.where((c) => (c['titulo'] as String).isNotEmpty).toList();
    if (activos.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Capture al menos un título para crear misión.')),
        );
      }
      return;
    }
    for (final c in activos) {
      if ((c['minutos'] as int?) == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Hay tarjetas con tiempo inválido. Use números >= 0 o marque "No aplica".'),
            ),
          );
        }
        return;
      }
      if ((c['responsable'] as String).isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Todas las tarjetas activas deben tener responsable.')),
          );
        }
        return;
      }
    }

    setState(() => _enviando = true);
    try {
      final errores = <String>[];
      for (var i = 0; i < activos.length; i++) {
        final c = activos[i];
        try {
          await ApiClient.post('/api/tareas/crear_manual', body: {
            'titulo': c['titulo'],
            'descripcion': c['descripcion'],
            'responsable': c['responsable'],
            'responsables': [c['responsable']],
            'categoria': c['categoria'],
            'minutos_estimados': c['minutos'],
            'sin_tiempo_estimado': c['sin_tiempo_estimado'],
            'checklist': c['checklist'] ?? const <Map<String, dynamic>>[],
            if ((c['imagen_base64'] as String?)?.isNotEmpty == true)
              'imagen_base64': c['imagen_base64'],
          });
        } catch (e) {
          errores.add('Tarjeta ${i + 1}: $e');
        }
      }
      if (errores.isNotEmpty) {
        throw Exception(errores.join('\n'));
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
      if (mounted) setState(() => _enviando = false);
    }
  }

  Widget _buildTarjetaMisionCompleta({
    required int cardIndex,
    required String tituloTarjeta,
    required double cardWidth,
    required TextEditingController tituloCtrl,
    required TextEditingController descCtrl,
    required TextEditingController diasCtrl,
    required TextEditingController horasCtrl,
    required TextEditingController minutosCtrl,
    required bool sinTiempo,
    required ValueChanged<bool> onSinTiempoChanged,
    required String? responsable,
    required ValueChanged<String?> onResponsableChanged,
    required String? categoria,
    required ValueChanged<String?> onCategoriaChanged,
    required List<String> responsables,
    required Color checklistBg,
    required Color checklistText,
    required Color checklistBorder,
  }) {
    final checklistItems = _checklistForCard(cardIndex);
    final pasoCtrl = _pasoCtrlForCard(cardIndex);
    final imagenBase64 = _imagenForCard(cardIndex);
    return SizedBox(
      width: cardWidth,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  tituloTarjeta,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: tituloCtrl,
                  enabled: !_enviando,
                  decoration: InputDecoration(
                    labelText: 'Título',
                    border: const OutlineInputBorder(),
                    hintText: cardIndex == 0 ? null : 'Si queda vacío, no se envía',
                  ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: descCtrl,
                  enabled: !_enviando,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Descripción',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: diasCtrl,
                        enabled: !_enviando && !sinTiempo,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Días',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: TextFormField(
                        controller: horasCtrl,
                        enabled: !_enviando && !sinTiempo,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Horas',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: TextFormField(
                        controller: minutosCtrl,
                        enabled: !_enviando && !sinTiempo,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Minutos',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilterChip(
                    label: const Text('No aplica'),
                    selected: sinTiempo,
                    onSelected: _enviando ? null : onSinTiempoChanged,
                  ),
                ),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  value: responsable,
                  decoration: const InputDecoration(
                    labelText: 'Responsable',
                    border: OutlineInputBorder(),
                  ),
                  items: responsables
                      .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                      .toList(),
                  onChanged: _enviando ? null : onResponsableChanged,
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: categoria,
                  decoration: const InputDecoration(
                    labelText: 'Categoría',
                    border: OutlineInputBorder(),
                  ),
                  items: kCategoriasMision
                      .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                      .toList(),
                  onChanged: _enviando ? null : onCategoriaChanged,
                ),
                const SizedBox(height: 12),
                Text(
                  'Checklist',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: checklistText,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                if (checklistItems.isNotEmpty)
                  Container(
                    constraints: const BoxConstraints(maxHeight: 110),
                    decoration: BoxDecoration(
                      color: checklistBg,
                      border: Border.all(color: checklistBorder, width: 0.5),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: checklistItems.length,
                      itemBuilder: (_, i) {
                        return ListTile(
                          dense: true,
                          title: Text(
                            checklistItems[i]['nombre'] ?? '',
                            style: Theme.of(
                              context,
                            ).textTheme.bodySmall?.copyWith(color: checklistText),
                          ),
                          trailing: IconButton(
                            onPressed: _enviando
                                ? null
                                : () => _removerPasoCard(cardIndex, i),
                            icon: const Icon(Icons.close, size: 16),
                          ),
                        );
                      },
                    ),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: pasoCtrl,
                        enabled: !_enviando,
                        decoration: const InputDecoration(
                          labelText: 'Nuevo paso',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onFieldSubmitted: _enviando
                            ? null
                            : (_) => _agregarPasoCard(cardIndex),
                      ),
                    ),
                    const SizedBox(width: 6),
                    IconButton(
                      onPressed: _enviando ? null : () => _agregarPasoCard(cardIndex),
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _enviando ? null : () => _pegarPortapapelesCard(cardIndex),
                      icon: const Icon(Icons.paste, size: 16),
                      label: const Text('Pegar imagen'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _enviando ? null : () => _elegirArchivoCard(cardIndex),
                      icon: const Icon(Icons.image_outlined, size: 16),
                      label: const Text('Subir imagen'),
                    ),
                    if (imagenBase64 != null && imagenBase64.isNotEmpty)
                      TextButton(
                        onPressed: _enviando
                            ? null
                            : () => setState(() => _setImagenForCard(cardIndex, null)),
                        child: const Text('Quitar'),
                      ),
                  ],
                ),
                if (imagenBase64 != null && imagenBase64.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Builder(
                    builder: (_) {
                      try {
                        final u8 = base64Decode(imagenBase64);
                        return ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.memory(
                            u8,
                            height: 74,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) =>
                                const Text('Vista previa no disponible'),
                          ),
                        );
                      } catch (_) {
                        return const Text('Vista previa no disponible');
                      }
                    },
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final responsables = widget.responsables;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final checklistBg = isDark
        ? const Color(0xFF2A2A2A)
        : const Color(0xFFF4F6FB);
    final checklistText = isDark
        ? const Color(0xFFE8E8E8)
        : const Color(0xFF1F2937);
    final checklistBorder = isDark
        ? const Color(0xFFB0B0B0)
        : const Color(0xFFD0D7E2);

    if (_slotCount > 1) {
      final screen = MediaQuery.of(context).size;
      final dialogWidth = (screen.width * 0.96).clamp(1060.0, 1800.0);
      final dialogHeight = (screen.height * 0.82).clamp(560.0, 900.0);
      return AlertDialog(
        title: const Text('Nueva misión manual'),
        content: SizedBox(
          width: dialogWidth,
          height: dialogHeight,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Modo alta rápida: 3 tarjetas completas',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                    onPressed: _enviando ? null : () => setState(() => _slotCount = 1),
                    child: const Text('Modo 1 tarjeta'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    const spacing = 10.0;
                    final available = constraints.maxWidth;
                    final rowTargetCardWidth = (available - (spacing * 2)) / 3;
                    final useHorizontalScroll = rowTargetCardWidth < 340;
                    final cardWidth = useHorizontalScroll ? 360.0 : rowTargetCardWidth;
                    final totalWidth = (cardWidth * 3) + (spacing * 2);
                    return SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minWidth: available),
                        child: SizedBox(
                          width: useHorizontalScroll ? totalWidth : available,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildTarjetaMisionCompleta(
                                cardIndex: 0,
                                tituloTarjeta: 'Tarjeta 1',
                                cardWidth: cardWidth,
                                tituloCtrl: _tituloCtrl,
                                descCtrl: _descCtrl,
                                diasCtrl: _diasCtrl,
                                horasCtrl: _horasCtrl,
                                minutosCtrl: _minutosCtrl,
                                sinTiempo: _sinTiempoEstimado,
                                onSinTiempoChanged:
                                    (v) => setState(() => _sinTiempoEstimado = v),
                                responsable: _responsable,
                                onResponsableChanged: (v) => setState(() => _responsable = v),
                                categoria: _categoria,
                                onCategoriaChanged: (v) => setState(() => _categoria = v),
                                responsables: responsables,
                                checklistBg: checklistBg,
                                checklistText: checklistText,
                                checklistBorder: checklistBorder,
                              ),
                              const SizedBox(width: spacing),
                              _buildTarjetaMisionCompleta(
                                cardIndex: 1,
                                tituloTarjeta: 'Tarjeta 2',
                                cardWidth: cardWidth,
                                tituloCtrl: _tituloExtraCtrls[0],
                                descCtrl: _descExtraCtrls[0],
                                diasCtrl: _diasExtraCtrls[0],
                                horasCtrl: _horasExtraCtrls[0],
                                minutosCtrl: _minutosExtraCtrls[0],
                                sinTiempo: _sinTiempoExtra[0],
                                onSinTiempoChanged:
                                    (v) => setState(() => _sinTiempoExtra[0] = v),
                                responsable: _responsableExtra[0],
                                onResponsableChanged:
                                    (v) => setState(() => _responsableExtra[0] = v),
                                categoria: _categoriaExtra[0] ?? _categoria,
                                onCategoriaChanged: (v) => setState(() => _categoriaExtra[0] = v),
                                responsables: responsables,
                                checklistBg: checklistBg,
                                checklistText: checklistText,
                                checklistBorder: checklistBorder,
                              ),
                              const SizedBox(width: spacing),
                              _buildTarjetaMisionCompleta(
                                cardIndex: 2,
                                tituloTarjeta: 'Tarjeta 3',
                                cardWidth: cardWidth,
                                tituloCtrl: _tituloExtraCtrls[1],
                                descCtrl: _descExtraCtrls[1],
                                diasCtrl: _diasExtraCtrls[1],
                                horasCtrl: _horasExtraCtrls[1],
                                minutosCtrl: _minutosExtraCtrls[1],
                                sinTiempo: _sinTiempoExtra[1],
                                onSinTiempoChanged:
                                    (v) => setState(() => _sinTiempoExtra[1] = v),
                                responsable: _responsableExtra[1],
                                onResponsableChanged:
                                    (v) => setState(() => _responsableExtra[1] = v),
                                categoria: _categoriaExtra[1] ?? _categoria,
                                onCategoriaChanged: (v) => setState(() => _categoriaExtra[1] = v),
                                responsables: responsables,
                                checklistBg: checklistBg,
                                checklistText: checklistText,
                                checklistBorder: checklistBorder,
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _enviando ? null : () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: _enviando ? null : _crear,
            child:
                _enviando
                    ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : const Text('Crear misión'),
          ),
        ],
      );
    }

    return AlertDialog(
      title: const Text('Nueva misión manual'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _tituloCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Título',
                    border: OutlineInputBorder(),
                  ),
                  validator:
                      (v) =>
                          (v == null || v.trim().isEmpty)
                              ? 'Obligatorio'
                              : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _descCtrl,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Descripción',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _diasCtrl,
                        enabled: !_sinTiempoEstimado && !_enviando,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Días',
                          border: OutlineInputBorder(),
                          hintText: '1 día = 540 min',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextFormField(
                        controller: _horasCtrl,
                        enabled: !_sinTiempoEstimado && !_enviando,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Horas',
                          border: OutlineInputBorder(),
                          hintText: 'p. ej. 2',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextFormField(
                        controller: _minutosCtrl,
                        enabled: !_sinTiempoEstimado && !_enviando,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Minutos',
                          border: OutlineInputBorder(),
                          hintText: 'p. ej. 120',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilterChip(
                      label: const Text('No aplica'),
                      selected: _sinTiempoEstimado,
                      onSelected:
                          _enviando
                              ? null
                              : (v) => setState(() => _sinTiempoEstimado = v),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _slotCount == 1
                            ? 'Alta rápida: 1 tarjeta'
                            : 'Alta rápida: 3 tarjetas',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    TextButton(
                      onPressed: _enviando
                          ? null
                          : () {
                              if (_slotCount == 1) {
                                _activarModoTresTarjetas();
                              } else {
                                setState(() => _slotCount = 1);
                              }
                            },
                      child: Text(
                        _slotCount == 1 ? '+ 2 tareas rápidas' : 'Modo 1 tarjeta',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: _responsable,
                  decoration: const InputDecoration(
                    labelText: 'Responsable (usuario de sistema)',
                    border: OutlineInputBorder(),
                  ),
                  items:
                      responsables
                          .map(
                            (e) => DropdownMenuItem(value: e, child: Text(e)),
                          )
                          .toList(),
                  onChanged:
                      _enviando
                          ? null
                          : (v) => setState(() {
                                _responsable = v;
                                final sv = (v ?? '').trim();
                                if (sv.isNotEmpty) {
                                  _responsablesSeleccionados.add(sv);
                                }
                              }),
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  value: _asignarMultiples,
                  onChanged: _enviando
                      ? null
                      : (v) => setState(() => _asignarMultiples = v ?? false),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Asignar a más de una persona'),
                ),
                if (_asignarMultiples) ...[
                  CheckboxListTile(
                    value: _asignarATodos,
                    onChanged: _enviando
                        ? null
                        : (v) => setState(() => _asignarATodos = v ?? false),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Asignar a todos los usuarios'),
                  ),
                  if (!_asignarATodos)
                    Container(
                      constraints: const BoxConstraints(maxHeight: 140),
                      decoration: BoxDecoration(
                        border: Border.all(color: checklistBorder),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final usr in responsables)
                            CheckboxListTile(
                              value: _responsablesSeleccionados.contains(usr),
                              dense: true,
                              title: Text(usr),
                              onChanged: _enviando
                                  ? null
                                  : (v) => setState(() {
                                        if (v == true) {
                                          _responsablesSeleccionados.add(usr);
                                        } else {
                                          _responsablesSeleccionados.remove(usr);
                                        }
                                      }),
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 8),
                ],
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: _categoria,
                  decoration: const InputDecoration(
                    labelText: 'Categoría',
                    border: OutlineInputBorder(),
                  ),
                  items:
                      kCategoriasMision
                          .map(
                            (e) => DropdownMenuItem(value: e, child: Text(e)),
                          )
                          .toList(),
                  onChanged:
                      _enviando ? null : (v) => setState(() => _categoria = v),
                ),
                const SizedBox(height: 16),
                // Sección de checklist
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'PASOS (CHECKLIST)',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: checklistText,
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Lista de pasos
                    if (_checklistItems.isNotEmpty)
                      Container(
                        decoration: BoxDecoration(
                          color: checklistBg,
                          border: Border.all(
                            color: checklistBorder,
                            width: 0.5,
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: ListView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: _checklistItems.length,
                          itemBuilder:
                              (_, i) => Container(
                                decoration: BoxDecoration(
                                  border:
                                      i < _checklistItems.length - 1
                                          ? Border(
                                            bottom: BorderSide(
                                              color: checklistBorder,
                                              width: 0.3,
                                            ),
                                          )
                                          : null,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          _checklistItems[i]['nombre'] ?? '',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodyMedium?.copyWith(
                                            color: checklistText,
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        onPressed:
                                            _enviando
                                                ? null
                                                : () => _removerPaso(i),
                                        icon: const Icon(
                                          Icons.close,
                                          size: 18,
                                          color: Color(0xFFFF8C00),
                                        ),
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(
                                          minWidth: 32,
                                          minHeight: 32,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    // Input para nuevo paso
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _pasoCtrl,
                            enabled: !_enviando,
                            decoration: const InputDecoration(
                              labelText: 'Nuevo paso',
                              border: OutlineInputBorder(),
                              hintText: 'Ej: Inspeccionar componentes',
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                            ),
                            onFieldSubmitted:
                                _enviando ? null : (_) => _agregarPaso(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: _enviando ? null : _agregarPaso,
                          child: const Text('AGREGAR'),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _enviando ? null : _pegarPortapapeles,
                  icon: const Icon(Icons.paste, size: 18),
                  label: const Text('Pegar imagen del portapapeles'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _enviando ? null : _elegirArchivo,
                  icon: const Icon(Icons.image_outlined, size: 18),
                  label: const Text('Adjuntar imagen desde archivo'),
                ),
                if (_imagenBase64 != null && _imagenBase64!.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Imagen lista (${(_imagenBase64!.length / 1024).toStringAsFixed(1)} KB en Base64)',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      TextButton(
                        onPressed:
                            _enviando
                                ? null
                                : () => setState(() => _imagenBase64 = null),
                        child: const Text('Quitar'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Builder(
                    builder: (_) {
                      try {
                        final u8 = base64Decode(_imagenBase64!);
                        return ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.memory(
                            u8,
                            height: 100,
                            fit: BoxFit.cover,
                            errorBuilder:
                                (_, __, ___) =>
                                    const Text('Vista previa no disponible'),
                          ),
                        );
                      } catch (_) {
                        return const Text('Vista previa no disponible');
                      }
                    },
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _enviando ? null : () => Navigator.pop(context, false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _enviando ? null : _crear,
          child:
              _enviando
                  ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                  : const Text('Crear misión'),
        ),
      ],
    );
  }
}
