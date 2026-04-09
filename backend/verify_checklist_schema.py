#!/usr/bin/env python3
"""
Script para verificar la estructura de Tbl_Gestor_Checklist
"""

import pyodbc
import sys

def main():
    try:
        available_drivers = [d for d in pyodbc.drivers() if 'SQL Server' in d]
        if not available_drivers:
            print("ERROR: No se encontró ODBC Driver para SQL Server")
            sys.exit(1)

        driver = available_drivers[0]
        conn = pyodbc.connect(
            f'Driver={driver};'
            f'Server=192.168.1.73;'
            f'Database=DB_Materiales_Industrial;'
            f'Trusted_Connection=yes;'
        )

        cursor = conn.cursor()

        # Buscar tabla Tbl_Gestor_Checklist
        cursor.execute("""
            SELECT TABLE_NAME
            FROM INFORMATION_SCHEMA.TABLES
            WHERE TABLE_NAME LIKE '%Gestor%Check%'
        """)

        tables = cursor.fetchall()
        if tables:
            print(f">>> Columnas en Tbl_Gestor_Checklist:")
            cursor.execute("""
                SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE
                FROM INFORMATION_SCHEMA.COLUMNS
                WHERE TABLE_NAME = ?
                ORDER BY ORDINAL_POSITION
            """, (tables[0][0],))

            columns = cursor.fetchall()
            print(f"Total columnas: {len(columns)}\n")

            for col_name, col_type, nullable in columns:
                null_marker = "NULL" if nullable == "YES" else "NOT NULL"
                print(f"  {col_name:40s} {col_type:20s} {null_marker}")
        else:
            print("No se encontró Tbl_Gestor_Checklist")

        cursor.close()
        conn.close()

    except Exception as e:
        print(f"ERROR: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)

if __name__ == '__main__':
    main()
