"""Delta de Tbl_Auditoria_Cambios para notificaciones del rol Desarrollador (solo lectura)."""
from __future__ import annotations

from typing import Any, Dict, List, Optional

from fastapi import APIRouter, Header, HTTPException, Query

from database import get_db_connection
from jwt_tokens import decode_access_token_payload

router = APIRouter()

_ROLES_DEV_FEED = frozenset(
    {
        "DESARROLLADOR",
        "DESARROLLO",
        "DEVELOPER",
        "DEV",
        "PROGRAMADOR",
    }
)


def _require_desarrollador(authorization: Optional[str]) -> str:
    data = decode_access_token_payload(authorization)
    if not data:
        raise HTTPException(status_code=401, detail="No autorizado")
    rol = (
        str(data.get("rol") or "")
        .strip()
        .upper()
        .replace("Á", "A")
        .replace("É", "E")
        .replace("Í", "I")
        .replace("Ó", "O")
        .replace("Ú", "U")
    )
    if rol not in _ROLES_DEV_FEED:
        raise HTTPException(
            status_code=403,
            detail="Solo el rol desarrollador puede consultar este feed",
        )
    sub = str(data.get("sub") or "").strip()
    if not sub:
        raise HTTPException(status_code=401, detail="Token inválido")
    return sub


@router.get("/api/dev/auditoria_delta")
def dev_auditoria_delta(
    since_id: int = Query(0, ge=0),
    authorization: Optional[str] = Header(None),
) -> Dict[str, Any]:
    """
    Devuelve filas nuevas de auditoría (importaciones BOM, sync Excel, borrados, etc.)
    y el MAX(ID_Log) actual para que el cliente mantenga cursor sin perder eventos.
    """
    _require_desarrollador(authorization)
    conn = get_db_connection()
    cursor = conn.cursor()
    try:
        cursor.execute("SELECT ISNULL(MAX(ID_Log), 0) FROM Tbl_Auditoria_Cambios")
        max_row = cursor.fetchone()
        max_id = int(max_row[0]) if max_row and max_row[0] is not None else 0

        cursor.execute(
            """
            SELECT TOP 50 ID_Log, Codigo_Pieza, Accion, Valor_Anterior, Valor_Nuevo, Usuario, Fecha_Hora
            FROM Tbl_Auditoria_Cambios
            WHERE ID_Log > ?
            ORDER BY ID_Log ASC
            """,
            (since_id,),
        )
        rows = cursor.fetchall()
        items: List[Dict[str, Any]] = []
        for r in rows:
            fh = r[6]
            items.append(
                {
                    "id_log": int(r[0]),
                    "codigo": (r[1] or "") if r[1] is not None else "",
                    "accion": (r[2] or "") if r[2] is not None else "",
                    "valor_anterior": (str(r[3])[:400] if r[3] is not None else ""),
                    "valor_nuevo": (str(r[4])[:400] if r[4] is not None else ""),
                    "usuario": (r[5] or "") if r[5] is not None else "",
                    "fecha": fh.strftime("%Y-%m-%d %H:%M:%S") if fh else None,
                }
            )
        return {"items": items, "max_id": max_id}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()
