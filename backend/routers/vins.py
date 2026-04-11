"""API router: vins."""
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

router = APIRouter()

# === NUBE DE ARCHIVOS VIN ===
VIN_FILES_BASE = r"C:\BDIV_Archivos\VINs"

@router.get("/api/vins/{id_vin}/archivos")
def get_archivos_vin(id_vin: int):
    """Lista archivos adjuntos de un VIN."""
    folder = os.path.join(VIN_FILES_BASE, str(id_vin))
    if not os.path.exists(folder):
        return []
    archivos = []
    for fname in os.listdir(folder):
        fpath = os.path.join(folder, fname)
        if os.path.isfile(fpath):
            archivos.append({
                "nombre": fname,
                "tamano_kb": round(os.path.getsize(fpath) / 1024, 1),
                "es_pdf": fname.lower().endswith(".pdf")
            })
    return archivos

@router.post("/api/vins/{id_vin}/subir_archivo")
async def subir_archivo_vin(id_vin: int, file: UploadFile = File(...), x_usuario: Optional[str] = Header(None)):
    """Sube y guarda un archivo en la carpeta del VIN en el servidor."""
    folder = os.path.join(VIN_FILES_BASE, str(id_vin))
    os.makedirs(folder, exist_ok=True)
    # Sanitizar nombre de archivo
    safe_name = re.sub(r"[^\w\.\-]", "_", file.filename or "archivo")
    dest = os.path.join(folder, safe_name)
    try:
        content = await file.read()
        with open(dest, "wb") as f:
            f.write(content)
        # === Auditoría de subida de archivo (columnas reales) ===
        try:
            usuario_log = x_usuario if x_usuario else "SISTEMA_VIN"
            conn_log = get_db_connection()
            cursor_log = conn_log.cursor()
            cursor_log.execute(
                "INSERT INTO Tbl_Auditoria_Cambios (Codigo_Pieza, Accion, Valor_Anterior, Valor_Nuevo, Usuario) "
                "VALUES (?, ?, ?, ?, ?)",
                (f"VIN-{id_vin}", 'Subir Archivo', None, f"Archivo '{safe_name}' subido ({round(len(content)/1024,1)} KB)", usuario_log)
            )
            conn_log.commit()
            conn_log.close()
        except Exception:
            pass  # No interrumpir operación principal si falla el log
        return {"status": "success", "nombre": safe_name, "tamano_kb": round(len(content) / 1024, 1)}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error al guardar archivo: {str(e)}")

@router.get("/api/vins/{id_vin}/archivos/{nombre_archivo}")
async def descargar_archivo_vin(id_vin: int, nombre_archivo: str):
    """Descarga/abre un archivo adjunto del VIN."""
    safe_name = re.sub(r"[^\w\.\-]", "_", nombre_archivo)
    fpath = os.path.join(VIN_FILES_BASE, str(id_vin), safe_name)
    if not os.path.exists(fpath):
        raise HTTPException(status_code=404, detail="Archivo no encontrado")
    def iterfile():
        with open(fpath, "rb") as f:
            yield from f
    media_type = "application/pdf" if safe_name.lower().endswith(".pdf") else "application/octet-stream"
    return StreamingResponse(iterfile(), media_type=media_type,
        headers={"Content-Disposition": f"inline; filename={safe_name}"})

# --- FUNCIONALIDADES AVANZADAS (FASE 8) ---

@router.get("/api/vins/buscar")
def buscar_vin(q: str):
    """Búsqueda de VINs por serie.
    CORREGIDO: subconsulta STRING_AGG para clientes en lugar de LEFT JOIN directo.
    El JOIN directo producía N copias del mismo VIN si su versión tenía N clientes."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        query = """
            SELECT
                u.ID_Unidad,
                u.Serie               AS VIN,
                u.Observaciones       AS Notas,
                u.ID_VIN_Asociado,
                r.ID_Revision,
                r.Numero_Revision,
                v.ID_Version,
                v.Nombre_Version,
                t.Nombre_Tipo,
                tr.Nombre_Tracto,
                socio.Serie           AS VIN_Asociado_Nombre,
                ISNULL(
                    (SELECT STRING_AGG(c2.Nombre_Cliente, ', ')
                     FROM Tbl_Clientes_Configuracion c2
                     WHERE c2.ID_Version = v.ID_Version),
                    'Ingeniería Base (Sin clientes)'
                ) AS Nombre_Cliente
            FROM Tbl_Unidades_Fisicas u
            LEFT JOIN Tbl_BOM_Revisiones       r    ON u.ID_Revision      = r.ID_Revision
            LEFT JOIN Tbl_Versiones_Ingenieria v    ON r.ID_Version       = v.ID_Version
            LEFT JOIN Tbl_Tipos_Proyecto       t    ON v.ID_Tipo          = t.ID_Tipo
            LEFT JOIN Tbl_Proyectos_Tracto     tr   ON t.ID_Tracto        = tr.ID_Tracto
            LEFT JOIN Tbl_Unidades_Fisicas     socio ON u.ID_VIN_Asociado = socio.ID_Unidad
            WHERE u.Serie LIKE ?
        """
        q = (q or "").strip()
        cursor.execute(query, (f"%{q}%",))
        rows = cursor.fetchall()
        return [
            {
                "id_unidad":      r.ID_Unidad,
                "vin":            r.VIN,
                "notas":          r.Notas,
                "id_revision":    r.ID_Revision,
                "numero_revision": r.Numero_Revision,
                "cliente":        r.Nombre_Cliente,
                "version":        r.Nombre_Version,
                "tipo":           r.Nombre_Tipo,
                "tracto":         r.Nombre_Tracto,
                "id_socio":       r.ID_VIN_Asociado,
                "vin_socio":      r.VIN_Asociado_Nombre,
            }
            for r in rows
        ]
    finally:
        conn.close()

@router.get("/api/vins/{id_unidad}/adn")
def get_vin_adn(id_unidad: int):
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("SELECT Serie as VIN, ID_Revision FROM Tbl_Unidades_Fisicas WHERE ID_Unidad = ?", (id_unidad,))
        row = cursor.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="VIN no encontrado")
        vin_str = row.VIN
        id_revision = row.ID_Revision

        eventos = []

        # 1. Movimientos propios del VIN desde Tbl_Auditoria_Cambios
        prefix = f"VIN-{vin_str}"
        cursor.execute("""
            SELECT Accion, Valor_Anterior, Valor_Nuevo, Usuario, Fecha_Hora
            FROM Tbl_Auditoria_Cambios
            WHERE Codigo_Pieza = ?
        """, (prefix,))
        for ev in cursor.fetchall():
            eventos.append({
                "fecha": ev.Fecha_Hora.isoformat() if ev.Fecha_Hora else None,
                "titulo": ev.Accion,
                "detalle": ev.Valor_Nuevo,
                "usuario": ev.Usuario,
                "tipo": "VIN"
            })

        # 2. Movimientos de la revisión de Tbl_Log_Cambios_Ingenieria
        try:
            cursor.execute("""
                SELECT Accion, Detalle_Cambio, Usuario, Fecha_Hora
                FROM Tbl_Log_Cambios_Ingenieria
                WHERE ID_Revision = ?
            """, (id_revision,))
            for lr in cursor.fetchall():
                eventos.append({
                    "fecha": lr.Fecha_Hora.isoformat() if lr.Fecha_Hora else None,
                    "titulo": lr.Accion,
                    "detalle": lr.Detalle_Cambio,
                    "usuario": lr.Usuario,
                    "tipo": "REVISION"
                })
        except:
            pass # Si Tbl_Log_Cambios_Ingenieria doesn't exist yet, ignore
            
        # Ordenar cronológicamente descendente
        eventos.sort(key=lambda x: x['fecha'] or "", reverse=True)
        return eventos
    finally:
        conn.close()

@router.post("/api/vins/{id_unidad}/vincular/{id_socio}")
def vincular_vin(id_unidad: int, id_socio: int, x_usuario: Optional[str] = Header(None)):
    # === TAREA 2: Rastreo de usuario real ===
    usuario_real = x_usuario if x_usuario else "SISTEMA_VIN"
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("SELECT Serie as VIN FROM Tbl_Unidades_Fisicas WHERE ID_Unidad = ?", (id_unidad,))
        u1 = cursor.fetchone()
        if not u1:
            raise HTTPException(status_code=404, detail="Unidad no encontrada")

        if id_socio == 0:
            # Desvincular
            cursor.execute("SELECT ID_VIN_Asociado FROM Tbl_Unidades_Fisicas WHERE ID_Unidad = ?", (id_unidad,))
            socio = cursor.fetchone()
            if socio and socio.ID_VIN_Asociado:
                cursor.execute("UPDATE Tbl_Unidades_Fisicas SET ID_VIN_Asociado = NULL WHERE ID_Unidad = ?", (socio.ID_VIN_Asociado,))
            cursor.execute("UPDATE Tbl_Unidades_Fisicas SET ID_VIN_Asociado = NULL WHERE ID_Unidad = ?", (id_unidad,))
            
            cursor.execute(
                "INSERT INTO Tbl_Auditoria_Cambios (Codigo_Pieza, Accion, Valor_Anterior, Valor_Nuevo, Usuario, Fecha_Hora) VALUES (?, ?, ?, ?, ?, GETDATE())",
                (f"VIN-{u1.VIN}", "VIN DESVINCULADO", "Combo disuelto", "Regresó a individual", usuario_real)  # === TAREA 2 ===
            )
            
        else:
            # Vincular (Bidireccional)
            cursor.execute("SELECT Serie as VIN FROM Tbl_Unidades_Fisicas WHERE ID_Unidad = ?", (id_socio,))
            u2 = cursor.fetchone()
            if not u2:
                raise HTTPException(status_code=404, detail="Socio no encontrado")
                
            cursor.execute("UPDATE Tbl_Unidades_Fisicas SET ID_VIN_Asociado = ? WHERE ID_Unidad = ?", (id_socio, id_unidad))
            cursor.execute("UPDATE Tbl_Unidades_Fisicas SET ID_VIN_Asociado = ? WHERE ID_Unidad = ?", (id_unidad, id_socio))
            
            cursor.execute(
                "INSERT INTO Tbl_Auditoria_Cambios (Codigo_Pieza, Accion, Valor_Anterior, Valor_Nuevo, Usuario, Fecha_Hora) VALUES (?, ?, ?, ?, ?, GETDATE())",
                (f"VIN-{u1.VIN}", "COMBO C3 CREADO", "Individual", f"Vinculado con VIN: {u2.VIN}", usuario_real)  # === TAREA 2 ===
            )
            cursor.execute(
                "INSERT INTO Tbl_Auditoria_Cambios (Codigo_Pieza, Accion, Valor_Anterior, Valor_Nuevo, Usuario, Fecha_Hora) VALUES (?, ?, ?, ?, ?, GETDATE())",
                (f"VIN-{u2.VIN}", "COMBO C3 CREADO", "Individual", f"Vinculado con VIN: {u1.VIN}", usuario_real)  # === TAREA 2 ===
            )

        conn.commit()
        return {"status": "success"}
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

@router.put("/api/vins/{id_unidad}/notas")
def update_vin_notas(id_unidad: int, payload: VINPayload, x_usuario: Optional[str] = Header(None)):
    # === TAREA 2: Historial acumulativo – concatenar, no sobrescribir ===
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        nueva_nota = payload.observaciones if payload.observaciones is not None else (payload.notas or "")
        if not nueva_nota.strip():
            return {"status": "no_change"}

        usuario_real = x_usuario if x_usuario else "Operador"
        from datetime import datetime
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M")
        entrada = f"[{timestamp}] {usuario_real}: {nueva_nota.strip()}"

        # Concatenar con separador de línea, no reemplazar
        cursor.execute("""
            UPDATE Tbl_Unidades_Fisicas
            SET Observaciones = CASE
                WHEN ISNULL(Observaciones, '') = '' THEN ?
                ELSE Observaciones + CHAR(13) + CHAR(10) + ?
            END
            WHERE ID_Unidad = ?
        """, (entrada, entrada, id_unidad))
        conn.commit()
        # === TAREA 3: Auditoría con conexión fresca (columnas reales de la tabla) ===
        try:
            conn2 = get_db_connection()
            cur2 = conn2.cursor()
            cur2.execute(
                "INSERT INTO Tbl_Auditoria_Cambios (Codigo_Pieza, Accion, Valor_Anterior, Valor_Nuevo, Usuario) "
                "VALUES (?, ?, ?, ?, ?)",
                (f"VIN-{id_unidad}", 'Agregar Nota', None, entrada, usuario_real)
            )
            conn2.commit()
            conn2.close()
        except Exception:
            pass  # No interrumpir si falla el log
        return {"status": "success", "entrada": entrada}
    finally:
        conn.close()

# === Endpoint para REEMPLAZAR notas completas (usado al borrar una nota) ===
@router.put("/api/vins/{id_unidad}/notas_reemplazar")
def replace_vin_notas(id_unidad: int, payload: NotasReplacePayload, x_usuario: Optional[str] = Header(None)):
    """Sobrescribe Observaciones de la unidad indicada estrictamente por PK (ID_Unidad)."""
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        texto_completo = payload.observaciones if payload.observaciones is not None else (payload.notas or "")
        usuario_real = x_usuario if x_usuario else "Operador"

        # Obtener Serie antes del UPDATE para usar en auditoría
        cursor.execute("SELECT Serie FROM Tbl_Unidades_Fisicas WHERE ID_Unidad = ?", (id_unidad,))
        vin_row = cursor.fetchone()
        serie_label = f"VIN-{vin_row.Serie}" if vin_row else f"VIN-ID{id_unidad}"

        # Aislamiento estricto: WHERE por PK, nunca por Serie para evitar cruces
        cursor.execute(
            "UPDATE Tbl_Unidades_Fisicas SET Observaciones = ? WHERE ID_Unidad = ?",
            (texto_completo, id_unidad),
        )
        conn.commit()

        try:
            conn2 = get_db_connection()
            cur2 = conn2.cursor()
            cur2.execute(
                "INSERT INTO Tbl_Auditoria_Cambios "
                "(Codigo_Pieza, Accion, Valor_Anterior, Valor_Nuevo, Usuario) "
                "VALUES (?, ?, ?, ?, ?)",
                (serie_label, "Borrar Nota", None,
                 f"Nota eliminada del historial {serie_label}", usuario_real),
            )
            cur2.execute(
                "SELECT ID_Revision FROM Tbl_Unidades_Fisicas WHERE ID_Unidad = ?",
                (id_unidad,),
            )
            rev_row = cur2.fetchone()
            if rev_row:
                registrar_log(
                    cur2,
                    rev_row.ID_Revision,
                    "VIN_NOTA_BORRADA",
                    f"{serie_label}: nota eliminada.",
                    usuario=usuario_real,
                )
            conn2.commit()
            conn2.close()
        except Exception:
            pass
        return {"status": "success"}
    finally:
        conn.close()

# === TAREA 4: Borrar archivo físico de la Nube VIN ===
@router.delete("/api/vins/{id_vin}/archivos/{nombre_archivo}")
async def eliminar_archivo_vin(id_vin: int, nombre_archivo: str, x_usuario: Optional[str] = Header(None)):
    """Elimina físicamente un archivo adjunto del VIN del servidor."""
    safe_name = re.sub(r"[^\w\.\-]", "_", nombre_archivo)
    fpath = os.path.join(VIN_FILES_BASE, str(id_vin), safe_name)
    if not os.path.exists(fpath):
        raise HTTPException(status_code=404, detail="Archivo no encontrado")
    try:
        os.remove(fpath)
        # === Auditoría de borrado de archivo (columnas reales) ===
        try:
            usuario_log = x_usuario if x_usuario else "SISTEMA_VIN"
            conn_log = get_db_connection()
            cur_log = conn_log.cursor()
            cur_log.execute(
                "INSERT INTO Tbl_Auditoria_Cambios (Codigo_Pieza, Accion, Valor_Anterior, Valor_Nuevo, Usuario) "
                "VALUES (?, ?, ?, ?, ?)",
                (f"VIN-{id_vin}", 'Borrar Archivo', None, f"Archivo '{safe_name}' eliminado", usuario_log)
            )
            conn_log.commit()
            conn_log.close()
        except Exception:
            pass
        return {"status": "success", "eliminado": safe_name}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error al eliminar: {str(e)}")

@router.delete("/api/vins/{serie}")
def delete_vin(serie: str, payload: DeleteVinPayload, x_usuario: Optional[str] = Header(None)):
    assert_admin_master_password_matches(payload.password)

    # === TAREA 2: Rastreo de usuario real ===
    usuario_real = x_usuario if x_usuario else "SISTEMA_VIN"
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        # Check if VIN exists and get ID_Unidad and ID_Revision (for logging context)
        cursor.execute("SELECT ID_Unidad FROM Tbl_Unidades_Fisicas WHERE Serie = ?", (serie,))
        row = cursor.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="VIN no encontrado")
        id_unidad = row.ID_Unidad

        # 1. Unlink from C3 if associated
        cursor.execute("UPDATE Tbl_Unidades_Fisicas SET ID_VIN_Asociado = NULL WHERE ID_VIN_Asociado = ?", (id_unidad,))

        # 2. Add audit log
        motivo_str = payload.motivo if payload.motivo else "Eliminación autorizada por administrador"
        cursor.execute(
            "INSERT INTO Tbl_Auditoria_Cambios (Codigo_Pieza, Accion, Valor_Anterior, Valor_Nuevo, Usuario, Fecha_Hora) VALUES (?, 'ELIMINAR_VIN', ?, ?, ?, GETDATE())",
            (f"VIN-{serie}", serie, motivo_str, usuario_real)  # === TAREA 2: usuario real ===
        )

        # 3. Delete Physical record
        cursor.execute("DELETE FROM Tbl_Unidades_Fisicas WHERE ID_Unidad = ?", (id_unidad,))
        conn.commit()
        
        # 4. Delete files related to this VIN
        try:
            folder_path = os.path.join(VIN_FILES_BASE, str(id_unidad))
            if os.path.exists(folder_path):
                shutil.rmtree(folder_path, ignore_errors=True)
        except Exception as e:
            pass # No bloqueamos si falla el borrado de archivos.

        return {"status": "success", "message": f"VIN {serie} eliminado correctamente"}
    except pyodbc.IntegrityError as e:
        conn.rollback()
        raise HTTPException(status_code=400, detail=f"No se puede eliminar por restricciones de BD: {str(e)}")
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()
