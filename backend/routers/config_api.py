"""API router: config_api."""
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
import state

router = APIRouter()

@router.get("/api/config/materiales")
def get_materiales():
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT Material FROM Tbl_Materiales_Aprobados ORDER BY Material")
    rows = cursor.fetchall()
    conn.close()
    return [row[0] for row in rows]

@router.post("/api/config/materiales")
def add_material(payload: MaterialPayload):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("INSERT INTO Tbl_Materiales_Aprobados (Material) VALUES (?)", (payload.material.upper(),))
        conn.commit()
        return {"mensaje": "Material agregado correctamente"}
    except pyodbc.IntegrityError:
        raise HTTPException(status_code=400, detail="El material ya existe")
    finally:
        conn.close()

@router.delete("/api/config/materiales/{material_name}")
def delete_material(material_name: str):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("DELETE FROM Tbl_Materiales_Aprobados WHERE Material = ?", (material_name,))
        if cursor.rowcount == 0:
            raise HTTPException(status_code=404, detail="Material no encontrado")
        conn.commit()
        return {"mensaje": "Material eliminado correctamente"}
    finally:
        conn.close()

class MaterialOficial(BaseModel):
    descripcion: str

@router.post("/api/materiales/oficial")
def agregar_material_oficial(payload: MaterialOficial):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute(
            "INSERT INTO Tbl_Materiales_Aprobados (Material) VALUES (?)",
            (payload.descripcion.upper(),)
        )
        conn.commit()
        return {"status": "success", "message": "Material oficial guardado correctamente"}
    except pyodbc.IntegrityError:
        conn.rollback()
        # En caso de que el material ya exista (UNIQUE constraint)
        return {"status": "success", "message": "Material ya existe o se guardó correctamente"}
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error en SQL Server al guardar material: {str(e)}")
    finally:
        conn.close()

@router.delete("/api/materiales/oficial/{identificador}")
def eliminar_material_oficial(identificador: str):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("DELETE FROM Tbl_Materiales_Aprobados WHERE Material = ?", (identificador,))
        if cursor.rowcount == 0:
            raise HTTPException(status_code=404, detail="Material no encontrado")
        conn.commit()
        return {"status": "success", "message": "Material oficial eliminado correctamente"}
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error en SQL Server al eliminar material: {str(e)}")
    finally:
        conn.close()
@router.get("/api/config/regla_espejo")
async def get_mirror_config():
    return {"activa": state.REGLA_ESPEJO_ACTIVA}

@router.post("/api/config/regla_espejo")
async def set_mirror_config(config: MirrorConfig):
    state.REGLA_ESPEJO_ACTIVA = config.activa
    print(f"--- REGLA ESPEJO ACTUALIZADA: {state.REGLA_ESPEJO_ACTIVA} ---")
    return {"activa": state.REGLA_ESPEJO_ACTIVA}
