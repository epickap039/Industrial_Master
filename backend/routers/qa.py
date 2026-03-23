"""API router: qa."""
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

# === BUG TRACKER ===
@router.post("/api/reportes/nuevo")
def nuevo_reporte(payload: BugReportPayload):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("""
            INSERT INTO Tbl_Reportes_Beta (Usuario, Fecha_Hora, Modulo, Descripcion, Gravedad, Estado, Captura_Base64)
            VALUES (?, GETDATE(), ?, ?, ?, 'Abierto', ?)
        """, (payload.usuario, payload.modulo, payload.descripcion, payload.gravedad, payload.captura))
        conn.commit()
        return {"status": "success"}
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

@router.get("/api/reportes/exportar_gemini")
def exportar_reportes():
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("SELECT ID_Reporte, Modulo, Descripcion, Gravedad, Captura_Base64 FROM Tbl_Reportes_Beta WHERE Estado = 'Abierto'")
        rows = cursor.fetchall()
        reportes = []
        for r in rows:
            reportes.append({
                "id": r.ID_Reporte,
                "modulo": r.Modulo,
                "error": r.Descripcion,
                "severidad": r.Gravedad,
                "captura_base64": r.Captura_Base64
            })
        return reportes
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

@router.get("/api/reportes")
def listar_reportes():
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("SELECT ID_Reporte, Usuario, Fecha_Hora, Modulo, Descripcion, Gravedad, Estado, Captura_Base64 FROM Tbl_Reportes_Beta WHERE Estado = 'Abierto' ORDER BY Fecha_Hora DESC")
        rows = cursor.fetchall()
        reportes = []
        for r in rows:
            reportes.append({
                "id": r.ID_Reporte,
                "usuario": r.Usuario,
                "fecha": r.Fecha_Hora.strftime("%Y-%m-%d %H:%M:%S") if r.Fecha_Hora else None,
                "modulo": r.Modulo,
                "descripcion": r.Descripcion,
                "gravedad": r.Gravedad,
                "estado": r.Estado,
                "captura_base64": r.Captura_Base64
            })
        return reportes
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

@router.get("/api/reportes/exportar")
def exportar_reportes_excel():
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("SELECT ID_Reporte, Usuario, Fecha_Hora, Modulo, Descripcion, Gravedad, Estado FROM Tbl_Reportes_Beta ORDER BY Fecha_Hora DESC")
        rows = cursor.fetchall()
        
        wb = openpyxl.Workbook()
        ws = wb.active
        ws.title = "Reportes Beta"
        
        headers = ["ID", "Usuario", "Fecha", "Módulo", "Gravedad", "Estado", "Descripción"]
        for col_idx, text in enumerate(headers, 1):
            cell = ws.cell(row=1, column=col_idx, value=text)
            cell.font = Font(bold=True, color="FFFFFF")
            cell.fill = PatternFill(start_color="1E3A8A", end_color="1E3A8A", fill_type="solid")
            cell.alignment = Alignment(horizontal="center")
            
        for row_idx, r in enumerate(rows, 2):
            fecha_str = r.Fecha_Hora.strftime("%Y-%m-%d %H:%M:%S") if r.Fecha_Hora else "Sin fecha"
            ws.cell(row=row_idx, column=1, value=int(r.ID_Reporte))
            ws.cell(row=row_idx, column=2, value=str(r.Usuario))
            ws.cell(row=row_idx, column=3, value=fecha_str)
            ws.cell(row=row_idx, column=4, value=str(r.Modulo))
            ws.cell(row=row_idx, column=5, value=str(r.Gravedad))
            ws.cell(row=row_idx, column=6, value=str(r.Estado))
            ws.cell(row=row_idx, column=7, value=str(r.Descripcion))

        # Auto-fit columns
        for col in ws.columns:
            max_length = 0
            column = col[0].column_letter
            for cell in col:
                try:
                    if len(str(cell.value)) > max_length:
                        max_length = len(str(cell.value))
                except: pass
            ws.column_dimensions[column].width = min((max_length + 2) * 1.1, 60)
            
        stream = io.BytesIO()
        wb.save(stream)
        stream.seek(0)
        
        return StreamingResponse(
            stream,
            media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            headers={
                "Content-Disposition": "attachment; filename=Reportes_Beta.xlsx"
            }
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

@router.put("/api/reportes/{id_reporte}/resolver")
def resolver_reporte(id_reporte: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("UPDATE Tbl_Reportes_Beta SET Estado = 'Cerrado' WHERE ID_Reporte = ?", (id_reporte,))
        conn.commit()
        return {"status": "success"}
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()
