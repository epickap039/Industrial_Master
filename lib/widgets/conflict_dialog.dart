import 'dart:math' show min;

import 'package:fluent_ui/fluent_ui.dart';

class ConflictResolutionDialog extends StatelessWidget {
  final dynamic item;

  const ConflictResolutionDialog({super.key, required this.item});

  // ── Helpers de extracción de datos ──────────────────────────────────────────

  /// Devuelve el valor como String, nunca null.
  static String _str(dynamic v) =>
      (v == null || v.toString().trim().isEmpty) ? '—' : v.toString().trim();

  /// true si el valor indica "sin definir" (vacío o placeholder).
  static bool _isSinDefinir(String v) =>
      v == '—' || v.isEmpty || v.toUpperCase() == 'POR DEFINIR';

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);

    final Map<String, dynamic> excel =
        item['Excel_Data'] is Map
            ? Map<String, dynamic>.from(item['Excel_Data'])
            : {};
    final Map<String, dynamic> sqlRaw =
        item['SQL_Data'] is Map
            ? Map<String, dynamic>.from(item['SQL_Data'])
            : {};

    // ── Campos a mostrar ──────────────────────────────────────────────────────
    final fields = [
      _FieldDef('Descripción', 'Descripcion_Excel', 'Descripcion'),
      _FieldDef('Medida', 'Medida_Excel', 'Medida'),
      _FieldDef('Material', 'Material_Excel', 'Material'),
      _FieldDef('Proceso Primario', 'Proceso_Primario', 'Proceso_Primario'),
      _FieldDef('Proceso 1', 'Proceso_1', 'Proceso_1'),
      _FieldDef('Proceso 2', 'Proceso_2', 'Proceso_2'),
      _FieldDef('Proceso 3', 'Proceso_3', 'Proceso_3'),
      _FieldDef('Simetría', 'Simetria', 'Simetria'),
      _FieldDef('Link Drive', 'Link_Drive', 'Link_Drive'),
    ];

    // ── Colores de tema ───────────────────────────────────────────────────────
    final accent = theme.accentColor;
    final cardBg = theme.cardColor;
    final divColor = theme.resources.dividerStrokeColorDefault;
    final labelColor = theme.resources.textFillColorSecondary;
    final textColor = theme.resources.textFillColorPrimary;
    final rowAlt = theme.resources.cardBackgroundFillColorSecondary;

    // ── Panel de un lado (Excel o BD) ─────────────────────────────────────────
    Widget buildPanel({
      required String title,
      required IconData icon,
      required Color accentBorder,
      required Map<String, dynamic> data,
      required bool isExcel,
    }) {
      // Fix BorderRadius crash:
      // Flutter NO permite borderRadius + Border con colores distintos en cada lado.
      // Solución: border uniforme (Border.all) + el acento de color queda solo
      // en la franja de cabecera interior (sin borderRadius = sin conflicto).
      return Container(
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: divColor), // ← uniforme: compatible con radius
        ),
        clipBehavior: Clip.antiAlias, // recorta cabecera coloreada respetando el radius
        child: Column(
          // ⬇ mainAxisSize.min es obligatorio dentro de SingleChildScrollView
          // (altura unbounded): con max, la Column colapsa a 0 y no se ve nada.
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Franja de cabecera: acento de color aquí, sin borderRadius propio
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: accentBorder.withValues(alpha: 0.18),
                border: Border(
                  bottom: BorderSide(color: accentBorder, width: 3),
                ),
              ),
              child: Row(
                children: [
                  Icon(icon, size: 15, color: accentBorder),
                  const SizedBox(width: 8),
                  // ⬇ Text en lugar de SelectableText — SelectableText necesita
                  // un SelectionArea ancestro en Flutter desktop; sin él,
                  // produce un render vacío dentro de scroll views.
                  Text(
                    title,
                    style: theme.typography.bodyStrong?.copyWith(
                      color: textColor,
                    ),
                  ),
                ],
              ),
            ),
            // Tabla de filas campo → valor
            ...fields.asMap().entries.map((entry) {
              final i = entry.key;
              final f = entry.value;
              final rawVal = data[isExcel ? f.excelKey : f.sqlKey];
              final val = _str(rawVal);
              final sinDef = _isSinDefinir(val) && f.excelKey == 'Material_Excel';
              final isEven = i.isEven;

              return Container(
                color: isEven ? Colors.transparent : rowAlt,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      f.label,
                      style: theme.typography.caption?.copyWith(
                        color: labelColor,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            val,
                            style: theme.typography.body?.copyWith(
                              color: textColor,
                              fontWeight: FontWeight.w600,
                            ),
                            softWrap: true,
                          ),
                        ),
                        // Badge "POR DEFINIR" solo en campo Material vacío
                        if (sinDef) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.orange.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: Colors.orange,
                                width: 1,
                              ),
                            ),
                            child: Text(
                              'Sin definir',
                              style: theme.typography.caption?.copyWith(
                                color: Colors.orange,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      );
    }

    // ── Altura dinámica ───────────────────────────────────────────────────────
    final maxH = min(560.0, MediaQuery.sizeOf(context).height * 0.72);
    const double kPanelWidth = 400;
    const double kGap = 12;
    const double kDialogWidth = kPanelWidth * 2 + kGap;

    return ContentDialog(
      constraints: BoxConstraints(maxWidth: kDialogWidth + 48),
      title: Row(
        children: [
          Text(
            'Resolver conflicto',
            style: theme.typography.subtitle?.copyWith(color: textColor),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: theme.resources.cardBackgroundFillColorSecondary,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              item['Codigo_Pieza']?.toString() ?? 'N/A',
              style: theme.typography.caption?.copyWith(
                fontWeight: FontWeight.bold,
                color: accent,
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: kDialogWidth,
        height: maxH,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Paneles comparativos ─────────────────────────────────────────
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Panel Excel
                  SizedBox(
                    width: kPanelWidth,
                    child: SingleChildScrollView(
                      child: buildPanel(
                        title: 'Propuesta Excel',
                        icon: FluentIcons.excel_logo,
                        accentBorder: Colors.blue,
                        data: excel,
                        isExcel: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: kGap),
                  // Panel BD
                  SizedBox(
                    width: kPanelWidth,
                    child: SingleChildScrollView(
                      child: buildPanel(
                        title: 'Base de Datos Actual',
                        icon: FluentIcons.database,
                        accentBorder: Colors.orange,
                        data: sqlRaw,
                        isExcel: false,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // ── Divisor ──────────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Divider(
                style: DividerThemeData(
                  thickness: 1,
                  decoration: BoxDecoration(color: divColor),
                ),
              ),
            ),
            // ── Botones de acción ────────────────────────────────────────────
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Button(
                    child: const Text('Cancelar'),
                    onPressed: () => Navigator.pop(context, null),
                  ),
                  const SizedBox(width: 12),
                  HyperlinkButton(
                    child: const Text('Editar manual'),
                    onPressed: () => Navigator.pop(context, {
                      'action': 'EDIT_MANUAL',
                    }),
                  ),
                  const SizedBox(width: 8),
                  Button(
                    child: const Text('Mantener BD'),
                    onPressed: () => Navigator.pop(context, {
                      'action': 'KEEP_DB',
                      'data': sqlRaw,
                    }),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    child: const Text('Usar Excel'),
                    onPressed: () => Navigator.pop(context, {
                      'action': 'SYNC_EXCEL',
                      'data': excel,
                    }),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: const [],
    );
  }
}

/// Definición de un campo a comparar entre Excel y BD.
class _FieldDef {
  final String label;
  final String excelKey;
  final String sqlKey;
  const _FieldDef(this.label, this.excelKey, this.sqlKey);
}
