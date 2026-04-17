"""
Ayudas visuales (PDFs por categoría y revisiones).

Esquema SQL (nombres exactos):

    Tbl_Ayudas_Categorias: ID_Categoria, Nombre_Categoria, Activo, Icono_Codigo,
                          Icono_Png_Base64 (legado), Icono_Ico_Base64 (tintado en app)
    Tbl_Ayudas_Maestro: Id_Ayuda, Id_Categoria, Titulo_Documento, Fecha_Creacion, VIN,
                          Subcategoria, Tags (JSON array de #hashtags, NVARCHAR(MAX))
    Tbl_Ayudas_Revisiones: Id_Revision, Id_Ayuda, Numero_Revision, Ruta_PDF, Pdf_Binario (opcional),
                          Fecha_Subida, Es_Vigente, Usuario_Subida

Archivos físicos: Z:\\Ayudas_Visuales\\<NombreCategoria_Sanitizado>\\
  (copia en disco; además cada nueva revisión guarda el PDF en Pdf_Binario cuando la columna existe).
  GET /api/ayudas/ver prioriza Pdf_Binario sobre el archivo de Ruta_PDF.
"""
from __future__ import annotations

import base64
import json
import os
import re
import uuid
from datetime import datetime
from typing import Any, Dict, List, Optional

from fastapi import APIRouter, File, Form, Header, HTTPException, UploadFile
from fastapi.responses import FileResponse, Response
from pydantic import BaseModel, Field

from admin_master_password import assert_admin_master_password_matches
from audit_service import registrar_log_global
from database import get_db_connection
from user_context import resolve_actor_user

router = APIRouter()

AYUDAS_RAIZ = r"Z:\Ayudas_Visuales"


class CategoriaCreatePayload(BaseModel):
    nombre: str = Field(..., min_length=1)
    icono: str = ""
    icono_png_base64: Optional[str] = None
    icono_ico_base64: Optional[str] = None
    fondo_base64: Optional[str] = None

class CategoriaUpdatePayload(BaseModel):
    icono: Optional[str] = None
    icono_png_base64: Optional[str] = None
    icono_ico_base64: Optional[str] = None
    fondo_base64: Optional[str] = None

class EditarSubcategoriaPayload(BaseModel):
    id_categoria: int
    nombre_antiguo: Optional[str] = None
    nombre_nuevo: str = Field(..., min_length=1)


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

def _has_column(cur: Any, table_name: str, column_name: str) -> bool:
    cur.execute(
        """
        SELECT 1
        FROM sys.columns
        WHERE object_id = OBJECT_ID(?) AND name = ?
        """,
        (table_name, column_name),
    )
    return cur.fetchone() is not None

def _ensure_categoria_png_column(cur: Any) -> None:
    cur.execute(
        """
        IF COL_LENGTH('dbo.Tbl_Ayudas_Categorias', 'Icono_Png_Base64') IS NULL
        BEGIN
            ALTER TABLE dbo.Tbl_Ayudas_Categorias
            ADD Icono_Png_Base64 NVARCHAR(MAX) NULL;
        END
        """
    )


def _ensure_categoria_ico_column(cur: Any) -> None:
    cur.execute(
        """
        IF COL_LENGTH('dbo.Tbl_Ayudas_Categorias', 'Icono_Ico_Base64') IS NULL
        BEGIN
            ALTER TABLE dbo.Tbl_Ayudas_Categorias
            ADD Icono_Ico_Base64 NVARCHAR(MAX) NULL;
        END
        """
    )


def _ensure_categoria_fondo_column(cur: Any) -> None:
    cur.execute(
        """
        IF COL_LENGTH('dbo.Tbl_Ayudas_Categorias', 'Fondo_Base64') IS NULL
        BEGIN
            ALTER TABLE dbo.Tbl_Ayudas_Categorias
            ADD Fondo_Base64 NVARCHAR(MAX) NULL;
        END
        """
    )


def _validate_background_image_base64(raw_b64: str) -> str:
    s = (raw_b64 or "").strip()
    if not s:
        return ""
    try:
        raw = base64.b64decode(s, validate=True)
    except Exception:
        raise HTTPException(status_code=400, detail="fondo_base64 inválido")
    if len(raw) > 2 * 1024 * 1024:
        raise HTTPException(status_code=400, detail="Fondo excede 2MB")
    if len(raw) < 8:
        raise HTTPException(status_code=400, detail="Fondo inválido")
    return s


def _validate_categoria_ico_base64(raw_b64: str) -> str:
    """Valida ICO (cabecera estándar) y devuelve el mismo base64 recortado para guardar."""
    s = (raw_b64 or "").strip()
    if not s:
        return ""
    try:
        raw = base64.b64decode(s, validate=True)
    except Exception:
        raise HTTPException(status_code=400, detail="icono_ico_base64 inválido")
    if len(raw) > 256 * 1024:
        raise HTTPException(status_code=400, detail="Ícono ICO excede 256KB")
    if len(raw) < 22:
        raise HTTPException(status_code=400, detail="Archivo ICO demasiado corto")
    if raw[0:2] != b"\x00\x00" or raw[2:4] != b"\x01\x00":
        raise HTTPException(
            status_code=400,
            detail="Formato ICO inválido (se espera tipo icono 1)",
        )
    return s


def _categoria_select_columns_sql(cur: Any) -> str:
    parts = ["ID_Categoria", "Nombre_Categoria", "Activo", "Icono_Codigo"]
    if _has_column(cur, "dbo.Tbl_Ayudas_Categorias", "Icono_Png_Base64"):
        parts.append("Icono_Png_Base64")
    if _has_column(cur, "dbo.Tbl_Ayudas_Categorias", "Icono_Ico_Base64"):
        parts.append("Icono_Ico_Base64")
    if _has_column(cur, "dbo.Tbl_Ayudas_Categorias", "Fondo_Base64"):
        parts.append("Fondo_Base64")
    return ", ".join(parts)


def _ensure_pdf_binario_column(cur: Any) -> None:
    cur.execute(
        """
        IF COL_LENGTH('dbo.Tbl_Ayudas_Revisiones', 'Pdf_Binario') IS NULL
        BEGIN
            ALTER TABLE dbo.Tbl_Ayudas_Revisiones
            ADD Pdf_Binario VARBINARY(MAX) NULL;
        END
        """
    )


def _coerce_pdf_binario(raw: Any) -> Optional[bytes]:
    if raw is None:
        return None
    if isinstance(raw, memoryview):
        b = raw.tobytes()
    elif isinstance(raw, (bytes, bytearray)):
        b = bytes(raw)
    else:
        try:
            b = bytes(raw)
        except Exception:
            return None
    return b if len(b) > 0 else None


def _normalize_consecutivo(raw: str) -> str:
    return re.sub(r"\s+", "", (raw or "").strip()).upper()

def _normalize_role(raw: str) -> str:
    s = (raw or "").strip().upper()
    s = (
        s.replace("Á", "A")
        .replace("É", "E")
        .replace("Í", "I")
        .replace("Ó", "O")
        .replace("Ú", "U")
    )
    return re.sub(r"[^A-Z0-9]+", " ", s).strip()

def _assert_can_edit_categoria_imagen(cur: Any, username: str) -> None:
    user = (username or "").strip()
    if not user:
        raise HTTPException(status_code=403, detail="Usuario no identificado")
    cur.execute(
        "SELECT TOP 1 rol FROM dbo.Tbl_Usuarios WHERE username = ?",
        (user,),
    )
    row = cur.fetchone()
    if not row:
        raise HTTPException(status_code=403, detail="Usuario no encontrado para validar permisos")
    rol = _normalize_role(str(row[0] or ""))
    allow = (
        "ADMIN" in rol
        or "ADMINISTRADOR" in rol
        or "ADMINISTRACION" in rol
        or "DESARROLLADOR" in rol
        or "DESAROLLADOR" in rol
        or "DESARROLLO" in rol
        or "DESAR" in rol
        or "DEV" in rol
        or "INGENIERIA" in rol
        or "METODOS" in rol
    )
    if not allow:
        raise HTTPException(
            status_code=403,
            detail="Solo Desarrollador e Ingenieria pueden editar la imagen de categoria",
        )

def _next_consecutivo_from_values(values: List[str]) -> str:
    max_n = 0
    for v in values:
        s = (v or "").strip().upper()
        if not s:
            continue
        m = re.search(r"(\d+)$", s)
        if m:
            try:
                n = int(m.group(1))
                if n > max_n:
                    max_n = n
            except ValueError:
                continue
    return f"AV-{max_n + 1:06d}"


def _normalize_tags_json(raw: Optional[str]) -> Optional[str]:
    """Recibe JSON array o texto separado por comas; devuelve JSON array compacto o None."""
    if raw is None:
        return None
    s = str(raw).strip()
    if not s:
        return None
    try:
        data = json.loads(s)
        if isinstance(data, list):
            normalized: List[str] = []
            for x in data:
                t = str(x).strip().lstrip("#").strip()
                if t:
                    normalized.append(t)
            return json.dumps(normalized, ensure_ascii=False) if normalized else None
    except json.JSONDecodeError:
        pass
    parts = [p.strip().lstrip("#") for p in re.split(r"[,;\n]+", s) if p.strip()]
    return json.dumps(parts, ensure_ascii=False) if parts else None


def _distinct_tags_for_categoria(cur, id_categoria: int) -> List[str]:
    cur.execute(
        """
        SELECT m.Tags
        FROM Tbl_Ayudas_Maestro m
        WHERE m.Id_Categoria = ? AND m.Tags IS NOT NULL AND LTRIM(RTRIM(m.Tags)) <> ''
        """,
        (id_categoria,),
    )
    seen: set[str] = set()
    for (raw,) in cur.fetchall():
        if not raw:
            continue
        try:
            arr = json.loads(str(raw))
            if isinstance(arr, list):
                for x in arr:
                    t = str(x).strip().lstrip("#").strip()
                    if t:
                        seen.add(t)
        except json.JSONDecodeError:
            continue
    return sorted(seen, key=lambda x: x.lower())


@router.get("/api/ayudas/categorias")
def list_categorias_activas():
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        col_sql = _categoria_select_columns_sql(cur)
        cur.execute(
            f"""
            SELECT {col_sql}
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
    icono_png = (payload.icono_png_base64 or "").strip()
    icono_ico = (payload.icono_ico_base64 or "").strip()
    fondo_b64 = _validate_background_image_base64(payload.fondo_base64 or "")
    if not nombre:
        raise HTTPException(status_code=400, detail="nombre es obligatorio")
    if icono_ico:
        icono_ico = _validate_categoria_ico_base64(icono_ico)
        icono_png = ""
    elif icono_png:
        try:
            raw = base64.b64decode(icono_png, validate=True)
        except Exception:
            raise HTTPException(status_code=400, detail="icono_png_base64 inválido")
        if len(raw) > 512 * 1024:
            raise HTTPException(status_code=400, detail="Ícono PNG excede 512KB")

    usr = resolve_actor_user(authorization, x_usuario)
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        _ensure_categoria_png_column(cur)
        _ensure_categoria_ico_column(cur)
        _ensure_categoria_fondo_column(cur)
        has_png_col = _has_column(cur, "dbo.Tbl_Ayudas_Categorias", "Icono_Png_Base64")
        has_ico_col = _has_column(cur, "dbo.Tbl_Ayudas_Categorias", "Icono_Ico_Base64")
        has_fondo_col = _has_column(cur, "dbo.Tbl_Ayudas_Categorias", "Fondo_Base64")
        cols = ["Nombre_Categoria", "Icono_Codigo"]
        params_ins: List[Any] = [nombre, icono or None]
        if has_png_col:
            cols.append("Icono_Png_Base64")
            params_ins.append(icono_png or None)
        if has_ico_col:
            cols.append("Icono_Ico_Base64")
            params_ins.append(icono_ico or None)
        if has_fondo_col:
            cols.append("Fondo_Base64")
            params_ins.append(fondo_b64 or None)
        cols.append("Activo")
        params_ins.append(1)
        col_sql = ", ".join(cols)
        ph = ", ".join(["?"] * len(params_ins))
        cur.execute(
            f"""
            INSERT INTO Tbl_Ayudas_Categorias ({col_sql})
            OUTPUT INSERTED.ID_Categoria
            VALUES ({ph})
            """,
            tuple(params_ins),
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

@router.put("/api/ayudas/categorias/{id_categoria}")
def editar_categoria(
    id_categoria: int,
    payload: CategoriaUpdatePayload,
    authorization: Optional[str] = Header(None),
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
):
    icono = (payload.icono or "").strip()
    icono_png = (payload.icono_png_base64 or "").strip()
    icono_ico = (payload.icono_ico_base64 or "").strip()
    fondo_b64 = _validate_background_image_base64(payload.fondo_base64 or "")

    if (
        payload.icono is None
        and payload.icono_png_base64 is None
        and payload.icono_ico_base64 is None
        and payload.fondo_base64 is None
    ):
        raise HTTPException(status_code=400, detail="Debe enviar al menos un campo a actualizar")

    if icono_png and icono_ico:
        raise HTTPException(
            status_code=400,
            detail="No enviar ícono PNG e ICO con datos a la vez; use solo uno",
        )

    if icono_png:
        try:
            raw = base64.b64decode(icono_png, validate=True)
        except Exception:
            raise HTTPException(status_code=400, detail="icono_png_base64 inválido")
        if len(raw) > 512 * 1024:
            raise HTTPException(status_code=400, detail="Ícono PNG excede 512KB")

    if icono_ico:
        icono_ico = _validate_categoria_ico_base64(icono_ico)

    usr = resolve_actor_user(authorization, x_usuario)
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        _ensure_categoria_png_column(cur)
        _ensure_categoria_ico_column(cur)
        _ensure_categoria_fondo_column(cur)
        _assert_can_edit_categoria_imagen(cur, usr)
        cur.execute(
            "SELECT Nombre_Categoria FROM Tbl_Ayudas_Categorias WHERE ID_Categoria = ?",
            (id_categoria,),
        )
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Categoría no encontrada")

        has_png_col = _has_column(cur, "dbo.Tbl_Ayudas_Categorias", "Icono_Png_Base64")
        has_ico_col = _has_column(cur, "dbo.Tbl_Ayudas_Categorias", "Icono_Ico_Base64")
        has_fondo_col = _has_column(cur, "dbo.Tbl_Ayudas_Categorias", "Fondo_Base64")
        if payload.icono_png_base64 is not None and icono_png and not has_png_col:
            raise HTTPException(
                status_code=400,
                detail="La BD no soporta Icono_Png_Base64 en Tbl_Ayudas_Categorias",
            )
        if payload.icono_ico_base64 is not None and icono_ico and not has_ico_col:
            raise HTTPException(
                status_code=400,
                detail="La BD no soporta Icono_Ico_Base64 en Tbl_Ayudas_Categorias",
            )
        if payload.fondo_base64 is not None and fondo_b64 and not has_fondo_col:
            raise HTTPException(
                status_code=400,
                detail="La BD no soporta Fondo_Base64 en Tbl_Ayudas_Categorias",
            )

        updates: List[str] = []
        params: List[Any] = []

        if payload.icono is not None:
            updates.append("Icono_Codigo = ?")
            params.append(icono or None)
        if payload.icono_png_base64 is not None and has_png_col:
            updates.append("Icono_Png_Base64 = ?")
            params.append(icono_png or None)
            if icono_png and has_ico_col:
                updates.append("Icono_Ico_Base64 = ?")
                params.append(None)
        if payload.icono_ico_base64 is not None and has_ico_col:
            updates.append("Icono_Ico_Base64 = ?")
            params.append(icono_ico or None)
            if icono_ico and has_png_col:
                updates.append("Icono_Png_Base64 = ?")
                params.append(None)
        if payload.fondo_base64 is not None and has_fondo_col:
            updates.append("Fondo_Base64 = ?")
            params.append(fondo_b64 or None)

        if not updates:
            return {"ok": True, "id_categoria": id_categoria, "updated": False}

        sql = f"UPDATE Tbl_Ayudas_Categorias SET {', '.join(updates)} WHERE ID_Categoria = ?"
        params.append(id_categoria)
        cur.execute(sql, tuple(params))

        detalle = (
            f"id={id_categoria};nombre={row[0]};"
            f"icono={(icono if payload.icono is not None else '[sin-cambio]') or '-'};"
            f"icono_png={'actualizado' if payload.icono_png_base64 is not None else 'sin-cambio'};"
            f"icono_ico={'actualizado' if payload.icono_ico_base64 is not None else 'sin-cambio'};"
            f"fondo={'actualizado' if payload.fondo_base64 is not None else 'sin-cambio'}"
        )
        registrar_log_global(cur, "AYUDAS", "EDITAR_CATEGORIA_AYUDAS", "", detalle, usr)
        conn.commit()
        return {"ok": True, "id_categoria": id_categoria, "updated": True}
    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.get("/api/ayudas/tags/{id_categoria}")
def lista_tags_categoria(id_categoria: int):
    """Lista de etiquetas unicas (#hashtags) usadas en la categoria (para filtros y sugerencias)."""
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        return _distinct_tags_for_categoria(cur, id_categoria)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.get("/api/ayudas/lista/{id_categoria}")
def lista_documentos_categoria(id_categoria: int):
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        has_consec = _has_column(cur, "dbo.Tbl_Ayudas_Revisiones", "Consecutivo_Unico")
        if has_consec:
            cur.execute(
                """
                SELECT
                    m.Id_Ayuda,
                    m.Id_Categoria,
                    m.Titulo_Documento,
                    m.Subcategoria,
                    m.VIN,
                    m.Tags,
                    r.Id_Revision,
                    r.Numero_Revision,
                    r.Consecutivo_Unico,
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
        else:
            cur.execute(
                """
                SELECT
                    m.Id_Ayuda,
                    m.Id_Categoria,
                    m.Titulo_Documento,
                    m.Subcategoria,
                    m.VIN,
                    m.Tags,
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
        has_consec = _has_column(cur, "dbo.Tbl_Ayudas_Revisiones", "Consecutivo_Unico")
        if has_consec:
            cur.execute(
                """
                SELECT
                    Id_Revision,
                    Id_Ayuda,
                    Numero_Revision,
                    Consecutivo_Unico,
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
        else:
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


@router.get("/api/ayudas/secundaria-opciones/{id_ayuda}")
def opciones_secundaria_misma_categoria(id_ayuda: int):
    """Opciones de comparación secundaria: ayudas vigentes de la misma categoría."""
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        cur.execute(
            """
            SELECT TOP 1 Id_Categoria
            FROM Tbl_Ayudas_Maestro
            WHERE Id_Ayuda = ?
            """,
            (id_ayuda,),
        )
        row_cat = cur.fetchone()
        if not row_cat:
            raise HTTPException(status_code=404, detail="Ayuda no encontrada")
        id_categoria = int(row_cat[0])
        has_consec = _has_column(cur, "dbo.Tbl_Ayudas_Revisiones", "Consecutivo_Unico")
        if has_consec:
            cur.execute(
                """
                SELECT
                    m.Id_Ayuda,
                    m.Id_Categoria,
                    m.Titulo_Documento,
                    m.Subcategoria,
                    m.VIN,
                    m.Tags,
                    r.Id_Revision,
                    r.Numero_Revision,
                    r.Consecutivo_Unico,
                    r.Fecha_Subida,
                    r.Es_Vigente,
                    r.Ruta_PDF,
                    r.Usuario_Subida
                FROM Tbl_Ayudas_Maestro m
                INNER JOIN Tbl_Ayudas_Revisiones r
                    ON r.Id_Ayuda = m.Id_Ayuda AND r.Es_Vigente = 1
                WHERE m.Id_Categoria = ?
                  AND m.Id_Ayuda <> ?
                ORDER BY m.Titulo_Documento
                """,
                (id_categoria, id_ayuda),
            )
        else:
            cur.execute(
                """
                SELECT
                    m.Id_Ayuda,
                    m.Id_Categoria,
                    m.Titulo_Documento,
                    m.Subcategoria,
                    m.VIN,
                    m.Tags,
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
                  AND m.Id_Ayuda <> ?
                ORDER BY m.Titulo_Documento
                """,
                (id_categoria, id_ayuda),
            )
        rows = cur.fetchall()
        return [_row_to_dict(cur, r) for r in rows]
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

@router.put("/api/ayudas/subcategoria/editar")
def editar_subcategoria_masiva(
    payload: EditarSubcategoriaPayload,
    authorization: Optional[str] = Header(None),
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
):
    usr = resolve_actor_user(authorization, x_usuario)
    id_categoria = int(payload.id_categoria)
    nombre_antiguo = payload.nombre_antiguo
    nombre_nuevo = (payload.nombre_nuevo or "").strip()
    if not nombre_nuevo:
        raise HTTPException(status_code=400, detail="nombre_nuevo es obligatorio")

    conn = get_db_connection()
    cur = conn.cursor()
    try:
        if nombre_antiguo is None or not str(nombre_antiguo).strip():
            cur.execute(
                """
                UPDATE Tbl_Ayudas_Maestro
                SET Subcategoria = ?
                WHERE Id_Categoria = ?
                  AND (Subcategoria IS NULL OR LTRIM(RTRIM(Subcategoria)) = '')
                """,
                (nombre_nuevo, id_categoria),
            )
            old_label = "(vacio)"
        else:
            old_value = str(nombre_antiguo).strip()
            cur.execute(
                """
                UPDATE Tbl_Ayudas_Maestro
                SET Subcategoria = ?
                WHERE Id_Categoria = ?
                  AND Subcategoria = ?
                """,
                (nombre_nuevo, id_categoria, old_value),
            )
            old_label = old_value

        updated = int(cur.rowcount or 0)
        detalle = (
            f"id_categoria={id_categoria};old={old_label[:80]};"
            f"new={nombre_nuevo[:80]};rows={updated}"
        )
        registrar_log_global(
            cur,
            "AYUDAS",
            "EDITAR_SUBCATEGORIA_MASIVA",
            "",
            detalle[:250],
            usr,
        )
        conn.commit()
        return {"ok": True, "updated": updated}
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.delete("/api/ayudas/revision/{id_revision}")
def eliminar_revision(
    id_revision: int,
    authorization: Optional[str] = Header(None),
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
    x_admin_master_password: Optional[str] = Header(
        None, alias="X-Admin-Master-Password"
    ),
):
    assert_admin_master_password_matches(x_admin_master_password)
    usr = resolve_actor_user(authorization, x_usuario)
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        cur.execute(
            """
            SELECT Id_Ayuda, Ruta_PDF, Numero_Revision, ISNULL(Es_Vigente, 0)
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
        era_vigente = bool(int(row[3] or 0))

        cur.execute(
            "DELETE FROM Tbl_Ayudas_Revisiones WHERE Id_Revision = ?",
            (id_revision,),
        )

        promoted_revision_id: Optional[int] = None
        # Si al borrar una revisión (vigente o por datos inconsistentes) no queda ninguna
        # revisión marcada como vigente, promovemos la más reciente restante.
        cur.execute(
            """
            SELECT TOP 1 Id_Revision
            FROM Tbl_Ayudas_Revisiones
            WHERE Id_Ayuda = ? AND Es_Vigente = 1
            ORDER BY Fecha_Subida DESC, Id_Revision DESC
            """,
            (id_ayuda,),
        )
        row_vig = cur.fetchone()
        if row_vig is None:
            cur.execute(
                """
                SELECT TOP 1 Id_Revision
                FROM Tbl_Ayudas_Revisiones
                WHERE Id_Ayuda = ?
                ORDER BY Fecha_Subida DESC, Id_Revision DESC
                """,
                (id_ayuda,),
            )
            row_promote = cur.fetchone()
            if row_promote:
                promoted_revision_id = int(row_promote[0])
                cur.execute(
                    "UPDATE Tbl_Ayudas_Revisiones SET Es_Vigente = 0 WHERE Id_Ayuda = ?",
                    (id_ayuda,),
                )
                cur.execute(
                    "UPDATE Tbl_Ayudas_Revisiones SET Es_Vigente = 1 WHERE Id_Revision = ?",
                    (promoted_revision_id,),
                )

        detalle = (
            f"id_rev={id_revision};id_ayuda={id_ayuda};num={num_rev};"
            f"era_vigente={1 if era_vigente else 0};"
            f"promovida={promoted_revision_id if promoted_revision_id else '-'}"
        )
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

        return {"ok": True, "promoted_revision_id": promoted_revision_id}
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
    x_admin_master_password: Optional[str] = Header(
        None, alias="X-Admin-Master-Password"
    ),
):
    """Elimina todas las revisiones y el registro maestro del documento."""
    assert_admin_master_password_matches(x_admin_master_password)
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
    consecutivo: Optional[str] = Form(None),
    usuario: str = Form(...),
    vin: Optional[str] = Form(None),
    tags: Optional[str] = Form(None),
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

    tags_json = _normalize_tags_json(tags)

    consec_raw = (consecutivo or "").strip() or (numero_revision or "").strip()
    consec_norm = _normalize_consecutivo(consec_raw)
    if not consec_norm:
        raise HTTPException(status_code=400, detail="Consecutivo único es obligatorio")

    conn = get_db_connection()
    cur = conn.cursor()
    try:
        _ensure_pdf_binario_column(cur)
        has_pdf_binario_col = _has_column(cur, "dbo.Tbl_Ayudas_Revisiones", "Pdf_Binario")

        id_ayuda_int: Optional[int] = None
        id_cat_int: Optional[int] = None
        nombre_categoria: str = ""

        has_consec_col = _has_column(cur, "dbo.Tbl_Ayudas_Revisiones", "Consecutivo_Unico")
        if has_consec_col:
            cur.execute(
                """
                SELECT TOP 1 Id_Revision
                FROM Tbl_Ayudas_Revisiones
                WHERE UPPER(REPLACE(LTRIM(RTRIM(ISNULL(Consecutivo_Unico, ''))), ' ', '')) = ?
                """,
                (consec_norm,),
            )
        else:
            cur.execute(
                """
                SELECT TOP 1 Id_Revision
                FROM Tbl_Ayudas_Revisiones
                WHERE UPPER(REPLACE(LTRIM(RTRIM(ISNULL(Numero_Revision, ''))), ' ', '')) = ?
                """,
                (consec_norm,),
            )
        dup = cur.fetchone()
        if dup:
            raise HTTPException(
                status_code=409,
                detail=f"El consecutivo '{consec_raw}' ya existe. Debe ser único.",
            )

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
            if tags_json is not None:
                cur.execute(
                    "UPDATE Tbl_Ayudas_Maestro SET Tags = ? WHERE Id_Ayuda = ?",
                    (tags_json, id_ayuda_int),
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
                    (Id_Categoria, Titulo_Documento, Subcategoria, Fecha_Creacion, VIN, Tags)
                OUTPUT INSERTED.Id_Ayuda
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    id_cat_int,
                    titulo_doc,
                    subcategoria_raw,
                    ahora_creacion,
                    vin_raw,
                    tags_json,
                ),
            )
            id_ayuda_int = int(cur.fetchone()[0])

        assert id_ayuda_int is not None

        carpeta = os.path.join(AYUDAS_RAIZ, _sanitize_folder_name(nombre_categoria))
        os.makedirs(carpeta, exist_ok=True)

        safe_rev = re.sub(r'[^\w.\-]', "_", consec_norm) or "rev"
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
        if has_consec_col:
            if has_pdf_binario_col:
                cur.execute(
                    """
                    INSERT INTO Tbl_Ayudas_Revisiones
                        (Id_Ayuda, Numero_Revision, Consecutivo_Unico, Ruta_PDF, Pdf_Binario, Fecha_Subida, Es_Vigente, Usuario_Subida)
                    OUTPUT INSERTED.Id_Revision
                    VALUES (?, ?, ?, ?, ?, ?, 1, ?)
                    """,
                    (
                        id_ayuda_int,
                        numero_revision.strip(),
                        consec_norm,
                        dest_path,
                        body,
                        ahora_subida,
                        usuario_limpio,
                    ),
                )
            else:
                cur.execute(
                    """
                    INSERT INTO Tbl_Ayudas_Revisiones
                        (Id_Ayuda, Numero_Revision, Consecutivo_Unico, Ruta_PDF, Fecha_Subida, Es_Vigente, Usuario_Subida)
                    OUTPUT INSERTED.Id_Revision
                    VALUES (?, ?, ?, ?, ?, 1, ?)
                    """,
                    (
                        id_ayuda_int,
                        numero_revision.strip(),
                        consec_norm,
                        dest_path,
                        ahora_subida,
                        usuario_limpio,
                    ),
                )
        elif has_pdf_binario_col:
            cur.execute(
                """
                INSERT INTO Tbl_Ayudas_Revisiones
                    (Id_Ayuda, Numero_Revision, Ruta_PDF, Pdf_Binario, Fecha_Subida, Es_Vigente, Usuario_Subida)
                OUTPUT INSERTED.Id_Revision
                VALUES (?, ?, ?, ?, ?, 1, ?)
                """,
                (
                    id_ayuda_int,
                    consec_norm,
                    dest_path,
                    body,
                    ahora_subida,
                    usuario_limpio,
                ),
            )
        else:
            cur.execute(
                """
                INSERT INTO Tbl_Ayudas_Revisiones
                    (Id_Ayuda, Numero_Revision, Ruta_PDF, Fecha_Subida, Es_Vigente, Usuario_Subida)
                OUTPUT INSERTED.Id_Revision
                VALUES (?, ?, ?, ?, 1, ?)
                """,
                (id_ayuda_int, consec_norm, dest_path, ahora_subida, usuario_limpio),
            )
        new_id = int(cur.fetchone()[0])

        log_nuevo = (
            f"id_rev={new_id};num={numero_revision.strip()};consec={consec_norm};"
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
            "consecutivo": consec_norm,
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

@router.get("/api/ayudas/consecutivo/siguiente")
def sugerir_consecutivo_siguiente():
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        has_consec = _has_column(cur, "dbo.Tbl_Ayudas_Revisiones", "Consecutivo_Unico")
        if has_consec:
            cur.execute(
                """
                SELECT Consecutivo_Unico
                FROM Tbl_Ayudas_Revisiones
                WHERE Consecutivo_Unico IS NOT NULL AND LTRIM(RTRIM(Consecutivo_Unico)) <> ''
                """
            )
        else:
            cur.execute(
                """
                SELECT Numero_Revision
                FROM Tbl_Ayudas_Revisiones
                WHERE Numero_Revision IS NOT NULL AND LTRIM(RTRIM(Numero_Revision)) <> ''
                """
            )
        vals = [str(r[0] or "").strip() for r in cur.fetchall()]
        return {"sugerido": _next_consecutivo_from_values(vals)}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.get("/api/ayudas/ver/{id_revision}")
def ver_pdf_revision(id_revision: int):
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        _ensure_pdf_binario_column(cur)
        has_bin = _has_column(cur, "dbo.Tbl_Ayudas_Revisiones", "Pdf_Binario")
        if has_bin:
            cur.execute(
                """
                SELECT Ruta_PDF, Pdf_Binario
                FROM Tbl_Ayudas_Revisiones
                WHERE Id_Revision = ?
                """,
                (id_revision,),
            )
        else:
            cur.execute(
                """
                SELECT Ruta_PDF
                FROM Tbl_Ayudas_Revisiones
                WHERE Id_Revision = ?
                """,
                (id_revision,),
            )
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Revisión no encontrada")
        path = str(row[0] or "").strip()
        if has_bin and len(row) > 1:
            blob = _coerce_pdf_binario(row[1])
            if blob is not None:
                return Response(
                    content=blob,
                    media_type="application/pdf",
                    headers={
                        "Content-Disposition": f'inline; filename="ayuda_{id_revision}.pdf"'
                    },
                )
        if not path:
            raise HTTPException(status_code=404, detail="Revisión no encontrada")
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
