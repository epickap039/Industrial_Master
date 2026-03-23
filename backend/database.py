"""Conexión SQL Server (extraída de server.py)."""
import pyodbc
from fastapi import HTTPException

DB_SERVER = "192.168.1.73"
DB_PORT = 1433
DB_DATABASE = "DB_Materiales_Industrial"

try:
    available_drivers = [d for d in pyodbc.drivers() if "SQL Server" in d]
    if available_drivers:
        best_driver = available_drivers[-1]
        DB_DRIVER = f"{{{best_driver}}}"
        print(f"SQL DRIVER SELECCIONADO: {DB_DRIVER}")
    else:
        DB_DRIVER = "{ODBC Driver 17 for SQL Server}"
        print("AVISO: No se detectaron drivers SQL. Usando default 17.")
except Exception as e:
    DB_DRIVER = "{ODBC Driver 17 for SQL Server}"
    print(f"Error detectando drivers: {e}")

CONNECTION_STRING = (
    f"DRIVER={DB_DRIVER};"
    f"SERVER={DB_SERVER},{DB_PORT};"
    f"DATABASE={DB_DATABASE};"
    "Trusted_Connection=yes;"
    "TrustServerCertificate=yes;"
)


def _int_from_count_row(row) -> int:
    """Lee COUNT(*) de pyodbc con alias Total (nombre o índice 0). Evita fallos por Row vs tuple."""
    if row is None:
        return 0
    try:
        v = getattr(row, "Total", None)
        if v is not None:
            return int(v)
    except (TypeError, ValueError):
        pass
    try:
        return int(row[0]) if row[0] is not None else 0
    except (IndexError, TypeError, ValueError):
        return 0


def get_db_connection():
    try:
        conn = pyodbc.connect(CONNECTION_STRING)
        return conn
    except Exception as e:
        print(f"Error de conexión SQL: {e}")
        raise HTTPException(status_code=500, detail=f"Database Connection Error: {str(e)}")
