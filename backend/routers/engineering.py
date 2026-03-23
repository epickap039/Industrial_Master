"""API router: engineering."""
import ast
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

router = APIRouter()

@router.get("/api/mapa/jerarquia")
def get_mapa_jerarquia():
    """Devuelve el árbol completo: Tracto > Tipo > Versión > Revisiones."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("""
            SELECT
                TR.ID_Tracto, TR.Nombre_Tracto,
                TP.ID_Tipo, TP.Nombre_Tipo,
                V.ID_Version, V.Nombre_Version,
                R.ID_Revision, R.Numero_Revision, R.Estado, R.Fecha_Creacion,
                ISNULL(C.Nombre_Cliente, 'Ingeniería Base (Sin clientes)') AS Nombre_Cliente
            FROM Tbl_Proyectos_Tracto TR
            JOIN Tbl_Tipos_Proyecto TP ON TP.ID_Tracto = TR.ID_Tracto
            JOIN Tbl_Versiones_Ingenieria V ON V.ID_Tipo = TP.ID_Tipo
            LEFT JOIN Tbl_BOM_Revisiones R ON R.ID_Version = V.ID_Version AND R.Estado = 'Aprobada'
            LEFT JOIN Tbl_Clientes_Configuracion C ON C.ID_Version = V.ID_Version
            ORDER BY TR.Nombre_Tracto, TP.Nombre_Tipo, V.Nombre_Version, R.Numero_Revision
        """)
        rows = cursor.fetchall()
        # Construir árbol en Python
        tractos: dict = {}
        for r in rows:
            tid = r.ID_Tracto
            if tid not in tractos:
                tractos[tid] = {"id": tid, "nombre": r.Nombre_Tracto, "tipos": {}}
            tipos = tractos[tid]["tipos"]
            pid = r.ID_Tipo
            if pid not in tipos:
                tipos[pid] = {"id": pid, "nombre": r.Nombre_Tipo, "versiones": {}}
            versiones = tipos[pid]["versiones"]
            vid = r.ID_Version
            if vid not in versiones:
                versiones[vid] = {"id": vid, "nombre": r.Nombre_Version, "revisiones": []}
            if r.ID_Revision:
                versiones[vid]["revisiones"].append({
                    "id_revision": r.ID_Revision,
                    "numero_revision": r.Numero_Revision,
                    "estado": r.Estado,
                    "fecha_creacion": r.Fecha_Creacion.isoformat() if r.Fecha_Creacion else None,
                    "cliente": r.Nombre_Cliente
                })
        # Serializar a lista
        result = []
        for tracto in tractos.values():
            t = {"id": tracto["id"], "nombre": tracto["nombre"], "tipos": []}
            for tipo in tracto["tipos"].values():
                tp = {"id": tipo["id"], "nombre": tipo["nombre"], "versiones": []}
                for ver in tipo["versiones"].values():
                    tp["versiones"].append({
                        "id": ver["id"],
                        "nombre": ver["nombre"],
                        "revisiones": ver["revisiones"]
                    })
                t["tipos"].append(tp)
            result.append(t)
        return result
    finally:
        conn.close()

@router.get("/api/bom/where-used/{codigo_pieza}")
def get_where_used(codigo_pieza: str):
    """Búsqueda ascendente (Bottom-Up) para encontrar dónde se usa una pieza."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("""
            SELECT 
                EN.ID_Ensamble,
                EN.Nombre_Ensamble,
                E.Cantidad,
                R.Numero_Revision AS Lista_BOM,
                V.Nombre_Version,
                TP.Nombre_Tipo AS Proyecto,
                TR.Nombre_Tracto AS Tracto,
                ISNULL(C.Nombre_Cliente, 'Ingeniería Base (Sin clientes)') AS Cliente
            FROM Tbl_BOM_Estructura E
            JOIN Tbl_Ensambles EN ON E.ID_Ensamble = EN.ID_Ensamble
            JOIN Tbl_Estaciones ES ON EN.ID_Estacion = ES.ID_Estacion
            JOIN Tbl_BOM_Revisiones R ON ES.ID_Revision = R.ID_Revision
            JOIN Tbl_Versiones_Ingenieria V ON R.ID_Version = V.ID_Version
            JOIN Tbl_Tipos_Proyecto TP ON V.ID_Tipo = TP.ID_Tipo
            JOIN Tbl_Proyectos_Tracto TR ON TP.ID_Tracto = TR.ID_Tracto
            LEFT JOIN Tbl_Clientes_Configuracion C ON V.ID_Version = C.ID_Version
            WHERE E.Codigo_Pieza = ?
        """, (codigo_pieza.upper(),))
        rows = cursor.fetchall()
        
        result = []
        for r in rows:
            result.append({
                "id_ensamble": r.ID_Ensamble,
                "nombre_ensamble": r.Nombre_Ensamble,
                "cantidad": float(r.Cantidad),
                "lista_bom": f"Rev {r.Lista_BOM}",
                "version": r.Nombre_Version,
                "proyecto": r.Proyecto,
                "tracto": r.Tracto,
                "cliente": r.Cliente
            })
        return result
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

# === MRP / ESTADO DE CUENTA DE MATERIALES ===

