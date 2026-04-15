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


class MrpOptimizarUsoMaterialPayload(BaseModel):
    material_oficial: str = Field(..., min_length=1)
    calibre_espesor: Optional[str] = None
    cantidad_disponible: float = Field(..., gt=0)
    id_revisiones: List[int] = Field(..., min_items=1)
    excluir_si_stock_gt_cero: bool = False
    # Retazo/chapa: medidas en mm. Si ambos > 0, cantidad_disponible = nº de piezas de ese tamaño
    # y el área útil es cantidad * largo * ancho; solo se sugieren piezas que caben (con giro).
    largo_materia_prima_mm: Optional[float] = None
    ancho_materia_prima_mm: Optional[float] = None


def _pieza_cabe_en_placa(
    largo_pieza_mm: float,
    ancho_pieza_mm: float,
    largo_placa_mm: float,
    ancho_placa_mm: float,
) -> bool:
    """Comprueba si la silueta de la pieza cabe en la placa/retazo (eje alineado, rotación 90°)."""
    lp = float(largo_pieza_mm or 0)
    wp = float(ancho_pieza_mm or 0)
    lp_stock = float(largo_placa_mm or 0)
    wp_stock = float(ancho_placa_mm or 0)
    if lp_stock <= 0 or wp_stock <= 0:
        return False
    # Perfil/barra: solo largo útil
    if lp > 0 and wp <= 0:
        return lp <= max(lp_stock, wp_stock)
    if wp > 0 and lp <= 0:
        return wp <= max(lp_stock, wp_stock)
    if lp <= 0 or wp <= 0:
        return False
    return (lp <= lp_stock and wp <= wp_stock) or (lp <= wp_stock and wp <= lp_stock)


def _colocar_rectangulo_en_huecos(
    huecos: List[tuple[float, float]],
    largo_pieza: float,
    ancho_pieza: float,
) -> bool:
    """Coloca una pieza en la lista de huecos con split simple (guillotina) para nesting rápido."""
    mejor_idx = -1
    mejor_orient: Optional[tuple[float, float]] = None
    mejor_desperdicio: Optional[float] = None
    for i, (hw, hh) in enumerate(huecos):
        for pw, ph in ((largo_pieza, ancho_pieza), (ancho_pieza, largo_pieza)):
            if pw <= 0 or ph <= 0:
                continue
            if pw <= hw and ph <= hh:
                desperdicio = (hw * hh) - (pw * ph)
                if mejor_desperdicio is None or desperdicio < mejor_desperdicio:
                    mejor_desperdicio = desperdicio
                    mejor_idx = i
                    mejor_orient = (pw, ph)
    if mejor_idx < 0 or mejor_orient is None:
        return False
    hw, hh = huecos.pop(mejor_idx)
    pw, ph = mejor_orient
    # Split guillotina: derecha + inferior. Es rápido y estable para UI en tiempo real.
    right_w = hw - pw
    bottom_h = hh - ph
    if right_w > 0:
        huecos.append((right_w, ph))
    if bottom_h > 0:
        huecos.append((hw, bottom_h))
    huecos.sort(key=lambda r: r[0] * r[1], reverse=True)
    return True


def _simular_nesting_ligero(
    candidatos: List[Dict[str, Any]],
    largo_placa_mm: float,
    ancho_placa_mm: float,
    cantidad_placas: int,
    warnings: List[str],
) -> Dict[str, Any]:
    """
    Heurística rápida tipo nesting:
    - Simulación por placa con huecos rectangulares (guillotina).
    - Prioriza piezas de mayor área para mejorar aprovechamiento.
    - Limita iteraciones para proteger tiempo de respuesta.
    """
    pendientes: Dict[str, int] = {}
    por_codigo: Dict[str, Dict[str, Any]] = {}
    for c in candidatos:
        cod = str(c.get("codigo_pieza") or "").strip()
        if not cod:
            continue
        por_codigo[cod] = c
        pendientes[cod] = max(0, int(math.floor(float(c.get("demanda_neta") or 0))))
    orden_codigos = sorted(
        por_codigo.keys(),
        key=lambda k: float(por_codigo[k].get("area_unidad_nesting_mm2") or 0),
        reverse=True,
    )
    colocadas: Dict[str, int] = {k: 0 for k in orden_codigos}
    max_colocaciones = 8000
    pasos = 0
    for _ in range(max(0, int(cantidad_placas))):
        huecos: List[tuple[float, float]] = [(float(largo_placa_mm), float(ancho_placa_mm))]
        progreso = True
        while progreso and pasos < max_colocaciones:
            progreso = False
            for cod in orden_codigos:
                if pendientes.get(cod, 0) <= 0:
                    continue
                c = por_codigo[cod]
                l = float(c.get("largo_unidad_mm") or 0)
                a = float(c.get("ancho_unidad_mm") or 0)
                if l <= 0 or a <= 0:
                    continue
                if _colocar_rectangulo_en_huecos(huecos, l, a):
                    pendientes[cod] = max(0, pendientes[cod] - 1)
                    colocadas[cod] = colocadas.get(cod, 0) + 1
                    pasos += 1
                    progreso = True
                if pasos >= max_colocaciones:
                    break
    if pasos >= max_colocaciones:
        warnings.append("Nesting parcial: se alcanzó el límite de iteraciones para mantener respuesta rápida.")
    consumido_mm2 = 0.0
    for cod, qty in colocadas.items():
        if qty <= 0:
            continue
        area_u = float(por_codigo[cod].get("area_unidad_nesting_mm2") or 0)
        consumido_mm2 += qty * area_u
    return {"colocadas": colocadas, "consumido_mm2": consumido_mm2}

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


@router.post("/api/mrp/optimizar_uso_material")
def optimizar_uso_material(payload: MrpOptimizarUsoMaterialPayload):
    revisiones = sorted({int(x) for x in payload.id_revisiones if int(x) > 0})
    if not revisiones:
        raise HTTPException(status_code=400, detail="id_revisiones inválido")
    material = (payload.material_oficial or "").strip()
    if not material:
        raise HTTPException(status_code=400, detail="material_oficial es obligatorio")
    calibre = (payload.calibre_espesor or "").strip()
    disponible = float(payload.cantidad_disponible or 0)
    if disponible <= 0:
        raise HTTPException(status_code=400, detail="cantidad_disponible debe ser mayor a 0")
    lm = float(payload.largo_materia_prima_mm or 0)
    wm = float(payload.ancho_materia_prima_mm or 0)
    if (lm > 0) != (wm > 0):
        raise HTTPException(
            status_code=400,
            detail="Indique largo y ancho de la materia prima (mm), o deje ambos vacíos para usar solo superficie total (mm²).",
        )
    usa_medidas_placa = lm > 0 and wm > 0
    if usa_medidas_placa:
        pool_mm2 = disponible * lm * wm
    else:
        pool_mm2 = disponible
    if pool_mm2 <= 0:
        raise HTTPException(status_code=400, detail="Superficie disponible inválida (revisar cantidad y medidas)")

    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        placeholders = ",".join(["?"] * len(revisiones))
        where_calibre = ""
        params: List[Any] = list(revisiones)
        params.append(material)
        if calibre:
            where_calibre = " AND ISNULL(CAST(M.Espesor_Perfil_CAD AS VARCHAR(50)), 'N/A') = ? "
            params.append(calibre)

        query = f"""
        WITH PiezasBase AS (
            SELECT
                E.Codigo_Pieza,
                ISNULL(NULLIF(LTRIM(RTRIM(M.Descripcion)), ''), E.Codigo_Pieza) AS Descripcion,
                LTRIM(RTRIM(ISNULL(M.Material, ''))) AS Material_Oficial,
                ISNULL(CAST(M.Espesor_Perfil_CAD AS VARCHAR(50)), 'N/A') AS Calibre_Espesor,
                ISNULL(M.Stock_PT_Almacen, 0) AS Stock_PT_Almacen,
                ISNULL(E.Cantidad, 0) AS Cantidad,
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
            JOIN Tbl_Ensambles EN ON E.ID_Ensamble = EN.ID_Ensamble
            JOIN Tbl_Estaciones ES ON EN.ID_Estacion = ES.ID_Estacion
            LEFT JOIN Tbl_Maestro_Piezas M
                ON LTRIM(RTRIM(E.Codigo_Pieza)) = LTRIM(RTRIM(M.Codigo_Pieza))
            WHERE ES.ID_Revision IN ({placeholders})
              AND UPPER(LTRIM(RTRIM(ISNULL(M.Material, '')))) NOT LIKE '%COMERCIAL%'
              AND LTRIM(RTRIM(ISNULL(M.Material, ''))) = ?
              {where_calibre}
        )
        SELECT
            Codigo_Pieza,
            MAX(Descripcion) AS Descripcion,
            MAX(Material_Oficial) AS Material_Oficial,
            MAX(Calibre_Espesor) AS Calibre_Espesor,
            SUM(Cantidad) AS Demanda_Total,
            MAX(Stock_PT_Almacen) AS Stock_PT_Almacen,
            SUM(Cantidad * ISNULL(NULLIF(AreaLimpia, 0), (ISNULL(LargoLimpio, 0) * ISNULL(AnchoLimpio, 0)))) AS Requerimiento_Area_mm2,
            SUM(Cantidad * ISNULL(LargoLimpio, 0)) AS Requerimiento_Longitud_mm,
            MAX(ISNULL(LargoLimpio, 0)) AS Largo_Unidad_mm,
            MAX(ISNULL(AnchoLimpio, 0)) AS Ancho_Unidad_mm
        FROM PiezasBase
        GROUP BY Codigo_Pieza
        ORDER BY Codigo_Pieza
        """
        cursor.execute(query, tuple(params))
        rows = cursor.fetchall()

        overstock: List[Dict[str, Any]] = []
        candidatos: List[Dict[str, Any]] = []
        descartadas_geometria: List[Dict[str, Any]] = []
        warnings: List[str] = []
        for r in rows:
            codigo = str(r.Codigo_Pieza or "").strip()
            demanda = float(r.Demanda_Total or 0)
            stock = float(r.Stock_PT_Almacen or 0)
            area = float(r.Requerimiento_Area_mm2 or 0)
            long_mm = float(r.Requerimiento_Longitud_mm or 0)
            consumo_unit = (area / demanda) if (demanda > 0 and area > 0) else ((long_mm / demanda) if (demanda > 0 and long_mm > 0) else 0.0)
            if consumo_unit <= 0:
                warnings.append(f"{codigo}: sin medidas CAD/DXF; no se optimiza")
                continue
            excluida = stock > 0 if payload.excluir_si_stock_gt_cero else stock >= demanda
            if excluida:
                overstock.append(
                    {
                        "codigo_pieza": codigo,
                        "descripcion": str(r.Descripcion or codigo),
                        "stock_pt": stock,
                        "demanda_en_revisiones": demanda,
                        "motivo": "sobrestock",
                    }
                )
                continue
            demanda_neta = max(0.0, demanda - stock)
            if demanda_neta <= 0:
                continue
            largo_u = float(getattr(r, "Largo_Unidad_mm", None) or 0)
            ancho_u = float(getattr(r, "Ancho_Unidad_mm", None) or 0)
            area_u_nesting = (largo_u * ancho_u) if (largo_u > 0 and ancho_u > 0) else 0.0
            if area_u_nesting <= 0 and demanda > 0 and area > 0:
                area_u_nesting = area / demanda
            if usa_medidas_placa:
                if largo_u <= 0 and ancho_u <= 0:
                    warnings.append(f"{codigo}: sin largo/ancho en maestro; no se puede verificar corte en placa")
                    descartadas_geometria.append(
                        {
                            "codigo_pieza": codigo,
                            "descripcion": str(r.Descripcion or codigo),
                            "motivo": "sin_medidas_cad",
                        }
                    )
                    continue
                if not _pieza_cabe_en_placa(largo_u, ancho_u, lm, wm):
                    descartadas_geometria.append(
                        {
                            "codigo_pieza": codigo,
                            "descripcion": str(r.Descripcion or codigo),
                            "motivo": "no_cabe_en_placa",
                            "largo_pieza_mm": largo_u,
                            "ancho_pieza_mm": ancho_u,
                        }
                    )
                    continue
            candidatos.append(
                {
                    "codigo_pieza": codigo,
                    "descripcion": str(r.Descripcion or codigo),
                    "calibre_espesor": str(r.Calibre_Espesor or "N/A"),
                    "demanda_neta": demanda_neta,
                    "consumo_unitario": consumo_unit,
                    "stock_pt": stock,
                    "material": str(r.Material_Oficial or material),
                    "requerimiento_material_por_unidad": consumo_unit,
                    "largo_unidad_mm": largo_u,
                    "ancho_unidad_mm": ancho_u,
                    "area_unidad_nesting_mm2": area_u_nesting,
                }
            )

        candidatos.sort(key=lambda x: (x["consumo_unitario"], x["codigo_pieza"]))
        fabricables: List[Dict[str, Any]] = []
        restante = pool_mm2
        if usa_medidas_placa:
            placas_enteras = int(math.floor(disponible))
            if placas_enteras <= 0:
                raise HTTPException(
                    status_code=400,
                    detail="Con largo/ancho de placa, cantidad_disponible debe ser al menos 1.",
                )
            if not math.isclose(disponible, float(placas_enteras)):
                warnings.append(
                    "cantidad_disponible con decimales: nesting usa solo placas completas para preservar rendimiento."
                )
            sim = _simular_nesting_ligero(candidatos, lm, wm, placas_enteras, warnings)
            colocadas = sim.get("colocadas", {})
            consumido_total = float(sim.get("consumido_mm2") or 0)
            restante = max(0.0, pool_mm2 - consumido_total)
            for c in candidatos:
                codigo = str(c["codigo_pieza"])
                sugerida = int(colocadas.get(codigo, 0) or 0)
                if sugerida <= 0:
                    continue
                consumo_unit = float(c.get("area_unidad_nesting_mm2") or c["consumo_unitario"] or 0)
                consumido = sugerida * consumo_unit
                fabricables.append(
                    {
                        "codigo_pieza": c["codigo_pieza"],
                        "descripcion": c["descripcion"],
                        "cantidad_bom_agregada": c["demanda_neta"],
                        "requerimiento_material_por_unidad": consumo_unit,
                        "cantidad_sugerida_fabricar": sugerida,
                        "material_consumido_estimado": consumido,
                        "stock_pt": c["stock_pt"],
                    }
                )
        else:
            for c in candidatos:
                max_units = math.floor(restante / c["consumo_unitario"]) if c["consumo_unitario"] > 0 else 0
                sugerida = min(int(c["demanda_neta"]), int(max_units))
                if sugerida <= 0:
                    continue
                consumido = sugerida * c["consumo_unitario"]
                restante = max(0.0, restante - consumido)
                fabricables.append(
                    {
                        "codigo_pieza": c["codigo_pieza"],
                        "descripcion": c["descripcion"],
                        "cantidad_bom_agregada": c["demanda_neta"],
                        "requerimiento_material_por_unidad": c["requerimiento_material_por_unidad"],
                        "cantidad_sugerida_fabricar": sugerida,
                        "material_consumido_estimado": consumido,
                        "stock_pt": c["stock_pt"],
                    }
                )

        return {
            "material_oficial": material,
            "calibre_espesor": calibre or None,
            "cantidad_disponible": disponible,
            "largo_materia_prima_mm": lm if usa_medidas_placa else None,
            "ancho_materia_prima_mm": wm if usa_medidas_placa else None,
            "area_disponible_mm2": pool_mm2,
            "fabricables": fabricables,
            "sobrestock": overstock,
            "descartadas_por_medida": descartadas_geometria,
            "resumen": {
                "material_restante": restante,
                "material_consumido": max(0.0, pool_mm2 - restante),
                "piezas_consideradas": len(candidatos),
                "piezas_fabricables": len(fabricables),
                "warnings": warnings,
                "modo_medidas_placa": usa_medidas_placa,
            },
        }
    except HTTPException:
        raise
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

