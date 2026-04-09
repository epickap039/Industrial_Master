"""Usuarios: Tbl_Usuarios (id, username, password_hash, rol)."""
from __future__ import annotations

import re
from typing import Any, Dict, List

from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel, Field

from admin_master_password import assert_admin_master_password_matches
from audit_service import registrar_log_global
from auth_service import hash_password
from database import get_db_connection
from jwt_tokens import create_access_token, decode_access_token_payload
from user_context import resolve_actor_user

router = APIRouter()


_ROLES_GESTION_USUARIOS = frozenset(
    {
        "ADMINISTRADOR",
        "ADMIN",
        "DESARROLLADOR",
        "DESARROLLO",
        "DEVELOPER",
    }
)


def _require_admin_o_desarrollador(authorization: str | None) -> str:
    """Username del token si el rol puede gestionar usuarios (admin o desarrollador)."""
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
    if rol not in _ROLES_GESTION_USUARIOS:
        raise HTTPException(
            status_code=403,
            detail="Solo administradores o desarrolladores pueden realizar esta operación",
        )
    sub = str(data.get("sub") or "").strip()
    if not sub:
        raise HTTPException(status_code=401, detail="Token inválido")
    return sub


class LoginUsuarioPayload(BaseModel):
    username: str = Field(..., min_length=1, max_length=100)
    password: str = Field(..., min_length=1, max_length=200)


class CrearUsuarioPayload(BaseModel):
    username: str = Field(..., min_length=2, max_length=50)
    password: str = Field(..., min_length=4, max_length=200)
    rol: str = Field(default="USER", max_length=50)


class ActualizarRolPayload(BaseModel):
    rol: str = Field(..., min_length=1, max_length=50)


_ROLES_VALIDOS = frozenset(
    {
        "ADMINISTRADOR",
        "CALIDAD",
        "PRODUCCION",
        "INGENIERIA_METODOS",
        "GESTION",
        "COMPRAS",
        "DIRECCION",
        "USER",
        "QA",
    }
)


def _normalizar_rol_api(raw: str) -> str:
    r = (raw or "").strip().upper().replace(" ", "_")
    if r == "PRODUCCIÓN" or r == "PRODUCCION":
        return "PRODUCCION"
    if r == "GESTIÓN" or r == "GESTION":
        return "GESTION"
    if r == "DIRECCIÓN" or r == "DIRECCION":
        return "DIRECCION"
    return r


def _fetch_usuarios_sin_hash(cur: Any, excluir_roles: bool = False) -> List[Dict[str, Any]]:
    """Devuelve usuarios sin password_hash.

    Si excluir_roles=True, excluye 'Producción' y 'Calidad'.
    """
    query = """
        SELECT id, username, rol
        FROM dbo.Tbl_Usuarios
        ORDER BY username ASC
        """
    if excluir_roles:
        query = """
        SELECT id, username, rol
        FROM dbo.Tbl_Usuarios
        WHERE rol NOT IN ('Producción', 'Calidad')
        ORDER BY username ASC
        """

    cur.execute(query)
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
    """Devuelve lista de usuarios disponibles para asignar tareas.
    Excluye roles 'Producción' y 'Calidad'.
    """
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        return _fetch_usuarios_sin_hash(cur, excluir_roles=True)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.get("/api/usuarios/all")
def listar_todos_usuarios():
    """Devuelve lista COMPLETA de usuarios (incluyendo Producción y Calidad).
    Usado para configuración y colores.
    """
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        return _fetch_usuarios_sin_hash(cur, excluir_roles=False)
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
    rol = _normalizar_rol_api(payload.rol or "USER") or "USER"
    if rol not in _ROLES_VALIDOS:
        raise HTTPException(status_code=400, detail=f"Rol no permitido: {rol}")
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


@router.put("/api/usuarios/{user_id}/rol")
def actualizar_rol_usuario(
    user_id: int,
    payload: ActualizarRolPayload,
    authorization: str | None = Header(None),
    x_usuario: str | None = Header(None, alias="X-Usuario"),
):
    actor = _require_admin_o_desarrollador(authorization)
    nuevo = _normalizar_rol_api(payload.rol)
    if nuevo not in _ROLES_VALIDOS:
        raise HTTPException(status_code=400, detail=f"Rol no permitido: {nuevo}")
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        cur.execute(
            "SELECT username, rol FROM dbo.Tbl_Usuarios WHERE id = ?",
            (user_id,),
        )
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Usuario no encontrado")
        target_user = str(row[0] or "").strip()
        if target_user.lower() == actor.strip().lower():
            raise HTTPException(
                status_code=400,
                detail="No puede cambiar el rol de su propia cuenta desde aquí",
            )
        cur.execute(
            "UPDATE dbo.Tbl_Usuarios SET rol = ? WHERE id = ?",
            (nuevo, user_id),
        )
        registrar_log_global(
            cur,
            "USUARIOS",
            "ACTUALIZAR_ROL",
            "",
            f"id={user_id};username={target_user[:40]};rol={nuevo}",
            resolve_actor_user(authorization, x_usuario),
        )
        conn.commit()
        return {"ok": True, "id": user_id, "username": target_user, "rol": nuevo}
    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


@router.delete("/api/usuarios/{user_id}")
def eliminar_usuario(
    user_id: int,
    authorization: str | None = Header(None),
    x_usuario: str | None = Header(None, alias="X-Usuario"),
    x_admin_master_password: str | None = Header(
        None, alias="X-Admin-Master-Password"
    ),
):
    assert_admin_master_password_matches(x_admin_master_password)
    actor = _require_admin_o_desarrollador(authorization)
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        cur.execute(
            "SELECT username FROM dbo.Tbl_Usuarios WHERE id = ?",
            (user_id,),
        )
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Usuario no encontrado")
        target = str(row[0] or "").strip()
        if target.lower() == actor.strip().lower():
            raise HTTPException(
                status_code=400,
                detail="No puede eliminar su propia cuenta",
            )
        cur.execute("DELETE FROM dbo.Tbl_Usuarios WHERE id = ?", (user_id,))
        registrar_log_global(
            cur,
            "USUARIOS",
            "ELIMINAR_USUARIO",
            "",
            f"id={user_id};username={target[:40]}",
            resolve_actor_user(authorization, x_usuario),
        )
        conn.commit()
        return {"ok": True}
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


# ============================================================================
# ENDPOINTS DE COLOR DE USUARIO - MEJORA INTEGRAL v15.5
# ============================================================================

class UsuarioColorUpdate(BaseModel):
    """Payload para actualizar el color de un usuario."""
    color_hex: str = Field(
        ...,
        pattern=r'^#[0-9A-Fa-f]{6}$',
        description="Color hexadecimal (ej: #FF8C00)",
        examples=["#FF8C00", "#4ECDC4", "#FF6B6B"]
    )


class UsuarioColorResponse(BaseModel):
    """Respuesta con información de color del usuario."""
    usuario_login: str
    color_hex: str


@router.get("/lista")
def obtener_usuarios_lista():
    """
    Obtiene lista de todos los usuarios registrados en el sistema.

    Retorna:
    - Lista de usuarios con su información básica y color asignado

    Response:
    ```json
    [
        {
            "id": 1,
            "username": "jperez",
            "rol": "Admin",
            "color_hex": "#FF8C00"
        }
    ]
    ```
    """
    try:
        conn = get_db_connection()
        cur = conn.cursor()

        query = """
        SELECT
            id,
            username,
            rol,
            COALESCE(color_hex, '#FF8C00') as color_hex
        FROM dbo.Tbl_Usuarios
        ORDER BY username ASC
        """

        cur.execute(query)
        rows = cur.fetchall()
        cols = [d[0] for d in cur.description]

        usuarios = []
        for row in rows:
            m = dict(zip(cols, row))
            usuarios.append({
                "id": m.get("id"),
                "username": m.get("username"),
                "rol": m.get("rol"),
                "color_hex": m.get("color_hex", "#FF8C00")
            })

        cur.close()
        conn.close()

        return usuarios

    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Error al obtener lista de usuarios: {str(e)}"
        )


@router.put("/api/usuarios/{username}/color")
def actualizar_color_usuario(username: str, payload: UsuarioColorUpdate):
    """
    Actualiza el color hexadecimal asignado a un usuario.

    Args:
    - username: Login del usuario (ejemplo: "jperez")
    - payload: Objeto con campo 'color_hex' (ejemplo: "#4ECDC4")

    Valida:
    - Formato hexadecimal válido (#RRGGBB)
    - Usuario existe en la base de datos

    Response:
    ```json
    {
        "usuario_login": "jperez",
        "color_hex": "#4ECDC4"
    }
    ```

    Errores:
    - 404: Usuario no existe
    - 400: Formato de color inválido
    - 500: Error en la base de datos
    """
    try:
        # Validar formato de color
        if not re.match(r'^#[0-9A-Fa-f]{6}$', payload.color_hex):
            raise HTTPException(
                status_code=400,
                detail=f"Formato de color inválido. Use formato #RRGGBB (ejemplo: #FF8C00)"
            )

        conn = get_db_connection()
        cur = conn.cursor()

        # Verificar que usuario existe

        cur.execute(
            "SELECT username FROM dbo.Tbl_Usuarios WHERE username = ?",
            (username,)
        )

        if not cur.fetchone():
            cur.close()
            conn.close()
            raise HTTPException(
                status_code=404,
                detail=f"Usuario '{username}' no encontrado"
            )

        # Actualizar color
        update_query = """
        UPDATE dbo.Tbl_Usuarios
        SET color_hex = ?
        WHERE username = ?
        """

        cur.execute(update_query, (payload.color_hex, username))
        conn.commit()
        cur.close()
        conn.close()

        # Retornar información actualizada
        return UsuarioColorResponse(
            usuario_login=username,
            color_hex=payload.color_hex
        )

    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Error al actualizar color: {str(e)}"
        )


@router.get("/api/usuarios/{username}/color")
def obtener_color_usuario(username: str):
    """
    Obtiene el color hexadecimal asignado a un usuario específico.

    Args:
    - username: Login del usuario (ejemplo: "jperez")

    Response:
    ```json
    {
        "usuario_login": "jperez",
        "color_hex": "#FF8C00"
    }
    ```

    Errores:
    - 404: Usuario no existe
    - 500: Error en la base de datos
    """
    try:
        conn = get_db_connection()
        cur = conn.cursor()


        query = """
        SELECT
            username,
            COALESCE(color_hex, '#FF8C00') as color_hex
        FROM dbo.Tbl_Usuarios
        WHERE username = ?
        """

        cur.execute(query, (username,))
        row = cur.fetchone()
        cur.close()
        conn.close()

        if not row:
            raise HTTPException(
                status_code=404,
                detail=f"Usuario '{username}' no encontrado"
            )

        cols = ["username", "color_hex"]
        m = dict(zip(cols, row))

        return UsuarioColorResponse(
            usuario_login=m.get("username"),
            color_hex=m.get("color_hex", "#FF8C00")
        )

    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Error al obtener color: {str(e)}"
        )

