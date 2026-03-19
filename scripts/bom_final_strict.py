#!/usr/bin/env python3
import sys
from pathlib import Path

# 1. FIX SERVER.PY (eliminar_revision)
SERVER = Path("backend/server.py")
server_raw = SERVER.read_bytes().decode("utf-8").replace("\r\n", "\n").replace("\r", "\n")

old_eliminar = """        ESTADOS_EDITABLES = {"Borrador", "PENDIENTE"}
        if estado not in ESTADOS_EDITABLES:
            if not payload.admin_override:
                raise HTTPException(
                    status_code=403,
                    detail=(
                        f"La Revisión {numero_revision} está en estado '{estado}' "
                        f"y es un registro histórico. Para eliminarla se requiere "
                        f"contraseña de administrador."
                    )
                )
            if payload.password != ADMIN_PASSWORD_INGENIERIA:
                raise HTTPException(
                    status_code=401,
                    detail="Contraseña de administrador incorrecta. Operación denegada."
                )"""

new_eliminar = """        ESTADOS_EDITABLES = {"Borrador", "PENDIENTE"}
        if estado not in ESTADOS_EDITABLES:
            if payload.password != "ADMIN_ING_2024":
                raise HTTPException(
                    status_code=401,
                    detail="Clave incorrecta. Operación denegada."
                )"""
server_raw = server_raw.replace(old_eliminar, new_eliminar)

# 2. Branching ESPECIFICO (We already have UPDATE Tbl_Clientes_Configuracion around 2305)
# So server.py doesn't need more for Step 2 if my previous edit has it. Let's make sure:
has_update = "UPDATE Tbl_Clientes_Configuracion SET ID_Version =" in server_raw
if not has_update:
    print("Warning: branch update not found")

SERVER.write_text(server_raw, "utf-8")


# 3. FIX BOM_MANAGER.DART (Vista Plana column JSON mapping)
BOM = Path("lib/screens/bom_manager.dart")
bom_raw = BOM.read_bytes().decode("utf-8").replace("\r\n", "\n").replace("\r", "\n")

old_row = """                              dataCell(row['largo']?.toString() ?? '', wMedida, isNumber: true),
                              dataCell(row['ancho']?.toString() ?? '', wMedida, isNumber: true),
                              dataCell(row['espesor']?.toString() ?? '', wMedida, isNumber: true),"""
new_row = """                              dataCell(row['largo_cad']?.toString() ?? '', wMedida, isNumber: true),
                              dataCell(row['ancho_cad']?.toString() ?? '', wMedida, isNumber: true),
                              dataCell(row['espesor_cad']?.toString() ?? '', wMedida, isNumber: true),"""
bom_raw = bom_raw.replace(old_row, new_row)

old_padre = "final padre = row['nom_ensamble']?.toString() ?? \"PIEZA\";"
new_padre = "final padre = row['nombre_ensamble']?.toString() ?? \"PIEZA\";"
bom_raw = bom_raw.replace(old_padre, new_padre)

old_sim = "dataCell(row['simetria']?.toString() ?? '', wSimetria, tooltip: true),"
new_sim = "dataCell(row['tiene_dxf']?.toString() ?? '', wSimetria, tooltip: true),"
bom_raw = bom_raw.replace(old_sim, new_sim)

# Ensure header match
bom_raw = bom_raw.replace('headerCell("Simetría", wSimetria),', 'headerCell("Tiene DXF", wSimetria),')

BOM.write_text(bom_raw, "utf-8")
print("✅ Files patched according to user request.")
