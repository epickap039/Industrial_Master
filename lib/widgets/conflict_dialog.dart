import 'package:fluent_ui/fluent_ui.dart';

class ConflictResolutionDialog extends StatelessWidget {
  final dynamic item;

  const ConflictResolutionDialog({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    final excel = item['Excel_Data'];
    final sqlRaw = item['SQL_Data'] ?? {}; 
    
    // Helper para campos individuales
    Widget _buildFieldParams(String label, String val, bool isHighlighted) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
            SelectableText(
              val.isEmpty ? "-" : val,
              style: TextStyle(
                fontWeight: isHighlighted ? FontWeight.bold : FontWeight.normal,
                color: isHighlighted ? Colors.red : null,
              ),
            ),
          ],
        ),
      );
    }

    // Helper para construir la tarjeta de datos
    Widget _buildDataCard(BuildContext context, String title, Map<String, dynamic> data, Color headerColor, bool isExcel) {
      return Card(
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            // Header
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
              color: headerColor.withOpacity(0.2),
              child: Text(title, style: TextStyle(fontWeight: FontWeight.bold, color: headerColor)),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildFieldParams("Descripción", data[isExcel ? 'Descripcion_Excel' : 'Descripcion'] ?? "", true),
                      const Divider(),
                      Row(
                        children: [
                          Expanded(child: _buildFieldParams("Medida", data[isExcel ? 'Medida_Excel' : 'Medida'] ?? "", true)),
                          const SizedBox(width: 8),
                          Expanded(child: _buildFieldParams("Material", data[isExcel ? 'Material_Excel' : 'Material'] ?? "", true)),
                        ],
                      ),
                       const Divider(),
                       Row(
                        children: [
                          Expanded(child: _buildFieldParams("Simetría", data['Simetria'] ?? "", false)),
                          const SizedBox(width: 8),
                          Expanded(child: _buildFieldParams("Proc. Prim.", data['Proceso_Primario'] ?? "", false)),
                        ],
                      ),
                      _buildFieldParams("Link", data['Link_Drive'] ?? "", false),
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
      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.9), // Ancho 90%
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text("Resolución de Conflictos: ${item['Codigo_Pieza']}"),
          IconButton(
            icon: const Icon(FluentIcons.chrome_close, size: 14),
            onPressed: () => Navigator.pop(context, null),
          ),
        ],
      ),
      content: SizedBox(
        height: 500, // Altura fija para layout controlado
        child: Row(
          children: [
            // COLUMNA 1: EXCEL
            Expanded(
              flex: 4,
              child: Column(
                children: [
                  Expanded(child: _buildDataCard(context, "PROPUESTA EXCEL (NUEVO)", excel, Colors.successPrimaryColor, true)),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton(
                      style: ButtonStyle(
                        backgroundColor: ButtonState.all(Colors.successPrimaryColor),
                      ),
                      child: const Text("USAR DATOS EXCEL", style: TextStyle(fontWeight: FontWeight.bold)),
                      onPressed: () => Navigator.pop(context, {'action': 'SYNC_EXCEL', 'data': excel}),
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
                  Expanded(child: _buildDataCard(context, "BASE DE DATOS (ACTUAL)", sqlRaw, Colors.warningPrimaryColor, false)),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: Button(
                      child: const Text("MANTENER DATOS BD", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.warningPrimaryColor)),
                      onPressed: () => Navigator.pop(context, {'action': 'KEEP_DB', 'data': sqlRaw}),
                    ),
                  ),
                ],
              ),
            ),
            
            const SizedBox(width: 24),
            
            // COLUMNA 3: ACCIONES EXTRA
            SizedBox(
              width: 150,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text("Otras Acciones", style: TextStyle(color: Colors.grey)),
                  const SizedBox(height: 12),
                  Button(
                    child: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(FluentIcons.edit, size: 24),
                        SizedBox(height: 8),
                        Text("Editar Manualmente", textAlign: TextAlign.center),
                      ],
                    ),
                    onPressed: () => Navigator.pop(context, {'action': 'EDIT_MANUAL'}),
                  ),
                ],
              ),
            )
          ],
        ),
      ),
      actions: const [], // Sin acciones estándar, usamos botones custom
    );
  }
}
