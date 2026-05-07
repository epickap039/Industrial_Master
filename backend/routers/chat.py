"""Chat interno entre usuarios (REST + WebSocket)."""
from __future__ import annotations

import asyncio
import importlib.util
from datetime import datetime
from typing import Any, Dict, List, Optional, Set

from fastapi import APIRouter, HTTPException, WebSocket, WebSocketDisconnect
from pydantic import BaseModel, Field

from database import get_db_connection
from env_config import allow_runtime_ddl
from schema_guard import table_exists

router = APIRouter()

_WS_CLIENTS: Dict[str, Set[WebSocket]] = {}
_WS_LOCK = asyncio.Lock()
_GROUP_CHAT_ROOM = "__CHAT_GRUPAL__"


@router.get("/api/chat/ws_health")
def ws_health():
    has_websockets = importlib.util.find_spec("websockets") is not None
    has_wsproto = importlib.util.find_spec("wsproto") is not None
    connected_users = len(_WS_CLIENTS)
    total_sockets = sum(len(v) for v in _WS_CLIENTS.values())
    return {
        "ok": has_websockets or has_wsproto,
        "websocket_library": {
            "websockets": has_websockets,
            "wsproto": has_wsproto,
        },
        "connected_users": connected_users,
        "connected_sockets": total_sockets,
    }


class ChatSendPayload(BaseModel):
    emisor: str = Field(..., min_length=1, max_length=120)
    receptor: str = Field(..., min_length=1, max_length=120)
    mensaje: str = Field(..., min_length=1, max_length=4000)


class ChatReadPayload(BaseModel):
    lector: str = Field(..., min_length=1, max_length=120)
    otro_usuario: str = Field(..., min_length=1, max_length=120)


class GroupChatSendPayload(BaseModel):
    emisor: str = Field(..., min_length=1, max_length=120)
    mensaje: str = Field(..., min_length=1, max_length=4000)


def _norm_user(v: str) -> str:
    return (v or "").strip()


def _prepare_chat_schema(cur: Any) -> None:
    if table_exists(cur, "Tbl_Chat_Mensajes"):
        return
    if allow_runtime_ddl():
        _ensure_chat_tables(cur)
    else:
        raise HTTPException(
            status_code=503,
            detail=(
                "Esquema de chat no instalado. Ejecute la migración "
                "backend/sql/add_chat_interno_tables.sql (tabla Tbl_Chat_Mensajes)."
            ),
        )


def _ensure_chat_tables(cur: Any) -> None:
    cur.execute(
        """
        IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'Tbl_Chat_Mensajes')
        BEGIN
            CREATE TABLE dbo.Tbl_Chat_Mensajes (
                ID_Mensaje INT IDENTITY(1,1) PRIMARY KEY,
                Emisor NVARCHAR(120) NOT NULL,
                Receptor NVARCHAR(120) NOT NULL,
                Tipo NVARCHAR(20) NOT NULL CONSTRAINT DF_Tbl_Chat_Mensajes_Tipo DEFAULT ('texto'),
                Mensaje NVARCHAR(MAX) NULL,
                Fecha_Envio DATETIME2(0) NOT NULL CONSTRAINT DF_Tbl_Chat_Mensajes_Fecha DEFAULT (SYSUTCDATETIME()),
                Leido BIT NOT NULL CONSTRAINT DF_Tbl_Chat_Mensajes_Leido DEFAULT (0)
            );
            CREATE INDEX IX_Tbl_Chat_Mensajes_ParFecha
                ON dbo.Tbl_Chat_Mensajes (Emisor, Receptor, Fecha_Envio DESC);
            CREATE INDEX IX_Tbl_Chat_Mensajes_ReceptorLeido
                ON dbo.Tbl_Chat_Mensajes (Receptor, Leido, Fecha_Envio DESC);
        END
        """
    )


def _insert_chat_message(cur: Any, emisor: str, receptor: str, mensaje: str, tipo: str) -> int:
    cur.execute(
        """
        INSERT INTO dbo.Tbl_Chat_Mensajes (Emisor, Receptor, Tipo, Mensaje)
        OUTPUT INSERTED.ID_Mensaje
        VALUES (?, ?, ?, ?)
        """,
        (emisor, receptor, tipo, mensaje),
    )
    return int(cur.fetchone()[0])


async def _broadcast_to_user(usuario: str, event: Dict[str, Any]) -> None:
    user = _norm_user(usuario)
    if not user:
        return
    async with _WS_LOCK:
        sockets = list(_WS_CLIENTS.get(user, set()))
    if not sockets:
        return
    stale: List[WebSocket] = []
    for ws in sockets:
        try:
            await ws.send_json(event)
        except Exception:
            stale.append(ws)
    if stale:
        async with _WS_LOCK:
            curr = _WS_CLIENTS.get(user, set())
            for ws in stale:
                curr.discard(ws)
            if not curr:
                _WS_CLIENTS.pop(user, None)


async def _broadcast_all(event: Dict[str, Any]) -> None:
    async with _WS_LOCK:
        users = list(_WS_CLIENTS.keys())
    for user in users:
        await _broadcast_to_user(user, event)


@router.get("/api/chat/usuarios")
def chat_usuarios():
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        _prepare_chat_schema(cur)
        conn.commit()
        cur.execute(
            """
            SELECT username
            FROM dbo.Tbl_Usuarios
            ORDER BY username
            """
        )
        out = []
        for (u,) in cur.fetchall():
            us = str(u or "").strip()
            if not us:
                continue
            out.append({"username": us, "nombre": us})
        return out
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.get("/api/chat/conversaciones/{usuario}")
def chat_conversaciones(usuario: str):
    user = _norm_user(usuario)
    if not user:
        raise HTTPException(status_code=400, detail="Usuario inválido")
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        _prepare_chat_schema(cur)
        conn.commit()
        cur.execute(
            """
            ;WITH paired AS (
                SELECT
                    CASE WHEN Emisor = ? THEN Receptor ELSE Emisor END AS OtroUsuario,
                    Fecha_Envio,
                    Mensaje,
                    Tipo,
                    Emisor,
                    Receptor
                FROM dbo.Tbl_Chat_Mensajes
                WHERE (Emisor = ? OR Receptor = ?)
                  AND Emisor <> ?
                  AND Receptor <> ?
            ),
            latest AS (
                SELECT *,
                       ROW_NUMBER() OVER (PARTITION BY OtroUsuario ORDER BY Fecha_Envio DESC, (SELECT NULL)) AS rn
                FROM paired
            )
            SELECT l.OtroUsuario, l.Fecha_Envio, l.Mensaje, l.Tipo,
                   (SELECT COUNT(1)
                    FROM dbo.Tbl_Chat_Mensajes m
                    WHERE m.Emisor = l.OtroUsuario AND m.Receptor = ? AND m.Leido = 0) AS NoLeidos
            FROM latest l
            WHERE l.rn = 1
            ORDER BY l.Fecha_Envio DESC
            """,
            (user, user, user, _GROUP_CHAT_ROOM, _GROUP_CHAT_ROOM, user),
        )
        rows = cur.fetchall()
        return [
            {
                "otro_usuario": str(r[0] or ""),
                "fecha": r[1].isoformat() if r[1] else None,
                "mensaje": str(r[2] or ""),
                "tipo": str(r[3] or "texto"),
                "no_leidos": int(r[4] or 0),
            }
            for r in rows
        ]
    finally:
        conn.close()


@router.get("/api/chat/mensajes")
def chat_mensajes(u1: str, u2: str, limit: int = 120):
    a = _norm_user(u1)
    b = _norm_user(u2)
    if not a or not b:
        raise HTTPException(status_code=400, detail="Par de usuarios inválido")
    lim = max(1, min(limit, 500))
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        _prepare_chat_schema(cur)
        conn.commit()
        cur.execute(
            f"""
            SELECT TOP ({lim}) ID_Mensaje, Emisor, Receptor, Tipo, Mensaje, Fecha_Envio, Leido
            FROM dbo.Tbl_Chat_Mensajes
            WHERE (Emisor = ? AND Receptor = ?) OR (Emisor = ? AND Receptor = ?)
            ORDER BY ID_Mensaje DESC
            """,
            (a, b, b, a),
        )
        rows = cur.fetchall()
        rows = list(reversed(rows))
        return [
            {
                "id_mensaje": int(r[0]),
                "emisor": str(r[1] or ""),
                "receptor": str(r[2] or ""),
                "tipo": str(r[3] or "texto"),
                "mensaje": str(r[4] or ""),
                "fecha_envio": r[5].isoformat() if r[5] else None,
                "leido": bool(r[6]),
            }
            for r in rows
        ]
    finally:
        conn.close()


@router.get("/api/chat/grupal/mensajes")
def chat_group_messages(limit: int = 220):
    lim = max(1, min(limit, 500))
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        _prepare_chat_schema(cur)
        conn.commit()
        cur.execute(
            f"""
            SELECT TOP ({lim}) ID_Mensaje, Emisor, Receptor, Tipo, Mensaje, Fecha_Envio, Leido
            FROM dbo.Tbl_Chat_Mensajes
            WHERE Receptor = ?
            ORDER BY ID_Mensaje DESC
            """,
            (_GROUP_CHAT_ROOM,),
        )
        rows = list(reversed(cur.fetchall()))
        return [
            {
                "id_mensaje": int(r[0]),
                "emisor": str(r[1] or ""),
                "receptor": str(r[2] or ""),
                "tipo": str(r[3] or "texto"),
                "mensaje": str(r[4] or ""),
                "fecha_envio": r[5].isoformat() if r[5] else None,
                "leido": bool(r[6]),
            }
            for r in rows
        ]
    finally:
        conn.close()


@router.post("/api/chat/mensajes")
async def chat_send(payload: ChatSendPayload):
    emisor = _norm_user(payload.emisor)
    receptor = _norm_user(payload.receptor)
    mensaje = (payload.mensaje or "").strip()
    if not emisor or not receptor or not mensaje:
        raise HTTPException(status_code=400, detail="Datos de mensaje inválidos")
    if receptor == _GROUP_CHAT_ROOM:
        raise HTTPException(status_code=400, detail="Usa /api/chat/grupal/mensajes para chat grupal")
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        _prepare_chat_schema(cur)
        mid = _insert_chat_message(cur, emisor, receptor, mensaje, "texto")
        conn.commit()
        event = {
            "kind": "chat_message",
            "id_mensaje": mid,
            "emisor": emisor,
            "receptor": receptor,
            "tipo": "texto",
            "mensaje": mensaje,
            "fecha_envio": datetime.utcnow().isoformat(),
        }
        await _broadcast_to_user(receptor, event)
        await _broadcast_to_user(emisor, event)
        return {"ok": True, "id_mensaje": mid}
    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.post("/api/chat/grupal/mensajes")
async def chat_group_send(payload: GroupChatSendPayload):
    emisor = _norm_user(payload.emisor)
    mensaje = (payload.mensaje or "").strip()
    if not emisor or not mensaje:
        raise HTTPException(status_code=400, detail="Datos de mensaje inválidos")
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        _prepare_chat_schema(cur)
        mid = _insert_chat_message(cur, emisor, _GROUP_CHAT_ROOM, mensaje, "texto_grupal")
        conn.commit()
        event = {
            "kind": "chat_group_message",
            "id_mensaje": mid,
            "emisor": emisor,
            "receptor": _GROUP_CHAT_ROOM,
            "tipo": "texto_grupal",
            "mensaje": mensaje,
            "fecha_envio": datetime.utcnow().isoformat(),
        }
        await _broadcast_all(event)
        return {"ok": True, "id_mensaje": mid}
    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.post("/api/chat/zumbido")
async def chat_buzz(payload: ChatSendPayload):
    emisor = _norm_user(payload.emisor)
    receptor = _norm_user(payload.receptor)
    if not emisor or not receptor:
        raise HTTPException(status_code=400, detail="Datos de zumbido inválidos")
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        _prepare_chat_schema(cur)
        cur.execute(
            """
            SELECT TOP 1 Fecha_Envio
            FROM dbo.Tbl_Chat_Mensajes
            WHERE Emisor = ? AND Receptor = ? AND Tipo = 'zumbido'
            ORDER BY ID_Mensaje DESC
            """,
            (emisor, receptor),
        )
        row = cur.fetchone()
        if row and row[0]:
            delta = (datetime.utcnow() - row[0]).total_seconds()
            if delta < 30:
                raise HTTPException(
                    status_code=429,
                    detail=f"Espera {int(30 - delta)}s para enviar otro zumbido.",
                )
        mid = _insert_chat_message(cur, emisor, receptor, "(zumbido)", "zumbido")
        conn.commit()
        event = {
            "kind": "chat_buzz",
            "id_mensaje": mid,
            "emisor": emisor,
            "receptor": receptor,
            "tipo": "zumbido",
            "mensaje": "(zumbido)",
            "fecha_envio": datetime.utcnow().isoformat(),
        }
        await _broadcast_to_user(receptor, event)
        await _broadcast_to_user(emisor, event)
        return {"ok": True, "id_mensaje": mid}
    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.put("/api/chat/leidos")
def chat_mark_read(payload: ChatReadPayload):
    lector = _norm_user(payload.lector)
    otro = _norm_user(payload.otro_usuario)
    if not lector or not otro:
        raise HTTPException(status_code=400, detail="Datos inválidos")
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        _prepare_chat_schema(cur)
        cur.execute(
            """
            UPDATE dbo.Tbl_Chat_Mensajes
            SET Leido = 1
            WHERE Emisor = ? AND Receptor = ? AND Leido = 0
            """,
            (otro, lector),
        )
        n = int(cur.rowcount or 0)
        conn.commit()
        return {"ok": True, "actualizados": n}
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.websocket("/ws/chat/{usuario}")
async def ws_chat(websocket: WebSocket, usuario: str):
    user = _norm_user(usuario)
    await websocket.accept()
    if not user:
        await websocket.close()
        return
    async with _WS_LOCK:
        _WS_CLIENTS.setdefault(user, set()).add(websocket)
    try:
        while True:
            _ = await websocket.receive_text()
    except WebSocketDisconnect:
        pass
    finally:
        async with _WS_LOCK:
            sockets = _WS_CLIENTS.get(user, set())
            sockets.discard(websocket)
            if not sockets:
                _WS_CLIENTS.pop(user, None)
