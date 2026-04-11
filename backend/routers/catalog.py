"""API router: catalog."""
import ast
import csv
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
import urllib.error
import urllib.request
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


@router.get("/api/catalog/pieza/{codigo}")
def get_catalog_pieza_by_codigo(codigo: str):
    """Comprueba si el código existe en Tbl_Maestro_Piezas (búsqueda ligera para el BOM)."""
    c = (codigo or "").strip()
    if not c:
        raise HTTPException(status_code=400, detail="Código vacío")
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute(
            """
            SELECT TOP 1
                Codigo_Pieza, Descripcion, Material,
                Proceso_Primario, Proceso_1, Proceso_2, Proceso_3
            FROM Tbl_Maestro_Piezas
            WHERE Codigo_Pieza = ?
            """,
            (c,),
        )
        row = cursor.fetchone()
        if not row:
            raise HTTPException(
                status_code=404,
                detail="Esta pieza no está en el catálogo",
            )
        return {
            "exists": True,
            "codigo_pieza": str(getattr(row, "Codigo_Pieza", "") or c),
            "descripcion": str(getattr(row, "Descripcion", "") or ""),
            "material": str(getattr(row, "Material", "") or ""),
            "proceso_primario": str(getattr(row, "Proceso_Primario", "") or ""),
            "proceso_1": str(getattr(row, "Proceso_1", "") or ""),
            "proceso_2": str(getattr(row, "Proceso_2", "") or ""),
            "proceso_3": str(getattr(row, "Proceso_3", "") or ""),
        }
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.get("/api/catalog/procesos")
def listar_procesos_catalogo():
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute(
            """
            SELECT DISTINCT p
            FROM (
                SELECT LTRIM(RTRIM(ISNULL(Proceso_Primario, ''))) AS p FROM Tbl_Maestro_Piezas
                UNION ALL
                SELECT LTRIM(RTRIM(ISNULL(Proceso_1, ''))) AS p FROM Tbl_Maestro_Piezas
                UNION ALL
                SELECT LTRIM(RTRIM(ISNULL(Proceso_2, ''))) AS p FROM Tbl_Maestro_Piezas
                UNION ALL
                SELECT LTRIM(RTRIM(ISNULL(Proceso_3, ''))) AS p FROM Tbl_Maestro_Piezas
            ) q
            WHERE p <> ''
            ORDER BY p
            """
        )
        return [str(r[0]).strip() for r in cursor.fetchall() if r and str(r[0]).strip()]
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.post("/api/catalog/generador/crear")
def crear_pieza_desde_generador(payload: CodigoGeneradorPayload):
    codigo = (payload.codigo or "").strip().upper()
    if not codigo:
        raise HTTPException(status_code=400, detail="Código obligatorio")
    procesos = [str(p or "").strip().upper() for p in (payload.procesos or []) if str(p or "").strip()]
    if not procesos:
        raise HTTPException(status_code=400, detail="Debe indicar al menos un proceso")

    desc = (payload.descripcion or "").strip()
    material = (payload.material or "").strip().upper()
    usuario = (payload.usuario or "GeneradorCodigo").strip() or "GeneradorCodigo"
    sim = "SI" if payload.simetria else "NO"
    detalle_sim = (payload.detalle_simetria or "").strip()
    ref_plano = (payload.referencia_plano or "").strip()

    medidas = []
    if payload.largo is not None:
        medidas.append(f"L:{payload.largo:g}")
    if payload.ancho is not None:
        medidas.append(f"A:{payload.ancho:g}")
    if payload.espesor is not None:
        medidas.append(f"E:{payload.espesor:g}")
    medida_txt = " | ".join(medidas)

    extras = []
    if detalle_sim:
        extras.append(f"Simetría: {detalle_sim}")
    if ref_plano:
        extras.append(f"Plano: {ref_plano}")
    if extras:
        desc = f"{desc} {' | '.join(extras)}".strip()

    p0 = procesos[0] if len(procesos) > 0 else ""
    p1 = procesos[1] if len(procesos) > 1 else ""
    p2 = procesos[2] if len(procesos) > 2 else ""
    p3 = procesos[3] if len(procesos) > 3 else ""

    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute(
            "SELECT TOP 1 Codigo_Pieza FROM Tbl_Maestro_Piezas WHERE Codigo_Pieza = ?",
            (codigo,),
        )
        if cursor.fetchone():
            raise HTTPException(status_code=409, detail="El código ya existe en catálogo maestro")

        cursor.execute(
            """
            INSERT INTO Tbl_Maestro_Piezas
            (
                Codigo_Pieza, Codigo, Descripcion, Medida, Material, Simetria,
                Proceso_Primario, Proceso_1, Proceso_2, Proceso_3,
                Link_Drive, Ultima_Actualizacion, Modificado_Por
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '', GETDATE(), ?)
            """,
            (
                codigo,
                codigo,
                desc,
                medida_txt,
                material,
                sim,
                p0,
                p1,
                p2,
                p3,
                usuario,
            ),
        )
        conn.commit()
        return {"status": "ok", "codigo": codigo, "message": "Pieza creada en catálogo maestro"}
    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
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


# --- Inventario PT (Google Sheet → columna Stock_PT_Almacen en Tbl_Maestro_Piezas) ---

_COL_SKU_CSV = 2  # C
_COL_STOCK_CSV = 8  # I


def _sheet_inventario_pt_export_url() -> str:
    sid = os.environ.get(
        "GOOGLE_SHEET_INVENTARIO_PT_ID",
        "1Y2e-JgPqasjqlKu_wTW5vFYHbyWO0ctTQk6QfwioBGc",
    ).strip()
    gid = os.environ.get("GOOGLE_SHEET_INVENTARIO_PT_GID", "1451349253").strip()
    return f"https://docs.google.com/spreadsheets/d/{sid}/export?format=csv&gid={gid}"


def _fetch_inventario_pt_csv(timeout: int = 90) -> str:
    url = _sheet_inventario_pt_export_url()
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "IndustrialManagerBackend/1.0 (stock-pt)"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        raise HTTPException(
            status_code=502,
            detail=f"No se pudo descargar la hoja (HTTP {e.code}). Revise ID/GID y permisos del enlace.",
        ) from e
    except urllib.error.URLError as e:
        raise HTTPException(
            status_code=502,
            detail=f"Error de red al leer Google Sheets: {e.reason!r}",
        ) from e


def _parse_inventario_pt_codigo_stock(csv_text: str) -> List[tuple[str, int]]:
    reader = csv.reader(io.StringIO(csv_text))
    rows = list(reader)
    start = 0
    for i, row in enumerate(rows):
        if len(row) > _COL_SKU_CSV and row[_COL_SKU_CSV].strip().upper() == "SKU":
            start = i + 1
            break
    out: List[tuple[str, int]] = []
    for row in rows[start:]:
        if len(row) <= max(_COL_SKU_CSV, _COL_STOCK_CSV):
            continue
        cod = row[_COL_SKU_CSV].strip()
        if not cod or cod.upper() == "SKU":
            continue
        raw = row[_COL_STOCK_CSV].strip()
        try:
            stock = int(float(raw.replace(",", "")))
        except (TypeError, ValueError):
            continue
        out.append((cod, stock))
    return out


def _ensure_maestro_stock_pt_columns(cursor) -> None:
    for name, ddl in (
        ("Stock_PT_Almacen", "INT NOT NULL CONSTRAINT DF_Tbl_Maestro_Piezas_Stock_PT_Almacen DEFAULT (0)"),
        ("Stock_PT_Almacen_SyncAt", "DATETIME2(0) NULL"),
    ):
        try:
            cursor.execute(f"SELECT [{name}] FROM dbo.Tbl_Maestro_Piezas WHERE 1=0")
        except Exception:
            cursor.execute(f"ALTER TABLE dbo.Tbl_Maestro_Piezas ADD [{name}] {ddl}")
    # Backfill defensivo para instalaciones existentes con NULL.
    cursor.execute(
        """
        UPDATE dbo.Tbl_Maestro_Piezas
        SET Stock_PT_Almacen = 0
        WHERE Stock_PT_Almacen IS NULL
        """
    )


@router.post("/api/catalog/stock-pt/sync")
def sync_stock_pt_desde_google_sheet():
    """
    Lee CSV público de la hoja Inventario, actualiza Stock_PT_Almacen y fecha de sync
    solo donde Codigo_Pieza coincide exactamente.
    """
    csv_text = _fetch_inventario_pt_csv()
    pairs = _parse_inventario_pt_codigo_stock(csv_text)
    if not pairs:
        raise HTTPException(
            status_code=400,
            detail="No se obtuvieron filas SKU/Stock del CSV. Revise formato de la hoja.",
        )

    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        _ensure_maestro_stock_pt_columns(cursor)
        conn.commit()
    except Exception:
        conn.rollback()
        raise HTTPException(
            status_code=500,
            detail="No se pudieron asegurar columnas Stock_PT_* en Tbl_Maestro_Piezas",
        )
    try:
        updated = 0
        # Base para cálculos: todo catálogo inicia en 0 y luego se sobreescribe
        # con lo que exista en la hoja.
        cursor.execute(
            """
            UPDATE dbo.Tbl_Maestro_Piezas
            SET Stock_PT_Almacen = 0, Stock_PT_Almacen_SyncAt = SYSUTCDATETIME()
            """
        )
        for codigo, stock in pairs:
            cursor.execute(
                """
                UPDATE dbo.Tbl_Maestro_Piezas
                SET Stock_PT_Almacen = ?, Stock_PT_Almacen_SyncAt = SYSUTCDATETIME()
                WHERE Codigo_Pieza = ?
                """,
                (stock, codigo),
            )
            try:
                rc = cursor.rowcount
            except Exception:
                rc = 0
            if rc and rc > 0:
                updated += 1
        conn.commit()
        return {
            "status": "ok",
            "filas_hoja": len(pairs),
            "registros_catalogo_actualizados": updated,
        }
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.get("/api/catalog/stock-pt/orphans")
def list_inventario_pt_sin_catalogo():
    """
    Códigos en la hoja (SKU con stock numérico) que no existen en Tbl_Maestro_Piezas
    (comparación sin distinguir mayúsculas).
    """
    csv_text = _fetch_inventario_pt_csv()
    pairs = _parse_inventario_pt_codigo_stock(csv_text)
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("SELECT Codigo_Pieza FROM dbo.Tbl_Maestro_Piezas")
        rows = cursor.fetchall()
        catalog_upper = {
            str(r[0]).strip().upper()
            for r in rows
            if r is not None and r[0] is not None and str(r[0]).strip()
        }
        items: List[Dict[str, Any]] = []
        for codigo, stock in pairs:
            if stock <= 0:
                continue
            if codigo.upper() not in catalog_upper:
                items.append({"codigo": codigo, "stock": stock})
        items.sort(key=lambda x: (x["codigo"] or "").upper())
        return {"count": len(items), "items": items}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

