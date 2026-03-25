"""API router: analytics."""
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

@router.get("/api/analytics/dashboard/{id_revision}")
def get_analytics_dashboard(id_revision: str, exclude_ids: Optional[str] = None):
    """Obtiene métricas clave para el Dashboard de Analytics (Soporta 'global' o ID numérico).
    exclude_ids: cadena CSV de IDs de revisión a excluir del cálculo global.
    AUDITADO (sin riesgo de producto cartesiano): las 4 sub-consultas (top_piezas,
    distribucion_material, salud_cad, distribucion_ensambles) sólo cruzan
    BOM_Estructura → Ensambles → Estaciones → Maestro_Piezas.
    No hay JOIN a Tbl_Clientes_Configuracion en ninguna de ellas."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # Parsear lista de exclusión (CSV de enteros)
        excl_list: list[int] = []
        if exclude_ids:
            try:
                excl_list = [int(x.strip()) for x in exclude_ids.split(',') if x.strip()]
            except ValueError:
                pass  # IDs malformados → se ignoran silenciosamente
        excl_clause = (
            f"AND ES.ID_Revision NOT IN ({','.join(str(i) for i in excl_list)})"
            if excl_list else ""
        )

        # Lógica dinámica: Si es 'global' se saltan los filtros de revisión
        where_clause = ""
        where_clause_salud = ""
        if id_revision != 'global':
            try:
                id_int = int(id_revision)
                # Filtro para omitir piezas incompletas en métricas a nivel proyecto
                # Métricas de material: sólo columna SQL Material (sin fallback a Descripcion).
                where_clause = f"""WHERE ES.ID_Revision = {id_int} 
                    AND (
                        NULLIF(LTRIM(RTRIM(M.Material)), '') IS NOT NULL
                        AND (
                            TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Area_CAD, ' mm^2', ''), ',', ''), ' ', ''), '-', '') AS FLOAT) > 0 
                            OR TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Largo_CAD, ' mm', ''), ',', ''), ' ', ''), '-', '') AS FLOAT) > 0 
                            OR (TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Largo_CAD, ' mm', ''), ',', ''), ' ', ''), '-', '') AS FLOAT) * TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Ancho_CAD, ' mm', ''), ',', ''), ' ', ''), '-', '') AS FLOAT)) > 0
                        )
                    ) {excl_clause}"""
                where_clause_salud = f"WHERE ES.ID_Revision = {id_int} {excl_clause}"
            except ValueError:
                raise HTTPException(status_code=400, detail="ID de revisión inválido")
        else:
            # Modo global: solo aplicar exclusiones si hay alguna
            if excl_list:
                where_clause      = f"WHERE 1=1 {excl_clause}"
                where_clause_salud = f"WHERE 1=1 {excl_clause}"

        # 1. Top 10 Piezas
        cursor.execute(f"""
            SELECT TOP 10 E.Codigo_Pieza, ISNULL(SUM(E.Cantidad), 0) AS Total_Piezas
            FROM Tbl_BOM_Estructura E
            JOIN Tbl_Ensambles EN ON E.ID_Ensamble = EN.ID_Ensamble
            JOIN Tbl_Estaciones ES ON EN.ID_Estacion = ES.ID_Estacion
            JOIN Tbl_Maestro_Piezas M ON E.Codigo_Pieza = M.Codigo_Pieza
            {where_clause}
            GROUP BY E.Codigo_Pieza
            ORDER BY Total_Piezas DESC
        """)
        top_piezas = [{"Codigo_Pieza": r.Codigo_Pieza, "Total_Piezas": float(r.Total_Piezas or 0)} for r in cursor.fetchall()]

        # 2. Distribución de Materiales (m2)
        cursor.execute(f"""
            WITH PiezasBase AS (
                SELECT 
                    COALESCE(NULLIF(LTRIM(RTRIM(M.Material)), ''), 'FALTA ASIGNAR EN CAD') AS MaterialLimpio,
                    E.Cantidad,
                    TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Largo_CAD, ' mm', ''), ',', ''), ' ', ''), '-', '') AS FLOAT) AS LargoLimpio,
                    TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Ancho_CAD, ' mm', ''), ',', ''), ' ', ''), '-', '') AS FLOAT) AS AnchoLimpio,
                    TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Area_CAD, ' mm^2', ''), ',', ''), ' ', ''), '-', '') AS FLOAT) AS AreaLimpia
                FROM Tbl_BOM_Estructura E
                JOIN Tbl_Ensambles EN ON E.ID_Ensamble = EN.ID_Ensamble
                JOIN Tbl_Estaciones ES ON EN.ID_Estacion = ES.ID_Estacion
                JOIN Tbl_Maestro_Piezas M ON E.Codigo_Pieza = M.Codigo_Pieza
                {where_clause_salud if id_revision != 'global' else ""}
            )
            SELECT 
                MaterialLimpio AS Material,
                ISNULL(SUM(Cantidad * ISNULL(NULLIF(AreaLimpia, 0), (ISNULL(LargoLimpio, 0) * ISNULL(AnchoLimpio, 0)))) / 1000000.0, 0) AS Total_m2
            FROM PiezasBase
            WHERE MaterialLimpio != 'FALTA ASIGNAR EN CAD'
            GROUP BY MaterialLimpio
            ORDER BY Total_m2 DESC
        """)
        distribucion = [{"Material": r.Material, "Total_m2": float(r.Total_m2 or 0)} for r in cursor.fetchall()]

        # 3. Salud CAD (Valid vs Orphan)
        cursor.execute(f"""
            WITH PiezasBase AS (
                SELECT 
                    COALESCE(NULLIF(LTRIM(RTRIM(M.Material)), ''), 'FALTA ASIGNAR EN CAD') AS MaterialLimpio,
                    TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Largo_CAD, ' mm', ''), ',', ''), ' ', ''), '-', '') AS FLOAT) AS LargoLimpio,
                    TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Ancho_CAD, ' mm', ''), ',', ''), ' ', ''), '-', '') AS FLOAT) AS AnchoLimpio,
                    TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Area_CAD, ' mm^2', ''), ',', ''), ' ', ''), '-', '') AS FLOAT) AS AreaLimpia
                FROM Tbl_BOM_Estructura E
                JOIN Tbl_Ensambles EN ON E.ID_Ensamble = EN.ID_Ensamble
                JOIN Tbl_Estaciones ES ON EN.ID_Estacion = ES.ID_Estacion
                JOIN Tbl_Maestro_Piezas M ON E.Codigo_Pieza = M.Codigo_Pieza
                {where_clause_salud if id_revision != 'global' else ""}
            )
            SELECT 
                SUM(CASE WHEN MaterialLimpio != 'FALTA ASIGNAR EN CAD' AND (ISNULL(AreaLimpia, 0) > 0 OR ISNULL(LargoLimpio, 0) > 0 OR (ISNULL(LargoLimpio, 0) * ISNULL(AnchoLimpio, 0)) > 0) THEN 1 ELSE 0 END) AS Piezas_Validas,
                SUM(CASE WHEN MaterialLimpio = 'FALTA ASIGNAR EN CAD' OR (ISNULL(AreaLimpia, 0) = 0 AND ISNULL(LargoLimpio, 0) = 0 AND (ISNULL(LargoLimpio, 0) * ISNULL(AnchoLimpio, 0)) = 0) THEN 1 ELSE 0 END) AS Piezas_Huerfanas
            FROM PiezasBase
        """)
        salud = cursor.fetchone()
        salud_cad = {
            "Validas": int(salud.Piezas_Validas or 0) if salud else 0,
            "Huerfanas": int(salud.Piezas_Huerfanas or 0) if salud else 0
        }

        # 4. Distribución por Ensamble (Complejidad por Concentración de Piezas)
        # Si es global, usamos LEFT JOIN para no perder ensambles sin estación
        estaciones_join = "JOIN Tbl_Estaciones ES ON EN.ID_Estacion = ES.ID_Estacion" if id_revision != 'global' else "LEFT JOIN Tbl_Estaciones ES ON EN.ID_Estacion = ES.ID_Estacion"
        
        cursor.execute(f"""
            SELECT TOP 5 EN.Nombre_Ensamble, ISNULL(SUM(E.Cantidad), 0) AS Total_Piezas
            FROM Tbl_BOM_Estructura E
            JOIN Tbl_Ensambles EN ON E.ID_Ensamble = EN.ID_Ensamble
            {estaciones_join}
            JOIN Tbl_Maestro_Piezas M ON E.Codigo_Pieza = M.Codigo_Pieza
            {where_clause}
            GROUP BY EN.Nombre_Ensamble
            ORDER BY Total_Piezas DESC
        """)
        rows_ens = cursor.fetchall()
        
        # Procesar para agrupar en "Otros" los que no son Top 5
        ensambles = []
        top_ids = [r.Nombre_Ensamble for r in rows_ens]
        for r in rows_ens:
            ensambles.append({"Ensamble": r.Nombre_Ensamble, "Total_Piezas": float(r.Total_Piezas or 0)})
            
        if top_ids:
            # Calcular "Otros"
            cursor.execute(f"""
                SELECT ISNULL(SUM(E.Cantidad), 0) AS Otros_Total
                FROM Tbl_BOM_Estructura E
                JOIN Tbl_Ensambles EN ON E.ID_Ensamble = EN.ID_Ensamble
                {estaciones_join}
                JOIN Tbl_Maestro_Piezas M ON E.Codigo_Pieza = M.Codigo_Pieza
                {where_clause}
                {"AND" if where_clause else "WHERE"} EN.Nombre_Ensamble NOT IN ({','.join(['?' for _ in top_ids])})
            """, top_ids)
            row_otros = cursor.fetchone()
            if row_otros and row_otros.Otros_Total and row_otros.Otros_Total > 0:
                ensambles.append({"Ensamble": "OTROS", "Total_Piezas": float(row_otros.Otros_Total)})

        sugerencia_texto = ""
        if rows_ens and rows_ens[0].Nombre_Ensamble:
            sugerencia_texto = f"Sugerencia: El ensamble '{rows_ens[0].Nombre_Ensamble}' concentra la mayoría de piezas"

        # 5. Conteo de versiones de ingeniería (tabla maestra; coherente con Lobby/KPI)
        cursor.execute("SELECT COUNT(*) AS Total FROM Tbl_Versiones_Ingenieria")
        row_v2 = cursor.fetchone()
        total_versiones = int(row_v2[0] if row_v2 is not None else 0)

        # 6. Conteo de unidades (VINs) — global o por revisión
        if id_revision == 'global':
            if excl_list:
                excl_ph = ','.join(str(i) for i in excl_list)
                cursor.execute(
                    f"SELECT COUNT(*) AS Total FROM Tbl_Unidades_Fisicas "
                    f"WHERE ID_Revision NOT IN ({excl_ph}) OR ID_Revision IS NULL"
                )
            else:
                cursor.execute("SELECT COUNT(*) AS Total FROM Tbl_Unidades_Fisicas")
        else:
            cursor.execute(
                "SELECT COUNT(*) AS Total FROM Tbl_Unidades_Fisicas WHERE ID_Revision = ?",
                (id_int,),
            )
        row_u2 = cursor.fetchone()
        total_unidades = int(row_u2.Total or 0) if row_u2 else 0

        # 7. Referencia de volumen físico (tablas; independiente de filtros de gráficos)
        #    total_lineas_bom_estructura = filas en Tbl_BOM_Estructura (0 tras purga_fantasmas.sql)
        #    total_registros_maestro_piezas = filas en Tbl_Maestro_Piezas (no se purga con BOM)
        try:
            cursor.execute("SELECT COUNT(*) AS Total FROM Tbl_BOM_Estructura")
            total_lineas_bom_estructura = _int_from_count_row(cursor.fetchone())
        except Exception:
            total_lineas_bom_estructura = 0
        try:
            cursor.execute("SELECT COUNT(*) AS Total FROM Tbl_Maestro_Piezas")
            total_registros_maestro_piezas = _int_from_count_row(cursor.fetchone())
        except Exception:
            total_registros_maestro_piezas = 0

        return {
            "top_piezas":            top_piezas,
            "distribucion_material": distribucion,
            "salud_cad":             salud_cad,
            "distribucion_ensambles": ensambles,
            "sugerencia":            sugerencia_texto,
            "total_versiones":       total_versiones,
            "total_unidades":        total_unidades,
            "total_lineas_bom_estructura": total_lineas_bom_estructura,
            "total_registros_maestro_piezas": total_registros_maestro_piezas,
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

