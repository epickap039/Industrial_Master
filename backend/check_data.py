import pyodbc

DB_SERVER = '192.168.1.73'
DB_PORT = 1433
DB_DATABASE = 'DB_Materiales_Industrial'
DB_DRIVER = '{ODBC Driver 17 for SQL Server}'
CONNECTION_STRING = (
    f'DRIVER={DB_DRIVER};'
    f'SERVER={DB_SERVER},{DB_PORT};'
    f'DATABASE={DB_DATABASE};'
    'Trusted_Connection=yes;'
    'TrustServerCertificate=yes;'
)

try:
    conn = pyodbc.connect(CONNECTION_STRING, timeout=5)
    cursor = conn.cursor()
    cursor.execute("SELECT TOP 5 * FROM Tbl_Clientes_Configuracion")
    print([col[0] for col in cursor.description])
    for row in cursor.fetchall():
        print(row)
except Exception as e:
    print(e)
