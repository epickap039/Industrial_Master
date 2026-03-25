import 'dart:math' show min;

import 'package:fluent_ui/fluent_ui.dart';

class ConflictResolutionDialog extends StatelessWidget {
  final dynamic item;

  const ConflictResolutionDialog({super.key, required this.item});

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

    Widget buildValue(String label, String value) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: theme.typography.caption?.copyWith(
                color: theme.resources.textFillColorSecondary,
              ),
            ),
            const SizedBox(height: 2),
            SelectableText(
              value.isEmpty ? "—" : value,
              style: theme.typography.bodyStrong,
            ),
          ],
        ),
      );
    }

    /// Tarjeta lado a lado: [Column] de datos (sin apilar Excel sobre BD).
    Widget buildMirrorSide({
      required String title,
      required IconData icon,
      required Color markerColor,
      required Map<String, dynamic> data,
      required bool isExcel,
    }) {
      return Container(
        decoration: BoxDecoration(
          color: theme.cardColor,
          borderRadius: BorderRadius.circular(8),
          border: Border(
            left: BorderSide(color: markerColor, width: 4),
            top: BorderSide(color: theme.resources.dividerStrokeColorDefault),
            right: BorderSide(color: theme.resources.dividerStrokeColorDefault),
            bottom: BorderSide(
              color: theme.resources.dividerStrokeColorDefault,
            ),
          ),
        ),
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 15, color: markerColor),
                const SizedBox(width: 8),
                Text(title, style: theme.typography.bodyStrong),
              ],
            ),
            const SizedBox(height: 10),
            buildValue(
              "Descripcion",
              (data[isExcel ? 'Descripcion_Excel' : 'Descripcion'] ?? "")
                  .toString(),
            ),
            buildValue(
              "Medida",
              (data[isExcel ? 'Medida_Excel' : 'Medida'] ?? "").toString(),
            ),
            buildValue(
              "Material",
              (data[isExcel ? 'Material_Excel' : 'Material'] ?? "").toString(),
            ),
            buildValue(
              "Proceso primario",
              (data['Proceso_Primario'] ?? "").toString(),
            ),
            buildValue(
              "Proceso 1",
              (data['Proceso_1'] ?? "").toString(),
            ),
            buildValue(
              "Proceso 2",
              (data['Proceso_2'] ?? "").toString(),
            ),
            buildValue(
              "Proceso 3",
              (data['Proceso_3'] ?? "").toString(),
            ),
            buildValue(
              "Simetria",
              (data['Simetria'] ?? "").toString(),
            ),
            buildValue(
              "Link Drive",
              (data['Link_Drive'] ?? "").toString(),
            ),
          ],
        ),
      );
    }

    final maxH = min(
      560.0,
      MediaQuery.sizeOf(context).height * 0.72,
    );

    return ContentDialog(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * 0.88,
      ),
      title: Row(
        children: [
          Text(
            "Resolver conflicto",
            style: theme.typography.subtitle?.copyWith(
              color: theme.typography.title?.color,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: theme.resources.cardBackgroundFillColorSecondary,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              item['Codigo_Pieza'] ?? "N/A",
              style: theme.typography.caption?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: double.infinity,
        height: maxH,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 400,
                      child: SingleChildScrollView(
                        child: buildMirrorSide(
                          title: "Propuesta Excel",
                          icon: FluentIcons.excel_logo,
                          markerColor: Colors.blue,
                          data: excel,
                          isExcel: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 400,
                      child: SingleChildScrollView(
                        child: buildMirrorSide(
                          title: "Base de Datos Actual",
                          icon: FluentIcons.database,
                          markerColor: Colors.orange,
                          data: sqlRaw,
                          isExcel: false,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Divider(
                style: DividerThemeData(
                  thickness: 1,
                  decoration: BoxDecoration(
                    color: theme.resources.dividerStrokeColorDefault,
                  ),
                ),
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Button(
                    child: const Text("Cancelar"),
                    onPressed: () => Navigator.pop(context, null),
                  ),
                  const SizedBox(width: 12),
                  HyperlinkButton(
                    child: const Text("Editar manual"),
                    onPressed:
                        () => Navigator.pop(context, {
                          'action': 'EDIT_MANUAL',
                        }),
                  ),
                  const SizedBox(width: 8),
                  Button(
                    child: const Text("Mantener BD"),
                    onPressed:
                        () => Navigator.pop(context, {
                          'action': 'KEEP_DB',
                          'data': sqlRaw,
                        }),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    child: const Text("Usar Excel"),
                    onPressed:
                        () => Navigator.pop(context, {
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
