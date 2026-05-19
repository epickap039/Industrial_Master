"""Tokens JWT de sesión (HS256). Secreto vía env JWT_SECRET en producción."""
from __future__ import annotations

import os
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, Optional

from env_config import DEV_JWT_SECRET_FALLBACK

try:
    import jwt
except ModuleNotFoundError as e:
    raise ImportError(
        "Falta el paquete PyJWT (proporciona el módulo 'jwt'). "
        "Use el mismo Python que arranca el servidor y ejecute:\n"
        "  python -m pip install PyJWT\n"
        "o desde la carpeta backend:\n"
        "  python -m pip install -r requirements.txt\n"
        "No instale el paquete pypi 'jwt' (es otro proyecto); debe ser 'PyJWT'."
    ) from e

JWT_SECRET = os.environ.get("JWT_SECRET", DEV_JWT_SECRET_FALLBACK)
JWT_ALG = "HS256"
# Sin caducidad práctica: la sesión termina solo con "Cerrar sesión" en la app.
JWT_EXPIRE_DAYS = 3650


def create_access_token(username: str, rol: str) -> str:
    now = datetime.now(timezone.utc)
    payload: Dict[str, Any] = {
        "sub": (username or "").strip(),
        "rol": (rol or "USER").strip(),
        "iat": int(now.timestamp()),
        "exp": now + timedelta(days=JWT_EXPIRE_DAYS),
    }
    return jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALG)


def decode_access_token_payload(authorization: Optional[str]) -> Optional[Dict[str, Any]]:
    if not authorization or not str(authorization).strip().lower().startswith("bearer "):
        return None
    token = str(authorization)[7:].strip()
    if not token:
        return None
    try:
        return jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALG])
    except jwt.PyJWTError:
        return None


def subject_from_authorization(authorization: Optional[str]) -> Optional[str]:
    data = decode_access_token_payload(authorization)
    if not data:
        return None
    sub = data.get("sub")
    if sub is None:
        return None
    s = str(sub).strip()
    return s if s else None
