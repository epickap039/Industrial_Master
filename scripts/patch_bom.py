#!/usr/bin/env python3
"""
patch_bom_final.py
Aplica todos los cambios del BOM Manager (Save + Diff Auditor) usando inserciones
y reemplazos por NUMERO DE LINEA, mucho más robusto que buscar strings en un archivo
con caracteres unicode y CRLF.

El archivo HEAD restaurado tiene exactamente 3011 líneas.
"""
import sys
from pathlib import Path

TARGET = Path(__file__).parent.parent / "lib" / "screens" / "bom_manager.dart"
raw = TARGET.read_bytes().decode("utf-8").replace("\r\n", "\n").replace("\r", "\n")
original_lines = raw.split("\n")
n = len(original_lines)
print(f"Archivo: {TARGET.name} - {n} lineas")
if n < 3000:
    print("ERROR: El archivo no parece el HEAD (demasiado corto).")
    sys.exit(1)

# Trabajaremos con 0-indexed internamente
lines = list(original_lines)

def insert_after(zero_idx, new_lines_str):
    """Inserta líneas DESPUÉS de zero_idx."""
    new_lines = new_lines_str.split("\n")
    lines[zero_idx+1:zero_idx+1] = new_lines

def replace_range(zero_start, zero_end, new_text):
    """Reemplaza lines[zero_start..zero_end] (inclusive) con new_text."""
    new_lines = new_text.split("\n")
    lines[zero_start:zero_end+1] = new_lines

def verify_line(zero_idx, expected_fragment, label):
    actual = lines[zero_idx]
    if expected_fragment not in actual:
        print(f"  [FAIL] {label}")
        print(f"    Linea {zero_idx+1}: {repr(actual[:80])}")
        print(f"    Esperado fragmento: {repr(expected_fragment)}")
        sys.exit(1)
    print(f"  [OK] {label}")

# ─────────────────────────────────────────────────────────────────────────────
# 1. Insertar _hasPendingChanges + _lastSavedAt después de línea 53 (0-indexed: 52)
#    Línea 53 en HEAD: "  bool _vistaPlana = false;"
# ─────────────────────────────────────────────────────────────────────────────
verify_line(52, "_vistaPlana = false", "L53: _vistaPlana")
insert_after(52,
    "\n"
    "  // Estado de guardado (indicador de cambios pendientes)\n"
    "  bool _hasPendingChanges = false;\n"
    "  DateTime? _lastSavedAt;"
)
print("  [OK] _hasPendingChanges + _lastSavedAt insertados")

# ─────────────────────────────────────────────────────────────────────────────
# 2. Insertar _showAprobarConfirmDialog antes de _aprobarRevision
#    En HEAD, "  Future<void> _aprobarRevision() async {" está en línea 326 (0-idx: 325)
#    Pero tras la inserción anterior (+4 líneas), ahora es 325+4 = 329
# ─────────────────────────────────────────────────────────────────────────────
# Buscamos dinámicamente para no asumir offset exacto
aprobar_idx = next(i for i,l in enumerate(lines) if "Future<void> _aprobarRevision() async {" in l)
verify_line(aprobar_idx, "_aprobarRevision() async", "futuro _aprobarRevision")

# Insertar antes de _aprobarRevision (después de la línea anterior que es "  }")
insert_after(aprobar_idx - 1,
    "  /// Abre el Auditor de Cambios (diff estilo Git) antes de aprobar la revisión.\n"
    "  void _showAprobarConfirmDialog() {\n"
    "    if (_selectedRevision == null) return;\n"
    "    final int idRev = _selectedRevision!['id_revision'] as int;\n"
    "    final String revNum =\n"
    "        (_selectedRevision!['numero_revision'] ?? '-').toString();\n"
    "    showDialog(\n"
    "      context: context,\n"
    "      builder: (ctx) => _DiffAuditorDialog(\n"
    "        idRevision: idRev,\n"
    "        revNum: revNum,\n"
    "        accentColor: _accentColor,\n"
    "        onConfirm: () {\n"
    "          Navigator.pop(ctx);\n"
    "          _aprobarRevision();\n"
    "        },\n"
    "      ),\n"
    "    );\n"
    "  }\n"
)
print("  [OK] _showAprobarConfirmDialog insertado")

# ─────────────────────────────────────────────────────────────────────────────
# 3. _fetchArbol setState: insertar reset pendingChanges
#    En HEAD línea 352: "        setState(() {"  (dentro de _fetchArbol)
#    línea 353: "          _arbol = json.decode(response.body);"
#    Insertamos después de _arbol = ...
# ─────────────────────────────────────────────────────────────────────────────
arbol_assign_idx = next(i for i,l in enumerate(lines) 
    if "_arbol = json.decode(response.body);" in l and i > 340)
verify_line(arbol_assign_idx, "_arbol = json.decode", "_fetchArbol _arbol assign")
insert_after(arbol_assign_idx,
    "          _hasPendingChanges = false;\n"
    "          _lastSavedAt = DateTime.now();"
)
print("  [OK] _fetchArbol: reset pendingChanges")

# ─────────────────────────────────────────────────────────────────────────────
# 4. _fetchBomPlana setState: reemplazar línea de setState de una sola línea
#    "        setState(() => _bomPlana = json.decode(response.body));"
# ─────────────────────────────────────────────────────────────────────────────
bom_plana_idx = next(i for i,l in enumerate(lines) 
    if "setState(() => _bomPlana = json.decode" in l)
verify_line(bom_plana_idx, "setState(() => _bomPlana", "_fetchBomPlana setState")
replace_range(bom_plana_idx, bom_plana_idx,
    "        setState(() {\n"
    "          _bomPlana = json.decode(response.body);\n"
    "          _hasPendingChanges = false;\n"
    "          _lastSavedAt = DateTime.now();\n"
    "        });"
)
print("  [OK] _fetchBomPlana: reset pendingChanges")

# ─────────────────────────────────────────────────────────────────────────────
# 5. _updateCantidadPieza: marcar pending ANTES del try {}
#    Buscamos "    try {" que sigue al guard de _esEditable
# ─────────────────────────────────────────────────────────────────────────────
update_guard_idx = next(i for i,l in enumerate(lines) 
    if "try {" in l and i > 610 and "updateCantidad" not in l)
# Verificar que el try anterior sea el correcto (en _updateCantidadPieza)
# Buscamos hacia arriba que haya un "return;" seguido de "}"
context_lines = "\n".join(lines[update_guard_idx-4:update_guard_idx+1])
if "_esEditable" not in context_lines and "return;" not in context_lines:
    # Try search again more carefully
    for i, l in enumerate(lines):
        if "try {" in l and i > 610 and i < 680:
            ctx = "\n".join(lines[i-5:i])
            if "return;" in ctx and "_showError" in ctx:
                update_guard_idx = i
                break

verify_line(update_guard_idx, "try {", "_updateCantidadPieza try {")
# Insert the setState BEFORE the try line
lines.insert(update_guard_idx,
    "    if (mounted) setState(() => _hasPendingChanges = true);"
)
print("  [OK] _updateCantidadPieza: marcar pending")

# ─────────────────────────────────────────────────────────────────────────────
# 6. CommandBar: cambiar onPressed de _aprobarRevision a _showAprobarConfirmDialog
#    y añadir botón Guardar antes del botón Aprobar
# ─────────────────────────────────────────────────────────────────────────────
# Buscar la línea "                                   onPressed: _aprobarRevision,"
# que sigue a la label "Aprobar" en el CommandBar
aprobar_btn_idx = next(i for i,l in enumerate(lines) 
    if "onPressed: _aprobarRevision," in l)
verify_line(aprobar_btn_idx, "onPressed: _aprobarRevision,", "CommandBar onPressed _aprobarRevision")
# Cambiar
lines[aprobar_btn_idx] = lines[aprobar_btn_idx].replace(
    "onPressed: _aprobarRevision,",
    "onPressed: _showAprobarConfirmDialog,"
)
print("  [OK] CommandBar Aprobar: onPressed cambiado a _showAprobarConfirmDialog")

# Buscar la línea del ECR comment para insertar el botón Guardar después de _ecrCommandBarItem
ecr_item_idx = next(i for i,l in enumerate(lines) if "_ecrCommandBarItem," in l)
verify_line(ecr_item_idx, "_ecrCommandBarItem,", "ECR item line")
insert_after(ecr_item_idx,
    "\n"
    "                              // ── 💾 Guardar Cambios (solo Borrador) ─────────\n"
    "                              if (_esEditable)\n"
    "                                CommandBarButton(\n"
    "                                  icon: Icon(\n"
    "                                    FluentIcons.save,\n"
    "                                    color: _hasPendingChanges\n"
    "                                        ? Colors.orange\n"
    "                                        : Colors.grey,\n"
    "                                  ),\n"
    "                                  label: Row(\n"
    "                                    mainAxisSize: MainAxisSize.min,\n"
    "                                    children: [\n"
    "                                      Text(\n"
    "                                        _hasPendingChanges\n"
    "                                            ? 'Cambios sin guardar'\n"
    "                                            : 'Actualizado',\n"
    "                                        style: TextStyle(\n"
    "                                          fontSize: 11,\n"
    "                                          color: _hasPendingChanges\n"
    "                                              ? Colors.orange\n"
    "                                              : Colors.grey,\n"
    "                                          fontWeight: _hasPendingChanges\n"
    "                                              ? FontWeight.bold\n"
    "                                              : FontWeight.normal,\n"
    "                                        ),\n"
    "                                      ),\n"
    "                                      if (_hasPendingChanges) ...[\n"
    "                                        const SizedBox(width: 4),\n"
    "                                        Container(\n"
    "                                          width: 7,\n"
    "                                          height: 7,\n"
    "                                          decoration: BoxDecoration(\n"
    "                                            color: Colors.orange,\n"
    "                                            shape: BoxShape.circle,\n"
    "                                          ),\n"
    "                                        ),\n"
    "                                      ],\n"
    "                                    ],\n"
    "                                  ),\n"
    "                                  onPressed: _hasPendingChanges\n"
    "                                      ? () => _vistaPlana\n"
    "                                          ? _fetchBomPlana()\n"
    "                                          : _fetchArbol()\n"
    "                                      : null,\n"
    "                                ),"
)
print("  [OK] Botón 💾 Guardar añadido al CommandBar")

# ─────────────────────────────────────────────────────────────────────────────
# 7. Banner MODO EDICIÓN: insertar después de "if (_isLoading) const ProgressBar(),"
#    y antes de la InfoBar de aprobada
# ─────────────────────────────────────────────────────────────────────────────
progress_bar_idx = next(i for i,l in enumerate(lines) 
    if "if (_isLoading) const ProgressBar()," in l and i > 2700)
verify_line(progress_bar_idx, "if (_isLoading) const ProgressBar(),", "ProgressBar line")
insert_after(progress_bar_idx,
    "\n"
    "                  // ── Banner MODO EDICIÓN (solo Borrador) ──────────────────\n"
    "                  if (_esEditable)\n"
    "                    Padding(\n"
    "                      padding: const EdgeInsets.only(bottom: 3),\n"
    "                      child: Container(\n"
    "                        decoration: BoxDecoration(\n"
    "                          gradient: LinearGradient(colors: [\n"
    "                            _accentColor.withOpacity(0.18),\n"
    "                            _accentColor.withOpacity(0.06),\n"
    "                          ]),\n"
    "                          border: Border(\n"
    "                              left: BorderSide(color: _accentColor, width: 3)),\n"
    "                          borderRadius: BorderRadius.circular(4),\n"
    "                        ),\n"
    "                        padding: const EdgeInsets.symmetric(\n"
    "                            horizontal: 10, vertical: 5),\n"
    "                        child: Row(children: [\n"
    "                          Icon(FluentIcons.edit, size: 12,\n"
    "                              color: _accentColor),\n"
    "                          const SizedBox(width: 6),\n"
    "                          Text(\n"
    "                            'MODO EDICIÓN  ·  Confirma cantidades con Enter en cada celda.',\n"
    "                            style: TextStyle(\n"
    "                              fontSize: 11,\n"
    "                              color: _accentColor,\n"
    "                              fontWeight: FontWeight.w600,\n"
    "                            ),\n"
    "                          ),\n"
    "                          const Spacer(),\n"
    "                          if (_lastSavedAt != null)\n"
    "                            Text(\n"
    "                              'Sync '\n"
    "                              '${_lastSavedAt!.hour.toString().padLeft(2, \"0\")}:'\n"
    "                              '${_lastSavedAt!.minute.toString().padLeft(2, \"0\")}',\n"
    "                              style: TextStyle(\n"
    "                                  fontSize: 10,\n"
    "                                  color: _accentColor.withOpacity(0.7)),\n"
    "                            ),\n"
    "                        ]),\n"
    "                      ),\n"
    "                    ),"
)
print("  [OK] Banner MODO EDICIÓN insertado")

# ─────────────────────────────────────────────────────────────────────────────
# 8. Añadir _DiffAuditorDialog al final del archivo
# ─────────────────────────────────────────────────────────────────────────────
DIFF_WIDGET = """
// ════════════════════════════════════════════════════════════════════════════
// _DiffAuditorDialog — Auditor de Cambios estilo Git/Cursor
// Muestra el diff de la revisión actual vs la anterior antes de aprobar.
// Tabla color-codificada: Verde=nuevo  Rojo=eliminado  Naranja=modificado
// ════════════════════════════════════════════════════════════════════════════

class _DiffAuditorDialog extends StatefulWidget {
  final int          idRevision;
  final String       revNum;
  final Color        accentColor;
  final VoidCallback onConfirm;

  const _DiffAuditorDialog({
    required this.idRevision,
    required this.revNum,
    required this.accentColor,
    required this.onConfirm,
  });

  @override
  State<_DiffAuditorDialog> createState() => _DiffAuditorDialogState();
}

class _DiffAuditorDialogState extends State<_DiffAuditorDialog> {
  bool    _loading     = true;
  String? _error;
  List<_DiffRow> _rows = [];
  int _cntNuevos       = 0;
  int _cntEliminados   = 0;
  int _cntModificados  = 0;

  @override
  void initState() {
    super.initState();
    _loadDiff();
  }

  Future<void> _loadDiff() async {
    try {
      final respDelta = await http.get(
        Uri.parse('$API_URL/api/bom/delta/${widget.idRevision}'),
      );
      if (respDelta.statusCode != 200) {
        setState(() {
          _error   = 'Error en delta: ${respDelta.statusCode}';
          _loading = false;
        });
        return;
      }
      final delta = json.decode(respDelta.body) as Map<String, dynamic>;

      if (delta['tiene_anterior'] != true) {
        setState(() { _rows = []; _loading = false; });
        return;
      }

      final List<String> nuevos =
          List<String>.from(delta['codigos_nuevos']     as List? ?? []);
      final List<String> eliminados =
          List<String>.from(delta['codigos_eliminados'] as List? ?? []);
      final Map<String, dynamic> modificados =
          Map<String, dynamic>.from(delta['modificados'] as Map? ?? {});

      final respPlana = await http.get(
        Uri.parse('$API_URL/api/bom/plana/${widget.idRevision}'),
      );
      final Map<String, String> descMap = {};
      final Map<String, double> cantMap = {};
      if (respPlana.statusCode == 200) {
        final plana = json.decode(respPlana.body) as List<dynamic>;
        for (final row in plana) {
          if ((row['nivel'] as num).toInt() == 3) {
            final cod    = row['codigo_pieza']?.toString() ?? '';
            descMap[cod] = row['descripcion']?.toString() ?? '';
            cantMap[cod] = double.tryParse(row['cantidad']?.toString() ?? '') ?? 0.0;
          }
        }
      }

      final List<_DiffRow> rows = [];

      for (final cod in nuevos) {
        rows.add(_DiffRow(
          tipo:         _DiffTipo.agregado,
          codigo:       cod,
          descripcion:  descMap[cod] ?? '',
          cantAnterior: '',
          cantActual:   _fmt(cantMap[cod] ?? 0.0),
        ));
      }
      for (final cod in eliminados) {
        final prev = (modificados[cod]?['prev_qty'] as num?)?.toDouble() ?? 0.0;
        rows.add(_DiffRow(
          tipo:         _DiffTipo.eliminado,
          codigo:       cod,
          descripcion:  '',
          cantAnterior: _fmt(prev),
          cantActual:   '--',
        ));
      }
      for (final entry in modificados.entries) {
        final cod  = entry.key;
        final prev = double.tryParse(entry.value['prev_qty']?.toString() ?? '') ?? 0.0;
        final curr = double.tryParse(entry.value['curr_qty']?.toString() ?? '') ?? 0.0;
        if (prev == curr) continue;
        rows.add(_DiffRow(
          tipo:         _DiffTipo.modificado,
          codigo:       cod,
          descripcion:  descMap[cod] ?? '',
          cantAnterior: _fmt(prev),
          cantActual:   _fmt(curr),
        ));
      }

      rows.sort((a, b) => a.tipo.index.compareTo(b.tipo.index));

      setState(() {
        _rows           = rows;
        _cntNuevos      = rows.where((r) => r.tipo == _DiffTipo.agregado).length;
        _cntEliminados  = rows.where((r) => r.tipo == _DiffTipo.eliminado).length;
        _cntModificados = rows.where((r) => r.tipo == _DiffTipo.modificado).length;
        _loading        = false;
      });
    } catch (e) {
      setState(() { _error = 'Error: $e'; _loading = false; });
    }
  }

  String _fmt(double v) {
    if (v == v.truncateToDouble()) return v.toInt().toString();
    return v.toStringAsFixed(2).replaceAll(RegExp(r'\\.?0+$'), '');
  }

  @override
  Widget build(BuildContext context) {
    final bool isDark = FluentTheme.of(context).brightness == Brightness.dark;
    final Color bg  = isDark ? const Color(0xFF1E1E2A) : Colors.white;
    final Color tx  = isDark ? const Color(0xFFE8EAED) : const Color(0xFF1A1A2E);
    final Color bdr = isDark ? const Color(0xFF3A3A4A) : const Color(0xFFDDE3EA);

    const Color clrGreen    = Color(0xFF2E7D32);
    const Color clrGreenBg  = Color(0x182E7D32);
    const Color clrRed      = Color(0xFFC62828);
    const Color clrRedBg    = Color(0x18C62828);
    const Color clrOrange   = Color(0xFFE65100);
    const Color clrOrangeBg = Color(0x18E65100);

    const double wFlag  =   5.0;
    const double wCod   = 130.0;
    const double wDesc  = 260.0;
    const double wPrev  =  90.0;
    const double wCurr  =  90.0;
    const double totalW = wFlag + wCod + wDesc + wPrev + wCurr;

    Widget hCell(String label, double w, {TextAlign align = TextAlign.left}) {
      return Container(
        width: w,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        decoration: BoxDecoration(
          color: widget.accentColor,
          border: Border(right: BorderSide(
              color: Colors.white.withOpacity(0.15), width: 0.5)),
        ),
        child: Text(label,
          style: const TextStyle(color: Colors.white,
              fontWeight: FontWeight.bold, fontSize: 11, letterSpacing: 0.3),
          textAlign: align, overflow: TextOverflow.ellipsis),
      );
    }

    Widget dCell(String text, double w,
        {Color? fg, FontWeight fw = FontWeight.normal,
         bool mono = false, TextAlign align = TextAlign.left}) {
      final txt = Text(text,
        style: TextStyle(color: fg ?? tx, fontSize: 11, fontWeight: fw,
            fontFamily: mono ? 'monospace' : null),
        textAlign: align, overflow: TextOverflow.ellipsis, maxLines: 1);
      return Container(
        width: w,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
            border: Border(right: BorderSide(color: bdr, width: 0.5))),
        child: text.length > 35 ? Tooltip(message: text, child: txt) : txt,
      );
    }

    Widget badge(String label, int count, Color color) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(0.5)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 8, height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text('$count $label',
              style: TextStyle(color: color, fontSize: 11,
                  fontWeight: FontWeight.bold)),
        ]),
      );
    }

    return ContentDialog(
      constraints: BoxConstraints(
        maxWidth:  MediaQuery.of(context).size.width  * 0.82,
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      title: Row(children: [
        Icon(FluentIcons.compare, size: 18, color: widget.accentColor),
        const SizedBox(width: 8),
        Expanded(child: Text(
          'Auditor de Cambios — Rev. ${widget.revNum}',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
          overflow: TextOverflow.ellipsis)),
        if (!_loading && _error == null) ...[
          const SizedBox(width: 8),
          badge('Nuevas',      _cntNuevos,      clrGreen),
          const SizedBox(width: 6),
          badge('Eliminadas',  _cntEliminados,  clrRed),
          const SizedBox(width: 6),
          badge('Modificadas', _cntModificados, clrOrange),
        ],
      ]),
      content: _loading
          ? const Center(child: ProgressRing())
          : _error != null
              ? Center(child: Text(_error!,
                  style: TextStyle(color: Colors.red)))
              : _rows.isEmpty
                  ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(FluentIcons.check_mark, size: 40, color: clrGreen),
                      const SizedBox(height: 12),
                      const Text('Sin diferencias detectadas.',
                          style: TextStyle(fontSize: 15,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      Text(
                        'La revisión ${widget.revNum} es idéntica a la anterior.',
                        style: const TextStyle(fontSize: 12, color: Colors.grey)),
                    ]))
                  : Container(
                      decoration: BoxDecoration(
                          border: Border.all(color: bdr),
                          borderRadius: BorderRadius.circular(6),
                          color: bg),
                      child: Column(children: [
                        Row(children: [
                          Container(width: wFlag, color: widget.accentColor),
                          hCell('Código',        wCod),
                          hCell('Descripción',   wDesc),
                          hCell('Rev. Anterior', wPrev, align: TextAlign.center),
                          hCell('Rev. Actual',   wCurr, align: TextAlign.center),
                        ]),
                        Expanded(child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            width: totalW,
                            child: ListView.builder(
                              itemCount: _rows.length,
                              itemBuilder: (ctx, i) {
                                final r = _rows[i];
                                Color rowBg, flagClr, codeFg, qtyFg;
                                String icon;
                                switch (r.tipo) {
                                  case _DiffTipo.agregado:
                                    rowBg = clrGreenBg; flagClr = clrGreen;
                                    codeFg = clrGreen; qtyFg = clrGreen; icon = '+';
                                  case _DiffTipo.eliminado:
                                    rowBg = clrRedBg; flagClr = clrRed;
                                    codeFg = clrRed; qtyFg = clrRed; icon = '-';
                                  case _DiffTipo.modificado:
                                    rowBg = isDark ? const Color(0xFF1E1000) : clrOrangeBg;
                                    flagClr = clrOrange; codeFg = clrOrange;
                                    qtyFg = clrOrange; icon = '*';
                                }
                                return Container(
                                  color: rowBg,
                                  child: Row(children: [
                                    Container(
                                      width: wFlag, color: flagClr,
                                      alignment: Alignment.center,
                                      child: Text(icon, style: const TextStyle(
                                          color: Colors.white, fontSize: 10,
                                          fontWeight: FontWeight.bold)),
                                    ),
                                    dCell(r.codigo, wCod,
                                        fg: codeFg, fw: FontWeight.w600, mono: true),
                                    dCell(r.descripcion, wDesc,
                                        fg: r.tipo == _DiffTipo.eliminado
                                            ? clrRed.withOpacity(0.8) : null),
                                    Container(
                                      width: wPrev,
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 5),
                                      decoration: BoxDecoration(border: Border(
                                          right: BorderSide(color: bdr, width: 0.5))),
                                      child: Text(r.cantAnterior,
                                        style: TextStyle(
                                          fontSize: 12, fontWeight: FontWeight.w600,
                                          color: r.tipo == _DiffTipo.eliminado ? clrRed
                                              : r.tipo == _DiffTipo.modificado
                                                  ? clrOrange.withOpacity(0.7) : tx,
                                          decoration: r.tipo == _DiffTipo.modificado
                                              ? TextDecoration.lineThrough : null),
                                        textAlign: TextAlign.center),
                                    ),
                                    Container(
                                      width: wCurr,
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 5),
                                      child: Text(r.cantActual,
                                        style: TextStyle(fontSize: 12,
                                            fontWeight: FontWeight.bold, color: qtyFg),
                                        textAlign: TextAlign.center),
                                    ),
                                  ]),
                                );
                              },
                            ),
                          ),
                        )),
                      ]),
                    ),
      actions: [
        Button(
          child: const Text('Cancelar'),
          onPressed: () => Navigator.pop(context),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Text('Esta acción es irreversible.',
              style: TextStyle(fontSize: 11,
                  color: Colors.orange.withOpacity(0.9))),
        ),
        FilledButton(
          style: ButtonStyle(backgroundColor: WidgetStateProperty.all(clrGreen)),
          onPressed: widget.onConfirm,
          child: const Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(FluentIcons.check_mark, size: 13, color: Colors.white),
            SizedBox(width: 6),
            Text('Confirmar y Aprobar Revisión',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ]),
        ),
      ],
    );
  }
}

// ─── Modelos ──────────────────────────────────────────────────────────────────
enum _DiffTipo { eliminado, modificado, agregado }

class _DiffRow {
  final _DiffTipo tipo;
  final String    codigo;
  final String    descripcion;
  final String    cantAnterior;
  final String    cantActual;

  const _DiffRow({
    required this.tipo,
    required this.codigo,
    required this.descripcion,
    required this.cantAnterior,
    required this.cantActual,
  });
}
"""

last_non_empty = max(i for i, l in enumerate(lines) if l.strip())
lines[last_non_empty+1:] = []  # eliminar trailing blanks
lines.append("")  # final newline
lines.extend(DIFF_WIDGET.split("\n"))
print("  [OK] _DiffAuditorDialog + modelos appended")

# ─────────────────────────────────────────────────────────────────────────────
# WRITE
# ─────────────────────────────────────────────────────────────────────────────
result = "\n".join(lines)
TARGET.write_text(result, encoding="utf-8", newline="\n")
final_lines = result.count("\n")
print(f"\n✅ Archivo escrito: {final_lines} lineas")
