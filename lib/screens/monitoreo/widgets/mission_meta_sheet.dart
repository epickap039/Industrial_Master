import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'task_display_utils.dart';

/// Meta sin texto duplicado ni adjuntos base64 (la descripción va arriba).
Map<String, dynamic>? _metaFiltradaAuditoria(Object? metaRaw) {
  Object? data = metaRaw;
  if (metaRaw is String && metaRaw.trim().isNotEmpty) {
    try {
      data = json.decode(metaRaw);
    } catch (_) {
      return null;
    }
  }
  if (data == null || (data is String && data.trim().isEmpty)) return null;
  if (data is! Map) return null;
  final m = Map<String, dynamic>.from(
    data.map((k, v) => MapEntry('$k', v)),
  );
  for (final k in [
    'imagen_adjunta_base64',
    'imagen_base64',
    'descripcion',
    'Descripcion',
    'detalle',
    'descripcion_mision',
  ]) {
    m.remove(k);
  }
  return m.isEmpty ? null : m;
}

String _descripcionDesdeMetaRaw(Object? metaRaw) {
  String? norm(Object? v) {
    if (v == null) return null;
    final s = v.toString().trim();
    if (s.isEmpty || s == 'null') return null;
    return s;
  }

  Object? data = metaRaw;
  if (metaRaw is String && metaRaw.trim().isNotEmpty) {
    try {
      data = json.decode(metaRaw);
    } catch (_) {
      return '';
    }
  }
  if (data is! Map) return '';
  final m = Map<String, dynamic>.from(
    data.map((k, v) => MapEntry('$k', v)),
  );
  for (final key in [
    'descripcion',
    'Descripcion',
    'detalle',
    'Detalle',
    'descripcion_mision',
    'texto_descripcion',
  ]) {
    final s = norm(m[key]);
    if (s != null) return s;
  }
  return '';
}

Uint8List? _bytesImagenAdjuntaTarea(Map<String, dynamic>? task) {
  if (task == null) return null;
  var s = imagenAdjuntaBase64Tarea(task);
  if (s == null || s.isEmpty) return null;
  final comma = s.indexOf(',');
  if (s.startsWith('data:') && comma > 0) {
    s = s.substring(comma + 1);
  }
  try {
    return base64Decode(s.replaceAll(RegExp(r'\s'), ''));
  } catch (_) {
    return null;
  }
}

Color _accentAsignadoMision(Map<String, dynamic>? task) {
  if (task == null) return const Color(0xFF1565C0);
  final n = asignadoMision(task);
  if (n.isEmpty || n == 'Sin asignar') return const Color(0xFF1565C0);
  const cols = <Color>[
    Color(0xFF1565C0),
    Color(0xFF2E7D32),
    Color(0xFF6A1B9A),
    Color(0xFF6D4C41),
    Color(0xFFB71C1C),
    Color(0xFF006064),
    Color(0xFF0277BD),
  ];
  return cols[n.hashCode.abs() % cols.length];
}

DateTime? _parseApiDate(Object? raw) {
  if (raw == null) return null;
  try {
    return DateTime.parse(raw.toString());
  } catch (_) {
    return null;
  }
}

/// Lead time entre inicio de ciclo y cierre (mision finalizada).
Widget? buildLeadTimeSectionForTask(Map<String, dynamic>? task, ThemeData theme) {
  if (task == null) return null;
  final start = _parseApiDate(task['fecha_inicio_ciclo']) ??
      _parseApiDate(task['Fecha_Inicio_Ciclo']) ??
      _parseApiDate(task['Fecha_Inicio']) ??
      _parseApiDate(task['fecha_creacion']) ??
      _parseApiDate(task['Fecha_Creacion']) ??
      _parseApiDate(task['FechaCreacion']) ??
      _parseApiDate(task['CreatedAt']) ??
      _parseApiDate(task['created_at']);
  final end = _parseApiDate(task['fecha_cierre']) ??
      _parseApiDate(task['Fecha_Cierre']) ??
      _parseApiDate(task['Fecha_Completado']);
  if (start == null || end == null) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Text(
        'Lead time: sin Fecha inicio/cierre en la respuesta del servidor.',
        style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
      ),
    );
  }
  final d = end.difference(start);
  if (d.isNegative) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Text(
        'Lead time: fechas inconsistentes.',
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
      ),
    );
  }
  final long = d.inHours > 48;
  final days = d.inDays;
  final hours = d.inHours % 24;
  final label = days > 0
      ? '${days}d ${hours}h (${d.inHours} h total)'
      : '${d.inHours}h ${d.inMinutes % 60}m';

  final leadBg = long
      ? const Color(0xFFFFF3E0)
      : (theme.brightness == Brightness.dark
          ? const Color(0xFF3D3D44)
          : const Color(0xFFE8EAF0));
  return Padding(
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
    child: Material(
      color: leadBg,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.schedule,
              size: 20,
              color: long ? const Color(0xFFE65100) : theme.colorScheme.primary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Lead time',
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: long ? const Color(0xFFE65100) : null,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: long ? const Color(0xFFBF360C) : null,
                    ),
                  ),
                  Text(
                    'Desde inicio de ciclo hasta cierre.',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                  ),
                  if (long)
                    Text(
                      '> 48 h: revision sugerida de cuellos de botella.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFFE65100),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Panel lateral con JSON de Meta_JSON (trazabilidad tecnica / auditoria).
/// [task]: opcional; si viene, muestra Lead time (fecha_inicio_ciclo -> fecha_cierre).
Future<void> showMissionMetaSideSheet(
  BuildContext context,
  Object? metaRaw, {
  Map<String, dynamic>? task,
}) {
  final auditMap = _metaFiltradaAuditoria(metaRaw);
  final prettyAudit = auditMap != null && auditMap.isNotEmpty
      ? const JsonEncoder.withIndent('  ').convert(auditMap)
      : '';

  final theme = Theme.of(context);
  final h = MediaQuery.sizeOf(context).height;
  final w = MediaQuery.sizeOf(context).width;
  final sheetW = (w * 0.38).clamp(300.0, 460.0);
  final opaqueBg = theme.brightness == Brightness.dark
      ? const Color(0xFF2C2C32)
      : const Color(0xFFF2F2F5);

  final lead = buildLeadTimeSectionForTask(task, theme);
  final titulo = task != null ? tituloMision(task) : '';
  final descTask = task != null ? descripcionMision(task) : '';
  final descMeta = _descripcionDesdeMetaRaw(metaRaw);
  final desc = descTask.isNotEmpty ? descTask : descMeta;
  final tieneJson = prettyAudit.isNotEmpty;
  final accentUser = _accentAsignadoMision(task);
  final imgBytes = _bytesImagenAdjuntaTarea(task);

  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 280),
    pageBuilder: (ctx, animation, secondary) {
      return Align(
        alignment: Alignment.centerRight,
        child: Material(
          elevation: 16,
          color: opaqueBg,
          shadowColor: Colors.black45,
          child: SizedBox(
            width: sheetW,
            height: h,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  height: 5,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        accentUser,
                        accentUser.withValues(alpha: 0.65),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 4, 8),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, size: 20, color: accentUser),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Misión',
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
                if (titulo.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                    child: Text(
                      titulo,
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                if (desc.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                    child: Text(
                      'Descripción',
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: theme.hintColor,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                    child: Text(
                      desc,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        height: 1.35,
                        color: theme.textTheme.bodyMedium?.color,
                      ),
                    ),
                  ),
                ] else if (task != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Text(
                      'Sin descripción guardada para esta misión.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.hintColor,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                if (imgBytes != null) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: ColoredBox(
                        color: theme.brightness == Brightness.dark
                            ? const Color(0xFF1E1E22)
                            : const Color(0xFFECEFF1),
                        child: Image.memory(
                          imgBytes,
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                          filterQuality: FilterQuality.medium,
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                    child: Text(
                      'Imagen adjunta a la misión',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.hintColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
                if (lead != null) lead,
                Expanded(
                  child: tieneJson
                      ? ColoredBox(
                          color: theme.brightness == Brightness.dark
                              ? const Color(0xFF252528)
                              : const Color(0xFFFFFFFF),
                          child: ListView(
                            padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
                            children: [
                              ExpansionTile(
                                initiallyExpanded: false,
                                tilePadding:
                                    const EdgeInsets.symmetric(horizontal: 8),
                                childrenPadding: EdgeInsets.zero,
                                title: Text(
                                  'Datos técnicos (auditoría)',
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                subtitle: Text(
                                  'Categoría, origen y contexto en servidor',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.hintColor,
                                  ),
                                ),
                                children: [
                                  ColoredBox(
                                    color: theme.brightness == Brightness.dark
                                        ? const Color(0xFF1A1A1D)
                                        : const Color(0xFFFAFAFA),
                                    child: Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: SelectableText(
                                        prettyAudit,
                                        style: TextStyle(
                                          fontFamily: 'Consolas, monospace',
                                          fontSize: 11,
                                          height: 1.35,
                                          color: theme.brightness ==
                                                  Brightness.dark
                                              ? const Color(0xFFE0E0E0)
                                              : const Color(0xFF263238),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        )
                      : ColoredBox(
                          color: theme.brightness == Brightness.dark
                              ? const Color(0xFF252528)
                              : const Color(0xFFFFFFFF),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              'Sin metadatos técnicos adicionales.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.hintColor,
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
