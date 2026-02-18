import 'package:fluent_ui/fluent_ui.dart';

class ConflictResolutionDialog extends StatelessWidget {
  final dynamic item;

  const ConflictResolutionDialog({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    // Datos: asegurar que sean mapas, aunque vengan vacíos
    final Map<String, dynamic> excel = item['Excel_Data'] is Map ? Map<String, dynamic>.from(item['Excel_Data']) : {};
    final Map<String, dynamic> sqlRaw = item['SQL_Data'] is Map ? Map<String, dynamic>.from(item['SQL_Data']) : {}; 
    
    // Helper para etiquetas y valores con estilo
    Widget _buildFieldParams(String label, String val, bool isHighlighted, {bool isHeader = false}) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label.toUpperCase(), 
              style: TextStyle(
                fontSize: 9, 
                color: Colors.grey[120],
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5
              )
            ),
            const SizedBox(height: 2),
            SelectableText(
              val.isEmpty ? "-" : val,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isHighlighted || isHeader ? FontWeight.bold : FontWeight.normal,
                color: isHighlighted ? Colors.red : Colors.black,
              ),
            ),
          ],
        ),
      );
    }

    // Helper para construir la tarjeta de datos
    Widget _buildDataCard(BuildContext context, String title, Map<String, dynamic> data, Color headerColor, bool isExcel) {
      if (data.isEmpty) {
        return Card(
           padding: const EdgeInsets.all(24),
           child: Center(
             child: Column(
               mainAxisAlignment: MainAxisAlignment.center,
               children: [
                 Icon(FluentIcons.database, size: 48, color: Colors.grey[60]),
                 const SizedBox(height: 16),
                 Text("Sin datos en BD", style: TextStyle(color: Colors.grey[100])),
               ],
             ),
           ),
        );
      }

      return Card(
        padding: EdgeInsets.zero,
        backgroundColor: headerColor.withOpacity(0.05), // Fondo tintado suave
        borderColor: headerColor.withOpacity(0.3),
        child: Column(
          children: [
            // Header Estilizado
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
              decoration: BoxDecoration(
                color: headerColor,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
              ),
              child: Row(
                children: [
                  Icon(isExcel ? FluentIcons.excel_logo : FluentIcons.database, color: Colors.white, size: 16),
                  const SizedBox(width: 8),
                  Text(title, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildFieldParams("Descripción", data[isExcel ? 'Descripcion_Excel' : 'Descripcion'] ?? "", true, isHeader: true),
                      const SizedBox(height: 12),
                      const Divider(),
                      const SizedBox(height: 12),
                      
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: _buildFieldParams("Medida", data[isExcel ? 'Medida_Excel' : 'Medida'] ?? "", true)),
                          const SizedBox(width: 16),
                          Expanded(child: _buildFieldParams("Material", data[isExcel ? 'Material_Excel' : 'Material'] ?? "", true)),
                        ],
                      ),
                       const SizedBox(height: 8),
                       Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: _buildFieldParams("Simetría", data['Simetria'] ?? "", false)),
                          const SizedBox(width: 16),
                          Expanded(child: _buildFieldParams("Proc. Prim.", data['Proceso_Primario'] ?? "", false)),
                        ],
                      ),
                      
                      const SizedBox(height: 12),
                      const Divider(),
                      const SizedBox(height: 12),
                      
                      // NUEVOS CAMPOS: PROCESOS
                      const Text("PROCESOS SECUNDARIOS", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(child: _buildFieldParams("Proc. 1", data['Proceso_1'] ?? "", false)),
                          Expanded(child: _buildFieldParams("Proc. 2", data['Proceso_2'] ?? "", false)),
                          Expanded(child: _buildFieldParams("Proc. 3", data['Proceso_3'] ?? "", false)),
                        ],
                      ),

                      const SizedBox(height: 12),
                      const Divider(),
                      const SizedBox(height: 12),
                      _buildFieldParams("Link Drive", data['Link_Drive'] ?? "", false),
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
      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.95), // Ancho 95%
      title: Row(
        children: [
          const Text("Resolución de Conflictos", style: TextStyle(fontSize: 20)),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(color: Colors.grey[30], borderRadius: BorderRadius.circular(4)),
            child: Text(item['Codigo_Pieza'] ?? "N/A", style: const TextStyle(fontWeight: FontWeight.bold, fontFamily: 'Consolas')),
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
                  Expanded(child: _buildDataCard(context, "PROPUESTA EXCEL", excel, Colors.green.darkest, true)),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton(
                      style: ButtonStyle(
                        backgroundColor: WidgetStateProperty.all(Colors.green.darkest), 
                        shape: WidgetStateProperty.all(RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)))
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(FluentIcons.check_mark, size: 18),
                          SizedBox(width: 8),
                          Text("USAR EXCEL", style: TextStyle(fontWeight: FontWeight.bold)),
                        ],
                      ),
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
                  Expanded(child: _buildDataCard(context, "BASE DE DATOS ACTUAL", sqlRaw, Colors.red.darkest, false)),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: Button(
                      style: ButtonStyle(
                        shape: WidgetStateProperty.all(RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                          side: BorderSide(color: Colors.red.darkest)
                        )),
                      ),
                      child: Text("MANTENER BD", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red.darkest)),
                      onPressed: () => Navigator.pop(context, {'action': 'KEEP_DB', 'data': sqlRaw}),
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
                  const Text("¿Ninguno es correcto?", textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
                  const SizedBox(height: 12),
                  Button(
                    child: const Text("Editar Manualmente"),
                    onPressed: () => Navigator.pop(context, {'action': 'EDIT_MANUAL'}),
                  ),
                ],
              ),
            )
          ],
        ),
      ),
      actions: const [], 
    );
  }
}
