#!/usr/bin/env python3
import sys
from pathlib import Path

TARGET = Path("backend/server.py")
raw = TARGET.read_bytes().decode("utf-8").replace("\r\n", "\n").replace("\r", "\n")

# Inject logging to Tbl_Log_Cambios_Ingenieria when branching ESPECIFICO
old_branching = """            # Crear Revisión 0 en la nueva versión
            cursor.execute(
                "INSERT INTO Tbl_BOM_Revisiones (ID_Version, Numero_Revision, Estado) "
                "OUTPUT INSERTED.ID_Revision VALUES (?, 0, 'Borrador')",
                (id_version_nueva,),
            )
            nuevo_id_revision = cursor.fetchone()[0]"""

new_branching = """            # Crear Revisión 0 en la nueva versión
            cursor.execute(
                "INSERT INTO Tbl_BOM_Revisiones (ID_Version, Numero_Revision, Estado) "
                "OUTPUT INSERTED.ID_Revision VALUES (?, 0, 'Borrador')",
                (id_version_nueva,),
            )
            nuevo_id_revision = cursor.fetchone()[0]

            # Historial Global: Registrar derivación V1 -> V2
            cursor.execute(
                "INSERT INTO Tbl_Log_Cambios_Ingenieria (ID_Revision, Accion, Detalle_Cambio, Motivo) "
                "VALUES (?, ?, ?, ?)",
                (nuevo_id_revision, 'DERIVACION', f"Creada {nombre_fork} desde V1 original con {len(payload.lista_clientes)} clientes.", 'Cambio Específico de Clientes')
            )"""

raw = raw.replace(old_branching, new_branching)
TARGET.write_text(raw, "utf-8")
print("✅ server.py histórico agregado!")
