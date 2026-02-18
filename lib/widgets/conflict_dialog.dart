import 'package:fluent_ui/fluent_ui.dart';

class ConflictResolutionDialog extends StatelessWidget {
  final Map<String, dynamic> item;

  const ConflictResolutionDialog({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    final excel = item['Excel_Data'];
    // Parsing seguro de SQL_Data (puede venir null o incompleto)
    final sqlRaw = item['SQL_Data'] ?? {}; 
    
    // Función auxiliar para construir filas de comparación
    Widget _buildRow(String label, String valExcel, String valSql) {
      final isDiff = valExcel.trim().toLowerCase() != valSql.trim().toLowerCase();
      // Si ambos son vacíos, no mostrar diferencia
      final showDiff = isDiff && (valExcel.isNotEmpty || valSql.isNotEmpty);

      return Padding(
        padding: const EdgeInsets.only(bottom: 8.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 80, child: Text("$label:", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
            Expanded(
              child: SelectableText( // Permitir copiar
                valExcel.isEmpty ? "-" : valExcel, 
                style: TextStyle(
                  color: showDiff ? Colors.blue : null, 
                  fontWeight: showDiff ? FontWeight.bold : FontWeight.normal
                ),
              ),
            ),
            const SizedBox(width: 10),
            const Icon(FluentIcons.compare, size: 12, color: Colors.grey),
            const SizedBox(width: 10),
            Expanded(
              child: SelectableText(
                valSql.isEmpty ? "ND" : valSql, 
                style: TextStyle(
                  color: showDiff ? Colors.red : Colors.grey, 
                  decoration: showDiff ? TextDecoration.lineThrough : null
                ),
              ),
            ),
          ],
        ),
      );
    }

    return ContentDialog(
      title: Text("Arbitraje: ${item['Codigo_Pieza']}"),
      content: SizedBox(
        width: 600, // Ancho suficiente para comparar
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ENCABEZADOS
            Row(
              children: [
                const SizedBox(width: 80), // Espacio para labels
                Expanded(child: Text("PROPUESTA EXCEL (NUEVO)", style: TextStyle(color: Colors.successPrimaryColor, fontWeight: FontWeight.bold))),
                const SizedBox(width: 32),
                const Expanded(child: Text("BASE DE DATOS (ACTUAL)", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold))),
              ],
            ),
            const Divider(),
            const SizedBox(height: 10),
            
            // CAMPOS DE COMPARACIÓN
            _buildRow("Descripción", excel['Descripcion_Excel'] ?? "", sqlRaw['Descripcion'] ?? ""),
            _buildRow("Medida", excel['Medida_Excel'] ?? "", sqlRaw['Medida'] ?? ""),
            _buildRow("Material", excel['Material_Excel'] ?? "", sqlRaw['Material'] ?? ""),
            const SizedBox(height: 10),
            _buildRow("Simetría", excel['Simetria'] ?? "", sqlRaw['Simetria'] ?? ""),
            _buildRow("Proc. Prim.", excel['Proceso_Primario'] ?? "", sqlRaw['Proceso_Primario'] ?? ""),
            _buildRow("Proc. 1", excel['Proceso_1'] ?? "", sqlRaw['Proceso_1'] ?? ""),
            _buildRow("Proc. 2", excel['Proceso_2'] ?? "", sqlRaw['Proceso_2'] ?? ""),
            _buildRow("Proc. 3", excel['Proceso_3'] ?? "", sqlRaw['Proceso_3'] ?? ""),
            const SizedBox(height: 10),
            _buildRow("Link Drive", excel['Link_Drive'] ?? "", sqlRaw['Link_Drive'] ?? ""),
          ],
        ),
      ),
      actions: [
        Button(
          child: const Text("Editar Manualmente"),
          onPressed: () => Navigator.pop(context, 'EDIT'),
        ),
        Button(
          child: const Text("Descartar (Usar SQL)"),
          onPressed: () => Navigator.pop(context, 'SQL'),
        ),
        FilledButton(
          child: const Text("Aprobar Excel"),
          onPressed: () => Navigator.pop(context, 'EXCEL'),
        ),
      ],
    );
  }
}
