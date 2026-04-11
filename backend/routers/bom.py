"""API router: bom."""
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
from bom_audit_log import registrar_log
from user_context import resolve_actor_user

router = APIRouter()


def _usuario_ingenieria(x_usuario: Optional[str]) -> str:
    s = (x_usuario or "").strip()
    return s if s else "Operador_Desconocido"


def _norm_bom_group_label(value: Any) -> str:
    """
    Clave estable para agrupar estaciones/ensambles: colapsa espacios y compara
    sin sensibilidad a mayúsculas (evita carpetas duplicadas por espacios o casing).
    """
    if value is None or (isinstance(value, float) and pd.isna(value)):
        return ""
    s = str(value).strip()
    if not s:
        return ""
    return " ".join(s.split()).casefold()


def _display_bom_group_label(value: Any) -> str:
    """Nombre legible (sin espacios múltiples) para persistir en BD."""
    if value is None or (isinstance(value, float) and pd.isna(value)):
        return ""
    s = str(value).strip()
    if not s:
        return ""
    return " ".join(s.split())


def _clear_bom_structure_for_revision(cursor, id_revision: int) -> None:
    """
    Borra piezas, ensambles y estaciones de la revisión (reemplazo total desde Excel).
    No elimina la fila de Tbl_BOM_Revisiones ni unidades físicas (VINs).
    """
    cursor.execute(
        """
        DELETE E FROM Tbl_BOM_Estructura E
        INNER JOIN Tbl_Ensambles EN ON E.ID_Ensamble = EN.ID_Ensamble
        INNER JOIN Tbl_Estaciones ES ON EN.ID_Estacion = ES.ID_Estacion
        WHERE ES.ID_Revision = ?
        """,
        (id_revision,),
    )
    cursor.execute(
        """
        DELETE EN FROM Tbl_Ensambles EN
        INNER JOIN Tbl_Estaciones ES ON EN.ID_Estacion = ES.ID_Estacion
        WHERE ES.ID_Revision = ?
        """,
        (id_revision,),
    )
    cursor.execute("DELETE FROM Tbl_Estaciones WHERE ID_Revision = ?", (id_revision,))


def _auditoria_bom_import(
    cursor,
    id_revision: int,
    accion: str,
    detalle: str,
    usuario: str,
) -> None:
    cursor.execute(
        """
        INSERT INTO Tbl_Auditoria_Cambios (Codigo_Pieza, Accion, Valor_Anterior, Valor_Nuevo, Usuario, Fecha_Hora)
        VALUES (?, ?, ?, ?, ?, GETDATE())
        """,
        (
            f"BOM-REV-{id_revision}",
            accion,
            "importacion_excel",
            (detalle or "")[:3800],
            (usuario or "Sistema")[:100],
        ),
    )


def _parse_bom_import_excel(
    df: pd.DataFrame,
    codigos_buscar: set,
) -> tuple:
    """
    Lee filas del Excel BOM → acumulados por (est_norm, ens_norm, codigo).
    Retorna (acumulados, canonical_estacion, canonical_ensamble, errores_mapeo, total_leidos).
    """
    _COL_MAP = {
        "estacion": {"ESTACION", "ESTACIÓN", "UBICACION", "UBICACIÓN", "STATION"},
        "ensamble": {"ENSAMBLE", "GRUPO", "SUBENSAMBLE", "SUBGRUPO", "ASSEMBLY"},
        "codigo": {
            "CODIGO",
            "CÓDIGO",
            "PARTE",
            "NO. PARTE",
            "NO.PARTE",
            "CODIGO PIEZA",
            "CÓDIGO PIEZA",
            "PART NO",
            "PART NUMBER",
        },
        "cantidad": {"CANTIDAD", "CANT", "CANT.", "QTY", "QUANTITY"},
    }
    idx = {"estacion": 1, "ensamble": 2, "codigo": 3, "cantidad": 6}

    header_row_found = None
    for r_idx, row_scan in df.iterrows():
        if r_idx >= 10:
            break
        row_vals = [str(v).strip().upper() if not pd.isna(v) else "" for v in row_scan]
        matched = 0
        tmp = {}
        for campo, sinonimos in _COL_MAP.items():
            for c_idx, val in enumerate(row_vals):
                if val in sinonimos:
                    tmp[campo] = c_idx
                    matched += 1
                    break
        if matched >= 3:
            idx.update(tmp)
            header_row_found = r_idx
            break

    data_start = (header_row_found + 1) if header_row_found is not None else 0

    acumulados: Dict[tuple, int] = {}
    canonical_estacion: Dict[str, str] = {}
    canonical_ensamble: Dict[tuple, str] = {}
    errores_mapeo: List[str] = []
    total_leidos = 0

    last_estacion = None
    last_ensamble = None

    for index, row in df.iterrows():
        if index < data_start:
            continue

        def _safe(col_idx):
            try:
                v = row[col_idx]
                return None if pd.isna(v) else str(v).strip()
            except (KeyError, IndexError):
                return None

        estacion_raw = _safe(idx["estacion"])
        ensamble_raw = _safe(idx["ensamble"])
        codigo_raw = _safe(idx["codigo"])
        cantidad_raw = _safe(idx["cantidad"])

        if estacion_raw:
            last_estacion = estacion_raw
        if ensamble_raw:
            last_ensamble = ensamble_raw
        estacion_val = last_estacion
        ensamble_val = last_ensamble

        if not codigo_raw:
            continue
        skip_values = {
            "codigo",
            "código",
            "codigo pieza",
            "código pieza",
            "codigo_pieza",
            "no. parte",
            "part no",
            "none",
            "",
        }
        if codigo_raw.lower() in skip_values:
            continue
        if not estacion_val or not ensamble_val:
            continue

        total_leidos += 1
        codigo = codigo_raw.upper()

        if codigo not in codigos_buscar:
            if codigo not in errores_mapeo:
                errores_mapeo.append(codigo)
            continue

        try:
            cantidad = 1 if not cantidad_raw else int(float(cantidad_raw))
        except (ValueError, TypeError):
            cantidad = 1

        est_norm = _norm_bom_group_label(estacion_val)
        ens_norm = _norm_bom_group_label(ensamble_val)
        if not est_norm or not ens_norm:
            continue

        canonical_estacion.setdefault(est_norm, _display_bom_group_label(estacion_val))
        canonical_ensamble.setdefault((est_norm, ens_norm), _display_bom_group_label(ensamble_val))

        llave = (est_norm, ens_norm, codigo)
        acumulados[llave] = acumulados.get(llave, 0) + cantidad

    return acumulados, canonical_estacion, canonical_ensamble, errores_mapeo, total_leidos


def _bom_apply_accumulated(
    cursor,
    id_revision: int,
    acumulados: Dict[tuple, int],
    canonical_estacion: Dict[str, str],
    canonical_ensamble: Dict[tuple, str],
    estacion_id_por_norm: Dict[str, int],
    sumar: bool,
) -> tuple:
    """
    Aplica filas acumuladas a la revisión. Si sumar=True, suma cantidad si existe la pieza
    en el ensamble; si no, inserta. Si sumar=False, solo inserta (estructura vacía previa).
    Retorna (insertados, actualizados).
    """
    insertados = 0
    actualizados = 0

    cursor.execute(
        "SELECT MAX(Codigo_Ensamble) FROM Tbl_Ensambles WHERE Codigo_Ensamble LIKE 'E-%'"
    )
    max_code_row = cursor.fetchone()
    secuencia_ensamble = 0
    if max_code_row and max_code_row[0]:
        try:
            secuencia_ensamble = int(max_code_row[0].split("-")[1])
        except (ValueError, IndexError):
            pass

    cache_ensambles: Dict[tuple, int] = {}

    for (est_norm, ens_norm, codigo), cantidad in acumulados.items():
        nombre_estacion = canonical_estacion.get(est_norm) or ""
        nombre_ensamble = canonical_ensamble.get((est_norm, ens_norm)) or ""

        id_estacion = estacion_id_por_norm.get(est_norm)
        if id_estacion is None:
            cursor.execute(
                "SELECT ISNULL(MAX(Orden), 0) + 1 FROM Tbl_Estaciones WHERE ID_Revision = ?",
                (id_revision,),
            )
            nuevo_orden = cursor.fetchone()[0]
            cursor.execute(
                "INSERT INTO Tbl_Estaciones (ID_Revision, Nombre_Estacion, Orden) OUTPUT INSERTED.ID_Estacion VALUES (?, ?, ?)",
                (id_revision, nombre_estacion, nuevo_orden),
            )
            id_estacion = int(cursor.fetchone()[0])
            estacion_id_por_norm[est_norm] = id_estacion

        ens_cache_key = (id_estacion, ens_norm)
        if ens_cache_key not in cache_ensambles:
            cursor.execute(
                "SELECT ID_Ensamble, Nombre_Ensamble FROM Tbl_Ensambles WHERE ID_Estacion = ?",
                (id_estacion,),
            )
            for erow in cursor.fetchall():
                eid = int(erow[0])
                ename_norm = _norm_bom_group_label(erow[1])
                if ename_norm:
                    cache_ensambles.setdefault((id_estacion, ename_norm), eid)

        id_ensamble = cache_ensambles.get(ens_cache_key)
        if id_ensamble is None:
            cursor.execute(
                "SELECT ID_Ensamble FROM Tbl_Ensambles WHERE ID_Estacion = ? AND Nombre_Ensamble = ?",
                (id_estacion, nombre_ensamble),
            )
            ens_row = cursor.fetchone()
            if ens_row:
                id_ensamble = int(ens_row[0])
            else:
                secuencia_ensamble += 1
                codigo_ensamble_generado = f"E-{secuencia_ensamble:04d}"
                cursor.execute(
                    "INSERT INTO Tbl_Ensambles (ID_Estacion, Codigo_Ensamble, Nombre_Ensamble) OUTPUT INSERTED.ID_Ensamble VALUES (?, ?, ?)",
                    (id_estacion, codigo_ensamble_generado, nombre_ensamble),
                )
                id_ensamble = int(cursor.fetchone()[0])
            cache_ensambles[ens_cache_key] = id_ensamble

        if sumar:
            cursor.execute(
                "SELECT ID_BOM, Cantidad FROM Tbl_BOM_Estructura WHERE ID_Ensamble = ? AND Codigo_Pieza = ?",
                (id_ensamble, codigo),
            )
            ex = cursor.fetchone()
            if ex:
                prev_q = int(ex.Cantidad or 0)
                cursor.execute(
                    "UPDATE Tbl_BOM_Estructura SET Cantidad = ? WHERE ID_BOM = ?",
                    (prev_q + int(cantidad), int(ex.ID_BOM)),
                )
                actualizados += 1
            else:
                cursor.execute(
                    "INSERT INTO Tbl_BOM_Estructura (ID_Ensamble, Codigo_Pieza, Cantidad, Observaciones_Proceso) VALUES (?, ?, ?, ?)",
                    (id_ensamble, codigo, cantidad, ""),
                )
                insertados += 1
        else:
            cursor.execute(
                "INSERT INTO Tbl_BOM_Estructura (ID_Ensamble, Codigo_Pieza, Cantidad, Observaciones_Proceso) VALUES (?, ?, ?, ?)",
                (id_ensamble, codigo, cantidad, ""),
            )
            insertados += 1

    return insertados, actualizados


# === MODULO: BOM (Gestor de Listas) ===
@router.get("/api/bom/estaciones/{id_revision}")
def get_estaciones(id_revision: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("SELECT ID_Estacion, ID_Revision, Nombre_Estacion, Orden FROM Tbl_Estaciones WHERE ID_Revision = ? ORDER BY Orden", (id_revision,))
        rows = cursor.fetchall()
        return [{"id": r.ID_Estacion, "id_revision": r.ID_Revision, "nombre": r.Nombre_Estacion, "orden": r.Orden} for r in rows]
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error al obtener estaciones: {str(e)}")
    finally:
        conn.close()

# Endpoints Revisiones
# --- Endpoints Revisiones (v60.0: agrupados por ID_Version, no por cliente) ---
@router.get("/api/bom/revisiones/version/{id_version}")
def get_revisiones_por_version(id_version: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute(
            """
            SELECT
                R.ID_Revision,
                R.ID_Version,
                R.Numero_Revision,
                R.Estado,
                R.Fecha_Creacion,
                ISNULL(
                    (SELECT STRING_AGG(C.Nombre_Cliente, ', ')
                     FROM Tbl_Clientes_Configuracion C
                     WHERE C.ID_Version = R.ID_Version),
                    'Ingeniería Base (Sin clientes)'
                ) AS Clientes_Afectados
            FROM Tbl_BOM_Revisiones R
            WHERE R.ID_Version = ?
            ORDER BY R.Numero_Revision
            """,
            (id_version,)
        )
        rows = cursor.fetchall()
        return [
            {
                "id_revision":        r.ID_Revision,
                "id_version":         r.ID_Version,
                "numero_revision":    r.Numero_Revision,
                "estado":             r.Estado,
                "fecha_creacion":     r.Fecha_Creacion.isoformat() if r.Fecha_Creacion else None,
                "clientes_afectados": r.Clientes_Afectados or "Ingeniería Base (Sin clientes)",
            }
            for r in rows
        ]
    finally:
        conn.close()

@router.post("/api/bom/revisiones/version/{id_version}")
def add_revision_version(
    id_version: int,
    payload: RevisionPayload,
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute(
            "SELECT ISNULL(MAX(Numero_Revision), -1) + 1 FROM Tbl_BOM_Revisiones WHERE ID_Version = ?",
            (id_version,),
        )
        siguiente_rev = int(cursor.fetchone()[0])
        # Nombre auto-generado "Revisión N"; notas se preservan en el log.
        cursor.execute(
            "INSERT INTO Tbl_BOM_Revisiones (ID_Version, Numero_Revision, Estado) "
            "OUTPUT INSERTED.ID_Revision VALUES (?, ?, 'Borrador')",
            (id_version, siguiente_rev),
        )
        id_rev = cursor.fetchone()[0]
        notas_txt = f' | Anotaciones: "{payload.notas}"' if payload.notas else ""
        registrar_log(
            cursor,
            id_rev,
            "Creación",
            f"Revisión {siguiente_rev} creada para Versión ID {id_version}{notas_txt}",
            usuario=_usuario_ingenieria(x_usuario),
        )
        conn.commit()
        return {"status": "success", "id_revision": id_rev, "numero_revision": siguiente_rev}
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error creando revisión: {str(e)}")
    finally:
        conn.close()

# --- Compatibilidad legacy: revisiones por cliente (redirige a versión) ---
@router.get("/api/bom/revisiones/{id_cliente}")
def get_revisiones(id_cliente: int):
    """Legacy endpoint - mantiene compatibilidad con pantallas antiguas."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # Buscar revisiones cuya versión corresponde al cliente
        cursor.execute(
            """
            SELECT R.ID_Revision, R.Numero_Revision, R.Estado, R.Fecha_Creacion
            FROM Tbl_BOM_Revisiones R
            JOIN Tbl_Clientes_Configuracion CC ON CC.ID_Version = R.ID_Version
            WHERE CC.ID_Config_Cliente = ?
            ORDER BY R.Numero_Revision
            """,
            (id_cliente,)
        )
        rows = cursor.fetchall()
        return [{"id_revision": r.ID_Revision, "numero_revision": r.Numero_Revision, "estado": r.Estado, "fecha_creacion": r.Fecha_Creacion.isoformat() if r.Fecha_Creacion else None} for r in rows]
    finally:
        conn.close()

@router.post("/api/bom/revisiones/{id_cliente}")
def add_revision(
    id_cliente: int,
    payload: RevisionPayload,
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
):
    """Legacy endpoint."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("SELECT ID_Version FROM Tbl_Clientes_Configuracion WHERE ID_Config_Cliente = ?", (id_cliente,))
        ver_row = cursor.fetchone()
        if not ver_row:
            raise HTTPException(status_code=404, detail="Cliente no encontrado")
        id_version = ver_row[0]
        cursor.execute(
            "SELECT ISNULL(MAX(Numero_Revision), -1) + 1 FROM Tbl_BOM_Revisiones WHERE ID_Version = ?",
            (id_version,),
        )
        siguiente_rev = int(cursor.fetchone()[0])
        cursor.execute(
            "INSERT INTO Tbl_BOM_Revisiones (ID_Version, Numero_Revision, Estado) "
            "OUTPUT INSERTED.ID_Revision VALUES (?, ?, 'Borrador')",
            (id_version, siguiente_rev),
        )
        id_rev = cursor.fetchone()[0]
        notas_txt = f' | Anotaciones: "{payload.notas}"' if payload.notas else ""
        registrar_log(
            cursor,
            id_rev,
            "Creación",
            f"Revisión {siguiente_rev}{notas_txt} (vía cliente {id_cliente})",
            usuario=_usuario_ingenieria(x_usuario),
        )
        conn.commit()
        return {"status": "success", "id_revision": id_rev}
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error creando revisión: {str(e)}")
    finally:
        conn.close()

@router.put("/api/bom/revisiones/{id_revision}/aprobar")
def aprobar_revision(
    id_revision: int,
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # Obtener la versión para marcar las demás revisiones como OBSOLETO
        cursor.execute(
            "SELECT ID_Version, Numero_Revision FROM Tbl_BOM_Revisiones WHERE ID_Revision = ?",
            (id_revision,),
        )
        row = cursor.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Revisión no encontrada")
        id_version = row.ID_Version

        # PASO 1: Primero desalojar cualquier revisión actualmente Aprobada
        #         (garantiza exclusividad antes de crear el nuevo "verde")
        cursor.execute(
            "UPDATE Tbl_BOM_Revisiones SET Estado = 'OBSOLETO' "
            "WHERE ID_Version = ? AND ID_Revision != ? AND Estado = 'Aprobada'",
            (id_version, id_revision),
        )
        prev_aprobadas = cursor.rowcount

        # PASO 2: Marcar todo lo demás también como OBSOLETO (Borradores huérfanos, etc.)
        cursor.execute(
            "UPDATE Tbl_BOM_Revisiones SET Estado = 'OBSOLETO' "
            "WHERE ID_Version = ? AND ID_Revision != ? AND Estado != 'OBSOLETO'",
            (id_version, id_revision),
        )
        obsoletas = prev_aprobadas + cursor.rowcount

        # PASO 3: Aprobar — ahora sí, sin riesgo de dos verdes simultáneos
        cursor.execute(
            "UPDATE Tbl_BOM_Revisiones SET Estado = 'Aprobada' WHERE ID_Revision = ?",
            (id_revision,),
        )
        registrar_log(
            cursor,
            id_revision,
            "APROBAR_REVISION",
            f"Revisión {id_revision} aprobada. {obsoletas} revisión(es) anterior(es) marcadas como OBSOLETO.",
            usuario=_usuario_ingenieria(x_usuario),
        )
        conn.commit()
        return {"status": "success"}
    finally:
        conn.close()


def _physical_delete_revision_cascade(cursor, id_revision: int) -> None:
    """
    Borrado físico de una revisión BOM y toda su jerarquía (estructura, ensambles,
    estaciones, VINs). No valida contraseña ni estado.
    Omite Tbl_Log_Cambios_Ingenieria si la tabla no existe.
    """
    try:
        cursor.execute(
            "DELETE FROM Tbl_Log_Cambios_Ingenieria WHERE ID_Revision = ?",
            (id_revision,),
        )
    except pyodbc.Error:
        pass
    cursor.execute(
        """
        DELETE E FROM Tbl_BOM_Estructura E
        INNER JOIN Tbl_Ensambles EN ON E.ID_Ensamble = EN.ID_Ensamble
        INNER JOIN Tbl_Estaciones ES ON EN.ID_Estacion = ES.ID_Estacion
        WHERE ES.ID_Revision = ?
        """,
        (id_revision,),
    )
    cursor.execute(
        """
        DELETE EN FROM Tbl_Ensambles EN
        INNER JOIN Tbl_Estaciones ES ON EN.ID_Estacion = ES.ID_Estacion
        WHERE ES.ID_Revision = ?
        """,
        (id_revision,),
    )
    cursor.execute("DELETE FROM Tbl_Estaciones WHERE ID_Revision = ?", (id_revision,))
    cursor.execute("DELETE FROM Tbl_Unidades_Fisicas WHERE ID_Revision = ?", (id_revision,))
    cursor.execute("DELETE FROM Tbl_BOM_Revisiones WHERE ID_Revision = ?", (id_revision,))


def _purge_version_physical(cursor, id_version: int) -> int:
    """
    Elimina físicamente todas las revisiones de una versión, clientes de esa versión
    y la fila en Tbl_Versiones_Ingenieria. Retorna filas borradas en versiones (0 o 1).
    """
    cursor.execute(
        "SELECT ID_Revision FROM Tbl_BOM_Revisiones WHERE ID_Version = ?",
        (id_version,),
    )
    for row in cursor.fetchall():
        _physical_delete_revision_cascade(cursor, int(row[0]))
    cursor.execute(
        "DELETE FROM Tbl_Clientes_Configuracion WHERE ID_Version = ?",
        (id_version,),
    )
    cursor.execute(
        "DELETE FROM Tbl_Versiones_Ingenieria WHERE ID_Version = ?",
        (id_version,),
    )
    return cursor.rowcount


def _purge_tipo_physical(cursor, id_tipo: int) -> int:
    """Elimina todas las versiones (y BOM) de un tipo y luego el tipo. Retorna rowcount del tipo."""
    cursor.execute(
        "SELECT ID_Version FROM Tbl_Versiones_Ingenieria WHERE ID_Tipo = ?",
        (id_tipo,),
    )
    for row in cursor.fetchall():
        _purge_version_physical(cursor, int(row[0]))
    cursor.execute("DELETE FROM Tbl_Tipos_Proyecto WHERE ID_Tipo = ?", (id_tipo,))
    return cursor.rowcount


# ── NUEVO v60.1: Borrado de Revisión (con protección para Aprobadas) ──────────
@router.delete("/api/bom/revisiones/{id_revision}")
def eliminar_revision(
    id_revision: int,
    payload: EliminarRevisionPayload,
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
):
    """
    Borra una revisión y toda su estructura en cascada.
    - Borradores: no requieren contraseña.
    - Aprobadas: requieren la contraseña maestra de ingeniería.
    """
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # 1. Verificar existencia y estado
        cursor.execute(
            "SELECT Estado, Numero_Revision FROM Tbl_BOM_Revisiones WHERE ID_Revision = ?",
            (id_revision,)
        )
        row = cursor.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Revisión no encontrada")

        estado = row.Estado
        numero_revision = row.Numero_Revision

        # 2. Regla de Negocio:
        #    - Borradores/PENDIENTE: se borran sin contraseña.
        #    - Aprobada/OBSOLETO   : solo con contraseña correcta.
        ESTADOS_EDITABLES = {"Borrador", "PENDIENTE"}
        if estado not in ESTADOS_EDITABLES:
            assert_admin_master_password_matches(payload.password)

        # 3. Registrar en auditoría ANTES de borrar (sobrevive al borrado en cascada)
        usuario_log = _usuario_ingenieria(x_usuario)
        cursor.execute("""
            INSERT INTO Tbl_Auditoria_Cambios (Codigo_Pieza, Accion, Valor_Anterior, Valor_Nuevo, Usuario, Fecha_Hora)
            VALUES (?, ?, ?, ?, ?, GETDATE())
        """, (
            f"REV-{numero_revision}",
            "ELIMINAR_REVISION",
            f"ID_Revision: {id_revision}, Estado: {estado}",
            f"Motivo: {payload.motivo or 'N/A'}",
            usuario_log,
        ))
        conn.commit()  # Asegurar que el log quede persistido

        # 4. Borrado físico en cascada (misma lógica que _physical_delete_revision_cascade)
        _physical_delete_revision_cascade(cursor, id_revision)

        conn.commit()
        return {"status": "success", "message": f"Revisión {numero_revision} eliminada correctamente."}

    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error al eliminar revisión: {str(e)}")
    finally:
        conn.close()


# Endpoints VINs (Unidades Físicas)
@router.get("/api/bom/revisiones/{id_revision}/vins")
def get_vins(id_revision: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("SELECT ID_Unidad, Serie as VIN FROM Tbl_Unidades_Fisicas WHERE ID_Revision = ?", (id_revision,))
        rows = cursor.fetchall()
        return [{"id_unidad": r.ID_Unidad, "vin": r.VIN} for r in rows]
    finally:
        conn.close()

@router.get("/api/bom/buscar_pieza_jerarquia/{codigo_pieza}")
def buscar_pieza_jerarquia(codigo_pieza: str, exclude_rev: Optional[int] = None):
    """Búsqueda ascendente para el diálogo 'Propagar Cambios'.
    CORREGIDO: GROUP BY revision + STRING_AGG para clientes.
    Sin LEFT JOIN a Tbl_Clientes_Configuracion en el FROM → cero duplicados
    cuando una versión tiene múltiples clientes asociados."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # La subconsulta STRING_AGG reemplaza el LEFT JOIN directo que
        # producía N filas por revisión (una por cada cliente de la versión).
        base_query = """
            SELECT
                R.ID_Revision,
                TR.Nombre_Tracto,
                TP.Nombre_Tipo,
                V.Nombre_Version,
                V.ID_Version,
                R.Numero_Revision,
                R.Estado,
                SUM(E.Cantidad) AS Cantidad,
                ISNULL(
                    (SELECT STRING_AGG(C.Nombre_Cliente, ', ')
                     FROM Tbl_Clientes_Configuracion C
                     WHERE C.ID_Version = V.ID_Version),
                    'Ingeniería Base (Sin clientes)'
                ) AS Clientes_Afectados
            FROM Tbl_BOM_Estructura E
            JOIN Tbl_Ensambles           EN ON E.ID_Ensamble   = EN.ID_Ensamble
            JOIN Tbl_Estaciones          ES ON EN.ID_Estacion  = ES.ID_Estacion
            JOIN Tbl_BOM_Revisiones       R ON ES.ID_Revision  = R.ID_Revision
            JOIN Tbl_Versiones_Ingenieria V ON R.ID_Version    = V.ID_Version
            JOIN Tbl_Tipos_Proyecto      TP ON V.ID_Tipo       = TP.ID_Tipo
            JOIN Tbl_Proyectos_Tracto    TR ON TP.ID_Tracto    = TR.ID_Tracto
            WHERE E.Codigo_Pieza = ?
        """
        params: list = [codigo_pieza]

        if exclude_rev:
            base_query += " AND R.ID_Revision != ?"
            params.append(exclude_rev)

        base_query += """
            GROUP BY
                R.ID_Revision, TR.Nombre_Tracto, TP.Nombre_Tipo,
                V.Nombre_Version, V.ID_Version,
                R.Numero_Revision, R.Estado
            ORDER BY TR.Nombre_Tracto, TP.Nombre_Tipo, V.Nombre_Version, R.Numero_Revision
        """
        cursor.execute(base_query, params)
        return [
            {
                "id_revision":        r.ID_Revision,
                "tracto":             r.Nombre_Tracto,
                "tipo":               r.Nombre_Tipo,
                "version":            r.Nombre_Version,
                "clientes_afectados": r.Clientes_Afectados,
                "numero_revision":    r.Numero_Revision,
                "estado":             r.Estado,
                "cantidad":           float(r.Cantidad),
            }
            for r in cursor.fetchall()
        ]
    finally:
        conn.close()

@router.get("/api/bom/exportar/{id_revision}")
def exportar_bom(id_revision: int):
    """Exportación Pro: BOM + Historial de Auditoría en 2 pestañas."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # Pestaña 1: BOM
        cursor.execute(
            """
            SELECT ES.Nombre_Estacion, EN.Nombre_Ensamble, E.Codigo_Pieza,
                   M.Descripcion as Descripcion_Oficial, M.Medida, E.Cantidad,
                   M.Simetria, M.Proceso_Primario, M.Proceso_1, M.Proceso_2, M.Proceso_3, M.Link_Drive, E.Observaciones_Proceso
            FROM Tbl_BOM_Estructura E
            JOIN Tbl_Ensambles EN ON E.ID_Ensamble = EN.ID_Ensamble
            JOIN Tbl_Estaciones ES ON EN.ID_Estacion = ES.ID_Estacion
            LEFT JOIN Tbl_Maestro_Piezas M ON E.Codigo_Pieza = M.Codigo_Pieza
            WHERE ES.ID_Revision = ?
            ORDER BY ES.Orden, EN.Nombre_Ensamble
            """, (id_revision,)
        )
        bom_rows = cursor.fetchall()

        # Pestaña 2: Historial de Auditoría
        try:
            cursor.execute(
                "SELECT Usuario, Fecha_Hora, Accion, Detalle_Cambio, Motivo FROM Tbl_Log_Cambios_Ingenieria WHERE ID_Revision = ? ORDER BY Fecha_Hora DESC",
                (id_revision,)
            )
            log_rows = cursor.fetchall()
        except Exception:
            log_rows = []

        output = io.BytesIO()
        workbook = openpyxl.Workbook()

        # --- Pestaña 1: BOM (formato cliente: cabecera fila 5, datos desde fila 6) ---
        sheet_bom = workbook.active
        sheet_bom.title = "BOM"
        hdr_fill = PatternFill(start_color="1E3A8A", end_color="1E3A8A", fill_type="solid") # Azul Industrial
        hdr_font = Font(bold=True, color="FFFFFF")
        hdr_align = Alignment(horizontal="center")

        COL_ESTACION  = 2  # B
        COL_ENSAMBLE  = 3  # C
        COL_CODIGO    = 4  # D
        COL_DESC      = 5  # E
        COL_MEDIDA    = 6  # F
        COL_CANTIDAD  = 7  # G
        COL_SIMETRIA  = 8  # H
        COL_PROC_PRI  = 9  # I
        COL_PROC_1    = 10 # J
        COL_PROC_2    = 11 # K
        COL_PROC_3    = 12 # L
        COL_LINK      = 13 # M
        COL_OBS       = 14 # N
        HDR_ROW = 5
        DATA_ROW_START = 6

        headers = {
            COL_ESTACION: "Estación", COL_ENSAMBLE: "Ensamble",
            COL_CODIGO: "Código Pieza", COL_DESC: "Descripción",
            COL_MEDIDA: "Medida", COL_CANTIDAD: "Cantidad",
            COL_SIMETRIA: "Simetría", COL_PROC_PRI: "Proceso Primario",
            COL_PROC_1: "Proceso 1", COL_PROC_2: "Proceso 2", COL_PROC_3: "Proceso 3",
            COL_LINK: "Link Plano", COL_OBS: "Observaciones"
        }
        for col_idx, text in headers.items():
            cell = sheet_bom.cell(row=HDR_ROW, column=col_idx, value=text)
            cell.font = hdr_font
            cell.fill = hdr_fill
            cell.alignment = hdr_align

        for row_offset, r in enumerate(bom_rows):
            row_num = DATA_ROW_START + row_offset
            sheet_bom.cell(row=row_num, column=COL_ESTACION,  value=str(r.Nombre_Estacion))
            sheet_bom.cell(row=row_num, column=COL_ENSAMBLE,  value=str(r.Nombre_Ensamble))
            sheet_bom.cell(row=row_num, column=COL_CODIGO,    value=str(r.Codigo_Pieza))
            sheet_bom.cell(row=row_num, column=COL_DESC,      value=str(r.Descripcion_Oficial))
            sheet_bom.cell(row=row_num, column=COL_MEDIDA,    value=str(r.Medida))
            # CANTIDAD COMO NÚMERO PURO (float)
            try:
                cant_val = float(r.Cantidad)
            except:
                cant_val = 0.0
            sheet_bom.cell(row=row_num, column=COL_CANTIDAD,  value=cant_val)

            sheet_bom.cell(row=row_num, column=COL_SIMETRIA,  value=str(r.Simetria))
            sheet_bom.cell(row=row_num, column=COL_PROC_PRI,  value=str(r.Proceso_Primario))
            sheet_bom.cell(row=row_num, column=COL_PROC_1,    value=str(r.Proceso_1))
            sheet_bom.cell(row=row_num, column=COL_PROC_2,    value=str(r.Proceso_2))
            sheet_bom.cell(row=row_num, column=COL_PROC_3,    value=str(r.Proceso_3))
            sheet_bom.cell(row=row_num, column=COL_LINK,      value=str(r.Link_Drive))
            sheet_bom.cell(row=row_num, column=COL_OBS,       value=str(r.Observaciones_Proceso))

        # Auto-fit simple
        for col in sheet_bom.columns:
            max_length = 0
            column = col[0].column_letter
            for cell in col:
                try:
                    if len(str(cell.value)) > max_length:
                        max_length = len(str(cell.value))
                except:
                    pass
            adjusted_width = (max_length + 2) * 1.2
            sheet_bom.column_dimensions[column].width = min(adjusted_width, 50)

        # Ancho de columnas usadas
        anchos = [
            (COL_ESTACION, 22), (COL_ENSAMBLE, 28), (COL_CODIGO, 18),
            (COL_DESC, 30), (COL_MEDIDA, 15), (COL_CANTIDAD, 10),
            (COL_SIMETRIA, 15), (COL_PROC_PRI, 18), (COL_PROC_1, 15),
            (COL_PROC_2, 15), (COL_PROC_3, 15), (COL_LINK, 25), (COL_OBS, 25)
        ]
        for col_idx, ancho in anchos:
            col_letter = sheet_bom.cell(row=1, column=col_idx).column_letter
            sheet_bom.column_dimensions[col_letter].width = ancho

        # --- Pestaña 2: Historial ---
        sheet_log = workbook.create_sheet(title="Historial de Cambios")
        log_fill = PatternFill(start_color="2E7D32", end_color="2E7D32", fill_type="solid")
        log_headers = ["Usuario", "Fecha / Hora", "Acción", "Detalle", "Motivo"]
        sheet_log.append(log_headers)
        for cell in sheet_log[1]:
            cell.font = hdr_font; cell.fill = log_fill; cell.alignment = hdr_align
        for r in log_rows:
            sheet_log.append([
                r.Usuario,
                r.Fecha_Hora.strftime("%Y-%m-%d %H:%M:%S") if r.Fecha_Hora else '',
                r.Accion, r.Detalle_Cambio, r.Motivo or ''
            ])

        workbook.save(output)
        output.seek(0)

        return StreamingResponse(
            output,
            media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            headers={"Content-Disposition": f"attachment; filename=BOM_Rev{id_revision}_v60.xlsx"}
        )
    finally:
        conn.close()

@router.get("/api/bom/log/{id_revision}")
def get_log_auditoria(id_revision: int):
    """ADN de Ingeniería: historial completo de cambios de una revisión."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute(
            "SELECT ID_Log, Usuario, Fecha_Hora, Accion, Detalle_Cambio, Motivo FROM Tbl_Log_Cambios_Ingenieria WHERE ID_Revision = ? ORDER BY Fecha_Hora DESC",
            (id_revision,)
        )
        rows = cursor.fetchall()
        return [{
            "id_log": r.ID_Log,
            "usuario": r.Usuario,
            "fecha_hora": r.Fecha_Hora.isoformat() if r.Fecha_Hora else None,
            "accion": r.Accion,
            "detalle": r.Detalle_Cambio,
            "motivo": r.Motivo or ""
        } for r in rows]
    except Exception:
        return []  # Si la tabla aún no existe, retorna lista vacía
    finally:
        conn.close()

@router.put("/api/proyectos/clientes/{id_cliente}/asignar_revision")
def asignar_revision_cliente(id_cliente: int, payload: AsignarRevisionPayload):
    """Vincula un cliente a una revisión maestra específica."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute(
            "UPDATE Tbl_Clientes_Configuracion SET ID_Revision_Asignada = ? WHERE ID_Config_Cliente = ?",
            (payload.id_revision_asignada, id_cliente)
        )
        if cursor.rowcount == 0:
            raise HTTPException(status_code=404, detail="Cliente no encontrado")
        conn.commit()
        return {"status": "success"}
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

@router.post("/api/bom/revisiones/{id_revision}/vins")
def add_vin(id_revision: int, payload: VINPayload, x_usuario: Optional[str] = Header(None)):
    conn = get_db_connection()
    cursor = conn.cursor()
    usuario_real = _usuario_ingenieria(x_usuario)
    try:
        val = payload.observaciones if payload.observaciones is not None else payload.notas
        vin_upper = (payload.vin or "").strip().upper()
        if not vin_upper:
            raise HTTPException(status_code=400, detail="VIN vacío")

        # Prevención de duplicados por revisión para evitar excepción SQL.
        cursor.execute(
            "SELECT 1 FROM Tbl_Unidades_Fisicas WHERE ID_Revision = ? AND Serie = ?",
            (id_revision, vin_upper),
        )
        if cursor.fetchone():
            raise HTTPException(status_code=400, detail="El VIN ya está asignado a esta revisión")

        try:
            cursor.execute(
                "INSERT INTO Tbl_Unidades_Fisicas (ID_Revision, Serie, Observaciones) OUTPUT INSERTED.ID_Unidad VALUES (?, ?, ?)",
                (id_revision, vin_upper, val or ""),
            )
            id_gen = cursor.fetchone()[0]
        except Exception as e:
            print(f"Error SQL al insertar VIN: {e}")
            raise HTTPException(status_code=400, detail=f"Error al guardar VIN: {str(e)}")

        # Log assignment
        cursor.execute("""
            SELECT R.Numero_Revision, V.Nombre_Version, TR.Nombre_Tracto
            FROM Tbl_BOM_Revisiones R
            JOIN Tbl_Versiones_Ingenieria V ON R.ID_Version = V.ID_Version
            JOIN Tbl_Tipos_Proyecto TP ON V.ID_Tipo = TP.ID_Tipo
            JOIN Tbl_Proyectos_Tracto TR ON TP.ID_Tracto = TR.ID_Tracto
            WHERE R.ID_Revision = ?
        """, (id_revision,))
        rev_info = cursor.fetchone()
        proyecto = f"{rev_info.Nombre_Tracto} - {rev_info.Nombre_Version} (Rev {rev_info.Numero_Revision})" if rev_info else str(id_revision)

        cursor.execute("""
            INSERT INTO Tbl_Auditoria_Cambios (Codigo_Pieza, Accion, Valor_Anterior, Valor_Nuevo, Usuario, Fecha_Hora)
            VALUES (?, ?, ?, ?, ?, GETDATE())
        """, (
            f"VIN-{vin_upper}",
            "VIN ASIGNADO",
            "N/A",
            f"Serie {vin_upper} vinculada a {proyecto}",
            usuario_real  # === TAREA 2: usuario real en lugar de string quemado ===
        ))

        # We also can log it in Tbl_Log_Cambios_Ingenieria if it's for the revision, but user says Tbl_Auditoria_Cambios
        registrar_log(
            cursor,
            id_revision,
            "VIN_CREADO",
            f"VIN {vin_upper} registrado a la revisión.",
            usuario=usuario_real,
        )
        
        conn.commit()
        return {"status": "success", "id_unidad": id_gen}
    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error al agregar VIN: {str(e)}")
    finally:
        conn.close()

@router.delete("/api/bom/vins/{id_unidad}")
def delete_vin_simple(id_unidad: int, x_usuario: Optional[str] = Header(None)):
    usuario_real = _usuario_ingenieria(x_usuario)
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # Log de auditoría antes de eliminar
        cursor.execute("SELECT Serie FROM Tbl_Unidades_Fisicas WHERE ID_Unidad = ?", (id_unidad,))
        row = cursor.fetchone()
        if row:
            cursor.execute(
                "INSERT INTO Tbl_Auditoria_Cambios (Codigo_Pieza, Accion, Valor_Anterior, Valor_Nuevo, Usuario, Fecha_Hora) VALUES (?, 'ELIMINAR_VIN', ?, ?, ?, GETDATE())",
                (f"VIN-{row.Serie}", row.Serie, "Eliminado desde gestor BOM", usuario_real)
            )
        cursor.execute("DELETE FROM Tbl_Unidades_Fisicas WHERE ID_Unidad = ?", (id_unidad,))
        conn.commit()
        return {"status": "success"}
    finally:
        conn.close()
def _next_codigo_ensamble_seq(cursor) -> list:
    """
    Devuelve una función generadora de códigos E-NNNN únicos.
    Lee el MAX actual una sola vez y entrega un callable que incrementa.
    """
    cursor.execute(
        "SELECT MAX(Codigo_Ensamble) FROM Tbl_Ensambles WHERE Codigo_Ensamble LIKE 'E-%'"
    )
    row = cursor.fetchone()
    seq = 0
    if row and row[0]:
        try:
            seq = int(row[0].split("-")[1]) + 1
        except (ValueError, IndexError):
            pass
    counter = [seq]

    def _next():
        code = f"E-{counter[0]:04d}"
        counter[0] += 1
        return code

    return _next


@router.post("/api/bom/clonar")
def clonar_bom(payload: ClonarPayload):
    """Copia la estructura de una revisión origen EN una revisión destino ya existente."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        next_code = _next_codigo_ensamble_seq(cursor)

        cursor.execute(
            "SELECT ID_Estacion, Nombre_Estacion, Orden FROM Tbl_Estaciones WHERE ID_Revision = ?",
            (payload.id_revision_origen,),
        )
        estaciones = cursor.fetchall()

        for est_orig in estaciones:
            cursor.execute(
                "INSERT INTO Tbl_Estaciones (ID_Revision, Nombre_Estacion, Orden) "
                "OUTPUT INSERTED.ID_Estacion VALUES (?, ?, ?)",
                (payload.id_revision_destino, est_orig.Nombre_Estacion, est_orig.Orden),
            )
            id_est_dest = cursor.fetchone()[0]

            cursor.execute(
                "SELECT ID_Ensamble, Nombre_Ensamble FROM Tbl_Ensambles WHERE ID_Estacion = ?",
                (est_orig.ID_Estacion,),
            )
            for ens_orig in cursor.fetchall():
                cursor.execute(
                    "INSERT INTO Tbl_Ensambles (ID_Estacion, Codigo_Ensamble, Nombre_Ensamble) "
                    "OUTPUT INSERTED.ID_Ensamble VALUES (?, ?, ?)",
                    (id_est_dest, next_code(), ens_orig.Nombre_Ensamble),
                )
                id_ens_dest = cursor.fetchone()[0]

                cursor.execute(
                    "SELECT Codigo_Pieza, Cantidad, Observaciones_Proceso "
                    "FROM Tbl_BOM_Estructura WHERE ID_Ensamble = ?",
                    (ens_orig.ID_Ensamble,),
                )
                for p in cursor.fetchall():
                    cursor.execute(
                        "INSERT INTO Tbl_BOM_Estructura "
                        "(ID_Ensamble, Codigo_Pieza, Cantidad, Observaciones_Proceso) "
                        "VALUES (?, ?, ?, ?)",
                        (id_ens_dest, p.Codigo_Pieza, p.Cantidad, p.Observaciones_Proceso or ""),
                    )

        conn.commit()
        return {"status": "success", "detalle": f"Clonadas {len(estaciones)} estaciones."}
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error al clonar: {str(e)}")
    finally:
        conn.close()


@router.post("/api/bom/clonar/{id_revision_origen}")
def deep_copy_bom(
    id_revision_origen: int,
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
):
    """
    Deep Copy: crea una revisión nueva completa (Borrador) copiando toda la
    jerarquía Estaciones → Ensambles → BOM_Estructura del origen.
    Devuelve el nuevo ID_Revision y su Numero_Revision.
    """
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # 1. Verificar origen y obtener ID_Version
        cursor.execute(
            "SELECT ID_Version, Numero_Revision FROM Tbl_BOM_Revisiones WHERE ID_Revision = ?",
            (id_revision_origen,),
        )
        origen = cursor.fetchone()
        if not origen:
            raise HTTPException(status_code=404, detail="Revisión origen no encontrada")
        id_version = origen.ID_Version
        num_rev_origen = origen.Numero_Revision

        # 2. Calcular el siguiente número de revisión para esta versión
        cursor.execute(
            "SELECT ISNULL(MAX(Numero_Revision), -1) + 1 FROM Tbl_BOM_Revisiones WHERE ID_Version = ?",
            (id_version,),
        )
        siguiente_rev = int(cursor.fetchone()[0])

        # 3. Insertar nueva revisión en estado Borrador
        cursor.execute(
            "INSERT INTO Tbl_BOM_Revisiones (ID_Version, Numero_Revision, Estado) "
            "OUTPUT INSERTED.ID_Revision VALUES (?, ?, 'Borrador')",
            (id_version, siguiente_rev),
        )
        nuevo_id_revision = cursor.fetchone()[0]

        # 4. Obtener generador de códigos únicos ANTES del loop
        next_code = _next_codigo_ensamble_seq(cursor)

        # 5. Clonar Estaciones con mapeo de IDs
        cursor.execute(
            "SELECT ID_Estacion, Nombre_Estacion, Orden FROM Tbl_Estaciones "
            "WHERE ID_Revision = ? ORDER BY Orden",
            (id_revision_origen,),
        )
        estaciones = cursor.fetchall()
        total_piezas = 0

        for est in estaciones:
            cursor.execute(
                "INSERT INTO Tbl_Estaciones (ID_Revision, Nombre_Estacion, Orden) "
                "OUTPUT INSERTED.ID_Estacion VALUES (?, ?, ?)",
                (nuevo_id_revision, est.Nombre_Estacion, est.Orden),
            )
            nuevo_id_estacion = cursor.fetchone()[0]

            # 6. Clonar Ensambles de esta estación
            cursor.execute(
                "SELECT ID_Ensamble, Nombre_Ensamble FROM Tbl_Ensambles WHERE ID_Estacion = ?",
                (est.ID_Estacion,),
            )
            ensambles = cursor.fetchall()

            for ens in ensambles:
                cursor.execute(
                    "INSERT INTO Tbl_Ensambles (ID_Estacion, Codigo_Ensamble, Nombre_Ensamble) "
                    "OUTPUT INSERTED.ID_Ensamble VALUES (?, ?, ?)",
                    (nuevo_id_estacion, next_code(), ens.Nombre_Ensamble),
                )
                nuevo_id_ensamble = cursor.fetchone()[0]

                # 6. Clonar piezas del ensamble
                cursor.execute(
                    "SELECT Codigo_Pieza, Cantidad, Observaciones_Proceso "
                    "FROM Tbl_BOM_Estructura WHERE ID_Ensamble = ?",
                    (ens.ID_Ensamble,),
                )
                piezas = cursor.fetchall()
                total_piezas += len(piezas)

                for p in piezas:
                    cursor.execute(
                        "INSERT INTO Tbl_BOM_Estructura "
                        "(ID_Ensamble, Codigo_Pieza, Cantidad, Observaciones_Proceso) "
                        "VALUES (?, ?, ?, ?)",
                        (nuevo_id_ensamble, p.Codigo_Pieza, p.Cantidad, p.Observaciones_Proceso or ""),
                    )

        registrar_log(
            cursor,
            nuevo_id_revision,
            "CLONAR_BOM",
            f"Deep copy desde Rev {num_rev_origen} (ID {id_revision_origen}). "
            f"{len(estaciones)} estaciones, {total_piezas} piezas.",
            usuario=_usuario_ingenieria(x_usuario),
        )
        conn.commit()
        return {
            "nuevo_id_revision": nuevo_id_revision,
            "numero_revision": siguiente_rev,
            "estaciones_clonadas": len(estaciones),
            "piezas_clonadas": total_piezas,
        }
    except HTTPException:
        raise
    except pyodbc.Error as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error SQL al clonar BOM: {str(e)}")
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error al clonar BOM: {str(e)}")
    finally:
        conn.close()


# ── Control de Cambios (ECR) ──────────────────────────────────────────────────
@router.post("/api/bom/branching")
def branching_ecr(
    payload: BranchingPayload,
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
):
    """
    Gatillo de Edición — PLM Change Control.

    GLOBAL   : Crea Rev N+1 en la misma versión clonando toda la BOM. Estado: Borrador.
    ESPECIFICO: Crea una nueva Versión de Ingeniería, mueve los clientes indicados
                y clona la BOM como Revisión 0. Estado: Borrador.
    """
    conn = get_db_connection()
    cursor = conn.cursor()
    usuario_log = _usuario_ingenieria(x_usuario)
    try:
        # ── 1. Verificar origen ───────────────────────────────────────────────
        cursor.execute(
            "SELECT ID_Version, Numero_Revision, Estado "
            "FROM Tbl_BOM_Revisiones WHERE ID_Revision = ?",
            (payload.id_revision_origen,),
        )
        origen = cursor.fetchone()
        if not origen:
            raise HTTPException(status_code=404, detail="Revisión origen no encontrada.")
        id_version_origen = origen.ID_Version
        num_rev_origen    = origen.Numero_Revision

        # ── 2. Crear la nueva revisión según tipo ─────────────────────────────
        if payload.tipo_cambio == "GLOBAL":
            cursor.execute(
                "SELECT ISNULL(MAX(Numero_Revision), -1) + 1 FROM Tbl_BOM_Revisiones "
                "WHERE ID_Version = ?",
                (id_version_origen,),
            )
            siguiente_rev = int(cursor.fetchone()[0])
            cursor.execute(
                "INSERT INTO Tbl_BOM_Revisiones (ID_Version, Numero_Revision, Estado) "
                "OUTPUT INSERTED.ID_Revision VALUES (?, ?, 'Borrador')",
                (id_version_origen, siguiente_rev),
            )
            nuevo_id_revision = cursor.fetchone()[0]
            id_version_nueva  = id_version_origen

        elif payload.tipo_cambio == "ESPECIFICO":
            # 1. Permitir ESPECIFICO sin clientes iniciales
            clientes_a_mover = payload.lista_clientes or []
            
            # 2. Obtener ID_Tipo de la versión origen
            cursor.execute(
                "SELECT ID_Tipo, Nombre_Version FROM Tbl_Versiones_Ingenieria "
                "WHERE ID_Version = ?",
                (id_version_origen,),
            )
            ver_orig = cursor.fetchone()
            if not ver_orig:
                raise HTTPException(status_code=404, detail="Versión origen no encontrada.")
            id_tipo = ver_orig.ID_Tipo

            # 3. Lógica de Nomenclatura Secuencial PLM (V1, V2, V3...)
            cursor.execute("SELECT Nombre_Version FROM Tbl_Versiones_Ingenieria WHERE ID_Tipo = ?", (id_tipo,))
            nombres_existentes = [row[0] for row in cursor.fetchall()]
            max_v = 0
            for n in nombres_existentes:
                try:
                    if n.upper().startswith('V'):
                        num = int(n[1:])
                        if num > max_v: max_v = num
                except ValueError:
                    pass
            
            nuevo_num = max_v + 1 if max_v > 0 else len(nombres_existentes) + 1
            nombre_fork = f"V{nuevo_num}"

            # 4. Crear la Nueva Versión en BD
            cursor.execute(
                "INSERT INTO Tbl_Versiones_Ingenieria (ID_Tipo, Nombre_Version) "
                "OUTPUT INSERTED.ID_Version VALUES (?, ?)",
                (id_tipo, nombre_fork),
            )
            id_version_nueva = cursor.fetchone()[0]

            # 5. Mover los clientes seleccionados a la nueva versión
            if clientes_a_mover:
                for id_cli in clientes_a_mover:
                    cursor.execute(
                        "UPDATE Tbl_Clientes_Configuracion SET ID_Version = ? "
                        "WHERE ID_Config_Cliente = ?",
                        (id_version_nueva, id_cli),
                    )

            # 6. Crear Revisión 0 
            cursor.execute(
                "INSERT INTO Tbl_BOM_Revisiones (ID_Version, Numero_Revision, Estado) "
                "OUTPUT INSERTED.ID_Revision VALUES (?, 0, 'Borrador')",
                (id_version_nueva,),
            )
            nuevo_id_revision = cursor.fetchone()[0]

            # 7. Log Seguro 
            mensaje_log = f"Creada {nombre_fork} desde original con {len(clientes_a_mover)} clientes."
            registrar_log(
                cursor,
                nuevo_id_revision,
                "DERIVACION",
                mensaje_log,
                "Cambio Específico de Clientes",
                usuario=usuario_log,
            )
            
            siguiente_rev = 0

        else:
            raise HTTPException(
                status_code=400,
                detail="tipo_cambio debe ser 'GLOBAL' o 'ESPECIFICO'.",
            )

        # ── 3. Clonar estructura BOM ──────────────────────────────────────────
        next_code = _next_codigo_ensamble_seq(cursor)

        cursor.execute(
            "SELECT ID_Estacion, Nombre_Estacion, Orden FROM Tbl_Estaciones "
            "WHERE ID_Revision = ? ORDER BY Orden",
            (payload.id_revision_origen,),
        )
        estaciones  = cursor.fetchall()
        total_piezas = 0

        for est in estaciones:
            cursor.execute(
                "INSERT INTO Tbl_Estaciones (ID_Revision, Nombre_Estacion, Orden) "
                "OUTPUT INSERTED.ID_Estacion VALUES (?, ?, ?)",
                (nuevo_id_revision, est.Nombre_Estacion, est.Orden),
            )
            nuevo_id_est = cursor.fetchone()[0]

            cursor.execute(
                "SELECT ID_Ensamble, Nombre_Ensamble FROM Tbl_Ensambles "
                "WHERE ID_Estacion = ?",
                (est.ID_Estacion,),
            )
            for ens in cursor.fetchall():
                cursor.execute(
                    "INSERT INTO Tbl_Ensambles (ID_Estacion, Codigo_Ensamble, Nombre_Ensamble) "
                    "OUTPUT INSERTED.ID_Ensamble VALUES (?, ?, ?)",
                    (nuevo_id_est, next_code(), ens.Nombre_Ensamble),
                )
                nuevo_id_ens = cursor.fetchone()[0]

                cursor.execute(
                    "SELECT Codigo_Pieza, Cantidad, Observaciones_Proceso "
                    "FROM Tbl_BOM_Estructura WHERE ID_Ensamble = ?",
                    (ens.ID_Ensamble,),
                )
                for p in cursor.fetchall():
                    cursor.execute(
                        "INSERT INTO Tbl_BOM_Estructura "
                        "(ID_Ensamble, Codigo_Pieza, Cantidad, Observaciones_Proceso) "
                        "VALUES (?, ?, ?, ?)",
                        (nuevo_id_ens, p.Codigo_Pieza, p.Cantidad, p.Observaciones_Proceso or ""),
                    )
                    total_piezas += 1

        registrar_log(
            cursor,
            nuevo_id_revision,
            "ECR_BRANCHING",
            f"Rama {payload.tipo_cambio} desde Rev {num_rev_origen} (ID {payload.id_revision_origen}). "
            f"{len(estaciones)} estaciones, {total_piezas} piezas clonadas.",
            usuario=usuario_log,
        )
        conn.commit()
        return {
            "nuevo_id_revision": nuevo_id_revision,
            "numero_revision":   siguiente_rev,
            "id_version_nueva":  id_version_nueva,
            "tipo_cambio":       payload.tipo_cambio,
            "estaciones":        len(estaciones),
            "piezas":            total_piezas,
        }

    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error en branching ECR: {str(e)}")
    finally:
        conn.close()


# === BLOQUE 3: BUSCADOR DE PLANOS DXF/PDF ===
RUTA_PLANOS = r"C:\Planos_Temporales"

# Palabras clave (en minúsculas) en el nombre de una carpeta que la marcan como basura.
# Se usa coincidencia de subcadena: si alguna de estas aparece en el nombre, se omite.
_CARPETAS_BASURA = {"obsoleto", "0-obsoleto", "soleto", "el soleto"}
_EXTENSIONES_PLANO = {".dxf", ".pdf"}

@router.post("/api/bom/buscar_planos")
def buscar_planos(payload: BuscarPlanosPayload):
    """
    Auditoría de planos: búsqueda RECURSIVA de archivos .dxf/.pdf.

    - Ignora carpetas cuyo nombre (en minúsculas) contenga palabras de _CARPETAS_BASURA.
    - Si un código aparece en varios archivos, conserva el de fecha de modificación
      más reciente (resolución de duplicados).
    - BLINDADO: nunca lanza HTTP 500 por problemas de ruta o permisos.
    """
    _safe_faltantes = [c.strip().upper() for c in payload.codigos if c.strip()]

    ruta_str = payload.ruta_base.strip() if payload.ruta_base.strip() else RUTA_PLANOS

    # ── Verificación defensiva de la ruta ────────────────────────────────────
    if not os.path.exists(ruta_str):
        return {
            "encontrados": [],
            "faltantes": _safe_faltantes,
            "advertencia": f"Ruta no encontrada o inaccesible: {ruta_str}",
        }

    # ── Escaneo recursivo (una sola pasada) ───────────────────────────────────
    # Construimos: lista de tuplas (nombre_upper, nombre_original, mtime)
    # Modificar dirnames[:] en-lugar impide que os.walk descienda a carpetas basura.
    archivos_en_disco: list = []   # (nombre_upper, nombre_original, mtime)
    try:
        for dirpath, dirnames, filenames in os.walk(ruta_str):
            # Filtrar subcarpetas basura IN-PLACE ──────────────────────────────
            dirnames[:] = [
                d for d in dirnames
                if not any(kw in d.lower() for kw in _CARPETAS_BASURA)
            ]
            for fname in filenames:
                if os.path.splitext(fname)[1].lower() not in _EXTENSIONES_PLANO:
                    continue
                fpath = os.path.join(dirpath, fname)
                try:
                    mtime = os.path.getmtime(fpath)
                except OSError:
                    mtime = 0.0
                archivos_en_disco.append((fname.upper(), fname, mtime))
    except PermissionError:
        return {
            "encontrados": [],
            "faltantes": _safe_faltantes,
            "advertencia": f"Sin permisos para leer la ruta: {ruta_str}",
        }
    except OSError as exc:
        return {
            "encontrados": [],
            "faltantes": _safe_faltantes,
            "advertencia": f"Error de sistema al leer la ruta ({exc}): {ruta_str}",
        }

    # ── Matching de códigos con resolución de duplicados ─────────────────────
    encontrados: list = []
    faltantes: list = []

    for codigo in payload.codigos:
        codigo_limpio = codigo.strip().upper()
        if not codigo_limpio:
            continue

        # Recoger TODAS las coincidencias (puede haber el mismo código en varias carpetas)
        coincidencias = [
            (nombre_orig, mtime)
            for nombre_upper, nombre_orig, mtime in archivos_en_disco
            if codigo_limpio in nombre_upper
        ]

        if coincidencias:
            # Quedarse únicamente con el archivo más reciente
            mejor_archivo, _ = max(coincidencias, key=lambda x: x[1])
            encontrados.append({"codigo": codigo_limpio, "archivo": mejor_archivo})
        else:
            faltantes.append(codigo_limpio)

    return {"encontrados": encontrados, "faltantes": faltantes, "advertencia": None}


@router.post("/api/bom/propagar")
def propagar_cambios(payload: PropagarPayload):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        if not payload.id_revisiones:
            return {"status": "ignored", "mensaje": "No se seleccionaron revisiones"}
            
        # Generar placeholders para la lista de IDs
        placeholders = ",".join(["?"] * len(payload.id_revisiones))
        query = f"""
            UPDATE be
            SET be.Cantidad = ?
            FROM Tbl_BOM_Estructura be
            JOIN Tbl_Ensambles en ON be.ID_Ensamble = en.ID_Ensamble
            JOIN Tbl_Estaciones es ON en.ID_Estacion = es.ID_Estacion
            WHERE be.Codigo_Pieza = ? AND es.ID_Revision IN ({placeholders})
        """
        params = [payload.nueva_cantidad, payload.codigo_pieza] + payload.id_revisiones
        cursor.execute(query, params)
        affected = cursor.rowcount
        conn.commit()
        return {"status": "success", "afectados": affected}
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error en propagación: {str(e)}")
    finally:
        conn.close()

@router.post("/api/bom/estaciones")
def add_estacion(payload: EstacionPayload):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("INSERT INTO Tbl_Estaciones (ID_Revision, Nombre_Estacion, Orden) VALUES (?, ?, ?)", (payload.id_revision, payload.nombre.upper(), 0))
        conn.commit()
        return {"status": "success"}
    except pyodbc.IntegrityError as e:
        conn.rollback()
        raise HTTPException(status_code=400, detail=f"Error al agregar Estación. Asegúrate de que no exista duplicada. Detalle: {str(e)}")
    except pyodbc.Error as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error SQL interno en Estación: {str(e)}")
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error interno: {str(e)}")
    finally:
        conn.close()

@router.delete("/api/bom/estaciones/{id_estacion}")
def delete_estacion(id_estacion: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # Borrar piezas de sus ensambles
        cursor.execute("SELECT ID_Ensamble FROM Tbl_Ensambles WHERE ID_Estacion = ?", (id_estacion,))
        ensambles = cursor.fetchall()
        for ens in ensambles:
            cursor.execute("DELETE FROM Tbl_BOM_Estructura WHERE ID_Ensamble = ?", (ens.ID_Ensamble,))
        
        # Borrar los ensambles
        cursor.execute("DELETE FROM Tbl_Ensambles WHERE ID_Estacion = ?", (id_estacion,))
        
        # Borrar la estacion
        cursor.execute("DELETE FROM Tbl_Estaciones WHERE ID_Estacion = ?", (id_estacion,))
        conn.commit()
        return {"status": "success"}
    except pyodbc.Error as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error SQL al eliminar estación: {str(e)}")
    finally:
        conn.close()

@router.get("/api/bom/ensambles/{id_estacion}")
def get_ensambles(id_estacion: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("SELECT ID_Ensamble, ID_Estacion, Codigo_Ensamble, Nombre_Ensamble FROM Tbl_Ensambles WHERE ID_Estacion = ? ORDER BY Nombre_Ensamble", (id_estacion,))
        rows = cursor.fetchall()
        return [{"id": r.ID_Ensamble, "id_estacion": r.ID_Estacion, "codigo_ensamble": r.Codigo_Ensamble, "nombre": r.Nombre_Ensamble} for r in rows]
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error al obtener ensambles: {str(e)}")
    finally:
        conn.close()

@router.post("/api/bom/ensambles")
def add_ensamble(
    payload: EnsamblePayload,
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # Insertar ensamble
        cursor.execute(
            "INSERT INTO Tbl_Ensambles (ID_Estacion, Codigo_Ensamble, Nombre_Ensamble) VALUES (?, ?, ?)",
            (payload.id_estacion, "N/A", payload.nombre.upper())
        )
        # Recuperar ID_Revision para el log (via Tbl_Estaciones)
        cursor.execute("SELECT ID_Revision FROM Tbl_Estaciones WHERE ID_Estacion = ?", (payload.id_estacion,))
        rev_row = cursor.fetchone()
        if rev_row:
            registrar_log(
                cursor,
                rev_row.ID_Revision,
                "AGREGAR_ENSAMBLE",
                f"Nuevo ensamble '{payload.nombre.upper()}' en estación {payload.id_estacion}.",
                usuario=_usuario_ingenieria(x_usuario),
            )
        conn.commit()
        return {"status": "success"}
    except pyodbc.IntegrityError as e:
        conn.rollback()
        raise HTTPException(status_code=400, detail=f"Error de integridad en Ensamble. Detalle: {str(e)}")
    except pyodbc.Error as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error SQL en Ensamble: {str(e)}")
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error interno: {str(e)}")
    finally:
        conn.close()

@router.get("/api/bom/{id_revision}/calcular_placas")
def calcular_placas(id_revision: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("""
            SELECT m.Material, m.Largo_CAD, m.Ancho_CAD, e.Cantidad,
                   ISNULL(m.Descripcion, '') AS Descripcion,
                   ISNULL(m.Codigo_Pieza, '') AS Codigo_Pieza
            FROM Tbl_BOM_Estructura e
            INNER JOIN Tbl_Maestro_Piezas m ON e.Codigo_Pieza = m.Codigo_Pieza
            INNER JOIN Tbl_Ensambles en ON e.ID_Ensamble = en.ID_Ensamble
            INNER JOIN Tbl_Estaciones es ON en.ID_Estacion = es.ID_Estacion
            WHERE es.ID_Revision = ? AND m.Largo_CAD > 0 AND m.Ancho_CAD > 0
              AND m.Material IS NOT NULL AND m.Material != ''
        """, (id_revision,))

        placas = {}
        compra_directa = {}

        for row in cursor.fetchall():
            material    = str(row.Material).strip()    if row.Material    else "Sin Especificar"
            descripcion = str(row.Descripcion).strip() if row.Descripcion else ""
            codigo      = str(row.Codigo_Pieza).strip() if row.Codigo_Pieza else ""
            cantidad    = float(row.Cantidad)

            # Piezas COMERCIALES → compra directa, sin cálculo de placas
            es_comercial = (
                "COMERCIAL" in material.upper() or
                "COMERCIAL" in descripcion.upper()
            )
            if es_comercial:
                clave = descripcion or codigo or material
                if clave not in compra_directa:
                    compra_directa[clave] = {"cantidad_total": 0, "codigo": codigo}
                compra_directa[clave]["cantidad_total"] += int(cantidad)
                continue

            largo  = float(row.Largo_CAD)
            ancho  = float(row.Ancho_CAD)
            area_pieza = largo * ancho
            area_total = area_pieza * cantidad

            if material not in placas:
                placas[material] = {"area_total_mm2": 0.0, "piezas_involucradas": 0}
            placas[material]["area_total_mm2"]    += area_total
            placas[material]["piezas_involucradas"] += int(cantidad)

        return {"placas": placas, "compra_directa": compra_directa}
    except pyodbc.Error as e:
        raise HTTPException(status_code=500, detail=f"Error SQL en cálculo de placas: {str(e)}")
    finally:
        conn.close()

@router.delete("/api/bom/ensambles/{id_ensamble}")
def delete_ensamble(id_ensamble: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # Borrar piezas
        cursor.execute("DELETE FROM Tbl_BOM_Estructura WHERE ID_Ensamble = ?", (id_ensamble,))
        
        # Borrar ensamble
        cursor.execute("DELETE FROM Tbl_Ensambles WHERE ID_Ensamble = ?", (id_ensamble,))
        conn.commit()
        return {"status": "success"}
    except pyodbc.Error as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error SQL al eliminar ensamble: {str(e)}")
    finally:
        conn.close()

@router.get("/api/bom/estructura/{id_ensamble}")
def get_bom_estructura(id_ensamble: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("""
            SELECT e.ID_BOM, e.Codigo_Pieza, m.Descripcion, e.Cantidad, e.Observaciones_Proceso
            FROM Tbl_BOM_Estructura e
            LEFT JOIN Tbl_Maestro_Piezas m ON e.Codigo_Pieza = m.Codigo_Pieza
            WHERE e.ID_Ensamble = ?
        """, (id_ensamble,))
        rows = cursor.fetchall()
        return [{
            "id": r.ID_BOM,
            "codigo": r.Codigo_Pieza,
            "descripcion": getattr(r, 'Descripcion', 'Descripción no encontrada') if getattr(r, 'Descripcion', None) else "Descripción no encontrada",
            "cantidad": r.Cantidad,
            "observaciones": r.Observaciones_Proceso or ""
        } for r in rows]
    except pyodbc.Error as e:
        raise HTTPException(status_code=500, detail=f"Error SQL al obtener estructura: {str(e)}")
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error interno al obtener estructura: {str(e)}")
    finally:
        conn.close()

@router.post("/api/bom/estructura")
def add_bom_estructura(
    payload: BOMPayload,
    authorization: Optional[str] = Header(None),
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        codigo = (payload.codigo_pieza or "").strip()
        if not codigo:
            raise HTTPException(status_code=400, detail="Código de pieza vacío")

        ulog = resolve_actor_user(authorization, x_usuario)
        if ulog == "Sistema":
            ulog = _usuario_ingenieria(x_usuario)

        cursor.execute(
            "SELECT Codigo_Pieza FROM Tbl_Maestro_Piezas WHERE Codigo_Pieza = ?",
            (codigo,),
        )
        en_catalogo = cursor.fetchone() is not None

        if not en_catalogo:
            if payload.maestro is None:
                raise HTTPException(
                    status_code=400,
                    detail=(
                        "La pieza no está en el catálogo. "
                        "Indique descripción, material y procesos o registre la pieza antes."
                    ),
                )
            m = payload.maestro
            _insert_maestro_pieza_al_vuelo(cursor, codigo, m, ulog)

        # BOMPayload.observaciones → Observaciones_Proceso (línea BOM)
        cursor.execute("""
            INSERT INTO Tbl_BOM_Estructura (ID_Ensamble, Codigo_Pieza, Cantidad, Observaciones_Proceso)
            VALUES (?, ?, ?, ?)
        """, (payload.id_ensamble, codigo, payload.cantidad, payload.observaciones))
        # Recuperar ID_Revision para el log
        cursor.execute("""
            SELECT ES.ID_Revision FROM Tbl_Ensambles EN
            INNER JOIN Tbl_Estaciones ES ON EN.ID_Estacion = ES.ID_Estacion
            WHERE EN.ID_Ensamble = ?
        """, (payload.id_ensamble,))
        rev_row = cursor.fetchone()
        if rev_row:
            registrar_log(
                cursor,
                rev_row.ID_Revision,
                "AGREGAR_PIEZA",
                f"Pieza '{codigo}' x{payload.cantidad} agregada al ensamble {payload.id_ensamble}.",
                usuario=ulog,
            )
        conn.commit()
        return {"status": "success"}
    except HTTPException:
        conn.rollback()
        raise
    except pyodbc.IntegrityError as e:
        conn.rollback()
        print(f"ERROR SQL EN ALTA AL VUELO (integridad): {e!s}")
        traceback.print_exc()
        raise HTTPException(status_code=400, detail=f"Error de integridad en BOM. Verifica Código existete: {str(e)}")
    except pyodbc.Error as e:
        conn.rollback()
        print(f"ERROR SQL EN ALTA AL VUELO (pyodbc): {e!s}")
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))
    except Exception as e:
        conn.rollback()
        print(f"ERROR SQL EN ALTA AL VUELO: {e!s}")
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

@router.delete("/api/bom/estructura/{id_bom}")
def delete_bom_estructura(id_bom: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("DELETE FROM Tbl_BOM_Estructura WHERE ID_BOM = ?", (id_bom,))
        conn.commit()
        return {"status": "success"}
    except pyodbc.Error as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error SQL al eliminar BOM_Estructura: {str(e)}")
    finally:
        conn.close()

# ─── Schema-adaptive helpers ────────────────────────────────────────────────

# Caché a nivel de módulo: se llena la primera vez que se llama a
# _get_maestro_cols() y se reutiliza en todas las requests siguientes.
# Elimina la necesidad de abrir un cursor extra por cada request de árbol/plana.
_MAESTRO_COLS_CACHE: set = set()


def _insert_maestro_pieza_al_vuelo(cursor, codigo: str, m: "MaestroPiezaBomPayload", usuario: str) -> None:
    """
    INSERT en Tbl_Maestro_Piezas al agregar pieza nueva desde BOM.
    MaestroPiezaBomPayload.descripcion → columna Descripcion; .material → Material (1:1).
    El primer placeholder del batch es el de IF NOT EXISTS; el segundo es Codigo_Pieza en VALUES
    (mismo patrón que excel.py).
    """
    mc = _get_maestro_cols()
    opt_cols: List[str] = []
    opt_ph: List[str] = []
    opt_params: List[Any] = []
    if "ESTADO" in mc:
        opt_cols.append("Estado")
        opt_ph.append("?")
        opt_params.append("NUEVO")
    if "TIENE_DXF" in mc:
        opt_cols.append("Tiene_DXF")
        opt_ph.append("?")
        opt_params.append("No")

    tail = ""
    if opt_cols:
        tail = ", " + ", ".join(opt_cols)

    sql = f"""
                IF NOT EXISTS (SELECT 1 FROM Tbl_Maestro_Piezas WHERE Codigo_Pieza = ?)
                BEGIN
                    INSERT INTO Tbl_Maestro_Piezas
                    (Codigo_Pieza, Descripcion, Medida, Material, Simetria,
                     Proceso_Primario, Proceso_1, Proceso_2, Proceso_3,
                     Link_Drive, Ultima_Actualizacion{tail}, Modificado_Por)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, GETDATE(){", " + ", ".join(opt_ph) if opt_ph else ""}, ?)
                END
                """
    params: List[Any] = [
        codigo,
        codigo,
        m.descripcion.strip(),
        "",
        m.material.strip(),
        "",
        m.proceso_primario.strip(),
        (m.proceso_1 or "").strip(),
        (m.proceso_2 or "").strip(),
        (m.proceso_3 or "").strip(),
        "N/A",
    ]
    params.extend(opt_params)
    params.append(usuario)
    cursor.execute(sql, tuple(params))


def _get_maestro_cols() -> set:
    """
    Devuelve el conjunto (mayúsculas) de columnas de Tbl_Maestro_Piezas.

    Abre su PROPIA conexión privada (no comparte nada con el caller),
    la cierra antes de regresar y cachea el resultado para requests futuras.
    Esto elimina el error "Connection is busy" de ODBC Driver 17/18 que
    ocurría al abrir un segundo cursor sobre la misma conexión que ya
    tiene otro cursor abierto.
    """
    global _MAESTRO_COLS_CACHE
    if _MAESTRO_COLS_CACHE:            # ya inicializado → devolver caché
        return _MAESTRO_COLS_CACHE
    conn2 = None
    try:
        conn2 = get_db_connection()
        cur   = conn2.cursor()
        cur.execute("SELECT TOP 0 * FROM Tbl_Maestro_Piezas")
        _MAESTRO_COLS_CACHE = {col[0].upper() for col in cur.description}
        return _MAESTRO_COLS_CACHE
    except Exception:
        return set()           # fallback: expresiones usarán literales '' / 0
    finally:
        if conn2:
            conn2.close()


def _build_maestro_exprs(avail: set) -> dict:
    """
    Dada la lista de columnas disponibles en Tbl_Maestro_Piezas,
    devuelve un dict con las expresiones SQL listas para inyectar en
    el SELECT de piezas.  Se llama UNA VEZ y el resultado se reutiliza
    en todos los ensambles del árbol.
    """
    def _safe_str(col: str, width: int = 200) -> str:
        return (f"ISNULL(m.{col}, '')" if col.upper() in avail else "''")

    def _safe_num_str(col: str) -> str:
        return (f"ISNULL(TRY_CAST(m.{col} AS NVARCHAR(50)), '')"
                if col.upper() in avail else "''")

    if 'TIENE_DXF' in avail:
        dxf = "CAST(ISNULL(m.Tiene_DXF, 0) AS INT)"
    elif 'LINK_DRIVE' in avail:
        dxf = ("CASE WHEN m.Link_Drive IS NOT NULL "
               "AND LEN(ISNULL(m.Link_Drive,'')) > 0 THEN 1 ELSE 0 END")
    else:
        dxf = "0"

    return {
        "material":        _safe_str("Material"),
        "medida":          _safe_str("Medida"),
        "simetria":        _safe_str("Simetria"),
        "descripcion":     (_safe_str("Descripcion") if "DESCRIPCION" in avail
                            else "''"),
        "proc_prim":       _safe_str("Proceso_Primario"),
        "proc1":           _safe_str("Proceso_1"),
        "proc2":           _safe_str("Proceso_2"),
        "proc3":           _safe_str("Proceso_3"),
        "link_drive":      _safe_str("Link_Drive"),
        "largo_cad":       _safe_num_str("Largo_CAD"),
        "ancho_cad":       _safe_num_str("Ancho_CAD"),
        "espesor_cad":     _safe_num_str("Espesor_Perfil_CAD"),
        "tiene_dxf":       dxf,
    }

def _get_estado_revision_for_bom(cursor, id_bom: int) -> str:
    """Devuelve el Estado de la revisión a la que pertenece un registro BOM."""
    cursor.execute("""
        SELECT R.Estado
        FROM Tbl_BOM_Estructura E
        JOIN Tbl_Ensambles     EN ON E.ID_Ensamble  = EN.ID_Ensamble
        JOIN Tbl_Estaciones    ES ON EN.ID_Estacion = ES.ID_Estacion
        JOIN Tbl_BOM_Revisiones R ON ES.ID_Revision = R.ID_Revision
        WHERE E.ID_BOM = ?
    """, (id_bom,))
    row = cursor.fetchone()
    return row.Estado if row else ""

def _assert_bom_editable(cursor, id_bom: int):
    """Lanza 403 si la revisión está bloqueada (Aprobada u OBSOLETO)."""
    estado = _get_estado_revision_for_bom(cursor, id_bom)
    if estado in ("Aprobada", "OBSOLETO"):
        raise HTTPException(
            status_code=403,
            detail="No se puede editar una ingeniería bloqueada. Inicia un cambio ECR.",
        )

# Endpoint canónico utilizado por el frontend (alias del anterior)
@router.put("/api/bom/estructura/cantidad/{id_bom}")
def update_bom_cantidad(id_bom: int, payload: BOMPiezaUpdate):
    """PUT canónico para actualizar cantidad de una pieza BOM.
    Incluye verificación de estado: rechaza edición si la revisión está bloqueada."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        if payload.cantidad <= 0:
            raise HTTPException(status_code=400, detail="La cantidad debe ser mayor a 0.")
        _assert_bom_editable(cursor, id_bom)
        cursor.execute(
            "UPDATE Tbl_BOM_Estructura SET Cantidad = ? WHERE ID_BOM = ?",
            (payload.cantidad, id_bom),
        )
        if cursor.rowcount == 0:
            raise HTTPException(status_code=404, detail="Pieza de BOM no encontrada.")
        conn.commit()
        return {"status": "success"}
    except HTTPException:
        raise
    except pyodbc.Error as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error SQL al actualizar cantidad: {str(e)}")
    finally:
        conn.close()

# Alias legacy — conserva compatibilidad si algo llama al endpoint antiguo
@router.put("/api/bom/piezas/{id_bom}")
def update_bom_pieza(id_bom: int, payload: BOMPiezaUpdate):
    """Legacy: redirige a la misma lógica que update_bom_cantidad."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        if payload.cantidad <= 0:
            raise HTTPException(status_code=400, detail="La cantidad debe ser mayor a 0.")
        _assert_bom_editable(cursor, id_bom)
        cursor.execute(
            "UPDATE Tbl_BOM_Estructura SET Cantidad = ? WHERE ID_BOM = ?",
            (payload.cantidad, id_bom),
        )
        if cursor.rowcount == 0:
            raise HTTPException(status_code=404, detail="Pieza de BOM no encontrada.")
        conn.commit()
        return {"status": "success"}
    except HTTPException:
        raise
    except pyodbc.Error as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=f"Error SQL al actualizar la pieza: {str(e)}")
    finally:
        conn.close()

@router.get("/api/bom/arbol/{id_revision}")
def get_bom_arbol(id_revision: int):
    """
    Árbol BOM de 3 niveles: Estación → Ensamble → Pieza.

    Usa UN SOLO cursor para todas las queries (patrón secuencial original).
    LEFT JOIN a Tbl_Maestro_Piezas con ISNULL para evitar nulos de BD.
    """
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # SQL de piezas: LEFT JOIN + ISNULL explícitos (sincronizado con esquema Pydantic)
        pieza_sql = """
            SELECT
                e.ID_BOM,
                e.Codigo_Pieza,
                e.Cantidad,
                ISNULL(e.Observaciones_Proceso, '') AS Observaciones_Proceso,
                ISNULL(M.Descripcion, '') AS Descripcion,
                ISNULL(M.Simetria, '') AS Simetria,
                ISNULL(M.Material, '') AS Material,
                ISNULL(M.Medida, '') AS Medida,
                ISNULL(M.Proceso_Primario, '') AS Proceso_Primario,
                ISNULL(M.Proceso_1, '') AS Proceso_1,
                ISNULL(M.Proceso_2, '') AS Proceso_2,
                ISNULL(M.Proceso_3, '') AS Proceso_3,
                ISNULL(M.Link_Drive, '') AS Link_Drive,
                ISNULL(TRY_CAST(M.Largo_CAD AS NVARCHAR(50)), '') AS Largo_CAD,
                ISNULL(TRY_CAST(M.Ancho_CAD AS NVARCHAR(50)), '') AS Ancho_CAD,
                ISNULL(TRY_CAST(M.Espesor_Perfil_CAD AS NVARCHAR(50)), '') AS Espesor_CAD,
                ISNULL(M.Tiene_DXF, 'No') AS Tiene_DXF
            FROM Tbl_BOM_Estructura e
            LEFT JOIN Tbl_Maestro_Piezas M ON e.Codigo_Pieza = M.Codigo_Pieza
            WHERE e.ID_Ensamble = ?
        """

        # ── 2. Árbol con cursor único, acceso secuencial (fetchall completo
        #       antes de la siguiente execute — sin resultados pendientes) ──
        cursor.execute(
            "SELECT ID_Estacion, Nombre_Estacion, Orden "
            "FROM Tbl_Estaciones WHERE ID_Revision = ? ORDER BY Orden",
            (id_revision,)
        )
        estaciones = cursor.fetchall()   # completo → cursor libre

        arbol = []
        for est in estaciones:
            est_dict = {
                "id":        est.ID_Estacion,
                "nombre":    est.Nombre_Estacion or "",
                "ensambles": [],
            }

            cursor.execute(
                "SELECT ID_Ensamble, Nombre_Ensamble "
                "FROM Tbl_Ensambles WHERE ID_Estacion = ? ORDER BY Nombre_Ensamble",
                (est.ID_Estacion,)
            )
            ensambles = cursor.fetchall()   # completo → cursor libre

            for ens in ensambles:
                ens_dict = {
                    "id":     ens.ID_Ensamble,
                    "nombre": ens.Nombre_Ensamble or "",
                    "piezas": [],
                }

                cursor.execute(pieza_sql, (ens.ID_Ensamble,))
                piezas_rows = cursor.fetchall()   # completo → cursor libre

                for p in piezas_rows:
                    id_bom_val = int(p.ID_BOM) if p.ID_BOM is not None else None
                    ens_dict["piezas"].append({
                        "id":               id_bom_val,
                        "id_estructura":    id_bom_val,  # alias explícito para actualizar cantidades
                        "codigo":           str(p.Codigo_Pieza or ''),
                        "descripcion":      str(getattr(p, 'Descripcion',    None) or '') or 'N/A',
                        "cantidad":         float(p.Cantidad) if p.Cantidad is not None else 0.0,
                        "observaciones":    str(getattr(p, 'Observaciones_Proceso', None) or ''),
                        "simetria":         str(getattr(p, 'Simetria',         None) or ''),
                        "material":         str(getattr(p, 'Material',          None) or ''),
                        "medida":           str(getattr(p, 'Medida',            None) or ''),
                        "proceso_primario": str(getattr(p, 'Proceso_Primario',  None) or ''),
                        "proceso_1":        str(getattr(p, 'Proceso_1',         None) or ''),
                        "proceso_2":        str(getattr(p, 'Proceso_2',         None) or ''),
                        "proceso_3":        str(getattr(p, 'Proceso_3',         None) or ''),
                        "link_drive":       str(getattr(p, 'Link_Drive',        None) or ''),
                        "largo_cad":        str(getattr(p, 'Largo_CAD',         None) or ''),
                        "ancho_cad":        str(getattr(p, 'Ancho_CAD',         None) or ''),
                        "espesor_cad":      str(getattr(p, 'Espesor_CAD',       None) or ''),
                        "tiene_dxf":        str(getattr(p, 'Tiene_DXF', 'No') or 'No'),
                    })

                est_dict["ensambles"].append(ens_dict)

            arbol.append(est_dict)

        return arbol

    except pyodbc.Error as e:
        print(f"Error en arbol [rev={id_revision}]: {str(e)}")
        traceback.print_exc()
        raise HTTPException(
            status_code=500,
            detail=f"SQL error en Árbol BOM [rev={id_revision}]: {str(e)}"
        )
    except Exception as e:
        print(f"Error en arbol [rev={id_revision}]: {str(e)}")
        traceback.print_exc()
        raise HTTPException(
            status_code=500,
            detail=f"Error interno en Árbol BOM [rev={id_revision}]: {str(e)}"
        )
    finally:
        cursor.close()
        conn.close()



@router.get("/api/bom/plana/{id_revision}")
def get_bom_plana(id_revision: int):
    """
    Vista Plana HD: explosión jerárquica mediante CTE de 3 niveles.
    LEFT JOIN a Tbl_Maestro_Piezas con ISNULL para evitar nulos de BD.
    """
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        sql = """
            WITH Estaciones AS (
                SELECT ID_Estacion, Nombre_Estacion, Orden
                FROM   Tbl_Estaciones
                WHERE  ID_Revision = ?
            ),
            Explosion AS (
                -- Nivel 1: Estaciones (agrupador)
                SELECT
                    1                                         AS Nivel,
                    CAST(NULL AS NVARCHAR(200))               AS Codigo_Padre,
                    CAST(ES.Nombre_Estacion AS NVARCHAR(200)) AS Codigo_Pieza,
                    CAST(ES.Nombre_Estacion AS NVARCHAR(500)) AS Descripcion,
                    CAST(NULL AS FLOAT)                       AS Cantidad,
                    ''  AS Material,    ''  AS Medida,
                    ''  AS Proceso_Primario,
                    ''  AS Proceso_1,   ''  AS Proceso_2,   ''  AS Proceso_3,
                    ''  AS Largo_CAD,   ''  AS Ancho_CAD,   ''  AS Espesor_CAD,
                    'No' AS Tiene_DXF,  ''  AS Simetria,
                    CAST(ES.Nombre_Estacion AS NVARCHAR(200)) AS Nombre_Estacion,
                    CAST(NULL AS NVARCHAR(200))               AS Nombre_Ensamble,
                    CAST(NULL AS INT)                         AS ID_BOM,
                    ES.Orden AS Sort1, 0 AS Sort2, 0 AS Sort3
                FROM Estaciones ES

                UNION ALL

                -- Nivel 2: Ensambles (sub-agrupador)
                SELECT
                    2,
                    CAST(ES.Nombre_Estacion AS NVARCHAR(200)),
                    CAST(EN.Nombre_Ensamble AS NVARCHAR(200)),
                    CAST(EN.Nombre_Ensamble AS NVARCHAR(500)),
                    CAST(NULL AS FLOAT),
                    '', '', '', '', '', '',
                    '', '', '', 'No', '',
                    CAST(ES.Nombre_Estacion AS NVARCHAR(200)),
                    CAST(EN.Nombre_Ensamble AS NVARCHAR(200)),
                    CAST(NULL AS INT),
                    ES.Orden, EN.ID_Ensamble, 0
                FROM Tbl_Ensambles EN
                JOIN Estaciones ES ON EN.ID_Estacion = ES.ID_Estacion

                UNION ALL

                -- Nivel 3: Piezas. LEFT JOIN + ISNULL (sincronizado con esquema Pydantic)
                SELECT
                    3,
                    CAST(EN.Nombre_Ensamble AS NVARCHAR(200)),
                    CAST(E.Codigo_Pieza     AS NVARCHAR(200)),
                    ISNULL(CAST(M.Descripcion AS NVARCHAR(500)), ''),
                    CAST(E.Cantidad AS FLOAT),
                    ISNULL(M.Material, ''),
                    ISNULL(M.Medida, ''),
                    ISNULL(M.Proceso_Primario, ''),
                    ISNULL(M.Proceso_1, ''),
                    ISNULL(M.Proceso_2, ''),
                    ISNULL(M.Proceso_3, ''),
                    ISNULL(TRY_CAST(M.Largo_CAD AS NVARCHAR(50)), ''),
                    ISNULL(TRY_CAST(M.Ancho_CAD AS NVARCHAR(50)), ''),
                    ISNULL(TRY_CAST(M.Espesor_Perfil_CAD AS NVARCHAR(50)), ''),
                    ISNULL(M.Tiene_DXF, 'No'),
                    ISNULL(M.Simetria, ''),
                    CAST(ES.Nombre_Estacion AS NVARCHAR(200)),
                    CAST(EN.Nombre_Ensamble AS NVARCHAR(200)),
                    E.ID_BOM,
                    ES.Orden, EN.ID_Ensamble, E.ID_BOM
                FROM Tbl_BOM_Estructura E
                JOIN Tbl_Ensambles           EN ON E.ID_Ensamble  = EN.ID_Ensamble
                JOIN Estaciones              ES ON EN.ID_Estacion = ES.ID_Estacion
                LEFT JOIN Tbl_Maestro_Piezas M  ON E.Codigo_Pieza = M.Codigo_Pieza
            )
            SELECT Nivel, Codigo_Padre, Codigo_Pieza, Descripcion, Cantidad,
                   Material, Medida, Proceso_Primario, Proceso_1, Proceso_2, Proceso_3,
                   Largo_CAD, Ancho_CAD, Espesor_CAD, Tiene_DXF, Simetria,
                   Nombre_Estacion, Nombre_Ensamble, ID_BOM
            FROM   Explosion
            ORDER BY Sort1, Sort2, Nivel, Sort3
        """
        cursor.execute(sql, (id_revision,))
        rows = cursor.fetchall()

        def _gs(r, col: str, default: str = "") -> str:
            return str(getattr(r, col, default) or default)

        return [
            {
                "nivel":            int(getattr(r, 'Nivel', 0)),
                "codigo_padre":     _gs(r, 'Codigo_Padre'),
                "codigo_pieza":     _gs(r, 'Codigo_Pieza'),
                "descripcion":      _gs(r, 'Descripcion'),
                "cantidad":         (float(r.Cantidad) if r.Cantidad is not None else None),
                "material":         _gs(r, 'Material'),
                "medida":           _gs(r, 'Medida'),
                "proceso_primario": _gs(r, 'Proceso_Primario'),
                "proceso_1":        _gs(r, 'Proceso_1'),
                "proceso_2":        _gs(r, 'Proceso_2'),
                "proceso_3":        _gs(r, 'Proceso_3'),
                "largo_cad":        _gs(r, 'Largo_CAD'),
                "ancho_cad":        _gs(r, 'Ancho_CAD'),
                "espesor_cad":      _gs(r, 'Espesor_CAD'),
                "tiene_dxf":        str(getattr(r, 'Tiene_DXF', 'No') or 'No'),
                "simetria":         _gs(r, 'Simetria'),
                "nombre_estacion":  _gs(r, 'Nombre_Estacion'),
                "nombre_ensamble":  _gs(r, 'Nombre_Ensamble'),
                "id_bom":           (int(r.ID_BOM) if r.ID_BOM is not None else None),
                "id_estructura":    (int(r.ID_BOM) if r.ID_BOM is not None else None),  # alias explícito
            }
            for r in rows
        ]
    except pyodbc.Error as e:
        print(f"Error en plana [rev={id_revision}]: {str(e)}")
        traceback.print_exc()
        raise HTTPException(
            status_code=500,
            detail=f"SQL error en Vista Plana [rev={id_revision}]: {str(e)}"
        )
    except Exception as e:
        print(f"Error en plana [rev={id_revision}]: {str(e)}")
        traceback.print_exc()
        raise HTTPException(
            status_code=500,
            detail=f"Error interno en Vista Plana [rev={id_revision}]: {str(e)}"
        )
    finally:
        cursor.close()
        conn.close()


@router.get("/api/bom/delta/{id_revision}")
def get_bom_delta(id_revision: int):
    """
    Modo Delta: compara la revisión actual con la inmediatamente anterior
    en la misma versión de ingeniería.
    Devuelve conjuntos de piezas nuevas, eliminadas y con cantidad modificada.
    """
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # 1. Buscar la revisión anterior en la misma versión
        cursor.execute("""
            SELECT TOP 1 R2.ID_Revision
            FROM Tbl_BOM_Revisiones R1
            JOIN Tbl_BOM_Revisiones R2 ON R1.ID_Version = R2.ID_Version
            WHERE R1.ID_Revision = ?
              AND R2.Numero_Revision < R1.Numero_Revision
            ORDER BY R2.Numero_Revision DESC
        """, (id_revision,))
        row = cursor.fetchone()
        if not row:
            return {
                "tiene_anterior":     False,
                "id_rev_anterior":    None,
                "codigos_nuevos":     [],
                "codigos_eliminados": [],
                "modificados":        {},
            }
        id_rev_anterior = int(row[0])

        # Helper: sumar cantidades por código en una revisión
        def piezas_por_codigo(rev_id: int) -> dict:
            cursor.execute("""
                SELECT E.Codigo_Pieza, SUM(E.Cantidad)
                FROM Tbl_BOM_Estructura E
                JOIN Tbl_Ensambles  EN ON E.ID_Ensamble  = EN.ID_Ensamble
                JOIN Tbl_Estaciones ES ON EN.ID_Estacion = ES.ID_Estacion
                WHERE ES.ID_Revision = ?
                GROUP BY E.Codigo_Pieza
            """, (rev_id,))
            return {str(r[0]): float(r[1] or 0) for r in cursor.fetchall()}

        curr = piezas_por_codigo(id_revision)
        prev = piezas_por_codigo(id_rev_anterior)

        codigos_nuevos     = [c for c in curr if c not in prev]
        codigos_eliminados = [c for c in prev if c not in curr]
        modificados        = {
            c: {"prev_qty": prev[c], "curr_qty": curr[c]}
            for c in curr
            if c in prev and curr[c] != prev[c]
        }

        return {
            "tiene_anterior":     True,
            "id_rev_anterior":    id_rev_anterior,
            "codigos_nuevos":     codigos_nuevos,
            "codigos_eliminados": codigos_eliminados,
            "modificados":        modificados,
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error en Delta BOM: {str(e)}")
    finally:
        conn.close()


@router.post("/api/bom/importar/{id_revision}")
async def importar_bom(
    id_revision: int,
    file: UploadFile = File(...),
    authorization: Optional[str] = Header(None),
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
):
    """
    Reemplazo total: borra estaciones, ensambles y piezas de la revisión y vuelve a cargar desde Excel.
    """
    if not file.filename.endswith((".xls", ".xlsx")):
        raise HTTPException(status_code=400, detail="El archivo debe ser un Excel (.xlsx, .xls)")

    try:
        content = await file.read()
        df = pd.read_excel(io.BytesIO(content), header=None)
    except Exception as e:
        if isinstance(e, HTTPException):
            raise e
        raise HTTPException(status_code=400, detail=f"Error al analizar el Excel: {str(e)}")

    actor = resolve_actor_user(authorization, x_usuario)
    conn = get_db_connection()
    cursor = conn.cursor()

    try:
        cursor.execute(
            "SELECT ID_Revision FROM Tbl_BOM_Revisiones WHERE ID_Revision = ?",
            (id_revision,),
        )
        if not cursor.fetchone():
            raise HTTPException(status_code=404, detail="Revisión no encontrada")

        cursor.execute("SELECT Codigo_Pieza FROM Tbl_Maestro_Piezas")
        codigos_buscar = {str(row[0]).strip().upper() for row in cursor.fetchall() if row[0]}

        acumulados, canonical_estacion, canonical_ensamble, errores_mapeo, total_leidos = (
            _parse_bom_import_excel(df, codigos_buscar)
        )

        _clear_bom_structure_for_revision(cursor, id_revision)

        estacion_id_por_norm: Dict[str, int] = {}

        insertados, _ = _bom_apply_accumulated(
            cursor,
            id_revision,
            acumulados,
            canonical_estacion,
            canonical_ensamble,
            estacion_id_por_norm,
            sumar=False,
        )

        detalle = (
            f"reemplazo_total leidos={total_leidos} insertados_estructura={insertados} "
            f"omitidos_catalogo={len(errores_mapeo)}"
        )
        _auditoria_bom_import(
            cursor,
            id_revision,
            "IMPORTAR_BOM_REEMPLAZO_TOTAL",
            detalle,
            actor,
        )

        conn.commit()
        return {
            "status": "success",
            "total_leidos": total_leidos,
            "insertados": insertados,
            "errores": errores_mapeo,
        }
    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(
            status_code=500,
            detail=f"Error SQL durante importación, transacción revertida: {str(e)}",
        )
    finally:
        conn.close()


@router.post("/api/bom/importar_sumar/{id_revision}")
async def importar_bom_sumar(
    id_revision: int,
    file: UploadFile = File(...),
    authorization: Optional[str] = Header(None),
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
):
    """
    Suma / upsert: no borra nada. Por cada ruta Estación→Ensamble→Código suma cantidad
    si la línea existe; si falta nodo o pieza, crea/inserta.
    """
    if not file.filename.endswith((".xls", ".xlsx")):
        raise HTTPException(status_code=400, detail="El archivo debe ser un Excel (.xlsx, .xls)")

    try:
        content = await file.read()
        df = pd.read_excel(io.BytesIO(content), header=None)
    except Exception as e:
        if isinstance(e, HTTPException):
            raise e
        raise HTTPException(status_code=400, detail=f"Error al analizar el Excel: {str(e)}")

    actor = resolve_actor_user(authorization, x_usuario)
    conn = get_db_connection()
    cursor = conn.cursor()

    try:
        cursor.execute(
            "SELECT ID_Revision FROM Tbl_BOM_Revisiones WHERE ID_Revision = ?",
            (id_revision,),
        )
        if not cursor.fetchone():
            raise HTTPException(status_code=404, detail="Revisión no encontrada")

        cursor.execute("SELECT Codigo_Pieza FROM Tbl_Maestro_Piezas")
        codigos_buscar = {str(row[0]).strip().upper() for row in cursor.fetchall() if row[0]}

        acumulados, canonical_estacion, canonical_ensamble, errores_mapeo, total_leidos = (
            _parse_bom_import_excel(df, codigos_buscar)
        )

        cursor.execute(
            "SELECT ID_Estacion, Nombre_Estacion FROM Tbl_Estaciones WHERE ID_Revision = ?",
            (id_revision,),
        )
        estacion_id_por_norm: Dict[str, int] = {}
        for row in cursor.fetchall():
            nid = int(row[0])
            nn = _norm_bom_group_label(row[1])
            if nn and nn not in estacion_id_por_norm:
                estacion_id_por_norm[nn] = nid

        insertados, actualizados = _bom_apply_accumulated(
            cursor,
            id_revision,
            acumulados,
            canonical_estacion,
            canonical_ensamble,
            estacion_id_por_norm,
            sumar=True,
        )

        detalle = (
            f"sumar leidos={total_leidos} insertados={insertados} cantidades_actualizadas={actualizados} "
            f"omitidos_catalogo={len(errores_mapeo)}"
        )
        _auditoria_bom_import(
            cursor,
            id_revision,
            "IMPORTAR_BOM_SUMAR_EXCEL",
            detalle,
            actor,
        )

        conn.commit()
        return {
            "status": "success",
            "total_leidos": total_leidos,
            "insertados": insertados,
            "actualizados": actualizados,
            "errores": errores_mapeo,
        }
    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(
            status_code=500,
            detail=f"Error SQL durante importación (sumar), transacción revertida: {str(e)}",
        )
    finally:
        conn.close()
