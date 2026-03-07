import pyodbc
import hashlib

DB_SERVER = '192.168.1.73'
DB_PORT = 1433
DB_DATABASE = 'DB_Materiales_Industrial'
try:
    available_drivers = [d for d in pyodbc.drivers() if 'SQL Server' in d]
    if available_drivers:
        # Intenta elegir el de mayor versión (ej. ODBC Driver 18)
        best_driver = max(available_drivers, key=lambda d: ''.join([c for c in d if c.isdigit()]) or '0')
        DB_DRIVER = f'{{{best_driver}}}'
    else:
        DB_DRIVER = '{ODBC Driver 17 for SQL Server}'
except:
    DB_DRIVER = '{ODBC Driver 17 for SQL Server}'

CONNECTION_STRING = (
    f'DRIVER={DB_DRIVER};'
    f'SERVER={DB_SERVER},{DB_PORT};'
    f'DATABASE={DB_DATABASE};'
    'Trusted_Connection=yes;'
    'TrustServerCertificate=yes;'
)

conn = pyodbc.connect(CONNECTION_STRING)
cursor = conn.cursor()

username = "GA_Calidad"
pwd_hash = hashlib.sha256('ingenieriaGA_Q'.encode()).hexdigest()
rol = "QA"

try:
    cursor.execute("INSERT INTO Tbl_Usuarios (username, password_hash, rol) VALUES (?, ?, ?)", (username, pwd_hash, rol))
    conn.commit()
    print("User GA_Calidad inserted successfully.")
except Exception as e:
    # Quizás el usuario ya exista, intentamos hacer update
    if "Violation of UNIQUE KEY constraint" in str(e) or "UNIQUE" in str(e):
        cursor.execute("UPDATE Tbl_Usuarios SET password_hash = ?, rol = ? WHERE username = ?", (pwd_hash, rol, username))
        conn.commit()
        print("User GA_Calidad updated successfully.")
    else:
        print(f"Error: {e}")
finally:
    conn.close()
