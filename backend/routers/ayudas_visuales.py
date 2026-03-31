"""
Ayudas visuales (PDFs por categoría y revisiones).

Esquema SQL (nombres exactos):

    Tbl_Ayudas_Categorias: ID_Categoria, Nombre_Categoria, Activo, Icono_Codigo
    Tbl_Ayudas_Maestro: Id_Ayuda, Id_Categoria, Titulo_Documento, Fecha_Creacion, VIN
    Tbl_Ayudas_Revisiones: Id_Revision, Id_Ayuda, Numero_Revision, Ruta_PDF,
                          Fecha_Subida, Es_Vigente, Usuario_Subida

Archivos físicos: Z:\\Ayudas_Visuales\\<NombreCategoria_Sanitizado>\\
"""
from __future__ import annotations

import os
import re
import uuid
from datetime import datetime
from typing import Any, Dict, Optional

from fastapi import APIRouter, File, Form, Header, HTTPException, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

from audit_service import registrar_log_global
from database import get_db_connection
from user_context import resolve_actor_user

router = APIRouter()

AYUDAS_RAIZ = r"Z:\Ayudas_Visuales"


class CategoriaCreatePayload(BaseModel):
    nombre: str = Field(..., min_length=1)
    icono: str = ""


def _sanitize_folder_name(name: str) -> str:
    s = (name or "").strip()
    if not s:
        return "SinCategoria"
    s = re.sub(r'[<>:"/\\|?*]', "_", s)
    s = re.sub(r"\s+", "_", s)
    return s[:120]


def _row_to_dict(cursor, row) -> Dict[str, Any]:
    cols = [c[0] for c in cursor.description]
    out: Dict[str, Any] = {}
    for c, v in zip(cols, row):
        if hasattr(v, "isoformat"):
            out[c] = v.isoformat() if v else None
        else:
            out[c] = v
    return out


@router.get("/api/ayudas/categorias")
def list_categorias_activas():
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        cur.execute(
            """
            SELECT ID_Categoria, Nombre_Categoria, Activo, Icono_Codigo
            FROM Tbl_Ayudas_Categorias
            WHERE Activo = 1
            ORDER BY Nombre_Categoria
            """
        )
        rows = cur.fetchall()
        return [_row_to_dict(cur, r) for r in rows]
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.post("/api/ayudas/categorias")
def crear_categoria(
    payload: CategoriaCreatePayload,
    authorization: Optional[str] = Header(None),
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
):
    nombre = (payload.nombre or "").strip()
    icono = (payload.icono or "").strip()
    if not nombre:
        raise HTTPException(status_code=400, detail="nombre es obligatorio")

    usr = resolve_actor_user(authorization, x_usuario)
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        cur.execute(
            """
            INSERT INTO Tbl_Ayudas_Categorias (Nombre_Categoria, Icono_Codigo, Activo)
            OUTPUT INSERTED.ID_Categoria
            VALUES (?, ?, 1)
            """,
            (nombre, icono or None),
        )
        new_id = int(cur.fetchone()[0])
        detalle = f"id={new_id};nombre={nombre};icono={icono or '-'}"
        registrar_log_global(cur, "AYUDAS", "CREAR_CATEGORIA_AYUDAS", "", detalle, usr)
        conn.commit()
        return {"ok": True, "id_categoria": new_id}
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.get("/api/ayudas/lista/{id_categoria}")
def lista_documentos_categoria(id_categoria: int):
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        cur.execute(
            """
            SELECT
                m.Id_Ayuda,
                m.Id_Categoria,
                m.Titulo_Documento,
                m.Subcategoria,
                m.VIN,
                r.Id_Revision,
                r.Numero_Revision,
                r.Fecha_Subida,
                r.Es_Vigente,
                r.Ruta_PDF,
                r.Usuario_Subida
            FROM Tbl_Ayudas_Maestro m
            INNER JOIN Tbl_Ayudas_Revisiones r
                ON r.Id_Ayuda = m.Id_Ayuda AND r.Es_Vigente = 1
            WHERE m.Id_Categoria = ?
            ORDER BY m.Titulo_Documento
            """,
            (id_categoria,),
        )
        rows = cur.fetchall()
        return [_row_to_dict(cur, r) for r in rows]
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.get("/api/ayudas/historial/{id_ayuda}")
def historial_revisiones(id_ayuda: int):
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        cur.execute(
            """
            SELECT
                Id_Revision,
                Id_Ayuda,
                Numero_Revision,
                Ruta_PDF,
                Fecha_Subida,
                Es_Vigente,
                Usuario_Subida
            FROM Tbl_Ayudas_Revisiones
            WHERE Id_Ayuda = ?
            ORDER BY Fecha_Subida DESC
            """,
            (id_ayuda,),
        )
        rows = cur.fetchall()
        return [_row_to_dict(cur, r) for r in rows]
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.delete("/api/ayudas/revision/{id_revision}")
def eliminar_revision(
    id_revision: int,
    authorization: Optional[str] = Header(None),
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
):
    usr = resolve_actor_user(authorization, x_usuario)
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        cur.execute(
            """
            SELECT Id_Ayuda, Ruta_PDF, Numero_Revision
            FROM Tbl_Ayudas_Revisiones
            WHERE Id_Revision = ?
            """,
            (id_revision,),
        )
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Revisión no encontrada")
        id_ayuda = int(row[0])
        ruta = str(row[1] or "").strip()
        num_rev = str(row[2] or "")

        cur.execute(
            "DELETE FROM Tbl_Ayudas_Revisiones WHERE Id_Revision = ?",
            (id_revision,),
        )

        detalle = f"id_rev={id_revision};id_ayuda={id_ayuda};num={num_rev}"
        registrar_log_global(
            cur,
            f"AYUDA:{id_ayuda}",
            "ELIMINAR_REVISION_AYUDAS",
            ruta[:250] if ruta else str(id_revision),
            detalle[:250],
            usr,
        )
        conn.commit()

        if ruta and os.path.isfile(ruta):
            try:
                os.remove(ruta)
            except OSError:
                pass

        return {"ok": True}
    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.delete("/api/ayudas/documento/{id_ayuda}")
def eliminar_documento_cascada(
    id_ayuda: int,
    authorization: Optional[str] = Header(None),
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
):
    """Elimina todas las revisiones y el registro maestro del documento."""
    usr = resolve_actor_user(authorization, x_usuario)
    conn = get_db_connection()
    cur = conn.cursor()
    rutas_pdf: list[str] = []
    try:
        cur.execute(
            "SELECT Titulo_Documento FROM Tbl_Ayudas_Maestro WHERE Id_Ayuda = ?",
            (id_ayuda,),
        )
        row_m = cur.fetchone()
        if not row_m:
            raise HTTPException(status_code=404, detail="Documento no encontrado")
        titulo = str(row_m[0] or "")

        cur.execute(
            "SELECT Ruta_PDF FROM Tbl_Ayudas_Revisiones WHERE Id_Ayuda = ?",
            (id_ayuda,),
        )
        for r in cur.fetchall():
            p = str(r[0] or "").strip()
            if p:
                rutas_pdf.append(p)

        cur.execute(
            "DELETE FROM Tbl_Ayudas_Revisiones WHERE Id_Ayuda = ?",
            (id_ayuda,),
        )
        cur.execute(
            "DELETE FROM Tbl_Ayudas_Maestro WHERE Id_Ayuda = ?",
            (id_ayuda,),
        )

        detalle = f"id_ayuda={id_ayuda};titulo={titulo[:120]};revs={len(rutas_pdf)}"
        registrar_log_global(
            cur,
            f"AYUDA:{id_ayuda}",
            "ELIMINAR_DOCUMENTO_AYUDAS_CASCADA",
            "",
            detalle[:250],
            usr,
        )
        conn.commit()

        for ruta in rutas_pdf:
            if os.path.isfile(ruta):
                try:
                    os.remove(ruta)
                except OSError:
                    pass

        return {"ok": True}
    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.post("/api/ayudas/subir")
async def subir_revision_pdf(
    file: UploadFile = File(...),
    id_ayuda: Optional[str] = Form(None),
    id_categoria: Optional[str] = Form(None),
    titulo: Optional[str] = Form(None),
    subcategoria: Optional[str] = Form(None),
    numero_revision: str = Form(...),
    usuario: str = Form(...),
    vin: Optional[str] = Form(None),
    authorization: Optional[str] = Header(None),
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
):
    if not file.filename or not file.filename.lower().endswith(".pdf"):
        raise HTTPException(status_code=400, detail="Solo se admiten archivos .pdf")

    raw_ayuda = (id_ayuda or "").strip()
    raw_cat = (id_categoria or "").strip()
    titulo_doc = (titulo or "").strip()
    subcategoria_raw = subcategoria if subcategoria is not None else None
    usuario_limpio = (usuario or "").strip() or "Sistema"
    # Se guarda exactamente como llega desde frontend (incluyendo comas/espacios).
    vin_raw = vin if vin is not None else None
    usr_audit = resolve_actor_user(authorization, x_usuario)
    if usr_audit == "Sistema":
        usr_audit = usuario_limpio

    conn = get_db_connection()
    cur = conn.cursor()
    try:
        id_ayuda_int: Optional[int] = None
        id_cat_int: Optional[int] = None
        nombre_categoria: str = ""

        if raw_ayuda and raw_ayuda not in ("0", "null", "None"):
            id_ayuda_int = int(raw_ayuda)
            cur.execute(
                """
                SELECT m.Id_Categoria, c.Nombre_Categoria
                FROM Tbl_Ayudas_Maestro m
                INNER JOIN Tbl_Ayudas_Categorias c ON c.ID_Categoria = m.Id_Categoria
                WHERE m.Id_Ayuda = ?
                """,
                (id_ayuda_int,),
            )
            row = cur.fetchone()
            if not row:
                raise HTTPException(status_code=404, detail="Documento no encontrado")
            id_cat_int = int(row[0])
            nombre_categoria = str(row[1] or "")
            if vin_raw is not None:
                cur.execute(
                    "UPDATE Tbl_Ayudas_Maestro SET VIN = ? WHERE Id_Ayuda = ?",
                    (vin_raw, id_ayuda_int),
                )
            if subcategoria_raw is not None:
                cur.execute(
                    "UPDATE Tbl_Ayudas_Maestro SET Subcategoria = ? WHERE Id_Ayuda = ?",
                    (subcategoria_raw, id_ayuda_int),
                )
        else:
            if not raw_cat or not titulo_doc:
                raise HTTPException(
                    status_code=400,
                    detail="Para un documento nuevo indique id_categoria y titulo",
                )
            id_cat_int = int(raw_cat)
            cur.execute(
                "SELECT Nombre_Categoria FROM Tbl_Ayudas_Categorias WHERE ID_Categoria = ?",
                (id_cat_int,),
            )
            cr = cur.fetchone()
            if not cr:
                raise HTTPException(status_code=404, detail="Categoría no encontrada")
            nombre_categoria = str(cr[0] or "")
            ahora_creacion = datetime.now()
            cur.execute(
                """
                INSERT INTO Tbl_Ayudas_Maestro
                    (Id_Categoria, Titulo_Documento, Subcategoria, Fecha_Creacion, VIN)
                OUTPUT INSERTED.Id_Ayuda
                VALUES (?, ?, ?, ?, ?)
                """,
                (id_cat_int, titulo_doc, subcategoria_raw, ahora_creacion, vin_raw),
            )
            id_ayuda_int = int(cur.fetchone()[0])

        assert id_ayuda_int is not None

        carpeta = os.path.join(AYUDAS_RAIZ, _sanitize_folder_name(nombre_categoria))
        os.makedirs(carpeta, exist_ok=True)

        safe_rev = re.sub(r'[^\w.\-]', "_", (numero_revision or "").strip()) or "rev"
        fname = f"{id_ayuda_int}_{safe_rev}_{uuid.uuid4().hex[:8]}.pdf"
        dest_path = os.path.join(carpeta, fname)

        body = await file.read()
        with open(dest_path, "wb") as f:
            f.write(body)

        cur.execute(
            """
            UPDATE Tbl_Ayudas_Revisiones
            SET Es_Vigente = 0
            WHERE Id_Ayuda = ?
            """,
            (id_ayuda_int,),
        )

        ahora_subida = datetime.now()
        cur.execute(
            """
            INSERT INTO Tbl_Ayudas_Revisiones
                (Id_Ayuda, Numero_Revision, Ruta_PDF, Fecha_Subida, Es_Vigente, Usuario_Subida)
            OUTPUT INSERTED.Id_Revision
            VALUES (?, ?, ?, ?, 1, ?)
            """,
            (id_ayuda_int, numero_revision.strip(), dest_path, ahora_subida, usuario_limpio),
        )
        new_id = int(cur.fetchone()[0])

        log_nuevo = (
            f"id_rev={new_id};num={numero_revision.strip()};"
            f"subcat={subcategoria_raw or '-'};vin={vin_raw or '-'};"
            f"ruta={os.path.basename(dest_path)}"
        )
        registrar_log_global(
            cur,
            f"AYUDA:{id_ayuda_int}",
            "SUBIR_REVISION_AYUDAS",
            "",
            log_nuevo[:250],
            usr_audit,
        )

        conn.commit()

        return {
            "ok": True,
            "id_ayuda": id_ayuda_int,
            "id_revision": new_id,
            "ruta": dest_path,
        }
    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.get("/api/ayudas/ver/{id_revision}")
def ver_pdf_revision(id_revision: int):
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        cur.execute(
            """
            SELECT Ruta_PDF
            FROM Tbl_Ayudas_Revisiones
            WHERE Id_Revision = ?
            """,
            (id_revision,),
        )
        row = cur.fetchone()
        if not row or not row[0]:
            raise HTTPException(status_code=404, detail="Revisión no encontrada")
        path = str(row[0]).strip()
        if not os.path.isfile(path):
            raise HTTPException(
                status_code=404,
                detail=f"Archivo no encontrado en disco: {path}",
            )
        return FileResponse(
            path,
            media_type="application/pdf",
            filename=os.path.basename(path),
        )
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()
