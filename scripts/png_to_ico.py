#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Convierte un PNG a ICO (varias resoluciones embebidas) para iconos de
categoria en Ayudas visuales (tinte de tema en la app).

Requisito: pip install pillow

Ejemplo:
  python scripts/png_to_ico.py ruta/soldadura.png -o soldadura.ico
"""
from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image


def main() -> None:
    parser = argparse.ArgumentParser(description="PNG -> ICO (multisize)")
    parser.add_argument("input_png", type=Path, help="Archivo PNG de entrada")
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=None,
        help="Ruta .ico de salida (por defecto: mismo nombre que el PNG)",
    )
    args = parser.parse_args()
    src = args.input_png
    if not src.is_file():
        raise SystemExit(f"No existe el archivo: {src}")
    out = args.output if args.output is not None else src.with_suffix(".ico")

    img = Image.open(src).convert("RGBA")
    sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
    img.save(out, format="ICO", sizes=sizes)
    print(f"OK: {out.resolve()} ({out.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
