import pyodbc

conn = pyodbc.connect('DRIVER={ODBC Driver 17 for SQL Server};SERVER=localhost\\SQLEXPRESS;DATABASE=DB_Materiales_Industrial;Trusted_Connection=yes;', autocommit=True)
cursor = conn.cursor()

try:
    cursor.execute("SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'Tbl_Unidades_Fisicas'")
    cols = cursor.fetchall()
    print("Columns in Tbl_Unidades_Fisicas:", [c[0] for c in cols])
except Exception as e:
    print("Error:", e)

try:
    cursor.execute("SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'Tbl_VINs'")
    cols2 = cursor.fetchall()
    print("Columns in Tbl_VINs:", [c[0] for c in cols2])
except Exception as e:
    pass
