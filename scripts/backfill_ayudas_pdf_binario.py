#!/usr/bin/env python3
"""
Rellena Pdf_Binario en Tbl_Ayudas_Revisiones leyendo cada Ruta_PDF del disco.

Uso (desde la raíz del repo, con backend en PYTHONPATH vía insert):
  python scripts/backfill_ayudas_pdf_binario.py --dry-run
  python scripts/backfill_ayudas_pdf_binario.py
  python scripts/backfill_ayudas_pdf_binario.py --limit 50

Requiere columna Pdf_Binario (la crea el servidor al subir una revisión o ejecuta
backend/sql/add_ayudas_revision_pdf_binario.sql).
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

BACKEND = Path(__file__).resolve().parent.parent / "backend"
if str(BACKEND) not in sys.path:
    sys.path.insert(0, str(BACKEND))

from database import get_db_connection  # noqa: E402


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--dry-run", action="store_true", help="No escribe en BD")
    p.add_argument("--limit", type=int, default=0, help="Máximo de filas (0 = sin límite)")
    args = p.parse_args()

    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute(
        """
        SELECT 1
        FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.Tbl_Ayudas_Revisiones') AND name = 'Pdf_Binario'
        """
    )
    if cur.fetchone() is None:
        print(
            "Falta columna Pdf_Binario. Ejecuta backend/sql/add_ayudas_revision_pdf_binario.sql "
            "o sube una revisión desde la app (el API crea la columna automáticamente)."
        )
        conn.close()
        return 1

    cur.execute(
        """
        SELECT Id_Revision, Ruta_PDF
        FROM dbo.Tbl_Ayudas_Revisiones
        WHERE (Pdf_Binario IS NULL OR DATALENGTH(Pdf_Binario) = 0)
          AND Ruta_PDF IS NOT NULL AND LTRIM(RTRIM(Ruta_PDF)) <> ''
        ORDER BY Id_Revision
        """
    )
    rows = cur.fetchall()
    if args.limit and args.limit > 0:
        rows = rows[: args.limit]

    updated = 0
    skipped = 0
    for r in rows:
        id_rev = int(r[0])
        path = str(r[1] or "").strip()
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError:
            print(f"[omitir] id={id_rev} no lee disco: {path}")
            skipped += 1
            continue
        if not data:
            print(f"[omitir] id={id_rev} archivo vacío: {path}")
            skipped += 1
            continue
        if args.dry_run:
            print(f"[dry-run] id={id_rev} bytes={len(data)} {path}")
            updated += 1
            continue
        cur.execute(
            "UPDATE dbo.Tbl_Ayudas_Revisiones SET Pdf_Binario = ? WHERE Id_Revision = ?",
            (data, id_rev),
        )
        updated += 1
        if updated % 20 == 0:
            conn.commit()
            print(f"… {updated} actualizadas")
    if not args.dry_run:
        conn.commit()
    print(f"Listo: procesadas={updated} omitidas={skipped} dry_run={args.dry_run}")
    conn.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
