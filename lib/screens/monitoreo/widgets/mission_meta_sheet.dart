import 'dart:convert';

import 'package:flutter/material.dart';

/// Panel lateral con JSON de Meta_JSON (trazabilidad tecnica / auditoria).
/// Sin Scrollbar suelto: evita error de ScrollController en Windows.
Future<void> showMissionMetaSideSheet(BuildContext context, Object? metaRaw) {
  String pretty;
  try {
    Object? data = metaRaw;
    if (metaRaw is String && metaRaw.trim().isNotEmpty) {
      data = json.decode(metaRaw);
    }
    if (data == null || (data is String && data.trim().isEmpty)) {
      pretty = '(Sin datos tecnicos guardados)';
    } else {
      pretty = const JsonEncoder.withIndent('  ').convert(data);
    }
  } catch (_) {
    pretty = metaRaw?.toString() ?? '(Sin datos)';
  }

  final theme = Theme.of(context);
  final h = MediaQuery.sizeOf(context).height;
  final w = MediaQuery.sizeOf(context).width;
  final sheetW = (w * 0.38).clamp(300.0, 420.0);

  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black45,
    transitionDuration: const Duration(milliseconds: 280),
    pageBuilder: (ctx, animation, secondary) {
      return Align(
        alignment: Alignment.centerRight,
        child: Material(
          elevation: 12,
          color: theme.cardColor,
          child: SizedBox(
            width: sheetW,
            height: h,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 4, 8),
                  child: Row(
                    children: [
                      Icon(Icons.description_outlined, size: 20, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Detalle tecnico',
                          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    'Para ingenieria: simulacion Radar, IDs, contexto guardado en servidor.',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      pretty,
                      style: TextStyle(
                        fontFamily: 'Consolas, monospace',
                        fontSize: 11,
                        height: 1.35,
                        color: theme.textTheme.bodyMedium?.color,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
    transitionBuilder: (ctx, animation, secondary, child) {
      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return SlideTransition(
        position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero).animate(curved),
        child: child,
      );
    },
  );
}
