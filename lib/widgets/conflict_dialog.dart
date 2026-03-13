import 'package:fluent_ui/fluent_ui.dart';

class ConflictResolutionDialog extends StatelessWidget {
  final dynamic item;

  const ConflictResolutionDialog({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    // Datos: asegurar que sean mapas, aunque vengan vacíos
    final Map<String, dynamic> excel =
        item['Excel_Data'] is Map
            ? Map<String, dynamic>.from(item['Excel_Data'])
            : {};
    final Map<String, dynamic> sqlRaw =
        item['SQL_Data'] is Map
            ? Map<String, dynamic>.from(item['SQL_Data'])
            : {};



    // Helper para construir la tarjeta de datos
    Widget _buildDataCard(
      BuildContext context,
      String title,
      Map<String, dynamic> data,
      Color accentColor,
      bool isExcel,
    ) {
      // === TAREA 1: Detección de brillo explícita – independiente del TextTheme global ===
      final isDark = FluentTheme.of(context).brightness == Brightness.dark;
      final textColor = isDark ? Colors.white : const Color(0xFF1A1A1A);
      final subTextColor = isDark ? const Color(0xFFB0B0B0) : const Color(0xFF555555);
      final bgCard = FluentTheme.of(context).cardColor;

      if (data.isEmpty) {
        return Container(
          decoration: BoxDecoration(
            color: bgCard,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: accentColor.withOpacity(0.3)),
          ),
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(FluentIcons.database, size: 48, color: subTextColor),
                const SizedBox(height: 16),
                Text("Sin datos en BD", style: TextStyle(color: subTextColor)),
              ],
            ),
          ),
        );
      }

      // Helper interno de campo – siempre usa colores explícitos
      Widget buildField(String label, String val, {bool highlight = false}) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 5.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label.toUpperCase(),
                style: TextStyle(fontSize: 9, color: subTextColor, fontWeight: FontWeight.bold, letterSpacing: 0.5),
              ),
              const SizedBox(height: 2),
              SelectableText(
                val.isEmpty ? "—" : val,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: highlight ? FontWeight.bold : FontWeight.normal,
                  color: highlight ? accentColor : textColor,
                ),
              ),
            ],
          ),
        );
      }

      return Container(
        decoration: BoxDecoration(
          // === TAREA 1: Fondo del tema, sin sólido ===
          color: bgCard,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: accentColor.withOpacity(0.45), width: 1.5),
        ),
        child: Column(
          children: [
            // Cabecera: borde izquierdo grueso, sin fondo sólido
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
              decoration: BoxDecoration(
                color: accentColor.withOpacity(isDark ? 0.12 : 0.08),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(7)),
                border: Border(left: BorderSide(color: accentColor, width: 4)),
              ),
              child: Row(
                children: [
                  Icon(isExcel ? FluentIcons.excel_logo : FluentIcons.database, color: accentColor, size: 16),
                  const SizedBox(width: 8),
                  Text(title, style: TextStyle(fontWeight: FontWeight.bold, color: textColor, fontSize: 13)),
                ],
              ),
            ),
            // Cuerpo
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(14.0),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      buildField("Descripción",
                          data[isExcel ? 'Descripcion_Excel' : 'Descripcion'] ?? "", highlight: true),
                      const SizedBox(height: 8),
                      Container(height: 1, color: accentColor.withOpacity(0.2)),
                      const SizedBox(height: 4),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: buildField("Medida", data[isExcel ? 'Medida_Excel' : 'Medida'] ?? "")),
                          const SizedBox(width: 12),
                          Expanded(child: buildField("Material", data[isExcel ? 'Material_Excel' : 'Material'] ?? "")),
                        ],
                      ),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: buildField("Simetría", data['Simetria'] ?? "")),
                          const SizedBox(width: 12),
                          Expanded(child: buildField("Proc. Prim.", data['Proceso_Primario'] ?? "")),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Container(height: 1, color: accentColor.withOpacity(0.2)),
                      Text("PROCESOS SECUNDARIOS",
                          style: TextStyle(fontSize: 9, color: subTextColor, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(child: buildField("Proc. 1", data['Proceso_1'] ?? "")),
                          Expanded(child: buildField("Proc. 2", data['Proceso_2'] ?? "")),
                          Expanded(child: buildField("Proc. 3", data['Proceso_3'] ?? "")),
                        ],
                      ),
                      Container(height: 1, color: accentColor.withOpacity(0.2)),
                      buildField("Link Drive", data['Link_Drive'] ?? ""),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return ContentDialog(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.95,
      ), // Ancho 95%
      title: Row(
        children: [
          const Text(
            "Resolución de Conflictos",
            style: TextStyle(fontSize: 20),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF37474F), // Gris azulado oscuro – siempre legible
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              item['Codigo_Pieza'] ?? "N/A",
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontFamily: 'Consolas',
                color: Colors.white, // Explícito: blanco sobre fondo oscuro
              ),
            ),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(FluentIcons.chrome_close, size: 14),
            onPressed: () => Navigator.pop(context, null),
          ),
        ],
      ),
      content: SizedBox(
        height: 550, // Altura incrementada para los nuevos campos
        child: Row(
          children: [
            // COLUMNA 1: EXCEL
            Expanded(
              flex: 4,
              child: Column(
                children: [
                  Expanded(
                    child: _buildDataCard(
                      context,
                      "PROPUESTA EXCEL",
                      excel,
                      Colors.green.darkest,
                      true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton(
                      style: ButtonStyle(
                        backgroundColor: WidgetStateProperty.all(
                          Colors.green.darkest,
                        ),
                        shape: WidgetStateProperty.all(
                          RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(FluentIcons.check_mark, size: 18, color: Colors.white),
                          SizedBox(width: 8),
                          Text(
                            "USAR EXCEL",
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.white, // Explícito para garantizar contraste
                            ),
                          ),
                        ],
                      ),
                      onPressed:
                          () => Navigator.pop(context, {
                            'action': 'SYNC_EXCEL',
                            'data': excel,
                          }),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(width: 24),

            // COLUMNA 2: BD
            Expanded(
              flex: 4,
              child: Column(
                children: [
                  Expanded(
                    child: _buildDataCard(
                      context,
                      "BASE DE DATOS ACTUAL",
                      sqlRaw,
                      Colors.red.darkest,
                      false,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton(
                      style: ButtonStyle(
                        backgroundColor: WidgetStateProperty.all(Colors.red.darkest),
                        shape: WidgetStateProperty.all(
                          RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                      child: const Text(
                        "MANTENER BD",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.white, // Blanco sobre fondo rojo
                        ),
                      ),
                      onPressed:
                          () => Navigator.pop(context, {
                            'action': 'KEEP_DB',
                            'data': sqlRaw,
                          }),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(width: 24),

            // COLUMNA 3: ACCIONES EXTRA
            SizedBox(
              width: 160,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(FluentIcons.edit, size: 32, color: Colors.blue),
                  const SizedBox(height: 16),
                  const Text(
                    "¿Ninguno es correcto?",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 12),
                  Button(
                    child: const Text("Editar Manualmente"),
                    onPressed:
                        () => Navigator.pop(context, {'action': 'EDIT_MANUAL'}),
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
