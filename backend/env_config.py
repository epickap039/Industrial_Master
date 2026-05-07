"""Configuración por entorno (producción vs desarrollo y flags operativos).

Variables relevantes para servidor dedicado:
- IM_ENV: `production` activa validaciones estrictas en el arranque.
- CORS_ALLOW_ORIGINS: lista separada por comas (obligatoria en producción).
- JWT_SECRET, ADMIN_MASTER_PASSWORD: obligatorios en producción (sin valores por defecto débiles).
- DB_SERVER, DB_PORT, DB_DATABASE, DB_USER, DB_PASSWORD, DB_ENCRYPT, DB_TRUST_SERVER_CERTIFICATE
- IM_ALLOW_RUNTIME_DDL: `0` impide CREATE/ALTER desde endpoints y desde iniciar_auditoria (usar migraciones SQL).
- IM_ENABLE_LOCAL_FILE_LAUNCH: `1` permite /api/system/open_file (peligroso en servidores expuestos).
"""
from __future__ import annotations

import os

DEV_JWT_SECRET_FALLBACK = "industrial_manager_dev_change_me_in_production"
DEV_ADMIN_MASTER_FALLBACK = "ADMIN_ING_2024"


def is_production() -> bool:
    v = (os.environ.get("IM_ENV") or os.environ.get("ENVIRONMENT") or "").strip().lower()
    return v in ("production", "prod")


def allow_runtime_ddl() -> bool:
    """Si es False, no se deben ejecutar CREATE/ALTER desde la API ni desde iniciar_auditoria."""
    v = (os.environ.get("IM_ALLOW_RUNTIME_DDL") or "").strip().lower()
    if v in ("0", "false", "no", "off"):
        return False
    if v in ("1", "true", "yes", "on"):
        return True
    return not is_production()


def allow_local_file_launch() -> bool:
    v = (os.environ.get("IM_ENABLE_LOCAL_FILE_LAUNCH") or "").strip().lower()
    if v in ("1", "true", "yes", "on"):
        return True
    if v in ("0", "false", "no", "off"):
        return False
    return not is_production()


def cors_allow_origins() -> list[str]:
    raw = os.environ.get("CORS_ALLOW_ORIGINS") or os.environ.get("IM_CORS_ORIGINS")
    if raw and str(raw).strip():
        return [x.strip() for x in str(raw).split(",") if x.strip()]
    if is_production():
        return []
    return ["*"]


def validate_production_startup() -> None:
    """Lanza RuntimeError si falta configuración mínima en IM_ENV=production."""
    if not is_production():
        return
    errors: list[str] = []
    secret = (os.environ.get("JWT_SECRET") or "").strip()
    if not secret or secret == DEV_JWT_SECRET_FALLBACK:
        errors.append("JWT_SECRET debe estar definido y no ser el valor de desarrollo")
    master = os.environ.get("ADMIN_MASTER_PASSWORD")
    if not master or not str(master).strip():
        errors.append("ADMIN_MASTER_PASSWORD es obligatorio en IM_ENV=production")
    origins = cors_allow_origins()
    if not origins:
        errors.append(
            "CORS_ALLOW_ORIGINS (o IM_CORS_ORIGINS) debe listar orígenes explícitos en producción"
        )
    elif "*" in origins:
        errors.append("En producción no se permite CORS con origen comodín *")
    if errors:
        raise RuntimeError(
            "Configuración de producción incompleta:\n- " + "\n- ".join(errors)
        )
