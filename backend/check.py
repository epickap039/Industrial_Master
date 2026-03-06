import pyodbc
conn=pyodbc.connect('Driver={ODBC Driver 17 for SQL Server};Server=192.168.1.73;Database=DB_Materiales_Industrial;Trusted_Connection=yes;')
cursor=conn.cursor()
cursor.execute('SELECT TABLE_NAME, COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS')
print([(r.TABLE_NAME, r.COLUMN_NAME) for r in cursor.fetchall() if 'Cliente' in r.COLUMN_NAME])
