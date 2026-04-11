# -*- coding: utf-8 -*-
"""
Extrae solo columna C (SKU / codigo) e I (Stock) de la hoja Inventario (Google Sheets).

URL de export CSV (sin login si el libro esta compartido "cualquiera con el enlace"):
  https://docs.google.com/spreadsheets/d/{SHEET_ID}/export?format=csv&gid={GID}

Actualizacion en la app: no hace falta descargar el xlsx a mano. Basta un GET periodico
a esa URL (p. ej. cada 15-60 min o al abrir el modulo) y parsear CSV. Alternativa
robusta: Google Sheets API + cuenta de servicio.

Consulta SQL equivalente (si importas el CSV completo a una tabla staging con columnas
posicionales ColA..ColZ o nombres del header):

  SELECT
      LTRIM(RTRIM(ColC)) AS codigo,
      TRY_CONVERT(INT, LTRIM(RTRIM(ColI))) AS stock
  FROM dbo.Staging_InventarioPT
  WHERE LTRIM(RTRIM(ColC)) NOT IN (N'', N'SKU')
    AND ColA NOT LIKE N'SUCURSAL:%'
    AND ColA NOT LIKE N'ALMAC%';

Uso:
  python scripts/google_sheet_inventario_codigo_stock.py
  python scripts/google_sheet_inventario_codigo_stock.py --json
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import sys
import urllib.request

DEFAULT_SHEET_ID = "1Y2e-JgPqasjqlKu_wTW5vFYHbyWO0ctTQk6QfwioBGc"
DEFAULT_GID = "1451349253"
IDX_SKU = 2   # Columna C
IDX_STOCK = 8  # Columna I


def export_csv_url(sheet_id: str, gid: str) -> str:
    return (
        f"https://docs.google.com/spreadsheets/d/{sheet_id}/export"
        f"?format=csv&gid={gid}"
    )


def fetch_csv(url: str, timeout: int = 60) -> str:
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "IndustrialManager/1.0 (inventario sync)"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode("utf-8", errors="replace")


def parse_codigo_stock(csv_text: str) -> list[tuple[str, str]]:
    """Devuelve [(codigo, stock_raw), ...] omitiendo cabeceras y filas vacias."""
    reader = csv.reader(io.StringIO(csv_text))
    rows = list(reader)
    start = 0
    for i, row in enumerate(rows):
        if len(row) > IDX_SKU and row[IDX_SKU].strip().upper() == "SKU":
            start = i + 1
            break
    out: list[tuple[str, str]] = []
    for row in rows[start:]:
        if len(row) <= max(IDX_SKU, IDX_STOCK):
            continue
        codigo = row[IDX_SKU].strip()
        stock = row[IDX_STOCK].strip()
        if not codigo or codigo.upper() == "SKU":
            continue
        out.append((codigo, stock))
    return out


def main() -> int:
    p = argparse.ArgumentParser(description="SKU + Stock desde Google Sheet CSV")
    p.add_argument("--sheet-id", default=DEFAULT_SHEET_ID)
    p.add_argument("--gid", default=DEFAULT_GID)
    p.add_argument("--json", action="store_true", help="Salida JSON array {codigo,stock}")
    p.add_argument("--file", help="Leer CSV local en vez de URL")
    args = p.parse_args()

    try:
        if args.file:
            with open(args.file, encoding="utf-8", errors="replace") as f:
                text = f.read()
        else:
            text = fetch_csv(export_csv_url(args.sheet_id, args.gid))
    except Exception as e:
        print(f"Error leyendo datos: {e}", file=sys.stderr)
        return 1

    pairs = parse_codigo_stock(text)
    if args.json:
        print(
            json.dumps(
                [{"codigo": c, "stock": s} for c, s in pairs],
                ensure_ascii=False,
                indent=2,
            )
        )
    else:
        print("codigo\tstock")
        for c, s in pairs:
            print(f"{c}\t{s}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
