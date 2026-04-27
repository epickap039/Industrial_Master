"""API router: reconciliación BOM (lista) vs export CSV SolidWorks (macro)."""

from __future__ import annotations

import json
import traceback
from typing import Any, Optional, Union

import pyodbc
from fastapi import APIRouter, File, Form, Header, HTTPException, UploadFile
from fastapi.responses import Response

from bom_despiece_service import (
    compare_despiece,
    filas_to_csv,
    limit_filas_para_api,
    parse_sw_export_csv,
)
from database import get_db_connection
from user_context import resolve_actor_user

router = APIRouter()


def _parse_form_bool(v: Union[bool, str, None]) -> bool:
    if v is None:
        return True
    if isinstance(v, bool):
        return v
    s = str(v).strip().lower()
    if s in ("0", "false", "no", "n", "f", "off"):
        return False
    return True


def _revision_exists(cursor, id_revision: int) -> bool:
    cursor.execute(
        "SELECT 1 FROM Tbl_BOM_Revisiones WHERE ID_Revision = ?",
        (id_revision,),
    )
    return cursor.fetchone() is not None


def _auditoria_despiece(
    cursor,
    id_revision: int,
    detalle: str,
    usuario: str,
) -> None:
    cursor.execute(
        """
        INSERT INTO Tbl_Auditoria_Cambios (
            Codigo_Pieza, Accion, Valor_Anterior, Valor_Nuevo, Usuario, Fecha_Hora
        )
        VALUES (?, ?, ?, ?, ?, GETDATE())
        """,
        (
            f"BOM-DESPIECE-{id_revision}",
            "despiece_sw_compare",
            "csv_sw",
            (detalle or "")[:3800],
            (usuario or "Sistema")[:100],
        ),
    )


@router.get("/api/bom/despiece/spec")
def bom_despiece_spec() -> Any:
    """Contrato del CSV (columnas y convenciones) para la macro SolidWorks."""
    return {
        "delimiter": [";", ","],
        "encoding": "UTF-8 (con o sin BOM; el servidor acepta utf-8-sig)",
        "columns": [
            {"name": "codigo", "required": True, "description": "Stem del archivo de pieza/ensamble"},
            {"name": "cantidad", "required": True, "description": "Cantidad efectiva respecto al raíz"},
            {"name": "ruta_subensambles", "required": False},
            {"name": "suprimido", "required": False, "description": "0/1 o S/N — filas suprimidas se ignoran"},
            {"name": "archivo_completo", "required": False},
            {"name": "configuracion", "required": False},
        ],
        "macro_entry_point": "ExportarBOM_IndustrialManager",
        "macro_source_file": "backend/tools/export_bom_solidworks.bas",
        "form_fields_compare": {
            "include_suppressed": "true/false — si false, filas con suprimido=1 no entran en el diff.",
            "max_muestra_filas": "30–500 (default 200): máximo de filas de discrepancia en el JSON; el CSV de informe lleva todas.",
        },
    }


@router.post("/api/bom/despiece/compare")
async def bom_despiece_compare(
    file: UploadFile = File(...),
    id_revision: int = Form(...),
    include_suppressed: str = Form("false"),
    max_muestra_filas: str = Form("200"),
    authorization: Optional[str] = Header(None),
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
) -> Any:
    """
    Sube el CSV generado en SolidWorks y compara contra ``Tbl_BOM_Estructura`` de la revisión.

    La respuesta JSON incluye como máximo ``max_muestra_filas`` filas de discrepancia (muestra priorizada);
    el informe CSV descargable lleva el diff completo.
    """
    raw = await file.read()
    if not raw:
        raise HTTPException(status_code=400, detail="Archivo vacío.")

    try:
        sw_rows = parse_sw_export_csv(raw)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e
    except Exception as e:
        raise HTTPException(
            status_code=400,
            detail=f"No se pudo leer el CSV: {e}",
        ) from e

    ulog = resolve_actor_user(authorization, x_usuario)
    if ulog == "Sistema":
        ulog = (x_usuario or "").strip() or "Operador"

    incl_sup = _parse_form_bool(include_suppressed)
    try:
        max_m = max(30, min(500, int(str(max_muestra_filas).strip() or "200")))
    except ValueError:
        max_m = 200

    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        if not _revision_exists(cursor, id_revision):
            raise HTTPException(
                status_code=404,
                detail=f"No existe ID_Revisión {id_revision}.",
            )

        try:
            result = compare_despiece(
                id_revision,
                sw_rows,
                include_suppressed=incl_sup,
                cursor=cursor,
            )
        except ValueError as e:
            raise HTTPException(status_code=400, detail=str(e)) from e

        resumen = {
            "lineas_sw_usadas": result.lineas_sw_usadas,
            "lineas_lista": result.lineas_lista,
            "codigos_sw_unicos": result.codigos_sw_unicos,
            "codigos_lista_unicos": result.codigos_lista_unicos,
            "discrepancias": len(result.filas),
            "codigos_en_ambos": result.codigos_en_ambos,
            "codigos_solo_en_sw": result.codigos_solo_sw,
            "codigos_solo_en_lista": result.codigos_solo_lista,
            "codigos_coinciden_cantidades": result.codigos_ok_cantidades,
            "codigos_conflicto_cantidades": result.codigos_conflicto_cantidad,
            "csv_filas_total": result.csv_filas_total,
            "csv_filas_suprimidas": result.csv_filas_suprimidas,
        }
        filas_api, trunc = limit_filas_para_api(result.filas, max_filas=max_m)
        body = {
            "id_revision": id_revision,
            "include_suppressed": incl_sup,
            "max_muestra_filas": max_m,
            "resumen": resumen,
            "por_tipo": result.por_tipo,
            "cobertura_por_estacion": result.cobertura_por_estacion,
            "filas": filas_api,
            "filas_truncamiento": trunc,
        }

        try:
            detalle = json.dumps(
                {
                    "resumen": resumen,
                    "por_tipo": result.por_tipo,
                    "archivo": file.filename or "",
                },
                ensure_ascii=False,
            )
            _auditoria_despiece(cursor, id_revision, detalle, ulog)
        except pyodbc.Error:
            conn.rollback()
            conn.close()
            raise
        conn.commit()

        return body
    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e)) from e
    finally:
        try:
            cursor.close()
            conn.close()
        except Exception:
            pass


@router.post("/api/bom/despiece/reporte-csv")
async def bom_despiece_reporte_csv(
    file: UploadFile = File(...),
    id_revision: int = Form(...),
    include_suppressed: str = Form("false"),
    authorization: Optional[str] = Header(None),
    x_usuario: Optional[str] = Header(None, alias="X-Usuario"),
) -> Response:
    """Misma comparación que ``compare``; respuesta es CSV descargable (vuelve a ejecutar el diff)."""
    raw = await file.read()
    if not raw:
        raise HTTPException(status_code=400, detail="Archivo vacío.")
    try:
        sw_rows = parse_sw_export_csv(raw)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e

    ulog = resolve_actor_user(authorization, x_usuario)
    if ulog == "Sistema":
        ulog = (x_usuario or "").strip() or "Operador"

    incl_sup = _parse_form_bool(include_suppressed)

    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        if not _revision_exists(cursor, id_revision):
            raise HTTPException(
                status_code=404,
                detail=f"No existe ID_Revisión {id_revision}.",
            )
        result = compare_despiece(
            id_revision,
            sw_rows,
            include_suppressed=incl_sup,
            cursor=cursor,
        )
        _auditoria_despiece(
            cursor,
            id_revision,
            json.dumps(
                {
                    "via": "reporte_csv",
                    "resumen": {
                        "discrepancias": len(result.filas),
                    },
                    "archivo": file.filename or "",
                },
                ensure_ascii=False,
            ),
            ulog,
        )
        conn.commit()
        csv_text = filas_to_csv(result.filas)
        return Response(
            content=csv_text.encode("utf-8-sig"),
            media_type="text/csv; charset=utf-8",
            headers={
                "Content-Disposition": f'attachment; filename="despiece_rev{id_revision}.csv"'
            },
        )
    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e)) from e
    finally:
        try:
            cursor.close()
            conn.close()
        except Exception:
            pass
