#!/usr/bin/env python3
import sys
from pathlib import Path

TARGET = Path("lib/screens/bom_manager.dart")
raw = TARGET.read_bytes().decode("utf-8").replace("\r\n", "\n").replace("\r", "\n")

# 1. Seguridad: Quitar placeholder con admin y bypassear confirmación en _showAdminDeleteDialog
raw = raw.replace("placeholder: 'Contraseña (ADMIN_ING_2024)',", "placeholder: 'Contraseña maestra...',")
raw = raw.replace("""                if (v == 'ADMIN_ING_2024') {
                  Navigator.pop(ctx);
                  _checkAndShowDeleteDialog();
                }""", """                if (v == 'ADMIN_ING_2024') {
                  Navigator.pop(ctx);
                  _deleteRevision(password: v, motivo: 'Forzado por Admin Override');
                }""")
raw = raw.replace("""              if (pwdCtrl.text == 'ADMIN_ING_2024') {
                Navigator.pop(ctx);
                _checkAndShowDeleteDialog();
              }""", """              if (pwdCtrl.text == 'ADMIN_ING_2024') {
                Navigator.pop(ctx);
                _deleteRevision(password: pwdCtrl.text, motivo: 'Forzado por Admin Override');
              }""")

# 2. Blindaje de la Máquina de Estados (La Regla del Borrador Único)
branching_guard = """  Future<void> _showBranchingDialog() async {
    if (_selectedRevision == null) return;
    
    final bool hasBorrador = _revisiones.any((r) => r['estado'] == 'Borrador' || r['estado'] == 'PENDIENTE');
    if (hasBorrador) {
       _showError('No se puede crear otra revisión. Ya existe una en edición permanente ("Borrador" / "Pendiente"). Finalízala primero.');
       return;
    }
"""
raw = raw.replace("""  Future<void> _showBranchingDialog() async {
    if (_selectedRevision == null) return;
""", branching_guard)

add_revision_guard = """  Future<void> _addRevision(String notas) async {
    final bool hasBorrador = _revisiones.any((r) => r['estado'] == 'Borrador' || r['estado'] == 'PENDIENTE');
    if (hasBorrador) {
       _showError('Ya existe una revisión activa. No se puede crear una base nueva.');
       return;
    }
"""
raw = raw.replace("  Future<void> _addRevision(String notas) async {", add_revision_guard, 1)

# 3. Reparar Guardado y Trazabilidad (Refresco en onSubmitted o updateCantidadPieza)
# We already changed `id_estructura` in earlier revisions, but let's check updateCantidadPieza to do the _vistaPlana refresh:
# Wait, let's fix the X-Usuario universally:
raw = raw.replace("{'Content-Type': 'application/json'}", "{'Content-Type': 'application/json', 'X-Usuario': 'Admin PLM'}")
raw = raw.replace("headers: {\n              'X-Usuario': 'Admin PLM',", "headers: {\n              'X-Usuario': 'Admin PLM',") # Avoid duplications just in case
raw = raw.replace("headers: {\n              'Content-Type': 'application/json',\n            },", "headers: {\n              'Content-Type': 'application/json',\n              'X-Usuario': 'Admin PLM',\n            },")

# For _updateCantidadPieza, ensure it handles _vistaPlana correctly:
update_body = """      if (response.statusCode == 200) {
        if (mounted) setState(() => _hasPendingChanges = false);
        _showError("✅ Cantidad actualizada correctamente", isError: false);
        if (_vistaPlana) {
          _fetchBomPlana();
        } else {
          _fetchArbol();
        }
      } else {"""
raw = raw.replace("""      if (response.statusCode == 200) {
        _showError("✅ Cantidad actualizada correctamente", isError: false);
        _fetchArbol();
      } else {""", update_body)


# 5. Vista Plana Excel 13 Columnas
# Definitions:
old_widths = """    const double wNivel = 80.0;
    const double wCodigo = 210.0;
    const double wDesc = 300.0;
    const double wCant = 80.0;
    const double wMat = 160.0;
    const double totalWidth = wNivel + wCodigo + wDesc + wCant + wMat;"""
new_widths = """    const double wNivel = 80.0;
    const double wCodigo = 180.0;
    const double wDesc = 250.0;
    const double wCant = 80.0;
    const double wMat = 140.0;
    const double wMedida = 65.0; // Largo, Ancho, Espesor
    const double wProceso = 85.0; // P. Primario, 1, 2, 3
    const double wSimetria = 80.0;
    const double totalWidth = wNivel + wCodigo + wDesc + wCant + wMat + (wMedida * 3) + (wProceso * 4) + wSimetria;"""
raw = raw.replace(old_widths, new_widths)

old_header_cells = """                      children: [
                        headerCell("Nivel", wNivel),
                        headerCell("Código", wCodigo),
                        headerCell("Descripción", wDesc),
                        headerCell("Cantidad", wCant),
                        headerCell("Material", wMat),
                      ],"""
new_header_cells = """                      children: [
                        headerCell("Estación", wNivel),
                        headerCell("Código", wCodigo),
                        headerCell("Descripción", wDesc),
                        headerCell("Material", wMat),
                        headerCell("Cantidad", wCant),
                        headerCell("Largo", wMedida),
                        headerCell("Ancho", wMedida),
                        headerCell("Espesor", wMedida),
                        headerCell("Proc. P", wProceso),
                        headerCell("Proc. 1", wProceso),
                        headerCell("Proc. 2", wProceso),
                        headerCell("Proc. 3", wProceso),
                        headerCell("Simetría", wSimetria),
                      ],"""
raw = raw.replace(old_header_cells, new_header_cells)

# Now Data cells:
old_data_cells = """                          child: Row(
                            children: [
                              dataCell(
                                nivelLabel,
                                wNivel,
                                isNumber: true,
                                colorOverride: rowTextOverride,
                                fontWeight: fw,
                              ),
                              dataCell(
                                row['codigo_pieza']?.toString() ?? '',
                                wCodigo,
                                colorOverride: rowTextOverride,
                                fontWeight: fw,
                              ),
                              dataCell(
                                row['descripcion']?.toString() ?? '',
                                wDesc,
                                tooltip: true,
                              ),
                              nivel == 3
                                  ? Container(
                                      width: wCant,
                                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                      decoration: BoxDecoration(
                                        border: Border(
                                            right: BorderSide(color: borderColor, width: 0.5)),
                                      ),
                                      child: TextBox(
                                        controller: TextEditingController(text: cantStr),
                                        keyboardType: TextInputType.number,
                                        textInputAction: TextInputAction.done,
                                        enabled: _esEditable,
                                        placeholder: "Cant.",
                                        textAlign: TextAlign.center,
                                        onSubmitted: (value) async {
                                          final cant = double.tryParse(value);
                                          if (cant != null && cant > 0) {
                                            final idEst = row['id_estructura'];
                                            if (idEst != null) {
                                              await _updateCantidadPieza(
                                                  (idEst as num).toInt(), cant);
                                            } else {
                                              _showError("Pieza sin id_estructura válido.");
                                            }
                                          } else {
                                            _showError("Cantidad inválida o igual a 0");
                                          }
                                        },
                                      ),
                                    )
                                  : dataCell(cantStr, wCant, isNumber: true),
                              dataCell(
                                row['material']?.toString() ?? '',
                                wMat,
                              ),
                            ],
                          ),"""
new_data_cells = """                          child: Row(
                            children: [
                              dataCell(
                                nivelLabel,
                                wNivel,
                                isNumber: true,
                                colorOverride: rowTextOverride,
                                fontWeight: fw,
                              ),
                              dataCell(row['codigo_pieza']?.toString() ?? '', wCodigo, colorOverride: rowTextOverride, fontWeight: fw),
                              dataCell(row['descripcion']?.toString() ?? '', wDesc, tooltip: true),
                              dataCell(row['material']?.toString() ?? '', wMat, tooltip: true),
                              nivel == 3
                                  ? Container(
                                      width: wCant,
                                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                      decoration: BoxDecoration(border: Border(right: BorderSide(color: borderColor, width: 0.5))),
                                      child: TextBox(
                                        controller: TextEditingController(text: cantStr),
                                        keyboardType: TextInputType.number,
                                        enabled: _esEditable,
                                        textAlign: TextAlign.center,
                                        onSubmitted: (value) async {
                                          final cant = double.tryParse(value);
                                          if (cant != null && cant > 0) {
                                            final idEst = row['id_estructura'];
                                            if (idEst != null) {
                                              await _updateCantidadPieza((idEst as num).toInt(), cant);
                                            } else { _showError("Sin id_estructura"); }
                                          } else { _showError("Cantidad inválida"); }
                                        },
                                      ),
                                    )
                                  : dataCell(cantStr, wCant, isNumber: true),
                              dataCell(row['largo']?.toString() ?? '', wMedida, isNumber: true),
                              dataCell(row['ancho']?.toString() ?? '', wMedida, isNumber: true),
                              dataCell(row['espesor']?.toString() ?? '', wMedida, isNumber: true),
                              dataCell(row['proceso_primario']?.toString() ?? '', wProceso, tooltip: true),
                              dataCell(row['proceso_1']?.toString() ?? '', wProceso, tooltip: true),
                              dataCell(row['proceso_2']?.toString() ?? '', wProceso, tooltip: true),
                              dataCell(row['proceso_3']?.toString() ?? '', wProceso, tooltip: true),
                              dataCell(row['simetria']?.toString() ?? '', wSimetria, tooltip: true),
                            ],
                          ),"""
raw = raw.replace(old_data_cells, new_data_cells)

# Fix Nivel Label default text to Ensamble name
raw = raw.replace("""} else {
                          nivelLabel = "      PIE";
                        }""", """} else {
                          // Tarea 5: Mostrar Ensamble Padre o PIEZA
                          final padre = row['nom_ensamble']?.toString() ?? "PIEZA";
                          nivelLabel = "      " + (padre.length > 15 ? padre.substring(0,15) : padre);
                        }""")


# 6. Auditoría Visual (Ver Diff in Command Bar)
# The user wants _DiffAuditorDialog accessible anytime. We will add a "Auditor de Cambios" button in CommandBar!
diff_btn = """                              if (_selectedRevision != null)
                                CommandBarButton(
                                  icon: const Icon(FluentIcons.compare, color: Color(0xFF1976D2)),
                                  label: const Text('Auditor de Diff'),
                                  onPressed: () {
                                    showDialog(
                                      context: context,
                                      builder: (ctx) => _DiffAuditorDialog(
                                        idRevision: _selectedRevision!['id_revision'],
                                        revNum: _selectedRevision!['numero_revision'].toString(),
                                        accentColor: _accentColor,
                                        onConfirm: () => Navigator.pop(ctx),
                                      ),
                                    );
                                  },
                                ),
"""
# Insert before "Aprobar" button
raw = raw.replace("""                              if (_esEditable && !_esAprobada)
                                CommandBarButton(
                                  icon: const Icon(FluentIcons.accept,
                                      color: Color(0xFF4CAF50)),
                                  label: const Text("Aprobar"),
                                  onPressed: _showAprobarConfirmDialog,
                                ),""", diff_btn + """                              if (_esEditable && !_esAprobada)
                                CommandBarButton(
                                  icon: const Icon(FluentIcons.accept,
                                      color: Color(0xFF4CAF50)),
                                  label: const Text("Aprobar"),
                                  onPressed: _showAprobarConfirmDialog,
                                ),""")

TARGET.write_text(raw, "utf-8")
print("✅ bom_manager.dart arreglado y empaquetado!")
