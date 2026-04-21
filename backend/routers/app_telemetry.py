"""Telemetría de uso (navegación / sesión) agregada en SQL; lectura solo rol desarrollador."""
from __future__ import annotations

from typing import Any, Dict, List, Optional

from fastapi import APIRouter, Header, HTTPException, Query
from pydantic import BaseModel, Field

from database import get_db_connection
from jwt_tokens import decode_access_token_payload

router = APIRouter()

_ROLES_DEV = frozenset(
    {
        "DESARROLLADOR",
        "DESARROLLO",
        "DEVELOPER",
        "DEV",
        "PROGRAMADOR",
    }
)

_ALLOWED_TIPOS = frozenset({"nav", "feature", "sesion"})


def _require_desarrollador(authorization: Optional[str]) -> None:
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
    if rol not in _ROLES_DEV:
        raise HTTPException(
            status_code=403,
            detail="Solo el rol desarrollador puede consultar la telemetría agregada",
        )


def _actor_from_token(authorization: Optional[str]) -> tuple[str, str]:
    data = decode_access_token_payload(authorization)
    if not data:
        raise HTTPException(status_code=401, detail="No autorizado")
    sub = str(data.get("sub") or "").strip()
    if not sub:
        raise HTTPException(status_code=401, detail="Token inválido")
    rol = str(data.get("rol") or "USER").strip()
    return sub, rol


def _ensure_table(cur) -> None:
    cur.execute(
        """
        IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Tbl_App_Uso_Eventos' AND schema_id = SCHEMA_ID('dbo'))
        BEGIN
            CREATE TABLE dbo.Tbl_App_Uso_Eventos (
                ID_Evento INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
                Fecha_Hora DATETIME2(3) NOT NULL CONSTRAINT DF_AppUso_Fecha DEFAULT SYSUTCDATETIME(),
                Usuario_Login NVARCHAR(200) NOT NULL,
                Rol_Efectivo NVARCHAR(120) NOT NULL,
                Tipo NVARCHAR(20) NOT NULL,
                Destino_Codigo NVARCHAR(120) NOT NULL,
                Destino_Etiqueta NVARCHAR(240) NOT NULL
            );
            CREATE INDEX IX_AppUso_Fecha ON dbo.Tbl_App_Uso_Eventos(Fecha_Hora DESC);
            CREATE INDEX IX_AppUso_Destino ON dbo.Tbl_App_Uso_Eventos(Destino_Codigo, Tipo);
            CREATE INDEX IX_AppUso_Usuario ON dbo.Tbl_App_Uso_Eventos(Usuario_Login);
        END
        """
    )


class TelemetryEventIn(BaseModel):
    tipo: str = Field(..., max_length=20)
    destino_codigo: str = Field(..., max_length=120)
    destino_etiqueta: str = Field(..., max_length=240)
    rol_efectivo: str = Field(..., max_length=120)


@router.post("/api/app/telemetry/event")
def registrar_evento_uso(
    payload: TelemetryEventIn,
    authorization: Optional[str] = Header(None),
):
    """Cualquier usuario autenticado puede registrar eventos (fire-and-forget desde el cliente)."""
    usuario, _rol_token = _actor_from_token(authorization)
    t = (payload.tipo or "").strip().lower()
    if t not in _ALLOWED_TIPOS:
        raise HTTPException(status_code=400, detail="tipo inválido")
    dc = (payload.destino_codigo or "").strip()
    de = (payload.destino_etiqueta or "").strip()
    re = (payload.rol_efectivo or "").strip()
    if not dc or not de:
        raise HTTPException(status_code=400, detail="destino vacío")
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        _ensure_table(cur)
        cur.execute(
            """
            INSERT INTO dbo.Tbl_App_Uso_Eventos
                (Usuario_Login, Rol_Efectivo, Tipo, Destino_Codigo, Destino_Etiqueta)
            VALUES (?, ?, ?, ?, ?)
            """,
            (usuario[:200], re[:120], t[:20], dc[:120], de[:240]),
        )
        conn.commit()
        return {"ok": True}
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.get("/api/dev/telemetry/resumen")
def resumen_telemetria(
    days: int = Query(14, ge=1, le=90),
    authorization: Optional[str] = Header(None),
) -> Dict[str, Any]:
    _require_desarrollador(authorization)
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        _ensure_table(cur)
        cur.execute(
            """
            SELECT COUNT(*), COUNT(DISTINCT Usuario_Login)
            FROM dbo.Tbl_App_Uso_Eventos
            WHERE Fecha_Hora >= DATEADD(day, ?, SYSUTCDATETIME())
            """,
            (-days,),
        )
        row = cur.fetchone()
        total = int(row[0]) if row and row[0] is not None else 0
        usuarios = int(row[1]) if row and row[1] is not None else 0

        cur.execute(
            """
            SELECT TOP 18 Destino_Etiqueta, COUNT(*) AS n
            FROM dbo.Tbl_App_Uso_Eventos
            WHERE Fecha_Hora >= DATEADD(day, ?, SYSUTCDATETIME())
            GROUP BY Destino_Etiqueta
            ORDER BY n DESC
            """,
            (-days,),
        )
        top_dest: List[Dict[str, Any]] = []
        for r in cur.fetchall() or []:
            top_dest.append({"destino_etiqueta": str(r[0] or ""), "n": int(r[1] or 0)})

        cur.execute(
            """
            SELECT CAST(Fecha_Hora AS DATE) AS d, COUNT(*) AS n
            FROM dbo.Tbl_App_Uso_Eventos
            WHERE Fecha_Hora >= DATEADD(day, ?, SYSUTCDATETIME())
            GROUP BY CAST(Fecha_Hora AS DATE)
            ORDER BY d ASC
            """,
            (-days,),
        )
        por_dia: List[Dict[str, Any]] = []
        for r in cur.fetchall() or []:
            d = r[0]
            por_dia.append(
                {
                    "fecha": d.strftime("%Y-%m-%d") if d is not None else "",
                    "n": int(r[1] or 0),
                }
            )

        cur.execute(
            """
            SELECT TOP 12 Usuario_Login, COUNT(*) AS n
            FROM dbo.Tbl_App_Uso_Eventos
            WHERE Fecha_Hora >= DATEADD(day, ?, SYSUTCDATETIME())
            GROUP BY Usuario_Login
            ORDER BY n DESC
            """,
            (-days,),
        )
        top_users: List[Dict[str, Any]] = []
        for r in cur.fetchall() or []:
            top_users.append({"usuario_login": str(r[0] or ""), "n": int(r[1] or 0)})

        return {
            "days": days,
            "totales": {"eventos": total, "usuarios_distintos": usuarios},
            "top_destinos": top_dest,
            "por_dia": por_dia,
            "top_usuarios": top_users,
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()
