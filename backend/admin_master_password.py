"""Contraseña maestra para operaciones destructivas (solo servidor).

Definir en producción la variable de entorno ADMIN_MASTER_PASSWORD.
Si no está definida, se usa un valor por defecto de desarrollo.
"""
from __future__ import annotations

import os

from fastapi import HTTPException

ENV_ADMIN_MASTER_PASSWORD = "ADMIN_MASTER_PASSWORD"
_DEFAULT_FALLBACK = "ADMIN_ING_2024"


def get_admin_master_password() -> str:
    v = os.environ.get(ENV_ADMIN_MASTER_PASSWORD)
    if v is not None and str(v).strip() != "":
        return str(v).strip()
    return _DEFAULT_FALLBACK


def assert_admin_master_password_matches(provided: str | None) -> None:
    """Lanza 401 si la contraseña no coincide con la configurada en el servidor."""
    expected = get_admin_master_password()
    if (provided or "").strip() != expected:
        raise HTTPException(
            status_code=401,
            detail="Contraseña maestra incorrecta",
        )
