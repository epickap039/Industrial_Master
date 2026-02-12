import 'package:fluent_ui/fluent_ui.dart';
import 'database_helper.dart';

void showResolveDialog(
  BuildContext context,
  Map<String, dynamic> conflict,
  VoidCallback onSolved,
) {
  final descCtrl = TextEditingController(
    text: conflict['Desc_File'] ?? conflict['Descripcion_Archivo'] ?? conflict['Desc_Master'] ?? '',
  );
  final medidaCtrl = TextEditingController(
    text: conflict['Medida_File'] ?? conflict['Medida_Master'] ?? '',
  );
  final matCtrl = TextEditingController(
    text: conflict['Mat_File'] ?? conflict['Material_Archivo'] ?? conflict['Mat_Master'] ?? '',
  );
  final p0Ctrl = TextEditingController(
    text: (conflict['P0_File'] ?? conflict['P0_Master'] ?? '').toString(),
  );
  final p1Ctrl = TextEditingController(
    text: (conflict['P1_File'] ?? conflict['P1_Master'] ?? '').toString(),
  );
  final p2Ctrl = TextEditingController(
    text: (conflict['P2_File'] ?? conflict['P2_Master'] ?? '').toString(),
  );
  final p3Ctrl = TextEditingController(
    text: (conflict['P3_File'] ?? conflict['P3_Master'] ?? '').toString(),
  );

  bool _isLoading = false;

  showDialog(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) {
        Widget smartDiff(String label, dynamic master, TextEditingController ctrl) {
          final theme = FluentTheme.of(context);
          final mStr = master?.toString().trim() ?? '';
          final cStr = ctrl.text.trim();
          final bool isDifferent = mStr != cStr;

          final labelColor = theme.brightness == Brightness.dark
              ? Colors.white.withOpacity(0.5)
              : Colors.black.withOpacity(0.6);

          final containerBg = theme.brightness == Brightness.dark
              ? Colors.white.withOpacity(0.03)
              : Colors.black.withOpacity(0.05);

          final containerBorder = theme.brightness == Brightness.dark
              ? Colors.white.withOpacity(0.08)
              : Colors.black.withOpacity(0.1);

          final masterTextColor = theme.brightness == Brightness.dark
              ? Colors.white.withOpacity(0.6)
              : Colors.black.withOpacity(0.7);

          final inputTextColor = isDifferent
              ? const Color(0xFFFFA500)
              : (theme.brightness == Brightness.dark ? Colors.white : Colors.black);

          return Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: labelColor)),
                    if (isDifferent) ...[
                      const SizedBox(width: 8),
                      const Icon(FluentIcons.warning, color: Color(0xFFFFA500), size: 14),
                      const SizedBox(width: 4),
                      Text("⚠️ DIFERENCIA", style: TextStyle(fontSize: 10, color: Color(0xFFFFA500), fontWeight: FontWeight.w600)),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        height: 40,
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(color: containerBg, border: Border.all(color: containerBorder), borderRadius: BorderRadius.circular(4)),
                        child: Text(mStr.isEmpty ? '(Vacío)' : mStr, style: TextStyle(fontSize: 12, color: masterTextColor), overflow: TextOverflow.ellipsis),
                      ),
                    ),
                    const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Icon(FluentIcons.chevron_right, size: 12, color: Colors.grey)),
                    Expanded(
                      child: TextBox(
                        controller: ctrl,
                        onChanged: (_) => setDialogState(() {}),
                        style: TextStyle(fontSize: 12, fontWeight: isDifferent ? FontWeight.bold : FontWeight.normal, color: inputTextColor),
                        decoration: WidgetStateProperty.all(BoxDecoration(
                          color: isDifferent ? Colors.orange.withOpacity(0.05) : Colors.transparent,
                          border: Border.all(color: isDifferent ? Colors.orange : theme.resources.textFillColorSecondary.withOpacity(0.1), width: isDifferent ? 1.5 : 1),
                          borderRadius: BorderRadius.circular(4),
                        )),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        }

        return ContentDialog(
          constraints: const BoxConstraints(maxWidth: 800),
          title: Row(
            children: [
              Text("Árbitro: ${conflict['Codigo_Pieza']}"),
              const Spacer(),
              Tooltip(
                message: 'Cerrar sin guardar',
                child: IconButton(
                  icon: const Icon(FluentIcons.chrome_close, size: 20),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ],
          ),
          content: SizedBox(
            height: 500,
            child: Stack(
              children: [
                SingleChildScrollView(
                  child: Opacity(
                    opacity: _isLoading ? 0.3 : 1.0,
                    child: Column(
                      children: [
                        smartDiff("Descripción", conflict['Desc_Master'], descCtrl),
                        smartDiff("Medida / Dimensiones", conflict['Medida_Master'], medidaCtrl),
                        smartDiff("Material", conflict['Mat_Master'], matCtrl),
                        smartDiff("Proceso Primario (P.0)", conflict['P0_Master'], p0Ctrl),
                        smartDiff("Proceso 1 (P.1)", conflict['P1_Master'], p1Ctrl),
                        smartDiff("Proceso 2 (P.2)", conflict['P2_Master'], p2Ctrl),
                        smartDiff("Proceso 3 (P.3)", conflict['P3_Master'], p3Ctrl),
                      ],
                    ),
                  ),
                ),
                if (_isLoading) const Center(child: ProgressRing()),
              ],
            ),
          ),
          actions: [
            Button(
              onPressed: _isLoading ? null : () async {
                setDialogState(() => _isLoading = true);
                try {
                  final db = DatabaseHelper();
                  final res = await db.updateMaster(conflict['Codigo_Pieza'], {}, forceResolve: true);
                  if (res['history_logged'] == true) {
                    onSolved();
                    if (context.mounted) Navigator.pop(context);
                  }
                } catch (e) { setDialogState(() => _isLoading = false); }
              },
              child: const Text("❌ IGNORAR"),
            ),
            FilledButton(
              onPressed: _isLoading ? null : () async {
                setDialogState(() => _isLoading = true);
                try {
                  final db = DatabaseHelper();
                  final payload = {
                    'Descripcion': descCtrl.text,
                    'Medida': medidaCtrl.text,
                    'Material': matCtrl.text,
                    'Proceso_Primario': p0Ctrl.text,
                    'Proceso_1': p1Ctrl.text,
                    'Proceso_2': p2Ctrl.text,
                    'Proceso_3': p3Ctrl.text,
                  };
                  final res = await db.updateMaster(conflict['Codigo_Pieza'], payload, forceResolve: true);
                  if (res['history_logged'] == true) {
                    final report = await db.getHomologation(conflict['Codigo_Pieza']);
                    if (report.isNotEmpty && context.mounted) showHomologationDialog(context, report);
                    onSolved();
                    if (context.mounted) Navigator.pop(context);
                  }
                } catch (e) { setDialogState(() => _isLoading = false); }
              },
              child: const Text("✅ ACEPTAR CAMBIOS"),
            ),
          ],
        );
      },
    ),
  );
}

void showHomologationDialog(BuildContext context, List<Map<String, dynamic>> report) {
  showDialog(
    context: context,
    builder: (c) => ContentDialog(
      title: const Text('⚠️ Alerta de Homologación'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Se detectaron otros proyectos que usan esta misma pieza. ¿Desea actualizarlos también?'),
          const SizedBox(height: 10),
          ...report.take(5).map((r) => Text('• ${r['Proyecto']} (Fila ${r['Fila']})', style: const TextStyle(fontSize: 12))),
        ],
      ),
      actions: [
        Button(child: const Text('Cerrar'), onPressed: () => Navigator.pop(c)),
      ],
    ),
  );
}
