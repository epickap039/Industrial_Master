"""Telemetría de uso (navegación / sesión) agregada en SQL; lectura solo rol desarrollador."""
from __future__ import annotations

from typing import Any, Dict, List, Optional

from fastapi import APIRouter, Header, HTTPException, Query
from pydantic import BaseModel, Field

from database import get_db_connection
from env_config import allow_runtime_ddl
from jwt_tokens import decode_access_token_payload
from schema_guard import table_exists

router = APIRouter()

# Código que marca el heartbeat de presencia (no es navegación real; se excluye
# de las agregaciones de "destinos más frecuentes" y conteos de actividad).
_HEARTBEAT_CODIGO = "heartbeat"


def _rol_normalizado(data: Optional[Dict[str, Any]]) -> str:
    return (
        str((data or {}).get("rol") or "")
        .strip()
        .upper()
        .replace("Á", "A")
        .replace("É", "E")
        .replace("Í", "I")
        .replace("Ó", "O")
        .replace("Ú", "U")
    )


def _es_dev_o_ingenieria(rol_norm: str) -> bool:
    """Acceso a la telemetría/auditoría: rol desarrollador o ingeniería.

    Tolerante a sufijos/prefijos (p. ej. 'INGENIERIA IMV353', 'ROL: DESARROLLADOR').
    """
    if not rol_norm:
        return False
    if rol_norm == "DEV":
        return True
    if any(
        k in rol_norm
        for k in ("DESARROLLAD", "DESAROLLAD", "DESARROLLO", "DEVELOPER", "PROGRAMADOR")
    ):
        return True
    if "INGENIERIA" in rol_norm or "METODOS" in rol_norm:
        return True
    return False


_ALLOWED_TIPOS = frozenset({"nav", "feature", "sesion"})


def _require_telemetria(authorization: Optional[str]) -> None:
    data = decode_access_token_payload(authorization)
    if not data:
        raise HTTPException(status_code=401, detail="No autorizado")
    if not _es_dev_o_ingenieria(_rol_normalizado(data)):
        raise HTTPException(
            status_code=403,
            detail="Solo desarrollador e ingeniería pueden consultar la telemetría agregada",
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


def _prepare_telemetry_table(cur) -> None:
    if table_exists(cur, "Tbl_App_Uso_Eventos"):
        return
    if allow_runtime_ddl():
        _ensure_telemetry_table(cur)
    else:
        raise HTTPException(
            status_code=503,
            detail="Tbl_App_Uso_Eventos no existe. Aplique migración de telemetría o use IM_ALLOW_RUNTIME_DDL=1 solo en desarrollo.",
        )


def _ensure_telemetry_table(cur) -> None:
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
        _prepare_telemetry_table(cur)
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
    _require_telemetria(authorization)
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        _prepare_telemetry_table(cur)
        cur.execute(
            """
            SELECT COUNT(*), COUNT(DISTINCT Usuario_Login)
            FROM dbo.Tbl_App_Uso_Eventos
            WHERE Fecha_Hora >= DATEADD(day, ?, SYSUTCDATETIME())
              AND Destino_Codigo <> ?
            """,
            (-days, _HEARTBEAT_CODIGO),
        )
        row = cur.fetchone()
        total = int(row[0]) if row and row[0] is not None else 0
        usuarios = int(row[1]) if row and row[1] is not None else 0

        cur.execute(
            """
            SELECT TOP 18 Destino_Etiqueta, COUNT(*) AS n
            FROM dbo.Tbl_App_Uso_Eventos
            WHERE Fecha_Hora >= DATEADD(day, ?, SYSUTCDATETIME())
              AND Destino_Codigo <> ?
            GROUP BY Destino_Etiqueta
            ORDER BY n DESC
            """,
            (-days, _HEARTBEAT_CODIGO),
        )
        top_dest: List[Dict[str, Any]] = []
        for r in cur.fetchall() or []:
            top_dest.append({"destino_etiqueta": str(r[0] or ""), "n": int(r[1] or 0)})

        cur.execute(
            """
            SELECT CAST(Fecha_Hora AS DATE) AS d, COUNT(*) AS n
            FROM dbo.Tbl_App_Uso_Eventos
            WHERE Fecha_Hora >= DATEADD(day, ?, SYSUTCDATETIME())
              AND Destino_Codigo <> ?
            GROUP BY CAST(Fecha_Hora AS DATE)
            ORDER BY d ASC
            """,
            (-days, _HEARTBEAT_CODIGO),
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
              AND Destino_Codigo <> ?
            GROUP BY Usuario_Login
            ORDER BY n DESC
            """,
            (-days, _HEARTBEAT_CODIGO),
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


@router.get("/api/dev/telemetry/activos")
def usuarios_activos(
    minutes: int = Query(10, ge=1, le=240),
    authorization: Optional[str] = Header(None),
) -> Dict[str, Any]:
    """Usuarios con actividad reciente y la última pantalla que estaban viendo.

    "Conectado" = registró cualquier evento (navegación, acción o heartbeat de
    presencia) dentro de la ventana `minutes`. Para cada usuario se devuelve su
    evento más reciente, cuya etiqueta indica qué módulo estaba viendo.
    """
    _require_telemetria(authorization)
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        _prepare_telemetry_table(cur)
        cur.execute(
            """
            SELECT t.Usuario_Login, t.Rol_Efectivo, t.Destino_Etiqueta,
                   t.Tipo, t.Fecha_Hora,
                   DATEDIFF(SECOND, t.Fecha_Hora, SYSUTCDATETIME()) AS seg
            FROM dbo.Tbl_App_Uso_Eventos t
            INNER JOIN (
                SELECT Usuario_Login, MAX(Fecha_Hora) AS mx
                FROM dbo.Tbl_App_Uso_Eventos
                WHERE Fecha_Hora >= DATEADD(MINUTE, ?, SYSUTCDATETIME())
                GROUP BY Usuario_Login
            ) u ON u.Usuario_Login = t.Usuario_Login AND u.mx = t.Fecha_Hora
            ORDER BY t.Fecha_Hora DESC
            """,
            (-minutes,),
        )
        vistos: set = set()
        activos: List[Dict[str, Any]] = []
        for r in cur.fetchall() or []:
            usuario = str(r[0] or "")
            if usuario in vistos:
                continue
            vistos.add(usuario)
            seg = int(r[5] or 0)
            activos.append(
                {
                    "usuario_login": usuario,
                    "rol_efectivo": str(r[1] or ""),
                    "viendo": str(r[2] or ""),
                    "tipo": str(r[3] or ""),
                    "hace_segundos": max(0, seg),
                }
            )
        return {
            "minutes": minutes,
            "conectados": len(activos),
            "usuarios": activos,
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()
