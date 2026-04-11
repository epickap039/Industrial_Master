import 'dart:convert';
import 'dart:typed_data';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api_client.dart';

Future<void> showContextualBugReportDialog(
  BuildContext context, {
  required String modulo,
  required String contextoPantalla,
}) async {
  String gravedad = "Falla";
  String descripcion = "";
  bool enviando = false;
  Uint8List? capturaBytes;
  String? capturaBase64;

  await showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDState) {
        return Focus(
          autofocus: true,
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent &&
                (HardwareKeyboard.instance.isControlPressed ||
                    HardwareKeyboard.instance.isMetaPressed) &&
                event.logicalKey == LogicalKeyboardKey.keyV) {
              Pasteboard.image.then((bytes) {
                if (bytes == null) return;
                setDState(() {
                  capturaBytes = bytes;
                  capturaBase64 = base64Encode(bytes);
                });
              });
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: ContentDialog(
            title: const Text('Reportar fallo'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Módulo: $modulo'),
                Text(
                  'Contexto: $contextoPantalla',
                  style: TextStyle(
                    color: FluentTheme.of(context).typography.caption?.color,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 12),
                ComboBox<String>(
                  value: gravedad,
                  items: const [
                    ComboBoxItem(value: 'Crítico', child: Text('Crítico')),
                    ComboBoxItem(value: 'Falla', child: Text('Falla')),
                    ComboBoxItem(value: 'Mejora', child: Text('Mejora')),
                  ],
                  onChanged: (v) => setDState(() => gravedad = v ?? 'Falla'),
                ),
                const SizedBox(height: 12),
                TextBox(
                  maxLines: 4,
                  placeholder: 'Describe el fallo y pasos para reproducirlo...',
                  onChanged: (v) => descripcion = v,
                ),
                const SizedBox(height: 10),
                if (capturaBytes != null)
                  SizedBox(
                    height: 140,
                    child: Image.memory(capturaBytes!, fit: BoxFit.contain),
                  ),
              ],
            ),
            actions: [
              Button(
                onPressed: enviando ? null : () => Navigator.pop(ctx),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: enviando
                    ? null
                    : () async {
                        if (descripcion.trim().isEmpty) return;
                        setDState(() => enviando = true);
                        try {
                          final prefs = await SharedPreferences.getInstance();
                          final usuario = (prefs.getString('username') ?? 'Operador').trim();
                          await ApiClient.post(
                            '/api/reportes/nuevo',
                            body: {
                              'usuario': usuario,
                              'modulo': modulo,
                              'gravedad': gravedad,
                              'descripcion': descripcion.trim(),
                              'captura': capturaBase64,
                              'contexto_pantalla': contextoPantalla,
                              'crear_tarea_correccion': true,
                            },
                          );
                          if (ctx.mounted) {
                            Navigator.pop(ctx);
                            displayInfoBar(
                              context,
                              builder: (c, close) => InfoBar(
                                title: const Text('Reporte enviado'),
                                content: const Text(
                                  'Se creó reporte QA y tarea de corrección para Ingeniería/Métodos.',
                                ),
                                severity: InfoBarSeverity.success,
                                onClose: close,
                              ),
                            );
                          }
                        } catch (e) {
                          if (ctx.mounted) {
                            setDState(() => enviando = false);
                            displayInfoBar(
                              context,
                              builder: (c, close) => InfoBar(
                                title: const Text('Error'),
                                content: Text('No se pudo enviar el reporte: $e'),
                                severity: InfoBarSeverity.error,
                                onClose: close,
                              ),
                            );
                          }
                        }
                      },
                child: const Text('Enviar'),
              ),
            ],
          ),
        );
      },
    ),
  );
}
