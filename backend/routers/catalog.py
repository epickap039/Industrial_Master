"""API router: catalog."""
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
from audit_service import registrar_auditoria

router = APIRouter()

@router.get("/api/catalog")
async def get_catalog():
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # Catálogo maestro oficial: Tbl_Maestro_Piezas (misma fuente que total_piezas en /api/dashboard/kpi).
        cursor.execute("SELECT * FROM Tbl_Maestro_Piezas")
        columns = [column[0] for column in cursor.description]
        data = []
        for row in cursor.fetchall():
            record = {}
            for col, val in zip(columns, row):
                record[col] = val if val is not None else "-"
            data.append(record)
        return data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

@router.delete("/api/catalog/{codigo}")
async def delete_material_catalog(codigo: str):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # Check existence first
        cursor.execute("SELECT Codigo_Pieza FROM Tbl_Maestro_Piezas WHERE Codigo_Pieza = ?", (codigo,))
        if not cursor.fetchone():
            raise HTTPException(status_code=404, detail="Pieza no encontrada en el catálogo")
            
        cursor.execute("DELETE FROM Tbl_Maestro_Piezas WHERE Codigo_Pieza = ?", (codigo,))
        conn.commit()
        return {"status": "success", "message": f"Pieza {codigo} eliminada correctamente"}
    except HTTPException as he:
        conn.rollback()
        raise he
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

DIRECTORIO_MAESTRO_DXF = os.environ.get("DIRECTORIO_MAESTRO_DXF", r"Y:\2026")

@router.get("/api/dxf/search/{codigo}")
async def search_dxf_catalog(codigo: str, base_path: str):
    try:
        clean_base_path = base_path.strip('"').strip("'")
        target_dir = Path(clean_base_path)
        if not target_dir.exists() or not target_dir.is_dir():
             raise HTTPException(status_code=500, detail=f"Ruta maestra no encontrada o no es un directorio: {clean_base_path}")
             
        # Búsqueda global con comodines
        archivos_encontrados = list(target_dir.rglob(f"*{codigo}*.*"))
        
        # Filtrar solo archivos con extensiones dxf o dwg
        valid_files = [
            p for p in archivos_encontrados
            if p.is_file() and p.suffix.lower() in ['.dxf', '.dwg']
        ]
        
        if not valid_files:
             raise HTTPException(status_code=404, detail=f"No se encontraron archivos .dxf o .dwg válidos para '{codigo}' dentro de {clean_base_path}")

        # Manejo de Duplicados/Revisiones: Obtener el archivo más reciente (última modificación)
        newest_file = max(valid_files, key=lambda f: os.path.getmtime(f))

        return {"status": "success", "codigo": codigo, "dxf_path": str(newest_file.resolve())}
    except HTTPException as he:
        raise he
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# 6. EDICIÓN DE MATERIALES (ESPECÍFICA + CAMPOS NUEVOS + PROCESO 3)
@router.put("/api/material/update")
async def update_material(request: Request, payload: Dict[str, Any]):
    print(f"--- UPDATE MATERIAL FULL EDITOR V2 ---")
    print(f"Payload: {payload}")

    # Extraer ID
    codigo_pieza = payload.get('Codigo_Pieza')
    codigo_legacy = payload.get('Codigo')
    id_param = codigo_pieza if codigo_pieza else codigo_legacy

    if not id_param:
        raise HTTPException(status_code=400, detail="Falta Codigo_Pieza o Codigo")

    # Campos Permitidos (Whitelist) - Incluyendo Proceso_3
    allowed_fields = [
        'Descripcion', 'Medida', 'Material', 'Link_Drive', 
        'Simetria', 'Proceso_Primario', 'Proceso_1', 'Proceso_2', 'Proceso_3'
    ]
    
    # REGLA ESPEJO ELIMINADA: Descripcion y Material son campos independientes.
    # Cada campo recibe sólo su propio valor del frontend.

    usuario = payload.get('usuario') or payload.get('Modificado_Por') or 'Sistema'

    conn = get_db_connection()
    cursor = conn.cursor()
    
    try:
        # Asegurar columna Modificado_Por en maestro de piezas
        try:
            cursor.execute("SELECT Modificado_Por FROM Tbl_Maestro_Piezas WHERE 1=0")
        except Exception:
             conn.rollback()
             cursor.execute("ALTER TABLE Tbl_Maestro_Piezas ADD Modificado_Por NVARCHAR(50)")
             conn.commit()

        # Construcción Dinámica Segura de la Query
        set_clauses = []
        values = []
        
        for field in allowed_fields:
            if field in payload:
               set_clauses.append(f"{field} = ?")
               values.append(payload[field])
        
        if not set_clauses:
             return {"status": "ignored", "message": "No hay campos válidos para actualizar"}


        # Agregar Auditoría
        set_clauses.append("Modificado_Por = ?")
        values.append(usuario)
        
        set_clauses.append("Ultima_Actualizacion = GETDATE()")
        
        query_set = ", ".join(set_clauses)
        
        # --- AUDITORIA: CAPTURAR VALOR ANTERIOR ---
        try:
             # Seleccionamos todos los campos afectados + ID
             cols_to_select = ", ".join(allowed_fields)
             cursor.execute(f"SELECT {cols_to_select} FROM Tbl_Maestro_Piezas WHERE Codigo_Pieza = ?", (id_param,))
             row_prev = cursor.fetchone()
             
             valor_anterior = {}
             if row_prev:
                 for i, field in enumerate(allowed_fields):
                     valor_anterior[field] = str(row_prev[i]) if row_prev[i] is not None else ""
             else:
                 valor_anterior = "REGISTRO NO ENCONTRADO (Posible error en Update)"
        except Exception as audit_read_e:
             valor_anterior = f"ERROR LECTURA PREVIA: {audit_read_e}"
        # ------------------------------------------

        # Query Principal — Tbl_Maestro_Piezas (catálogo maestro)
        query = f"UPDATE Tbl_Maestro_Piezas SET {query_set} WHERE Codigo_Pieza = ?"
        values.append(id_param)
        
        print(f"SQL GENERADO: {query}")
        
        cursor.execute(query, values)
        
        if cursor.rowcount == 0:
            print("Fallback: Actualizando por Codigo...")
            query_fallback = f"UPDATE Tbl_Maestro_Piezas SET {query_set} WHERE Codigo = ?"
            cursor.execute(query_fallback, values)

        conn.commit()
        
        if cursor.rowcount > 0:
             # --- AUDITORIA: REGISTRAR CAMBIO ---
             registrar_auditoria(cursor, id_param, 'EDICION_CATALOGO', valor_anterior, payload, usuario)
             conn.commit() # Commit del log
             # -----------------------------------
             return {"status": "success", "message": "Actualizado correctamente"}
        else:
             raise HTTPException(status_code=404, detail="No se encontró registro (Codigo/Codigo_Pieza)")

    except Exception as e:
        conn.rollback()
        print(f"ERROR UPDATE: {e}")
        raise HTTPException(status_code=500, detail=f"SQL Error: {str(e)}")
    finally:
        conn.close()

