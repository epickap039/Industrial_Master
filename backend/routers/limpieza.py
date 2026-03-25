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
from fastapi import APIRouter, BackgroundTasks, File, Form, Header, HTTPException, Query, Request, Response, UploadFile
from fastapi.responses import StreamingResponse
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side

from database import get_db_connection, _int_from_count_row
from models import *
from audit_service import registrar_auditoria
from user_context import resolve_actor_user

router = APIRouter()

@router.get("/api/limpieza/descripciones_unicas")
async def get_unique_descriptions(
    campo: str = Query(
        "material",
        description="Columna a listar: 'material' o 'descripcion'",
    ),
):
    """Valores distintos de Material o Descripción con conteo de piezas (estandarización)."""
    c = (campo or "material").strip().lower()
    if c not in ("material", "descripcion"):
        raise HTTPException(
            status_code=400,
            detail="Parámetro 'campo' debe ser 'material' o 'descripcion'.",
        )
    col = "Material" if c == "material" else "Descripcion"
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        query = f"""
            SELECT {col}, COUNT(Codigo_Pieza) AS Total
            FROM Tbl_Maestro_Piezas
            WHERE {col} IS NOT NULL AND LTRIM(RTRIM({col})) <> ''
            GROUP BY {col}
            ORDER BY {col} ASC
        """
        cursor.execute(query)
        data = [
            {"valor": row[0], "total": row[1], "campo": c}
            for row in cursor.fetchall()
        ]
        return data
    except Exception as e:
        print(f"ERROR VALORES UNICOS ({c}): {e}")
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.post("/api/limpieza/actualizar_masivo")
async def actualizar_masivo(
    payload: MasivoUpdate,
    authorization: Optional[str] = Header(None),
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
):
    campo = payload.campo
    actor = resolve_actor_user(authorization, x_usuario)
    usuario_db = actor
    if actor == "Sistema" and (payload.usuario or "").strip():
        usuario_db = (payload.usuario or "").strip()[:100]
    print(
        f"--- ESTANDARIZACION MASIVA [{campo}] usuario={usuario_db}: "
        f"'{payload.old_desc}' -> '{payload.new_desc}' ---",
    )

    conn = get_db_connection()
    cursor = conn.cursor()

    try:
        if campo == "material":
            cursor.execute(
                "SELECT Codigo_Pieza FROM Tbl_Maestro_Piezas WHERE Material = ?",
                (payload.old_desc,),
            )
            col_set = "Material"
            val_ant = {"Material": payload.old_desc}
            val_nuevo_tpl = {"Material": payload.new_desc}
        else:
            cursor.execute(
                "SELECT Codigo_Pieza FROM Tbl_Maestro_Piezas WHERE Descripcion = ?",
                (payload.old_desc,),
            )
            col_set = "Descripcion"
            val_ant = {"Descripcion": payload.old_desc}
            val_nuevo_tpl = {"Descripcion": payload.new_desc}

        piezas = cursor.fetchall()

        if not piezas:
            label = "material" if campo == "material" else "descripción"
            return {
                "status": "ignored",
                "message": f"No se encontraron piezas con ese {label}.",
            }

        actualizadas = 0

        for p in piezas:
            codigo = p[0]
            cursor.execute(
                f"""
                UPDATE Tbl_Maestro_Piezas
                SET {col_set} = ?, Ultima_Actualizacion = GETDATE(), Modificado_Por = ?
                WHERE Codigo_Pieza = ?
                """,
                (payload.new_desc, usuario_db, codigo),
            )
            val_nuevo = str(val_nuevo_tpl)

            if cursor.rowcount > 0:
                actualizadas += 1
                registrar_auditoria(
                    cursor,
                    codigo_pieza=codigo,
                    accion="ESTANDARIZACION_MASIVA",
                    valor_anterior=str(val_ant),
                    valor_nuevo=val_nuevo,
                    usuario=usuario_db,
                )

        conn.commit()
        print(f"--- ESTANDARIZACION FINALIZADA: {actualizadas} piezas ---")
        return {"status": "ok", "actualizadas": actualizadas}

    except Exception as e:
        conn.rollback()
        print(f"ERROR MASIVO: {e}")
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()
