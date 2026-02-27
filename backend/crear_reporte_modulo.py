import pyodbc

conn = pyodbc.connect('DRIVER={ODBC Driver 17 for SQL Server};SERVER=localhost\\SQLEXPRESS;DATABASE=DB_Materiales_Industrial;Trusted_Connection=yes;', autocommit=True)
cursor = conn.cursor()

try:
    cursor.execute("""
        IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Tbl_Reportes_Beta')
        BEGIN
            CREATE TABLE Tbl_Reportes_Beta (
                ID_Reporte INT IDENTITY(1,1) PRIMARY KEY,
                Usuario NVARCHAR(50),
                Fecha_Hora DATETIME,
                Modulo NVARCHAR(100),
                Descripcion NVARCHAR(MAX),
                Gravedad NVARCHAR(20),
                Estado NVARCHAR(20) DEFAULT 'Abierto'
            );
        END
    """)
    print("Tabla Tbl_Reportes_Beta creada o ya existe en DB_Materiales_Industrial.")
except Exception as e:
    print("Error:", e)
