"""API router: root."""
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

router = APIRouter()

@router.get("/")
def read_root():
    return {"status": "online", "message": "Servidor Industrial Manager Activo"}

@router.get("/api/health")
def health_check():
    """Un simple healthcheck de base de datos sin carga."""
    try:
        conn = get_db_connection()
        conn.close()
        return {"status": "ok", "db_connected": True}
    except Exception as e:
        return {"status": "error", "db_connected": False, "detail": str(e)}

@router.get("/api/dashboard/kpi")
def get_dashboard_kpis():
    """Calcula indicadores clave (KPI) para el lobby principal.

    - **total_piezas**: query exacta `SELECT COUNT(*) FROM Tbl_Maestro_Piezas` (única tabla oficial del catálogo).
    - **total_lineas_bom**: `COUNT(*)` en **`Tbl_BOM_Estructura`** (filas en listas BOM; 0 tras purga de fantasmas).
    - **salud_cad**: % sobre líneas BOM enlazadas a maestro (si no hay líneas → 0 %).
    """
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        salud_cad = 0.0
        # 1. Salud CAD (no debe tumbar el endpoint si BOM vacío o error SQL puntual)
        try:
            cursor.execute("""
                WITH PiezasBase AS (
                    SELECT 
                        COALESCE(NULLIF(LTRIM(RTRIM(M.Material)), ''), NULLIF(LTRIM(RTRIM(M.Descripcion)), ''), 'FALTA ASIGNAR EN CAD') AS MaterialLimpio,
                        TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Largo_CAD, ' mm', ''), ',', ''), ' ', ''), '-', '') AS FLOAT) AS LargoLimpio,
                        TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Ancho_CAD, ' mm', ''), ',', ''), ' ', ''), '-', '') AS FLOAT) AS AnchoLimpio,
                        TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Area_CAD, ' mm^2', ''), ',', ''), ' ', ''), '-', '') AS FLOAT) AS AreaLimpia
                    FROM Tbl_BOM_Estructura E
                    JOIN Tbl_Ensambles EN ON E.ID_Ensamble = EN.ID_Ensamble
                    JOIN Tbl_Estaciones ES ON EN.ID_Estacion = ES.ID_Estacion
                    JOIN Tbl_Maestro_Piezas M ON E.Codigo_Pieza = M.Codigo_Pieza
                    -- Excluir piezas comerciales del calculo de salud CAD
                    WHERE (LOWER(ISNULL(CAST(M.Material AS NVARCHAR(200)), '')) NOT LIKE '%comercial%')
                )
                SELECT 
                    SUM(CASE WHEN MaterialLimpio != 'FALTA ASIGNAR EN CAD' AND (ISNULL(AreaLimpia, 0) > 0 OR ISNULL(LargoLimpio, 0) > 0 OR (ISNULL(LargoLimpio, 0) * ISNULL(AnchoLimpio, 0)) > 0) THEN 1 ELSE 0 END) AS Piezas_Validas,
                    SUM(CASE WHEN MaterialLimpio = 'FALTA ASIGNAR EN CAD' OR (ISNULL(AreaLimpia, 0) = 0 AND ISNULL(LargoLimpio, 0) = 0 AND (ISNULL(LargoLimpio, 0) * ISNULL(AnchoLimpio, 0)) = 0) THEN 1 ELSE 0 END) AS Piezas_Huerfanas
                FROM PiezasBase
            """)
            row = cursor.fetchone()
            if row is not None:
                pv = getattr(row, "Piezas_Validas", None)
                ph = getattr(row, "Piezas_Huerfanas", None)
                if pv is None:
                    try:
                        pv = row[0]
                    except (IndexError, TypeError):
                        pv = 0
                if ph is None:
                    try:
                        ph = row[1]
                    except (IndexError, TypeError):
                        ph = 0
                validas = int(pv or 0)
                huerfanas = int(ph or 0)
                total_bom_lineas = validas + huerfanas
                salud_cad = (validas / total_bom_lineas * 100.0) if total_bom_lineas > 0 else 0.0
        except Exception as ex_salud:
            print(f"[KPI] salud_cad omitida (fallback 0%): {ex_salud}")
            salud_cad = 0.0

        # 2. total_piezas — catálogo maestro único: Tbl_Maestro_Piezas (excluye comerciales)
        total_piezas_maestro = 0
        try:
            cursor.execute("""
                SELECT COUNT(*) FROM Tbl_Maestro_Piezas
                WHERE (LOWER(ISNULL(CAST(Material AS NVARCHAR(200)), '')) NOT LIKE '%comercial%')
            """)
            total_piezas_maestro = _int_from_count_row(cursor.fetchone())
        except Exception as ex_m:
            print(f"[KPI] Tbl_Maestro_Piezas: {ex_m} → total_piezas=0.")
            total_piezas_maestro = 0

        # 2b. Filas en Tbl_BOM_Estructura (volumen listas BOM / posibles fantasmas antes de purga)
        total_lineas_bom = 0
        try:
            cursor.execute("SELECT COUNT(*) AS Total FROM Tbl_BOM_Estructura")
            total_lineas_bom = _int_from_count_row(cursor.fetchone())
        except Exception as ex_b:
            print(f"[KPI] Tbl_BOM_Estructura: {ex_b} → total_lineas_bom=0.")
            total_lineas_bom = 0

        # 3. Unidades físicas (VINs)
        try:
            cursor.execute("SELECT COUNT(*) AS Total FROM Tbl_Unidades_Fisicas")
            total_unidades = _int_from_count_row(cursor.fetchone())
        except Exception as ex_u:
            print(f"[KPI] total_unidades fallback 0: {ex_u}")
            total_unidades = 0

        # 4. Versiones de ingeniería
        try:
            cursor.execute("SELECT COUNT(*) AS Total FROM Tbl_Versiones_Ingenieria")
            total_versiones = _int_from_count_row(cursor.fetchone())
        except Exception as ex_v:
            print(f"[KPI] total_versiones fallback 0: {ex_v}")
            total_versiones = 0

        return {
            # Compat: total_piezas = maestro técnico (Lobby "Catálogo Maestro" = registros en Maestro_Piezas)
            "total_piezas": int(total_piezas_maestro),
            "total_lineas_bom": int(total_lineas_bom),
            "total_unidades": int(total_unidades),
            "total_versiones": int(total_versiones),
            "merma_configurada": 15,
            "salud_cad": round(float(salud_cad), 2),
        }
    finally:
        conn.close()

