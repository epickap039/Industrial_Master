import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:pasteboard/pasteboard.dart';

import '../../../services/api_client.dart';

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
  var responsables = List<String>.from(kResponsablesMisionFallback);
  try {
    dynamic raw;
    try {
      raw = await ApiClient.get('/api/usuarios/all');
    } catch (_) {
      raw = await ApiClient.get('/api/usuarios/lista');
    }
    if (raw is List && raw.isNotEmpty) {
      final nom =
          raw
              .map((e) => Map<String, dynamic>.from(e as Map))
              .map((u) {
                final w = '${u['username'] ?? ''}'.trim();
                if (w.isNotEmpty) return w;
                return '${u['nombre'] ?? ''}'.trim();
              })
              .where((s) => s.isNotEmpty)
              .toList();
      if (nom.isNotEmpty) responsables = nom;
    }
  } catch (_) {}

  if (!context.mounted) return false;

  final ok = await showDialog<bool>(
    context: context,
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
  String? _responsable;
  String? _categoria;
  String? _imagenBase64;
  bool _enviando = false;
  bool _asignarMultiples = false;
  bool _asignarATodos = false;
  final Set<String> _responsablesSeleccionados = <String>{};

  /// Si true, no se envía presupuesto de tiempo (carga acumulada ignora esta misión).
  bool _sinTiempoEstimado = false;

  /// Items de checklist para la tarea
  final List<Map<String, dynamic>> _checklistItems = [];

  @override
  void initState() {
    super.initState();
    _tituloCtrl = TextEditingController();
    _descCtrl = TextEditingController();
    _diasCtrl = TextEditingController(text: '0');
    _horasCtrl = TextEditingController(text: '0');
    _minutosCtrl = TextEditingController(text: '60');
    _pasoCtrl = TextEditingController();
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
    super.dispose();
  }

  void _agregarPaso() {
    final paso = _pasoCtrl.text.trim();
    if (paso.isEmpty) return;
    setState(() {
      _checklistItems.add({
        'nombre': paso,
        'completado': 0,
        'minutos': 0,
        'grupo': '',
      });
    });
    _pasoCtrl.clear();
  }

  void _removerPaso(int index) {
    setState(() => _checklistItems.removeAt(index));
  }

  Future<void> _pegarPortapapeles() async {
    try {
      final Uint8List? bytes = await Pasteboard.image;
      if (bytes != null && bytes.isNotEmpty) {
        setState(() => _imagenBase64 = base64Encode(bytes));
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

  Future<void> _elegirArchivo() async {
    try {
      final r = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );
      if (r == null || r.files.isEmpty) return;
      final b = r.files.first.bytes;
      if (b != null && b.isNotEmpty) {
        setState(() => _imagenBase64 = base64Encode(b));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error al elegir archivo: $e')));
      }
    }
  }

  Future<void> _crear() async {
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
              : (diasParse * 24 * 60) + (horasParse * 60) + (minParse ?? 0);
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
      final body = <String, dynamic>{
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
        body['imagen_base64'] = img;
      }
      await ApiClient.post('/api/tareas/crear_manual', body: body);
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
                          hintText: 'p. ej. 1',
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
