"""API router: mrp."""
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

@router.get("/api/mrp/revisiones")
def get_mrp_revisiones():
    """Lista DISTINCT de revisiones para el selector del MRPII.
    Usa subconsulta con STRING_AGG para obtener los clientes afectados
    sin multiplicar filas por el JOIN a Tbl_Clientes_Configuracion."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("""
            SELECT
                R.ID_Revision,
                TR.Nombre_Tracto,
                TP.Nombre_Tipo,
                V.Nombre_Version,
                R.Numero_Revision,
                ISNULL(R.Estado, '') AS Estado,
                ISNULL(
                    (SELECT STRING_AGG(C.Nombre_Cliente, ', ')
                     FROM Tbl_Clientes_Configuracion C
                     WHERE C.ID_Version = V.ID_Version),
                    'Ingeniería Base (Sin clientes)'
                ) AS Clientes_Afectados
            FROM Tbl_BOM_Revisiones R
            JOIN Tbl_Versiones_Ingenieria V  ON R.ID_Version = V.ID_Version
            JOIN Tbl_Tipos_Proyecto      TP  ON V.ID_Tipo    = TP.ID_Tipo
            JOIN Tbl_Proyectos_Tracto    TR  ON TP.ID_Tracto = TR.ID_Tracto
            -- Solo revisiones Aprobadas en el selector MRPII.
            -- Las OBSOLETAS y Borradores no deben usarse para cálculo de materiales.
            WHERE R.Estado = 'Aprobada'
            ORDER BY TR.Nombre_Tracto, TP.Nombre_Tipo, V.Nombre_Version, R.Numero_Revision
        """)
        return [
            {
                "id_revision":         int(r.ID_Revision),
                "nombre_tracto":       r.Nombre_Tracto       or "",
                "nombre_tipo":         r.Nombre_Tipo         or "",
                "nombre_version":      r.Nombre_Version      or "",
                "numero_revision":     r.Numero_Revision,
                "estado":              r.Estado              or "",
                "clientes_afectados":  r.Clientes_Afectados  or "Ingeniería Base (Sin clientes)",
            }
            for r in cursor.fetchall()
        ]
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.get("/api/mrp/calculate/{id_revision}")
def calculate_mrp(id_revision: int):
    """Calcula la consolidación de compras (MRP) con filtrado estricto y diagnóstico de huérfanos.
    Separa los Componentes Comerciales del cálculo de placas/perfiles."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # ── CTE base compartida (reutilizada en las tres queries) ─────────────
        # PURGA REGLA ESPEJO: se eliminó M.Descripcion completamente.
        # Material se extrae ÚNICA y EXCLUSIVAMENTE de M.Material.
        # JOIN es LEFT JOIN para no perder piezas que aún no tienen CAD.
        _cte_base = """
        WITH PiezasBase AS (
            SELECT
                E.Codigo_Pieza,
                NULLIF(LTRIM(RTRIM(M.Material)), '')              AS MaterialOficialRaw,
                LTRIM(RTRIM(ISNULL(M.Material, '')))              AS Material_Trace,
                M.Espesor_Perfil_CAD,
                ISNULL(M.Stock_PT_Almacen, 0)                     AS Stock_PT_Almacen,
                M.Stock_PT_Almacen_SyncAt                         AS Stock_PT_Almacen_SyncAt,
                ISNULL(E.Cantidad, 0)                             AS Cantidad,
                COALESCE(
                    TRY_CAST(M.Largo_CAD AS FLOAT),
                    TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Largo_CAD,' mm',''),',',''),' ',''),'-','') AS FLOAT),
                    TRY_CAST(M.Largo_DXF AS FLOAT),
                    TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Largo_DXF,' mm',''),',',''),' ',''),'-','') AS FLOAT)
                ) AS LargoLimpio,
                COALESCE(
                    TRY_CAST(M.Ancho_CAD AS FLOAT),
                    TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Ancho_CAD,' mm',''),',',''),' ',''),'-','') AS FLOAT),
                    TRY_CAST(M.Ancho_DXF AS FLOAT),
                    TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Ancho_DXF,' mm',''),',',''),' ',''),'-','') AS FLOAT)
                ) AS AnchoLimpio,
                COALESCE(
                    TRY_CAST(M.Area_CAD AS FLOAT),
                    TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(M.Area_CAD,' mm^2',''),',',''),' ',''),'-','') AS FLOAT)
                ) AS AreaLimpia
            FROM Tbl_BOM_Estructura E
            JOIN Tbl_Ensambles   EN ON E.ID_Ensamble  = EN.ID_Ensamble
            JOIN Tbl_Estaciones  ES ON EN.ID_Estacion = ES.ID_Estacion
            LEFT JOIN Tbl_Maestro_Piezas M
                ON LTRIM(RTRIM(E.Codigo_Pieza)) = LTRIM(RTRIM(M.Codigo_Pieza))
            WHERE ES.ID_Revision = ?
        )
        """

        # ── 1. Materia Prima / Placas (excluye COMERCIAL) ────────────────────
        # Filtro COMERCIAL: solo por MaterialOficialRaw — sin fallback a Descripcion.
        # Espesor: ISNULL(CAST(...AS VARCHAR), 'N/A') para mostrar N/A limpio.
        query_mrp = _cte_base + """
        , BaseNoCommercial AS (
            SELECT *
            FROM PiezasBase
            WHERE MaterialOficialRaw IS NOT NULL
              AND UPPER(LTRIM(RTRIM(MaterialOficialRaw))) NOT LIKE '%COMERCIAL%'
        ),
        AggPerCode AS (
            SELECT
                LTRIM(RTRIM(MaterialOficialRaw))                            AS material_oficial,
                ISNULL(CAST(Espesor_Perfil_CAD AS VARCHAR(50)), 'N/A')      AS Calibre_Espesor,
                Codigo_Pieza,
                SUM(Cantidad)                                               AS Cantidad_Total_Piezas_Codigo,
                SUM(Cantidad * ISNULL(LargoLimpio, 0.0))                    AS Requerimiento_Longitud_mm_Codigo,
                SUM(Cantidad * ISNULL(NULLIF(AreaLimpia, 0),
                    (ISNULL(LargoLimpio, 0) * ISNULL(AnchoLimpio, 0))))     AS Requerimiento_Area_mm2_Codigo,
                MAX(ISNULL(Stock_PT_Almacen, 0))                            AS Stock_PT_Almacen_Codigo,
                MAX(Stock_PT_Almacen_SyncAt)                                AS Stock_PT_Almacen_SyncAt_Codigo
            FROM BaseNoCommercial
            GROUP BY
                LTRIM(RTRIM(MaterialOficialRaw)),
                ISNULL(CAST(Espesor_Perfil_CAD AS VARCHAR(50)), 'N/A'),
                Codigo_Pieza
        )
        SELECT
            material_oficial,
            Calibre_Espesor,
            SUM(Cantidad_Total_Piezas_Codigo)                           AS Cantidad_Total_Piezas,
            SUM(Requerimiento_Longitud_mm_Codigo)                       AS Requerimiento_Longitud_mm,
            SUM(Requerimiento_Area_mm2_Codigo)                          AS Requerimiento_Area_mm2,
            SUM(Stock_PT_Almacen_Codigo)                                AS Stock_Asociado_Estimado,
            MAX(Stock_PT_Almacen_SyncAt_Codigo)                         AS Stock_PT_Almacen_SyncAt
        FROM AggPerCode
        GROUP BY
            material_oficial,
            Calibre_Espesor
        ORDER BY
            material_oficial,
            Calibre_Espesor
        """
        cursor.execute(query_mrp, (id_revision,))
        rows_mrp = cursor.fetchall()

        mrp_calculado = []
        for r in rows_mrp:
            raw_mo = getattr(r, "material_oficial", None) or getattr(
                r, "Material_Oficial", None
            ) or ""
            mat_of = str(raw_mo).strip()
            material_upper = mat_of.upper()
            req_area_mm2   = float(r.Requerimiento_Area_mm2)
            req_long_mm    = float(r.Requerimiento_Longitud_mm)
            stock_asociado_estimado = float(getattr(r, "Stock_Asociado_Estimado", 0) or 0)
            cantidad_total_piezas = float(r.Cantidad_Total_Piezas)
            brecha_estim = max(0.0, cantidad_total_piezas - stock_asociado_estimado)
            sync_at = getattr(r, "Stock_PT_Almacen_SyncAt", None)

            sugerencia   = "N/A"
            scrap_factor = 1.15

            if req_area_mm2 <= 0 and req_long_mm <= 0:
                mrp_calculado.append({
                    "material_oficial":      mat_of,
                    "Material":              mat_of,
                    "Calibre_Espesor":       r.Calibre_Espesor,
                    "Cantidad_Total_Piezas": cantidad_total_piezas,
                    "Requerimiento_Area_mm2":    req_area_mm2,
                    "Requerimiento_Longitud_mm": req_long_mm,
                    "Sugerencia_Compra":     "Pendiente: cargar dimensiones CAD/DXF",
                    "Stock_Asociado_Estimado": stock_asociado_estimado,
                    "Brecha_Estimada": brecha_estim,
                    "es_estimado": True,
                    "Stock_PT_Almacen_SyncAt": sync_at.isoformat() if sync_at else None,
                })
                continue

            if any(x in material_upper for x in ['PERFIL', 'TUBO', 'BARRA', 'SOLERA', 'ANGULO', 'CANAL', 'HSS']):
                metros_totales = req_long_mm / 1000.0
                tramos_std = 12.0 if 'HSS' in material_upper else 6.0
                cantidad_tramos = math.ceil((metros_totales / tramos_std) * scrap_factor)
                sugerencia = f"Comprar {cantidad_tramos} Tramos de {int(tramos_std)} MT"
            else:
                m2_totales   = req_area_mm2 / 1_000_000.0
                area_placa_m2 = 3.72
                t_str         = "4'X10'"
                if   "8'X20'" in material_upper: area_placa_m2, t_str = 14.86, "8'X20'"
                elif "8'X30'" in material_upper: area_placa_m2, t_str = 22.30, "8'X30'"
                elif "5'X24'" in material_upper: area_placa_m2, t_str = 11.15, "5'X24'"
                cantidad_placas = math.ceil((m2_totales / area_placa_m2) * scrap_factor)
                sugerencia = f"Comprar {cantidad_placas} Placas de {t_str}"

            mrp_calculado.append({
                "material_oficial":      mat_of,
                "Material":              mat_of,
                "Calibre_Espesor":       r.Calibre_Espesor,
                "Cantidad_Total_Piezas": cantidad_total_piezas,
                "Requerimiento_Area_mm2":    req_area_mm2,
                "Requerimiento_Longitud_mm": req_long_mm,
                "Sugerencia_Compra":     sugerencia,
                "Stock_Asociado_Estimado": stock_asociado_estimado,
                "Brecha_Estimada": brecha_estim,
                "es_estimado": True,
                "Stock_PT_Almacen_SyncAt": sync_at.isoformat() if sync_at else None,
            })

        # ── 2. Componentes Comerciales (solo cantidad, sin placas) ─────────────
        # PURGA REGLA ESPEJO: filtro y agrupación SOLO por MaterialOficialRaw.
        # El marcador 'COMERCIAL' debe estar en la columna Material, no en Descripcion.
        query_comerciales = _cte_base + """
        SELECT
            Codigo_Pieza,
            LTRIM(RTRIM(ISNULL(Material_Trace, '')))  AS Material_Comercial,
            SUM(Cantidad)                              AS Cantidad_Total,
            MAX(ISNULL(Stock_PT_Almacen, 0))          AS Stock_PT_Almacen,
            MAX(Stock_PT_Almacen_SyncAt)              AS Stock_PT_Almacen_SyncAt
        FROM PiezasBase
        WHERE UPPER(LTRIM(RTRIM(ISNULL(Material_Trace, '')))) LIKE '%COMERCIAL%'
        GROUP BY Codigo_Pieza, LTRIM(RTRIM(ISNULL(Material_Trace, '')))
        ORDER BY Material_Comercial, Codigo_Pieza
        """
        cursor.execute(query_comerciales, (id_revision,))
        rows_com = cursor.fetchall()

        componentes_comerciales = []
        for r in rows_com:
            demanda = float(r.Cantidad_Total or 0)
            stock = float(getattr(r, "Stock_PT_Almacen", 0) or 0)
            faltante = max(0.0, demanda - stock)
            cobertura_pct = min(100.0, (stock / demanda) * 100.0) if demanda > 0 else 100.0
            sync_at = getattr(r, "Stock_PT_Almacen_SyncAt", None)
            componentes_comerciales.append(
                {
                    "Codigo_Pieza": r.Codigo_Pieza,
                    "Descripcion": r.Material_Comercial,  # campo renombrado; UI compat
                    "Cantidad_Total": demanda,
                    "Stock_PT_Almacen": stock,
                    "Cantidad_Faltante": faltante,
                    "Cobertura_Pct": cobertura_pct,
                    "Stock_PT_Almacen_SyncAt": sync_at.isoformat() if sync_at else None,
                }
            )

        # ── 3. Piezas sin medidas / sin material (huérfanas) ─────────────────
        # PURGA REGLA ESPEJO: huérfano = Material vacío, NULL o 'POR DEFINIR'.
        query_orphans = _cte_base + """
        SELECT
            Codigo_Pieza,
            ISNULL((SELECT TOP 1 Nombre_Ensamble
                    FROM Tbl_Ensambles EN2
                    JOIN Tbl_BOM_Estructura E2 ON E2.ID_Ensamble = EN2.ID_Ensamble
                    WHERE E2.Codigo_Pieza = PiezasBase.Codigo_Pieza), 'N/A') AS Nombre_Ensamble,
            ISNULL(Material_Trace, '')  AS Material,
            Cantidad,
            CASE
                WHEN MaterialOficialRaw IS NULL
                     AND (ISNULL(AreaLimpia,0)=0 AND ISNULL(LargoLimpio,0)=0
                          AND (ISNULL(LargoLimpio,0)*ISNULL(AnchoLimpio,0))=0)
                     THEN 'Sin Material ni Dimensiones'
                WHEN MaterialOficialRaw IS NULL THEN 'Falta Asignar Material'
                ELSE 'Sin Dimensiones CAD'
            END AS Motivo_Rechazo
        FROM PiezasBase
        WHERE MaterialOficialRaw IS NULL
           OR ISNULL(AreaLimpia,0) + ISNULL(LargoLimpio,0) = 0
        """
        cursor.execute(query_orphans, (id_revision,))
        rows_orphans = cursor.fetchall()

        piezas_sin_medidas = [
            {
                "Codigo_Pieza":   r.Codigo_Pieza,
                "Nombre_Ensamble": r.Nombre_Ensamble,
                "Material":        r.Material,
                "Cantidad":        float(r.Cantidad),
                "Motivo_Rechazo":  r.Motivo_Rechazo,
            }
            for r in rows_orphans
        ]

        # 4. Resumen de stock para widgets inferiores/laterales (MRP)
        demanda_total_com = sum(float(x.get("Cantidad_Total", 0) or 0) for x in componentes_comerciales)
        stock_total_com = sum(float(x.get("Stock_PT_Almacen", 0) or 0) for x in componentes_comerciales)
        faltante_total_com = sum(float(x.get("Cantidad_Faltante", 0) or 0) for x in componentes_comerciales)
        lineas_faltante_com = sum(1 for x in componentes_comerciales if float(x.get("Cantidad_Faltante", 0) or 0) > 0)

        demanda_total_mp = sum(float(x.get("Cantidad_Total_Piezas", 0) or 0) for x in mrp_calculado)
        stock_total_mp = sum(float(x.get("Stock_Asociado_Estimado", 0) or 0) for x in mrp_calculado)
        brecha_total_mp = sum(float(x.get("Brecha_Estimada", 0) or 0) for x in mrp_calculado)
        lineas_brecha_mp = sum(1 for x in mrp_calculado if float(x.get("Brecha_Estimada", 0) or 0) > 0)

        ultima_sync_candidates = [
            x.get("Stock_PT_Almacen_SyncAt")
            for x in componentes_comerciales + mrp_calculado
            if x.get("Stock_PT_Almacen_SyncAt")
        ]
        ultima_sync_stock_pt = max(ultima_sync_candidates) if ultima_sync_candidates else None

        return {
            "mrp_calculado":          mrp_calculado,
            "componentes_comerciales": componentes_comerciales,
            "piezas_sin_medidas":     piezas_sin_medidas,
            "resumen_stock_mrp": {
                "comerciales": {
                    "demanda_total_unidades": demanda_total_com,
                    "stock_total_unidades": stock_total_com,
                    "faltante_total_unidades": faltante_total_com,
                    "lineas_con_faltante": lineas_faltante_com,
                },
                "materia_prima_estimado": {
                    "demanda_total_unidades": demanda_total_mp,
                    "stock_asociado_total_unidades": stock_total_mp,
                    "brecha_total_unidades": brecha_total_mp,
                    "lineas_con_brecha": lineas_brecha_mp,
                    "es_estimado": True,
                },
                "ultima_sync_stock_pt": ultima_sync_stock_pt,
            },
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

