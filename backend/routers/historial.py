"""API router: historial."""
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

import ast

@router.get("/api/historial")
async def obtener_historial(busqueda: Optional[str] = None, limite: int = 50):
    print(f"--- CONSULTANDO HISTORIAL (Busqueda: {busqueda}, Limite: {limite}) ---")
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        
        query = """
            SELECT TOP (?) ID_Log, Codigo_Pieza, Accion, Valor_Anterior, Valor_Nuevo, Usuario, Fecha_Hora 
            FROM Tbl_Auditoria_Cambios 
        """
        params = [limite]
        
        if busqueda:
            # Busca en código, usuario Y acción para que eventos VIN aparezcan
            query += " WHERE Codigo_Pieza LIKE ? OR Usuario LIKE ? OR Accion LIKE ? "
            search_term = f"%{busqueda}%"
            params.extend([search_term, search_term, search_term])

        query += " ORDER BY Fecha_Hora DESC"
        
        cursor.execute(query, params)
        rows = cursor.fetchall()
        
        historial = []
        for row in rows:
            val_ant = row[3]
            val_nue = row[4]
            
            # Intentar parsear Valor_Anterior
            if val_ant and isinstance(val_ant, str):
                val_ant_s = val_ant.strip()
                try:
                    if val_ant_s.startswith('{') or val_ant_s.startswith('['):
                         val_ant = json.loads(val_ant.replace("'", '"')) # Attempt JSON fix or standard load
                    elif val_ant_s.startswith('('):
                         val_ant = ast.literal_eval(val_ant)
                    # NOTA: evitamos evaluar incondicionalmente con ast.literal_eval
                    # porque si val_ant es un string numérico con ceros a la izq ("002")
                    # Python lanza SyntaxWarning: invalid decimal literal
                except:
                    pass # Keep as string if fail

            # Intentar parsear Valor_Nuevo
            if val_nue and isinstance(val_nue, str):
                val_nue_s = val_nue.strip()
                try:
                    if val_nue_s.startswith('{') or val_nue_s.startswith('['):
                         val_nue = json.loads(val_nue.replace("'", '"'))
                    elif val_nue_s.startswith('('):
                         val_nue = ast.literal_eval(val_nue)
                except:
                    pass

            historial.append({
                "id": row[0],
                "codigo": row[1],
                "accion": row[2],
                "valor_anterior": val_ant,
                "valor_nuevo": val_nue,
                "usuario": row[5],
                "fecha": row[6].strftime("%Y-%m-%d %H:%M:%S") if row[6] else None
            })
            
        return historial

    except Exception as e:
        print(f"ERROR HISTORIAL: {e}")
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        if 'conn' in locals(): conn.close()

