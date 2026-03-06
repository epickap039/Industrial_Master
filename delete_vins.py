import pyodbc
import os
import sys

sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), 'backend')))

from backend.server import get_db_connection

try:
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute("UPDATE Tbl_Unidades_Fisicas SET ID_VIN_Asociado = NULL WHERE ID_VIN_Asociado IN (SELECT ID_Unidad FROM Tbl_Unidades_Fisicas WHERE Serie IN ('2223', '2222', '2234'))")
    cursor.execute("DELETE FROM Tbl_Unidades_Fisicas WHERE Serie IN ('2223', '2222', '2234')")
    conn.commit()
    print("VINs borrados exitosamente.")
except Exception as e:
    print(f"Error borrando VINs: {e}")
finally:
    if 'conn' in locals():
        conn.close()
