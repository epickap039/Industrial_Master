"""Genera routers/*.py a partir de un server monolítico (ejecutar desde carpeta backend).

Tras la Fase 3, `server.py` es solo arranque. Para volver a generar routers, copia aquí
el monolito histórico como `server_monolith_for_split.py` y descomenta la línea SOURCE abajo.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "server_monolith_for_split.py"
if not SOURCE.exists():
    SOURCE = ROOT / "server.py"
LINES = SOURCE.read_text(encoding="utf-8").splitlines(keepends=True)
if len(LINES) < 2000:
    raise SystemExit(
        "generate_routers: el archivo fuente es demasiado corto (¿ya modularizado?). "
        "Usa una copia del server monolítico como server_monolith_for_split.py"
    )


def sl(a: int, b: int) -> str:
    return "".join(LINES[a - 1 : b])


STD = """import ast
import io
import json
import math
import os
import re
import shutil
import socket
import subprocess
import sys
import traceback
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

import openpyxl
import pandas as pd
import pyodbc
from fastapi import APIRouter, BackgroundTasks, File, Form, Header, HTTPException, Request, Response, UploadFile
from fastapi.responses import StreamingResponse
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side

from database import get_db_connection, _int_from_count_row
from models import *
"""

STD_ROOT = STD.replace("from models import *\n", "")

out = ROOT / "routers"
out.mkdir(exist_ok=True)


def write_router(name: str, body: str, std: str = STD, extra_pre_router: str = ""):
    body = body.replace("@app.", "@router.")
    text = (
        f'"""API router: {name}."""\n'
        + std
        + extra_pre_router
        + "\nrouter = APIRouter()\n\n"
        + body
    )
    (out / f"{name}.py").write_text(text, encoding="utf-8")


# 1 root
write_router("root", sl(109, 221), std=STD_ROOT)

# 2 config + regla espejo
cfg = sl(222, 295)
mirror = sl(3603, 3612).replace("@app.", "@router.")
mirror = mirror.replace("global REGLA_ESPEJO_ACTIVA\n    ", "")
mirror = mirror.replace("REGLA_ESPEJO_ACTIVA", "state.REGLA_ESPEJO_ACTIVA")
cfg = cfg.replace("@app.", "@router.")
write_router(
    "config_api",
    cfg + mirror,
    extra_pre_router="import state\n",
)

# 3 proyectos
write_router("proyectos", sl(377, 565))

# 4 engineering (mapa + where-used)
write_router("engineering", sl(568, 676))

# 5 mrp
write_router("mrp", sl(677, 881))

# 6 analytics
write_router("analytics", sl(882, 1086))

# 7 vins (archivos + bloque búsqueda/ADN; sin solapar con BOM 1163–1822)
vins = sl(1087, 1150) + sl(1824, 2155)
vins = vins.replace("@app.", "@router.")
write_router(
    "vins",
    vins,
    extra_pre_router="from bom_audit_log import registrar_log\n",
)

# 8 bom (1163–1822 gestión BOM/VIN en revisión; 2157+ resto; sin modelos duplicados 2896–2946)
bom_body = sl(1163, 1822) + sl(2157, 2894) + sl(2947, 3597)
write_router(
    "bom",
    bom_body,
    extra_pre_router="from bom_audit_log import registrar_log\n",
)

# 9 auth
auth_body = sl(3666, 3687).replace("@app.", "@router.")
(out / "auth.py").write_text(
    '"""API router: login."""\n'
    + "from fastapi import APIRouter, HTTPException\n\n"
    + "from auth_service import hash_password\n"
    + "from database import get_db_connection\n"
    + "from models import LoginRequest\n\n"
    + "router = APIRouter()\n\n"
    + auth_body,
    encoding="utf-8",
)

# 10 catalog
write_router(
    "catalog",
    sl(3889, 4067),
    extra_pre_router="from audit_service import registrar_auditoria\n",
)

# 11 excel (sin clase SincronizacionItem duplicada: está en models)
excel_body = sl(4068, 4229) + sl(4247, 4761)
write_router(
    "excel",
    excel_body,
    extra_pre_router="from audit_service import registrar_auditoria\n",
)

# 12 historial
write_router("historial", sl(4762, 4835))

# 13 limpieza (sin MasivoUpdate duplicado en models)
limpieza_body = sl(4839, 4858) + sl(4865, 4916)
write_router(
    "limpieza",
    limpieza_body,
    extra_pre_router="from audit_service import registrar_auditoria\n",
)

# 14 qa
write_router("qa", sl(4918, 5051))

# 15 cad (sin modelo duplicado ScanCADPayload)
cad_head = sl(5053, 5062)
cad_tail = sl(5067, 5813)
cad_body = (cad_head + cad_tail).replace("@app.", "@router.")
(out / "cad.py").write_text(
    '"""API router: escáner CAD."""\n'
    + STD
    + "\nrouter = APIRouter()\n\n"
    + cad_body,
    encoding="utf-8",
)

(out / "__init__.py").write_text(
    '"""Routers FastAPI (Industrial Manager)."""\n'
    "from . import analytics\n"
    "from . import auth\n"
    "from . import bom\n"
    "from . import cad\n"
    "from . import catalog\n"
    "from . import config_api\n"
    "from . import engineering\n"
    "from . import excel\n"
    "from . import historial\n"
    "from . import limpieza\n"
    "from . import mrp\n"
    "from . import proyectos\n"
    "from . import qa\n"
    "from . import root\n"
    "from . import vins\n"
    "\n"
    "__all__ = [\n"
    "    'analytics',\n"
    "    'auth',\n"
    "    'bom',\n"
    "    'cad',\n"
    "    'catalog',\n"
    "    'config_api',\n"
    "    'engineering',\n"
    "    'excel',\n"
    "    'historial',\n"
    "    'limpieza',\n"
    "    'mrp',\n"
    "    'proyectos',\n"
    "    'qa',\n"
    "    'root',\n"
    "    'vins',\n"
    "]\n",
    encoding="utf-8",
)

print("routers generated OK")
