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

conn = pyodbc.connect(CONNECTION_STRING, timeout=5)
cursor = conn.cursor()
cursor.execute("SELECT TABLE_NAME, COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS")
cols = [(r.TABLE_NAME, r.COLUMN_NAME) for r in cursor.fetchall()]
for t, c in cols:
    print(f"{t} -> {c}")
