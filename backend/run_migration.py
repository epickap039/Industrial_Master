#!/usr/bin/env python3
"""
Ejecuta un script SQL de migración (p. ej. add_minutos_estimados.sql) contra la base configurada.

Usa la misma cadena de conexión que el API (variables DB_SERVER, DB_PORT, DB_DATABASE, etc.).
Ejecutar desde la carpeta backend:

  python run_migration.py sql/add_minutos_estimados.sql
"""

from __future__ import annotations

import sys

import pyodbc

from database import CONNECTION_STRING


def main() -> None:
    if len(sys.argv) < 2:
        print("Uso: python run_migration.py <ruta_al_sql>")
        sys.exit(1)
    sql_path = sys.argv[1]
    try:
        with open(sql_path, "r", encoding="utf-8") as f:
            sql_script = f.read()
    except OSError as e:
        print(f"ERROR: no se pudo leer {sql_path}: {e}")
        sys.exit(1)

    print("Conectando a SQL Server (CONNECTION_STRING de database.py)...")
    try:
        conn = pyodbc.connect(CONNECTION_STRING)
    except Exception as e:
        print(f"ERROR de conexión: {e}")
        sys.exit(1)
    cursor = conn.cursor()

    print("\n>>> Ejecutando script SQL...")
    print("-" * 60)
    statements = sql_script.split("GO")
    for i, statement in enumerate(statements):
        statement = statement.strip()
        if statement and not statement.startswith("--"):
            try:
                cursor.execute(statement)
                print(f"Statement {i + 1}: OK")
            except Exception as e:
                print(f"Statement {i + 1}: ERROR - {e}")

    conn.commit()
    print("-" * 60)
    print("\nScript procesado (revise errores arriba si los hubo).")
    cursor.close()
    conn.close()


if __name__ == "__main__":
    main()
