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
from fastapi import APIRouter, BackgroundTasks, File, Form, Header, HTTPException, Query, Request, Response, UploadFile
from fastapi.responses import StreamingResponse
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side

from database import get_db_connection, _int_from_count_row
from env_config import allow_runtime_ddl
from models import *
import state
from schema_guard import table_exists

router = APIRouter()


def _prepare_manual_table(cursor: Any) -> None:
    if table_exists(cursor, "Tbl_App_Manual"):
        return
    if allow_runtime_ddl():
        _ensure_manual_table(cursor)
    else:
        raise HTTPException(
            status_code=503,
            detail="Tbl_App_Manual no existe. Cree la tabla vía migraciones SQL o defina IM_ALLOW_RUNTIME_DDL=1 solo en desarrollo.",
        )


def _ensure_manual_table(cursor: Any) -> None:
    cursor.execute(
        """
        IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'Tbl_App_Manual')
        BEGIN
            CREATE TABLE dbo.Tbl_App_Manual (
                ID_Manual INT IDENTITY(1,1) PRIMARY KEY,
                Modulo NVARCHAR(80) NOT NULL UNIQUE,
                Titulo NVARCHAR(200) NOT NULL,
                Contenido NVARCHAR(MAX) NOT NULL,
                Actualizado_Por NVARCHAR(120) NULL,
                Actualizado_En DATETIME2(0) NOT NULL CONSTRAINT DF_Tbl_App_Manual_ActualizadoEn DEFAULT (SYSUTCDATETIME())
            );
        END
        """
    )


def _can_edit_manual(cursor: Any, usuario: str) -> bool:
    u = (usuario or "").strip()
    if not u:
        return False
    cursor.execute(
        """
        SELECT TOP 1 Rol
        FROM Tbl_Usuarios
        WHERE Username = ? OR Nombre = ?
        """,
        (u, u),
    )
    row = cursor.fetchone()
    if not row:
        return False
    rol = str(row[0] or "").strip().upper()
    return rol in {"ADMIN", "ADMINISTRADOR", "DESARROLLADOR", "INGENIERIA_METODOS", "INGENIERIA"}


class ManualEntryPayload(BaseModel):
    titulo: str
    contenido: str


@router.get("/api/config/manual")
def get_manual_entries():
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        _prepare_manual_table(cursor)
        conn.commit()
        cursor.execute(
            """
            SELECT Modulo, Titulo, Contenido, Actualizado_Por, Actualizado_En
            FROM Tbl_App_Manual
            ORDER BY Modulo
            """
        )
        rows = cursor.fetchall()
        return [
            {
                "modulo": str(r.Modulo),
                "titulo": str(r.Titulo),
                "contenido": str(r.Contenido),
                "actualizado_por": r.Actualizado_Por,
                "actualizado_en": r.Actualizado_En.isoformat() if r.Actualizado_En else None,
            }
            for r in rows
        ]
    finally:
        conn.close()


@router.put("/api/config/manual/{modulo}")
def upsert_manual_entry(
    modulo: str,
    payload: ManualEntryPayload,
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        _prepare_manual_table(cursor)
        usuario = (x_usuario or "").strip()
        if not _can_edit_manual(cursor, usuario):
            raise HTTPException(status_code=403, detail="Solo admin/desarrollador/ingeniería pueden editar el manual")

        mod = modulo.strip().lower()
        if not mod:
            raise HTTPException(status_code=400, detail="Módulo inválido")
        titulo = payload.titulo.strip()
        contenido = payload.contenido.strip()
        if not titulo or not contenido:
            raise HTTPException(status_code=400, detail="Título y contenido son obligatorios")

        cursor.execute("SELECT 1 FROM Tbl_App_Manual WHERE Modulo = ?", (mod,))
        if cursor.fetchone():
            cursor.execute(
                """
                UPDATE Tbl_App_Manual
                SET Titulo = ?, Contenido = ?, Actualizado_Por = ?, Actualizado_En = SYSUTCDATETIME()
                WHERE Modulo = ?
                """,
                (titulo, contenido, usuario or None, mod),
            )
        else:
            cursor.execute(
                """
                INSERT INTO Tbl_App_Manual (Modulo, Titulo, Contenido, Actualizado_Por)
                VALUES (?, ?, ?, ?)
                """,
                (mod, titulo, contenido, usuario or None),
            )
        conn.commit()
        return {"ok": True, "modulo": mod}
    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

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

def _delete_material_aprobado(material: str) -> dict:
    """Elimina por descripción exacta (mayúsculas, como en INSERT)."""
    key = (material or "").strip().upper()
    if not key:
        raise HTTPException(status_code=400, detail="Material vacío")
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute(
            "DELETE FROM Tbl_Materiales_Aprobados WHERE Material = ?",
            (key,),
        )
        if cursor.rowcount == 0:
            raise HTTPException(status_code=404, detail="Material no encontrado")
        conn.commit()
        return {"mensaje": "Material eliminado correctamente"}
    finally:
        conn.close()


@router.delete("/api/config/materiales")
def delete_material_query(material: str = Query(..., min_length=1)):
    """
    Elimina material oficial. Usar query `material` cuando el nombre lleva `/`
    (p. ej. `3/8"`) — evita 404 por segmentos de ruta.
    """
    return _delete_material_aprobado(material)


@router.delete("/api/config/materiales/{material_name:path}")
def delete_material_path(material_name: str):
    """Compatibilidad: ruta con `:path` captura barras en el nombre."""
    return _delete_material_aprobado(material_name)

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

@router.delete("/api/materiales/oficial")
def eliminar_material_oficial_query(
    material: str = Query(..., min_length=1),
):
    """Igual que config/materiales: query evita rotura con `/` en la descripción."""
    _delete_material_aprobado(material)
    return {"status": "success", "message": "Material oficial eliminado correctamente"}


@router.delete("/api/materiales/oficial/{identificador:path}")
def eliminar_material_oficial_path(identificador: str):
    try:
        _delete_material_aprobado(identificador)
        return {"status": "success", "message": "Material oficial eliminado correctamente"}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Error en SQL Server al eliminar material: {str(e)}",
        )
@router.get("/api/config/regla_espejo")
async def get_mirror_config():
    return {"activa": state.REGLA_ESPEJO_ACTIVA}

@router.post("/api/config/regla_espejo")
async def set_mirror_config(config: MirrorConfig):
    state.REGLA_ESPEJO_ACTIVA = config.activa
    print(f"--- REGLA ESPEJO ACTUALIZADA: {state.REGLA_ESPEJO_ACTIVA} ---")
    return {"activa": state.REGLA_ESPEJO_ACTIVA}
