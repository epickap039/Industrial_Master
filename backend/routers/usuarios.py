"""Usuarios: Tbl_Usuarios (id, username, password_hash, rol)."""
from __future__ import annotations

import re
from typing import Any, Dict, List

from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel, Field

from audit_service import registrar_log_global
from auth_service import hash_password
from database import get_db_connection
from jwt_tokens import create_access_token
from user_context import resolve_actor_user

router = APIRouter()


class LoginUsuarioPayload(BaseModel):
    username: str = Field(..., min_length=1, max_length=100)
    password: str = Field(..., min_length=1, max_length=200)


class CrearUsuarioPayload(BaseModel):
    username: str = Field(..., min_length=2, max_length=50)
    password: str = Field(..., min_length=4, max_length=200)
    rol: str = Field(default="USER", max_length=50)


def _fetch_usuarios_sin_hash(cur: Any) -> List[Dict[str, Any]]:
    cur.execute(
        """
        SELECT id, username, rol
        FROM dbo.Tbl_Usuarios
        ORDER BY username ASC
        """
    )
    cols = [d[0] for d in cur.description]
    out: List[Dict[str, Any]] = []
    for row in cur.fetchall():
        m = dict(zip(cols, row))
        uid = m.get("id")
        try:
            id_int = int(uid) if uid is not None else 0
        except (TypeError, ValueError):
            id_int = 0
        out.append(
            {
                "id": id_int,
                "username": str(m.get("username") or "").strip(),
                "rol": str(m.get("rol") or "USER").strip(),
            }
        )
    return out


@router.get("/api/usuarios/lista")
def listar_usuarios():
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        return _fetch_usuarios_sin_hash(cur)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.post("/api/usuarios/crear")
def crear_usuario(
    payload: CrearUsuarioPayload,
    authorization: str | None = Header(None),
    x_usuario: str | None = Header(None, alias="X-Usuario"),
):
    usr = resolve_actor_user(authorization, x_usuario)
    login = payload.username.strip()
    if not re.match(r"^[A-Za-z0-9._@-]+$", login):
        raise HTTPException(
            status_code=400,
            detail="Usuario: solo letras, números y . _ @ -",
        )
    rol = (payload.rol or "USER").strip().upper() or "USER"
    ph = hash_password(payload.password)
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        cur.execute("SELECT 1 FROM dbo.Tbl_Usuarios WHERE username = ?", (login,))
        if cur.fetchone():
            raise HTTPException(status_code=400, detail="El usuario ya existe")
        cur.execute(
            """
            INSERT INTO dbo.Tbl_Usuarios (username, password_hash, rol)
            OUTPUT INSERTED.id
            VALUES (?, ?, ?)
            """,
            (login, ph, rol),
        )
        row = cur.fetchone()
        try:
            nuevo_id = int(row[0]) if row and row[0] is not None else 0
        except (TypeError, ValueError):
            nuevo_id = 0
        registrar_log_global(
            cur,
            "USUARIOS",
            "CREAR_USUARIO",
            "",
            f"username={login[:40]};rol={rol}",
            usr,
        )
        conn.commit()
        return {"ok": True, "id": nuevo_id}
    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.post("/api/usuarios/login")
def login_usuario(payload: LoginUsuarioPayload):
    username = (payload.username or "").strip()
    if not username:
        raise HTTPException(status_code=400, detail="Usuario requerido")
    hashed = hash_password(payload.password)
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        cur.execute(
            """
            SELECT id, username, rol
            FROM dbo.Tbl_Usuarios
            WHERE username = ? AND password_hash = ?
            """,
            (username, hashed),
        )
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=401, detail="Credenciales incorrectas")
        cols = [d[0] for d in cur.description]
        m = dict(zip(cols, row))
        try:
            uid = int(m.get("id") or 0)
        except (TypeError, ValueError):
            uid = 0
        uname = str(m.get("username") or username).strip()
        rol = str(m.get("rol") or "USER").strip()
        token = create_access_token(uname, str(rol))
        return {
            "success": True,
            "id": uid,
            "username": uname,
            "rol": rol,
            "access_token": token,
        }
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()
