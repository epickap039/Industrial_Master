"""API router: limpieza."""
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

@router.get("/api/limpieza/descripciones_unicas")
async def get_unique_descriptions():
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        query = """
            SELECT Descripcion, COUNT(Codigo_Pieza) as Total 
            FROM Tbl_Maestro_Piezas 
            WHERE Descripcion IS NOT NULL AND Descripcion != ''
            GROUP BY Descripcion 
            ORDER BY Descripcion ASC
        """
        cursor.execute(query)
        data = [{"descripcion": row[0], "total": row[1]} for row in cursor.fetchall()]
        return data
    except Exception as e:
         print(f"ERROR DESC UNICAS: {e}")
         raise HTTPException(status_code=500, detail=str(e))
    finally:
         conn.close()
@router.post("/api/limpieza/actualizar_masivo")
async def actualizar_masivo(payload: MasivoUpdate):
    print(f"--- INICIANDO ESTANDARIZACION MASIVA: '{payload.old_desc}' -> '{payload.new_desc}' ---")
    
    conn = get_db_connection()
    cursor = conn.cursor()
    
    try:
        # 1. Obtener todas las piezas afectadas para auditoría individual
        cursor.execute("SELECT Codigo_Pieza FROM Tbl_Maestro_Piezas WHERE Descripcion = ?", (payload.old_desc,))
        piezas = cursor.fetchall()
        
        if not piezas:
             return {"status": "ignored", "message": "No se encontraron piezas con esa descripción."}
        
        actualizadas = 0
        
        # 2. Iterar y actualizar UNO A UNO
        for p in piezas:
            codigo = p[0]
            
            # REGLA ESPEJO ELIMINADA: el renombre masivo sólo toca Descripcion.
            # Material se mantiene intacto.
            cursor.execute("""
                UPDATE Tbl_Maestro_Piezas 
                SET Descripcion = ?, Ultima_Actualizacion = GETDATE(), Modificado_Por = ?
                WHERE Codigo_Pieza = ?
            """, (payload.new_desc, payload.usuario, codigo))
            val_nuevo = str({"Descripcion": payload.new_desc})
            
            if cursor.rowcount > 0:
                actualizadas += 1
                # Auditoría Individual
                registrar_auditoria(
                    cursor, 
                    codigo_pieza=codigo, 
                    accion='ESTANDARIZACION_MASIVA', 
                    valor_anterior=str({'Descripcion': payload.old_desc}), 
                    valor_nuevo=val_nuevo, 
                    usuario=payload.usuario
                )
        
        conn.commit()
        print(f"--- ESTANDARIZACION FINALIZADA: {actualizadas} piezas actualizadas ---")
        return {"status": "ok", "actualizadas": actualizadas}
        
    except Exception as e:
        conn.rollback()
        print(f"ERROR MASIVO: {e}")
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()
