"""API router: engineering."""
import ast
import io
import json
import math
import os
from collections import defaultdict
import re
import shutil
import socket
import subprocess
import sys
import traceback
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import openpyxl
import pandas as pd
import pyodbc
from fastapi import APIRouter, BackgroundTasks, File, Form, Header, HTTPException, Request, Response, UploadFile
from fastapi.responses import StreamingResponse
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from pydantic import BaseModel, ConfigDict, Field

from database import get_db_connection, _int_from_count_row
from user_context import resolve_actor_user
from models import *

router = APIRouter()

_RADAR_TIEMPOS_DEFAULT: Dict[str, int] = {
    "minutos_plano_ensamble": 20,
    "minutos_pdf": 5,
    "minutos_por_relacion_unidad": 5,
}


def _radar_tiempos_path() -> Path:
    return Path(__file__).resolve().parent.parent / "data" / "radar_tiempos.json"


def load_radar_tiempos() -> Dict[str, int]:
    """Constantes editables desde el Radar (panel engranaje)."""
    cfg = dict(_RADAR_TIEMPOS_DEFAULT)
    p = _radar_tiempos_path()
    if not p.is_file():
        return cfg
    try:
        with open(p, "r", encoding="utf-8") as f:
            raw = json.load(f)
        if isinstance(raw, dict):
            for k in _RADAR_TIEMPOS_DEFAULT:
                if k in raw and raw[k] is not None:
                    cfg[k] = max(0, int(raw[k]))
    except (OSError, json.JSONDecodeError, TypeError, ValueError):
        pass
    return cfg


def save_radar_tiempos(values: Dict[str, int]) -> Dict[str, int]:
    p = _radar_tiempos_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    out = {**_RADAR_TIEMPOS_DEFAULT, **values}
    for k in _RADAR_TIEMPOS_DEFAULT:
        out[k] = max(0, int(out.get(k, _RADAR_TIEMPOS_DEFAULT[k])))
    with open(p, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    return out


class RadarTiemposPayload(BaseModel):
    minutos_plano_ensamble: int = Field(20, ge=0, le=9999)
    minutos_pdf: int = Field(5, ge=0, le=9999)
    minutos_por_relacion_unidad: int = Field(5, ge=0, le=9999)


@router.get("/api/bom/impacto/tiempos-config")
def get_radar_tiempos_config():
    return load_radar_tiempos()


@router.put("/api/bom/impacto/tiempos-config")
def put_radar_tiempos_config(payload: RadarTiemposPayload):
    saved = save_radar_tiempos(payload.model_dump())
    return {"ok": True, "config": saved}


def _parse_codigos_pieza(raw: str) -> List[str]:
    """Acepta 'JA-001, JA-002' → ['JA-001', 'JA-002']."""
    return [p.strip().upper() for p in (raw or "").split(",") if p.strip()]


class ImpactSimulationPayload(BaseModel):
    model_config = ConfigDict(extra="ignore")

    codigo_pieza: str = Field(..., min_length=1)
    afecta_relaciones: bool = False


# Impacto de material (grupo aparte en checklist del Radar).
_GRUPO_IMPACTO_MATERIAL = "Impacto de material"


def _grupo_jerarquia_solidworks_desde_fila(r: Any) -> str:
    """
    Regla estricta (simulación impacto): sin Cliente en esta cadena.
    grupo == f"[{tracto}] > [{nombre_tipo}] > [{version}]"
    Usa la misma prioridad de alias que _jerarquia_nombres_desde_fila.
    """
    nt, nti, nv = _jerarquia_nombres_desde_fila(r)
    return f"[{nt}] > [{nti}] > [{nv}]"


_GRUPO_INDEFINIDO_SW = "[Indefinido] > [Indefinido] > [Indefinido]"


def _normalizar_grupo_entregable(
    item: Dict[str, Any],
    default: Optional[str] = None,
) -> Dict[str, Any]:
    """Garantiza clave 'grupo'. Sin 'Global' para ensambles; fallback nunca es Global."""
    out = dict(item)
    g = out.get("grupo")
    ensamble = out.get("id_ensamble")
    is_ens = ensamble is not None
    fallback = default if default is not None else _GRUPO_INDEFINIDO_SW

    if g is None or str(g).strip() == "":
        out["grupo"] = _GRUPO_INDEFINIDO_SW if is_ens else fallback
    else:
        gs = str(g).strip()
        if is_ens and gs.lower() == "global":
            out["grupo"] = _GRUPO_INDEFINIDO_SW
        else:
            out["grupo"] = gs
    return out


def _cliente_desde_fila_impacto(r: Any) -> Optional[str]:
    c = getattr(r, "Cliente", None)
    if c is None:
        return None
    s = str(c).strip()
    return s if s else None


def _jerarquia_nombres_desde_fila(r: Any) -> Tuple[str, str, str]:
    """
    Extrae (nombre_tracto, nombre_tipo, nombre_version) desde una fila pyodbc.
    Los aliases del SELECT de simular_impacto son exactamente:
      TR.Nombre_Tracto AS Tracto
      TP.Nombre_Tipo   AS Nombre_Tipo
      V.Nombre_Version            (sin alias; accesible como r.Nombre_Version)
    Se prueban primero los nombres canónicos y luego los aliases alternativos
    para que nunca quede en Indefinido si el dato existe en la fila.
    """

    def _seg(val: Any) -> str:
        s = str(val or "").strip()
        return s if s else "Indefinido"

    # nombre_tracto: alias «Tracto» en SELECT de simular_impacto;
    # «Nombre_Tracto» en where-used
    nombre_tracto = _seg(
        getattr(r, "Nombre_Tracto", None)
        or getattr(r, "Tracto", None)
    )
    # nombre_tipo: alias «Nombre_Tipo» en simular_impacto;
    # «Proyecto» en where-used
    nombre_tipo = _seg(
        getattr(r, "Nombre_Tipo", None)
        or getattr(r, "Proyecto", None)
    )
    # nombre_version: «Nombre_Version» en ambos queries
    nombre_version = _seg(
        getattr(r, "Nombre_Version", None)
        or getattr(r, "NombreVersion", None)
    )
    return nombre_tracto, nombre_tipo, nombre_version


def _grupo_titulo_por_version(
    nombre_tracto: str,
    nombre_tipo: str,
    nombre_version: str,
    clientes: Any,
) -> str:
    if isinstance(clientes, (set, frozenset)):
        cl = sorted(str(x).strip() for x in clientes if str(x).strip())
    else:
        cl = sorted({str(x).strip() for x in (clientes or []) if str(x).strip()})
    cli_txt = ", ".join(cl) if cl else "Indefinido"
    return (
        f"[{nombre_tracto}] > [{nombre_tipo}] > [{nombre_version}] - (Clientes: {cli_txt})"
    )


def _norm_nombre_ensamble_fila(nm: Any, ens_id: int) -> str:
    s = " ".join(str(nm or "").strip().upper().split())
    return s if s else f"__ID_ENSAMBLE_{int(ens_id)}"


def _merge_fila_entregable_impacto(a: Dict[str, Any], b: Dict[str, Any]) -> Dict[str, Any]:
    """Une cantidades por código, clientes y jerarquía no indefinida."""
    out = dict(a)
    qa = dict(a.get("qty_by_codigo") or {})
    for k, v in (b.get("qty_by_codigo") or {}).items():
        ck = str(k).strip().upper()
        qa[ck] = max(float(qa.get(ck, 0.0)), float(v or 0.0))
    out["qty_by_codigo"] = qa
    ca = set(a.get("clientes") or [])
    cb = set(b.get("clientes") or [])
    out["clientes"] = ca | cb
    out["id_revision"] = max(int(a.get("id_revision") or 0), int(b.get("id_revision") or 0))
    out["id_ensamble"] = min(int(a["id_ensamble"]), int(b["id_ensamble"]))
    na = str(a.get("nombre_ensamble") or "").strip()
    nb = str(b.get("nombre_ensamble") or "").strip()
    out["nombre_ensamble"] = na if len(na) >= len(nb) else nb
    for fld, indef in (
        ("nombre_tracto", "Indefinido"),
        ("nombre_tipo", "Indefinido"),
        ("nombre_version_sw", "Indefinido"),
    ):
        va = str(a.get(fld) or indef).strip() or indef
        vb = str(b.get(fld) or indef).strip() or indef
        out[fld] = va if va != indef else vb
    nv = str(a.get("nombre_version") or "").strip()
    nv2 = str(b.get("nombre_version") or "").strip()
    out["nombre_version"] = nv if nv else nv2
    out["id_version"] = int(a.get("id_version") or b.get("id_version") or 0)
    return out


def _consolidar_filas_entregable_por_version(rows: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """
    Una fila por ensamble físico por versión: dedup por id_ensamble y por nombre normalizado,
    fusionando cantidades y clientes (el título del grupo ya reúne todos los clientes).
    """
    if not rows:
        return []

    by_eid: Dict[int, Dict[str, Any]] = {}
    for it in rows:
        eid = int(it["id_ensamble"])
        cur = {**it, "qty_by_codigo": dict(it.get("qty_by_codigo") or {})}
        if eid not in by_eid:
            by_eid[eid] = cur
        else:
            by_eid[eid] = _merge_fila_entregable_impacto(by_eid[eid], cur)

    by_nombre: Dict[str, Dict[str, Any]] = {}
    for it in sorted(by_eid.values(), key=lambda x: int(x["id_ensamble"])):
        key = _norm_nombre_ensamble_fila(it.get("nombre_ensamble"), int(it["id_ensamble"]))
        if key not in by_nombre:
            by_nombre[key] = {**it, "qty_by_codigo": dict(it.get("qty_by_codigo") or {})}
        else:
            by_nombre[key] = _merge_fila_entregable_impacto(by_nombre[key], it)

    return sorted(by_nombre.values(), key=lambda x: int(x["id_ensamble"]))


def _total_minutos_desde_entregables(entregables: List[Dict[str, Any]]) -> int:
    return sum(int(x.get("minutos") or 0) for x in entregables)


class WhereUsedPayload(BaseModel):
    """Códigos separados por coma; una sola consulta consolidada."""

    codigo_pieza: str = Field(..., min_length=1)


def _revision_aprobada_vigente_sql(cursor) -> str:
    """Mismo criterio que where-used: aprobadas y Es_Vigente = 1 si la columna existe."""
    cursor.execute(
        """
        SELECT COUNT(*) AS c
        FROM sys.columns
        WHERE object_id = OBJECT_ID('Tbl_BOM_Revisiones')
          AND name = 'Es_Vigente'
        """
    )
    has_es_vigente = int(cursor.fetchone()[0] or 0) > 0
    return " AND R.Es_Vigente = 1 " if has_es_vigente else ""


def _pick_material_column_maestro(cols: List[str]) -> Optional[str]:
    """Columna de descripción de material en Tbl_Maestro_Piezas (sin peso)."""
    lower = {c.lower(): c for c in cols}
    for cand in (
        "material",
        "material_pieza",
        "descripcion_material",
        "mat",
        "nom_material",
        "material_desc",
    ):
        if cand in lower:
            return lower[cand]
    return None


def _maestro_material_column(cursor) -> Optional[str]:
    cursor.execute(
        """
        SELECT COLUMN_NAME
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_NAME = 'Tbl_Maestro_Piezas'
        """,
    )
    cols = [str(r[0]) for r in cursor.fetchall()]
    return _pick_material_column_maestro(cols)


def _rows_to_where_used_result(rows) -> List[Dict[str, Any]]:
    result: List[Dict[str, Any]] = []
    for r in rows:
        result.append(
            {
                "id_ensamble": r.ID_Ensamble,
                "nombre_ensamble": r.Nombre_Ensamble,
                "cantidad": float(r.Cantidad),
                "lista_bom": f"Rev {r.Lista_BOM}",
                "version": r.Nombre_Version,
                "proyecto": r.Proyecto,
                "tracto": r.Tracto,
                "cliente": r.Cliente,
            }
        )
    return result


def _compute_impacto_material(
    cursor,
    codigos: List[str],
    ens_ids: List[int],
    vigente_sql: str,
) -> str:
    """Texto limpio: solo descripción de material desde Tbl_Maestro_Piezas (sin peso ni kg)."""
    if not codigos or not ens_ids:
        return "Afectación: material — sin ensambles aprobados/vigentes para el análisis."

    mat_col = _maestro_material_column(cursor)
    cod_ph = ", ".join(["?"] * len(codigos))
    ens_ph = ", ".join(["?"] * len(ens_ids))
    sql_qty = f"""
        SELECT E.Codigo_Pieza, E.ID_Ensamble, MAX(E.Cantidad) AS Cantidad
        FROM Tbl_BOM_Estructura E
        JOIN Tbl_Ensambles EN ON E.ID_Ensamble = EN.ID_Ensamble
        JOIN Tbl_Estaciones ES ON EN.ID_Estacion = ES.ID_Estacion
        JOIN Tbl_BOM_Revisiones R ON ES.ID_Revision = R.ID_Revision
        WHERE E.Codigo_Pieza IN ({cod_ph})
          AND E.ID_Ensamble IN ({ens_ph})
          AND R.Estado = 'Aprobada'
          {vigente_sql}
        GROUP BY E.Codigo_Pieza, E.ID_Ensamble
    """
    cursor.execute(sql_qty, tuple(codigos) + tuple(ens_ids))
    qcols = [d[0] for d in cursor.description]
    qty_rows = [dict(zip(qcols, row)) for row in cursor.fetchall()]

    maestro_mat: Dict[str, str] = {}
    try:
        if mat_col:
            cursor.execute(
                f"""
                SELECT [Codigo_Pieza],
                       LTRIM(RTRIM(ISNULL([{mat_col}], ''))) AS _mat
                FROM Tbl_Maestro_Piezas
                WHERE Codigo_Pieza IN ({cod_ph})
                """,
                tuple(codigos),
            )
            mcols = [d[0] for d in cursor.description]
            for row in cursor.fetchall():
                md = dict(zip(mcols, row))
                cp = str(md.get("Codigo_Pieza") or "").strip().upper()
                if not cp:
                    continue
                maestro_mat[cp] = str(md.get("_mat") or "").strip()
    except Exception:
        pass

    mats: List[str] = []
    for md in qty_rows:
        cp = str(md.get("Codigo_Pieza") or "").strip().upper()
        m = maestro_mat.get(cp, "")
        if m:
            mats.append(m)

    uniq = sorted({x for x in mats if x})
    if uniq:
        if len(uniq) == 1:
            return f"Afectación: material {uniq[0]}"
        return f"Afectación: material {', '.join(uniq)}"
    if not mat_col:
        return "Afectación: material — sin columna de material en Tbl_Maestro_Piezas."
    return "Afectación: material — sin descripción en maestro para los códigos analizados."


def _where_used_query_and_params(codigos: List[str], vigente_sql: str) -> Tuple[str, tuple]:
    """
    Mismos filtros que POST /api/bom/impacto/simular:
    R.Estado = 'Aprobada' y, si existe columna, R.Es_Vigente = 1.
    """
    ph = ", ".join(["?"] * len(codigos))
    query = f"""
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
            WHERE E.Codigo_Pieza IN ({ph})
              AND R.Estado = 'Aprobada'
              {vigente_sql}
        """
    return query, tuple(codigos)

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
    """
    Búsqueda ascendente (Bottom-Up). Acepta un código o varios separados por coma.
    Solo listas BOM aprobadas y vigentes (Es_Vigente = 1 si la columna existe).
    """
    codigos = _parse_codigos_pieza(codigo_pieza)
    if not codigos:
        raise HTTPException(status_code=400, detail="codigo_pieza sin códigos válidos")
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        vigente_sql = _revision_aprobada_vigente_sql(cursor)
        q, params = _where_used_query_and_params(codigos, vigente_sql)
        cursor.execute(q, params)
        rows = cursor.fetchall()
        return _rows_to_where_used_result(rows)
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.post("/api/bom/where-used")
def post_where_used(payload: WhereUsedPayload):
    """Misma lógica que GET: múltiples códigos en una sola consulta consolidada."""
    codigos = _parse_codigos_pieza(payload.codigo_pieza)
    if not codigos:
        raise HTTPException(status_code=400, detail="codigo_pieza sin códigos válidos")
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        vigente_sql = _revision_aprobada_vigente_sql(cursor)
        q, params = _where_used_query_and_params(codigos, vigente_sql)
        cursor.execute(q, params)
        rows = cursor.fetchall()
        return _rows_to_where_used_result(rows)
    except HTTPException:
        raise
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

        vigente_sql = _revision_aprobada_vigente_sql(cursor)

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
                TP.Nombre_Tipo AS Nombre_Tipo,
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
            im_vacio = (
                "No hay listas BOM con Estado = 'Aprobada' y Es_Vigente = 1 para estos códigos. "
                "Revise revisiones en SolidWorks / SQL."
            )
            one_mat = _normalizar_grupo_entregable(
                {
                    "nombre": "Impacto de material",
                    "minutos": 0,
                    "grupo": _GRUPO_IMPACTO_MATERIAL,
                    "detalle_material": im_vacio,
                },
                default=_GRUPO_IMPACTO_MATERIAL,
            )
            ent_vacio = [one_mat]
            ent_agrup_vacio = [
                {
                    "grupo_titulo": _GRUPO_IMPACTO_MATERIAL,
                    "id_version": None,
                    "items": [one_mat],
                }
            ]
            return {
                "codigo_pieza": codigo_display,
                "total_minutos": _total_minutos_desde_entregables(ent_vacio),
                "entregables": ent_vacio,
                "entregables_agrupados": ent_agrup_vacio,
                "resumen_ensambles": [],
                "tipos_o_grupos_afectados": [],
                "impacto_material": im_vacio,
                "afecta_relaciones": payload.afecta_relaciones,
                "sin_bom_aprobada_vigente": True,
                "mensaje_alerta": im_vacio,
                "resumen_directivo": {
                    "total_tractos": 0,
                    "total_listas": 0,
                    "total_ensambles": 0,
                    "total_piezas_fisicas": 0,
                },
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

        # Sin entregables sintéticos tipo PDF / E-Drawing / Drive en la simulación.
        tipos_o_grupos_afectados: List[Dict[str, Any]] = []

        impacto_material = _compute_impacto_material(
            cursor, codigos, list(ensambles.keys()), vigente_sql
        )

        id_tractos = {int(r.ID_Tracto) for r in rows}
        id_revisiones = {int(r.ID_Revision) for r in rows}
        total_piezas_fisicas = 0.0
        for r in rows:
            cp = str(r.Codigo_Pieza or "").strip().upper()
            if cp and cp in codigos_set:
                total_piezas_fisicas += float(r.Cantidad or 0)
        resumen_directivo = {
            "total_tractos": len(id_tractos),
            "total_listas": len(id_revisiones),
            "total_ensambles": len(ensambles),
            "total_piezas_fisicas": int(round(total_piezas_fisicas)),
        }

        entregables: List[Dict[str, Any]] = []
        radar_cfg = load_radar_tiempos()
        # Solo tiempo de plano ensamble; sin bloque PDF / E-Drawing / Drive en minutos.
        base_plano = int(radar_cfg["minutos_plano_ensamble"])
        min_por_rel = int(radar_cfg["minutos_por_relacion_unidad"])

        # Clave principal: (ID_Ensamble, ID_Version).
        # El LEFT JOIN sobre Tbl_Clientes_Configuracion multiplica filas por cliente,
        # por eso la clave incluye id_ensamble para no perder la granularidad de
        # ensamble y poder deduplicar más tarde dentro de cada grupo de versión.
        pair_data: Dict[Tuple[int, int], Dict[str, Any]] = {}
        for r in rows:
            cp = str(r.Codigo_Pieza or "").strip().upper()
            if not cp or cp not in codigos_set:
                continue
            ens_id = int(r.ID_Ensamble)
            id_ver = int(r.ID_Version)
            key = (ens_id, id_ver)
            cant = float(r.Cantidad or 0)
            nm = str(r.Nombre_Ensamble or "").strip() or f"Ensamble {ens_id}"
            nombre_ver = str(r.Nombre_Version or "").strip() or "Indefinido"
            # _jerarquia_nombres_desde_fila resuelve los aliases correctos del SELECT:
            # Tracto → nombre_tracto, Nombre_Tipo → nombre_tipo, Nombre_Version → nombre_version_sw
            nt, nti, nv = _jerarquia_nombres_desde_fila(r)
            rev_id = int(r.ID_Revision)
            cli = _cliente_desde_fila_impacto(r)
            if key not in pair_data:
                clset: set = set()
                if cli:
                    clset.add(cli)
                pair_data[key] = {
                    "id_ensamble": ens_id,
                    "id_version": id_ver,
                    "id_revision": rev_id,
                    "nombre_ensamble": nm,
                    "nombre_version": nombre_ver,
                    # Estos tres campos alimentan grupo_titulo en el bloque de agrupamiento.
                    "nombre_tracto": nt,
                    "nombre_tipo": nti,
                    "nombre_version_sw": nv,
                    "qty_by_codigo": {cp: cant},
                    "clientes": clset,
                }
            else:
                # Misma clave (ens_id, id_ver): acumular cantidad y clientes.
                qmap: Dict[str, float] = pair_data[key]["qty_by_codigo"]
                qmap[cp] = max(qmap.get(cp, 0.0), cant)
                # Guardar la revisión más reciente vista.
                pair_data[key]["id_revision"] = max(pair_data[key]["id_revision"], rev_id)
                cur = pair_data[key]
                # Preferir valores no-Indefinido para la jerarquía.
                if nt != "Indefinido":
                    cur["nombre_tracto"] = nt
                if nti != "Indefinido":
                    cur["nombre_tipo"] = nti
                if nv != "Indefinido":
                    cur["nombre_version_sw"] = nv
                if cli:
                    pair_data[key]["clientes"].add(cli)

        sorted_pairs = sorted(
            pair_data.values(),
            key=lambda x: (x["id_version"], x["id_ensamble"]),
        )

        def _cantidad_unidades_item(item_dict: Dict[str, Any]) -> int:
            qmap = item_dict.get("qty_by_codigo") or {}
            if not qmap:
                return 0
            return int(math.ceil(sum(float(v) for v in qmap.values())))

        def _minutos_ensamble_item(item_dict: Dict[str, Any], afecta_rel: bool) -> int:
            cant_u = _cantidad_unidades_item(item_dict)
            rel = (cant_u * min_por_rel) if afecta_rel else 0
            return base_plano + rel

        by_version: Dict[int, List[Dict[str, Any]]] = defaultdict(list)
        for it in sorted_pairs:
            by_version[int(it["id_version"])].append(it)

        entregables_agrupados: List[Dict[str, Any]] = []

        for id_ver in sorted(by_version.keys()):
            group_rows = by_version[id_ver]

            # --- Reunir jerarquía y clientes de TODOS los ítems del grupo ---
            all_cli: set = set()
            best_tracto = "Indefinido"
            best_tipo = "Indefinido"
            best_version_sw = "Indefinido"
            for it in group_rows:
                all_cli.update(it.get("clientes") or [])
                t_val = str(it.get("nombre_tracto") or "").strip()
                ti_val = str(it.get("nombre_tipo") or "").strip()
                v_val = str(it.get("nombre_version_sw") or "").strip()
                if t_val and t_val != "Indefinido":
                    best_tracto = t_val
                if ti_val and ti_val != "Indefinido":
                    best_tipo = ti_val
                if v_val and v_val != "Indefinido":
                    best_version_sw = v_val

            # grupo_titulo: encabezado de la sección en la UI
            # Formato exacto: "[TRACTO] > [TIPO] > [VERSION] - (Clientes: A, B)"
            grupo_titulo = _grupo_titulo_por_version(
                best_tracto, best_tipo, best_version_sw, all_cli
            )
            # grupo_base: ruta jerárquica sin la lista de clientes (usado en el campo 'grupo' de cada ítem)
            grupo_base = f"[{best_tracto}] > [{best_tipo}] > [{best_version_sw}]"

            # --- Deduplicar estrictamente por id_ensamble dentro de la versión ---
            deduped_version = _consolidar_filas_entregable_por_version(group_rows)
            items_out: List[Dict[str, Any]] = []
            for item in deduped_version:
                mins = _minutos_ensamble_item(item, payload.afecta_relaciones)
                cant_u = _cantidad_unidades_item(item)
                nm_e = (
                    str(item.get("nombre_ensamble") or "").strip()
                    or f"Ensamble {item['id_ensamble']}"
                )
                nombre_item = f"[{nm_e}] - Modificar plano"
                ts_cant = f"{cant_u} u."
                d = _normalizar_grupo_entregable(
                    {
                        "nombre": nombre_item,
                        "texto_secundario": ts_cant,
                        "minutos": mins,
                        "id_ensamble": item["id_ensamble"],
                        "id_version": item["id_version"],
                        "id_revision": item["id_revision"],
                        # 'grupo' = la ruta jerárquica limpia (sin lista de clientes),
                        # que coincide con lo que el frontend usa para el matching.
                        "grupo": grupo_base,
                    }
                )
                items_out.append(d)
                entregables.append(d)

            entregables_agrupados.append(
                {
                    "grupo_titulo": grupo_titulo,
                    "id_version": id_ver,
                    "items": items_out,
                }
            )

        for ens in ensambles.values():
            eid = int(ens["id_ensamble"])
            per_ens = 0
            for item in sorted_pairs:
                if int(item["id_ensamble"]) != eid:
                    continue
                per_ens += _minutos_ensamble_item(item, payload.afecta_relaciones)
            ens["minutos_estimados"] = per_ens

        mat_item = _normalizar_grupo_entregable(
            {
                "nombre": "Impacto de material",
                "minutos": 0,
                "grupo": _GRUPO_IMPACTO_MATERIAL,
                "texto_secundario": "",
                "detalle_material": impacto_material,
            },
            default=_GRUPO_IMPACTO_MATERIAL,
        )
        entregables.append(mat_item)
        entregables_agrupados.append(
            {
                "grupo_titulo": _GRUPO_IMPACTO_MATERIAL,
                "id_version": None,
                "items": [mat_item],
            }
        )

        entregables = [_normalizar_grupo_entregable(e) for e in entregables]
        for gblk in entregables_agrupados:
            gblk["items"] = [_normalizar_grupo_entregable(x) for x in gblk.get("items") or []]
        total_min = _total_minutos_desde_entregables(entregables)

        return {
            "codigo_pieza": codigo_display,
            "total_minutos": total_min,
            "entregables": entregables,
            "entregables_agrupados": entregables_agrupados,
            "resumen_ensambles": list(ensambles.values()),
            "tipos_o_grupos_afectados": tipos_o_grupos_afectados,
            "afecta_relaciones": payload.afecta_relaciones,
            "impacto_material": impacto_material,
            "resumen_directivo": resumen_directivo,
            "sin_bom_aprobada_vigente": False,
            "mensaje_alerta": None,
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

# === MRP / ESTADO DE CUENTA DE MATERIALES ===

