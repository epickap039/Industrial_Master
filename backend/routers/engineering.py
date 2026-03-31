"""API router: engineering."""
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
from pydantic import BaseModel, Field

from database import get_db_connection, _int_from_count_row
from user_context import resolve_actor_user
from models import *

router = APIRouter()


def _parse_codigos_pieza(raw: str) -> List[str]:
    """Acepta 'JA-001, JA-002' → ['JA-001', 'JA-002']."""
    return [p.strip().upper() for p in (raw or "").split(",") if p.strip()]


class ImpactSimulationPayload(BaseModel):
    codigo_pieza: str = Field(..., min_length=1)
    afecta_relaciones: bool = False
    incluir_plano_pieza: bool = True
    incluir_plano_ensamble: bool = True
    incluir_pdf_ensamble: bool = True
    incluir_plano_general: bool = True
    incluir_subir_drive: bool = True

@router.get("/api/mapa/jerarquia")
def get_mapa_jerarquia():
    """Devuelve el árbol completo: Tracto > Tipo > Versión > Revisiones."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("""
            SELECT
                TR.ID_Tracto, TR.Nombre_Tracto,
                TP.ID_Tipo, TP.Nombre_Tipo,
                V.ID_Version, V.Nombre_Version,
                R.ID_Revision, R.Numero_Revision, R.Estado, R.Fecha_Creacion,
                ISNULL(C.Nombre_Cliente, 'Ingeniería Base (Sin clientes)') AS Nombre_Cliente
            FROM Tbl_Proyectos_Tracto TR
            JOIN Tbl_Tipos_Proyecto TP ON TP.ID_Tracto = TR.ID_Tracto
            JOIN Tbl_Versiones_Ingenieria V ON V.ID_Tipo = TP.ID_Tipo
            LEFT JOIN Tbl_BOM_Revisiones R ON R.ID_Version = V.ID_Version AND R.Estado = 'Aprobada'
            LEFT JOIN Tbl_Clientes_Configuracion C ON C.ID_Version = V.ID_Version
            ORDER BY TR.Nombre_Tracto, TP.Nombre_Tipo, V.Nombre_Version, R.Numero_Revision
        """)
        rows = cursor.fetchall()
        # Construir árbol en Python
        tractos: dict = {}
        for r in rows:
            tid = r.ID_Tracto
            if tid not in tractos:
                tractos[tid] = {"id": tid, "nombre": r.Nombre_Tracto, "tipos": {}}
            tipos = tractos[tid]["tipos"]
            pid = r.ID_Tipo
            if pid not in tipos:
                tipos[pid] = {"id": pid, "nombre": r.Nombre_Tipo, "versiones": {}}
            versiones = tipos[pid]["versiones"]
            vid = r.ID_Version
            if vid not in versiones:
                versiones[vid] = {"id": vid, "nombre": r.Nombre_Version, "revisiones": []}
            if r.ID_Revision:
                versiones[vid]["revisiones"].append({
                    "id_revision": r.ID_Revision,
                    "numero_revision": r.Numero_Revision,
                    "estado": r.Estado,
                    "fecha_creacion": r.Fecha_Creacion.isoformat() if r.Fecha_Creacion else None,
                    "cliente": r.Nombre_Cliente
                })
        # Serializar a lista
        result = []
        for tracto in tractos.values():
            t = {"id": tracto["id"], "nombre": tracto["nombre"], "tipos": []}
            for tipo in tracto["tipos"].values():
                tp = {"id": tipo["id"], "nombre": tipo["nombre"], "versiones": []}
                for ver in tipo["versiones"].values():
                    tp["versiones"].append({
                        "id": ver["id"],
                        "nombre": ver["nombre"],
                        "revisiones": ver["revisiones"]
                    })
                t["tipos"].append(tp)
            result.append(t)
        return result
    finally:
        conn.close()

@router.get("/api/bom/where-used/{codigo_pieza}")
def get_where_used(codigo_pieza: str):
    """Búsqueda ascendente (Bottom-Up) para encontrar dónde se usa una pieza."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("""
            SELECT 
                EN.ID_Ensamble,
                EN.Nombre_Ensamble,
                E.Cantidad,
                R.Numero_Revision AS Lista_BOM,
                V.Nombre_Version,
                TP.Nombre_Tipo AS Proyecto,
                TR.Nombre_Tracto AS Tracto,
                ISNULL(C.Nombre_Cliente, 'Ingeniería Base (Sin clientes)') AS Cliente
            FROM Tbl_BOM_Estructura E
            JOIN Tbl_Ensambles EN ON E.ID_Ensamble = EN.ID_Ensamble
            JOIN Tbl_Estaciones ES ON EN.ID_Estacion = ES.ID_Estacion
            JOIN Tbl_BOM_Revisiones R ON ES.ID_Revision = R.ID_Revision
            JOIN Tbl_Versiones_Ingenieria V ON R.ID_Version = V.ID_Version
            JOIN Tbl_Tipos_Proyecto TP ON V.ID_Tipo = TP.ID_Tipo
            JOIN Tbl_Proyectos_Tracto TR ON TP.ID_Tracto = TR.ID_Tracto
            LEFT JOIN Tbl_Clientes_Configuracion C ON V.ID_Version = C.ID_Version
            WHERE E.Codigo_Pieza = ?
        """, (codigo_pieza.upper(),))
        rows = cursor.fetchall()
        
        result = []
        for r in rows:
            result.append({
                "id_ensamble": r.ID_Ensamble,
                "nombre_ensamble": r.Nombre_Ensamble,
                "cantidad": float(r.Cantidad),
                "lista_bom": f"Rev {r.Lista_BOM}",
                "version": r.Nombre_Version,
                "proyecto": r.Proyecto,
                "tracto": r.Tracto,
                "cliente": r.Cliente
            })
        return result
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.post("/api/bom/impacto/simular")
def simular_impacto(payload: ImpactSimulationPayload):
    """
    Simulación de impacto consolidada por ensamble/cliente.
    Aplica sólo listas aprobadas y vigentes (cuando la columna existe).
    """
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        codigos = _parse_codigos_pieza(payload.codigo_pieza)
        if not codigos:
            raise HTTPException(status_code=400, detail="codigo_pieza sin códigos válidos tras split por comas")
        codigo_display = ", ".join(codigos)

        # Detectar si la columna Es_Vigente existe en Tbl_BOM_Revisiones.
        cursor.execute(
            """
            SELECT COUNT(*) AS c
            FROM sys.columns
            WHERE object_id = OBJECT_ID('Tbl_BOM_Revisiones')
              AND name = 'Es_Vigente'
            """
        )
        has_es_vigente = int(cursor.fetchone()[0] or 0) > 0
        vigente_sql = " AND ISNULL(R.Es_Vigente, 1) = 1 " if has_es_vigente else ""

        in_placeholders = ", ".join(["?"] * len(codigos))
        codigos_set = set(codigos)
        query = f"""
            SELECT
                EN.ID_Ensamble,
                EN.Nombre_Ensamble,
                E.Codigo_Pieza,
                E.Cantidad,
                R.ID_Revision,
                R.Numero_Revision AS Lista_BOM,
                V.ID_Version,
                V.Nombre_Version,
                TP.ID_Tipo,
                TP.Nombre_Tipo AS Proyecto,
                TR.ID_Tracto,
                TR.Nombre_Tracto AS Tracto,
                ISNULL(C.Nombre_Cliente, 'Ingeniería Base (Sin clientes)') AS Cliente
            FROM Tbl_BOM_Estructura E
            JOIN Tbl_Ensambles EN ON E.ID_Ensamble = EN.ID_Ensamble
            JOIN Tbl_Estaciones ES ON EN.ID_Estacion = ES.ID_Estacion
            JOIN Tbl_BOM_Revisiones R ON ES.ID_Revision = R.ID_Revision
            JOIN Tbl_Versiones_Ingenieria V ON R.ID_Version = V.ID_Version
            JOIN Tbl_Tipos_Proyecto TP ON V.ID_Tipo = TP.ID_Tipo
            JOIN Tbl_Proyectos_Tracto TR ON TP.ID_Tracto = TR.ID_Tracto
            LEFT JOIN Tbl_Clientes_Configuracion C ON V.ID_Version = C.ID_Version
            WHERE E.Codigo_Pieza IN ({in_placeholders})
              AND R.Estado = 'Aprobada'
              {vigente_sql}
        """
        cursor.execute(query, tuple(codigos))
        rows = cursor.fetchall()

        if not rows:
            return {
                "codigo_pieza": codigo_display,
                "total_minutos": 0,
                "entregables": [],
                "resumen_ensambles": [],
                "tipos_o_grupos_afectados": [],
            }

        # Consolidación por ensamble único + piezas del análisis presentes en cada ensamble.
        ensambles: Dict[int, Dict[str, Any]] = {}
        piezas_por_ens: Dict[int, set] = {}
        for r in rows:
            ens_id = int(r.ID_Ensamble)
            cp = str(r.Codigo_Pieza or "").strip().upper()
            if cp and cp in codigos_set:
                piezas_por_ens.setdefault(ens_id, set()).add(cp)

            if ens_id not in ensambles:
                ensambles[ens_id] = {
                    "id_ensamble": ens_id,
                    "nombre_ensamble": r.Nombre_Ensamble,
                    "cantidad_pieza_en_ensamble": float(r.Cantidad or 0),
                    "cliente": r.Cliente,
                    "lista_bom": f"Rev {r.Lista_BOM}",
                    "proyecto": r.Proyecto,
                    "tracto": r.Tracto,
                    "version": r.Nombre_Version,
                    "id_tipo": int(r.ID_Tipo),
                    "id_version": int(r.ID_Version),
                    "id_tracto": int(r.ID_Tracto),
                    "nombre_tipo": r.Proyecto,
                    "nombre_version": r.Nombre_Version,
                    "cantidad_piezas_distintas": 0,
                    "piezas_especificas_encontradas": [],
                }
            else:
                # Si por JOINs aparece repetido, consolidar cantidad máxima para relaciones.
                ensambles[ens_id]["cantidad_pieza_en_ensamble"] = max(
                    ensambles[ens_id]["cantidad_pieza_en_ensamble"],
                    float(r.Cantidad or 0),
                )

        for ens_id, ens_data in ensambles.items():
            cursor.execute(
                """
                SELECT COUNT(DISTINCT Codigo_Pieza)
                FROM Tbl_BOM_Estructura
                WHERE ID_Ensamble = ?
                """,
                (ens_id,),
            )
            ens_data["cantidad_piezas_distintas"] = int(cursor.fetchone()[0] or 0)

        for eid, ed in ensambles.items():
            ed["piezas_especificas_encontradas"] = sorted(piezas_por_ens.get(eid, set()))

        # Plano general / PDF maestro: una sola vez por (Cliente + Tipo + Versión).
        distinct_grupos_pg = set()
        grupos_meta: Dict[tuple, Dict[str, Any]] = {}
        for r in rows:
            cliente = str(r.Cliente or "")
            id_tipo = int(r.ID_Tipo)
            id_ver = int(r.ID_Version)
            key = (cliente, id_tipo, id_ver)
            distinct_grupos_pg.add(key)
            if key not in grupos_meta:
                grupos_meta[key] = {
                    "cliente": cliente,
                    "id_tipo": id_tipo,
                    "id_version": id_ver,
                    "nombre_tipo": str(r.Proyecto or ""),
                    "nombre_version": str(r.Nombre_Version or ""),
                    "nombre_tracto": str(r.Tracto or ""),
                    "minutos_plano_general": 23,
                }
        tipos_o_grupos_afectados = sorted(
            grupos_meta.values(),
            key=lambda g: (g["nombre_tracto"], g["id_tipo"], g["id_version"], g["cliente"]),
        )

        entregables: List[Dict[str, Any]] = []
        total_min = 0

        if payload.incluir_plano_pieza:
            for c in codigos:
                mins = 10
                entregables.append(
                    {"nombre": f"Actualizar plano pieza ({c})", "minutos": mins}
                )
                total_min += mins

        if payload.incluir_plano_ensamble:
            mins = 20 * len(ensambles)
            entregables.append({"nombre": "Actualizar planos de ensamble", "minutos": mins})
            total_min += mins

        if payload.incluir_pdf_ensamble:
            mins = sum(5 + int(e["cantidad_piezas_distintas"]) for e in ensambles.values())
            entregables.append({"nombre": "Actualizar PDF de ensambles", "minutos": mins})
            total_min += mins

        if payload.incluir_plano_general:
            n_pg = len(distinct_grupos_pg)
            mins = 23 * max(n_pg, 1)
            entregables.append(
                {
                    "nombre": (
                        f"Plano general maestro (Actualizar + PDF) — "
                        f"{n_pg} grupo(s) Cliente+Tipo+Versión"
                    ),
                    "minutos": mins,
                }
            )
            total_min += mins

        if payload.incluir_subir_drive:
            planos_count = len(ensambles) + (len(codigos) if payload.incluir_plano_pieza else 0)
            mins = 3 * planos_count
            entregables.append({"nombre": "Subir planos a Drive", "minutos": mins})
            total_min += mins

        if payload.afecta_relaciones:
            for ens in ensambles.values():
                cant = int(math.ceil(float(ens["cantidad_pieza_en_ensamble"])))
                mins = cant * 5
                total_min += mins
                entregables.append(
                    {
                        "nombre": f"Corregir relaciones de posición (Cant: {cant})",
                        "minutos": mins,
                        "id_ensamble": ens["id_ensamble"],
                    }
                )

        for ens in ensambles.values():
            per_ens = 0
            if payload.incluir_plano_ensamble:
                per_ens += 20
            if payload.incluir_pdf_ensamble:
                per_ens += 5 + int(ens["cantidad_piezas_distintas"])
            if payload.afecta_relaciones:
                cant = int(math.ceil(float(ens["cantidad_pieza_en_ensamble"])))
                per_ens += cant * 5
            ens["minutos_estimados"] = per_ens

        return {
            "codigo_pieza": codigo_display,
            "total_minutos": total_min,
            "entregables": entregables,
            "resumen_ensambles": list(ensambles.values()),
            "tipos_o_grupos_afectados": tipos_o_grupos_afectados,
            "afecta_relaciones": payload.afecta_relaciones,
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

# === MRP / ESTADO DE CUENTA DE MATERIALES ===

