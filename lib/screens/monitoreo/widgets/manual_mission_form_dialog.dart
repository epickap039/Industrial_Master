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
  List<String> responsables = List<String>.from(kResponsablesMisionFallback);
  try {
    final raw = await ApiClient.get('/api/usuarios/lista');
    if (raw is List && raw.isNotEmpty) {
      final nom = raw
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

  final formKey = GlobalKey<FormState>();
  final tituloCtrl = TextEditingController();
  final descCtrl = TextEditingController();
  String? responsable = responsables.first;
  String? categoria = kCategoriasMision.first;
  String? imagenBase64;
  var enviando = false;

  final ok = await showDialog<bool>(
    context: context,
    barrierColor: Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF121212)
        : Colors.white,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (context, setLocal) {
          Future<void> pegarPortapapeles() async {
            try {
              final Uint8List? bytes = await Pasteboard.image;
              if (bytes != null && bytes.isNotEmpty) {
                setLocal(() => imagenBase64 = base64Encode(bytes));
              } else if (ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('Portapapeles sin imagen')),
                );
              }
            } catch (e) {
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(content: Text('No se pudo leer el portapapeles: $e')),
                );
              }
            }
          }

          Future<void> elegirArchivo() async {
            try {
              final r = await FilePicker.platform.pickFiles(
                type: FileType.image,
                withData: true,
              );
              if (r == null || r.files.isEmpty) return;
              final b = r.files.first.bytes;
              if (b != null && b.isNotEmpty) {
                setLocal(() => imagenBase64 = base64Encode(b));
              }
            } catch (e) {
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(content: Text('Error al elegir archivo: $e')),
                );
              }
            }
          }

          return AlertDialog(
            title: const Text('Nueva misión manual'),
            content: SizedBox(
              width: 460,
              child: Form(
                key: formKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextFormField(
                        controller: tituloCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Título',
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) =>
                            (v == null || v.trim().isEmpty) ? 'Obligatorio' : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: descCtrl,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: 'Descripción',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        value: responsable,
                        decoration: const InputDecoration(
                          labelText: 'Responsable (usuario de sistema)',
                          border: OutlineInputBorder(),
                        ),
                        items: responsables
                            .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                            .toList(),
                        onChanged: enviando
                            ? null
                            : (v) => setLocal(() => responsable = v),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        value: categoria,
                        decoration: const InputDecoration(
                          labelText: 'Categoría',
                          border: OutlineInputBorder(),
                        ),
                        items: kCategoriasMision
                            .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                            .toList(),
                        onChanged: enviando
                            ? null
                            : (v) => setLocal(() => categoria = v),
                      ),
                      const SizedBox(height: 16),
                      OutlinedButton.icon(
                        onPressed: enviando ? null : pegarPortapapeles,
                        icon: const Icon(Icons.paste, size: 18),
                        label: const Text('Pegar imagen del portapapeles'),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: enviando ? null : elegirArchivo,
                        icon: const Icon(Icons.image_outlined, size: 18),
                        label: const Text('Adjuntar imagen desde archivo'),
                      ),
                      if (imagenBase64 != null && imagenBase64!.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Imagen lista (${(imagenBase64!.length / 1024).toStringAsFixed(1)} KB en Base64)',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                            TextButton(
                              onPressed: enviando
                                  ? null
                                  : () => setLocal(() => imagenBase64 = null),
                              child: const Text('Quitar'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Builder(
                          builder: (_) {
                            try {
                              final u8 = base64Decode(imagenBase64!);
                              return ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.memory(
                                  u8,
                                  height: 100,
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
            actions: [
              TextButton(
                onPressed: enviando ? null : () => Navigator.pop(ctx, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: enviando
                    ? null
                    : () async {
                        if (!formKey.currentState!.validate()) return;
                        setLocal(() => enviando = true);
                        try {
                          final body = <String, dynamic>{
                            'titulo': tituloCtrl.text.trim(),
                            'descripcion': descCtrl.text.trim(),
                            'responsable': responsable ?? '',
                            'categoria': categoria ?? '',
                            'minutos_estimados': 0,
                            'checklist': <Map<String, dynamic>>[],
                          };
                          final img = imagenBase64 == null
                              ? null
                              : _base64SinPrefijoDataUrl(imagenBase64!);
                          if (img != null && img.isNotEmpty) {
                            body['imagen_base64'] = img;
                          }
                          await ApiClient.post(
                            '/api/tareas/crear_manual',
                            body: body,
                          );
                          if (ctx.mounted) Navigator.pop(ctx, true);
                        } catch (e) {
                          setLocal(() => enviando = false);
                          if (ctx.mounted) {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              SnackBar(content: Text('Error: $e')),
                            );
                          }
                        }
                      },
                child: enviando
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Crear misión'),
              ),
            ],
          );
        },
      );
    },
  );

  tituloCtrl.dispose();
  descCtrl.dispose();
  return ok == true;
}
