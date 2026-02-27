import pyodbc

conn = pyodbc.connect('DRIVER={ODBC Driver 17 for SQL Server};SERVER=localhost\\SQLEXPRESS;DATABASE=DB_Materiales_Industrial;Trusted_Connection=yes;', autocommit=True)
cursor = conn.cursor()

try:
    cursor.execute("""
        IF COL_LENGTH('Tbl_Reportes_Beta', 'Captura_Base64') IS NULL
        BEGIN
            ALTER TABLE Tbl_Reportes_Beta ADD Captura_Base64 NVARCHAR(MAX) NULL;
            print('Columna Captura_Base64 agregada.');
        END
        ELSE
        BEGIN
            print('La columna ya existe.');
        END
    """)
    print("Migracion exitosa.")
except Exception as e:
    print("Error:", e)
