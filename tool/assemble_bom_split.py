"""Divide bom_manager: part file con mixin de lógica + pantalla principal con UI.

Re-ejecutar solo si se restaura bom_manager desde .bak_split y se quiere regenerar.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
src_path = ROOT / "lib/screens/bom_manager.dart.bak_split"
if not src_path.exists():
    src_path = ROOT / "lib/screens/bom_manager.dart"
lines = src_path.read_text(encoding="utf-8").splitlines()

def chunk(a1: int, b1: int) -> list[str]:
    """Líneas 1-based [a1, b1] inclusive."""
    return lines[a1 - 1 : b1]


# Mixin: campos + getters; didUpdate; 169-162 clearData.. (saltar 163-167 initState); ..1875; auditoría
mixin_body = []
mixin_body.extend(chunk(40, 86))
mixin_body.extend(chunk(144, 162))  # didUpdateWidget
mixin_body.extend(chunk(169, 1875))  # _clearData .. _showClonarDialog (sin initState duplicado)
mixin_body.extend(chunk(2236, 2504))

part_header = """part of 'package:industrial_manager_v15_5/screens/bom_manager.dart';

/// Lógica de negocio, estado y diálogos de datos del gestor BOM.
/// La construcción principal del árbol, tablas, vista plana y [build] permanecen en la pantalla.
mixin BomManagerControllerMixin on State<BOMManagerScreen> {
"""

part_footer = "}\n"

ctrl = ROOT / "lib/controllers/bom_manager_controller.dart"
ctrl.parent.mkdir(parents=True, exist_ok=True)
ctrl.write_text(part_header + "\n".join(mixin_body) + "\n" + part_footer, encoding="utf-8")

# Main: imports + part antes de const API_URL; widget; State + ECR + initState + UI
main_parts = []
main_parts.extend(lines[0:13])  # líneas 1–13: imports hasta `app_config.dart`
main_parts.append("part '../controllers/bom_manager_controller.dart';")
main_parts.append("")
main_parts.extend(lines[13:38])  # línea 14 en adelante: blank, API_URL, clase widget...
main_parts.append(
    "class _BOMManagerScreenState extends State<BOMManagerScreen> with BomManagerControllerMixin {"
)
main_parts.extend(chunk(88, 141))
main_parts.append("")
main_parts.extend(chunk(164, 167))  # initState con @override añadir manualmente si falta
main_parts.append("")
main_parts.extend(chunk(1876, 2234))
main_parts.append("")
main_parts.extend(lines[2505:])

out = ROOT / "lib/screens/bom_manager.dart"
out.write_text("\n".join(main_parts) + "\n", encoding="utf-8")
print("written", ctrl, "mixin lines", len(mixin_body))
print("written", out, "main lines", len(main_parts))
