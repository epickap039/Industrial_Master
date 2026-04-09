#!/usr/bin/env python3
"""
Script para ejecutar el migration SQL que agrega la columna Minutos_Estimados
a la tabla Tbl_Gestor_Tareas si no existe.
"""

import pyodbc
import sys

def main():
    try:
        # Detectar driver disponible
        available_drivers = [d for d in pyodbc.drivers() if 'SQL Server' in d]
        if not available_drivers:
            print("ERROR: No se encontró ODBC Driver para SQL Server")
            sys.exit(1)

        driver = available_drivers[0]
        print(f"Usando driver: {driver}")

        # Conectar a la base de datos
        conn = pyodbc.connect(
            f'Driver={driver};'
            f'Server=192.168.1.73;'
            f'Database=DB_Materiales_Industrial;'
            f'Trusted_Connection=yes;'
        )

        print("✓ Conexión establecida a DB_Materiales_Industrial")
        cursor = conn.cursor()

        # Leer el script SQL
        with open('./sql/add_minutos_estimados.sql', 'r', encoding='utf-8') as f:
            sql_script = f.read()

        print("\n>>> Ejecutando script SQL...")
        print("-" * 60)

        # Ejecutar el script (dividido por GO si es necesario)
        statements = sql_script.split('GO')
        for i, statement in enumerate(statements):
            statement = statement.strip()
            if statement and not statement.startswith('--'):
                try:
                    cursor.execute(statement)
                    print(f"Statement {i+1}: OK")
                except Exception as e:
                    print(f"Statement {i+1}: ERROR - {e}")

        conn.commit()
        print("-" * 60)
        print("\n✓ Script ejecutado exitosamente")

        # Verificar que la columna existe ahora
        cursor.execute("""
            SELECT COUNT(*) as col_count
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_NAME = 'Tbl_Gestor_Tareas'
              AND COLUMN_NAME = 'Minutos_Estimados'
        """)

        result = cursor.fetchone()
        if result[0] > 0:
            print("✓ Verificación: Columna Minutos_Estimados existe en Tbl_Gestor_Tareas")
        else:
            print("⚠ Advertencia: Columna Minutos_Estimados NO se encontró después de migration")

        cursor.close()
        conn.close()

    except Exception as e:
        print(f"ERROR: {e}")
        sys.exit(1)

if __name__ == '__main__':
    main()
