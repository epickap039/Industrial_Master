import pyodbc
from datetime import datetime

# CONFIGURACIÓN FINAL (Validada y Corregida)
DB_SERVER = '192.168.1.73'
DB_PORT = 1433
DB_DATABASE = 'DB_Materiales_Industrial'
DB_DRIVER = '{ODBC Driver 17 for SQL Server}'
TARGET_TABLE = 'Tbl_Maestro_Piezas'

CONNECTION_STRING = (
    f'DRIVER={DB_DRIVER};'
    f'SERVER={DB_SERVER},{DB_PORT};'
    f'DATABASE={DB_DATABASE};'
    'Trusted_Connection=yes;'
    'TrustServerCertificate=yes;'
)

def final_test():
    print(f"[{datetime.now()}] � VALIDACIÓN FINAL DE CONEXIÓN...")
    print(f"   Server: {DB_SERVER}")
    print(f"   Database: {DB_DATABASE}")
    print(f"   Table: {TARGET_TABLE}")
    print(f"   Auth: Windows Trusted")

    try:
        conn = pyodbc.connect(CONNECTION_STRING, timeout=5)
        cursor = conn.cursor()
        
        # Prueba real de datos
        cursor.execute(f"SELECT TOP 1 * FROM {TARGET_TABLE}")
        columns = [column[0] for column in cursor.description]
        row = cursor.fetchone()
        
        if row:
            print(f"\n✅ CONEXIÓN Y DATOS EXITOSOS.")
            print(f"   Columnas detectadas: {columns}")
            print(f"   Primer dato: {row[0]}")
        else:
            print("\n⚠️ CONEXIÓN OK, PERO TABLA VACÍA.")
            
        conn.close()
        return True

    except Exception as e:
        print(f"\n❌ ERROR CRÍTICO FINAL: {e}")
        return False

if __name__ == "__main__":
    final_test()
