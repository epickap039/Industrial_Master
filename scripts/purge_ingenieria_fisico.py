#!/usr/bin/env python3
"""
Purga FÍSICA de la estructura de ingeniería (BOM / versiones / tipos).

NO modifica:
  - Tbl_Proyectos_Tracto (tractos del lobby)
  - Tbl_Maestro_Piezas (catálogo maestro)

Sí vacía (orden respetando FKs):
  - Tbl_Log_Cambios_Ingenieria (si existe; errores ignorados)
  - Tbl_BOM_Estructura → Tbl_Ensambles → Tbl_Estaciones
  - Tbl_Unidades_Fisicas (VINs ligados a revisiones)
  - Tbl_BOM_Revisiones
  - Tbl_Clientes_Configuracion (asignaciones a versiones)
  - Tbl_Versiones_Ingenieria
  - Tbl_Tipos_Proyecto

Nota: En este proyecto las piezas BOM están en Tbl_BOM_Estructura (no existe Tbl_BOM_Items).

Uso (desde la raíz del repo):
  python scripts/purge_ingenieria_fisico.py --yes

Sin --yes solo muestra conteos y sale.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

BACKEND = Path(__file__).resolve().parent.parent / "backend"
if str(BACKEND) not in sys.path:
    sys.path.insert(0, str(BACKEND))


def main() -> int:
    parser = argparse.ArgumentParser(description="Purge engineering tables (physical DELETE).")
    parser.add_argument(
        "--yes",
        action="store_true",
        help="Confirmar ejecución destructiva.",
    )
    args = parser.parse_args()

    # Import tras ajustar path (usa CONNECTION_STRING de server.py)
    import pyodbc
    from server import CONNECTION_STRING, _purge_tipo_physical

    conn = pyodbc.connect(CONNECTION_STRING)
    cursor = conn.cursor()

    def count(table: str) -> int:
        cursor.execute(f"SELECT COUNT(*) AS c FROM {table}")
        return int(cursor.fetchone()[0])

    print("Conteos ANTES:")
    for t in (
        "Tbl_BOM_Estructura",
        "Tbl_BOM_Revisiones",
        "Tbl_Versiones_Ingenieria",
        "Tbl_Tipos_Proyecto",
    ):
        try:
            print(f"  {t}: {count(t)}")
        except pyodbc.Error as e:
            print(f"  {t}: (error) {e}")

    if not args.yes:
        print("\nNo se ejecutó ningún DELETE. Pasa --yes para purgar.")
        conn.close()
        return 0

    try:
        try:
            cursor.execute("DELETE FROM Tbl_Log_Cambios_Ingenieria")
        except pyodbc.Error:
            pass

        cursor.execute("SELECT ID_Tipo FROM Tbl_Tipos_Proyecto ORDER BY ID_Tipo")
        tipo_ids = [int(r[0]) for r in cursor.fetchall()]
        for tid in tipo_ids:
            _purge_tipo_physical(cursor, tid)

        conn.commit()
    except Exception as e:
        conn.rollback()
        print(f"ERROR: {e}")
        conn.close()
        return 1

    print("\nConteos DESPUÉS:")
    for t in (
        "Tbl_BOM_Estructura",
        "Tbl_BOM_Revisiones",
        "Tbl_Versiones_Ingenieria",
        "Tbl_Tipos_Proyecto",
    ):
        try:
            print(f"  {t}: {count(t)}")
        except pyodbc.Error as e:
            print(f"  {t}: (error) {e}")

    v = count("Tbl_Versiones_Ingenieria")
    print(f"\nVerificación: Tbl_Versiones_Ingenieria = {v} registros (objetivo 0).")
    conn.close()
    return 0 if v == 0 else 2


if __name__ == "__main__":
    raise SystemExit(main())
