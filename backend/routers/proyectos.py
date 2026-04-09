"""API router: proyectos."""
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

from admin_master_password import assert_admin_master_password_matches
from database import get_db_connection, _int_from_count_row
from models import *
from .bom import _purge_version_physical, _purge_tipo_physical

router = APIRouter()

@router.get("/api/proyectos/tractos")
def get_tractos():
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("SELECT ID_Tracto, Nombre_Tracto FROM Tbl_Proyectos_Tracto ORDER BY Nombre_Tracto")
        rows = cursor.fetchall()
        return [{"id": r[0], "nombre": r[1]} for r in rows]
    finally:
        conn.close()

@router.post("/api/proyectos/tractos")
def add_tracto(payload: TractoPayload):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("INSERT INTO Tbl_Proyectos_Tracto (Nombre_Tracto) VALUES (?)", (payload.nombre.upper(),))
        conn.commit()
        return {"status": "success"}
    except pyodbc.IntegrityError as e:
        conn.rollback()
        raise HTTPException(status_code=400, detail=f"El Tracto '{payload.nombre}' ya existe o hay un error de integridad. Detalle: {str(e)}")
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error interno del servidor al insertar tracto: {str(e)}")
    finally:
        conn.close()

@router.delete("/api/proyectos/tractos/{id_tracto}")
def delete_tracto(
    id_tracto: int,
    x_admin_master_password: Optional[str] = Header(
        None, alias="X-Admin-Master-Password"
    ),
):
    assert_admin_master_password_matches(x_admin_master_password)
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("DELETE FROM Tbl_Proyectos_Tracto WHERE ID_Tracto = ?", (id_tracto,))
        if cursor.rowcount == 0:
            raise HTTPException(status_code=404, detail="No encontrado")
        conn.commit()
        return {"status": "success"}
    finally:
        conn.close()

# Endpoints Tipo de Proyecto
@router.get("/api/proyectos/tipos/{id_tracto}")
def get_tipos(id_tracto: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("SELECT ID_Tipo, Nombre_Tipo FROM Tbl_Tipos_Proyecto WHERE ID_Tracto = ? ORDER BY Nombre_Tipo", (id_tracto,))
        rows = cursor.fetchall()
        return [{"id": r[0], "nombre": r[1]} for r in rows]
    finally:
        conn.close()

@router.post("/api/proyectos/tipos")
def add_tipo(payload: TipoProyectoPayload):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("INSERT INTO Tbl_Tipos_Proyecto (ID_Tracto, Nombre_Tipo) VALUES (?, ?)", (payload.id_tracto, payload.nombre.upper()))
        conn.commit()
        return {"status": "success"}
    except pyodbc.IntegrityError as e:
        conn.rollback()
        raise HTTPException(status_code=400, detail=f"Error al agregar Tipo. Verifica que no exista ya y que el Tracto sea válido. Detalle: {str(e)}")
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error interno: {str(e)}")
    finally:
        conn.close()

@router.delete("/api/proyectos/tipos/{id_tipo}")
def delete_tipo(
    id_tipo: int,
    x_admin_master_password: Optional[str] = Header(
        None, alias="X-Admin-Master-Password"
    ),
):
    """Borrado físico: elimina todas las versiones/BOM del tipo y luego el tipo (tractos intactos)."""
    assert_admin_master_password_matches(x_admin_master_password)
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute(
            "SELECT 1 FROM Tbl_Tipos_Proyecto WHERE ID_Tipo = ?",
            (id_tipo,),
        )
        if cursor.fetchone() is None:
            raise HTTPException(status_code=404, detail="No encontrado")
        _purge_tipo_physical(cursor, id_tipo)
        conn.commit()
        return {"status": "success"}
    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

# Endpoints Version
@router.get("/api/proyectos/versiones/{id_tipo}")
def get_versiones(id_tipo: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("SELECT ID_Version, Nombre_Version FROM Tbl_Versiones_Ingenieria WHERE ID_Tipo = ? ORDER BY Nombre_Version", (id_tipo,))
        rows = cursor.fetchall()
        return [{"id": r[0], "nombre": r[1]} for r in rows]
    finally:
        conn.close()

@router.post("/api/proyectos/versiones")
def add_version(payload: VersionPayload):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("INSERT INTO Tbl_Versiones_Ingenieria (ID_Tipo, Nombre_Version) VALUES (?, ?)", (payload.id_tipo, payload.nombre.upper()))
        conn.commit()
        return {"status": "success"}
    except pyodbc.IntegrityError as e:
        conn.rollback()
        raise HTTPException(status_code=400, detail=f"Error en inserción de Versión. Asegúrate de que el Tipo de Proyecto exista. Detalle: {str(e)}")
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error interno del servidor al insertar versión: {str(e)}")
    finally:
        conn.close()

@router.delete("/api/proyectos/versiones/{id_version}")
def delete_version(
    id_version: int,
    x_admin_master_password: Optional[str] = Header(
        None, alias="X-Admin-Master-Password"
    ),
):
    """Borrado físico: elimina revisiones BOM (cascada), clientes de la versión y la versión."""
    assert_admin_master_password_matches(x_admin_master_password)
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute(
            "SELECT 1 FROM Tbl_Versiones_Ingenieria WHERE ID_Version = ?",
            (id_version,),
        )
        if cursor.fetchone() is None:
            raise HTTPException(status_code=404, detail="No encontrado")
        _purge_version_physical(cursor, id_version)
        conn.commit()
        return {"status": "success"}
    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

# Endpoints Clientes
@router.get("/api/proyectos/clientes/{id_version}")
def get_clientes(id_version: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("SELECT ID_Config_Cliente, Nombre_Cliente FROM Tbl_Clientes_Configuracion WHERE ID_Version = ? ORDER BY Nombre_Cliente", (id_version,))
        rows = cursor.fetchall()
        return [{"id": r[0], "nombre": r[1]} for r in rows]
    finally:
        conn.close()

@router.post("/api/proyectos/clientes")
def add_cliente(payload: ClientePayload):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("INSERT INTO Tbl_Clientes_Configuracion (ID_Version, Nombre_Cliente) VALUES (?, ?)", (payload.id_version, payload.nombre.upper()))
        conn.commit()
        return {"status": "success"}
    except pyodbc.IntegrityError as e:
        conn.rollback()
        raise HTTPException(status_code=400, detail=f"Error en inserción de Cliente. Asegúrate de que la Versión exista. Detalle: {str(e)}")
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error interno del servidor al insertar cliente: {str(e)}")
    finally:
        conn.close()

@router.delete("/api/proyectos/clientes/{id_cliente}")
def delete_cliente(
    id_cliente: int,
    x_admin_master_password: Optional[str] = Header(
        None, alias="X-Admin-Master-Password"
    ),
):
    assert_admin_master_password_matches(x_admin_master_password)
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("DELETE FROM Tbl_Clientes_Configuracion WHERE ID_Config_Cliente = ?", (id_cliente,))
        if cursor.rowcount == 0:
            raise HTTPException(status_code=404, detail="No encontrado")
        conn.commit()
        return {"status": "success"}
    finally:
        conn.close()
# === FIN JERARQUIA DE PROYECTOS ===
