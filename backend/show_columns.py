#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Script para verificar la estructura de la tabla Tbl_Gestor_Tareas - versión sin Unicode
"""

import pyodbc
import sys

def main():
    try:
        available_drivers = [d for d in pyodbc.drivers() if 'SQL Server' in d]
        if not available_drivers:
            print("ERROR: No se encontro ODBC Driver para SQL Server")
            sys.exit(1)

        driver = available_drivers[0]
        print("Usando driver: " + driver)

        conn = pyodbc.connect(
            'Driver=' + driver + ';'
            'Server=192.168.1.73;'
            'Database=DB_Materiales_Industrial;'
            'Trusted_Connection=yes;'
        )

        print("OK: Conexion establecida\n")
        cursor = conn.cursor()

        # Buscar tabla Tbl_Gestor_Tareas
        cursor.execute("""
            SELECT TABLE_NAME
            FROM INFORMATION_SCHEMA.TABLES
            WHERE TABLE_NAME LIKE '%Gestor%Tarea%'
        """)

        tables = cursor.fetchall()
        if tables:
            print("Tablas encontradas: " + str(len(tables)))
            for table in tables:
                print("  - " + table[0])
        else:
            print("No se encontro Tbl_Gestor_Tareas")

        # Si encontramos la tabla, mostrar sus columnas
        if tables:
            print("\nColumnas en la tabla principal:")
            cursor.execute("""
                SELECT COLUMN_NAME, DATA_TYPE, IS_NULLABLE
                FROM INFORMATION_SCHEMA.COLUMNS
                WHERE TABLE_NAME = ?
                ORDER BY ORDINAL_POSITION
            """, (tables[0][0],))

            columns = cursor.fetchall()
            print("Total columnas: " + str(len(columns)) + "\n")

            for col_name, col_type, nullable in columns:
                null_marker = "NULL" if nullable == "YES" else "NOT NULL"
                print("  " + col_name.ljust(40) + col_type.ljust(20) + null_marker)

        cursor.close()
        conn.close()

    except Exception as e:
        print("ERROR: " + str(e))
        sys.exit(1)

if __name__ == '__main__':
    main()
