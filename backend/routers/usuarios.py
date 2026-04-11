"""Usuarios: Tbl_Usuarios (id, username, password_hash, rol)."""
from __future__ import annotations

import base64
import binascii
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

def _actor_y_rol(authorization: str | None) -> tuple[str, str]:
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
    actor = str(data.get("sub") or "").strip()
    if not actor:
        raise HTTPException(status_code=401, detail="Token inválido")
    return actor, rol


class LoginUsuarioPayload(BaseModel):
    username: str = Field(..., min_length=1, max_length=100)
    password: str = Field(..., min_length=1, max_length=200)


class CrearUsuarioPayload(BaseModel):
    username: str = Field(..., min_length=2, max_length=50)
    password: str = Field(..., min_length=4, max_length=200)
    rol: str = Field(default="USER", max_length=50)
    genero: str = Field(default="N", max_length=20)


class ActualizarRolPayload(BaseModel):
    rol: str = Field(..., min_length=1, max_length=50)

class ActualizarGeneroPayload(BaseModel):
    genero: str = Field(default="N", max_length=20)

class ActualizarAvatarPayload(BaseModel):
    avatar_base64: str = Field(..., min_length=20)


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

def _normalizar_genero_api(raw: str) -> str:
    g = (raw or "").strip().upper()
    if g in {"F", "FEMENINO", "FEMALE", "MUJER"}:
        return "F"
    if g in {"M", "MASCULINO", "MALE", "HOMBRE"}:
        return "M"
    return "N"


def _fetch_usuarios_sin_hash(cur: Any, excluir_roles: bool = False) -> List[Dict[str, Any]]:
    """Devuelve usuarios sin password_hash.

    Si excluir_roles=True, excluye 'Producción' y 'Calidad'.
    """
    query_base = """
        SELECT id, username, rol, ISNULL(genero, 'N') AS genero
        FROM dbo.Tbl_Usuarios
        {where_clause}
        ORDER BY username ASC
        """
    where_clause = ""
    if excluir_roles:
        where_clause = "WHERE rol NOT IN ('Producción', 'Calidad')"
    query = query_base.format(where_clause=where_clause)
    try:
        cur.execute(query)
    except Exception:
        query_legacy = """
            SELECT id, username, rol
            FROM dbo.Tbl_Usuarios
            {where_clause}
            ORDER BY username ASC
            """.format(where_clause=where_clause)
        cur.execute(query_legacy)

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
                "genero": str(m.get("genero") or "N").strip(),
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
    genero = _normalizar_genero_api(payload.genero)
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        cur.execute("SELECT 1 FROM dbo.Tbl_Usuarios WHERE username = ?", (login,))
        if cur.fetchone():
            raise HTTPException(status_code=400, detail="El usuario ya existe")
        try:
            cur.execute(
                """
                INSERT INTO dbo.Tbl_Usuarios (username, password_hash, rol, genero)
                OUTPUT INSERTED.id
                VALUES (?, ?, ?, ?)
                """,
                (login, ph, rol, genero),
            )
        except Exception:
            # Compatibilidad si la columna genero aún no existe.
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

@router.put("/api/usuarios/{user_id}/genero")
def actualizar_genero_usuario(
    user_id: int,
    payload: ActualizarGeneroPayload,
    authorization: str | None = Header(None),
    x_usuario: str | None = Header(None, alias="X-Usuario"),
):
    _require_admin_o_desarrollador(authorization)
    genero = _normalizar_genero_api(payload.genero)
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
        target_user = str(row[0] or "").strip()
        try:
            cur.execute(
                "UPDATE dbo.Tbl_Usuarios SET genero = ? WHERE id = ?",
                (genero, user_id),
            )
        except Exception:
            raise HTTPException(
                status_code=500,
                detail="La columna genero no existe. Ejecute la migración SQL.",
            )
        registrar_log_global(
            cur,
            "USUARIOS",
            "ACTUALIZAR_GENERO",
            "",
            f"id={user_id};username={target_user[:40]};genero={genero}",
            resolve_actor_user(authorization, x_usuario),
        )
        conn.commit()
        return {
            "ok": True,
            "id": user_id,
            "username": target_user,
            "genero": genero,
        }
    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

@router.put("/api/usuarios/{username}/avatar")
def actualizar_avatar_usuario(
    username: str,
    payload: ActualizarAvatarPayload,
    authorization: str | None = Header(None),
):
    actor, rol = _actor_y_rol(authorization)
    login = (username or "").strip()
    if not login:
        raise HTTPException(status_code=400, detail="Username inválido")
    puede_gestionar = rol in _ROLES_GESTION_USUARIOS
    if actor.strip().lower() != login.lower() and not puede_gestionar:
        raise HTTPException(
            status_code=403,
            detail="Solo puede editar su propio avatar",
        )
    b64 = (payload.avatar_base64 or "").strip()
    try:
        data = base64.b64decode(b64, validate=True)
    except (binascii.Error, ValueError):
        raise HTTPException(status_code=400, detail="avatar_base64 inválido")
    if len(data) > 3 * 1024 * 1024:
        raise HTTPException(status_code=400, detail="Avatar excede 3MB")

    conn = get_db_connection()
    cur = conn.cursor()
    try:
        cur.execute("SELECT 1 FROM dbo.Tbl_Usuarios WHERE username = ?", (login,))
        if not cur.fetchone():
            raise HTTPException(status_code=404, detail="Usuario no encontrado")
        try:
            cur.execute(
                "UPDATE dbo.Tbl_Usuarios SET avatar_base64 = ? WHERE username = ?",
                (b64, login),
            )
        except Exception:
            raise HTTPException(
                status_code=500,
                detail="La columna avatar_base64 no existe. Ejecute la migración SQL.",
            )
        conn.commit()
        return {"ok": True, "usuario_login": login}
    except HTTPException:
        conn.rollback()
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

@router.get("/api/usuarios/{username}/avatar")
def obtener_avatar_usuario(username: str):
    login = (username or "").strip()
    if not login:
        raise HTTPException(status_code=400, detail="Username inválido")
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        try:
            cur.execute(
                """
                SELECT username, avatar_base64
                FROM dbo.Tbl_Usuarios
                WHERE username = ?
                """,
                (login,),
            )
        except Exception:
            raise HTTPException(
                status_code=500,
                detail="La columna avatar_base64 no existe. Ejecute la migración SQL.",
            )
        row = cur.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Usuario no encontrado")
        return {
            "usuario_login": str(row[0] or "").strip(),
            "avatar_base64": str(row[1] or "").strip(),
        }
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()

@router.delete("/api/usuarios/{username}/avatar")
def eliminar_avatar_usuario(
    username: str,
    authorization: str | None = Header(None),
):
    actor, rol = _actor_y_rol(authorization)
    login = (username or "").strip()
    if not login:
        raise HTTPException(status_code=400, detail="Username inválido")
    puede_gestionar = rol in _ROLES_GESTION_USUARIOS
    if actor.strip().lower() != login.lower() and not puede_gestionar:
        raise HTTPException(
            status_code=403,
            detail="Solo puede eliminar su propio avatar",
        )
    conn = get_db_connection()
    cur = conn.cursor()
    try:
        try:
            cur.execute(
                "UPDATE dbo.Tbl_Usuarios SET avatar_base64 = NULL WHERE username = ?",
                (login,),
            )
        except Exception:
            raise HTTPException(
                status_code=500,
                detail="La columna avatar_base64 no existe. Ejecute la migración SQL.",
            )
        if cur.rowcount <= 0:
            raise HTTPException(status_code=404, detail="Usuario no encontrado")
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
        try:
            cur.execute(
                """
                SELECT id, username, rol, ISNULL(genero, 'N') AS genero, ISNULL(avatar_base64, '') AS avatar_base64
                FROM dbo.Tbl_Usuarios
                WHERE username = ? AND password_hash = ?
                """,
                (username, hashed),
            )
        except Exception:
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
            "genero": str(m.get("genero") or "N").strip(),
            "avatar_base64": str(m.get("avatar_base64") or "").strip(),
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
            COALESCE(color_hex, '#7F7F7F') as color_hex
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
                "color_hex": m.get("color_hex", "#7F7F7F")
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
def actualizar_color_usuario(
    username: str,
    payload: UsuarioColorUpdate,
    authorization: str | None = Header(None),
):
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

        actor, rol = _actor_y_rol(authorization)
        target = (username or "").strip()
        if not target:
            raise HTTPException(status_code=400, detail="Usuario inválido")
        puede_gestionar = rol in _ROLES_GESTION_USUARIOS
        if actor.strip().lower() != target.lower() and not puede_gestionar:
            raise HTTPException(
                status_code=403,
                detail="Solo puede editar su propio color",
            )

        conn = get_db_connection()
        cur = conn.cursor()

        # Verificar que usuario existe

        cur.execute(
            "SELECT username FROM dbo.Tbl_Usuarios WHERE username = ?",
            (target,)
        )

        if not cur.fetchone():
            cur.close()
            conn.close()
            raise HTTPException(
                status_code=404,
                detail=f"Usuario '{target}' no encontrado"
            )

        # Evitar colores repetidos entre usuarios distintos.
        # Excepción: gris temporal (#7F7F7F) puede repetirse.
        if payload.color_hex.strip().upper() != "#7F7F7F":
            cur.execute(
                """
                SELECT TOP 1 username
                FROM dbo.Tbl_Usuarios
                WHERE UPPER(ISNULL(color_hex, '')) = UPPER(?)
                  AND username <> ?
                """,
                (payload.color_hex, target),
            )
            dup = cur.fetchone()
            if dup:
                raise HTTPException(
                    status_code=409,
                    detail=f"El color {payload.color_hex} ya está asignado a '{dup[0]}'.",
                )

        # Actualizar color
        update_query = """
        UPDATE dbo.Tbl_Usuarios
        SET color_hex = ?
        WHERE username = ?
        """

        cur.execute(update_query, (payload.color_hex, target))
        conn.commit()
        cur.close()
        conn.close()

        # Retornar información actualizada
        return UsuarioColorResponse(
            usuario_login=target,
            color_hex=payload.color_hex
        )

    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Error al actualizar color: {str(e)}"
        )

@router.get("/api/usuarios/colores-ocupados")
def colores_ocupados():
    """
    Devuelve mapa de colores ya asignados para bloquear repetidos en UI.
    """
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute(
            """
            SELECT username, COALESCE(color_hex, '#7F7F7F') as color_hex
            FROM dbo.Tbl_Usuarios
            ORDER BY username ASC
            """
        )
        rows = cur.fetchall()
        out: list[dict[str, str]] = []
        for r in rows:
            out.append(
                {
                    "username": str(r[0] or "").strip(),
                    "color_hex": str(r[1] or "#7F7F7F").strip().upper(),
                }
            )
        cur.close()
        conn.close()
        return {"ocupados": out}
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Error al consultar colores ocupados: {str(e)}",
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
            COALESCE(color_hex, '#7F7F7F') as color_hex
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
            color_hex=m.get("color_hex", "#7F7F7F")
        )

    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Error al obtener color: {str(e)}"
        )

