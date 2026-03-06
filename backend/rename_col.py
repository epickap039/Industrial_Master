import pyodbc

conn = pyodbc.connect('DRIVER={ODBC Driver 17 for SQL Server};SERVER=localhost\\SQLEXPRESS;DATABASE=DB_Materiales_Industrial;Trusted_Connection=yes;', autocommit=True)
cursor = conn.cursor()

try:
    cursor.execute("sp_rename 'Tbl_Unidades_Fisicas.VIN', 'Serie', 'COLUMN'")
    print("Column renamed successfully.")
except Exception as e:
    print("Error renaming column:", e)
