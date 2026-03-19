#!/usr/bin/env python3
import sys
from pathlib import Path

TARGET = Path(__file__).parent.parent / "lib" / "screens" / "bom_manager.dart"
raw = TARGET.read_bytes().decode("utf-8").replace("\r\n", "\n").replace("\r", "\n")
lines = raw.split("\n")
print(f"Archivo: {TARGET.name} - {len(lines)} lineas")

def insert_after(zero_idx, new_lines_str):
    new_lines = new_lines_str.split("\n")
    lines[zero_idx+1:zero_idx+1] = new_lines

def replace_range(zero_start, zero_end, new_text):
    new_lines = new_text.split("\n")
    lines[zero_start:zero_end+1] = new_lines

# ─────────────────────────────────────────────────────────────────────────────
# 1. Semáforo Tooltip al lado del CommandBar
# Buscar separator: "color: Colors.grey.withOpacity(0.2),"
# En la línea siguiente a esa, antes del CommandBar
# ─────────────────────────────────────────────────────────────────────────────
separator_idx = next((i for i, l in enumerate(lines) if "color: Colors.grey.withOpacity" in l and "Expanded(" in lines[i+2]), -1)
if separator_idx != -1:
    insert_after(separator_idx + 1,
        "                        // ── Semáforo de Estado ──\n"
        "                        Padding(\n"
        "                          padding: const EdgeInsets.symmetric(horizontal: 14),\n"
        "                          child: Tooltip(\n"
        "                            message: _esAprobada \n"
        "                                ? 'Revisión Aprobada - Sólo Lectura' \n"
        "                                : _esObsoleta \n"
        "                                    ? 'Archivo Histórico - Sólo Lectura' \n"
        "                                    : 'Borrador - Edición Activa',\n"
        "                            child: Icon(\n"
        "                              FluentIcons.circle_fill, \n"
        "                              size: 14, \n"
        "                              color: _esAprobada \n"
        "                                  ? const Color(0xFF2E7D32) \n"
        "                                  : _esObsoleta \n"
        "                                      ? const Color(0xFF9E9E9E) \n"
        "                                      : const Color(0xFFF9A825)\n"
        "                            ),\n"
        "                          ),\n"
        "                        ),"
    )
    print("  [OK] Semáforo insertado")
else:
    print("  [FAIL] No se encontró separator del CommandBar")

# ─────────────────────────────────────────────────────────────────────────────
# 2. Eliminar InfoBars gigantes y Banner MODO EDICION
# Buscar: "// ── Banner MODO EDICIÓN" o "// ── InfoBar: Revisión APROBADA"
# Encontrar donde termina (antes de "Expanded(child: _vistaPlana")
# ─────────────────────────────────────────────────────────────────────────────
start_banner = next((i for i, l in enumerate(lines) if "Banner MODO EDIC" in l), -1)
if start_banner == -1:
    start_banner = next((i for i, l in enumerate(lines) if "InfoBar: Revisión APROBADA" in l), -1)

end_banner = next((i for i, l in enumerate(lines) if "ZONA PRINCIPAL" in l), -1)

if start_banner != -1 and end_banner != -1:
    # also remove the 'if (_isLoading) const ProgressBar(),' which is above start_banner usually, 
    # but let's keep progress bar, just kill the banners
    replace_range(start_banner, end_banner - 1, "")
    print("  [OK] Banners / InfoBars eliminados")
else:
    print("  [FAIL] No se encontraron banners para eliminar")


# ─────────────────────────────────────────────────────────────────────────────
# 3. Crash CommandBar RangeError
# ─────────────────────────────────────────────────────────────────────────────
cmd_bar_idx = next((i for i, l in enumerate(lines) if "child: CommandBar(" in l and "overflowBehavior:" in lines[i+1]), -1)
if cmd_bar_idx != -1:
    lines[cmd_bar_idx] = lines[cmd_bar_idx].replace("CommandBar(", 
        "CommandBar(\n                            key: ValueKey(_selectedRevision?['id_revision'] ?? 'cmd'),")
    print("  [OK] CommandBar ValueKey insertado")
else:
    print("  [FAIL] No se encontró CommandBar child")


# ─────────────────────────────────────────────────────────────────────────────
# 4. Restaurar botón Eliminar Bypass Admin
# ─────────────────────────────────────────────────────────────────────────────
delete_start = next((i for i, l in enumerate(lines) if "Eliminar: sólo Borrador" in l), -1)
if delete_start != -1:
    # Buscar el final (hasta _vistaPlana)
    delete_end = next((i for i, l in enumerate(lines) if "icon: Icon(" in l and "vistaPlana" in lines[i+1] and i > delete_start), -1)
    if delete_end != -1:
        replace_range(delete_start, delete_end - 2, 
            "                              // ── Eliminar: siempre visible, admin bypass si no es borrador ──\n"
            "                              if (_selectedRevision != null)\n"
            "                                CommandBarButton(\n"
            "                                  icon: Icon(FluentIcons.delete,\n"
            "                                      color: _esEditable ? const Color(0xFFF57C00) : const Color(0xFFBDBDBD)),\n"
            "                                  label: const Text('Eliminar'),\n"
            "                                  onPressed: _esEditable \n"
            "                                      ? _checkAndShowDeleteDialog \n"
            "                                      : _showAdminDeleteDialog,\n"
            "                                ),")
        print("  [OK] Botón Eliminar modificado (Admin Bypass)")
    else:
        print("  [FAIL] No se encontró fin de bloque Eliminar")
else:
    print("  [FAIL] No se encontró inicio de bloque Eliminar")

# Y añadir la función _showAdminDeleteDialog antes de _checkAndShowDeleteDialog
check_del_idx = next((i for i, l in enumerate(lines) if "Future<void> _checkAndShowDeleteDialog() async {" in l), -1)
if check_del_idx != -1:
    # Subimos unas lineas para insertar antes del comentario
    insert_idx = check_del_idx - 1
    if "── Verificaci" in lines[insert_idx]:
        insert_idx -= 1
    insert_after(insert_idx, """
  // ── Admin Delete Override ───────────────────────────────────────────────────
  void _showAdminDeleteDialog() {
    final TextEditingController pwdCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => ContentDialog(
        title: const Text('Anular Bloqueo (Admin)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Esta revisión está bloqueada.\\nIngrese contraseña de administrador para forzar un borrado completo de la revisión histórica:', style: TextStyle(fontSize: 13)),
            const SizedBox(height: 12),
            PasswordBox(
              controller: pwdCtrl,
              placeholder: 'Contraseña (e ej. ADMIN_ING_2024)',
              onSubmitted: (v) {
                if (v == 'ADMIN_ING_2024') {
                  Navigator.pop(ctx);
                  _checkAndShowDeleteDialog();
                } else {
                  _showError('Contraseña incorrecta');
                }
              },
            ),
          ],
        ),
        actions: [
          Button(child: const Text('Cancelar'), onPressed: () => Navigator.pop(ctx)),
          FilledButton(
            style: ButtonStyle(backgroundColor: WidgetStateProperty.all(Colors.red)),
            onPressed: () {
              if (pwdCtrl.text == 'ADMIN_ING_2024') {
                Navigator.pop(ctx);
                _checkAndShowDeleteDialog();
              } else {
                _showError('Contraseña incorrecta');
              }
            },
            child: const Text('Forzar Borrado', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
""")
    print("  [OK] _showAdminDeleteDialog añadido")


# ─────────────────────────────────────────────────────────────────────────────
# 5. Listas vacías: quitar la lógica if (_esObsoleta) del arbol
# ─────────────────────────────────────────────────────────────────────────────
obs_tree_idx = next((i for i, l in enumerate(lines) if "child: _esObsoleta" in l and "Mensaje de archivo hist" in lines[i+1]), -1)
if obs_tree_idx != -1:
    # The condition is:
    # child: _esObsoleta
    #     ? Center(...)
    #     : ListView.builder(...)
    # We want to remove the ternary and just keep child: ListView.builder(...)
    # To do this safely by indices:
    lv_idx = next((i for i, l in enumerate(lines) if "child: ListView.builder(" in l and i > obs_tree_idx), -1)
    if lv_idx != -1:
        replace_range(obs_tree_idx, lv_idx - 1, "")
        print("  [OK] Listas vacías: Quitada condición _esObsoleta del Árbol (Lado 1)")
        # Quitar el paréntesis extra que cerraba la condición terciaria.
        # Find the end of ListView.builder... this is hard to trace line by line.
        # Actually it's easier to use a regex on the whole string JUST for this part.

# Alternative regex for the _esObsoleta block:
full_text = "\n".join(lines)
import re
new_text = re.sub(
    r'child: _esObsoleta\s+// Tarea 4: Mensaje de archivo histórico\s+\? Center\([\s\S]*?child: ListView\.builder\(',
    r'child: ListView.builder(',
    full_text
)
# Fix the trailing parenthesis for the ternary
# It's at the end of the ListView, enclosed in `          ) // Faltaba un paréntesis de cierre\n` ... wait no, let's look at the actual code
# Actually the code doesn't have "Faltaba un parentesis", it was just my memory of an old file. Let's look at the file.
new_lines = new_text.split('\n')
print("  [OK] Regex applied for empty tree list")

lines = new_lines

# ─────────────────────────────────────────────────────────────────────────────
# 6. Bug de guardado de Cantidades (ID Estructura correcto y setState)
# Buscar el ListView de Tree y Vista Plana
# 1. EN ÁRBOL (aproximadamente línea 1944)
# _updateCantidadPieza(pieza['id'], cant);
# Asegurar: pieza['id'] ES el ID_Estructura en la respuesta /api/bom/arbol/{id}.
# Y en la vista Plana, añadir el TextBox.
# ─────────────────────────────────────────────────────────────────────────────
# TextBox Árbol:
for i, l in enumerate(lines):
    if "_updateCantidadPieza(" in l and "pieza" in l and "cant" in l:
        lines[i] = lines[i].replace("pieza['id']", "pieza['id_estructura']")
        print("  [OK] ID_Estructura corregido en Árbol")

# Vista Plana (añadir TextBox):
vp_dataCell_cant_idx = next((i for i, l in enumerate(lines) if "dataCell(cantStr, wCant, isNumber: true)," in l and i > 2500), -1)
if vp_dataCell_cant_idx != -1:
    replace_range(vp_dataCell_cant_idx, vp_dataCell_cant_idx, """
                              // TextBox Editable para Vista Plana
                              Container(
                                width: wCant,
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                decoration: BoxDecoration(
                                  border: Border(right: BorderSide(color: borderColor, width: 0.5)),
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
                                      final int idEst = row['id_estructura'] != null ? (row['id_estructura'] as num).toInt() : 0;
                                      if (idEst > 0) {
                                        await _updateCantidadPieza(idEst, cant);
                                        // Refrescar plana para fijar valor en UI
                                        if (!_hasPendingChanges) _fetchBomPlana();
                                      } else {
                                        _showError("No se encontró el id_estructura para esta pieza.");
                                      }
                                    } else {
                                      _showError("Cantidad inválida o igual a 0");
                                    }
                                  },
                                ),
                              ),""")
    print("  [OK] TextBox y Guardado de cantidad en Vista Plana insertado")

# Hacer que `_updateCantidadPieza` ejecute `_fetchBomPlana()` o similar?
# El método _updateCantidadPieza actualmente llama a `_fetchArbol();`. 
# Si estamos en plana, debe llamar a `_fetchBomPlana()`.
update_api_idx = next((i for i, l in enumerate(lines) if "Future<void> _updateCantidadPieza" in l), -1)
if update_api_idx != -1:
    fetch_arbol_idx = next((i for i, l in enumerate(lines) if "if (response.statusCode == 200) {" in lines[i-1] and "_showError" in lines[i+1] and i > update_api_idx), -1)
    if fetch_arbol_idx != -1:
        replace_range(fetch_arbol_idx, fetch_arbol_idx, 
            "        if (_vistaPlana) {\n"
            "          _fetchBomPlana();\n"
            "        } else {\n"
            "          _fetchArbol();\n"
            "        }")
        print("  [OK] _updateCantidadPieza actualizado para refrescar _vistaPlana si está activa")

# Fix trailing ternary paren of obsolete if we removed the top part
paren_fix_idx = next((i for i, l in enumerate(lines) if "                              }," in lines[i-1] and "                            )," in lines[i] and "                          )," in lines[i+1] and i > 2000 and i < 2400), -1)
# Actually, the quickest way to fix the dangling Parenthesis logic from removing ternary statement:
# En `lib/screens/bom_manager.dart`, line ~2175, there is a } closing the ListView.builder. 
# Then `),` closing Expanded.
# Then `)` closing Column/Center if obsolete was there? Let me run dart analyze after patching.

TARGET.write_text("\n".join(lines), "utf-8")
print("✅ Python script completed")
